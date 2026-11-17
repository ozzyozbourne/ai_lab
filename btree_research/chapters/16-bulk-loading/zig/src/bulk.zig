//! Bottom-up bulk loader: build a B+tree from sorted input without a single
//! split, writing every page exactly once.
//!
//! The picture to keep in mind is one "open page" per tree level:
//!
//!     level 2:                 [ . . . . ]            <- gets a pair when a
//!     level 1:        [ p p p . ]                        level-1 page is sealed
//!     level 0:  ##### ##### [ k k . ]  <- sorted input arrives here
//!
//! A pair is (key, pointer). On level 0 it is (key, value). On every higher
//! level it is (low key of a finished page, id of that page). So "a page was
//! finished" on level L is simply "a pair was added" on level L + 1, and the
//! same code runs on every level.
//!
//! Compared with PostgreSQL's nbtsort.c, which this follows, there is one
//! addition. Postgres writes a page the moment it is full and accepts that
//! the last page of each level may be nearly empty. Our tree promises the
//! textbook minimum occupancy, so each level keeps its most recently filled
//! page *pending*: it has a page id and is complete, but it is not written
//! until we know that the page after it is big enough. At the end of the
//! input the last two pages of a level can still be evened out (or merged)
//! for free, because neither has been written yet.
//!
//! Memory. The loader owns one buffer per level, taken from that level's own
//! `ArenaAllocator` and recycled with `reset(.retain_capacity)` every time a
//! page leaves the buffer. Its working memory is therefore O(height) pages no
//! matter how many keys are loaded.
const std = @import("std");
const Allocator = std.mem.Allocator;
const bptree = @import("bptree.zig");
const Tree = bptree.Tree;
const Entry = bptree.Entry;
const nil = bptree.nil;

pub const Options = struct {
    /// Target fullness of leaves, in percent of their capacity.
    leaf_fill: u8 = 100,
    /// Target fullness of interior nodes, in percent of their capacity.
    inner_fill: u8 = 100,
};

pub const Error = Allocator.Error || error{NotSorted};

const Pair = struct { key: u64, slot: u64 };

/// How many pairs a page gets before the next page is started:
/// floor(cap * percent / 100), but never below the minimum occupancy (so a
/// fill factor under 50% behaves like 50%) and never above the capacity.
pub fn fillTarget(cap: usize, min: usize, percent: u8) usize {
    return std.math.clamp(cap * percent / 100, min, cap);
}

const Level = struct {
    /// Owns `buf`. Reset after every page, so its capacity is one buffer.
    arena: std.heap.ArenaAllocator,
    /// The open page: pairs collected so far. Capacity = this level's target.
    buf: []Pair = &.{},
    len: usize = 0,
    /// Id of the page filled just before the open one. It sits in the tree's
    /// node array but has not been counted as written yet. `nil` if none.
    pending: u32 = nil,
    /// Pages of this level already written and announced to the parent level.
    sealed: usize = 0,
};

pub const BulkLoader = struct {
    gpa: Allocator,
    tree: *Tree,
    leaf_target: usize,
    inner_target: usize,
    /// Fixed array, not an ArrayList: a Level contains an arena, and arenas
    /// should not be moved around while in use.
    levels: [bptree.max_height]Level = undefined,
    n_levels: usize = 0,
    last_key: ?u64 = null,

    /// `tree` must be empty. The loader borrows it until `finish`.
    pub fn init(gpa: Allocator, tree: *Tree, options: Options) BulkLoader {
        std.debug.assert(tree.root == nil and tree.count == 0);
        return .{
            .gpa = gpa,
            .tree = tree,
            .leaf_target = fillTarget(tree.leafCap(), tree.leafMin(), options.leaf_fill),
            .inner_target = fillTarget(tree.innerCap(), tree.innerMin(), options.inner_fill),
        };
    }

    /// Frees the loader's buffers. The tree is not touched.
    pub fn deinit(self: *BulkLoader) void {
        for (self.levels[0..self.n_levels]) |*level| level.arena.deinit();
        self.* = undefined;
    }

    /// Feed the next entry. Keys must arrive in strictly ascending order.
    pub fn add(self: *BulkLoader, key: u64, value: u64) Error!void {
        if (self.last_key) |last| if (key <= last) return error.NotSorted;
        self.last_key = key;
        try self.addPair(0, .{ .key = key, .slot = value });
        self.tree.count += 1;
    }

    fn target(self: *const BulkLoader, level: usize) usize {
        return if (level == 0) self.leaf_target else self.inner_target;
    }

    /// Add one pair to the open page of `level`, starting the level or a new
    /// page as needed. This is the whole algorithm; everything else is
    /// bookkeeping for the two ends of the input.
    fn addPair(self: *BulkLoader, level: usize, pair: Pair) Allocator.Error!void {
        if (level == self.n_levels) {
            // First pair on this level: the tree just grew by one level.
            self.levels[level] = .{ .arena = .init(self.gpa) };
            self.n_levels += 1;
            const lv = &self.levels[level];
            lv.buf = try lv.arena.allocator().alloc(Pair, self.target(level));
        }
        if (self.levels[level].len == self.target(level)) {
            // The open page reached its fill target and another pair is
            // coming, so this page will certainly exist. Give it an id.
            try self.closeOpenPage(level);
        }
        const lv = &self.levels[level];
        lv.buf[lv.len] = pair;
        lv.len += 1;
    }

    /// Move the open page into the tree's node array (it becomes the pending
    /// page) and write out the page that was pending before it.
    fn closeOpenPage(self: *BulkLoader, level: usize) Allocator.Error!void {
        const id = try self.copyOut(level);
        const old = self.levels[level].pending;
        self.levels[level].pending = id;
        if (old != nil) {
            // Now the older page's right neighbour has an id, so its sibling
            // link can be filled in and the page is final.
            if (level == 0) self.tree.nodes.items[old].next = id;
            try self.seal(level, old);
        }
        // The buffer's contents now live in the node. Recycle the buffer:
        // reset keeps the memory, so this alloc reuses the same bytes.
        const lv = &self.levels[level];
        _ = lv.arena.reset(.retain_capacity);
        lv.buf = try lv.arena.allocator().alloc(Pair, self.target(level));
        lv.len = 0;
    }

    /// Allocate a node and copy the open page's pairs into it.
    fn copyOut(self: *BulkLoader, level: usize) Allocator.Error!u32 {
        const id = try self.tree.allocNode(level == 0);
        const node = &self.tree.nodes.items[id];
        const lv = &self.levels[level];
        for (lv.buf[0..lv.len], 0..) |pair, i| {
            node.keys[i] = pair.key;
            node.slots[i] = pair.slot;
        }
        node.len = @intCast(lv.len);
        return id;
    }

    /// The page is final: count the write and tell the parent level about it.
    /// The pair sent up is (the page's low key, the page's id). For a leaf
    /// the low key is its first key; for an interior page it is the low key
    /// of its first child, which is sitting in the ignored slot 0.
    fn seal(self: *BulkLoader, level: usize, id: u32) Allocator.Error!void {
        self.tree.stats.page_writes += 1;
        self.levels[level].sealed += 1;
        const low_key = self.tree.nodes.items[id].keys[0];
        try self.addPair(level + 1, .{ .key = low_key, .slot = id });
    }

    /// End of input: close the right edge of the tree, bottom to top.
    pub fn finish(self: *BulkLoader) Allocator.Error!void {
        const tree = self.tree;
        var level: usize = 0;
        while (level < self.n_levels) : (level += 1) {
            const lv = &self.levels[level];
            const is_leaf = level == 0;
            const min = tree.min(is_leaf);

            // Fix the tail. Only the open page can be under the minimum (the
            // pending page reached the target, and target >= min).
            if (lv.pending != nil and lv.len < min) {
                const left = &tree.nodes.items[lv.pending];
                const total = left.len + lv.len;
                if (total <= tree.cap(is_leaf)) {
                    // Too few pairs for two legal pages: put them all in the
                    // pending page. The open page never becomes a node.
                    for (lv.buf[0..lv.len], left.len..) |pair, i| {
                        left.keys[i] = pair.key;
                        left.slots[i] = pair.slot;
                    }
                    left.len = @intCast(total);
                    lv.len = 0;
                } else {
                    // Share evenly: move the pending page's last `move` pairs
                    // to the front of the open page.
                    const keep = total - total / 2;
                    const move = left.len - keep;
                    std.mem.copyBackwards(Pair, lv.buf[move .. move + lv.len], lv.buf[0..lv.len]);
                    for (0..move) |i| lv.buf[i] = .{ .key = left.keys[keep + i], .slot = left.slots[keep + i] };
                    lv.len += move;
                    left.len = @intCast(keep);
                }
            }

            const pages_left = @intFromBool(lv.pending != nil) + @as(usize, @intFromBool(lv.len > 0));
            if (lv.sealed == 0 and pages_left == 1) {
                // The only page on its level is the root. It is written but
                // has no parent to announce itself to.
                const id = if (lv.pending != nil) lv.pending else try self.copyOut(level);
                tree.stats.page_writes += 1;
                tree.root = id;
                tree.height = level + 1;
                return;
            }

            // Otherwise write what is left. Each seal adds a pair one level
            // up, which may create that level; the loop then finishes it too.
            const pending = lv.pending;
            if (lv.len > 0) {
                const id = try self.copyOut(level);
                self.levels[level].len = 0;
                if (pending != nil) {
                    if (is_leaf) tree.nodes.items[pending].next = id;
                    try self.seal(level, pending);
                }
                try self.seal(level, id);
            } else {
                try self.seal(level, pending);
            }
            self.levels[level].pending = nil;
        }
    }

};

/// Convenience wrapper: build a tree of the given order from a sorted slice.
pub fn bulkLoad(gpa: Allocator, order: usize, entries: []const Entry, options: Options) Error!Tree {
    var tree = Tree.init(gpa, order);
    errdefer tree.deinit();
    var loader = BulkLoader.init(gpa, &tree, options);
    defer loader.deinit();
    for (entries) |e| try loader.add(e.key, e.value);
    try loader.finish();
    return tree;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const ops = @import("ops.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;

fn ascending(gpa: Allocator, n: usize, step: u64) ![]Entry {
    const entries = try gpa.alloc(Entry, n);
    for (entries, 0..) |*e, i| e.* = .{ .key = (i + 1) * step, .value = (i + 1) * step * 10 };
    return entries;
}

test "fill target" {
    try testing.expectEqual(3, fillTarget(3, 1, 100));
    try testing.expectEqual(2, fillTarget(3, 1, 70));
    try testing.expectEqual(1, fillTarget(3, 1, 10)); // clamped to the minimum
    try testing.expectEqual(13, fillTarget(15, 7, 90));
    try testing.expectEqual(10, fillTarget(15, 7, 70));
    try testing.expectEqual(7, fillTarget(15, 7, 20));
    try testing.expectEqual(11, fillTarget(16, 8, 70));
}

test "hand example: 13 keys, order 4, full pages" {
    const gpa = testing.allocator;
    const entries = try ascending(gpa, 13, 1);
    defer gpa.free(entries);
    var tree = try bulkLoad(gpa, 4, entries, .{});
    defer tree.deinit();
    try tree.validate();
    const s = tree.shape();
    try testing.expectEqual(3, s.height);
    try testing.expectEqual(5, s.leaves);
    try testing.expectEqual(3, s.inner);
    // Every page written exactly once, no reads, no splits.
    try testing.expectEqual(8, tree.stats.page_writes);
    try testing.expectEqual(0, tree.stats.page_reads);
    try testing.expectEqual(0, tree.stats.splits);
    // The fifth leaf alone would make an interior node with one child, so the
    // loader shared the five leaves 3 + 2.
    const root = &tree.nodes.items[tree.root];
    try testing.expectEqual(2, root.len);
    try testing.expectEqual(10, root.keys[1]);
    try testing.expectEqual(3, tree.nodes.items[@intCast(root.slots[0])].len);
    try testing.expectEqual(2, tree.nodes.items[@intCast(root.slots[1])].len);
}

test "every size from 0 to 400, several orders and fill factors" {
    const gpa = testing.allocator;
    const all = try ascending(gpa, 400, 2);
    defer gpa.free(all);
    for ([_]usize{ 3, 4, 5, 6, 7, 16 }) |order| {
        for ([_]u8{ 100, 90, 70, 50, 1 }) |fill| {
            for (0..all.len + 1) |n| {
                var tree = try bulkLoad(gpa, order, all[0..n], .{ .leaf_fill = fill, .inner_fill = fill });
                defer tree.deinit();
                try tree.validate();
                try testing.expectEqual(n, tree.count);
                // Written once each: writes == pages, and no slot is wasted.
                const s = tree.shape();
                try testing.expectEqual(s.pages(), tree.stats.page_writes);
                try testing.expectEqual(s.pages(), tree.nodes.items.len);
                var it = tree.range(0, std.math.maxInt(u64));
                for (all[0..n]) |e| try testing.expectEqual(e, it.next().?);
                try testing.expectEqual(null, it.next());
                if (n > 0) try testing.expectEqual(null, tree.get(all[n - 1].key + 1));
            }
        }
    }
}

test "full pages give the minimum number of leaves" {
    const gpa = testing.allocator;
    const entries = try ascending(gpa, 1000, 1);
    defer gpa.free(entries);
    var tree = try bulkLoad(gpa, 16, entries, .{});
    defer tree.deinit();
    try testing.expectEqual(67, tree.shape().leaves); // ceil(1000 / 15)
}

test "unsorted or duplicate input is rejected" {
    const gpa = testing.allocator;
    var tree = Tree.init(gpa, 4);
    defer tree.deinit();
    var loader = BulkLoader.init(gpa, &tree, .{});
    defer loader.deinit();
    try loader.add(5, 0);
    try testing.expectError(error.NotSorted, loader.add(5, 0));
    try testing.expectError(error.NotSorted, loader.add(4, 0));
    try loader.add(6, 0);
    try loader.finish();
    try tree.validate();
    try testing.expectEqual(2, tree.count);
}

test "loader memory does not grow with the input" {
    const gpa = testing.allocator;
    for ([_]usize{ 2_000, 200_000 }) |n| {
        var tree = Tree.init(gpa, 4);
        defer tree.deinit();
        var loader = BulkLoader.init(gpa, &tree, .{});
        defer loader.deinit();
        for (0..n) |k| try loader.add(k, k);
        try loader.finish();
        // One arena per level, and every arena still holds one small buffer
        // (less than a single node) whether 600 or 60000 pages went through.
        try testing.expectEqual(tree.height, loader.n_levels);
        for (loader.levels[0..loader.n_levels]) |*level| {
            try testing.expect(level.arena.queryCapacity() < @sizeOf(bptree.Node));
        }
    }
}

test "bulk load under allocation failure does not leak" {
    const gpa = testing.allocator;
    const entries = try ascending(gpa, 60, 1);
    defer gpa.free(entries);
    const S = struct {
        fn run(failing: Allocator, input: []const Entry) !void {
            var tree = try bulkLoad(failing, 4, input, .{ .leaf_fill = 70, .inner_fill = 70 });
            defer tree.deinit();
            try tree.validate();
        }
    };
    try testing.checkAllAllocationFailures(gpa, S.run, .{entries});
}

test "model test: bulk load, then keep inserting, against the oracle" {
    const gpa = testing.allocator;
    var rng = SplitMix64.init(1616);
    for (0..40) |round| {
        const order: usize = @intCast(rng.range(3, 10));
        const fill: u8 = @intCast(rng.range(1, 101));
        const n: usize = @intCast(rng.below(300));
        var oracle: ops.Oracle = .{};
        defer oracle.deinit(gpa);
        // Random distinct keys: put them through the oracle, which sorts.
        for (0..n) |_| _ = try oracle.put(gpa, rng.below(1000), rng.nextU64());
        const sorted = oracle.range(0, 1000);

        var tree = Tree.init(gpa, order);
        defer tree.deinit();
        {
            var loader = BulkLoader.init(gpa, &tree, .{ .leaf_fill = fill, .inner_fill = fill });
            defer loader.deinit();
            for (sorted) |e| try loader.add(e.key, e.value);
            try loader.finish();
        }
        try tree.validate();
        try bptree.expectSameEntries(sorted, &tree, 0, 1000);

        // A bulk-loaded tree is an ordinary tree: the insert path works on it.
        var stream = ops.OpStream.init(.{
            .seed = round,
            .count = 500,
            .key_space = 1000,
            .weights = .{ .put = 5, .delete = 0, .get = 3, .range = 2 },
        });
        while (stream.next()) |op| switch (op) {
            .put => |p| {
                try tree.put(p.key, p.value);
                _ = try oracle.put(gpa, p.key, p.value);
            },
            .delete => unreachable,
            .get => |g| try testing.expectEqual(oracle.get(g.key), tree.get(g.key)),
            .range => |r| try bptree.expectSameEntries(oracle.range(r.lo, r.hi), &tree, r.lo, r.hi),
        };
        try tree.validate();
        try testing.expectEqual(oracle.len(), tree.count);
    }
}
