//! Range bounds: the nine combinations of {unbounded, included, excluded} for
//! the two ends of a range, and "prefix scan" expressed as such a range.
//!
//! The one rule of this file: an excluded bound is NEVER rewritten as an
//! included bound on `key + 1` (or `key - 1`). That trick overflows at the
//! largest key, and it does not exist at all for byte-string keys (there is
//! no "next string" you can compute cheaply in general). Instead the kind of
//! the bound picks the comparison: `>=` or `>`, `<=` or `<`.
const std = @import("std");
const assert = std.debug.assert;

pub const Bound = union(enum) {
    unbounded,
    included: u64,
    excluded: u64,
};

pub const Direction = enum { forward, backward };

/// Is `key` on the inside of the lower bound?
pub fn aboveLower(lo: Bound, key: u64) bool {
    return switch (lo) {
        .unbounded => true,
        .included => |k| key >= k,
        .excluded => |k| key > k,
    };
}

/// Is `key` on the inside of the upper bound?
pub fn belowUpper(hi: Bound, key: u64) bool {
    return switch (hi) {
        .unbounded => true,
        .included => |k| key <= k,
        .excluded => |k| key < k,
    };
}

/// The definition of a range, used as the specification in tests: a scan
/// must return exactly the entries for which this is true, in key order.
pub fn contains(lo: Bound, hi: Bound, key: u64) bool {
    return aboveLower(lo, key) and belowUpper(hi, key);
}

pub const Range = struct { lo: Bound, hi: Bound };

/// All keys whose top `prefix_bits` bits equal `prefix`, as a range.
///
/// With composite keys (chapter 07: `user_key << 32 | row_id`) "all rows of
/// user key 7" is `prefixRange(7, 32)`. The range is [first key with the
/// prefix, first key of the NEXT prefix). The next prefix is `prefix + 1`,
/// unless the prefix is all ones: then nothing sorts after it and the upper
/// bound is simply absent. For byte strings the same idea is "increment the
/// last byte that is not 0xFF and cut the string there".
pub fn prefixRange(prefix: u64, prefix_bits: u7) Range {
    assert(prefix_bits >= 1 and prefix_bits <= 64);
    const shift: u6 = @intCast(64 - @as(u8, prefix_bits));
    const largest_prefix = @as(u64, std.math.maxInt(u64)) >> shift;
    assert(prefix <= largest_prefix); // the prefix must fit in prefix_bits
    return .{
        .lo = .{ .included = prefix << shift },
        .hi = if (prefix == largest_prefix) .unbounded else .{ .excluded = (prefix + 1) << shift },
    };
}

test "contains: the nine combinations around 10..20" {
    const lows = [_]Bound{ .unbounded, .{ .included = 10 }, .{ .excluded = 10 } };
    const highs = [_]Bound{ .unbounded, .{ .included = 20 }, .{ .excluded = 20 } };
    // For each (lo, hi): which of the probe keys 9, 10, 15, 20, 21 are inside.
    const probes = [_]u64{ 9, 10, 15, 20, 21 };
    const expected = [3][3][5]bool{
        .{ .{ true, true, true, true, true }, .{ true, true, true, true, false }, .{ true, true, true, false, false } },
        .{ .{ false, true, true, true, true }, .{ false, true, true, true, false }, .{ false, true, true, false, false } },
        .{ .{ false, false, true, true, true }, .{ false, false, true, true, false }, .{ false, false, true, false, false } },
    };
    for (lows, 0..) |lo, i| for (highs, 0..) |hi, j| for (probes, 0..) |p, k| {
        try std.testing.expectEqual(expected[i][j][k], contains(lo, hi, p));
    };
}

test "contains: the ends of the key space need no special case" {
    const max = std.math.maxInt(u64);
    try std.testing.expect(contains(.{ .included = max }, .unbounded, max));
    try std.testing.expect(!contains(.{ .excluded = max }, .unbounded, max)); // "key > max": nothing
    try std.testing.expect(contains(.unbounded, .{ .included = 0 }, 0));
    try std.testing.expect(!contains(.unbounded, .{ .excluded = 0 }, 0)); // "key < 0": nothing
    // An inverted or degenerate range is just empty.
    try std.testing.expect(!contains(.{ .included = 20 }, .{ .included = 10 }, 15));
    try std.testing.expect(!contains(.{ .excluded = 10 }, .{ .excluded = 10 }, 10));
    try std.testing.expect(contains(.{ .included = 10 }, .{ .included = 10 }, 10));
}

test "prefixRange: next prefix as exclusive upper bound, none after all ones" {
    const r = prefixRange(7, 32);
    try std.testing.expectEqual(Bound{ .included = 7 << 32 }, r.lo);
    try std.testing.expectEqual(Bound{ .excluded = 8 << 32 }, r.hi);
    try std.testing.expect(contains(r.lo, r.hi, (7 << 32) | 0xFFFF_FFFF));
    try std.testing.expect(!contains(r.lo, r.hi, 8 << 32));

    // The largest prefix has no successor: (0xFFFFFFFF + 1) << 32 would overflow.
    const last = prefixRange(0xFFFF_FFFF, 32);
    try std.testing.expectEqual(Bound.unbounded, last.hi);
    try std.testing.expect(contains(last.lo, last.hi, std.math.maxInt(u64)));

    // A 64-bit prefix is a single key.
    const one = prefixRange(42, 64);
    try std.testing.expect(contains(one.lo, one.hi, 42));
    try std.testing.expect(!contains(one.lo, one.hi, 41) and !contains(one.lo, one.hi, 43));
}
