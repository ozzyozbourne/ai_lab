//! A cache-line accounting model.
//!
//! Chapter 01 counted page reads instead of comparisons. This chapter zooms in
//! one level: inside a page (or inside any in-memory array) the unit of cost
//! is the 64-byte cache line. Every search algorithm in this chapter takes a
//! `tracer` and reports each key it looks at. Two tracers exist:
//!
//!   * `NoTrace`: every method is empty, so the compiler removes the calls.
//!     This is the code you would ship.
//!   * `*Trace`: counts comparisons and remembers which cache lines were read.
//!
//! Because the same function body runs with both, the counted algorithm cannot
//! drift from the fast one. The model is deliberately simple: it assumes the
//! array starts on a cache-line boundary (the layouts in layout.zig really are
//! allocated that way) and it knows nothing about TLBs, the hardware
//! prefetcher or cache sizes. It produces counts, never timings.
const std = @import("std");

/// Bytes per cache line on every mainstream x86-64 and most AArch64 CPUs.
pub const line_bytes = 64;
/// u64 keys that fit in one line; also the lane count of our vectors.
pub const lanes = line_bytes / @sizeOf(u64);
/// Largest array the model can describe: 2048 lines = 128 KiB.
pub const max_lines = 2048;
/// How many probe positions a trace remembers (enough for any binary search).
pub const max_probes = 16;

/// Where the key of element `i` lives: byte `i * stride + offset` of the array.
/// A plain `[]u64` has stride 8. An array of 16-byte `{key, child}` structs
/// has stride 16: only four keys share a line.
pub const Layout = struct {
    stride: usize = @sizeOf(u64),
    offset: usize = 0,

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
        std.debug.assert(line < max_lines);
        const bit = @as(u64, 1) << @intCast(line % 64);
        const fresh = self.words[line / 64] & bit == 0;
        self.words[line / 64] |= bit;
        self.count += @intFromBool(fresh);
        return fresh;
    }

    pub fn contains(self: *const LineSet, line: usize) bool {
        return self.words[line / 64] & (@as(u64, 1) << @intCast(line % 64)) != 0;
    }
};

pub const Trace = struct {
    layout: Layout = .{},
    /// Key comparisons. A vector compare of 8 lanes counts as 8.
    comparisons: u32 = 0,
    /// Compare instructions: 1 per scalar compare, 1 per 8-lane vector compare.
    steps: u32 = 0,
    /// Prefetch hints issued.
    prefetches: u32 = 0,
    /// Distinct lines the comparisons read.
    read: LineSet = .{},
    /// Distinct lines named by prefetch hints.
    hinted: LineSet = .{},
    /// Lines read for the first time that no earlier hint had asked for. On a
    /// cold cache each of these is a miss the CPU must wait for before it can
    /// even compute the next address. Hinted lines are already on their way.
    uncovered: u32 = 0,
    /// The first `max_probes` element indexes compared, for the hand example.
    probes: [max_probes]u32 = @splat(0),
    probe_len: u32 = 0,

    pub fn init(layout: Layout) Trace {
        return .{ .layout = layout };
    }

    /// One scalar comparison against element `index`.
    pub fn cmp(self: *Trace, index: usize) void {
        self.comparisons += 1;
        self.steps += 1;
        self.note(index);
        self.readLine(self.layout.lineOf(index));
    }

    /// One vector comparison against elements `index .. index + count - 1`.
    pub fn cmpBlock(self: *Trace, index: usize, count: usize) void {
        self.comparisons += @intCast(count);
        self.steps += 1;
        self.note(index);
        var line = self.layout.lineOf(index);
        const last = self.layout.lineOf(index + count - 1);
        while (line <= last) : (line += 1) self.readLine(line);
    }

    /// A prefetch hint for the line holding element `index`.
    pub fn prefetch(self: *Trace, index: usize) void {
        self.prefetches += 1;
        _ = self.hinted.insert(self.layout.lineOf(index));
    }

    pub fn linesRead(self: *const Trace) u32 {
        return self.read.count;
    }

    pub fn probeSlice(self: *const Trace) []const u32 {
        return self.probes[0..self.probe_len];
    }

    fn readLine(self: *Trace, line: usize) void {
        if (self.read.insert(line) and !self.hinted.contains(line)) self.uncovered += 1;
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
};

test "Layout: eight u64 keys per line, four 16-byte entries per line" {
    const plain: Layout = .{};
    try std.testing.expectEqual(0, plain.lineOf(7));
    try std.testing.expectEqual(1, plain.lineOf(8));
    const aos: Layout = .{ .stride = 16 };
    try std.testing.expectEqual(0, aos.lineOf(3));
    try std.testing.expectEqual(1, aos.lineOf(4));
}

test "Trace: distinct lines, vector steps and prefetch coverage" {
    var t: Trace = .init(.{});
    t.cmp(0);
    t.cmp(7); // same line as index 0
    t.cmp(8); // second line
    try std.testing.expectEqual(3, t.comparisons);
    try std.testing.expectEqual(2, t.linesRead());
    try std.testing.expectEqual(2, t.uncovered);

    t.prefetch(100); // line 12, hinted before it is read
    t.cmp(100);
    try std.testing.expectEqual(3, t.linesRead());
    try std.testing.expectEqual(2, t.uncovered); // the hinted line is covered

    t.cmpBlock(16, 8); // one instruction, eight lanes, one line
    try std.testing.expectEqual(12, t.comparisons);
    try std.testing.expectEqual(5, t.steps);
    try std.testing.expectEqual(4, t.linesRead());
    try std.testing.expectEqualSlices(u32, &.{ 0, 7, 8, 100, 16 }, t.probeSlice());
}
