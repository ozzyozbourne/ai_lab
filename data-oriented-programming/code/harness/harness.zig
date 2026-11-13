// Reference copy of the shared benchmark harness (Zig 0.17.1).
// Chapters copy the block between the `---- harness ----` markers verbatim into their main.zig.
// Demo: `zig run -O fast harness.zig -- --quick`

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

fn sum(v: []const u64) u64 {
    var s: u64 = 0;
    for (v) |x| s +%= x;
    return s;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    const v = try gpa.alloc(u64, args.n);
    defer gpa.free(v);
    for (v, 0..) |*x, i| x.* = i;

    const runs = benchRuns(io, sum, @as([]const u64, v));
    const med = runs[RUNS / 2];
    try out.print("sum of {d} u64: median {d} ns ({d:.2} ns/elem), quick={}\n", .{
        args.n, med, @as(f64, @floatFromInt(med)) / @as(f64, @floatFromInt(args.n)), args.quick,
    });
    try emitBench(out, "harness-demo", "sum u64", args.n, &runs);
    try out.flush();
}
