// Chapter 12, "Measure, and Know When Not To": three ways a benchmark lies to you, measured.
//   (a) ch12-deadcode  one sum of squares timed three ways: result discarded (the optimizer deletes it),
//                      input visible to the optimizer (the loop becomes a formula), and kept alive (honest)
//   (b) ch12-noise     a 16 KiB and a 16 MiB sum, each timed SAMPLES times; every sample is printed for bench-dist
//   (c) ch12-aa        an A/A test: the same kernel as "A" and "B", timed A-then-B and A,B,A,B
// Usage: zig run -O fast main.zig -- [N] [--quick]

// ---- harness ----
const std = @import("std");
const Io = std.Io;

const RUNS = 7;

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// Runs `f(ctx)` once to warm up, then RUNS timed times. Returns the sorted timings in ns.
fn benchRuns(io: Io, comptime f: anytype, ctx: anytype) [RUNS]u64 {
    std.mem.doNotOptimizeAway(f(ctx));
    var t: [RUNS]u64 = undefined;
    for (&t) |*slot| {
        const t0 = nowNs(io);
        std.mem.doNotOptimizeAway(f(ctx));
        slot.* = @intCast(nowNs(io) - t0);
    }
    std.mem.sort(u64, &t, {}, std.sort.asc(u64));
    return t;
}

/// Median of RUNS timed runs (after one warm-up run), in ns.
fn bench(io: Io, comptime f: anytype, ctx: anytype) u64 {
    return benchRuns(io, f, ctx)[RUNS / 2];
}

const Args = struct { n: usize, quick: bool };

/// Positional integer N (default 1 << 20) and `--quick` (caps N at 1 << 12).
fn parseArgs(init: std.process.Init) !Args {
    var n: usize = 1 << 20;
    var quick = false;
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--quick")) quick = true else n = try std.fmt.parseInt(usize, a, 10);
    }
    if (quick) n = @min(n, 1 << 12);
    return .{ .n = n, .quick = quick };
}

/// Prints one machine-readable line for bench_all.sh:
/// BENCH {"id":"chNN-x","label":"...","lang":"zig","n":N,"ns":median,"samples":[...]}
/// `runs` must be sorted (as returned by `benchRuns`). Labels must not contain `"` or `\`.
fn emitBench(out: *Io.Writer, id: []const u8, label: []const u8, n: usize, runs: []const u64) !void {
    try out.print("BENCH {{\"id\":\"{s}\",\"label\":\"{s}\",\"lang\":\"zig\",\"n\":{d},\"ns\":{d},\"samples\":[", .{ id, label, n, runs[runs.len / 2] });
    for (runs, 0..) |r, i| try out.print("{s}{d}", .{ if (i == 0) "" else ",", r });
    try out.writeAll("]}\n");
}
// ---- harness ----

/// A layout guard: compilation fails if someone grows the hot record.
const Particle = struct { pos: [3]f32, vel: [3]f32, alive: bool, kind: u8 };
comptime {
    std.debug.assert(@sizeOf(Particle) == 28);
}

test "Particle stays 28 bytes" {
    try std.testing.expectEqual(28, @sizeOf(Particle));
    try std.testing.expectEqual(4, @alignOf(Particle));
}

/// Timed runs per noise sample set (bench-dist draws every one of them).
const SAMPLES = 41;
/// Timed runs per side of the A/A test, and how many times the whole test is repeated.
const AA = 31;
const AA_ROUNDS = 7;

/// Below this many ns per element, a loop over memory is not believable: at 2.6 GHz it would
/// mean about 8 elements per clock cycle, more than this loop can sustain. The honest run takes about 0.4 ns.
const min_plausible_ns_per_elem = 0.05;

/// The kernel for the dead-code demo: a wrapping sum of squares over a slice.
fn sumSquares(v: []const u64) u64 {
    var s: u64 = 0;
    for (v) |x| s +%= x *% x;
    return s;
}

/// The same sum with no input data: v[i] = i, so the loop only needs n.
fn sumSquaresRange(n: u64) u64 {
    var s: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) s +%= i *% i;
    return s;
}

/// Does nothing: timing it measures only the two clock reads.
fn empty(_: void) u64 {
    return 0;
}

/// A broken harness: identical to `benchRuns`, except that the result is thrown away.
fn benchRunsDiscarding(io: Io, comptime f: anytype, ctx: anytype) [RUNS]u64 {
    _ = f(ctx);
    var t: [RUNS]u64 = undefined;
    for (&t) |*slot| {
        const t0 = nowNs(io);
        _ = f(ctx); // nothing reads this, so the optimizer may delete the call
        slot.* = @intCast(nowNs(io) - t0);
    }
    std.mem.sort(u64, &t, {}, std.sort.asc(u64));
    return t;
}

/// Two sanity checks every timing should pass before anyone looks at a ratio.
fn verdict(ns: u64, timer_floor: u64, n: usize) []const u8 {
    const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
    if (ns < 2 * timer_floor) return "<- SUSPICIOUS: no slower than timing nothing";
    if (per < min_plausible_ns_per_elem) return "<- SUSPICIOUS: faster than the core can do the work";
    return "plausible";
}

/// The noise kernel: sum a slice of u32 into a u64.
fn sumU32(v: []const u32) u64 {
    var s: u64 = 0;
    for (v) |x| s += x;
    return s;
}

/// Same input in all three languages: x[i] = i * 2654435761 (mod 2^32).
fn makeU32(gpa: std.mem.Allocator, n: usize) ![]u32 {
    const x = try gpa.alloc(u32, n);
    for (x, 0..) |*e, i| e.* = @as(u32, @truncate(i)) *% 2_654_435_761;
    return x;
}

/// `benchRuns` with K timed runs instead of RUNS: one warm-up, then K sorted timings.
fn sampleRuns(io: Io, comptime K: usize, comptime f: anytype, ctx: anytype) [K]u64 {
    std.mem.doNotOptimizeAway(f(ctx));
    var t: [K]u64 = undefined;
    for (&t) |*slot| {
        const t0 = nowNs(io);
        std.mem.doNotOptimizeAway(f(ctx));
        slot.* = @intCast(nowNs(io) - t0);
    }
    std.mem.sort(u64, &t, {}, std.sort.asc(u64));
    return t;
}

/// Coefficient of variation: sample standard deviation divided by the mean.
fn cv(runs: []const u64) f64 {
    var mean: f64 = 0;
    for (runs) |r| mean += @floatFromInt(r);
    mean /= @floatFromInt(runs.len);
    var v: f64 = 0;
    for (runs) |r| v += std.math.pow(f64, @as(f64, @floatFromInt(r)) - mean, 2);
    v /= @floatFromInt(runs.len - 1);
    return @sqrt(v) / mean;
}

fn med(runs: []const u64) f64 {
    return @floatFromInt(runs[runs.len / 2]);
}

const Pair = struct { a: [AA]u64, b: [AA]u64 };

/// A/A test, sequential: all AA runs of "A", then all AA runs of "B". Same code, different buffers.
fn aaSequential(io: Io, a: []const u32, b: []const u32) Pair {
    return .{ .a = sampleRuns(io, AA, sumU32, a), .b = sampleRuns(io, AA, sumU32, b) };
}

/// A/A test, alternating: A, B, A, B, ... so slow drift hits both sides equally.
fn aaAlternating(io: Io, a: []const u32, b: []const u32) Pair {
    std.mem.doNotOptimizeAway(sumU32(a));
    std.mem.doNotOptimizeAway(sumU32(b));
    var p: Pair = undefined;
    for (&p.a, &p.b) |*ta, *tb| {
        var t0 = nowNs(io);
        std.mem.doNotOptimizeAway(sumU32(a));
        ta.* = @intCast(nowNs(io) - t0);
        t0 = nowNs(io);
        std.mem.doNotOptimizeAway(sumU32(b));
        tb.* = @intCast(nowNs(io) - t0);
    }
    std.mem.sort(u64, &p.a, {}, std.sort.asc(u64));
    std.mem.sort(u64, &p.b, {}, std.sort.asc(u64));
    return p;
}

fn printRatios(out: *Io.Writer, name: []const u8, xs: []const f64) !void {
    try out.print("    {s:<11}", .{name});
    var d: [AA_ROUNDS]f64 = undefined;
    for (xs, &d) |r, *e| {
        try out.print(" {d:.3}", .{r});
        e.* = @abs(r - 1.0);
    }
    std.mem.sort(f64, &d, {}, std.sort.asc(f64));
    try out.print("  |B/A-1| median {d:.1}%, worst {d:.1}%\n", .{ 100.0 * d[d.len / 2], 100.0 * d[d.len - 1] });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;
    const args = try parseArgs(init);
    const n = args.n;

    // ---- (a) dead code: the same work, timed three ways ----
    const v = try gpa.alloc(u64, n);
    defer gpa.free(v);
    for (v, 0..) |*x, i| x.* = i;
    const vc: []const u64 = v;
    const timer_only = benchRuns(io, empty, {});
    const discarded = benchRunsDiscarding(io, sumSquares, vc);
    const folded = benchRuns(io, sumSquaresRange, @as(u64, n));
    const kept = benchRuns(io, sumSquares, vc);
    try out.print("(a) sum of squares over {d} u64, median of {d}:\n", .{ n, RUNS });
    const rows = [_]struct { []const u8, [RUNS]u64 }{
        .{ "empty (timer only)", timer_only },
        .{ "result discarded", discarded },
        .{ "input visible", folded },
        .{ "kept alive", kept },
    };
    for (rows) |r| {
        const m = r[1][RUNS / 2];
        try out.print("    {s:<17} {d:>12} ns  {d:>9.4} ns/elem  {s}\n", .{
            r[0], m, @as(f64, @floatFromInt(m)) / @as(f64, @floatFromInt(n)), if (std.mem.startsWith(u8, r[0], "empty")) "(the floor: two clock reads)" else verdict(m, timer_only[RUNS / 2], n),
        });
        try emitBench(out, "ch12-deadcode", r[0], n, &r[1]);
    }
    try out.print("    checksum: kept alive {d}, input visible {d}\n", .{ sumSquares(v), sumSquaresRange(n) });

    // ---- (b) noise: one kernel, many samples ----
    try out.print("(b) noise, {d} timed runs each:\n", .{SAMPLES});
    const kernels = [_]struct { []const u8, usize }{ .{ "16 KiB (L1)", 1 << 12 }, .{ "16 MiB (L3/DRAM)", 1 << 22 } };
    for (kernels) |kr| {
        const x = try makeU32(gpa, kr[1]);
        defer gpa.free(x);
        const xc: []const u32 = x;
        const runs = sampleRuns(io, SAMPLES, sumU32, xc);
        try out.print("    {s:<17} min {d:>10} ns  median {d:>10} ns  max {d:>10} ns  CV {d:>5.1}%  checksum {d}\n", .{
            kr[0], runs[0], runs[SAMPLES / 2], runs[SAMPLES - 1], 100.0 * cv(&runs), sumU32(x),
        });
        try emitBench(out, "ch12-noise", kr[0], kr[1], &runs);
    }

    // ---- (c) A/A test: sequential versus alternating ----
    const len: usize = 1 << 16; // 256 KiB per buffer: both fit in L2 together
    const a = try makeU32(gpa, len);
    defer gpa.free(a);
    const b = try makeU32(gpa, len);
    defer gpa.free(b);
    try out.print("(c) A/A test on 2 x 256 KiB, {d} runs per side; B/A ratio of medians (truth: 1.000)\n", .{AA});
    var seq: [AA_ROUNDS]f64 = undefined;
    var alt: [AA_ROUNDS]f64 = undefined;
    for (0..AA_ROUNDS) |round| {
        const s = aaSequential(io, a, b);
        const t = aaAlternating(io, a, b);
        seq[round] = med(&s.b) / med(&s.a);
        alt[round] = med(&t.b) / med(&t.a);
        if (round == 0) {
            try emitBench(out, "ch12-aa", "A, sequential", len, &s.a);
            try emitBench(out, "ch12-aa", "B, sequential", len, &s.b);
            try emitBench(out, "ch12-aa", "A, alternating", len, &t.a);
            try emitBench(out, "ch12-aa", "B, alternating", len, &t.b);
        }
    }
    try printRatios(out, "sequential", &seq);
    try printRatios(out, "alternating", &alt);
    try out.print("    checksum: A {d} B {d}\n", .{ sumU32(a), sumU32(b) });

    // ---- (d) layout guard: checked at compile time, printed for the reader ----
    try out.print("(d) Particle: {d} B, align {d}; pos @{d}, vel @{d}, alive @{d}, kind @{d}\n", .{
        @sizeOf(Particle),            @alignOf(Particle),
        @offsetOf(Particle, "pos"),   @offsetOf(Particle, "vel"),
        @offsetOf(Particle, "alive"), @offsetOf(Particle, "kind"),
    });
    try out.flush();
}
