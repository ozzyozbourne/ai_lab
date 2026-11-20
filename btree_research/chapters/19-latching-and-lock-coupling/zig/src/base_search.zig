// Copied from chapters/07-bplus-trees/zig/src/search.zig, trimmed for chapter
// 19 to the in-node searches (the descent is rewritten per latch protocol).
//! Binary search inside one node.
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

/// Which child of an internal node to descend into: the number of separators
/// that are <= key. A key EQUAL to a separator goes RIGHT.
pub fn childIndex(separators: []const u64, key: u64) usize {
    return upperBound(separators, key);
}

test "a key equal to a separator is routed to the right child" {
    try std.testing.expectEqual(0, childIndex(&.{ 10, 20 }, 9));
    try std.testing.expectEqual(1, childIndex(&.{ 10, 20 }, 10));
    try std.testing.expectEqual(1, childIndex(&.{ 10, 20 }, 19));
    try std.testing.expectEqual(2, childIndex(&.{ 10, 20 }, 20));
    try std.testing.expectEqual(0, lowerBound(&.{}, 1));
}
