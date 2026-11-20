// Copied from chapters/05-deletion-and-rebalancing/zig/src/search.zig; do not edit here.
// Trimmed: `range` and its tests are left out (range scans are chapter 08).
//! SECTION 3: search and ordered traversal (explained in chapter 03).
//!
//! Nothing here allocates or modifies the tree. This file needs only
//! node.zig.
const std = @import("std");
const Node = @import("base_node.zig").Node;

/// Index of the first key that is >= `key` (chapter 02). For a key that is
/// absent this is both the place where it would be inserted and the index of
/// the child whose subtree would contain it.
pub fn lowerBound(keys: []const u64, key: u64) usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Walk down from the root: one node per level.
pub fn get(comptime M: usize, root: ?*const Node(M), key: u64) ?u64 {
    var node = root orelse return null;
    while (true) {
        const i = lowerBound(node.keySlice(), key);
        if (i < node.len and node.keys[i] == key) return node.values[i];
        if (node.leaf) return null;
        node = node.children[i].?;
    }
}

/// In-order traversal: child 0, key 0, child 1, key 1, ..., last child.
/// Calls `visitor.visit(key, value)` for every entry in ascending key order.
pub fn inOrder(comptime M: usize, root: ?*const Node(M), visitor: anytype) void {
    const node = root orelse return;
    for (0..node.len + 1) |i| {
        if (!node.leaf) inOrder(M, node.children[i], visitor);
        if (i < node.len) visitor.visit(node.keys[i], node.values[i]);
    }
}

test "lowerBound" {
    const keys = [_]u64{ 10, 20, 30 };
    try std.testing.expectEqual(0, lowerBound(&keys, 5));
    try std.testing.expectEqual(0, lowerBound(&keys, 10));
    try std.testing.expectEqual(1, lowerBound(&keys, 11));
    try std.testing.expectEqual(2, lowerBound(&keys, 30));
    try std.testing.expectEqual(3, lowerBound(&keys, 31));
    try std.testing.expectEqual(0, lowerBound(&.{}, 1));
}

test "get and inOrder on a tree built by hand" {
    //            [20]
    //     [5 10]      [30 40]
    const N = Node(4);
    var left: N = .{ .leaf = true };
    left.insertEntry(0, 5, 50);
    left.insertEntry(1, 10, 100);
    var right: N = .{ .leaf = true };
    right.insertEntry(0, 30, 300);
    right.insertEntry(1, 40, 400);
    var root: N = .{ .leaf = false };
    root.children[0] = &left;
    root.insertChild(1, &right);
    root.insertEntry(0, 20, 200);

    try std.testing.expectEqual(200, get(4, &root, 20)); // found in the interior node
    try std.testing.expectEqual(400, get(4, &root, 40));
    try std.testing.expectEqual(null, get(4, &root, 25));
    try std.testing.expectEqual(null, get(4, null, 25));

    const Collect = struct {
        keys: [8]u64 = undefined,
        n: usize = 0,
        fn visit(self: *@This(), key: u64, value: u64) void {
            std.debug.assert(value == key * 10);
            self.keys[self.n] = key;
            self.n += 1;
        }
    };
    var all: Collect = .{};
    inOrder(4, &root, &all);
    try std.testing.expectEqualSlices(u64, &.{ 5, 10, 20, 30, 40 }, all.keys[0..all.n]);
}
