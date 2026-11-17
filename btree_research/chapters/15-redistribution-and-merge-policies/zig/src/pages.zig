//! Chapter 15: redistribution and merge policies on an in-memory page model.
//!
//! The model is deliberately small: one parent page and a row of leaf pages.
//!
//!   parent:  (p0, 40) (p2, 75) right=p1      divider cells + right-most pointer
//!   leaves:  p0: keys <= 40    p2: 40 < keys <= 75    p1: keys > 75
//!
//! A leaf holds cells `{key, size}`. Only the byte size matters here, so there
//! is no payload. A page is full when the sizes add up to `capacity` (4096 by
//! default). The parent is not size-limited: how a parent overflows is the
//! same story one level up, and is not what this chapter is about.
//!
//! The parent has the shape of a SQLite/Turso table interior page: each
//! divider cell is `(left child, largest key that may live in that child)`,
//! and the last child hangs off a separate right-most pointer. Dividers are
//! routing information only; they are never part of the cells that get
//! redistributed (turso/core/storage/btree.rs:4622-4630 builds them the same
//! way: left page id + rowid of the last cell on the left page).
//!
//! The central routine is `balance`: flatten up to three adjacent siblings
//! into one array, cut the array into pages again (`packLeft` + `evenOut`),
//! write the pages back and replace the dividers. Split, redistribution and
//! merge are that one routine with a different number of output pages.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// One record on a leaf. `size` is its whole footprint on the page in bytes
/// (payload plus slot pointer), which is all a balancing decision looks at.
pub const Cell = struct { key: u64, size: u32 };

/// One cell of the parent: "keys <= `key` live under page `child`".
pub const Divider = struct { child: u32, key: u64 };

/// Balancing 3 siblings never needs more than 5 output pages (the same bound
/// as MAX_NEW_SIBLING_PAGES_AFTER_BALANCE, turso/core/storage/btree.rs:163).
/// Here it follows from `put` refusing cells larger than a third of a page:
/// every page that `packLeft` closes is then more than 2/3 full, and three
/// pages plus one cell cannot fill five of those.
pub const max_out_pages = 5;

/// What `delete` does when a page gets emptier.
pub const MergePolicy = enum {
    /// Do nothing, ever. Empty pages stay in the tree.
    never,
    /// Unlink a page only when its last cell is gone (the Postgres rule,
    /// minus VACUUM and the two-phase protocol of chapter 24).
    at_empty,
    /// Rebalance with the siblings when more than 2/3 of the page is free
    /// (the SQLite/Turso trigger, turso/core/storage/btree.rs:3427-3430).
    below_third,
    /// Rebalance as soon as less than half the page is used (textbook).
    below_half,
};

pub const Config = struct {
    capacity: u32 = 4096,
    /// How many adjacent siblings an overflowing page is balanced with.
    /// 1 = plain split of the page alone, 2 = the classic B* pairing, 3 = Turso.
    insert_siblings: u8 = 3,
    /// Append fast path (`balance_quick`): a cell that overflows the end of
    /// the right-most leaf starts a new leaf of its own.
    quick_append: bool = true,
    merge: MergePolicy = .below_third,
};

/// Counters for the "churn" comparison. Only structural work is counted; the
/// one leaf write that every put or delete needs anyway is not.
pub const Stats = struct {
    balances: u64 = 0,
    quick_appends: u64 = 0,
    pages_allocated: u64 = 0,
    pages_freed: u64 = 0,
    /// Leaf pages whose set of cells was changed by a structural operation.
    leaf_writes: u64 = 0,
    /// Structural operations that had to rewrite divider cells.
    parent_writes: u64 = 0,
    /// Cells that ended up on a different page than they were on.
    cells_moved: u64 = 0,
    /// ... of which onto a page that already existed before the operation.
    /// This is the number Postgres insists on keeping at zero (see README).
    cells_moved_to_old: u64 = 0,
};

pub const Page = struct {
    cells: std.ArrayList(Cell) = .empty,
    /// Sum of the cell sizes. May exceed `capacity` only between the insert
    /// and the balance inside one `put` ("overfull is represented, not
    /// prevented", like Turso's overflow cells).
    used: u32 = 0,
    live: bool = false,
};

fn sum(sizes: []const u32) u32 {
    var total: u32 = 0;
    for (sizes) |s| total += s;
    return total;
}

/// Step 1 of redistribution: cut the flattened cells into as few pages as
/// possible by filling each page from the left.
///
/// Returns `ends`: `ends[p]` is the index one past the last cell of output
/// page p (prefix sums, like `cell_count_per_page_cumulative` in Turso,
/// btree.rs:4200-4284). Always at least one page; only that single page can
/// be empty. The slice lives in `scratch`.
pub fn packLeft(scratch: Allocator, sizes: []const u32, capacity: u32) Allocator.Error![]u32 {
    var ends: std.ArrayList(u32) = .empty;
    var used: u32 = 0;
    for (sizes, 0..) |size, i| {
        std.debug.assert(size <= capacity);
        if (used + size > capacity) {
            try ends.append(scratch, @intCast(i)); // close the page before cell i
            used = 0;
        }
        used += size;
    }
    try ends.append(scratch, @intCast(sizes.len));
    return ends.items;
}

/// Step 2: packing left leaves the last page with whatever was left over,
/// possibly a single cell. Walk the page boundaries from right to left and
/// move cells from the left page to the right page for as long as that does
/// not make the right page the bigger one (btree.rs:4384-4390).
///
/// Only the boundaries move; no page ever gains more than its left neighbour
/// had, so nothing can overflow.
pub fn evenOut(sizes: []const u32, ends: []u32) void {
    var k = ends.len;
    while (k > 1) {
        k -= 1; // boundary between page k-1 (left) and page k (right)
        const left_start: u32 = if (k >= 2) ends[k - 2] else 0;
        var left_used = sum(sizes[left_start..ends[k - 1]]);
        var right_used = sum(sizes[ends[k - 1]..ends[k]]);
        // The left page always keeps at least one cell.
        while (ends[k - 1] > left_start + 1) {
            const c = sizes[ends[k - 1] - 1]; // last cell of the left page
            if (right_used != 0 and right_used + c > left_used - c) break;
            ends[k - 1] -= 1;
            left_used -= c;
            right_used += c;
        }
    }
}

fn cellKeyOrder(key: u64, cell: Cell) std.math.Order {
    return std.math.order(key, cell.key);
}

fn dividerKeyOrder(key: u64, divider: Divider) std.math.Order {
    return std.math.order(key, divider.key);
}

pub const Tree = struct {
    /// Long-lived memory: the page table, each page's cell array, the parent.
    gpa: Allocator,
    /// Scratch memory for one `balance` call: the flattened cell array and
    /// the boundaries. Reset (keeping its buffer) when the call returns.
    scratch: std.heap.ArenaAllocator,
    cfg: Config,
    /// Page table indexed by page id; freed pages stay as dead slots.
    pages: std.ArrayList(Page) = .empty,
    /// Free list of page ids. Its capacity always covers `pages.items.len`,
    /// so freeing a page can never fail.
    free_ids: std.ArrayList(u32) = .empty,
    /// The parent page: divider cells in key order, plus the right-most child.
    dividers: std.ArrayList(Divider) = .empty,
    rightmost: u32 = 0,
    count: usize = 0,
    stats: Stats = .{},

    pub const PutError = Allocator.Error || error{CellTooLarge};

    pub fn init(gpa: Allocator, cfg: Config) Allocator.Error!Tree {
        std.debug.assert(cfg.capacity >= 4 and cfg.insert_siblings >= 1 and cfg.insert_siblings <= 3);
        var tree: Tree = .{ .gpa = gpa, .scratch = .init(gpa), .cfg = cfg };
        errdefer tree.deinit();
        tree.rightmost = try tree.allocPage(); // an empty tree is one empty leaf
        tree.stats = .{};
        return tree;
    }

    pub fn deinit(self: *Tree) void {
        for (self.pages.items) |*page| page.cells.deinit(self.gpa);
        self.pages.deinit(self.gpa);
        self.free_ids.deinit(self.gpa);
        self.dividers.deinit(self.gpa);
        self.scratch.deinit();
        self.* = undefined;
    }

    // ---- page table -----------------------------------------------------

    fn allocPage(self: *Tree) Allocator.Error!u32 {
        self.stats.pages_allocated += 1;
        if (self.free_ids.pop()) |id| {
            self.pages.items[id].live = true;
            return id;
        }
        // Reserve the free-list slot first: `freePage` must not allocate.
        try self.free_ids.ensureTotalCapacity(self.gpa, self.pages.items.len + 1);
        try self.pages.append(self.gpa, .{ .live = true });
        return @intCast(self.pages.items.len - 1);
    }

    fn freePage(self: *Tree, id: u32) void {
        const page = &self.pages.items[id];
        page.cells.clearRetainingCapacity(); // keep the buffer, like a real page frame
        page.used = 0;
        page.live = false;
        self.free_ids.appendAssumeCapacity(id);
        self.stats.pages_freed += 1;
    }

    // ---- parent ---------------------------------------------------------

    pub fn childCount(self: *const Tree) usize {
        return self.dividers.items.len + 1;
    }

    /// Page id of the i-th child, left to right.
    pub fn childAt(self: *const Tree, i: usize) u32 {
        return if (i < self.dividers.items.len) self.dividers.items[i].child else self.rightmost;
    }

    /// Index of the child whose key range contains `key`: the first divider
    /// with divider.key >= key, else the right-most child.
    fn findChild(self: *const Tree, key: u64) usize {
        return std.sort.lowerBound(Divider, self.dividers.items, key, dividerKeyOrder);
    }

    pub fn usedBytes(self: *const Tree) u64 {
        var total: u64 = 0;
        for (0..self.childCount()) |i| total += self.pages.items[self.childAt(i)].used;
        return total;
    }

    /// Average fill of the leaves in tenths of a percent (integers only, so
    /// Zig and Rust print the same digits).
    pub fn fillPermille(self: *const Tree) u64 {
        return self.usedBytes() * 1000 / (@as(u64, self.childCount()) * self.cfg.capacity);
    }

    // ---- operations -----------------------------------------------------

    /// Size of the cell stored under `key`.
    pub fn get(self: *const Tree, key: u64) ?u32 {
        const cells = self.pages.items[self.childAt(self.findChild(key))].cells.items;
        const pos = std.sort.lowerBound(Cell, cells, key, cellKeyOrder);
        return if (pos < cells.len and cells[pos].key == key) cells[pos].size else null;
    }

    /// Insert a cell, or replace the size of an existing one. On any error
    /// the tree is exactly as it was before the call.
    pub fn put(self: *Tree, key: u64, size: u32) PutError!void {
        // A third of a page at most, so that every page can hold several
        // cells and three siblings plus one cell fit in five pages.
        if (size == 0 or size > self.cfg.capacity / 3) return error.CellTooLarge;
        const ci = self.findChild(key);
        const page = &self.pages.items[self.childAt(ci)];
        const pos = std.sort.lowerBound(Cell, page.cells.items, key, cellKeyOrder);
        const existing = pos < page.cells.items.len and page.cells.items[pos].key == key;
        const old_size: u32 = if (existing) page.cells.items[pos].size else 0;
        if (existing) {
            page.cells.items[pos].size = size;
        } else {
            try page.cells.insert(self.gpa, pos, .{ .key = key, .size = size });
            self.count += 1;
        }
        page.used = page.used - old_size + size;
        if (page.used <= self.cfg.capacity) return;

        // The page is overfull. Unlike underflow, this MUST be repaired
        // before returning, so a failed repair undoes the insert.
        const saved_stats = self.stats;
        const appended = !existing and pos == page.cells.items.len - 1;
        self.fixOverflow(ci, appended) catch |err| {
            // Nothing structural was committed (balance allocates first,
            // then mutates), so `ci` and `pos` are still right. The page
            // table itself may have been reallocated, so look the page up again.
            const undo = &self.pages.items[self.childAt(ci)];
            if (existing) {
                undo.cells.items[pos].size = old_size;
            } else {
                _ = undo.cells.orderedRemove(pos);
                self.count -= 1;
            }
            undo.used = undo.used - size + old_size;
            self.stats = saved_stats;
            return err;
        };
    }

    fn fixOverflow(self: *Tree, ci: usize, appended: bool) Allocator.Error!void {
        // Turso's conditions for the fast path (btree.rs:3460-3492): the
        // overflowing cell is the last cell of the right-most leaf.
        if (self.cfg.quick_append and appended and ci == self.childCount() - 1) {
            return self.quickAppend();
        }
        return self.balance(ci, self.cfg.insert_siblings);
    }

    /// Append fast path (Turso `balance_quick`, btree.rs:3526-3600): do not
    /// look at any sibling, do not move any existing cell. The new cell gets
    /// a fresh right-most leaf to itself and the old leaf stays 100% full.
    fn quickAppend(self: *Tree) Allocator.Error!void {
        const old_id = self.rightmost;
        const new_id = try self.allocPage();
        errdefer self.freePage(new_id);
        try self.pages.items[new_id].cells.ensureTotalCapacity(self.gpa, 1);
        try self.dividers.ensureUnusedCapacity(self.gpa, 1);
        // Everything below cannot fail.
        const old = &self.pages.items[old_id]; // after allocPage: the table may have moved
        const cell = old.cells.pop().?;
        old.used -= cell.size;
        const new = &self.pages.items[new_id];
        new.cells.appendAssumeCapacity(cell);
        new.used = cell.size;
        // New divider: (old leaf, largest key left on it); the right-most
        // pointer now names the new leaf.
        self.dividers.appendAssumeCapacity(.{ .child = old_id, .key = old.cells.items[old.cells.items.len - 1].key });
        self.rightmost = new_id;
        self.stats.quick_appends += 1;
        self.stats.leaf_writes += 1;
        self.stats.parent_writes += 1;
    }

    /// Remove `key`. Returns whether it was present. Never fails: repairing
    /// an underfull page is optional, so if the repair runs out of memory
    /// the tree is simply left as it is (still valid, a little emptier).
    pub fn delete(self: *Tree, key: u64) bool {
        const ci = self.findChild(key);
        const page = &self.pages.items[self.childAt(ci)];
        const pos = std.sort.lowerBound(Cell, page.cells.items, key, cellKeyOrder);
        if (pos == page.cells.items.len or page.cells.items[pos].key != key) return false;
        page.used -= page.cells.orderedRemove(pos).size;
        self.count -= 1;
        // Note: the divider above this page may now be larger than every key
        // on it (a stale separator). That is fine: it is still an upper bound.
        if (self.childCount() == 1) return true; // a lone leaf has nobody to merge with

        const cap = self.cfg.capacity;
        const free = cap - page.used;
        const wants_balance = switch (self.cfg.merge) {
            .never => return true,
            .at_empty => false,
            .below_third => @as(u64, free) * 3 > @as(u64, cap) * 2,
            .below_half => @as(u64, page.used) * 2 < cap,
        };
        const is_empty = page.used == 0;
        if (wants_balance) {
            const saved_stats = self.stats;
            if (self.balance(ci, 3)) |_| return true else |_| self.stats = saved_stats;
        }
        // An empty page must not stay (only `.never` tolerates it).
        if (is_empty) self.removeEmpty(ci);
        return true;
    }

    /// Unlink the empty child `ci`. Needs no memory and moves no cell.
    /// Dropping divider `ci` hands the page's key range to its RIGHT
    /// neighbour (the same trick as Postgres `_bt_mark_page_halfdead`); only
    /// the right-most child gives its range to the left instead.
    fn removeEmpty(self: *Tree, ci: usize) void {
        const id = self.childAt(ci);
        if (ci < self.dividers.items.len) {
            _ = self.dividers.orderedRemove(ci);
        } else {
            self.rightmost = self.dividers.pop().?.child;
        }
        self.freePage(id);
        self.stats.parent_writes += 1;
    }

    /// The one routine: balance child `ci` together with its neighbours, up
    /// to `window` siblings in total. Depending on how many pages the cells
    /// need afterwards this is a split (more pages), a redistribution (same
    /// number) or a merge (fewer).
    ///
    /// All allocation happens before the first mutation, so on error the
    /// tree is untouched.
    fn balance(self: *Tree, ci: usize, window: usize) Allocator.Error!void {
        // Scratch memory dies with this call; the buffer is kept for the next.
        defer _ = self.scratch.reset(.retain_capacity);
        const sa = self.scratch.allocator();
        const cap = self.cfg.capacity;

        // 1. Pick the siblings: the page itself, then its left and right
        //    neighbours; at the edges take the first or last `window`
        //    children (btree.rs:3693-3713).
        const n = self.childCount();
        const cnt = @min(window, n);
        const start = @min(ci -| (window / 2), n - cnt);
        var old_ids: [3]u32 = undefined;
        var old_ends: [3]u32 = undefined;
        var total: usize = 0;
        for (0..cnt) |s| {
            old_ids[s] = self.childAt(start + s);
            total += self.pages.items[old_ids[s]].cells.items.len;
            old_ends[s] = @intCast(total);
        }

        // 2. Flatten: copy every cell of the siblings into one array, in key
        //    order. `from` remembers where each cell came from, `sizes` is
        //    all the redistribution maths needs.
        const flat = try sa.alloc(Cell, total);
        const from = try sa.alloc(u32, total);
        const sizes = try sa.alloc(u32, total);
        var at: usize = 0;
        for (old_ids[0..cnt]) |id| {
            for (self.pages.items[id].cells.items) |cell| {
                flat[at] = cell;
                from[at] = id;
                sizes[at] = cell.size;
                at += 1;
            }
        }

        // 3. Decide the new page boundaries. Pure arithmetic on `sizes`.
        const ends = try packLeft(sa, sizes, cap);
        evenOut(sizes, ends);
        const new_cnt = ends.len;
        std.debug.assert(new_cnt <= max_out_pages);
        if (std.mem.eql(u32, ends, old_ends[0..cnt])) return; // already as good as it gets

        // 4. Reserve everything the commit needs: extra pages, room in each
        //    output page, room in the parent.
        var ids: [max_out_pages]u32 = undefined;
        var got: usize = @min(cnt, new_cnt);
        @memcpy(ids[0..got], old_ids[0..got]); // old pages are reused in order
        errdefer for (ids[@min(cnt, new_cnt)..got]) |id| self.freePage(id);
        while (got < new_cnt) : (got += 1) ids[got] = try self.allocPage();
        for (ids[0..new_cnt], 0..) |id, p| {
            const first: u32 = if (p == 0) 0 else ends[p - 1];
            try self.pages.items[id].cells.ensureTotalCapacity(self.gpa, ends[p] - first);
        }
        // The last sibling may hang off the right-most pointer instead of
        // owning a divider cell.
        const last_is_right = start + cnt == n;
        const old_div = if (last_is_right) cnt - 1 else cnt;
        const new_div = if (last_is_right) new_cnt - 1 else new_cnt;
        try self.dividers.ensureTotalCapacity(self.gpa, self.dividers.items.len - old_div + new_div);

        // 5. Commit. Nothing below can fail.
        for (ids[0..new_cnt], 0..) |id, p| {
            const first: u32 = if (p == 0) 0 else ends[p - 1];
            const old_first: u32 = if (p == 0) 0 else if (p < cnt) old_ends[p - 1] else 0;
            const changed = p >= cnt or first != old_first or ends[p] != old_ends[p];
            if (changed) self.stats.leaf_writes += 1;
            for (from[first..ends[p]]) |origin| {
                if (origin != id) {
                    self.stats.cells_moved += 1;
                    if (p < cnt) self.stats.cells_moved_to_old += 1;
                }
            }
            const page = &self.pages.items[id];
            page.cells.clearRetainingCapacity();
            page.cells.appendSliceAssumeCapacity(flat[first..ends[p]]);
            page.used = sum(sizes[first..ends[p]]);
        }
        for (old_ids[@min(cnt, new_cnt)..cnt]) |id| self.freePage(id);

        // New dividers: every output page except the last is bounded by the
        // largest key it now holds. The last one keeps the upper bound the
        // old last sibling had (its old divider, or none if it is right-most).
        var new_dividers: [max_out_pages]Divider = undefined;
        for (0..new_div) |p| {
            const key = if (p + 1 < new_cnt) flat[ends[p] - 1].key else self.dividers.items[start + cnt - 1].key;
            new_dividers[p] = .{ .child = ids[p], .key = key };
        }
        self.dividers.replaceRangeAssumeCapacity(start, old_div, new_dividers[0..new_div]);
        if (last_is_right) self.rightmost = ids[new_cnt - 1];
        self.stats.balances += 1;
        self.stats.parent_writes += 1;
    }

    /// Append every cell with lo <= key < hi to `out`, in key order.
    pub fn range(self: *const Tree, gpa: Allocator, lo: u64, hi: u64, out: *std.ArrayList(Cell)) Allocator.Error!void {
        if (lo >= hi) return;
        // Without sibling links the scan walks the parent, child by child.
        for (self.findChild(lo)..self.childCount()) |ci| {
            for (self.pages.items[self.childAt(ci)].cells.items) |cell| {
                if (cell.key >= hi) return;
                if (cell.key >= lo) try out.append(gpa, cell);
            }
        }
    }

    /// Check every invariant of the model. Being underfull is NOT a
    /// violation: minimum fill is a policy, not an invariant.
    pub fn validate(self: *const Tree) error{Invalid}!void {
        var live: usize = 0;
        for (self.pages.items) |page| live += @intFromBool(page.live);
        // Every live page is reachable exactly once, the rest is on the free list.
        if (live != self.childCount()) return error.Invalid;
        if (self.free_ids.items.len != self.pages.items.len - live) return error.Invalid;
        for (self.free_ids.items) |id| if (self.pages.items[id].live) return error.Invalid;

        var cells_seen: usize = 0;
        var lower: ?u64 = null; // exclusive lower bound of the current child
        for (0..self.childCount()) |ci| {
            const page = self.pages.items[self.childAt(ci)];
            if (!page.live) return error.Invalid;
            const upper: ?u64 = if (ci < self.dividers.items.len) self.dividers.items[ci].key else null;
            // Dividers strictly increase, so key ranges do not overlap.
            if (lower != null and upper != null and upper.? <= lower.?) return error.Invalid;
            var used: u32 = 0;
            var prev = lower;
            for (page.cells.items) |cell| {
                if (prev != null and cell.key <= prev.?) return error.Invalid; // sorted, above the lower bound
                if (upper != null and cell.key > upper.?) return error.Invalid; // within the divider
                prev = cell.key;
                used += cell.size;
            }
            if (used != page.used or used > self.cfg.capacity) return error.Invalid;
            if (used == 0 and self.cfg.merge != .never and self.childCount() > 1) return error.Invalid;
            cells_seen += page.cells.items.len;
            lower = upper;
        }
        if (cells_seen != self.count) return error.Invalid;
    }

    /// Text picture of the tree, used by the fixed scenario and by the
    /// visualization's self-test.
    pub fn dump(self: *const Tree, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("parent:");
        for (self.dividers.items) |d| try w.print(" (p{d}, {d})", .{ d.child, d.key });
        try w.print(" right=p{d}\n", .{self.rightmost});
        for (0..self.childCount()) |ci| {
            const id = self.childAt(ci);
            const page = self.pages.items[id];
            try w.print("  p{d} {d:>3}/{d}:", .{ id, page.used, self.cfg.capacity });
            for (page.cells.items) |cell| try w.print(" {d}:{d}", .{ cell.key, cell.size });
            try w.writeAll("\n");
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const ops = @import("ops.zig");

fn redistributeForTest(sizes: []const u32, capacity: u32, out: []u32) ![]u32 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ends = try packLeft(arena.allocator(), sizes, capacity);
    evenOut(sizes, ends);
    @memcpy(out[0..ends.len], ends);
    return out[0..ends.len];
}

test "packLeft fills pages from the left, evenOut balances right to left" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sizes = [_]u32{ 30, 30, 30, 30, 30, 30, 20 }; // 200 bytes, capacity 100
    const ends = try packLeft(arena.allocator(), &sizes, 100);
    try testing.expectEqualSlices(u32, &.{ 3, 6, 7 }, ends); // 90 | 90 | 20
    evenOut(&sizes, ends);
    // One cell moves right (60 | 50); a second would make the right page the
    // bigger one. The first boundary stays: 90 vs 60 cannot be improved.
    try testing.expectEqualSlices(u32, &.{ 3, 5, 7 }, ends);
}

test "redistribute: edge cases" {
    var buf: [8]u32 = undefined;
    // No cells at all: one empty page.
    try testing.expectEqualSlices(u32, &.{0}, try redistributeForTest(&.{}, 100, &buf));
    // Everything fits one page: a merge.
    try testing.expectEqualSlices(u32, &.{3}, try redistributeForTest(&.{ 30, 30, 40 }, 100, &buf));
    // A lone leftover cell pulls cells over from its left neighbour.
    try testing.expectEqualSlices(u32, &.{ 3, 5 }, try redistributeForTest(&.{ 25, 25, 25, 25, 10 }, 100, &buf));
    // One big cell per page: nothing to even out, left pages keep >= 1 cell.
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, try redistributeForTest(&.{ 90, 90, 90 }, 100, &buf));
}

test "redistribute: every page fits and no page is empty (random sizes)" {
    var rng = @import("prng.zig").SplitMix64.init(15);
    var sizes: [64]u32 = undefined;
    var buf: [65]u32 = undefined;
    for (0..500) |_| {
        const n: usize = @intCast(rng.range(1, 65));
        for (sizes[0..n]) |*s| s.* = @intCast(rng.range(1, 26));
        const ends = try redistributeForTest(sizes[0..n], 100, &buf);
        var first: u32 = 0;
        for (ends) |end| {
            try testing.expect(end > first);
            try testing.expect(sum(sizes[first..end]) <= 100);
            first = end;
        }
        try testing.expectEqual(n, first);
        // Minimal page count: greedy packing is optimal for contiguous cuts.
        try testing.expectEqual((sum(sizes[0..n]) + 99) / 100 <= ends.len, true);
    }
}

fn expectDump(tree: *const Tree, expected: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try tree.dump(&aw.writer);
    try testing.expectEqualStrings(expected, aw.written());
}

test "split, redistribution and merge are one routine" {
    var tree: Tree = try .init(testing.allocator, .{ .capacity = 100, .quick_append = false });
    defer tree.deinit();
    for ([_]u64{ 10, 20, 30, 40 }) |k| try tree.put(k, 25);
    try tree.put(50, 25); // overflow with no sibling: 1 page in, 2 out
    try expectDump(&tree,
        \\parent: (p0, 30) right=p1
        \\  p0  75/100: 10:25 20:25 30:25
        \\  p1  50/100: 40:25 50:25
        \\
    );
    try tree.put(5, 25);
    try tree.put(15, 25); // p0 overflows, p1 has room: 2 in, 2 out, no new page
    try expectDump(&tree,
        \\parent: (p0, 20) right=p1
        \\  p0 100/100: 5:25 10:25 15:25 20:25
        \\  p1  75/100: 30:25 40:25 50:25
        \\
    );
    try testing.expectEqual(2, tree.stats.balances);
    try testing.expectEqual(1, tree.stats.pages_allocated);
    try testing.expectEqual(1, tree.stats.cells_moved_to_old); // key 30 crossed an existing boundary
    // Deleting until p1 is more than 2/3 free pulls the siblings together.
    try testing.expect(tree.delete(40));
    try testing.expect(tree.delete(50)); // p1 = 25 bytes; 125 bytes in total still need 2 pages
    try expectDump(&tree,
        \\parent: (p0, 15) right=p1
        \\  p0  75/100: 5:25 10:25 15:25
        \\  p1  50/100: 20:25 30:25
        \\
    );
    try testing.expect(tree.delete(5));
    try testing.expect(tree.delete(20)); // p1 = 25 bytes again; now 75 bytes fit one page
    try expectDump(&tree,
        \\parent: right=p0
        \\  p0  75/100: 10:25 15:25 30:25
        \\
    );
    try testing.expectEqual(1, tree.stats.pages_freed);
    try tree.validate();
}

test "quick append leaves the old right-most leaf full and moves nothing" {
    var tree: Tree = try .init(testing.allocator, .{ .capacity = 100 });
    defer tree.deinit();
    for (1..10) |k| try tree.put(k, 25);
    try expectDump(&tree,
        \\parent: (p0, 4) (p1, 8) right=p2
        \\  p0 100/100: 1:25 2:25 3:25 4:25
        \\  p1 100/100: 5:25 6:25 7:25 8:25
        \\  p2  25/100: 9:25
        \\
    );
    try testing.expectEqual(2, tree.stats.quick_appends);
    try testing.expectEqual(0, tree.stats.balances);
    try testing.expectEqual(0, tree.stats.cells_moved);
    // A key that overflows the right-most leaf but is not its last cell
    // does not qualify.
    for ([_]u64{ 20, 30, 40 }) |k| try tree.put(k, 25);
    try tree.put(15, 25);
    try testing.expectEqual(2, tree.stats.quick_appends);
    try testing.expectEqual(1, tree.stats.balances);
    try tree.validate();
}

test "merge policies on the same deletes" {
    const policies = [_]MergePolicy{ .never, .at_empty, .below_third, .below_half };
    const pages_after = [_]usize{ 4, 2, 1, 1 };
    for (policies, pages_after) |policy, expected| {
        var tree: Tree = try .init(testing.allocator, .{ .capacity = 100, .merge = policy });
        defer tree.deinit();
        for (1..17) |k| try tree.put(k, 25); // four full leaves
        // Empty the two middle leaves, leave one cell in each outer leaf.
        for (2..16) |k| try testing.expect(tree.delete(k));
        try testing.expectEqual(expected, tree.childCount());
        try testing.expectEqual(2, tree.count);
        try testing.expectEqual(25, tree.get(1).?);
        try testing.expectEqual(25, tree.get(16).?);
        try tree.validate();
        // Only the rebalancing policies ever move a cell onto another page.
        const moved = tree.stats.cells_moved_to_old != 0;
        try testing.expectEqual(policy == .below_third or policy == .below_half, moved);
    }
}

test "put rejects oversized cells and overwrites in place" {
    var tree: Tree = try .init(testing.allocator, .{ .capacity = 100 });
    defer tree.deinit();
    try testing.expectError(error.CellTooLarge, tree.put(1, 34));
    try testing.expectError(error.CellTooLarge, tree.put(1, 0));
    try tree.put(1, 10);
    try tree.put(1, 20); // overwrite: still one cell
    try testing.expectEqual(1, tree.count);
    try testing.expectEqual(20, tree.get(1).?);
    try testing.expectEqual(null, tree.get(2));
    try testing.expect(!tree.delete(2));
    // An overwrite that grows a cell can overflow the page too.
    for (2..6) |k| try tree.put(k, 20);
    try tree.put(3, 25);
    try testing.expectEqual(2, tree.childCount());
    try tree.validate();
}

fn cellSizeFor(value: u64) u32 {
    return @intCast(1 + value % 25); // 1..25 bytes on a 100-byte page
}

fn modelTest(cfg: Config, seed: u64) !void {
    const gpa = testing.allocator;
    var tree: Tree = try .init(gpa, cfg);
    defer tree.deinit();
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var got: std.ArrayList(Cell) = .empty;
    defer got.deinit(gpa);
    var stream = ops.OpStream.init(.{ .seed = seed, .count = 6000, .key_space = 300 });
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| {
                try tree.put(p.key, cellSizeFor(p.value));
                _ = try oracle.put(gpa, p.key, cellSizeFor(p.value));
            },
            .delete => |d| try testing.expectEqual(oracle.delete(d.key) != null, tree.delete(d.key)),
            .get => |g| try testing.expectEqual(oracle.get(g.key), if (tree.get(g.key)) |size| @as(?u64, size) else null),
            .range => |r| {
                got.clearRetainingCapacity();
                try tree.range(gpa, r.lo, r.hi, &got);
                const want = oracle.range(r.lo, r.hi);
                try testing.expectEqual(want.len, got.items.len);
                for (want, got.items) |w, g| {
                    try testing.expectEqual(w.key, g.key);
                    try testing.expectEqual(w.value, g.size);
                }
            },
        }
        try tree.validate();
        try testing.expectEqual(oracle.len(), tree.count);
    }
}

test "model test against the oracle, every policy combination" {
    var seed: u64 = 1;
    for ([_]MergePolicy{ .never, .at_empty, .below_third, .below_half }) |merge| {
        for ([_]u8{ 1, 2, 3 }) |siblings| {
            for ([_]bool{ false, true }) |quick| {
                try modelTest(.{ .capacity = 100, .insert_siblings = siblings, .quick_append = quick, .merge = merge }, seed);
                seed += 1;
            }
        }
    }
}

fn putMany(gpa: Allocator, siblings: u8) !void {
    var tree: Tree = try .init(gpa, .{ .capacity = 100, .insert_siblings = siblings, .merge = .never });
    defer tree.deinit();
    var rng = @import("prng.zig").SplitMix64.init(99);
    for (0..60) |_| try tree.put(rng.below(80), @intCast(rng.range(5, 26)));
    for (100..110) |k| try tree.put(k, 25); // appends
    try tree.validate();
}

test "allocation failure at every point of a run of puts leaks nothing" {
    // Runs putMany once per allocation it makes, failing that allocation,
    // and requires error.OutOfMemory and no leak every time.
    for ([_]u8{ 1, 2, 3 }) |siblings| {
        try testing.checkAllAllocationFailures(testing.allocator, putMany, .{siblings});
    }
}

test "a failed put leaves the tree exactly as it was; a failed merge is skipped" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var tree: Tree = try .init(failing.allocator(), .{ .capacity = 100, .quick_append = false });
    defer tree.deinit();
    for (1..5) |k| try tree.put(k * 10, 25); // one full leaf
    var before: std.Io.Writer.Allocating = .init(testing.allocator);
    defer before.deinit();
    try tree.dump(&before.writer);
    const stats_before = tree.stats;

    // Let the overflowing put get 0, 1, 2, ... allocations before memory
    // runs out. Every failed attempt must leave no trace.
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        failing.fail_index = failing.alloc_index + fail_at;
        if (tree.put(25, 25)) |_| break else |err| try testing.expectEqual(error.OutOfMemory, err);
        try expectDump(&tree, before.written());
        try testing.expectEqual(stats_before, tree.stats);
        try testing.expectEqual(4, tree.count);
        try tree.validate();
    }
    // Fewer attempts than allocations: capacity that a failed attempt did
    // get (the scratch buffer, a dead page slot) is kept for the next one.
    try testing.expect(fail_at >= 2);
    try testing.expectEqual(2, tree.childCount()); // p0: 10 20 25, p1: 30 40
    failing.fail_index = std.math.maxInt(usize);

    // Underflow repair is optional. Give p1 many tiny cells so that the next
    // balance needs more scratch memory than the arena has kept, then take
    // all memory away: the deletes still succeed, the merge just does not happen.
    for (41..91) |k| try tree.put(k, 1);
    try testing.expect(tree.delete(30));
    try testing.expect(tree.delete(40)); // p0: 75 bytes, p1: fifty 1-byte cells
    failing.fail_index = failing.alloc_index;
    const balances = tree.stats.balances;
    // At 25 bytes on p1 everything would fit on one page.
    for (41..66) |k| try testing.expect(tree.delete(k));
    try testing.expectEqual(balances, tree.stats.balances);
    try testing.expectEqual(2, tree.childCount());
    try tree.validate();
    // With memory back, the next delete does the merge.
    failing.fail_index = std.math.maxInt(usize);
    try testing.expect(tree.delete(66));
    try testing.expectEqual(balances + 1, tree.stats.balances);
    try testing.expectEqual(1, tree.childCount());
    try tree.validate();
}
