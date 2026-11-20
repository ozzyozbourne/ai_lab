//! Why a B-tree cannot index 2-D points for nearness: flatten the plane into
//! one sorted order and measure how far apart touching cells end up.
//!
//! Two orders over a side x side grid:
//!   row-major: position = y * side + x          (sort by y, then x)
//!   Z-order:   position = interleaved bits of x and y (Morton code)
//! For every pair of cells that touch (share an edge) we take the distance
//! between their positions in the order. In a B-tree that distance is "how
//! many keys lie between them", i.e. how long a range scan must be to reach
//! one from the other.
const std = @import("std");

/// Morton code: bit i of x goes to bit 2i, bit i of y to bit 2i+1.
pub fn interleave(x: u16, y: u16) u32 {
    var z: u32 = 0;
    for (0..16) |i| {
        const from: u4 = @intCast(i);
        const to: u5 = @intCast(2 * i);
        z |= @as(u32, (x >> from) & 1) << to;
        z |= @as(u32, (y >> from) & 1) << (to + 1);
    }
    return z;
}

pub fn rowMajor(side: u32, x: u16, y: u16) u32 {
    return @as(u32, y) * side + x;
}

pub const Curve = enum { row_major, z_order };

pub const GapStats = struct {
    /// Touching pairs: 2 * side * (side - 1).
    pairs: u32 = 0,
    /// Pairs whose positions differ by at least `side`.
    far_pairs: u32 = 0,
    max_gap: u32 = 0,
    sum_gap: u64 = 0,
};

pub fn gapStats(curve: Curve, side: u32) GapStats {
    std.debug.assert(side >= 2 and side <= 256);
    var stats: GapStats = .{};
    for (0..side) |yi| {
        for (0..side) |xi| {
            const x: u16 = @intCast(xi);
            const y: u16 = @intCast(yi);
            const here = position(curve, side, x, y);
            if (xi + 1 < side) record(&stats, side, here, position(curve, side, x + 1, y));
            if (yi + 1 < side) record(&stats, side, here, position(curve, side, x, y + 1));
        }
    }
    return stats;
}

fn position(curve: Curve, side: u32, x: u16, y: u16) u32 {
    return switch (curve) {
        .row_major => rowMajor(side, x, y),
        .z_order => interleave(x, y),
    };
}

fn record(stats: *GapStats, side: u32, a: u32, b: u32) void {
    const gap = @max(a, b) - @min(a, b);
    stats.pairs += 1;
    stats.sum_gap += gap;
    stats.max_gap = @max(stats.max_gap, gap);
    if (gap >= side) stats.far_pairs += 1;
}

const testing = std.testing;

test "interleave: known Morton codes" {
    try testing.expectEqual(0, interleave(0, 0));
    try testing.expectEqual(1, interleave(1, 0));
    try testing.expectEqual(2, interleave(0, 1));
    try testing.expectEqual(3, interleave(1, 1));
    try testing.expectEqual(0b100111, interleave(0b011, 0b101));
    try testing.expectEqual(0xFFFF_FFFF, interleave(0xFFFF, 0xFFFF));
}

test "Z-order is a bijection on the grid" {
    var seen: [64]bool = @splat(false);
    for (0..8) |y| for (0..8) |x| {
        const z = interleave(@intCast(x), @intCast(y));
        try testing.expect(!seen[z]);
        seen[z] = true;
    };
}

test "no order keeps all touching cells close" {
    for ([_]u32{ 4, 8, 16, 32 }) |side| {
        const rm = gapStats(.row_major, side);
        const z = gapStats(.z_order, side);
        try testing.expectEqual(2 * side * (side - 1), rm.pairs);
        try testing.expectEqual(rm.pairs, z.pairs);
        // Row-major: every vertical pair is exactly `side` apart.
        try testing.expectEqual(side, rm.max_gap);
        try testing.expectEqual(side * (side - 1), rm.far_pairs);
        // Z-order: fewer far pairs, but the worst one is much worse.
        try testing.expect(z.far_pairs < rm.far_pairs);
        try testing.expect(z.max_gap > rm.max_gap);
        try testing.expect(z.far_pairs > 0);
    }
}
