// Chapter 3: Size, Alignment and Padding (Zig 0.17.1).
// Part (a) prints sizes, alignments and offsets (layout.zig).
// Part (b) sweeps N from 10k to 10M monsters and times one pass over three layouts of the same data:
//   24 B: pointer-sized anim handle, u32 hp, u32 y, bool    (Kelley's "fat" monster)
//   16 B: u32 anim index instead of the pointer-sized handle
//   12 B: u32 anim index and y quantized to u16
// Every variant computes the same checksum. Usage: [N = largest size, default 10_000_000] [--quick]

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

const layout = @import("layout.zig");

// monsters
/// 8 + 4 + 4 + 1 = 17 bytes of fields, padded to 24 (align 8).
const Fat = struct { anim: usize, hp: u32, y: u32, alive: bool };
/// 4 + 4 + 4 + 1 = 13 bytes of fields, padded to 16 (align 4).
const Index = struct { anim: u32, hp: u32, y: u32, alive: bool };
/// 4 + 4 + 2 + 1 = 11 bytes of fields, padded to 12 (align 4).
const Small = struct { anim: u32, hp: u32, y: u16, alive: bool };

comptime {
    std.debug.assert(@sizeOf(Fat) == 24);
    std.debug.assert(@sizeOf(Index) == 16);
    std.debug.assert(@sizeOf(Small) == 12);
}
// monsters

// score
/// The per-monster work: read every field, sum the live ones. One function per element type.
fn totalOf(comptime M: type) fn ([]const M) u64 {
    return struct {
        fn total(ms: []const M) u64 {
            var s: u64 = 0;
            for (ms) |m| {
                // Branch-free on purpose: `alive` is random, and a branch would measure mispredictions (Chapter 7).
                s += (@as(u64, m.anim) + m.hp + m.y) * @intFromBool(m.alive);
            }
            return s;
        }
    }.total;
}
// score

/// splitmix64 of i: a stateless hash, so all three languages generate the same monsters.
fn mix(i: u64) u64 {
    var z = i +% 0x9E37_79B9_7F4A_7C15;
    z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
    return z ^ (z >> 31);
}

/// Monster i in layout M: anim < 4096, hp < 1000, y < 65536, 75% alive.
fn make(comptime M: type, i: usize) M {
    const r = mix(i);
    return .{
        .anim = @intCast(r & 0xFFF),
        .hp = @intCast((r >> 12) % 1000),
        .y = @as(u16, @truncate(r >> 24)),
        .alive = (r >> 40) & 3 != 0,
    };
}

/// Builds the monsters, times one pass, prints a line and a BENCH record. Returns the checksum.
fn run(comptime M: type, io: Io, gpa: std.mem.Allocator, out: *Io.Writer, label: []const u8, n: usize) !u64 {
    const ms = try gpa.alloc(M, n);
    defer gpa.free(ms);
    for (ms, 0..) |*m, i| m.* = make(M, i);
    const total = totalOf(M);
    const runs = benchRuns(io, total, @as([]const M, ms));
    const sum = total(ms);
    try out.print("  {s:<10} {d:>3} B/elem  {d:>11} B total  {d:>6.3} ns/elem  checksum {d}\n", .{
        label, @sizeOf(M), @sizeOf(M) * n, @as(f64, @floatFromInt(runs[RUNS / 2])) / @as(f64, @floatFromInt(n)), sum,
    });
    try emitBench(out, "ch03-monsters", label, n, &runs);
    return sum;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    try layout.print(out);

    // The harness caps N at 4096 under --quick; this sweep has its own sizes.
    var explicit_n = false;
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |a| {
        if (!std.mem.eql(u8, a, "--quick")) explicit_n = true;
    }
    const max_n: usize = if (args.quick) 100_000 else if (explicit_n) args.n else 10_000_000;
    const sizes = [_]usize{ 10_000, 30_000, 100_000, 300_000, 1_000_000, 3_000_000, 10_000_000 };

    try out.print("== padding-waste sweep (one pass, median of {d}) ==\n", .{RUNS});
    for (sizes) |n| {
        if (n > max_n) break;
        try out.print("N = {d}\n", .{n});
        const a = try run(Fat, io, gpa, out, "24 B fat", n);
        const b = try run(Index, io, gpa, out, "16 B index", n);
        const c = try run(Small, io, gpa, out, "12 B small", n);
        if (a != b or b != c) return error.ChecksumMismatch;
        try out.writeAll("  checksums match\n");
        try out.flush();
    }
    try out.flush();
}
