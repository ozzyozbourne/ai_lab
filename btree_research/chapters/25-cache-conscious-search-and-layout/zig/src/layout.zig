//! Two static layouts of the same sorted keys, both allocated on a cache-line
//! boundary, both searched without an unpredictable branch.
//!
//!   * `Eytzinger`: a binary search tree stored in breadth-first order, the
//!     way a binary heap is stored. Children of slot k are slots 2k and 2k+1.
//!   * `BlockTree`: the same idea with 8 keys (one cache line) per node and 9
//!     children: one key line per level. It borrows the B-tree's node shape
//!     (8 keys, 9 children, one unit of transfer) but it is NOT a B-tree. It
//!     is a complete 9-ary search tree in breadth-first numbering: leaves may
//!     sit on two adjacent levels and a node may have fewer children than
//!     keys + 1.
//!
//! Both are built once from sorted input and never modified (compare the
//! bulk-loaded trees of chapter 16). Both keep a `rank` array that maps a slot
//! back to the index in sorted order, so that their answers can be compared
//! with the searches in search.zig. A real index would store the payload
//! (a child page id, a row id) in that parallel array instead.
//!
//! `rank` is a second array, so reading it costs a cache line of its own.
//! Both searches therefore read it exactly ONCE, after the descent, and
//! report that read to the tracer (`tracer.side`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const trace = @import("trace.zig");
const search = @import("search.zig");

const lanes = trace.lanes;
/// Padding value: compares greater than or equal to every needle, so padded
/// slots never count as "smaller". Real keys must be below it.
pub const sentinel = std.math.maxInt(u64);
const line_align: std.mem.Alignment = .fromByteUnits(trace.line_bytes);

pub const AlignedKeys = []align(trace.line_bytes) u64;

/// Copies `sorted` into a line-aligned array padded with sentinels to a
/// multiple of 8 keys, ready for `search.lowerBoundVector`.
///
/// Why aligned: `alignedAlloc(u64, .fromByteUnits(64), n)` guarantees that key 0 starts a
/// cache line, so every 8-key block is exactly one line. With the natural
/// 8-byte alignment a block could straddle two lines and every vector load
/// would touch twice the memory.
pub fn padToLanes(gpa: Allocator, sorted: []const u64) Allocator.Error!AlignedKeys {
    const padded = try gpa.alignedAlloc(u64, line_align, std.mem.alignForward(usize, sorted.len, lanes));
    @memcpy(padded[0..sorted.len], sorted);
    @memset(padded[sorted.len..], sentinel);
    return padded;
}

pub const ValidateError = error{Corrupt};

pub const Eytzinger = struct {
    /// Slot 0 is unused, slots 1..n hold keys, the rest is sentinel padding.
    /// Slot 0 is not wasted: it shifts the tree so that slots 8k..8k+7, the
    /// eight great-grandchildren of slot k, are exactly one cache line.
    keys: AlignedKeys,
    /// rank[slot] = index of that key in sorted order; rank[0] = n ("no key").
    rank: []u32,
    n: usize,

    pub fn init(gpa: Allocator, sorted: []const u64) Allocator.Error!Eytzinger {
        const n = sorted.len;
        const keys = try gpa.alignedAlloc(u64, line_align, std.mem.alignForward(usize, n + 1, lanes));
        errdefer gpa.free(keys);
        const rank = try gpa.alloc(u32, n + 1);
        @memset(keys, sentinel);
        keys[0] = 0;
        rank[0] = @intCast(n);
        var self: Eytzinger = .{ .keys = keys, .rank = rank, .n = n };
        var next: usize = 0;
        self.fill(sorted, 1, &next);
        std.debug.assert(next == n);
        return self;
    }

    pub fn deinit(self: *Eytzinger, gpa: Allocator) void {
        gpa.free(self.keys);
        gpa.free(self.rank);
        self.* = undefined;
    }

    /// In-order walk of the implicit tree, handing out sorted keys as we go:
    /// everything in the left subtree gets a smaller key than slot k.
    fn fill(self: *Eytzinger, sorted: []const u64, k: usize, next: *usize) void {
        if (k > self.n) return;
        self.fill(sorted, 2 * k, next);
        std.debug.assert(sorted[next.*] < sentinel);
        self.keys[k] = sorted[next.*];
        self.rank[k] = @intCast(next.*);
        next.* += 1;
        self.fill(sorted, 2 * k + 1, next);
    }

    /// Lower bound as an index into the SORTED order.
    ///
    /// Descend: go right (2k+1) when the slot's key is smaller, else left
    /// (2k). The slot number therefore records the path in binary: each right
    /// turn appends a 1, each left turn a 0. The answer is the last slot where
    /// we turned left (its key is >= the needle and nothing smaller below it
    /// is). To get back there, drop the trailing 1 bits and one more bit. If
    /// we never turned left the result is slot 0, whose rank is n.
    pub fn lowerBound(self: *const Eytzinger, key: u64, comptime prefetch: bool, tracer: anytype) usize {
        var k: usize = 1;
        while (k <= self.n) {
            if (prefetch) {
                // Slots 8k..8k+7 are the eight possible positions three
                // levels down and they share one line: a single hint covers
                // all of them, with three comparisons of lead time.
                const ahead = @min(8 * k, self.keys.len - 1);
                @prefetch(&self.keys[ahead], .{ .rw = .read, .locality = 0, .cache = .data });
                tracer.prefetch(ahead);
            }
            tracer.cmp(k);
            k = 2 * k + @intFromBool(self.keys[k] < key);
        }
        k >>= @intCast(@ctz(~k) + 1);
        // The only read of the second array: one more cache line.
        tracer.side(k);
        return self.rank[k];
    }

    /// Checks: an in-order walk visits strictly increasing keys with ranks
    /// 0, 1, 2, ...; padding is untouched; rank[0] is n.
    pub fn validate(self: *const Eytzinger) ValidateError!void {
        if (self.rank[0] != self.n or self.rank.len != self.n + 1) return error.Corrupt;
        if (self.keys.len % lanes != 0 or @intFromPtr(self.keys.ptr) % trace.line_bytes != 0) return error.Corrupt;
        for (self.keys[self.n + 1 ..]) |pad| if (pad != sentinel) return error.Corrupt;
        var next: usize = 0;
        var prev: ?u64 = null;
        try self.walk(1, &next, &prev);
        if (next != self.n) return error.Corrupt;
    }

    fn walk(self: *const Eytzinger, k: usize, next: *usize, prev: *?u64) ValidateError!void {
        if (k > self.n) return;
        try self.walk(2 * k, next, prev);
        if (self.rank[k] != next.*) return error.Corrupt;
        if (prev.*) |p| if (p >= self.keys[k]) return error.Corrupt;
        prev.* = self.keys[k];
        next.* += 1;
        try self.walk(2 * k + 1, next, prev);
    }
};

pub const BlockTree = struct {
    /// Node b owns keys[8b .. 8b+7]. Child j of node b is node 9b + j + 1.
    /// No pointers are stored: the child's position is arithmetic.
    keys: AlignedKeys,
    /// rank[slot] = index in sorted order, n for padding slots. One entry
    /// longer than `keys`: rank[keys.len] = n is the "no key is >= the needle"
    /// answer, so the search can end with one unconditional read.
    rank: []u32,
    n: usize,

    pub const fanout = lanes + 1;

    pub fn init(gpa: Allocator, sorted: []const u64) Allocator.Error!BlockTree {
        const n = sorted.len;
        const slots = std.mem.alignForward(usize, n, lanes);
        const block_keys = try gpa.alignedAlloc(u64, line_align, slots);
        errdefer gpa.free(block_keys);
        const rank = try gpa.alloc(u32, slots + 1);
        @memset(block_keys, sentinel);
        @memset(rank, @intCast(n));
        var self: BlockTree = .{ .keys = block_keys, .rank = rank, .n = n };
        var next: usize = 0;
        self.fill(sorted, 0, &next);
        std.debug.assert(next == n);
        return self;
    }

    pub fn deinit(self: *BlockTree, gpa: Allocator) void {
        gpa.free(self.keys);
        gpa.free(self.rank);
        self.* = undefined;
    }

    pub fn blockCount(self: *const BlockTree) usize {
        return self.keys.len / lanes;
    }

    /// In-order: child 0, key 0, child 1, key 1, ..., key 7, child 8.
    /// When the sorted keys run out the remaining slots keep their sentinel.
    fn fill(self: *BlockTree, sorted: []const u64, block: usize, next: *usize) void {
        if (block >= self.blockCount()) return;
        for (0..lanes) |j| {
            self.fill(sorted, block * fanout + j + 1, next);
            if (next.* < sorted.len) {
                std.debug.assert(sorted[next.*] < sentinel);
                self.keys[block * lanes + j] = sorted[next.*];
                self.rank[block * lanes + j] = @intCast(next.*);
                next.* += 1;
            }
        }
        self.fill(sorted, block * fanout + lanes + 1, next);
    }

    /// Lower bound as an index into the sorted order. Per level: one vector
    /// compare of one line gives the child number r. If r < 8, key r of this
    /// node is the best candidate so far (deeper candidates are smaller and
    /// still >= the needle, so later ones overwrite earlier ones).
    ///
    /// The descent only REMEMBERS the candidate's slot number. It does not
    /// look the rank up on every level: `rank` is another array, and each
    /// lookup there would be another cache line, about one per level, as many
    /// again as the key lines. One read after the loop is enough.
    pub fn lowerBound(self: *const BlockTree, key: u64, tracer: anytype) usize {
        var slot: usize = self.keys.len; // the "no key" entry of rank
        var block: usize = 0;
        const blocks = self.blockCount();
        while (block < blocks) {
            tracer.cmpBlock(block * lanes, lanes);
            const r = search.rank8(self.keys[block * lanes ..][0..lanes], key);
            // A select between two values that are already in registers: no
            // memory is touched. (Exercise 5 removes even this select.)
            slot = if (r < lanes) block * lanes + r else slot;
            block = block * fanout + r + 1;
        }
        tracer.side(slot);
        return self.rank[slot];
    }

    pub fn validate(self: *const BlockTree) ValidateError!void {
        if (self.keys.len + 1 != self.rank.len or self.keys.len != std.mem.alignForward(usize, self.n, lanes)) return error.Corrupt;
        if (self.rank[self.keys.len] != self.n) return error.Corrupt;
        if (@intFromPtr(self.keys.ptr) % trace.line_bytes != 0) return error.Corrupt;
        var next: usize = 0;
        var prev: ?u64 = null;
        try self.walk(0, &next, &prev);
        if (next != self.n) return error.Corrupt;
    }

    fn walk(self: *const BlockTree, block: usize, next: *usize, prev: *?u64) ValidateError!void {
        if (block >= self.blockCount()) return;
        for (0..lanes) |j| {
            try self.walk(block * fanout + j + 1, next, prev);
            const slot = block * lanes + j;
            if (next.* < self.n) {
                if (self.rank[slot] != next.*) return error.Corrupt;
                if (prev.*) |p| if (p >= self.keys[slot]) return error.Corrupt;
                prev.* = self.keys[slot];
                next.* += 1;
            } else if (self.keys[slot] != sentinel or self.rank[slot] != self.n) {
                return error.Corrupt;
            }
        }
        try self.walk(block * fanout + lanes + 1, next, prev);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Trace = trace.Trace;
const NoTrace = trace.NoTrace;
const SplitMix64 = @import("prng.zig").SplitMix64;

test "Eytzinger layout of 15 keys is the breadth-first order of the balanced tree" {
    var sorted: [15]u64 = undefined;
    for (&sorted, 1..) |*k, i| k.* = i * 10;
    var e = try Eytzinger.init(testing.allocator, &sorted);
    defer e.deinit(testing.allocator);
    try e.validate();
    try testing.expectEqualSlices(u64, &.{ 80, 40, 120, 20, 60, 100, 140, 10, 30, 50, 70, 90, 110, 130, 150 }, e.keys[1..16]);
    try testing.expectEqual(16, e.keys.len);
    try testing.expectEqual(0, @intFromPtr(e.keys.ptr) % 64);

    var t: Trace = .init(.{});
    try testing.expectEqual(6, e.lowerBound(70, false, &t));
    try testing.expectEqualSlices(u32, &.{ 1, 2, 5, 11 }, t.probeSlice()); // 80, 40, 60, 70
    try testing.expectEqual(2, t.keyLines()); // slots 1..7 share line 0, slot 11 is in line 1
    try testing.expectEqual(1, t.sideLines()); // rank[11]
    try testing.expectEqual(3, t.linesRead());
    try testing.expectEqual(15, e.lowerBound(151, false, NoTrace{})); // never turned left
}

test "BlockTree of 15 keys: one full leaf and a root with seven keys" {
    var sorted: [15]u64 = undefined;
    for (&sorted, 1..) |*k, i| k.* = i * 10;
    var b = try BlockTree.init(testing.allocator, &sorted);
    defer b.deinit(testing.allocator);
    try b.validate();
    try testing.expectEqualSlices(u64, &.{ 90, 100, 110, 120, 130, 140, 150, sentinel }, b.keys[0..8]);
    try testing.expectEqualSlices(u64, &.{ 10, 20, 30, 40, 50, 60, 70, 80 }, b.keys[8..16]);
    var t: Trace = .init(.{});
    try testing.expectEqual(6, b.lowerBound(70, &t));
    try testing.expectEqual(2, t.steps);
    try testing.expectEqual(2, t.keyLines());
    try testing.expectEqual(1, t.sideLines()); // one rank read, after the descent
    try testing.expectEqual(3, t.linesRead());
    try testing.expectEqual(15, b.rank[b.keys.len]); // the "no key" entry
    try testing.expectEqual(15, b.lowerBound(151, NoTrace{}));
}

test "model test: both layouts agree with the linear oracle on seeded random arrays" {
    const gpa = testing.allocator;
    var rng = SplitMix64.init(25);
    for (0..300) |round| {
        const n: usize = if (round < 100) round else @intCast(rng.below(700));
        const sorted = try gpa.alloc(u64, n);
        defer gpa.free(sorted);
        var key: u64 = 0;
        for (sorted) |*k| {
            key += 1 + rng.below(50);
            k.* = key;
        }
        var e = try Eytzinger.init(gpa, sorted);
        defer e.deinit(gpa);
        var b = try BlockTree.init(gpa, sorted);
        defer b.deinit(gpa);
        const padded = try padToLanes(gpa, sorted);
        defer gpa.free(padded);
        try e.validate();
        try b.validate();
        for (0..64) |_| {
            const needle = rng.below(key + 60);
            const want = search.lowerBoundLinear(sorted, needle);
            var te: Trace = .init(.{});
            var tp: Trace = .init(.{});
            var tb: Trace = .init(.{});
            try testing.expectEqual(want, e.lowerBound(needle, false, &te));
            try testing.expectEqual(want, e.lowerBound(needle, true, &tp));
            try testing.expectEqual(want, b.lowerBound(needle, &tb));
            try testing.expectEqual(want, search.lowerBoundVector(padded, needle, NoTrace{}));
            // Prefetching changes neither the probes nor the lines read.
            try testing.expectEqualSlices(u32, te.probeSlice(), tp.probeSlice());
            try testing.expectEqual(te.linesRead(), tp.linesRead());
            if (n > 0) {
                // Eytzinger depth: floor(log2 n) or one more.
                const depth = std.math.log2_int(usize, n);
                try testing.expect(te.comparisons >= depth and te.comparisons <= depth + 1);
                // Two lines are read without a hint that had lead time: key
                // line 0 (slots 1..7; below 8 keys the clamped hint names line
                // 0 itself, but in the same step as the read) and the rank line.
                try testing.expectEqual(2, tp.uncovered);
                // One key line per level of the 9-way tree.
                try testing.expectEqual(tb.steps, tb.keyLines());
            }
            // Regression (review round 1, G1): the rank array is read, and
            // counted, exactly once per lookup, whatever the depth. Even an
            // empty layout reads its "no key" entry.
            try testing.expectEqual(1, te.sideLines());
            try testing.expectEqual(1, tb.sideLines());
            try testing.expectEqual(te.keyLines() + 1, te.linesRead());
            try testing.expectEqual(tb.keyLines() + 1, tb.linesRead());
            try testing.expectEqual(tb.linesRead(), tb.uncovered); // no hints at all
        }
        try testing.expectEqual(n, e.lowerBound(sentinel, false, NoTrace{}));
        try testing.expectEqual(n, b.lowerBound(sentinel, NoTrace{}));
    }
}

test "validate catches a swapped pair" {
    var sorted: [40]u64 = undefined;
    for (&sorted, 0..) |*k, i| k.* = i;
    var e = try Eytzinger.init(testing.allocator, &sorted);
    defer e.deinit(testing.allocator);
    std.mem.swap(u64, &e.keys[3], &e.keys[4]);
    try testing.expectError(error.Corrupt, e.validate());
    var b = try BlockTree.init(testing.allocator, &sorted);
    defer b.deinit(testing.allocator);
    std.mem.swap(u64, &b.keys[0], &b.keys[1]);
    try testing.expectError(error.Corrupt, b.validate());
    std.mem.swap(u64, &b.keys[0], &b.keys[1]);
    try b.validate();
    b.rank[b.keys.len] = 0; // the "no key" entry must stay n
    try testing.expectError(error.Corrupt, b.validate());
}

fn buildAll(gpa: Allocator, sorted: []const u64) !void {
    var e = try Eytzinger.init(gpa, sorted);
    defer e.deinit(gpa);
    var b = try BlockTree.init(gpa, sorted);
    defer b.deinit(gpa);
    const padded = try padToLanes(gpa, sorted);
    defer gpa.free(padded);
}

test "allocation failure at every allocation leaks nothing" {
    var sorted: [100]u64 = undefined;
    for (&sorted, 0..) |*k, i| k.* = i;
    try testing.checkAllAllocationFailures(testing.allocator, buildAll, .{@as([]const u64, &sorted)});
}
