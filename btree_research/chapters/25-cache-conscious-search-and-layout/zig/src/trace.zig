//! A cache-line accounting model.
//!
//! Chapter 01 counted page reads instead of comparisons. This chapter zooms in
//! one level: inside a page (or inside any in-memory array) the unit of cost
//! is the 64-byte cache line. Every search algorithm in this chapter takes a
//! `tracer` and reports every memory read that depends on the needle. Two
//! tracers exist:
//!
//!   * `NoTrace`: every method is empty, so the compiler removes the calls.
//!     This is the code you would ship.
//!   * `*Trace`: counts comparisons and remembers which cache lines were read.
//!
//! Because the same function body runs with both, the counted algorithm cannot
//! drift from the fast one.
//!
//! What the model counts. A lookup may read two arrays: the KEY array
//! (`cmp`, `cmpBlock`) and a SIDE array of 4-byte entries (`side`): the `rank`
//! array of the layouts in layout.zig, or the child column of a
//! struct-of-arrays node. `linesRead()` is the sum of the distinct lines of
//! both, so a lookup cannot hide a read in an array the model does not see.
//!
//! What the model assumes. Each array starts on a cache-line boundary. That
//! is true for every key array the fixed scenario searches with
//! `Layout.keys` (they come from `alignedAlloc`, see layout.zig). It is NOT
//! guaranteed for the two node types in node.zig, whose containers align to 8
//! bytes: their counts describe a node that starts on a line boundary, and a
//! node that does not can touch one line more. A side read is one 4-byte
//! entry, which lies inside one line wherever its array starts, and the model
//! takes the side array to share no line with the key array.
//!
//! The model knows nothing about TLBs, the hardware prefetcher or cache
//! sizes. It produces counts, never timings.
const std = @import("std");

/// Bytes per cache line on every mainstream x86-64 and most AArch64 CPUs.
pub const line_bytes = 64;
/// u64 keys that fit in one line; also the lane count of our vectors.
pub const lanes = line_bytes / @sizeOf(u64);
/// Largest array the model can describe: 2048 lines = 128 KiB.
pub const max_lines = 2048;
/// How many probe positions a trace remembers (enough for any binary search).
pub const max_probes = 16;
/// Prefetch hints that may be issued between two comparisons.
pub const max_pending = 4;

/// Where the key of element `i` lives: byte `i * stride + offset` of the array.
/// A plain `[]u64` has stride 8. An array of 16-byte `{key, child}` structs
/// has stride 16: only four keys share a line.
pub const Layout = struct {
    stride: usize = @sizeOf(u64),
    offset: usize = 0,

    /// A dense array of u64 keys: eight per line.
    pub const keys: Layout = .{};
    /// A dense array of u32 ranks or child ids: sixteen per line.
    pub const side: Layout = .{ .stride = @sizeOf(u32) };

    pub fn lineOf(self: Layout, index: usize) usize {
        return (index * self.stride + self.offset) / line_bytes;
    }
};

/// A set of cache-line numbers as a fixed bitmap. No allocation: a trace is
/// created and thrown away for every single lookup.
pub const LineSet = struct {
    words: [max_lines / 64]u64 = @splat(0),
    count: u32 = 0,

    /// Adds `line`; returns true when it was not in the set before.
    pub fn insert(self: *LineSet, line: usize) bool {
        // A real check, not an assert: in ReleaseFast an assert is assumed
        // true and a larger array would silently write outside `words`.
        if (line >= max_lines) @panic("trace: the array is larger than the model's max_lines");
        const bit = @as(u64, 1) << @intCast(line % 64);
        const fresh = self.words[line / 64] & bit == 0;
        self.words[line / 64] |= bit;
        self.count += @intFromBool(fresh);
        return fresh;
    }

    pub fn contains(self: *const LineSet, line: usize) bool {
        if (line >= max_lines) return false;
        return self.words[line / 64] & (@as(u64, 1) << @intCast(line % 64)) != 0;
    }
};

pub const Trace = struct {
    /// Where the keys are (the array `cmp` and `cmpBlock` index).
    layout: Layout = .keys,
    /// Where the side entries are (the array `side` indexes).
    side_layout: Layout = .side,
    /// Key comparisons. A vector compare of 8 lanes counts as 8.
    comparisons: u32 = 0,
    /// Compare instructions: 1 per scalar compare, 1 per 8-lane vector compare.
    steps: u32 = 0,
    /// Prefetch hints issued.
    prefetches: u32 = 0,
    /// Distinct lines of the key array that were read.
    read: LineSet = .{},
    /// Distinct lines of the side array that were read.
    side_read: LineSet = .{},
    /// Key lines named by a hint that has had lead time: at least one
    /// comparison was made between the hint and now.
    hinted: LineSet = .{},
    /// Key lines hinted since the last comparison. A hint issued immediately
    /// before the read it names has bought nothing: the load still has to
    /// wait for the whole miss. So these do not cover the next read; they
    /// move to `hinted` once that comparison is done.
    pending: [max_pending]u32 = @splat(0),
    pending_len: u32 = 0,
    /// Lines (of either array) read for the first time without a hint that
    /// had lead time. On a cold cache each of these is a miss the CPU must
    /// wait for before it can even compute the next address. Hinted lines
    /// are already on their way.
    uncovered: u32 = 0,
    /// The first `max_probes` element indexes compared, for the hand example.
    probes: [max_probes]u32 = @splat(0),
    probe_len: u32 = 0,

    pub fn init(layout: Layout) Trace {
        return .{ .layout = layout };
    }

    /// One scalar comparison against key `index`.
    pub fn cmp(self: *Trace, index: usize) void {
        self.comparisons += 1;
        self.steps += 1;
        self.note(index);
        self.readLine(self.layout.lineOf(index));
        self.settleHints();
    }

    /// One vector comparison against keys `index .. index + count - 1`.
    pub fn cmpBlock(self: *Trace, index: usize, count: usize) void {
        self.comparisons += @intCast(count);
        self.steps += 1;
        self.note(index);
        var line = self.layout.lineOf(index);
        const last = self.layout.lineOf(index + count - 1);
        while (line <= last) : (line += 1) self.readLine(line);
        self.settleHints();
    }

    /// A prefetch hint for the line holding key `index`.
    pub fn prefetch(self: *Trace, index: usize) void {
        self.prefetches += 1;
        // A real check, not an assert, for the same reason as in
        // `LineSet.insert`: in ReleaseFast an assert is assumed true and a
        // fifth hint would be written past the end of `pending`.
        if (self.pending_len == max_pending) @panic("trace: more than max_pending hints between two comparisons");
        self.pending[self.pending_len] = @intCast(self.layout.lineOf(index));
        self.pending_len += 1;
    }

    /// One read of entry `index` of the side array (a rank or a child id).
    /// Nothing in this chapter prefetches the side array, so a first read of
    /// one of its lines is always uncovered.
    pub fn side(self: *Trace, index: usize) void {
        if (self.side_read.insert(self.side_layout.lineOf(index))) self.uncovered += 1;
    }

    /// Distinct key-array lines read.
    pub fn keyLines(self: *const Trace) u32 {
        return self.read.count;
    }

    /// Distinct side-array lines read.
    pub fn sideLines(self: *const Trace) u32 {
        return self.side_read.count;
    }

    /// Every distinct line the lookup read, in both arrays.
    pub fn linesRead(self: *const Trace) u32 {
        return self.read.count + self.side_read.count;
    }

    pub fn probeSlice(self: *const Trace) []const u32 {
        return self.probes[0..self.probe_len];
    }

    fn readLine(self: *Trace, line: usize) void {
        if (self.read.insert(line) and !self.hinted.contains(line)) self.uncovered += 1;
    }

    /// The comparison that just ran is the lead time of every pending hint.
    fn settleHints(self: *Trace) void {
        for (self.pending[0..self.pending_len]) |line| _ = self.hinted.insert(line);
        self.pending_len = 0;
    }

    fn note(self: *Trace, index: usize) void {
        if (self.probe_len < max_probes) {
            self.probes[self.probe_len] = @intCast(index);
            self.probe_len += 1;
        }
    }
};

/// The tracer that does nothing. `inline` plus empty bodies means a search
/// instantiated with `NoTrace` compiles to exactly the untraced loop.
pub const NoTrace = struct {
    pub inline fn cmp(_: NoTrace, _: usize) void {}
    pub inline fn cmpBlock(_: NoTrace, _: usize, _: usize) void {}
    pub inline fn prefetch(_: NoTrace, _: usize) void {}
    pub inline fn side(_: NoTrace, _: usize) void {}
};

test "Layout: eight u64 keys per line, four 16-byte entries per line" {
    const plain: Layout = .keys;
    try std.testing.expectEqual(0, plain.lineOf(7));
    try std.testing.expectEqual(1, plain.lineOf(8));
    const aos: Layout = .{ .stride = 16 };
    try std.testing.expectEqual(0, aos.lineOf(3));
    try std.testing.expectEqual(1, aos.lineOf(4));
    try std.testing.expectEqual(0, Layout.side.lineOf(15));
    try std.testing.expectEqual(1, Layout.side.lineOf(16));
}

test "Trace: distinct lines, vector steps and prefetch coverage" {
    var t: Trace = .init(.keys);
    t.cmp(0);
    t.cmp(7); // same line as index 0
    t.cmp(8); // second line
    try std.testing.expectEqual(3, t.comparisons);
    try std.testing.expectEqual(2, t.linesRead());
    try std.testing.expectEqual(2, t.uncovered);

    t.prefetch(100); // line 12, hinted one comparison before it is read
    t.cmp(50); // line 6: the lead time of the hint
    t.cmp(100);
    try std.testing.expectEqual(4, t.linesRead());
    try std.testing.expectEqual(3, t.uncovered); // line 6 was a surprise, line 12 was not

    t.cmpBlock(16, 8); // one instruction, eight lanes, one line
    try std.testing.expectEqual(13, t.comparisons);
    try std.testing.expectEqual(6, t.steps);
    try std.testing.expectEqual(5, t.linesRead());
    try std.testing.expectEqualSlices(u32, &.{ 0, 7, 8, 50, 100, 16 }, t.probeSlice());
}

// Regression (review round 1, G4): a hint used to "cover" a read that came
// straight after it, so a 15-key search reported no surprising line at all.
test "Trace: a hint with no comparison in between does not cover the read" {
    var t: Trace = .init(.keys);
    t.prefetch(100);
    t.cmp(100); // same step as the hint: the miss is not hidden
    try std.testing.expectEqual(1, t.uncovered);
    t.prefetch(200);
    t.prefetch(300);
    t.cmp(100); // lead time for both hints
    t.cmp(200);
    t.cmp(300);
    try std.testing.expectEqual(1, t.uncovered);
    try std.testing.expectEqual(3, t.prefetches);
    try std.testing.expectEqual(3, t.keyLines());
}

// Regression (review round 2, G-R2-9): the bound on `pending` was only an
// assert. The buffer must take exactly `max_pending` hints between two
// comparisons, and be empty again after the comparison.
test "Trace: max_pending hints between two comparisons fit, and all get lead time" {
    var t: Trace = .init(.keys);
    for (0..3) |round| {
        for (0..max_pending) |i| t.prefetch(8 * (1 + round * max_pending + i));
        try std.testing.expectEqual(max_pending, t.pending_len);
        t.cmp(0); // lead time for all of them; the buffer is free again
        try std.testing.expectEqual(0, t.pending_len);
    }
    for (0..3 * max_pending) |i| t.cmp(8 * (1 + i)); // every one of these lines was hinted in time
    try std.testing.expectEqual(1, t.uncovered); // only line 0
    try std.testing.expectEqual(3 * max_pending, t.prefetches);
    try std.testing.expectEqual(3 * max_pending + 1, t.keyLines());
}

// Regression (review round 1, G1): reads of the rank / child array were
// invisible to the model.
test "Trace: side-array reads are lines too, counted apart from key lines" {
    var t: Trace = .init(.keys);
    t.cmp(0);
    t.side(0); // entry 0 of ANOTHER array: a second line, not key line 0
    t.side(15); // sixteen 4-byte entries share a line
    t.side(16);
    try std.testing.expectEqual(1, t.keyLines());
    try std.testing.expectEqual(2, t.sideLines());
    try std.testing.expectEqual(3, t.linesRead());
    try std.testing.expectEqual(3, t.uncovered);
    try std.testing.expectEqual(1, t.comparisons); // a side read is not a comparison
}
