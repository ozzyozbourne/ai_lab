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

    /// Append all entries with lo <= key < hi to `out`, ascending.
    pub fn range(self: *const Bst, allocator: Allocator, lo: u64, hi: u64, out: *std.ArrayList(Entry)) Allocator.Error!void {
        try rangeNode(self.root, allocator, lo, hi, out);
    }

    fn rangeNode(maybe_node: ?*const Node, allocator: Allocator, lo: u64, hi: u64, out: *std.ArrayList(Entry)) Allocator.Error!void {
        const node = maybe_node orelse return;
        // In-order walk, pruning subtrees that cannot contain keys in range.
        if (lo < node.key) try rangeNode(node.left, allocator, lo, hi, out);
        if (lo <= node.key and node.key < hi) try out.append(allocator, .{ .key = node.key, .value = node.value });
        if (node.key < hi) try rangeNode(node.right, allocator, lo, hi, out);
    }

    /// Number of nodes on the longest path from the root down (0 if empty).
    /// This is the worst-case number of page reads for one lookup.
    pub fn height(self: *const Bst) usize {
        return heightOf(self.root);
    }

    fn heightOf(maybe_node: ?*const Node) usize {
        // Loop down chains of single children so that a degenerate tree
        // (every node has one child) needs no recursion at all.
        var depth: usize = 0;
        var current = maybe_node;
        while (current) |node| {
            depth += 1;
            if (node.left != null and node.right != null) {
                return depth + @max(heightOf(node.left), heightOf(node.right));
            }
            current = node.left orelse node.right;
        }
        return depth;
    }

    pub const ValidateError = error{ KeyOutOfOrder, CountMismatch };

    /// Check the search-tree invariant and that `len` matches the node count.
    pub fn validate(self: *const Bst) ValidateError!void {
        const count = try validateNode(self.root, null, null);
        if (count != self.len) return error.CountMismatch;
    }

    /// Every key below `node` must lie strictly between `low` and `high`
    /// (null = unbounded). Returns the number of nodes in the subtree.
    fn validateNode(maybe_node: ?*const Node, low: ?u64, high: ?u64) ValidateError!usize {
        var count: usize = 0;
        var current = maybe_node;
        var lo = low;
        var hi = high;
        // Same trick as heightOf: recurse only where the tree really forks.
        while (current) |node| {
            if (lo) |l| if (node.key <= l) return error.KeyOutOfOrder;
            if (hi) |h| if (node.key >= h) return error.KeyOutOfOrder;
            count += 1;
            if (node.left != null and node.right != null) {
                count += try validateNode(node.left, lo, node.key);
                count += try validateNode(node.right, node.key, hi);
                return count;
            }
            if (node.left) |left| {
                hi = node.key;
                current = left;
            } else {
                lo = node.key;
                current = node.right;
            }
        }
        return count;
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
    try tree.validate();
    try testing.expectEqual(12, tree.len);
    try testing.expectEqual(5, tree.height());

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
    try tree.validate();
    try testing.expectEqual(500, tree.height());
    var trace: cost.Trace = .{};
    _ = tree.getTraced(499, &trace);
    try testing.expectEqual(500, trace.page_reads);
}

test "deinit, height and validate survive a very deep tree" {
    const allocator = testing.allocator;
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    // Build a 20000-node chain directly (20000 puts would walk the chain
    // 20000 times). Recursive code would need 20000 stack frames here.
    var link: *?*Bst.Node = &tree.root;
    for (0..20_000) |i| {
        const node = try allocator.create(Bst.Node);
        node.* = .{ .key = i, .value = i };
        link.* = node;
        link = &node.right;
        tree.len += 1;
    }
    try tree.validate();
    try testing.expectEqual(20_000, tree.height());
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
    try tree.validate();
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
    try testing.expectError(error.KeyOutOfOrder, tree.validate());
    right.key = 11;
    try tree.validate();
    tree.len = 3;
    try testing.expectError(error.CountMismatch, tree.validate());
}

test "put that fails to allocate leaves the tree unchanged" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 3 });
    const allocator = failing.allocator();
    var tree: Bst = .empty;
    defer tree.deinit(allocator);
    for ([_]u64{ 2, 1, 3 }) |k| _ = try tree.put(allocator, k, k);
    try testing.expectError(error.OutOfMemory, tree.put(allocator, 4, 4));
    try tree.validate();
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
        try tree.validate();
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
        try tree.validate();
        try testing.expectEqual(oracle.len(), tree.len);
    }
}
