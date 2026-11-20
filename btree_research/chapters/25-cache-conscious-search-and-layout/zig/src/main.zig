//! Chapter 25: cache-conscious search and layout.
//!
//! `zig build run` prints a fixed, deterministic scenario made only of counts
//! (comparisons, compare instructions, cache lines). It is byte-identical to
//! the Rust twin and to ../expected_output.txt.
//!
//! `zig build run -Doptimize=fast -- --bench` additionally prints wall-clock
//! timings to STDERR. Timings depend on your machine and are never part of
//! the expected output or of any test.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const trace = @import("trace.zig");
const search = @import("search.zig");
const layout = @import("layout.zig");
const node = @import("node.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;
const Trace = trace.Trace;
const NoTrace = trace.NoTrace;

/// Totals over many lookups of one algorithm.
const Stats = struct {
    lookups: u64 = 0,
    comparisons: u64 = 0,
    steps: u64 = 0,
    /// Distinct lines of the key array, of the side array, and both together.
    key_lines: u64 = 0,
    side_lines: u64 = 0,
    lines: u64 = 0,
    max_lines: u64 = 0,
    prefetches: u64 = 0,
    uncovered: u64 = 0,

    fn add(self: *Stats, t: *const Trace) void {
        self.lookups += 1;
        self.comparisons += t.comparisons;
        self.steps += t.steps;
        self.key_lines += t.keyLines();
        self.side_lines += t.sideLines();
        self.lines += t.linesRead();
        self.max_lines = @max(self.max_lines, t.linesRead());
        self.prefetches += t.prefetches;
        self.uncovered += t.uncovered;
    }
};

/// "12.34" for total / count, rounded down, using integers only so that both
/// languages print the same digits.
fn avg(buf: *[24]u8, total: u64, count: u64) []const u8 {
    const hundredths = total * 100 / count;
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ hundredths / 100, hundredths % 100 }) catch unreachable;
}

/// Strictly increasing keys with random gaps of 1..100.
fn makeKeys(gpa: Allocator, n: usize, seed: u64) ![]u64 {
    const keys = try gpa.alloc(u64, n);
    var rng = SplitMix64.init(seed);
    var key: u64 = 0;
    for (keys) |*k| {
        key += 1 + rng.below(100);
        k.* = key;
    }
    return keys;
}

/// Every searchable form of one sorted key set.
const Index = struct {
    /// The sorted keys: a view of `padded` without its padding. It is the
    /// SAME line-aligned memory, so the model's "the array starts on a line
    /// boundary" is true for the classic and halving searches as well. (A
    /// plain `gpa.alloc(u64, n)` only promises 8-byte alignment.)
    sorted: []const u64,
    padded: layout.AlignedKeys,
    eytzinger: layout.Eytzinger,
    blocks: layout.BlockTree,

    fn init(gpa: Allocator, n: usize, seed: u64) !Index {
        const keys = try makeKeys(gpa, n, seed);
        defer gpa.free(keys);
        return build(gpa, keys);
    }

    fn build(gpa: Allocator, keys: []const u64) !Index {
        const padded = try layout.padToLanes(gpa, keys);
        errdefer gpa.free(padded);
        var eytzinger = try layout.Eytzinger.init(gpa, keys);
        errdefer eytzinger.deinit(gpa);
        var blocks = try layout.BlockTree.init(gpa, keys);
        errdefer blocks.deinit(gpa);
        try eytzinger.validate();
        try blocks.validate();
        return .{ .sorted = padded[0..keys.len], .padded = padded, .eytzinger = eytzinger, .blocks = blocks };
    }

    fn deinit(self: *Index, gpa: Allocator) void {
        gpa.free(self.padded);
        self.eytzinger.deinit(gpa);
        self.blocks.deinit(gpa);
    }
};

const Algorithm = enum { classic, halving, vector, eytzinger, blocktree };
const algorithms = [_]Algorithm{ .classic, .halving, .vector, .eytzinger, .blocktree };

fn runOne(index: *const Index, algorithm: Algorithm, needle: u64, t: *Trace) usize {
    return switch (algorithm) {
        .classic => search.lowerBoundClassic(index.sorted, needle, t),
        .halving => search.lowerBoundHalving(.hinted, false, index.sorted, needle, t),
        .vector => search.lowerBoundVector(index.padded, needle, t),
        .eytzinger => index.eytzinger.lowerBound(needle, false, t),
        .blocktree => index.blocks.lowerBound(needle, t),
    };
}

fn printKeys(w: *Io.Writer, keys: []const u64) !void {
    for (keys) |k| {
        if (k == layout.sentinel) try w.writeAll(" -") else try w.print(" {d}", .{k});
    }
}

fn handExample(gpa: Allocator, w: *Io.Writer) !void {
    try w.writeAll("== 1. Fifteen keys by hand ==\n");
    var tens: [15]u64 = undefined;
    for (&tens, 1..) |*k, i| k.* = i * 10;
    var index = try Index.build(gpa, &tens);
    defer index.deinit(gpa);
    const sorted = index.sorted;

    try w.writeAll("sorted    :");
    try printKeys(w, sorted);
    try w.writeAll("\neytzinger :");
    try printKeys(w, index.eytzinger.keys[1..]);
    try w.writeAll("\nblocktree :");
    try printKeys(w, index.blocks.keys[0..8]);
    try w.writeAll(" |");
    try printKeys(w, index.blocks.keys[8..16]);
    try w.writeAll("\n");

    for ([_]u64{ 70, 95, 999 }) |needle| {
        try w.print("needle {d} -> index {d}\n", .{ needle, search.lowerBoundLinear(sorted, needle) });
        for (algorithms) |algorithm| {
            var t: Trace = .init(.keys);
            const got = runOne(&index, algorithm, needle, &t);
            std.debug.assert(got == search.lowerBoundLinear(sorted, needle));
            try w.print("  {t:<9} cmps {d:>2} steps {d} lines {d} (keys {d} + rank {d}) probes", .{
                algorithm, t.comparisons, t.steps, t.linesRead(), t.keyLines(), t.sideLines(),
            });
            for (t.probeSlice()) |p| try w.print(" {d}", .{p});
            try w.writeAll("\n");
        }
    }
}

const lookups_per_size = 1000;

fn sizeTable(gpa: Allocator, w: *Io.Writer, agree: *u64, checksum: *u64) !void {
    try w.print("\n== 2. {d} lookups per size: comparisons and cache lines per lookup ==\n", .{lookups_per_size});
    try w.writeAll("     n  algorithm     cmps   steps  key lines  rank lines   lines  max lines\n");
    for ([_]usize{ 7, 15, 63, 255, 1023, 4095 }) |n| {
        var index = try Index.init(gpa, n, 1000 + n);
        defer index.deinit(gpa);
        var stats: [algorithms.len]Stats = @splat(.{});
        var rng = SplitMix64.init(2000 + n);
        for (0..lookups_per_size) |_| {
            const needle = rng.below(index.sorted[n - 1] + 50);
            const want = search.lowerBoundLinear(index.sorted, needle);
            var all_equal = true;
            for (algorithms, &stats) |algorithm, *s| {
                var t: Trace = .init(.keys);
                const got = runOne(&index, algorithm, needle, &t);
                all_equal = all_equal and got == want;
                s.add(&t);
            }
            agree.* += @intFromBool(all_equal);
            checksum.* += want;
        }
        // The halving search is the one whose cost is known before it runs.
        std.debug.assert(stats[1].comparisons == @as(u64, search.halvingComparisons(n)) * lookups_per_size);
        for (algorithms, &stats) |algorithm, *s| {
            var b1: [24]u8 = undefined;
            var b2: [24]u8 = undefined;
            var b3: [24]u8 = undefined;
            var b4: [24]u8 = undefined;
            var b5: [24]u8 = undefined;
            try w.print("{d:>6}  {t:<9} {s:>8} {s:>7} {s:>10} {s:>11} {s:>7} {d:>10}\n", .{
                n,                                  algorithm,
                avg(&b1, s.comparisons, s.lookups), avg(&b2, s.steps, s.lookups),
                avg(&b3, s.key_lines, s.lookups),   avg(&b4, s.side_lines, s.lookups),
                avg(&b5, s.lines, s.lookups),       s.max_lines,
            });
        }
    }
}

fn nodeLayouts(gpa: Allocator, w: *Io.Writer) !void {
    const capacity = 255;
    try w.print("\n== 3. One {d}-entry node: array of structs vs struct of arrays ==\n", .{capacity});
    const keys = try makeKeys(gpa, capacity, 3000);
    defer gpa.free(keys);
    var soa = try node.SoaNode.init(gpa, capacity);
    defer soa.deinit(gpa);
    var aos = try node.AosNode.init(gpa, capacity);
    defer aos.deinit(gpa);
    // Insert in a shuffled order so that `put` really has to keep the node sorted.
    const order = try gpa.dupe(u64, keys);
    defer gpa.free(order);
    var rng = SplitMix64.init(3001);
    rng.shuffle(order);
    for (order, 0..) |k, i| {
        try soa.put(k, @intCast(i + 1));
        try aos.put(k, @intCast(i + 1));
    }
    try soa.validate();
    try aos.validate();

    // `search`: only the lower bound. `get`: the lower bound, the equality
    // check and, in SoA, the read of the child column.
    var soa_search: Stats = .{};
    var aos_search: Stats = .{};
    var soa_get: Stats = .{};
    var aos_get: Stats = .{};
    var hits: u64 = 0;
    for (0..lookups_per_size) |_| {
        // Half the needles are keys that exist, half are random.
        const needle = if (rng.chance(1, 2)) keys[@intCast(rng.below(capacity))] else rng.below(keys[capacity - 1] + 50);
        var ss: Trace = .init(node.soa_layout);
        var sa: Trace = .init(node.aos_layout);
        const is = soa.lowerBound(needle, &ss);
        const ia = aos.lowerBound(needle, &sa);
        std.debug.assert(is == ia);
        var ts: Trace = .init(node.soa_layout);
        var ta: Trace = .init(node.aos_layout);
        const a = soa.get(needle, &ts);
        const b = aos.get(needle, &ta);
        std.debug.assert(a == b);
        hits += @intFromBool(a != null);
        soa_search.add(&ss);
        aos_search.add(&sa);
        soa_get.add(&ts);
        aos_get.add(&ta);
    }
    try w.writeAll("layout  bytes/key  key bytes  key lines | search: cmps   lines | get: cmps  key lines  child lines   lines  max lines\n");
    for ([_]struct { []const u8, trace.Layout, Stats, Stats }{
        .{ "aos", node.aos_layout, aos_search, aos_get },
        .{ "soa", node.soa_layout, soa_search, soa_get },
    }) |row| {
        var bufs: [6][24]u8 = undefined;
        const bytes = row[1].stride * capacity;
        const s = row[2];
        const g = row[3];
        try w.print("{s:<6} {d:>10} {d:>10} {d:>10} | {s:>12} {s:>7} | {s:>9} {s:>10} {s:>12} {s:>7} {d:>10}\n", .{
            row[0],                                  row[1].stride,
            bytes,                                   (bytes + trace.line_bytes - 1) / trace.line_bytes,
            avg(&bufs[0], s.comparisons, s.lookups), avg(&bufs[1], s.lines, s.lookups),
            avg(&bufs[2], g.comparisons, g.lookups), avg(&bufs[3], g.key_lines, g.lookups),
            avg(&bufs[4], g.side_lines, g.lookups),  avg(&bufs[5], g.lines, g.lookups),
            g.max_lines,
        });
    }
    try w.print("found {d} of {d} needles; both layouts returned the same child every time\n", .{ hits, lookups_per_size });
}

fn prefetchTable(gpa: Allocator, w: *Io.Writer) !void {
    const n = 4095;
    try w.print("\n== 4. Prefetch coverage, n = {d}, per lookup ==\n", .{n});
    var index = try Index.init(gpa, n, 1000 + n);
    defer index.deinit(gpa);
    var stats: [4]Stats = @splat(.{});
    var rng = SplitMix64.init(4000);
    for (0..lookups_per_size) |_| {
        const needle = rng.below(index.sorted[n - 1] + 50);
        var traces: [4]Trace = @splat(.init(.keys));
        const r0 = search.lowerBoundHalving(.hinted, false, index.sorted, needle, &traces[0]);
        const r1 = search.lowerBoundHalving(.hinted, true, index.sorted, needle, &traces[1]);
        const r2 = index.eytzinger.lowerBound(needle, false, &traces[2]);
        const r3 = index.eytzinger.lowerBound(needle, true, &traces[3]);
        std.debug.assert(r0 == r1 and r1 == r2 and r2 == r3);
        for (&stats, &traces) |*s, *t| s.add(t);
    }
    try w.writeAll("algorithm            lines   hints  lines not hinted\n");
    const names = [_][]const u8{ "halving", "halving+prefetch", "eytzinger", "eytzinger+prefetch" };
    for (names, &stats) |name, *s| {
        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        var b3: [24]u8 = undefined;
        try w.print("{s:<18} {s:>7} {s:>7} {s:>17}\n", .{
            name,                              avg(&b1, s.lines, s.lookups),
            avg(&b2, s.prefetches, s.lookups), avg(&b3, s.uncovered, s.lookups),
        });
    }
}

/// The whole deterministic scenario. Tests call it with an in-memory writer.
pub fn scenario(gpa: Allocator, w: *Io.Writer) !void {
    try w.writeAll("Chapter 25: cache-conscious search and layout\n");
    try w.writeAll("model: 64-byte cache lines, 8-byte keys, 4-byte ranks, every array starts on a line boundary\n");
    try w.writeAll("lines = key lines + rank lines: every array a lookup reads is counted\n\n");
    try handExample(gpa, w);
    var agree: u64 = 0;
    var checksum: u64 = 0;
    try sizeTable(gpa, w, &agree, &checksum);
    try nodeLayouts(gpa, w);
    try prefetchTable(gpa, w);
    try w.writeAll("\n== 5. Agreement ==\n");
    try w.print("all five algorithms returned the linear-scan answer in {d} of {d} lookups\n", .{ agree, 6 * lookups_per_size });
    try w.print("checksum of answers: {d}\n", .{checksum});
}

/// Optional micro-benchmark. STDERR only; numbers vary by machine and build
/// mode and mean nothing in a debug build.
fn bench(gpa: Allocator, io: Io) !void {
    std.debug.print("micro-benchmark (stderr only; build with -Doptimize=fast for meaningful numbers)\n", .{});
    for ([_]usize{ 15, 255, 4095 }) |n| {
        var index = try Index.init(gpa, n, 1000 + n);
        defer index.deinit(gpa);
        const needles = try gpa.alloc(u64, 1 << 16);
        defer gpa.free(needles);
        var rng = SplitMix64.init(9);
        for (needles) |*x| x.* = rng.below(index.sorted[n - 1] + 50);
        inline for (.{ "classic", "halving-branch", "halving-arith", "halving-hinted", "halving+prefetch", "vector", "eytzinger", "eytzinger+prefetch", "blocktree" }, 0..) |name, which| {
            const start = Io.Clock.awake.now(io);
            var sum: usize = 0;
            for (0..8) |_| for (needles) |x| {
                sum +%= switch (which) {
                    0 => search.lowerBoundClassic(index.sorted, x, NoTrace{}),
                    1 => search.lowerBoundHalving(.branch, false, index.sorted, x, NoTrace{}),
                    2 => search.lowerBoundHalving(.arithmetic, false, index.sorted, x, NoTrace{}),
                    3 => search.lowerBoundHalving(.hinted, false, index.sorted, x, NoTrace{}),
                    4 => search.lowerBoundHalving(.hinted, true, index.sorted, x, NoTrace{}),
                    5 => search.lowerBoundVector(index.padded, x, NoTrace{}),
                    6 => index.eytzinger.lowerBound(x, false, NoTrace{}),
                    7 => index.eytzinger.lowerBound(x, true, NoTrace{}),
                    else => index.blocks.lowerBound(x, NoTrace{}),
                };
            };
            std.mem.doNotOptimizeAway(sum);
            const ns: u64 = @intCast(start.untilNow(io, .awake).toNanoseconds());
            const centi = ns * 100 / (8 * needles.len);
            std.debug.print("  n={d:>5} {s:<19} {d:>4}.{d:0>2} ns/lookup\n", .{ n, name, centi / 100, centi % 100 });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try scenario(gpa, stdout);
    try stdout.flush();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--bench")) try bench(gpa, init.io);
    }
}

test "the scenario prints exactly expected_output.txt" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try scenario(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}

// Regression (review round 1, G6): the header says every array starts on a
// line boundary; the array the classic and halving searches run on used to
// come from a plain `gpa.alloc(u64, n)`, which starts 16 bytes into a line
// for small n.
test "the scenario searches line-aligned keys" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 7, 15, 63, 255 }) |n| {
        var index = try Index.init(gpa, n, 1000 + n);
        defer index.deinit(gpa);
        try std.testing.expectEqual(n, index.sorted.len);
        try std.testing.expectEqual(0, @intFromPtr(index.sorted.ptr) % trace.line_bytes);
        const keys = try makeKeys(gpa, n, 1000 + n);
        defer gpa.free(keys);
        try std.testing.expectEqualSlices(u64, keys, index.sorted);
    }
}

test "the scenario survives allocation failure at every allocation" {
    const Run = struct {
        fn run(gpa: Allocator) !void {
            var buf: [16384]u8 = undefined;
            var w: Io.Writer = .fixed(&buf);
            try handExample(gpa, &w);
            try nodeLayouts(gpa, &w);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}

test {
    // Make `zig build test` reach the tests of every file.
    _ = trace;
    _ = search;
    _ = layout;
    _ = node;
    _ = @import("prng.zig");
}
