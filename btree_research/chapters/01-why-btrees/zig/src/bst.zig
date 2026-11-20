//! An unbalanced binary search tree (BST) that counts node visits.
//!
//! The BST fixes the sorted array's write problem: inserting a key allocates
//! one node and changes one pointer; nothing is shifted. It pays for this
//! twice:
//!
//!   1. Every step of a lookup follows a pointer to a node that can be
//!      anywhere in memory (or on disk). In the cost model of this chapter
//!      each node visit is one page read.
//!   2. Nothing keeps the tree shallow. Insert keys in ascending order and
//!      the "tree" is a linked list: height = number of keys.
//!
//! A B-tree keeps the pointer idea but puts hundreds of keys in each node
//! (few page reads) and keeps all leaves at the same depth (no bad order).
//!
//! Invariant (checked by `validate`): for every node, all keys in its left
//! subtree are smaller and all keys in its right subtree are larger.
const std = @import("std");
const Allocator = std.mem.Allocator;
const cost = @import("cost.zig");

pub const Entry = cost.Entry;

pub const Bst = struct {
    root: ?*Node = null,
    len: usize = 0,

    pub const Node = struct {
        key: u64,
        value: u64,
        left: ?*Node = null,
        right: ?*Node = null,
    };

    pub const empty: Bst = .{};

    /// Free every node. The allocator must be the one that was passed to
    /// `put`; the tree does not remember it.
    pub fn deinit(self: *Bst, allocator: Allocator) void {
        // Iterative on purpose: a degenerate tree is as deep as it is large,
        // and recursion that deep would overflow the stack. We repeatedly
        // detach the root and push its children onto a list threaded through
        // the `right` pointers of nodes that are waiting to be freed.
        var pending = self.root;
        while (pending) |node| {
            var next = node.right;
            if (node.left) |left| {
                // Hang the rest of the pending list below the rightmost node
                // of the left subtree, then continue with the left subtree.
                var rightmost = left;
                while (rightmost.right) |r| rightmost = r;
                rightmost.right = next;
                next = left;
            }
            allocator.destroy(node);
            pending = next;
        }
        self.* = .empty;
    }

    pub fn get(self: *const Bst, key: u64) ?u64 {
        var trace: cost.Trace = .{};
        return self.getTraced(key, &trace);
    }

    /// `get` that also reports what the lookup cost: one comparison and one
    /// page read per node on the path.
    pub fn getTraced(self: *const Bst, key: u64, trace: *cost.Trace) ?u64 {
        var current = self.root;
        while (current) |node| {
            trace.comparisons += 1;
            trace.page_reads += 1; // model: every node lives on its own page
            switch (std.math.order(key, node.key)) {
                .eq => return node.value,
                .lt => current = node.left,
                .gt => current = node.right,
            }
        }
        return null;
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    /// On error.OutOfMemory the tree is unchanged.
    pub fn put(self: *Bst, allocator: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
        // `link` points at the pointer we would have to change: first the
        // root field, then the left or right field of some node. When it
        // points at null we have found the place where the key belongs.
        var link: *?*Node = &self.root;
        while (link.*) |node| {
            switch (std.math.order(key, node.key)) {
                .eq => {
                    const old = node.value;
                    node.value = value;
                    return old;
                },
                .lt => link = &node.left,
                .gt => link = &node.right,
            }
        }
        // Allocate last: if this fails, nothing has been modified yet.
        const node = try allocator.create(Node);
        node.* = .{ .key = key, .value = value };
        link.* = node; // the only write to existing memory: one pointer
        self.len += 1;
        return null;
    }

    /// Remove a key. Returns the removed value, or null if it was absent.
    pub fn delete(self: *Bst, allocator: Allocator, key: u64) ?u64 {
        var link: *?*Node = &self.root;
        const node = while (link.*) |candidate| {
            switch (std.math.order(key, candidate.key)) {
                .eq => break candidate,
                .lt => link = &candidate.left,
                .gt => link = &candidate.right,
            }
        } else return null;
        const old = node.value;

        if (node.left != null and node.right != null) {
            // Two children: the node cannot simply be cut out. Replace its
            // entry by its successor (the smallest key of the right subtree,
            // found by going left as far as possible) and cut out the
            // successor's node instead, which has no left child.
            var successor_link: *?*Node = &node.right;
            while (successor_link.*.?.left != null) successor_link = &successor_link.*.?.left;
            const successor = successor_link.*.?;
            node.key = successor.key;
            node.value = successor.value;
            successor_link.* = successor.right;
            allocator.destroy(successor);
        } else {
            // At most one child: that child (or null) takes the node's place.
            link.* = node.left orelse node.right;
            allocator.destroy(node);
        }
        self.len -= 1;
        return old;
    }

    // `range`, `height` and `validate` have to visit a whole subtree, so they
    // must remember where to continue after finishing one side. Recursion
    // remembers that on the call stack, one frame per level, and an
    // unbalanced tree can have as many levels as it has nodes: 20000 nodes
    // inserted in ascending order would need 20000 frames. All three
    // therefore keep the pending work in an ArrayList on the heap, which can
    // grow as long as there is memory. That is why they take an allocator.

    /// Append all entries with lo <= key < hi to `out`, ascending.
    pub fn range(self: *const Bst, allocator: Allocator, lo: u64, hi: u64, out: *std.ArrayList(Entry)) Allocator.Error!void {
        // In-order walk. `pending` holds the nodes whose left subtree is
        // being visited: their own entry and their right subtree come later.
        var pending: std.ArrayList(*const Node) = .empty;
        defer pending.deinit(allocator);
        var current: ?*const Node = self.root;
        while (true) {
            while (current) |node| {
                if (node.key < lo) {
                    // The node and its whole left subtree are below the range.
                    current = node.right;
                } else {
                    try pending.append(allocator, node);
                    // Keys equal to `lo` cannot have anything useful on the left.
                    current = if (lo < node.key) node.left else null;
                }
            }
            const node = pending.pop() orelse break;
            // Everything still pending is larger than this node: stop early.
            if (node.key >= hi) break;
            try out.append(allocator, .{ .key = node.key, .value = node.value });
            current = node.right;
        }
    }

    /// Number of nodes on the longest path from the root down (0 if empty).
    /// This is the worst-case number of page reads for one lookup.
    pub fn height(self: *const Bst, allocator: Allocator) Allocator.Error!usize {
        const Pending = struct { node: *const Node, depth: usize };
        var pending: std.ArrayList(Pending) = .empty;
        defer pending.deinit(allocator);
        if (self.root) |root| try pending.append(allocator, .{ .node = root, .depth = 1 });
        var deepest: usize = 0;
        while (pending.pop()) |item| {
            deepest = @max(deepest, item.depth);
            if (item.node.left) |left| try pending.append(allocator, .{ .node = left, .depth = item.depth + 1 });
            if (item.node.right) |right| try pending.append(allocator, .{ .node = right, .depth = item.depth + 1 });
        }
        return deepest;
    }

    pub const ValidateError = error{ KeyOutOfOrder, CountMismatch };

    /// Check the search-tree invariant and that `len` matches the node count.
    pub fn validate(self: *const Bst, allocator: Allocator) (ValidateError || Allocator.Error)!void {
        // Every key in the subtree below `node` must lie strictly between
        // `low` and `high` (null = unbounded).
        const Pending = struct { node: *const Node, low: ?u64, high: ?u64 };
        var pending: std.ArrayList(Pending) = .empty;
        defer pending.deinit(allocator);
        if (self.root) |root| try pending.append(allocator, .{ .node = root, .low = null, .high = null });
        var count: usize = 0;
        while (pending.pop()) |item| {
            const node = item.node;
            if (item.low) |low| if (node.key <= low) return error.KeyOutOfOrder;
            if (item.high) |high| if (node.key >= high) return error.KeyOutOfOrder;
            count += 1;
            // Going left tightens the upper bound, going right the lower one.
            if (node.left) |left| try pending.append(allocator, .{ .node = left, .low = item.low, .high = node.key });
            if (node.right) |right| try pending.append(allocator, .{ .node = right, .low = node.key, .high = item.high });
        }
        if (count != self.len) return error.CountMismatch;
    }

    /// How many distinct 4096-byte pages of REAL memory hold the nodes on the
    /// search path for `key`? This looks at actual addresses, so the answer
    /// depends on the allocator that produced the nodes: that is the point.
    pub fn pagesOnPath(self: *const Bst, key: u64) u64 {
        var trace: cost.Trace = .{};
        var current = self.root;
        while (current) |node| {
            // A path longer than 64 nodes would overflow `seen`; stop there.
            if (trace.page_reads == trace.seen.len) break;
            trace.touch(@intFromPtr(node) / cost.page_size);
            switch (std.math.order(key, node.key)) {
                .eq => break,
                .lt => current = node.left,
                .gt => current = node.right,
            }
        }
        return trace.page_reads;
    }
};

// ----------------------------------------------------------------- tests ---

const testing = std.testing;
const ops = @import("ops.zig");

/// The guide's canonical keys (chapters 03 to 08 insert the same sequence).
const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

test "put, get and node visits on the canonical keys" {
    const allocator = testing.allocator;
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    for (canonical) |k| try testing.expectEqual(null, try tree.put(allocator, k, k * 10));
    try tree.validate(allocator);
    try testing.expectEqual(12, tree.len);
    try testing.expectEqual(5, try tree.height(allocator));

    // 10 -> 20 -> 12 -> 17: four nodes, four page reads.
    var trace: cost.Trace = .{};
    try testing.expectEqual(170, tree.getTraced(17, &trace));
    try testing.expectEqual(4, trace.page_reads);

    try testing.expectEqual(null, tree.get(18));
    try testing.expectEqual(170, try tree.put(allocator, 17, 1));
    try testing.expectEqual(12, tree.len);
}

test "ascending inserts degenerate into a linked list" {
    const allocator = testing.allocator;
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    for (0..500) |i| _ = try tree.put(allocator, i, i);
    try tree.validate(allocator);
    try testing.expectEqual(500, try tree.height(allocator));
    var trace: cost.Trace = .{};
    _ = tree.getTraced(499, &trace);
    try testing.expectEqual(500, trace.page_reads);
}

/// Build a deep tree directly, without `put` (which would walk the whole
/// chain for every key). `spine` nodes hang below each other; with
/// `.right_chain` and `.left_chain` that is all. With `.caterpillar` every
/// spine node also gets a leaf as its left child, which is what inserting
/// 2, 1, 4, 3, 6, 5, ... (nearly sorted input) produces: no long chain of
/// single children anywhere, but still `spine` levels.
const Shape = enum { right_chain, left_chain, caterpillar };

fn buildDeep(allocator: Allocator, spine: u64, shape: Shape) !Bst {
    var tree: Bst = .empty;
    var link: *?*Bst.Node = &tree.root;
    for (0..spine) |i| {
        const node = try allocator.create(Bst.Node);
        // Keys 1, 3, 5, ... going down (descending for the left chain).
        const rank = if (shape == .left_chain) spine - 1 - i else i;
        node.* = .{ .key = rank * 2 + 1, .value = i };
        link.* = node;
        tree.len += 1;
        if (shape == .caterpillar) {
            const leaf = try allocator.create(Bst.Node);
            leaf.* = .{ .key = rank * 2, .value = i };
            node.left = leaf;
            tree.len += 1;
        }
        link = if (shape == .left_chain) &node.left else &node.right;
    }
    return tree;
}

test "deinit, height, validate and range survive very deep trees" {
    // Regression test. Recursive versions of these functions overflowed the
    // stack: Rust at 20000 levels, Zig at 100000 (validate on the
    // caterpillar) and 1000000 (range on a chain). The arena makes a million
    // small allocations cheap; testing.allocator below it still catches leaks.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = testing.allocator;
    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(allocator);

    const cases = [_]struct { shape: Shape, spine: u64, nodes: usize }{
        .{ .shape = .right_chain, .spine = 1_000_000, .nodes = 1_000_000 },
        .{ .shape = .left_chain, .spine = 1_000_000, .nodes = 1_000_000 },
        .{ .shape = .caterpillar, .spine = 200_000, .nodes = 400_000 },
    };
    for (cases) |case| {
        const tree = try buildDeep(arena.allocator(), case.spine, case.shape);
        try testing.expectEqual(case.nodes, tree.len);
        try tree.validate(allocator);
        const expected_height = case.spine + @intFromBool(case.shape == .caterpillar);
        try testing.expectEqual(expected_height, try tree.height(allocator));

        out.clearRetainingCapacity();
        try tree.range(allocator, 0, std.math.maxInt(u64), &out);
        try testing.expectEqual(case.nodes, out.items.len);
        for (out.items[0 .. out.items.len - 1], out.items[1..]) |a, b| try testing.expect(a.key < b.key);

        // A narrow range deep inside the tree: keys 1000, 1001, 1002.
        out.clearRetainingCapacity();
        try tree.range(allocator, 1000, 1003, &out);
        const want: usize = if (case.shape == .caterpillar) 3 else 1; // chains hold odd keys only
        try testing.expectEqual(want, out.items.len);
    }
}

test "deinit frees a very deep tree node by node" {
    // The same shapes without an arena, so that `deinit` itself is tested.
    const allocator = testing.allocator;
    for ([_]Shape{ .right_chain, .left_chain, .caterpillar }) |shape| {
        var tree = try buildDeep(allocator, 20_000, shape);
        defer tree.deinit(allocator);
        try tree.validate(allocator);
    }
}

test "range prunes: bounds, empty and inverted ranges" {
    const allocator = testing.allocator;
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    for (canonical) |k| _ = try tree.put(allocator, k, k * 10);
    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(allocator);

    const cases = [_]struct { lo: u64, hi: u64, want: []const u64 }{
        .{ .lo = 6, .hi = 17, .want = &.{ 6, 7, 10, 12, 15 } }, // lo included, hi excluded
        .{ .lo = 8, .hi = 9, .want = &.{} },
        .{ .lo = 20, .hi = 5, .want = &.{} }, // inverted
        .{ .lo = 10, .hi = 10, .want = &.{} },
        .{ .lo = 30, .hi = std.math.maxInt(u64), .want = &.{30} },
        .{ .lo = 0, .hi = 2, .want = &.{1} },
    };
    for (cases) |case| {
        out.clearRetainingCapacity();
        try tree.range(allocator, case.lo, case.hi, &out);
        try testing.expectEqual(case.want.len, out.items.len);
        for (case.want, out.items) |w, e| try testing.expectEqual(w, e.key);
    }
}

fn walkAll(allocator: Allocator) !void {
    // Insert order 2, 1, 4, 3, ...: a small caterpillar, built with a
    // separate allocator so that only the three walks are under test.
    var tree: Bst = .empty;
    defer tree.deinit(testing.allocator);
    for (0..12) |i| _ = try tree.put(testing.allocator, i ^ 1, i);
    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(allocator);
    try tree.validate(allocator);
    try testing.expectEqual(7, try tree.height(allocator));
    try tree.range(allocator, 0, 100, &out);
    try testing.expectEqual(12, out.items.len);
}

test "range, height and validate under every possible allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, walkAll, .{});
}

test "delete: leaf, one child, two children, root" {
    const allocator = testing.allocator;
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    for (canonical) |k| _ = try tree.put(allocator, k, k * 10);

    try testing.expectEqual(10, tree.delete(allocator, 1)); // leaf
    try testing.expectEqual(60, tree.delete(allocator, 6)); // one child (7)
    try testing.expectEqual(200, tree.delete(allocator, 20)); // two children
    try testing.expectEqual(100, tree.delete(allocator, 10)); // the root
    try testing.expectEqual(null, tree.delete(allocator, 10));
    try tree.validate(allocator);
    try testing.expectEqual(8, tree.len);
    try testing.expectEqual(12, tree.root.?.key); // successor of 10 moved up

    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(allocator);
    try tree.range(allocator, 0, 100, &out);
    const want = [_]u64{ 3, 5, 7, 12, 15, 17, 25, 30 };
    try testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, e| try testing.expectEqual(w, e.key);
}

test "validate rejects a tree that breaks the ordering" {
    var right: Bst.Node = .{ .key = 5, .value = 0 }; // 5 on the right of 10
    var root: Bst.Node = .{ .key = 10, .value = 0, .right = &right };
    var tree: Bst = .{ .root = &root, .len = 2 };
    try testing.expectError(error.KeyOutOfOrder, tree.validate(testing.allocator));
    right.key = 11;
    try tree.validate(testing.allocator);
    tree.len = 3;
    try testing.expectError(error.CountMismatch, tree.validate(testing.allocator));
}

test "put that fails to allocate leaves the tree unchanged" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 3 });
    const allocator = failing.allocator();
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    for ([_]u64{ 2, 1, 3 }) |k| _ = try tree.put(allocator, k, k);
    try testing.expectError(error.OutOfMemory, tree.put(allocator, 4, 4));
    try tree.validate(testing.allocator); // not the failing one: validate allocates too
    try testing.expectEqual(3, tree.len);
    try testing.expectEqual(null, tree.get(4));
    // Overwriting allocates nothing, so it works even when memory is gone.
    try testing.expectEqual(3, try tree.put(allocator, 3, 33));
}

fn putMany(allocator: Allocator, count: u64) !void {
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    for (0..count) |i| {
        _ = try tree.put(allocator, (i * 7) % count, i);
        try tree.validate(allocator);
    }
}

test "put under every possible allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, putMany, .{@as(u64, 25)});
}

test "page_allocator puts every node on its own page" {
    const allocator = std.heap.page_allocator;
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    for (canonical) |k| _ = try tree.put(allocator, k, k);
    try testing.expectEqual(4, tree.pagesOnPath(17)); // 4 nodes, 4 pages

    // The same tree in one page-aligned buffer: the whole path is one page.
    var buffer: [canonical.len * @sizeOf(Bst.Node)]u8 align(cost.page_size) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);
    var packed_tree: Bst = .empty; // no deinit: the buffer is on the stack
    for (canonical) |k| _ = try packed_tree.put(fba.allocator(), k, k);
    try testing.expectEqual(1, packed_tree.pagesOnPath(17));
}

test "model test against the oracle" {
    const allocator = testing.allocator;
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(allocator);
    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(allocator);

    var stream = ops.OpStream.init(.{ .seed = 2, .count = 5000, .key_space = 200 });
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| try testing.expectEqual(try oracle.put(allocator, p.key, p.value), try tree.put(allocator, p.key, p.value)),
            .delete => |d| try testing.expectEqual(oracle.delete(d.key), tree.delete(allocator, d.key)),
            .get => |g| try testing.expectEqual(oracle.get(g.key), tree.get(g.key)),
            .range => |r| {
                out.clearRetainingCapacity();
                try tree.range(allocator, r.lo, r.hi, &out);
                const want = oracle.range(r.lo, r.hi);
                try testing.expectEqual(want.len, out.items.len);
                for (want, out.items) |w, g| {
                    try testing.expectEqual(w.key, g.key);
                    try testing.expectEqual(w.value, g.value);
                }
            },
        }
        try tree.validate(allocator);
        try testing.expectEqual(oracle.len(), tree.len);
    }
}
