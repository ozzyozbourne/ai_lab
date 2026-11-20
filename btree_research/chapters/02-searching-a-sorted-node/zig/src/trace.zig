//! Instrumented twins of the functions in search.zig.
//!
//! The functions in search.zig are kept free of bookkeeping so that they read
//! like the textbook. To SHOW what they do (the step table in the program
//! output and in the visualization) and to COUNT comparisons, this file
//! repeats the same loops with a recorder attached. The tests at the bottom
//! prove that every twin returns exactly what the plain function returns.
const std = @import("std");
const search = @import("search.zig");

pub const Mode = enum { lower, upper };

/// One iteration of the binary search loop.
pub const Step = struct {
    lo: usize,
    hi: usize,
    mid: usize,
    /// keys[mid], the only element this iteration looks at.
    probe: u64,
    /// true: the probe goes to the left group, `lo = mid + 1`.
    /// false: the probe goes to the right group, `hi = mid`.
    go_right: bool,
};

/// More steps than any slice can need: one per bit of an index, plus one.
pub const max_steps = @bitSizeOf(usize) + 1;

pub const Trace = struct {
    steps: []const Step,
    index: usize,
};

/// `lowerBound` / `upperBound` with every iteration written into `buffer`
/// (caller memory again: tracing does not allocate either).
pub fn traceBound(keys: []const u64, key: u64, mode: Mode, buffer: *[max_steps]Step) Trace {
    var count: usize = 0;
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const go_right = switch (mode) {
            .lower => keys[mid] < key,
            .upper => keys[mid] <= key,
        };
        buffer[count] = .{ .lo = lo, .hi = hi, .mid = mid, .probe = keys[mid], .go_right = go_right };
        count += 1;
        if (go_right) lo = mid + 1 else hi = mid;
    }
    return .{ .steps = buffer[0..count], .index = lo };
}

pub const Counted = struct {
    index: usize,
    /// Number of key comparisons (`keys[i] < key` evaluations).
    comparisons: u64,
};

pub fn lowerBoundCounted(keys: []const u64, key: u64) Counted {
    var buffer: [max_steps]Step = undefined;
    const t = traceBound(keys, key, .lower, &buffer);
    return .{ .index = t.index, .comparisons = t.steps.len };
}

/// `search.gallopLowerBound` with a comparison counter. Same structure, line
/// for line; see the comments there.
pub fn gallopLowerBoundCounted(keys: []const u64, from: usize, key: u64) Counted {
    std.debug.assert(from <= keys.len);
    if (from == keys.len) return .{ .index = from, .comparisons = 0 };
    var comparisons: u64 = 1;
    if (keys[from] >= key) return .{ .index = from, .comparisons = comparisons };

    var below = from;
    var step: usize = 1;
    var hi = keys.len;
    while (step < keys.len - below) {
        const probe = below + step;
        comparisons += 1;
        if (keys[probe] >= key) {
            hi = probe;
            break;
        }
        below = probe;
        step *= 2;
    }
    const first = below + 1;
    const inner = lowerBoundCounted(keys[first..hi], key);
    return .{ .index = first + inner.index, .comparisons = comparisons + inner.comparisons };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const SplitMix64 = @import("prng.zig").SplitMix64;

test "trace of the worked example: lowerBound(13) on the canonical keys" {
    const keys = [_]u64{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 };
    var buffer: [max_steps]Step = undefined;
    const t = traceBound(&keys, 13, .lower, &buffer);
    try testing.expectEqual(7, t.index);
    try testing.expectEqualSlices(Step, &.{
        .{ .lo = 0, .hi = 12, .mid = 6, .probe = 12, .go_right = true },
        .{ .lo = 7, .hi = 12, .mid = 9, .probe = 20, .go_right = false },
        .{ .lo = 7, .hi = 9, .mid = 8, .probe = 17, .go_right = false },
        .{ .lo = 7, .hi = 8, .mid = 7, .probe = 15, .go_right = false },
    }, t.steps);
}

test "seeded: the twins return what the plain functions return, within the bound" {
    var buf: [200 * @sizeOf(u64)]u8 align(@alignOf(u64)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var rng = SplitMix64.init(0x0202);
    var buffer: [max_steps]Step = undefined;
    for (0..200) |round| {
        fba.reset();
        const n: usize = @intCast(rng.below(200));
        const keys = try search.makeSorted(fba.allocator(), &rng, n, if (round % 2 == 0) 3 else 50);
        const top = if (n == 0) 10 else keys[n - 1] + 2;
        for (0..40) |_| {
            const key = rng.below(top);
            const lower = traceBound(keys, key, .lower, &buffer);
            try testing.expectEqual(search.lowerBound(keys, key), lower.index);
            try testing.expect(lower.steps.len <= search.maxComparisons(n));
            const upper = traceBound(keys, key, .upper, &buffer);
            try testing.expectEqual(search.upperBound(keys, key), upper.index);
            try testing.expect(upper.steps.len <= search.maxComparisons(n));

            const from: usize = @intCast(rng.below(n + 1));
            const g = gallopLowerBoundCounted(keys, from, key);
            try testing.expectEqual(search.gallopLowerBound(keys, from, key), g.index);
            // Galloping to an answer d positions away costs at most about
            // 2 * log2(d) + 2 comparisons, however long the array is.
            const distance = g.index - from;
            try testing.expect(g.comparisons <= 2 * search.maxComparisons(distance) + 2);
        }
    }
}
