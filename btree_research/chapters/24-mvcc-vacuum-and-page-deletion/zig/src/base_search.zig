// Copied from chapters/07-bplus-trees/zig/src/search.zig, trimmed to the
// binary searches inside one node (the descent lives in index.zig here).
//! Search inside one node. Keys are the packed (user key, tid) index keys of
//! base_node.zig; they are unique, so the rules of chapter 07 apply unchanged.
const std = @import("std");

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
    try std.testing.expectEqual(1, childIndex(&.{ 10, 20 }, 10));
}
