//! Chapter 02: searching a sorted node.
//!
//! A B-tree node is a small sorted array of keys. Every tree operation starts
//! by asking one question of that array: "where does this key belong?".
//! This file answers it with two functions, `lowerBound` and `upperBound`,
//! and builds everything else (exact lookup, insertion index, ranges with
//! inclusive / exclusive bounds, neighbours, galloping) on top of them.
//!
//! Nothing here allocates. All functions take a slice over memory the caller
//! owns, which is exactly the situation inside a tree: the node (or the disk
//! page) already holds the keys, and the search only looks at them.
const std = @import("std");
const assert = std.debug.assert;

/// True if `keys` is in non-decreasing order (duplicates allowed).
/// This is the precondition of every search function below. Binary search on
/// an unsorted array does not crash, it silently returns nonsense, so tests
/// and `validate` functions check it explicitly.
pub fn isSorted(keys: []const u64) bool {
    for (1..@max(keys.len, 1)) |i| {
        if (keys[i - 1] > keys[i]) return false;
    }
    return true;
}

/// Index of the first element that is `>= key`, or `keys.len` if there is none.
///
/// Equivalent statements of the same result `i`:
///   * every key in `keys[0..i]` is `< key`, every key in `keys[i..]` is `>= key`;
///   * `i` is the number of keys smaller than `key`;
///   * `i` is the leftmost position where `key` can be inserted so that the
///     array stays sorted.
///
/// The candidate ANSWERS are the closed range of indices `[lo, hi]` (the answer
/// can be `keys.len`, so there are `len + 1` candidates); the unknown ELEMENTS
/// are the half-open range `keys[lo..hi]`. The loop keeps this invariant:
///
///     keys[0..lo]  are all <  key        (known to be left of the answer)
///     keys[hi..]   are all >= key        (known to be at or right of it)
///
/// Both ranges start empty, so the invariant holds trivially before the loop.
/// Each iteration looks at one unknown element and moves it into one of the
/// two ranges. When `lo == hi` nothing is unknown, and `lo` is the answer.
pub fn lowerBound(keys: []const u64, key: u64) usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        // Not `(lo + hi) / 2`: the sum can overflow. `lo + (hi - lo) / 2`
        // cannot, because `hi - lo` is at most `hi`. Since `lo < hi`, we get
        // `lo <= mid < hi`, so `keys[mid]` is always a real element.
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] < key) {
            // keys[mid] and everything left of it is < key.
            lo = mid + 1;
        } else {
            // keys[mid] >= key, so mid is still a candidate answer: keep it
            // (`hi = mid`, not `mid - 1`).
            hi = mid;
        }
    }
    return lo;
}

/// Index of the first element that is `> key`, or `keys.len` if there is none.
///
/// The only difference from `lowerBound` is `<=` instead of `<`: equal keys
/// are now pushed to the left side. Invariant:
///
///     keys[0..lo]  are all <= key
///     keys[hi..]   are all >  key
///
/// `i` is the rightmost position where `key` can be inserted so that the
/// array stays sorted, and the number of keys `<= key`.
pub fn upperBound(keys: []const u64, key: u64) usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] <= key) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// What a node search should return: not "the key or nothing", but always a
/// position. `index` is the lower bound; `found` says whether the key at that
/// position is the one searched for.
///
///   found = true   keys[index] == key (the first one, if there are duplicates)
///   found = false  key is absent and `index` is where to insert it
///
/// One search then serves `get` (use `found`), `put` (overwrite at `index` or
/// insert at `index`), `delete`, and the start of a range scan.
pub const SearchResult = struct {
    found: bool,
    index: usize,
};

pub fn search(keys: []const u64, key: u64) SearchResult {
    const index = lowerBound(keys, key);
    // The `index < keys.len` test must come first: index may be keys.len.
    return .{ .found = index < keys.len and keys[index] == key, .index = index };
}

/// A half-open range of indices `[start, end)`. Half-open ranges are used for
/// the same reason the search itself is half-open: the length is `end - start`,
/// the empty range needs no special value, and adjacent ranges share a bound.
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn len(self: Span) usize {
        return self.end - self.start;
    }
};

/// All positions holding `key`: `[lowerBound, upperBound)`. Empty (start ==
/// end == insertion index) when the key is absent.
pub fn equalRange(keys: []const u64, key: u64) Span {
    return .{ .start = lowerBound(keys, key), .end = upperBound(keys, key) };
}

/// One end of a key range, as a user writes it: `>= k`, `> k`, or no limit.
pub const Bound = union(enum) {
    unbounded,
    included: u64,
    excluded: u64,
};

/// Translate a key range with inclusive / exclusive ends into a half-open
/// index range. This table is the whole trick:
///
///     start:  >= k  -> lowerBound(k)      > k  -> upperBound(k)
///     end:    <= k  -> upperBound(k)      < k  -> lowerBound(k)
///
/// (An inclusive end must step PAST the equal keys, an exclusive start too.)
pub fn rangeSpan(keys: []const u64, lo: Bound, hi: Bound) Span {
    const start = switch (lo) {
        .unbounded => 0,
        .included => |k| lowerBound(keys, k),
        .excluded => |k| upperBound(keys, k),
    };
    const end = switch (hi) {
        .unbounded => keys.len,
        .included => |k| upperBound(keys, k),
        .excluded => |k| lowerBound(keys, k),
    };
    // An empty or inverted key range such as (7, 7) or [9, 3] gives
    // end < start. Clamp, so that `Span.len()` cannot underflow.
    return .{ .start = start, .end = @max(start, end) };
}

/// Index of the last element `<= key`, or null if every element is greater.
/// This is "upper bound minus one": the predecessor query. Interior nodes of
/// a B-tree use this shape to pick the child to descend into (chapter 03).
pub fn lastLessOrEqual(keys: []const u64, key: u64) ?usize {
    const i = upperBound(keys, key);
    // `i - 1` would underflow for i == 0; an optional states that honestly.
    return if (i == 0) null else i - 1;
}

/// Index of the last element `< key`, or null: "lower bound minus one".
pub fn lastLess(keys: []const u64, key: u64) ?usize {
    const i = lowerBound(keys, key);
    return if (i == 0) null else i - 1;
}

/// Lower bound of `key` in `keys[from..]`, returned as an index into `keys`.
/// The result is `max(from, lowerBound(keys, key))`.
///
/// Use it when the answer is expected to be CLOSE to `from`: for example when
/// looking up a sorted batch of keys, where each search can start where the
/// previous one ended. Instead of halving the whole array, it first doubles a
/// step (1, 2, 4, 8, ...) until it jumps past the answer, then runs a normal
/// binary search inside the last jump. If the answer is `d` positions after
/// `from`, this costs about `2 * log2(d)` comparisons instead of `log2(n)`.
pub fn gallopLowerBound(keys: []const u64, from: usize, key: u64) usize {
    assert(from <= keys.len);
    if (from == keys.len or keys[from] >= key) return from;

    // Invariant of the galloping phase: keys[below] < key.
    var below = from;
    var step: usize = 1;
    // Exclusive upper end of the bracket that must contain the answer.
    var hi = keys.len;
    // `step < keys.len - below` is `below + step < keys.len` written so that
    // it cannot overflow.
    while (step < keys.len - below) {
        const probe = below + step;
        if (keys[probe] >= key) {
            hi = probe; // keys[probe] is a candidate answer
            break;
        }
        below = probe;
        step *= 2; // cannot overflow: step < keys.len
    }
    // Now keys[below] < key, and the answer is in (below, hi].
    const first = below + 1;
    return first + lowerBound(keys[first..hi], key);
}

/// Reference implementations: one line of logic each, obviously correct, O(n).
/// The tests compare every clever function against these.
pub fn linearLowerBound(keys: []const u64, key: u64) usize {
    for (keys, 0..) |k, i| {
        if (k >= key) return i;
    }
    return keys.len;
}

pub fn linearUpperBound(keys: []const u64, key: u64) usize {
    for (keys, 0..) |k, i| {
        if (k > key) return i;
    }
    return keys.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const SplitMix64 = @import("prng.zig").SplitMix64;

/// Fill `keys` with a sorted sequence: each key is the previous one plus a
/// random gap in [0, max_gap). A gap of 0 produces a duplicate.
pub fn fillSorted(rng: *SplitMix64, keys: []u64, max_gap: u64) void {
    var previous: u64 = 0;
    for (keys) |*k| {
        previous += rng.below(max_gap);
        k.* = previous;
    }
}

/// Allocate and fill a sorted array. The allocator is a parameter, as
/// everywhere in this guide; callers in this chapter pass a
/// `FixedBufferAllocator` because the arrays are short-lived scratch data.
pub fn makeSorted(allocator: std.mem.Allocator, rng: *SplitMix64, n: usize, max_gap: u64) ![]u64 {
    const keys = try allocator.alloc(u64, n);
    fillSorted(rng, keys, max_gap);
    return keys;
}

test "hand example: lower and upper bound on a node with duplicates" {
    const keys = [_]u64{ 3, 7, 7, 7, 12, 15, 15, 20 };
    try testing.expect(isSorted(&keys));
    try testing.expectEqual(0, lowerBound(&keys, 0));
    try testing.expectEqual(0, upperBound(&keys, 0));
    try testing.expectEqual(1, lowerBound(&keys, 7));
    try testing.expectEqual(4, upperBound(&keys, 7));
    try testing.expectEqual(4, lowerBound(&keys, 8));
    try testing.expectEqual(4, upperBound(&keys, 8));
    try testing.expectEqual(7, lowerBound(&keys, 20));
    try testing.expectEqual(8, upperBound(&keys, 20));
    try testing.expectEqual(8, lowerBound(&keys, 21));
    try testing.expectEqual(Span{ .start = 5, .end = 7 }, equalRange(&keys, 15));
    try testing.expectEqual(0, equalRange(&keys, 13).len());
}

test "empty and single-element nodes" {
    const empty = [_]u64{};
    try testing.expectEqual(0, lowerBound(&empty, 5));
    try testing.expectEqual(0, upperBound(&empty, 5));
    try testing.expectEqual(SearchResult{ .found = false, .index = 0 }, search(&empty, 5));
    try testing.expectEqual(null, lastLessOrEqual(&empty, 5));
    try testing.expectEqual(0, gallopLowerBound(&empty, 0, 5));

    const one = [_]u64{5};
    try testing.expectEqual(SearchResult{ .found = false, .index = 0 }, search(&one, 4));
    try testing.expectEqual(SearchResult{ .found = true, .index = 0 }, search(&one, 5));
    try testing.expectEqual(SearchResult{ .found = false, .index = 1 }, search(&one, 6));
}

test "extreme keys: 0 and maxInt need no special case" {
    const max = std.math.maxInt(u64);
    const keys = [_]u64{ 0, 0, 1, max - 1, max, max };
    try testing.expectEqual(0, lowerBound(&keys, 0));
    try testing.expectEqual(2, upperBound(&keys, 0));
    try testing.expectEqual(4, lowerBound(&keys, max));
    try testing.expectEqual(6, upperBound(&keys, max));
    try testing.expectEqual(Span{ .start = 0, .end = 6 }, rangeSpan(&keys, .{ .included = 0 }, .{ .included = max }));
}

test "search result is the insertion index" {
    const keys = [_]u64{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 };
    try testing.expectEqual(SearchResult{ .found = true, .index = 6 }, search(&keys, 12));
    try testing.expectEqual(SearchResult{ .found = false, .index = 7 }, search(&keys, 13));
    try testing.expectEqual(SearchResult{ .found = false, .index = 0 }, search(&keys, 0));
    try testing.expectEqual(SearchResult{ .found = false, .index = 12 }, search(&keys, 31));
}

test "range bounds: the four inclusive / exclusive combinations" {
    const keys = [_]u64{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 };
    const S = Span;
    try testing.expectEqual(S{ .start = 2, .end = 9 }, rangeSpan(&keys, .{ .included = 5 }, .{ .included = 17 }));
    try testing.expectEqual(S{ .start = 3, .end = 9 }, rangeSpan(&keys, .{ .excluded = 5 }, .{ .included = 17 }));
    try testing.expectEqual(S{ .start = 2, .end = 8 }, rangeSpan(&keys, .{ .included = 5 }, .{ .excluded = 17 }));
    try testing.expectEqual(S{ .start = 3, .end = 8 }, rangeSpan(&keys, .{ .excluded = 5 }, .{ .excluded = 17 }));
    // Bounds that are not keys: all four combinations agree.
    try testing.expectEqual(S{ .start = 2, .end = 8 }, rangeSpan(&keys, .{ .excluded = 4 }, .{ .excluded = 16 }));
    try testing.expectEqual(S{ .start = 2, .end = 8 }, rangeSpan(&keys, .{ .included = 4 }, .{ .included = 16 }));
    // Unbounded ends.
    try testing.expectEqual(S{ .start = 0, .end = 12 }, rangeSpan(&keys, .unbounded, .unbounded));
    try testing.expectEqual(S{ .start = 10, .end = 12 }, rangeSpan(&keys, .{ .excluded = 20 }, .unbounded));
    // Empty and inverted key ranges are clamped to an empty span.
    try testing.expectEqual(0, rangeSpan(&keys, .{ .excluded = 7 }, .{ .excluded = 7 }).len());
    try testing.expectEqual(0, rangeSpan(&keys, .{ .included = 20 }, .{ .included = 5 }).len());
    try testing.expectEqual(0, rangeSpan(&keys, .{ .included = 8 }, .{ .included = 9 }).len());
}

test "neighbours: last key below or at a key" {
    const keys = [_]u64{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 };
    try testing.expectEqual(6, lastLessOrEqual(&keys, 12));
    try testing.expectEqual(6, lastLessOrEqual(&keys, 13));
    try testing.expectEqual(5, lastLess(&keys, 12));
    try testing.expectEqual(null, lastLessOrEqual(&keys, 0));
    try testing.expectEqual(null, lastLess(&keys, 1));
    try testing.expectEqual(11, lastLess(&keys, 1000));
}

test "trap: the midpoint (lo + hi) / 2 overflows" {
    // Shown with 8-bit indices so that the numbers fit in a comment. With
    // usize the same thing happens once lo + hi exceeds the integer range.
    const lo: u8 = 200;
    const hi: u8 = 250;
    // 200 + 250 = 450 does not fit in a u8. Zig's `+` traps on overflow in
    // debug builds; `+%` wraps like C does, giving (450 - 256) / 2 = 97,
    // an index that is not even between lo and hi.
    try testing.expectEqual(97, (lo +% hi) / 2);
    try testing.expectError(error.Overflow, std.math.add(u8, lo, hi));
    // The safe form stays inside [lo, hi).
    try testing.expectEqual(225, lo + (hi - lo) / 2);
}

/// Number of loop iterations binary search needs for n elements, worst case:
/// the number of bits of n (0 for n = 0, 1 for n = 1, 2 for n = 2..3, ...).
pub fn maxComparisons(n: usize) u64 {
    return @bitSizeOf(usize) - @clz(n);
}

test maxComparisons {
    try testing.expectEqual(0, maxComparisons(0));
    try testing.expectEqual(1, maxComparisons(1));
    try testing.expectEqual(2, maxComparisons(3));
    try testing.expectEqual(3, maxComparisons(4));
    try testing.expectEqual(4, maxComparisons(12));
    try testing.expectEqual(13, maxComparisons(4096));
}

// --- Exhaustive testing ----------------------------------------------------
//
// Binary search has few inputs that matter: the length of the array, where
// the duplicates are, and where the key falls relative to the elements. So
// instead of picking examples we enumerate ALL sorted arrays of length 0..7
// over the alphabet {1, 3, 5, 7} and search each one for EVERY key 0..8
// (below, between, equal to and above every element).

const alphabet = [_]u64{ 1, 3, 5, 7 };
const max_exhaustive_len = 7;

const Counterexample = struct {
    keys: [max_exhaustive_len]u64,
    len: usize,
    key: u64,
    got: usize,
    want: usize,
};

const BoundFn = fn ([]const u64, u64) usize;

/// Run `candidate` on every small input and return the first input where it
/// disagrees with `reference` (shortest array first), or null if none.
/// `scratch` provides the memory for the arrays being enumerated.
fn firstCounterexample(scratch: std.mem.Allocator, comptime candidate: BoundFn, comptime reference: BoundFn) !?Counterexample {
    const keys_buf = try scratch.alloc(u64, max_exhaustive_len);
    defer scratch.free(keys_buf);

    for (0..max_exhaustive_len + 1) |n| {
        const keys = keys_buf[0..n];
        // `code` counts through all alphabet.len^n digit strings; the ones
        // that are not sorted are skipped.
        var code: usize = 0;
        const codes = std.math.pow(usize, alphabet.len, n);
        while (code < codes) : (code += 1) {
            var rest = code;
            for (keys) |*k| {
                k.* = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            if (!isSorted(keys)) continue;
            for (0..9) |key| {
                const got = candidate(keys, key);
                const want = reference(keys, key);
                if (got != want) {
                    var ce: Counterexample = .{ .keys = @splat(0), .len = n, .key = key, .got = got, .want = want };
                    @memcpy(ce.keys[0..n], keys);
                    return ce;
                }
            }
        }
    }
    return null;
}

test "exhaustive: lowerBound and upperBound agree with a linear scan" {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    try testing.expectEqual(null, try firstCounterexample(fba.allocator(), lowerBound, linearLowerBound));
    try testing.expectEqual(null, try firstCounterexample(fba.allocator(), upperBound, linearUpperBound));
}

test "exhaustive: derived results and galloping from every start" {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const keys_buf = try fba.allocator().alloc(u64, max_exhaustive_len);

    var arrays: usize = 0;
    for (0..max_exhaustive_len + 1) |n| {
        const keys = keys_buf[0..n];
        var code: usize = 0;
        const codes = std.math.pow(usize, alphabet.len, n);
        while (code < codes) : (code += 1) {
            var rest = code;
            for (keys) |*k| {
                k.* = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            if (!isSorted(keys)) continue;
            arrays += 1;
            for (0..9) |key| {
                const lower = linearLowerBound(keys, key);
                const upper = linearUpperBound(keys, key);

                // The two bounds bracket exactly the copies of `key`.
                try testing.expect(lower <= upper);
                for (keys, 0..) |k, i| try testing.expectEqual(k == key, lower <= i and i < upper);

                const r = search(keys, key);
                try testing.expectEqual(lower, r.index);
                try testing.expectEqual(lower != upper, r.found);

                try testing.expectEqual(if (upper == 0) null else upper - 1, lastLessOrEqual(keys, key));
                try testing.expectEqual(if (lower == 0) null else lower - 1, lastLess(keys, key));

                // Galloping from any start gives the lower bound, unless the
                // start is already past it.
                for (0..n + 1) |from| {
                    try testing.expectEqual(@max(from, lower), gallopLowerBound(keys, from, key));
                }
            }
        }
    }
    // 1 + 4 + 10 + 20 + 35 + 56 + 84 + 120 sorted arrays of length 0..7.
    try testing.expectEqual(330, arrays);
}

// Two classic wrong versions. They are not exported; they exist so that the
// tests can show the exhaustive checker catching them, with the smallest
// failing input.

/// Bug 1: "closed interval" search that starts with hi = len - 1 but keeps
/// the half-open loop. The answer `len` (key greater than everything) is no
/// longer reachable.
fn buggyLowerBoundClosed(keys: []const u64, key: u64) usize {
    if (keys.len == 0) return 0;
    var lo: usize = 0;
    var hi: usize = keys.len - 1;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Bug 2: return as soon as an equal key is seen. Correct for unique keys,
/// but with duplicates it returns SOME equal element, not the first.
fn buggyLowerBoundEarlyExit(keys: []const u64, key: u64) usize {
    var lo: usize = 0;
    var hi: usize = keys.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (keys[mid] == key) return mid;
        if (keys[mid] < key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

test "trap: the exhaustive checker finds the smallest failing input of two classic bugs" {
    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);

    // Bug 1 fails on the smallest possible input: one key, search above it.
    const closed = (try firstCounterexample(fba.allocator(), buggyLowerBoundClosed, linearLowerBound)).?;
    try testing.expectEqualSlices(u64, &.{1}, closed.keys[0..closed.len]);
    try testing.expectEqual(2, closed.key);
    try testing.expectEqual(0, closed.got);
    try testing.expectEqual(1, closed.want);

    // Bug 2 needs a duplicate: [1, 1], key 1 probes index 1 first.
    const early = (try firstCounterexample(fba.allocator(), buggyLowerBoundEarlyExit, linearLowerBound)).?;
    try testing.expectEqualSlices(u64, &.{ 1, 1 }, early.keys[0..early.len]);
    try testing.expectEqual(1, early.key);
    try testing.expectEqual(1, early.got);
    try testing.expectEqual(0, early.want);
}

fn orderOf(key: u64, item: u64) std.math.Order {
    return std.math.order(key, item);
}

test "seeded: random sorted arrays against the linear scan and against std.sort" {
    // The backing memory comes from the leak-checking test allocator; the
    // arrays themselves are bump-allocated out of it and dropped all at once
    // by `reset`, one round after another.
    const backing = try testing.allocator.alloc(u8, 4096);
    defer testing.allocator.free(backing);
    var fba: std.heap.FixedBufferAllocator = .init(backing);

    var rng = SplitMix64.init(0x02);
    for (0..300) |round| {
        fba.reset();
        const n: usize = @intCast(rng.below(200));
        // Small gaps on even rounds give many duplicates.
        const keys = try makeSorted(fba.allocator(), &rng, n, if (round % 2 == 0) 3 else 1000);
        try testing.expect(isSorted(keys));
        const top = if (n == 0) 10 else keys[n - 1] + 2;
        for (0..50) |_| {
            const key = rng.below(top);
            const lower = lowerBound(keys, key);
            const upper = upperBound(keys, key);
            try testing.expectEqual(linearLowerBound(keys, key), lower);
            try testing.expectEqual(linearUpperBound(keys, key), upper);
            try testing.expectEqual(std.sort.lowerBound(u64, keys, key, orderOf), lower);
            try testing.expectEqual(std.sort.upperBound(u64, keys, key, orderOf), upper);
            const from: usize = @intCast(rng.below(n + 1));
            try testing.expectEqual(@max(from, lower), gallopLowerBound(keys, from, key));
        }
    }
}

test "allocation failure: a scratch buffer that is too small reports OutOfMemory" {
    // Room for exactly 8 keys. `align` matters: a [64]u8 may start at an odd
    // address, and the padding needed to align the first u64 would then eat
    // into the 64 bytes.
    var buf: [8 * @sizeOf(u64)]u8 align(@alignOf(u64)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var rng = SplitMix64.init(1);
    const keys = try makeSorted(fba.allocator(), &rng, 8, 10);
    try testing.expectEqual(8, keys.len);
    // The buffer is full now. Nothing is leaked or corrupted: the caller
    // gets an error and can reset the buffer.
    try testing.expectError(error.OutOfMemory, makeSorted(fba.allocator(), &rng, 1, 10));
    fba.reset();
    _ = try makeSorted(fba.allocator(), &rng, 8, 10);
}
