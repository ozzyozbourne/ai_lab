//! SECTION D: how many keys fit in a tree of height h, and the other way
//! round. The proof is in the README ("The height bound"); this file is the
//! arithmetic, so that the README's numbers are printed by a program.
//!
//! M is a run-time number here (not `comptime`), because the functions only
//! compute with it. Results saturate at maxInt(u64) instead of overflowing.
const std = @import("std");

const max_u64 = std.math.maxInt(u64);

/// t = ceil(M/2): the fewest children of an interior node that is not the root.
pub fn minChildren(m: u64) u64 {
    return (m + 1) / 2;
}

fn power(base: u64, exponent: usize) u64 {
    var result: u64 = 1;
    for (0..exponent) |_| result = std.math.mul(u64, result, base) catch max_u64;
    return result;
}

/// Fewest keys in a tree of `height` levels: 2 * t^(height-1) - 1.
/// (The root has 1 key and 2 children; every other node has t - 1 keys.)
pub fn minKeys(m: u64, height: usize) u64 {
    if (height == 0) return 0;
    const half = power(minChildren(m), height - 1);
    return (std.math.mul(u64, 2, half) catch max_u64) - 1;
}

/// Most keys in a tree of `height` levels: M^height - 1 (every node full).
pub fn maxKeys(m: u64, height: usize) u64 {
    return power(m, height) - 1;
}

/// Shortest tree that can hold n keys: the smallest h with M^h - 1 >= n.
pub fn minHeight(m: u64, n: u64) usize {
    var h: usize = 0;
    while (maxKeys(m, h) < n) h += 1;
    return h;
}

/// Tallest tree that n keys can form: the largest h with 2 * t^(h-1) - 1 <= n.
pub fn maxHeight(m: u64, n: u64) usize {
    if (n == 0) return 0;
    var h: usize = 1;
    while (minKeys(m, h + 1) <= n) h += 1;
    return h;
}

test "key counts per height for M = 4" {
    try std.testing.expectEqual(2, minChildren(4));
    try std.testing.expectEqual(2, minChildren(3));
    try std.testing.expectEqual(3, minChildren(5));
    const want = [_][2]u64{ .{ 0, 0 }, .{ 1, 3 }, .{ 3, 15 }, .{ 7, 63 }, .{ 15, 255 } };
    for (want, 0..) |pair, h| {
        try std.testing.expectEqual(pair[0], minKeys(4, h));
        try std.testing.expectEqual(pair[1], maxKeys(4, h));
    }
}

test "height bounds: the README's worked example" {
    // One million keys, M = 4 (t = 2): at most 1 + floor(log2(500000.5)) = 19 levels.
    try std.testing.expectEqual(19, maxHeight(4, 1_000_000));
    try std.testing.expectEqual(10, minHeight(4, 1_000_000));
    // M = 256 (t = 128): 128^2 = 16384 <= 500000.5 < 128^3, so exactly 3 levels.
    try std.testing.expectEqual(3, maxHeight(256, 1_000_000));
    try std.testing.expectEqual(3, minHeight(256, 1_000_000));
    try std.testing.expectEqual(0, maxHeight(4, 0));
    try std.testing.expectEqual(0, minHeight(4, 0));
    try std.testing.expectEqual(1, maxHeight(4, 2));
    try std.testing.expectEqual(2, maxHeight(4, 3)); // 3 keys may already be root + 2 leaves
    try std.testing.expectEqual(2, minHeight(4, 4)); // 4 keys no longer fit in one node
}

test "the two bounds are consistent, and huge inputs saturate instead of overflowing" {
    for ([_]u64{ 3, 4, 5, 16, 255, 256 }) |m| {
        for (0..2000) |n| {
            const lo = minHeight(m, n);
            const hi = maxHeight(m, n);
            try std.testing.expect(lo <= hi);
            // n lies in the key range of both extreme heights.
            try std.testing.expect(minKeys(m, hi) <= n and n <= maxKeys(m, lo));
        }
    }
    try std.testing.expectEqual(max_u64 - 1, maxKeys(1024, 100));
    try std.testing.expect(maxHeight(4, max_u64) >= 63);
}
