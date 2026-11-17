//! A compact in-memory B+tree whose nodes play the role of disk pages.
//!
//! Everything in this chapter is about *how the tree gets built*, so the tree
//! itself is kept as small as possible:
//!
//!   * keys and values are u64, duplicates are rejected (put overwrites);
//!   * nodes have a fixed capacity and live in one array (`nodes`); a node is
//!     named by its index, which stands in for a page id;
//!   * there is no delete (chapters 05, 07 and 15 cover it);
//!   * every time a node would have to be written back to disk we bump
//!     `stats.page_writes`. That counter is the measuring stick of the chapter.
//!
//! Node layout. Leaf and interior nodes use the same two arrays:
//!
//!     leaf:      keys[i] -> slots[i] is a value          (len entries)
//!     interior:  slots[i] is a child id                  (len children)
//!                keys[i], i >= 1, is the separator: every key in child i
//!                is >= keys[i] and every key in child i-1 is < keys[i]
//!                keys[0] is IGNORED by search ("minus infinity")
//!
//! Storing an ignored key in slot 0 keeps both node kinds a plain list of
//! (key, pointer) pairs, which is exactly the shape the bulk loader produces.
//! PostgreSQL does the same: the first item on an internal page is a "minus
//! infinity" item whose key is never compared.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Largest supported order. Fixed so that a node is a fixed-size struct, like
/// a page. One extra array slot lets a node overflow by one before it splits.
pub const max_order = 32;
/// "No node": used for an empty tree's root and the last leaf's `next`.
pub const nil: u32 = std.math.maxInt(u32);
/// A tree of order >= 3 with 2^32 node ids cannot be taller than this.
pub const max_height = 32;

pub const Entry = struct { key: u64, value: u64 };

pub const Node = struct {
    is_leaf: bool,
    len: u16 = 0,
    /// Leaves only: id of the next leaf to the right, or `nil`.
    next: u32 = nil,
    keys: [max_order + 1]u64 = undefined,
    slots: [max_order + 1]u64 = undefined,
};

pub const Stats = struct {
    /// Nodes written back. One insert that splits nothing writes 1 page; each
    /// split writes the two halves; a new root is one more write.
    page_writes: u64 = 0,
    /// Nodes read by `put` on its way down (one per level).
    page_reads: u64 = 0,
    /// Node splits performed by `put`.
    splits: u64 = 0,
};

/// What the tree looks like, for the report and the tests.
pub const Shape = struct {
    height: usize = 0,
    leaves: usize = 0,
    inner: usize = 0,
    entries: usize = 0,

    pub fn pages(self: Shape) usize {
        return self.leaves + self.inner;
    }
};

pub const ValidateError = error{
    KeysOutOfOrder,
    KeyOutOfBounds,
    Underfull,
    Overfull,
    UnevenDepth,
    BrokenLeafChain,
    CountMismatch,
};

pub const Tree = struct {
    gpa: Allocator,
    /// Order M = maximum number of children (Knuth). 3 <= M <= max_order.
    order: usize,
    nodes: std.ArrayList(Node) = .empty,
    root: u32 = nil,
    /// Number of levels; 0 for an empty tree, 1 when the root is a leaf.
    height: usize = 0,
    /// Number of key/value pairs.
    count: usize = 0,
    stats: Stats = .{},

    pub fn init(gpa: Allocator, order: usize) Tree {
        std.debug.assert(order >= 3 and order <= max_order);
        return .{ .gpa = gpa, .order = order };
    }

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.gpa);
        self.* = undefined;
    }

    // ---- capacities (all in "pairs", see the node layout above) ----

    pub fn leafCap(self: *const Tree) usize {
        return self.order - 1;
    }
    pub fn innerCap(self: *const Tree) usize {
        return self.order;
    }
    /// ceil(M/2) - 1 keys, but never less than one.
    pub fn leafMin(self: *const Tree) usize {
        return @max(1, (self.order + 1) / 2 - 1);
    }
    /// ceil(M/2) children.
    pub fn innerMin(self: *const Tree) usize {
        return (self.order + 1) / 2;
    }
    pub fn cap(self: *const Tree, is_leaf: bool) usize {
        return if (is_leaf) self.leafCap() else self.innerCap();
    }
    pub fn min(self: *const Tree, is_leaf: bool) usize {
        return if (is_leaf) self.leafMin() else self.innerMin();
    }

    /// Append a blank node and return its id. This only reserves the page id;
    /// it does not count as a page write.
    pub fn allocNode(self: *Tree, is_leaf: bool) Allocator.Error!u32 {
        try self.nodes.append(self.gpa, .{ .is_leaf = is_leaf });
        return @intCast(self.nodes.items.len - 1);
    }

    // ---- search ----

    /// Which child of an interior node covers `key`: the last i with
    /// keys[i] <= key, where keys[0] counts as minus infinity.
    fn childIndex(node: *const Node, key: u64) usize {
        var i: usize = 1;
        while (i < node.len and node.keys[i] <= key) i += 1;
        return i - 1;
    }

    /// First position in a leaf whose key is >= `key` (may be node.len).
    fn lowerBound(node: *const Node, key: u64) usize {
        var i: usize = 0;
        while (i < node.len and node.keys[i] < key) i += 1;
        return i;
    }

    fn findLeaf(self: *const Tree, key: u64) u32 {
        var id = self.root;
        while (!self.nodes.items[id].is_leaf) {
            const node = &self.nodes.items[id];
            id = @intCast(node.slots[childIndex(node, key)]);
        }
        return id;
    }

    pub fn get(self: *const Tree, key: u64) ?u64 {
        if (self.root == nil) return null;
        const leaf = &self.nodes.items[self.findLeaf(key)];
        const pos = lowerBound(leaf, key);
        if (pos < leaf.len and leaf.keys[pos] == key) return leaf.slots[pos];
        return null;
    }

    /// Iterator over the entries with lo <= key < hi, ascending. It walks
    /// the leaf chain, so it also proves that the loader linked the leaves.
    pub const RangeIter = struct {
        tree: *const Tree,
        node: u32,
        pos: usize,
        hi: u64,

        pub fn next(self: *RangeIter) ?Entry {
            while (self.node != nil) {
                const leaf = &self.tree.nodes.items[self.node];
                if (self.pos < leaf.len) {
                    const key = leaf.keys[self.pos];
                    if (key >= self.hi) return null;
                    self.pos += 1;
                    return .{ .key = key, .value = leaf.slots[self.pos - 1] };
                }
                self.node = leaf.next;
                self.pos = 0;
            }
            return null;
        }
    };

    pub fn range(self: *const Tree, lo: u64, hi: u64) RangeIter {
        if (self.root == nil or lo >= hi) return .{ .tree = self, .node = nil, .pos = 0, .hi = hi };
        const id = self.findLeaf(lo);
        return .{ .tree = self, .node = id, .pos = lowerBound(&self.nodes.items[id], lo), .hi = hi };
    }

    // ---- one-by-one insert (the path the bulk loader is compared against) ----

    /// Insert or overwrite. On error.OutOfMemory the tree is unchanged.
    pub fn put(self: *Tree, key: u64, value: u64) Allocator.Error!void {
        if (self.root == nil) {
            const id = try self.allocNode(true);
            const leaf = &self.nodes.items[id];
            leaf.keys[0] = key;
            leaf.slots[0] = value;
            leaf.len = 1;
            self.root = id;
            self.height = 1;
            self.count = 1;
            self.stats.page_writes += 1;
            return;
        }

        // 1. Descend, remembering the path: path[d] is the node at depth d and
        //    idx[d] the child slot we took out of it.
        var path: [max_height]u32 = undefined;
        var idx: [max_height]usize = undefined;
        var depth: usize = 0;
        var id = self.root;
        while (true) {
            path[depth] = id;
            self.stats.page_reads += 1;
            const node = &self.nodes.items[id];
            if (node.is_leaf) break;
            idx[depth] = childIndex(node, key);
            id = @intCast(node.slots[idx[depth]]);
            depth += 1;
        }

        const leaf = &self.nodes.items[id];
        const pos = lowerBound(leaf, key);
        if (pos < leaf.len and leaf.keys[pos] == key) {
            leaf.slots[pos] = value; // overwrite: one page written, no growth
            self.stats.page_writes += 1;
            return;
        }

        // 2. Reserve memory for every node this insert can create BEFORE
        //    changing anything: one new node per full node at the bottom of
        //    the path, plus a new root if the whole path is full. After this
        //    line nothing can fail, so an OOM never leaves a half-done split.
        var needed: usize = 0;
        var d = depth + 1;
        while (d > 0) : (d -= 1) {
            const n = &self.nodes.items[path[d - 1]];
            if (n.len < self.cap(n.is_leaf)) break;
            needed += 1;
        }
        if (needed == depth + 1) needed += 1; // root splits too
        try self.nodes.ensureUnusedCapacity(self.gpa, needed);

        // 3. Insert into the leaf, then walk back up while nodes overflow.
        insertAt(&self.nodes.items[id], pos, key, value);
        self.count += 1;
        d = depth;
        while (true) {
            const node_id = path[d];
            const node = &self.nodes.items[node_id];
            if (node.len <= self.cap(node.is_leaf)) {
                self.stats.page_writes += 1;
                return;
            }
            // Overflow by one: split 50/50. The right half's first key is the
            // separator. In a leaf it is *copied* up (the entry stays in the
            // leaf); in an interior node it moves into the ignored slot 0 of
            // the right half, which amounts to pushing it up.
            const right_id: u32 = @intCast(self.nodes.items.len);
            self.nodes.appendAssumeCapacity(.{ .is_leaf = node.is_leaf });
            const left = &self.nodes.items[node_id];
            const right = &self.nodes.items[right_id];
            const keep = left.len - left.len / 2;
            right.len = left.len - keep;
            @memcpy(right.keys[0..right.len], left.keys[keep..left.len]);
            @memcpy(right.slots[0..right.len], left.slots[keep..left.len]);
            left.len = keep;
            if (left.is_leaf) {
                right.next = left.next;
                left.next = right_id;
            }
            self.stats.page_writes += 2;
            self.stats.splits += 1;
            const sep = right.keys[0];

            if (d == 0) {
                // The root split: grow the tree by one level.
                const root_id: u32 = @intCast(self.nodes.items.len);
                self.nodes.appendAssumeCapacity(.{ .is_leaf = false });
                const root = &self.nodes.items[root_id];
                root.keys[0] = 0; // ignored
                root.slots[0] = node_id;
                root.keys[1] = sep;
                root.slots[1] = right_id;
                root.len = 2;
                self.root = root_id;
                self.height += 1;
                self.stats.page_writes += 1;
                return;
            }
            d -= 1;
            insertAt(&self.nodes.items[path[d]], idx[d] + 1, sep, right_id);
        }
    }

    /// Shift pairs [pos, len) one to the right and put (key, slot) at pos.
    fn insertAt(node: *Node, pos: usize, key: u64, slot: u64) void {
        var i: usize = node.len;
        while (i > pos) : (i -= 1) {
            node.keys[i] = node.keys[i - 1];
            node.slots[i] = node.slots[i - 1];
        }
        node.keys[pos] = key;
        node.slots[pos] = slot;
        node.len += 1;
    }

    // ---- inspection ----

    pub fn shape(self: *const Tree) Shape {
        var s: Shape = .{ .height = self.height };
        if (self.root != nil) self.shapeOf(self.root, &s);
        return s;
    }

    fn shapeOf(self: *const Tree, id: u32, s: *Shape) void {
        const node = &self.nodes.items[id];
        if (node.is_leaf) {
            s.leaves += 1;
            s.entries += node.len;
        } else {
            s.inner += 1;
            for (node.slots[0..node.len]) |child| self.shapeOf(@intCast(child), s);
        }
    }

    /// Check every invariant of the structure:
    ///   1. keys inside a node are strictly ascending;
    ///   2. every key lies inside the bounds its ancestors' separators promise;
    ///   3. every node except the root holds at least the minimum, none more
    ///      than the capacity; an interior root has at least two children;
    ///   4. all leaves are at the same depth;
    ///   5. the leaf chain visits the leaves left to right and ends with nil;
    ///   6. `count` equals the number of entries in the leaves.
    pub fn validate(self: *const Tree) ValidateError!void {
        if (self.root == nil) {
            if (self.count != 0 or self.height != 0) return error.CountMismatch;
            return;
        }
        var walk: Walk = .{};
        try self.check(self.root, null, null, 1, &walk);
        if (walk.prev_leaf != nil and self.nodes.items[walk.prev_leaf].next != nil) return error.BrokenLeafChain;
        if (walk.entries != self.count) return error.CountMismatch;
    }

    const Walk = struct { prev_leaf: u32 = nil, entries: usize = 0 };

    fn check(self: *const Tree, id: u32, lo: ?u64, hi: ?u64, depth: usize, walk: *Walk) ValidateError!void {
        const node = &self.nodes.items[id];
        const is_root = id == self.root;
        if (node.len > self.cap(node.is_leaf)) return error.Overfull;
        const least: usize = if (!is_root) self.min(node.is_leaf) else if (node.is_leaf) 1 else 2;
        if (node.len < least) return error.Underfull;

        if (node.is_leaf) {
            if (depth != self.height) return error.UnevenDepth;
            for (node.keys[0..node.len], 0..) |key, i| {
                if (i > 0 and node.keys[i - 1] >= key) return error.KeysOutOfOrder;
                if (lo != null and key < lo.?) return error.KeyOutOfBounds;
                if (hi != null and key >= hi.?) return error.KeyOutOfBounds;
            }
            // In-order traversal meets the leaves left to right, so the leaf
            // seen just before this one must point here.
            if (walk.prev_leaf != nil and self.nodes.items[walk.prev_leaf].next != id) return error.BrokenLeafChain;
            walk.prev_leaf = id;
            walk.entries += node.len;
            return;
        }

        for (0..node.len) |i| {
            // keys[0] is ignored: child 0 inherits the lower bound from above.
            const child_lo: ?u64 = if (i == 0) lo else node.keys[i];
            const child_hi: ?u64 = if (i + 1 < node.len) node.keys[i + 1] else hi;
            if (i >= 1) {
                if (i >= 2 and node.keys[i - 1] >= node.keys[i]) return error.KeysOutOfOrder;
                if (lo != null and node.keys[i] <= lo.?) return error.KeyOutOfBounds;
                if (hi != null and node.keys[i] >= hi.?) return error.KeyOutOfBounds;
            }
            try self.check(@intCast(node.slots[i]), child_lo, child_hi, depth + 1, walk);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const ops = @import("ops.zig");

test "empty tree" {
    var tree = Tree.init(testing.allocator, 4);
    defer tree.deinit();
    try tree.validate();
    try testing.expectEqual(null, tree.get(1));
    var it = tree.range(0, 100);
    try testing.expectEqual(null, it.next());
}

test "ascending inserts leave leaves half full" {
    var tree = Tree.init(testing.allocator, 4);
    defer tree.deinit();
    for (1..14) |k| try tree.put(k, k * 10);
    try tree.validate();
    const s = tree.shape();
    // 13 keys, leaf capacity 3: a 50/50 split of a full leaf leaves 2 behind,
    // and nothing is ever added to a left half again.
    try testing.expectEqual(6, s.leaves);
    try testing.expectEqual(3, s.height);
    try testing.expectEqual(13, s.entries);
    for (1..14) |k| try testing.expectEqual(k * 10, tree.get(k).?);
    try testing.expectEqual(null, tree.get(14));
}

test "put overwrites" {
    var tree = Tree.init(testing.allocator, 4);
    defer tree.deinit();
    try tree.put(5, 1);
    try tree.put(5, 2);
    try testing.expectEqual(1, tree.count);
    try testing.expectEqual(2, tree.get(5).?);
}

test "model test: put, get, range against the oracle" {
    const gpa = testing.allocator;
    for ([_]usize{ 3, 4, 5, 8 }) |order| {
        var tree = Tree.init(gpa, order);
        defer tree.deinit();
        var oracle: ops.Oracle = .{};
        defer oracle.deinit(gpa);
        var stream = ops.OpStream.init(.{
            .seed = 16 + order,
            .count = 4000,
            .key_space = 300,
            .weights = .{ .put = 5, .delete = 0, .get = 3, .range = 2 },
        });
        while (stream.next()) |op| switch (op) {
            .put => |p| {
                try tree.put(p.key, p.value);
                _ = try oracle.put(gpa, p.key, p.value);
            },
            .delete => unreachable, // weight 0: this chapter's tree has no delete
            .get => |g| try testing.expectEqual(oracle.get(g.key), tree.get(g.key)),
            .range => |r| try expectSameEntries(oracle.range(r.lo, r.hi), &tree, r.lo, r.hi),
        };
        try tree.validate();
        try testing.expectEqual(oracle.len(), tree.count);
    }
}

pub fn expectSameEntries(expected: []const ops.Entry, tree: *const Tree, lo: u64, hi: u64) !void {
    var it = tree.range(lo, hi);
    for (expected) |e| {
        const got = it.next() orelse return error.TestExpectedEqual;
        try testing.expectEqual(e.key, got.key);
        try testing.expectEqual(e.value, got.value);
    }
    try testing.expectEqual(null, it.next());
}

test "put under allocation failure leaves the tree unchanged" {
    // Fail the Nth allocation for N = 0, 1, 2, ... until a run succeeds.
    // Whenever put fails, everything inserted before must still be there.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        var tree = Tree.init(failing.allocator(), 4);
        defer tree.deinit();
        var inserted: u64 = 0;
        var failed = false;
        while (inserted < 200) : (inserted += 1) {
            tree.put(inserted * 3, inserted) catch {
                failed = true;
                break;
            };
        }
        try tree.validate();
        try testing.expectEqual(inserted, tree.count);
        for (0..inserted) |k| try testing.expectEqual(k, tree.get(k * 3).?);
        if (!failed) break;
        try testing.expect(failing.has_induced_failure);
    }
    try testing.expect(fail_index > 0);
}

test "validate catches a broken separator and a broken leaf chain" {
    var tree = Tree.init(testing.allocator, 4);
    defer tree.deinit();
    for (1..14) |k| try tree.put(k, k);
    const first_leaf = tree.findLeaf(0);
    const saved = tree.nodes.items[first_leaf];
    tree.nodes.items[first_leaf].keys[1] = 0;
    try testing.expectError(error.KeysOutOfOrder, tree.validate());
    tree.nodes.items[first_leaf] = saved;
    tree.nodes.items[first_leaf].next = nil;
    try testing.expectError(error.BrokenLeafChain, tree.validate());
    tree.nodes.items[first_leaf] = saved;
    try tree.validate();
}
