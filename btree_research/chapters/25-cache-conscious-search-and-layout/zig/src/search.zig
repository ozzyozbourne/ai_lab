//! Four ways to find the lower bound in a sorted `[]const u64`.
//!
//! Every function returns the same thing chapter 02 called the insertion
//! index: the number of keys strictly less than `key` (so `keys.len` when all
//! keys are smaller). They differ only in which keys they look at, in what
//! order, and in whether the CPU has to guess a branch.
const std = @import("std");
const trace = @import("trace.zig");

/// The oracle: count the smaller keys one by one. Obviously correct.
pub fn lowerBoundLinear(keys: []const u64, key: u64) usize {
    var count: usize = 0;
    for (keys) |k| count += @intFromBool(k < key);
    return count;
}

/// Chapter 02's loop. Invariant: every key left of `lo` is < key, every key
/// at or right of `hi` is >= key. The `if` is a data-dependent branch: for
/// random needles the predictor is wrong about half the time, and the number
/// of iterations depends on the path taken.
pub fn lowerBoundClassic(keys: []const u64, key: u64, tracer: anytype) usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        tracer.cmp(mid);
        if (keys[mid] < key) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// How the halving loop moves `offset`. All three compare exactly the same
/// keys in the same order; only the machine code may differ.
///
///   * `branch`: a plain `if`. The compiler usually emits a conditional jump.
///   * `arithmetic`: `offset += half * (0 or 1)`. Looks branch-free in the
///     source, but the optimiser recognises the pattern and is free to turn
///     it back into a jump (LLVM did, when we looked: see the README).
///   * `hinted`: an `if` expression whose taken arm starts with
///     `@branchHint(.unpredictable)`. This tells the compiler what the
///     arithmetic trick only implies, and is what produced a conditional
///     move (`cmov`) on x86-64. TigerBeetle uses the same hint.
pub const Select = enum { branch, arithmetic, hinted };

/// The "offset + length" binary search (the shape of TigerBeetle's
/// `binary_search_values_upsert_index`). The window is `[offset, offset+length)`
/// and `length` shrinks by `half` on EVERY iteration whichever way the
/// comparison goes. Consequences:
///
///   * the trip count depends only on `keys.len` (see `halvingComparisons`),
///     so the loop branch is perfectly predictable;
///   * the comparison only decides whether `offset` moves, which can be a
///     conditional move instead of a jump (see `Select`);
///   * both possible next probes are known one step ahead, so they can be
///     prefetched.
///
/// Invariant: keys[offset - 1] < key (or offset == 0), and
/// key <= keys[offset + length] (or offset + length == keys.len).
pub fn lowerBoundHalving(
    comptime select: Select,
    comptime prefetch: bool,
    keys: []const u64,
    key: u64,
    tracer: anytype,
) usize {
    if (keys.len == 0) return 0;
    var offset: usize = 0;
    var length: usize = keys.len;
    while (length > 1) {
        const half = length / 2;
        const mid = offset + half;
        if (prefetch) {
            // The next iteration will compare keys[offset + next_half] or
            // keys[mid + next_half]. Ask for both lines now: one of the two
            // hints is always wasted, which is the price of not knowing yet.
            // Both indexes are inside the current window, so `&keys[...]` is
            // in bounds. A prefetch never faults and never changes results.
            const next_half = (length - half) / 2;
            @prefetch(&keys[offset + next_half], .{ .rw = .read, .locality = 0, .cache = .data });
            @prefetch(&keys[mid + next_half], .{ .rw = .read, .locality = 0, .cache = .data });
            tracer.prefetch(offset + next_half);
            tracer.prefetch(mid + next_half);
        }
        tracer.cmp(mid);
        const take_upper = keys[mid] < key;
        switch (select) {
            .branch => if (take_upper) {
                offset = mid;
            },
            .arithmetic => offset += half * @intFromBool(take_upper),
            .hinted => offset = if (take_upper) blk: {
                @branchHint(.unpredictable); // must be the first statement of the arm
                break :blk mid;
            } else offset,
        }
        length -= half;
    }
    // One key is left in the window. It is the answer unless it is too small.
    tracer.cmp(offset);
    return offset + @intFromBool(keys[offset] < key);
}

/// Comparisons made by `lowerBoundHalving` for an array of `n` keys:
/// ceil(log2(n)) halvings plus the final check. Independent of the needle.
pub fn halvingComparisons(n: usize) u32 {
    if (n == 0) return 0;
    return std.math.log2_int_ceil(usize, n) + 1;
}

/// Rank of `key` inside one 8-key block: how many of the 8 keys are smaller.
/// One vector compare gives 8 booleans; packed into a byte, the number of set
/// bits is the answer. No loop, no branch, one 64-byte line.
pub fn rank8(block: *const [trace.lanes]u64, key: u64) usize {
    const V = @Vector(trace.lanes, u64);
    const smaller: @Vector(trace.lanes, bool) = @as(V, block.*) < @as(V, @splat(key));
    return @popCount(@as(u8, @bitCast(smaller)));
}

/// Linear scan, eight keys at a time. `padded` is the sorted keys followed by
/// `maxInt(u64)` sentinels up to a multiple of 8 (see `layout.padToLanes`):
/// a sentinel is never smaller than any needle, so the tail needs no special
/// case. Reads every line of the array, which is why it only wins when the
/// array is a handful of lines.
pub fn lowerBoundVector(padded: []align(trace.line_bytes) const u64, key: u64, tracer: anytype) usize {
    std.debug.assert(padded.len % trace.lanes == 0);
    var count: usize = 0;
    var i: usize = 0;
    while (i < padded.len) : (i += trace.lanes) {
        tracer.cmpBlock(i, trace.lanes);
        count += rank8(padded[i..][0..trace.lanes], key);
    }
    return count;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Trace = trace.Trace;
const NoTrace = trace.NoTrace;

test "rank8 counts the smaller keys" {
    const block = [8]u64{ 10, 20, 30, 40, 50, 60, 70, 80 };
    try testing.expectEqual(0, rank8(&block, 5));
    try testing.expectEqual(3, rank8(&block, 35));
    try testing.expectEqual(3, rank8(&block, 40)); // equal is not smaller
    try testing.expectEqual(8, rank8(&block, 99));
}

test "exhaustive: every algorithm equals the linear scan for every length up to 70" {
    // Keys 10, 20, 30, ...; needles cover below, equal, between and above.
    var padded: [72]u64 align(trace.line_bytes) = undefined;
    for (0..71) |n| {
        for (0..72) |i| padded[i] = if (i < n) (i + 1) * 10 else std.math.maxInt(u64);
        const keys: []const u64 = padded[0..n];
        const padded_len = std.mem.alignForward(usize, n, trace.lanes);
        var needle: u64 = 0;
        while (needle <= (n + 1) * 10) : (needle += 5) {
            const want = lowerBoundLinear(keys, needle);
            try testing.expectEqual(want, lowerBoundClassic(keys, needle, NoTrace{}));
            try testing.expectEqual(want, lowerBoundHalving(.branch, false, keys, needle, NoTrace{}));
            try testing.expectEqual(want, lowerBoundHalving(.arithmetic, false, keys, needle, NoTrace{}));
            try testing.expectEqual(want, lowerBoundHalving(.hinted, false, keys, needle, NoTrace{}));
            try testing.expectEqual(want, lowerBoundHalving(.hinted, true, keys, needle, NoTrace{}));
            try testing.expectEqual(want, lowerBoundVector(padded[0..padded_len], needle, NoTrace{}));
        }
    }
}

test "halving: comparison count depends only on the length" {
    var keys: [300]u64 = undefined;
    for (&keys, 0..) |*k, i| k.* = i * 3;
    for (0..keys.len + 1) |n| {
        var needle: u64 = 0;
        while (needle < 3 * n + 3) : (needle += 1) {
            var t: Trace = .init(.{});
            _ = lowerBoundHalving(.hinted, false, keys[0..n], needle, &t);
            try testing.expectEqual(halvingComparisons(n), t.comparisons);
        }
    }
    // 15 keys: 15 -> 8 -> 4 -> 2 -> 1 is four halvings, plus the final check.
    try testing.expectEqual(5, halvingComparisons(15));
    try testing.expectEqual(1, halvingComparisons(1));
}

test "halving: branch, arithmetic, hinted and prefetch variants probe identical keys" {
    var keys: [1000]u64 = undefined;
    for (&keys, 0..) |*k, i| k.* = i * 2;
    var needle: u64 = 0;
    while (needle < 2010) : (needle += 7) {
        var a: Trace = .init(.{});
        var b: Trace = .init(.{});
        var c: Trace = .init(.{});
        var d: Trace = .init(.{});
        const ra = lowerBoundHalving(.branch, false, &keys, needle, &a);
        const rb = lowerBoundHalving(.arithmetic, false, &keys, needle, &b);
        const rc = lowerBoundHalving(.hinted, true, &keys, needle, &c);
        const rd = lowerBoundHalving(.hinted, false, &keys, needle, &d);
        try testing.expectEqual(ra, rb);
        try testing.expectEqual(ra, rc);
        try testing.expectEqual(ra, rd);
        try testing.expectEqualSlices(u32, a.probeSlice(), b.probeSlice());
        try testing.expectEqualSlices(u32, a.probeSlice(), c.probeSlice());
        try testing.expectEqualSlices(u32, a.probeSlice(), d.probeSlice());
        try testing.expectEqual(a.linesRead(), c.linesRead());
        // Every line except the very first probe was hinted before it was read.
        try testing.expectEqual(1, c.uncovered);
        try testing.expectEqual(a.linesRead(), a.uncovered);
        try testing.expectEqual(2 * (c.comparisons - 1), c.prefetches);
    }
}

test "classic: between floor(log2 n) and floor(log2 n) + 1 comparisons" {
    var keys: [200]u64 = undefined;
    for (&keys, 0..) |*k, i| k.* = i;
    for (1..keys.len + 1) |n| {
        const floor_log = std.math.log2_int(usize, n);
        var needle: u64 = 0;
        while (needle <= n) : (needle += 1) {
            var t: Trace = .init(.{});
            _ = lowerBoundClassic(keys[0..n], needle, &t);
            try testing.expect(t.comparisons >= floor_log and t.comparisons <= floor_log + 1);
        }
    }
}

test "vector scan: one step and one line per eight keys" {
    var padded: [64]u64 align(trace.line_bytes) = undefined;
    for (&padded, 0..) |*k, i| k.* = if (i < 60) i else std.math.maxInt(u64);
    var t: Trace = .init(.{});
    try testing.expectEqual(33, lowerBoundVector(&padded, 33, &t));
    try testing.expectEqual(64, t.comparisons);
    try testing.expectEqual(8, t.steps);
    try testing.expectEqual(8, t.linesRead());
    // The largest possible needle still stops at the sentinels.
    try testing.expectEqual(60, lowerBoundVector(&padded, std.math.maxInt(u64), NoTrace{}));
}
