//! Chapter 8: SIMD and parallelism (Zig 0.17.1).
//!   1. f32 dot product (naive, 8 accumulators, explicit @Vector, @setFloatMode(.optimized)) at L1 / L2 / DRAM sizes
//!   2. a branch in SIMD: sum and count of the positive values, branchy vs 8-lane @select
//!   3. false sharing: per-thread atomic counters packed in one line vs padded to 64 B / std.atomic.cache_line
//!   4. thread scaling: SoA particle step split into chunks over 1, 2 and 4 std.Thread.spawn threads
//!
//! Run: zig run -O fast main.zig -- [N] [--quick]   (DRAM control = 16·N floats)

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

/// lowbias32 (Chris Wellons): the same integer hash in all three languages, so the data is identical.
fn hash(x0: u32) u32 {
    var x = x0;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    return x ^ (x >> 16);
}

/// 24 random bits as an exact f32 in [-1, 1).
fn signed(h: u32) f32 {
    return @as(f32, @floatFromInt(h >> 8)) * (1.0 / 8388608.0) - 1.0;
}

// ---- dot ----
/// 1. The obvious loop: one accumulator, strict left-to-right order. Each add waits for the previous one.
fn dotNaive(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}

/// 2. Eight accumulators: we reassociate by hand. (Zig 0.17.1 has LLVM's loop vectorizer off;
/// the SLP vectorizer may still pack the eight independent adds into one register.)
fn dotAcc8(a: []const f32, b: []const f32) f32 {
    var acc: [8]f32 = @splat(0);
    var i: usize = 0;
    while (i + 8 <= a.len) : (i += 8) {
        inline for (0..8) |j| acc[j] += a[i + j] * b[i + j];
    }
    var s: f32 = 0;
    for (acc) |v| s += v;
    while (i < a.len) : (i += 1) s += a[i] * b[i];
    return s;
}

const V = @Vector(8, f32);

/// 3. Explicit SIMD: four @Vector(8, f32) accumulators (32 partial sums), four adds in flight at once.
fn dotSimd(a: []const f32, b: []const f32) f32 {
    var acc: [4]V = @splat(@splat(0));
    var i: usize = 0;
    while (i + 32 <= a.len) : (i += 32) {
        inline for (0..4) |k| {
            const va: V = a[i + 8 * k ..][0..8].*; // slice → array → vector: one unaligned load
            const vb: V = b[i + 8 * k ..][0..8].*;
            acc[k] += va * vb;
        }
    }
    const lanes: [8]f32 = ((acc[0] + acc[1]) + acc[2]) + acc[3];
    var s: f32 = 0;
    for (lanes) |l| s += l; // ordered, so the bits match Rust and Odin
    while (i < a.len) : (i += 1) s += a[i] * b[i];
    return s;
}

/// 4. The naive loop with reassociation (and contraction) allowed for this one function.
fn dotReassoc(a: []const f32, b: []const f32) f32 {
    @setFloatMode(.optimized);
    var s: f32 = 0;
    for (a, b) |x, y| s += x * y;
    return s;
}
// ---- dot ----

// ---- mask ----
const Pos = struct { sum: f32, count: u32 };

/// Branchy scalar: sum and count of the positive values.
fn posBranchy(a: []const f32) Pos {
    var r: Pos = .{ .sum = 0, .count = 0 };
    for (a) |x| {
        if (x > 0) {
            r.sum += x;
            r.count += 1;
        }
    }
    return r;
}

/// Branch-free lanes: `v > zero` is a @Vector(8, bool) mask; @select keeps x or 0.0 per lane.
fn posMask(a: []const f32) Pos {
    const zero: V = @splat(0);
    const U = @Vector(8, u32);
    var s: V = zero;
    var c: U = @splat(0);
    var i: usize = 0;
    while (i + 8 <= a.len) : (i += 8) {
        const v: V = a[i..][0..8].*;
        const m = v > zero;
        s += @select(f32, m, v, zero);
        c += @select(u32, m, @as(U, @splat(1)), @as(U, @splat(0)));
    }
    const sl: [8]f32 = s;
    var r: Pos = .{ .sum = 0, .count = @reduce(.Add, c) };
    for (sl) |l| r.sum += l;
    const t = posBranchy(a[i..]);
    return .{ .sum = r.sum + t.sum, .count = r.count + t.count };
}
// ---- mask ----

// ---- false sharing ----
const Counter = std.atomic.Value(u64);

/// Two counters in one 64-byte line (aligned so the pair cannot straddle two lines).
const Packed = struct { c: [2]Counter align(64) };
/// One counter per 64-byte line: adjacent lines still form one 128-byte pair for the spatial prefetcher.
const Pad64 = struct { c: Counter align(64) };
/// One counter per std.atomic.cache_line (128 on x86-64: Zig already accounts for the pair prefetch).
const Pad128 = struct { c: Counter align(std.atomic.cache_line) };

comptime {
    std.debug.assert(@sizeOf(Packed) == 64 and @sizeOf(Pad64) == 64);
    std.debug.assert(std.atomic.cache_line == 128 and @sizeOf(Pad128) == 128);
}

fn hammer(c: *Counter, iters: u64) void {
    for (0..iters) |_| _ = c.fetchAdd(1, .monotonic);
}

const Two = struct { c0: *Counter, c1: *Counter, iters: u64 };

/// Each of the two threads increments its own counter `iters` times. Returns the total.
fn twoThreads(t: Two) u64 {
    const t0 = std.Thread.spawn(.{}, hammer, .{ t.c0, t.iters }) catch @panic("spawn failed");
    const t1 = std.Thread.spawn(.{}, hammer, .{ t.c1, t.iters }) catch @panic("spawn failed");
    t0.join();
    t1.join();
    return t.c0.load(.monotonic) + t.c1.load(.monotonic);
}

fn hammerOne(t: Two) u64 {
    hammer(t.c0, t.iters);
    return t.c0.load(.monotonic);
}
// ---- false sharing ----

// ---- threads ----
const DT: f32 = 0.01;

/// SoA particle columns, hand-written (a MultiArrayList would work too; we want plain slices to split).
const Soa = struct { x: []f32, y: []f32, vx: []const f32, vy: []const f32 };

/// One particle step over a chunk: x += vx·dt, y += vy·dt, 8 lanes at a time (plain loops stay scalar in 0.17.1).
fn step(c: Soa) void {
    const vdt: V = @splat(DT);
    var i: usize = 0;
    while (i + 8 <= c.x.len) : (i += 8) {
        const x: V = c.x[i..][0..8].*;
        const y: V = c.y[i..][0..8].*;
        const vx: V = c.vx[i..][0..8].*;
        const vy: V = c.vy[i..][0..8].*;
        c.x[i..][0..8].* = x + vx * vdt;
        c.y[i..][0..8].* = y + vy * vdt;
    }
    while (i < c.x.len) : (i += 1) {
        c.x[i] += c.vx[i] * DT;
        c.y[i] += c.vy[i] * DT;
    }
}

fn worker(c: Soa, passes: usize) void {
    for (0..passes) |_| step(c);
}

/// Split the columns into `threads` disjoint chunks (whole multiples of 32 floats = 128 B; the columns are
/// 128-byte aligned, so no two threads write the same cache-line pair), one std.Thread each, then join them all.
fn stepParallel(s: Soa, threads: usize, passes: usize) void {
    const chunk = std.mem.alignForward(usize, std.math.divCeil(usize, s.x.len, threads) catch unreachable, 32);
    var pool: [8]std.Thread = undefined;
    var spawned: usize = 0;
    var lo: usize = 0;
    while (lo < s.x.len) : (lo += chunk) {
        const hi = @min(lo + chunk, s.x.len);
        const part: Soa = .{ .x = s.x[lo..hi], .y = s.y[lo..hi], .vx = s.vx[lo..hi], .vy = s.vy[lo..hi] };
        pool[spawned] = std.Thread.spawn(.{}, worker, .{ part, passes }) catch @panic("spawn failed");
        spawned += 1;
    }
    for (pool[0..spawned]) |t| t.join();
}
// ---- threads ----

const DotCtx = struct { a: []const f32, b: []const f32, reps: usize };

fn Repeat(comptime kernel: fn ([]const f32, []const f32) f32) type {
    return struct {
        fn run(c: DotCtx) f32 {
            var s: f32 = 0;
            for (0..c.reps) |_| {
                std.mem.doNotOptimizeAway(c.a.ptr); // memory clobber: the kernel must really run every rep
                s += kernel(c.a, c.b);
            }
            return s;
        }
    };
}

const MaskCtx = struct { a: []const f32, reps: usize };

fn RepeatMask(comptime kernel: fn ([]const f32) Pos) type {
    return struct {
        fn run(c: MaskCtx) u32 {
            var n: u32 = 0;
            for (0..c.reps) |_| {
                std.mem.doNotOptimizeAway(c.a.ptr);
                const r = kernel(c.a);
                n +%= r.count ^ @as(u32, @bitCast(r.sum)); // keep both results, so neither half can be dropped
            }
            return n;
        }
    };
}

const StepCtx = struct { s: Soa, threads: usize, passes: usize };

fn runStep(c: StepCtx) f32 {
    stepParallel(c.s, c.threads, c.passes);
    return c.s.x[0];
}

/// Each column starts on a std.atomic.cache_line (128-byte) boundary, so 128-byte chunk boundaries are real line-pair boundaries
/// (gpa.alloc(f32, n) only promises 4-byte alignment).
fn makeSoa(gpa: std.mem.Allocator, n: usize) !Soa {
    var cols: [4][]align(std.atomic.cache_line) f32 = undefined;
    for (&cols, 0..) |*col, k| {
        col.* = try gpa.alignedAlloc(f32, .fromByteUnits(std.atomic.cache_line), n);
        for (col.*, 0..) |*v, i| v.* = signed(hash(@intCast(4 * i + k)));
    }
    return .{ .x = cols[0], .y = cols[1], .vx = cols[2], .vy = cols[3] };
}

fn freeSoa(gpa: std.mem.Allocator, s: Soa) void {
    inline for (.{ s.x, s.y, s.vx, s.vy }) |col| gpa.free(@as([]align(std.atomic.cache_line) const f32, @alignCast(col)));
}

fn bitsSum(v: []const f32) u64 {
    var h: u64 = 0;
    for (v) |x| h = std.math.rotl(u64, h, 5) ^ @as(u32, @bitCast(x));
    return h;
}

fn perElem(ns: u64, n: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    const dram = 16 * args.n; // DRAM control: 2 × 64 MiB of f32 at the default N
    const L1: usize = 4096; // 2 arrays × 16 KiB = 32 KiB  < 48 KiB L1d
    const L2: usize = 65536; // 2 arrays × 256 KiB = 512 KiB < 1.25 MiB L2
    try out.print("ch08 zig: N={d} quick={} cpu={s} cache_line={d} cpus={d}\n", .{
        args.n, args.quick, @import("builtin").cpu.model.name, std.atomic.cache_line, std.Thread.getCpuCount() catch 0,
    });

    // ---- 1. dot product ----
    {
        const len = @max(dram, L2);
        const a = try gpa.alloc(f32, len);
        defer gpa.free(a);
        const b = try gpa.alloc(f32, len);
        defer gpa.free(b);
        for (a, b, 0..) |*x, *y, i| {
            x.* = signed(hash(@intCast(2 * i)));
            y.* = signed(hash(@intCast(2 * i + 1)));
        }
        const Variant = struct { label: []const u8, f: *const fn ([]const f32, []const f32) f32, run: *const fn (DotCtx) f32 };
        const variants = [_]Variant{
            .{ .label = "naive (1 accumulator)", .f = dotNaive, .run = Repeat(dotNaive).run },
            .{ .label = "8 accumulators", .f = dotAcc8, .run = Repeat(dotAcc8).run },
            .{ .label = "explicit SIMD (4x8 lanes)", .f = dotSimd, .run = Repeat(dotSimd).run },
            .{ .label = "reassociation allowed", .f = dotReassoc, .run = Repeat(dotReassoc).run },
        };
        const sizes = [_]struct { id: []const u8, n: usize }{ .{ .id = "ch08-dot-l1", .n = L1 }, .{ .id = "ch08-dot-l2", .n = L2 }, .{ .id = "ch08-dot-dram", .n = dram } };
        for (sizes) |sz| {
            const ctx: DotCtx = .{ .a = a[0..sz.n], .b = b[0..sz.n], .reps = @max(dram / sz.n, 1) };
            var exact: f64 = 0;
            var scale: f64 = 0;
            for (ctx.a, ctx.b) |x, y| {
                const p = @as(f64, x) * @as(f64, y);
                exact += p;
                scale += @abs(p);
            }
            try out.print("{s}: {d} floats x2 ({d} KiB), {d} reps, f64 reference {d:.6}\n", .{ sz.id, sz.n, sz.n * 8 / 1024, ctx.reps, exact });
            inline for (variants) |v| {
                const r = v.f(ctx.a, ctx.b);
                const err = @abs(@as(f64, r) - exact);
                if (err > 1e-3 * scale) @panic("result too far from the f64 reference");
                const runs = benchRuns(io, v.run, ctx);
                try out.print("  {s:<27} {d:>7.3} ns/elem  result {d:>14.6} (bits {x:0>8}, |err| {e:.2})\n", .{
                    v.label, perElem(runs[RUNS / 2], sz.n * ctx.reps), r, @as(u32, @bitCast(r)), err,
                });
                try emitBench(out, sz.id, v.label, sz.n * ctx.reps, &runs);
            }
        }
    }

    // ---- 2. masks ----
    {
        const a = try gpa.alloc(f32, L2);
        defer gpa.free(a);
        for (a, 0..) |*x, i| x.* = signed(hash(@as(u32, @intCast(i)) ^ 0x5bd1e995));
        const ctx: MaskCtx = .{ .a = a, .reps = @max(dram / L2, 1) };
        const r0 = posBranchy(a);
        const r1 = posMask(a);
        if (r0.count != r1.count) @panic("counts must match exactly");
        if (@abs(r0.sum - r1.sum) > 1e-3 * r0.sum) @panic("sums too far apart");
        try out.print("ch08-mask: {d} floats, {d} reps, count {d} (both), sum branchy {d:.4} vs mask {d:.4}\n", .{ L2, ctx.reps, r0.count, r0.sum, r1.sum });
        inline for (.{ .{ "branchy scalar", posBranchy }, .{ "8-lane mask", posMask } }) |v| {
            const runs = benchRuns(io, RepeatMask(v[1]).run, ctx);
            try out.print("  {s:<27} {d:>7.3} ns/elem\n", .{ v[0], perElem(runs[RUNS / 2], L2 * ctx.reps) });
            try emitBench(out, "ch08-mask", v[0], L2 * ctx.reps, &runs);
        }
    }

    // ---- 3. false sharing ----
    {
        const iters: u64 = if (args.quick) 1 << 14 else 1 << 24;
        try out.print("ch08-false-sharing: {d} relaxed fetchAdd per thread\n", .{iters});
        var one: Pad128 = .{ .c = .init(0) };
        var p: Packed = .{ .c = .{ .init(0), .init(0) } };
        var q: [2]Pad64 = .{ .{ .c = .init(0) }, .{ .c = .init(0) } };
        var r: [2]Pad128 = .{ .{ .c = .init(0) }, .{ .c = .init(0) } };
        const twos = [_]Two{
            .{ .c0 = &one.c, .c1 = &one.c, .iters = iters },
            .{ .c0 = &p.c[0], .c1 = &p.c[1], .iters = iters },
            .{ .c0 = &q[0].c, .c1 = &q[1].c, .iters = iters },
            .{ .c0 = &r[0].c, .c1 = &r[1].c, .iters = iters },
        };
        const labels = .{ "1 thread alone", "2 threads, same line", "2 threads, padded 64 B", "2 threads, padded 128 B" };
        inline for (labels, 0..) |label, k| {
            const f = if (k == 0) hammerOne else twoThreads;
            const runs = benchRuns(io, f, twos[k]);
            const t = twos[k];
            const total = if (k == 0) t.c0.load(.monotonic) else t.c0.load(.monotonic) + t.c1.load(.monotonic);
            if (total != (if (k == 0) 8 * iters else 16 * iters)) @panic("lost increments");
            try out.print("  {s:<27} {d:>7.3} ns per increment (wall), total {d}\n", .{ label, perElem(runs[RUNS / 2], iters), total });
            try emitBench(out, "ch08-false-sharing", label, iters, &runs);
        }
    }

    // ---- 4. thread scaling ----
    {
        var sums: [3]u64 = undefined;
        for ([_]usize{ 1, 2, 4 }, &sums) |threads, *h| {
            const s = try makeSoa(gpa, L2);
            defer freeSoa(gpa, s);
            stepParallel(s, threads, 3);
            h.* = bitsSum(s.x) ^ bitsSum(s.y);
        }
        if (sums[1] != sums[0] or sums[2] != sums[0]) @panic("thread count changed the result");
        try out.print("ch08-threads: checksum {x:0>16} for 1, 2 and 4 threads (identical)\n", .{sums[0]});
        const big = @max(dram / 2, L2);
        const configs = [_]struct { id: []const u8, n: usize, passes: usize }{
            .{ .id = "ch08-threads-l2", .n = L2, .passes = @max(dram / L2, 1) },
            .{ .id = "ch08-threads-dram", .n = big, .passes = 1 },
        };
        for (configs) |cfg| {
            const s = try makeSoa(gpa, cfg.n);
            defer freeSoa(gpa, s);
            try out.print("{s}: {d} particles ({d} KiB of SoA), {d} passes\n", .{ cfg.id, cfg.n, cfg.n * 16 / 1024, cfg.passes });
            for ([_]usize{ 1, 2, 4 }) |threads| {
                const runs = benchRuns(io, runStep, StepCtx{ .s = s, .threads = threads, .passes = cfg.passes });
                var lb: [16]u8 = undefined;
                const label = try std.mem.print(&lb, "{d} thread{s}", .{ threads, if (threads == 1) "" else "s" });
                try out.print("  {s:<27} {d:>7.3} ns/particle-step\n", .{ label, perElem(runs[RUNS / 2], cfg.n * cfg.passes) });
                try emitBench(out, cfg.id, label, cfg.n * cfg.passes, &runs);
            }
        }
    }
    try out.flush();
}
