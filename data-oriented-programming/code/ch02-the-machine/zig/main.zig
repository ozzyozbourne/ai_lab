// Chapter 2, "The Machine": what the memory hierarchy costs, measured four ways.
//   (a) ch02-list    sum 4·N nodes as an array, as a list linked in memory order, and as a shuffled list
//   (b) ch02-sweep   a dependent random chase (Sattolo single cycle, one load per 64 B line) from 4 KiB to 512 MiB
//   (c) ch02-access  the same 16·N u32s read sequentially, at a 64 B stride, at a 4 KiB stride, in random order,
//                    and in random order with a software prefetch
//   (d) ch02-mlp     the same chase split into 1, 2, 4 or 8 independent chains (memory-level parallelism)
// N defaults to 2^20, so (a), (c) and (d) each touch 64 MiB, more than this orb's 54 MiB L3.
// Run: zig run -O fast main.zig -- --quick

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

const Allocator = std.mem.Allocator;

/// splitmix64. The Rust and Odin versions use the same generator and seeds, so all three
/// programs build identical permutations and print identical checksums.
const Rng = struct {
    state: u64,

    fn next(r: *Rng) u64 {
        r.state +%= 0x9E37_79B9_7F4A_7C15;
        var z = r.state;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        return z ^ (z >> 31);
    }

    /// Uniform-enough integer in 0..n (multiply-high, no division).
    fn below(r: *Rng, n: usize) usize {
        return @intCast((@as(u128, r.next()) * n) >> 64);
    }
};

fn identity(gpa: Allocator, n: usize) ![]u32 {
    const p = try gpa.alloc(u32, n);
    for (p, 0..) |*x, i| x.* = @intCast(i);
    return p;
}

/// Fisher-Yates: a uniformly random permutation of 0..n.
fn shuffled(gpa: Allocator, n: usize, rng: *Rng) ![]u32 {
    const p = try identity(gpa, n);
    var i = n - 1;
    while (i > 0) : (i -= 1) std.mem.swap(u32, &p[i], &p[rng.below(i + 1)]);
    return p;
}

/// Sattolo's algorithm: like Fisher-Yates but j < i, never j == i. The result, read as
/// "next = p[i]", is ONE cycle through all n elements, so a chase can never get stuck in a short loop.
fn sattolo(gpa: Allocator, n: usize, rng: *Rng) ![]u32 {
    const p = try identity(gpa, n);
    var i = n - 1;
    while (i > 0) : (i -= 1) std.mem.swap(u32, &p[i], &p[rng.below(i)]);
    return p;
}

// ---- (a) array vs linked list ----

const END: u32 = std.math.maxInt(u32);

/// 16 bytes: 8 value + 4 next + 4 padding, so four nodes share a 64-byte line.
const Node = struct { value: u64, next: u32 };

const List = struct { nodes: []const Node, head: u32 };

/// Links the nodes in `order`: order[0] is the head and each node points to the next one in `order`.
fn link(gpa: Allocator, order: []const u32) !List {
    const nodes = try gpa.alloc(Node, order.len);
    for (order, 0..) |i, k| {
        nodes[i] = .{ .value = i, .next = if (k + 1 < order.len) order[k + 1] else END };
    }
    return .{ .nodes = nodes, .head = order[0] };
}

fn sumArray(l: List) u64 {
    var s: u64 = 0;
    for (l.nodes) |n| s += n.value;
    return s;
}

fn sumList(l: List) u64 {
    var s: u64 = 0;
    var i = l.head;
    while (i != END) {
        const n = l.nodes[i];
        s += n.value;
        i = n.next; // the next address is only known when this load returns
    }
    return s;
}

// ---- (b) and (d) dependent chase, one u32 per 64-byte line ----

const LINE_U32 = 64 / 4;

/// `bytes` of memory with one live u32 per 64-byte line: buf[16·k] = 16·next(k), next a Sattolo cycle.
fn chaseBuffer(gpa: Allocator, bytes: usize, rng: *Rng) ![]u32 {
    const lines = bytes / 64;
    const cyc = try sattolo(gpa, lines, rng);
    defer gpa.free(cyc);
    const buf = try gpa.alloc(u32, lines * LINE_U32);
    @memset(buf, 0);
    for (cyc, 0..) |nx, k| buf[k * LINE_U32] = nx * LINE_U32;
    return buf;
}

const Chase = struct { buf: []const u32, hops: usize };

fn chase(c: Chase) u64 {
    var s: u64 = 0;
    var i: usize = 0;
    for (0..c.hops) |_| {
        i = c.buf[i]; // each load needs the previous one's result
        s += i;
    }
    return s;
}

/// One full trip around a cycle of `lines` lines visits every line once: sum of 16·k for k < lines.
fn tripSum(lines: usize) u64 {
    return LINE_U32 * lines * (lines - 1) / 2;
}

const Chains = struct { buf: []const u32, starts: []const usize, hops_each: usize };

/// K cursors spread evenly around the same cycle, advanced in lockstep. The K loads in one
/// round do not depend on each other, so the core can have K misses in flight at once.
fn chaseK(comptime K: usize) fn (Chains) u64 {
    return struct {
        fn run(c: Chains) u64 {
            var cur: [K]usize = c.starts[0..K].*;
            var s: u64 = 0;
            for (0..c.hops_each) |_| {
                inline for (&cur) |*p| {
                    p.* = c.buf[p.*];
                    s += p.*;
                }
            }
            return s;
        }
    }.run;
}

fn starts(buf: []const u32, lines: usize, out: []usize) void {
    var i: usize = 0;
    for (out, 0..) |*slot, k| {
        slot.* = i;
        if (k + 1 < out.len) {
            for (0..lines / out.len) |_| i = buf[i];
        }
    }
}

// ---- (c) access patterns over the same bytes ----

const Gather = struct { a: []const u32, idx: []const u32 };
const Strided = struct { a: []const u32, stride: usize };

fn sumSeq(a: []const u32) u64 {
    var s: u64 = 0;
    for (a) |x| s += x;
    return s;
}

/// Visits every element exactly once: `stride` passes, each touching every stride-th element.
fn sumStrided(c: Strided) u64 {
    var s: u64 = 0;
    for (0..c.stride) |off| {
        var i = off;
        while (i < c.a.len) : (i += c.stride) s += c.a[i];
    }
    return s;
}

fn sumGather(g: Gather) u64 {
    var s: u64 = 0;
    for (g.idx) |i| s += g.a[i];
    return s;
}

const PREFETCH_AHEAD = 16;

fn sumGatherPrefetch(g: Gather) u64 {
    var s: u64 = 0;
    for (g.idx, 0..) |i, k| {
        if (k + PREFETCH_AHEAD < g.idx.len) {
            // ask for a line we will need 16 iterations from now (a no-op where unsupported)
            @prefetch(&g.a[g.idx[k + PREFETCH_AHEAD]], .{ .rw = .read, .locality = 3, .cache = .data });
        }
        s += g.a[i];
    }
    return s;
}

fn nsPer(ns: u64, n: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
}

fn okText(ok: bool) []const u8 {
    return if (ok) "all match" else "MISMATCH";
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var out_buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &out_buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    const args = try parseArgs(init);
    const n = args.n;
    var all_ok = true;
    try out.print("ch02 the machine: N = {d}, quick = {}\n", .{ n, args.quick });

    // (a) array vs linked list over 4·N 16-byte nodes
    {
        const count = 4 * n;
        var rng: Rng = .{ .state = 1 };
        const ident = try identity(gpa, count);
        defer gpa.free(ident);
        const perm = try shuffled(gpa, count, &rng);
        defer gpa.free(perm);
        const in_order = try link(gpa, ident);
        defer gpa.free(in_order.nodes);
        const scattered = try link(gpa, perm);
        defer gpa.free(scattered.nodes);

        const want: u64 = count * (count - 1) / 2;
        const ok = sumArray(scattered) == want and sumList(in_order) == want and sumList(scattered) == want;
        all_ok = all_ok and ok;
        try out.print("(a) {d} nodes x 16 B = {d} KiB, checksum {d} ({s})\n", .{ count, count * 16 / 1024, want, okText(ok) });
        const runs = [_]struct { []const u8, [RUNS]u64 }{
            .{ "array", benchRuns(io, sumArray, scattered) },
            .{ "list, in order", benchRuns(io, sumList, in_order) },
            .{ "list, shuffled", benchRuns(io, sumList, scattered) },
        };
        for (runs) |r| {
            try out.print("    {s:<16} {d:>7.2} ns/node\n", .{ r[0], nsPer(r[1][RUNS / 2], count) });
            try emitBench(out, "ch02-list", r[0], count, &r[1]);
        }
    }

    // (b) working-set sweep: 4 KiB .. 512 MiB (2 MiB with --quick), powers of two and 1.5x midpoints
    {
        const max: usize = if (args.quick) 2 << 20 else 512 << 20;
        const min_hops: usize = if (args.quick) 1 << 16 else 1 << 21;
        try out.print("(b) dependent random chase, one load per 64 B line, >= {d} loads per size\n", .{min_hops});
        var rng: Rng = .{ .state = 2 };
        var ok = true;
        var b: usize = 4 << 10;
        while (b <= max) : (b *= 2) {
            for ([_]usize{ b, b * 3 / 2 }) |bytes| {
                if (bytes > max) continue;
                const buf = try chaseBuffer(gpa, bytes, &rng);
                defer gpa.free(buf);
                const lines = bytes / 64;
                const rounds = @max(min_hops / lines, 1);
                const c: Chase = .{ .buf = buf, .hops = rounds * lines };
                ok = ok and chase(c) == rounds * tripSum(lines);
                var runs = benchRuns(io, chase, c);
                // one sample = one trip around the cycle, so ns/n is the latency of one load
                for (&runs) |*r| r.* /= rounds;
                try out.print("    {d:>8} KiB  {d:>7.2} ns/load\n", .{ bytes >> 10, nsPer(runs[RUNS / 2], lines) });
                try emitBench(out, "ch02-sweep", "random chase", lines, &runs);
            }
        }
        all_ok = all_ok and ok;
        try out.print("    every trip visited every line once: {s}\n", .{if (ok) "yes" else "NO"});
    }

    // (c) sequential vs strided vs random over the same 16·N u32s
    {
        const m = 16 * n;
        var rng: Rng = .{ .state = 3 };
        const a = try gpa.alloc(u32, m);
        defer gpa.free(a);
        for (a, 0..) |*x, i| x.* = @as(u32, @intCast(i)) *% 2_654_435_761;
        const idx = try shuffled(gpa, m, &rng);
        defer gpa.free(idx);
        const g: Gather = .{ .a = a, .idx = idx };

        const want = sumSeq(a);
        const ok = sumStrided(.{ .a = a, .stride = 16 }) == want and sumStrided(.{ .a = a, .stride = 1024 }) == want and
            sumGather(g) == want and sumGatherPrefetch(g) == want;
        all_ok = all_ok and ok;
        try out.print("(c) {d} u32 = {d} KiB, checksum {d} ({s})\n", .{ m, m * 4 / 1024, want, okText(ok) });
        const runs = [_]struct { []const u8, [RUNS]u64 }{
            .{ "sequential", benchRuns(io, sumSeq, @as([]const u32, a)) },
            .{ "stride 64 B", benchRuns(io, sumStrided, Strided{ .a = a, .stride = 16 }) },
            .{ "stride 4 KiB", benchRuns(io, sumStrided, Strided{ .a = a, .stride = 1024 }) },
            .{ "random", benchRuns(io, sumGather, g) },
            .{ "random + prefetch", benchRuns(io, sumGatherPrefetch, g) },
        };
        for (runs) |r| {
            try out.print("    {s:<18} {d:>7.2} ns/elem\n", .{ r[0], nsPer(r[1][RUNS / 2], m) });
            try emitBench(out, "ch02-access", r[0], m, &r[1]);
        }
    }

    // (d) memory-level parallelism: the same N-line cycle walked by 1, 2, 4 or 8 chains
    {
        const lines = n / 8 * 8;
        var rng: Rng = .{ .state = 4 };
        const buf = try chaseBuffer(gpa, lines * 64, &rng);
        defer gpa.free(buf);
        const want = tripSum(lines);
        var ok = true;
        try out.print("(d) {d} lines = {d} KiB, checksum {d}", .{ lines, lines * 64 / 1024, want });
        var results: [4][RUNS]u64 = undefined;
        inline for (.{ 1, 2, 4, 8 }, 0..) |k, j| {
            var st: [k]usize = undefined;
            starts(buf, lines, &st);
            const c: Chains = .{ .buf = buf, .starts = &st, .hops_each = lines / k };
            ok = ok and chaseK(k)(c) == want;
            results[j] = benchRuns(io, chaseK(k), c);
        }
        all_ok = all_ok and ok;
        try out.print(" ({s})\n", .{okText(ok)});
        for (results, [_][]const u8{ "1 chain", "2 chains", "4 chains", "8 chains" }) |runs, label| {
            try out.print("    {s:<9} {d:>7.2} ns/load\n", .{ label, nsPer(runs[RUNS / 2], lines) });
            try emitBench(out, "ch02-mlp", label, lines, &runs);
        }
    }

    if (!all_ok) {
        try out.flush();
        std.debug.print("checksum mismatch\n", .{});
        std.process.exit(1);
    }
}
