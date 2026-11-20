// Copied from chapters/07-bplus-trees/zig/src/search.zig; only the @import paths were renamed to base_*.
//! Search: inside one node (binary search) and from the root to a leaf.
//!
//! In a B+tree EVERY lookup ends in a leaf, even if the key equals a separator
//! on the way down: the separator is only a copy, the value is in the leaf.
const std = @import("std");
const BPlusTree = @import("base_tree.zig").BPlusTree;
const NodeId = @import("base_arena.zig").NodeId;

/// Index of the first key >= `key` (= keys.len if there is none).
/// In a leaf this is where `key` is, or where it would be inserted.
pub fn lowerBound(keys: []const u64, key: u64) usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Index of the first key > `key` (= keys.len if there is none).
pub fn upperBound(keys: []const u64, key: u64) usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] <= key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Which child of an internal node to descend into.
///
/// Child i holds keys in [keys[i-1], keys[i]), so we want the number of
/// separators that are <= key: that is the upper bound. A key EQUAL to a
/// separator goes RIGHT, because a separator is a copy of the smallest key
/// that was in the right half when the leaf split.
pub fn childIndex(separators: []const u64, key: u64) usize {
    return upperBound(separators, key);
}

/// The leaf whose key range contains `key` (whether or not the key is in it).
/// `.nil` only for an empty tree.
pub fn findLeaf(tree: *const BPlusTree, key: u64) NodeId {
    var id = tree.root;
    if (id == .nil) return .nil;
    while (true) {
        const n = tree.nodes.get(id);
        switch (n.kind) {
            .leaf => return id,
            .internal => |*in| id = in.children[childIndex(n.keySlice(), key)],
        }
    }
}

pub fn get(tree: *const BPlusTree, key: u64) ?u64 {
    const id = findLeaf(tree, key);
    if (id == .nil) return null;
    const leaf = tree.nodes.get(id);
    const i = lowerBound(leaf.keySlice(), key);
    if (i < leaf.len and leaf.keys[i] == key) return leaf.kind.leaf.values[i];
    return null;
}

test "lowerBound and upperBound differ only on equal keys" {
    const keys = [_]u64{ 10, 20, 30 };
    const probes = [_]u64{ 5, 10, 15, 20, 30, 35 };
    const lower = [_]usize{ 0, 0, 1, 1, 2, 3 };
    const upper = [_]usize{ 0, 1, 1, 2, 3, 3 };
    for (probes, lower, upper) |p, lo, up| {
        try std.testing.expectEqual(lo, lowerBound(&keys, p));
        try std.testing.expectEqual(up, upperBound(&keys, p));
    }
    try std.testing.expectEqual(0, lowerBound(&.{}, 1));
    try std.testing.expectEqual(0, upperBound(&.{}, 1));
}

test "a key equal to a separator is routed to the right child" {
    try std.testing.expectEqual(0, childIndex(&.{ 10, 20 }, 9));
    try std.testing.expectEqual(1, childIndex(&.{ 10, 20 }, 10));
    try std.testing.expectEqual(1, childIndex(&.{ 10, 20 }, 19));
    try std.testing.expectEqual(2, childIndex(&.{ 10, 20 }, 20));
}
