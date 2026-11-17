//! Chapter 14: a deliberately small page model to try split policies on.
//!
//! There is no pager and there are no bytes: a leaf page is a sorted list of
//! cells that only remember how many bytes they WOULD occupy, and the whole
//! upper part of the tree is flattened into one sorted "directory" of
//! separators. That is enough to measure what a split policy does to space:
//! how many pages, how full, and how large the separators.
//!
//!   directory:  [ -inf -> leaf 0 | (20) -> leaf 2 | (20,7) -> leaf 1 | ... ]
//!   leaves:       cells sorted by (key, tid), used <= capacity
//!
//! Invariants (checked by `validate`):
//!   I1  directory separators are strictly ascending
//!   I2  every cell of the page behind entry i is >= entry i's separator and
//!       < entry i+1's separator
//!   I3  cells inside a page are strictly ascending by (key, tid)
//!   I4  used == sum of cell sizes, and used <= capacity
//!   I5  len == number of cells in all pages
const std = @import("std");
const Allocator = std.mem.Allocator;
const split = @import("split.zig");

pub const Cell = split.Cell;
pub const Policy = split.Policy;
pub const Strategy = split.Strategy;

/// Lower bound of a page, stored in the directory.
///
/// `tid == null` is a TRUNCATED separator: it compares below every cell with
/// the same key, which is only correct if the page to its left holds no cell
/// with that key. A cut between two different keys can therefore store the
/// bare key (8 bytes); a cut inside a run of equal keys has to keep the tid
/// as well (16 bytes). This is the model's version of suffix truncation.
pub const Sep = struct {
    key: u64,
    tid: ?u64,

    pub fn bytes(self: Sep) u32 {
        return if (self.tid == null) 8 else 16;
    }

    /// separator <= (key, tid)?
    fn atOrBelow(self: Sep, key: u64, tid: u64) bool {
        if (self.key != key) return self.key < key;
        return if (self.tid) |t| t <= tid else true;
    }

    fn lessThan(a: Sep, b: Sep) bool {
        if (a.key != b.key) return a.key < b.key;
        // null sorts first; two separators are never equal in a valid tree.
        const at = a.tid orelse return b.tid != null;
        const bt = b.tid orelse return false;
        return at < bt;
    }
};

pub const Leaf = struct {
    cells: std.ArrayList(Cell) = .empty,
    used: u32 = 0,
};

pub const DirEntry = struct {
    /// null only for the first entry: its lower bound is minus infinity.
    low: ?Sep,
    /// Index into `Tree.leaves`. Page numbers are handed out in creation
    /// order, so they say nothing about key order; only the directory does.
    leaf: u32,
};

pub const Stats = struct {
    splits: u64 = 0,
    /// Indexed by @intFromEnum(Strategy).
    by_strategy: [3]u64 = .{ 0, 0, 0 },
    /// Cells copied into a new right page by splits ("churn").
    cells_moved: u64 = 0,
};

/// A snapshot of how full the pages are.
pub const Fill = struct {
    pages: u32 = 0,
    used_bytes: u64 = 0,
    min_used: u32 = 0,
    /// histogram[b] = pages whose fill is in [b*10 %, b*10+10 %); 100% is in
    /// the last bucket.
    histogram: [10]u32 = @splat(0),
    sep_bytes: u64 = 0,
    /// Separators that could not be truncated to the bare key.
    tid_seps: u32 = 0,

    /// Average fill in tenths of a percent (integer, so no float printing).
    pub fn avgPermille(self: Fill, capacity: u32) u64 {
        return self.used_bytes * 1000 / (@as(u64, self.pages) * capacity);
    }
};

pub const RangeSum = struct { cells: u64 = 0, bytes: u64 = 0 };

pub const PutError = Allocator.Error || error{BadCellSize};

pub const Tree = struct {
    /// Long-lived memory: the pages and the directory.
    gpa: Allocator,
    /// Short-lived memory: everything `split.chooseSplit` needs to look at
    /// one overfull page. Emptied after every split, see `splitAndInsert`.
    scratch: std.heap.ArenaAllocator,
    capacity: u32,
    policy: Policy,
    leaves: std.ArrayList(Leaf) = .empty,
    dir: std.ArrayList(DirEntry) = .empty,
    len: usize = 0,
    stats: Stats = .{},

    pub fn init(gpa: Allocator, capacity: u32, policy: Policy) Allocator.Error!Tree {
        var tree: Tree = .{
            .gpa = gpa,
            .scratch = .init(gpa),
            .capacity = capacity,
            .policy = policy,
        };
        errdefer tree.deinit();
        // A tree always has at least one (possibly empty) page.
        try tree.leaves.append(gpa, .{});
        try tree.dir.append(gpa, .{ .low = null, .leaf = 0 });
        return tree;
    }

    pub fn deinit(self: *Tree) void {
        for (self.leaves.items) |*leaf| leaf.cells.deinit(self.gpa);
        self.leaves.deinit(self.gpa);
        self.dir.deinit(self.gpa);
        self.scratch.deinit();
        self.* = undefined;
    }

    /// Largest cell `put` accepts. With cells this small an overfull page can
    /// always be cut into two pages that both fit (total <= 1.25 * capacity).
    pub fn maxCellSize(self: *const Tree) u32 {
        return self.capacity / 4;
    }

    /// Directory position of the page that must contain (key, tid): the last
    /// entry whose separator is <= (key, tid). Binary search over I1.
    fn findDir(self: *const Tree, key: u64, tid: u64) usize {
        var lo: usize = 1; // entry 0 has no separator and always qualifies
        var hi: usize = self.dir.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.dir.items[mid].low.?.atOrBelow(key, tid)) lo = mid + 1 else hi = mid;
        }
        return lo - 1;
    }

    /// First index in `cells` that is not less than (key, tid).
    fn lowerBound(cells: []const Cell, key: u64, tid: u64) usize {
        const probe: Cell = .{ .key = key, .tid = tid, .size = 0 };
        var lo: usize = 0;
        var hi: usize = cells.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (split.cellLess(cells[mid], probe)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Size of the cell (key, tid), or null.
    pub fn get(self: *const Tree, key: u64, tid: u64) ?u16 {
        const leaf = &self.leaves.items[self.dir.items[self.findDir(key, tid)].leaf];
        const i = lowerBound(leaf.cells.items, key, tid);
        if (i == leaf.cells.items.len) return null;
        const c = leaf.cells.items[i];
        return if (c.key == key and c.tid == tid) c.size else null;
    }

    /// Insert a cell of `size` bytes. Returns false (and changes nothing) if
    /// (key, tid) is already present. On error the tree is unchanged.
    pub fn put(self: *Tree, key: u64, tid: u64, size: u16) PutError!bool {
        if (size == 0 or size > self.maxCellSize()) return error.BadCellSize;
        const d = self.findDir(key, tid);
        const leaf = &self.leaves.items[self.dir.items[d].leaf];
        const i = lowerBound(leaf.cells.items, key, tid);
        if (i < leaf.cells.items.len) {
            const c = leaf.cells.items[i];
            if (c.key == key and c.tid == tid) return false;
        }
        const cell: Cell = .{ .key = key, .tid = tid, .size = size };
        if (leaf.used + size <= self.capacity) {
            try leaf.cells.insert(self.gpa, i, cell);
            leaf.used += size;
        } else {
            try self.splitAndInsert(d, i, cell);
        }
        self.len += 1;
        return true;
    }

    /// The page behind directory entry `d` cannot take `cell` at index `i`.
    /// Ask the policy where to cut, then move the right part to a new page.
    fn splitAndInsert(self: *Tree, d: usize, i: usize, cell: Cell) Allocator.Error!void {
        // Everything allocated from `scratch` below dies here, on success and
        // on failure alike. retain_capacity keeps the arena's buffer, so in
        // steady state a split asks the general purpose allocator for
        // nothing but the new right page.
        defer _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();

        const left_id = self.dir.items[d].leaf;
        const old = self.leaves.items[left_id].cells.items;

        // The "imaginary page" of nbtsplitloc.c: the old cells with the new
        // one already in place. It is larger than a page, which is exactly
        // why it lives in scratch memory and not in a page.
        const items = try scratch.alloc(Cell, old.len + 1);
        @memcpy(items[0..i], old[0..i]);
        items[i] = cell;
        @memcpy(items[i + 1 ..], old[i..]);

        const upper_key: ?u64 = if (d + 1 < self.dir.items.len) self.dir.items[d + 1].low.?.key else null;
        const choice = try split.chooseSplit(scratch, items, i, .{
            .capacity = self.capacity,
            .upper_key = upper_key,
        }, self.policy);
        const fr = choice.first_right;

        // Reserve every byte of long-lived memory BEFORE touching the tree,
        // so that an allocation failure leaves it exactly as it was.
        try self.leaves.ensureUnusedCapacity(self.gpa, 1);
        try self.dir.ensureUnusedCapacity(self.gpa, 1);
        var right: Leaf = .{};
        try right.cells.ensureTotalCapacityPrecise(self.gpa, items.len - fr);
        // ---- nothing below can fail ----

        right.cells.appendSliceAssumeCapacity(items[fr..]);
        right.used = choice.right_bytes;

        // The left page keeps its buffer. It never needs to grow: the right
        // page takes at least one cell, so at most old.len cells remain.
        // (`old` aliases this buffer; `items` is a copy, so this is safe.)
        const left = &self.leaves.items[left_id];
        left.cells.clearRetainingCapacity();
        left.cells.appendSliceAssumeCapacity(items[0..fr]);
        left.used = choice.left_bytes;

        // The separator is the lower bound of the right page. Truncate it to
        // the bare key when the last cell on the left has a different key.
        const first_right = items[fr];
        const sep: Sep = .{
            .key = first_right.key,
            .tid = if (choice.penalty == 1) null else first_right.tid,
        };
        const right_id: u32 = @intCast(self.leaves.items.len);
        self.leaves.appendAssumeCapacity(right);
        self.dir.insertAssumeCapacity(d + 1, .{ .low = sep, .leaf = right_id });

        self.stats.splits += 1;
        self.stats.by_strategy[@backingInt(choice.strategy)] += 1;
        self.stats.cells_moved += items.len - fr;
    }

    /// Remove (key, tid). Pages are never merged or freed here, not even
    /// empty ones: what to do with underfull pages is chapter 15.
    pub fn delete(self: *Tree, key: u64, tid: u64) bool {
        const leaf = &self.leaves.items[self.dir.items[self.findDir(key, tid)].leaf];
        const i = lowerBound(leaf.cells.items, key, tid);
        if (i == leaf.cells.items.len) return false;
        const c = leaf.cells.items[i];
        if (c.key != key or c.tid != tid) return false;
        _ = leaf.cells.orderedRemove(i);
        leaf.used -= c.size;
        self.len -= 1;
        return true;
    }

    /// Count and total size of all cells with lo <= key < hi.
    pub fn range(self: *const Tree, lo: u64, hi: u64) RangeSum {
        var sum: RangeSum = .{};
        if (lo >= hi) return sum;
        var d = self.findDir(lo, 0);
        while (d < self.dir.items.len) : (d += 1) {
            const cells = self.leaves.items[self.dir.items[d].leaf].cells.items;
            for (cells[lowerBound(cells, lo, 0)..]) |c| {
                if (c.key >= hi) return sum;
                sum.cells += 1;
                sum.bytes += c.size;
            }
        }
        return sum;
    }

    pub fn fill(self: *const Tree) Fill {
        var f: Fill = .{ .min_used = self.capacity };
        for (self.dir.items) |entry| {
            const used = self.leaves.items[entry.leaf].used;
            f.pages += 1;
            f.used_bytes += used;
            f.min_used = @min(f.min_used, used);
            f.histogram[@min(9, used * 10 / self.capacity)] += 1;
            if (entry.low) |sep| {
                f.sep_bytes += sep.bytes();
                if (sep.tid != null) f.tid_seps += 1;
            }
        }
        return f;
    }

    /// Check invariants I1 to I5 (see the top of this file).
    pub fn validate(self: *const Tree) error{Invalid}!void {
        if (self.dir.items.len == 0 or self.dir.items.len != self.leaves.items.len) return error.Invalid;
        if (self.dir.items[0].low != null) return error.Invalid;
        var count: usize = 0;
        for (self.dir.items, 0..) |entry, d| {
            if (entry.leaf >= self.leaves.items.len) return error.Invalid;
            const leaf = &self.leaves.items[entry.leaf];
            const upper: ?Sep = if (d + 1 < self.dir.items.len) self.dir.items[d + 1].low else null;
            if (d > 0) {
                const low = entry.low orelse return error.Invalid;
                if (upper) |up| if (!low.lessThan(up)) return error.Invalid; // I1
            }
            var used: u32 = 0;
            for (leaf.cells.items, 0..) |c, i| {
                if (i > 0 and !split.cellLess(leaf.cells.items[i - 1], c)) return error.Invalid; // I3
                if (entry.low) |low| if (!low.atOrBelow(c.key, c.tid)) return error.Invalid; // I2
                if (upper) |up| if (up.atOrBelow(c.key, c.tid)) return error.Invalid; // I2
                used += c.size;
            }
            if (used != leaf.used or used > self.capacity) return error.Invalid; // I4
            count += leaf.cells.items.len;
        }
        if (count != self.len) return error.Invalid; // I5
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const SplitMix64 = @import("prng.zig").SplitMix64;

pub const all_policies = [_]Policy{ .half, .{ .fill = 90 }, .{ .rightmost = 90 }, .{ .adaptive = 90 } };

test "put, get, delete and range on one page" {
    var tree: Tree = try .init(testing.allocator, 100, .half);
    defer tree.deinit();
    try testing.expect(try tree.put(5, 1, 10));
    try testing.expect(try tree.put(5, 2, 20));
    try testing.expect(try tree.put(3, 9, 25));
    try testing.expect(!try tree.put(5, 2, 25)); // already there, unchanged
    try testing.expectEqual(20, tree.get(5, 2));
    try testing.expectEqual(null, tree.get(5, 3));
    try testing.expectEqual(RangeSum{ .cells = 2, .bytes = 30 }, tree.range(5, 6));
    try testing.expectEqual(RangeSum{ .cells = 3, .bytes = 55 }, tree.range(0, 100));
    try testing.expect(tree.delete(5, 1));
    try testing.expect(!tree.delete(5, 1));
    try testing.expectEqual(2, tree.len);
    try testing.expectError(error.BadCellSize, tree.put(1, 1, 26));
    try testing.expectError(error.BadCellSize, tree.put(1, 1, 0));
    try tree.validate();
}

test "the hand example splits where each policy says" {
    // (policy, bytes left, bytes right, separator carries a tid?)
    const Case = struct { policy: Policy, left: u32, right: u32, tid_sep: bool };
    const cases = [_]Case{
        .{ .policy = .half, .left = 46, .right = 60, .tid_sep = true },
        .{ .policy = .{ .fill = 90 }, .left = 86, .right = 20, .tid_sep = false },
        .{ .policy = .{ .rightmost = 90 }, .left = 86, .right = 20, .tid_sep = false },
        .{ .policy = .{ .adaptive = 90 }, .left = 86, .right = 20, .tid_sep = false },
    };
    for (cases) |case| {
        var tree: Tree = try .init(testing.allocator, split.hand_capacity, case.policy);
        defer tree.deinit();
        for (split.hand_items, 0..) |c, i| {
            if (i != split.hand_new_index) _ = try tree.put(c.key, c.tid, c.size);
        }
        const new = split.hand_items[split.hand_new_index];
        _ = try tree.put(new.key, new.tid, new.size);
        try tree.validate();
        try testing.expectEqual(2, tree.dir.items.len);
        try testing.expectEqual(case.left, tree.leaves.items[0].used);
        try testing.expectEqual(case.right, tree.leaves.items[1].used);
        try testing.expectEqual(case.tid_sep, tree.dir.items[1].low.?.tid != null);
    }
}

test "ascending inserts: half leaves pages half empty, rightmost does not" {
    var half: Tree = try .init(testing.allocator, 4096, .half);
    defer half.deinit();
    var right: Tree = try .init(testing.allocator, 4096, .{ .rightmost = 90 });
    defer right.deinit();
    for (0..2000) |i| {
        _ = try half.put(i, i, 64);
        _ = try right.put(i, i, 64);
    }
    try half.validate();
    try right.validate();
    // 4096 / 64 = 64 cells per page. Of the 65 cells of an overfull page,
    // 50:50 keeps 32 on the left and the 90% target keeps 58, so a new page
    // is needed every 32 or every 58 inserts.
    try testing.expectEqual(62, half.fill().pages);
    try testing.expectEqual(35, right.fill().pages);
    try testing.expect(half.fill().avgPermille(4096) < 550);
    try testing.expect(right.fill().avgPermille(4096) > 850);
}

// Seeded model test: random puts, deletes, gets and ranges against a hash
// map oracle, under every policy, on small pages so that splits are common.
test "model test against an oracle, all policies" {
    const gpa = testing.allocator;
    const Id = struct { key: u64, tid: u64 };
    for (all_policies, 0..) |policy, p| {
        var tree: Tree = try .init(gpa, 256, policy);
        defer tree.deinit();
        var oracle: std.AutoHashMap(Id, u16) = .init(gpa);
        defer oracle.deinit();
        var rng = SplitMix64.init(1400 + p);

        for (0..6000) |step| {
            const key = rng.below(40);
            const tid = rng.below(60);
            const id: Id = .{ .key = key, .tid = tid };
            switch (rng.below(10)) {
                0...5 => {
                    const size: u16 = @intCast(rng.range(1, 65));
                    const added = try tree.put(key, tid, size);
                    try testing.expectEqual(!oracle.contains(id), added);
                    if (added) try oracle.put(id, size);
                },
                6, 7 => try testing.expectEqual(oracle.remove(id), tree.delete(key, tid)),
                8 => try testing.expectEqual(oracle.get(id), tree.get(key, tid)),
                else => {
                    const hi = key + 1 + rng.below(5);
                    var want: RangeSum = .{};
                    var it = oracle.iterator();
                    while (it.next()) |e| {
                        if (e.key_ptr.key >= key and e.key_ptr.key < hi) {
                            want.cells += 1;
                            want.bytes += e.value_ptr.*;
                        }
                    }
                    try testing.expectEqual(want, tree.range(key, hi));
                },
            }
            if (step % 500 == 0) try tree.validate();
        }
        try tree.validate();
        try testing.expectEqual(oracle.count(), tree.len);
        try testing.expect(tree.stats.splits > 10);
    }
}

fn buildUnderFailure(gpa: Allocator, policy: Policy) !void {
    var tree: Tree = try .init(gpa, 128, policy);
    defer tree.deinit();
    var rng = SplitMix64.init(7);
    for (0..40) |i| _ = try tree.put(rng.below(6), i, @intCast(rng.range(8, 33)));
    try tree.validate();
}

test "every allocation failure while building is reported and leaks nothing" {
    for (all_policies) |policy| {
        try testing.checkAllAllocationFailures(testing.allocator, buildUnderFailure, .{policy});
    }
}

test "a put that fails leaves the tree unchanged" {
    // Fail the 1st, 2nd, ... allocation of the one put that splits; whatever
    // fails (scratch, directory, page list, right page), the tree must still
    // be valid, must not contain the cell, and must accept it afterwards.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        var tree: Tree = try .init(failing.allocator(), 100, .{ .adaptive = 90 });
        defer tree.deinit();
        for (split.hand_items, 0..) |c, i| {
            if (i != split.hand_new_index) _ = try tree.put(c.key, c.tid, c.size);
        }
        const new = split.hand_items[split.hand_new_index];

        failing.fail_index = failing.alloc_index + fail_index;
        const result = tree.put(new.key, new.tid, new.size);
        failing.fail_index = std.math.maxInt(usize);

        try tree.validate();
        if (result) |added| {
            // No allocation was left to fail: the split went through.
            try testing.expect(added);
            try testing.expect(fail_index > 0);
            try testing.expectEqual(2, tree.dir.items.len);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(6, tree.len);
            try testing.expectEqual(1, tree.dir.items.len);
            try testing.expectEqual(null, tree.get(new.key, new.tid));
            try testing.expect(try tree.put(new.key, new.tid, new.size));
            try tree.validate();
        }
    }
}
