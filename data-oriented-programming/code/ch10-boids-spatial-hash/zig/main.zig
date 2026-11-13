// Chapter 10: one deterministic 2D boids step, six ways (Zig 0.17.1). See rust/src/main.rs for the
// list of variants; this file is the same algorithm, sizes and seed.
//
//   zig run -O fast main.zig -- [N] [--quick]
//
// Boid state is a std.MultiArrayList(Boid). Plain loops stay scalar in Zig 0.17.1 (LLVM's loop
// vectorizer is disabled), so the SIMD variant uses @Vector explicitly.

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

// ---- the model: one step of Reynolds' three rules ----
const NEIGHBOR_R2: f32 = 1.0; // neighbour radius 1.0 = one grid cell
const SEPARATION_R2: f32 = 0.0625; // separation radius 0.25
const COHESION: f32 = 0.02;
const ALIGNMENT: f32 = 0.05;
const SEPARATION: f32 = 0.5;
const MAX_SPEED: f32 = 2.0;
const DT: f32 = 0.05;
const BOIDS_PER_CELL = 4; // average density; the world grows with N
const LANES = 8;
const THREADS = 2;
const NAIVE_MAX = 1 << 14;
const SEED: u64 = 0x5EED_B01D;

/// SplitMix64: the same generator, bit for bit, in all three languages (std.Random.SplitMix64).
const SplitMix64 = std.Random.SplitMix64;

/// Uniform in [0, 1) from the top 24 bits, so every value is exact in f32.
fn unit(r: *SplitMix64) f32 {
    return @as(f32, @floatFromInt(r.next() >> 40)) * (1.0 / 16777216.0);
}

/// One boid. std.MultiArrayList(Boid) stores each field as its own column in one allocation.
/// `id` is the spawn index, which survives reordering.
const Boid = struct { x: f32, y: f32, vx: f32, vy: f32, id: u32 };

/// The column slices of a MultiArrayList, fetched once and passed by value (no reloads in hot loops).
const Cols = struct {
    x: []f32,
    y: []f32,
    vx: []f32,
    vy: []f32,
    id: []u32,

    fn of(list: *const std.MultiArrayList(Boid)) Cols {
        const s = list.slice();
        return .{ .x = s.items(.x), .y = s.items(.y), .vx = s.items(.vx), .vy = s.items(.vy), .id = s.items(.id) };
    }
};

/// n boids plus LANES zeroed spare elements at the end, so 8-wide loads never run off a column.
const Boids = struct {
    n: usize,
    list: std.MultiArrayList(Boid),
    c: Cols,

    fn init(gpa: std.mem.Allocator, n: usize) !Boids {
        var list: std.MultiArrayList(Boid) = .empty;
        try list.resize(gpa, n + LANES);
        const c = Cols.of(&list);
        inline for (.{ c.x, c.y, c.vx, c.vy }) |col| @memset(col, 0);
        @memset(c.id, 0);
        return .{ .n = n, .list = list, .c = c };
    }

    fn deinit(self: *Boids, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
    }

    fn spawn(gpa: std.mem.Allocator, n: usize, w: World) !Boids {
        var b = try Boids.init(gpa, n);
        var rng: SplitMix64 = .init(SEED);
        for (0..n) |i| {
            b.c.x[i] = unit(&rng) * w.size;
            b.c.y[i] = unit(&rng) * w.size;
            b.c.vx[i] = unit(&rng) * 2.0 - 1.0;
            b.c.vy[i] = unit(&rng) * 2.0 - 1.0;
            b.c.id[i] = @intCast(i);
        }
        return b;
    }

    /// The reorder: copy every column into the order the grid sorted them (a gather).
    fn gatherFrom(self: *Boids, src: *const Boids, order: []const u32) void {
        const d = self.c;
        const s = src.c;
        for (order, 0..) |j, k| {
            d.x[k] = s.x[j];
            d.y[k] = s.y[j];
            d.vx[k] = s.vx[j];
            d.vy[k] = s.vy[j];
            d.id[k] = s.id[j];
        }
    }
};

fn setOut(out: Cols, k: usize, s: [4]f32, id: u32) void {
    out.x[k] = s[0];
    out.y[k] = s[1];
    out.vx[k] = s[2];
    out.vy[k] = s[3];
    out.id[k] = id;
}

/// A square world of side × side unit cells. The cell size equals the neighbour radius,
/// so every neighbour of a boid lies in its own cell or one of the eight around it.
const World = struct {
    side: u32,
    size: f32,

    fn forCount(n: usize) World {
        const side: u32 = @intFromFloat(@max(1.0, @round(@sqrt(@as(f64, @floatFromInt(n / BOIDS_PER_CELL))))));
        return .{ .side = side, .size = @floatFromInt(side) };
    }
    fn cellXY(w: World, x: f32, y: f32) [2]u32 {
        const cx: u32 = @intFromFloat(x); // x is in [0, size]: the bounce keeps it there
        const cy: u32 = @intFromFloat(y);
        return .{ @min(cx, w.side - 1), @min(cy, w.side - 1) };
    }
    /// Row-major cell number: cells in one row are consecutive.
    fn rowMajor(w: World, x: f32, y: f32) u32 {
        const c = w.cellXY(x, y);
        return c[1] * w.side + c[0];
    }
    fn mortonKey(w: World, x: f32, y: f32) u32 {
        const c = w.cellXY(x, y);
        return morton(c[0], c[1]);
    }
    /// The 3×3 block around a cell, clipped at the walls: x0, x1, y0, y1, inclusive.
    fn block(w: World, x: f32, y: f32) [4]u32 {
        const c = w.cellXY(x, y);
        return .{ c[0] -| 1, @min(c[0] + 1, w.side - 1), c[1] -| 1, @min(c[1] + 1, w.side - 1) };
    }
    /// Cells needed by the Morton numbering: the side rounded up to a power of two, squared.
    fn mortonCells(w: World) usize {
        const p: usize = std.math.ceilPowerOfTwoAssert(u32, w.side);
        return p * p;
    }
};

/// Interleaves the bits of x and y (x in the even bits): the Z-order curve.
fn morton(cx: u32, cy: u32) u32 {
    const spread = struct {
        fn f(v0: u32) u32 {
            var v = v0 & 0xFFFF;
            v = (v | (v << 8)) & 0x00FF_00FF;
            v = (v | (v << 4)) & 0x0F0F_0F0F;
            v = (v | (v << 2)) & 0x3333_3333;
            return (v | (v << 1)) & 0x5555_5555;
        }
    }.f;
    return spread(cx) | (spread(cy) << 1);
}

/// `v` when `c` holds, else 0. The hint tells LLVM the condition is a coin flip,
/// so it emits a conditional move/blend instead of a jump (Rust: select_unpredictable).
inline fn pick(c: bool, v: f32) f32 {
    if (c) {
        @branchHint(.unpredictable);
        return v;
    }
    return 0.0;
}

/// What one boid accumulates over its neighbours (itself included, so n >= 1).
const Acc = struct {
    n: u32 = 0,
    sx: f32 = 0, // sum of offsets to neighbours (cohesion)
    sy: f32 = 0,
    ax: f32 = 0, // sum of neighbour velocities (alignment)
    ay: f32 = 0,
    qx: f32 = 0, // push away from very close neighbours (separation)
    qy: f32 = 0,

    inline fn visit(self: *Acc, xi: f32, yi: f32, xj: f32, yj: f32, vxj: f32, vyj: f32) void {
        const dx = xj - xi;
        const dy = yj - yi;
        const d2 = dx * dx + dy * dy;
        const near = d2 < NEIGHBOR_R2;
        const close = d2 < SEPARATION_R2;
        self.n += @intFromBool(near);
        self.sx += pick(near, dx);
        self.sy += pick(near, dy);
        self.ax += pick(near, vxj);
        self.ay += pick(near, vyj);
        self.qx -= pick(close, dx);
        self.qy -= pick(close, dy);
    }

    /// Steer, clamp the speed, move, and bounce off the walls. Returns x, y, vx, vy.
    inline fn integrate(self: Acc, w: World, x: f32, y: f32, vx: f32, vy: f32) [4]f32 {
        const inv = 1.0 / @as(f32, @floatFromInt(self.n));
        var nvx = vx + COHESION * (self.sx * inv) + ALIGNMENT * (self.ax * inv - vx) + SEPARATION * self.qx;
        var nvy = vy + COHESION * (self.sy * inv) + ALIGNMENT * (self.ay * inv - vy) + SEPARATION * self.qy;
        const s2 = nvx * nvx + nvy * nvy;
        if (s2 > MAX_SPEED * MAX_SPEED) {
            const k = MAX_SPEED / @sqrt(s2);
            nvx *= k;
            nvy *= k;
        }
        const bx = bounce(x + nvx * DT, nvx, w.size);
        const by = bounce(y + nvy * DT, nvy, w.size);
        return .{ bx[0], by[0], bx[1], by[1] };
    }
};

fn bounce(p: f32, v: f32, size: f32) [2]f32 {
    if (p < 0.0) return .{ -p, -v };
    if (p > size) return .{ size + size - p, -v };
    return .{ p, v };
}

/// Visits a contiguous run of boids (all four columns read in lockstep).
inline fn visitSpan(acc: *Acc, b: Cols, a: usize, e: usize, xi: f32, yi: f32) void {
    for (b.x[a..e], b.y[a..e], b.vx[a..e], b.vy[a..e]) |xj, yj, vxj, vyj| {
        acc.visit(xi, yi, xj, yj, vxj, vyj);
    }
}

// ---- the counting-sort grid ----

/// `start[c]..start[c + 1]` is the slice of `order` holding the boids of cell c.
const Grid = struct {
    start: []u32, // cells + 1 entries
    cell: []u32, // cell of each boid
    order: []u32, // boid indices sorted by cell

    fn init(gpa: std.mem.Allocator, cells: usize, n: usize) !Grid {
        return .{ .start = try gpa.alloc(u32, cells + 1), .cell = try gpa.alloc(u32, n), .order = try gpa.alloc(u32, n) };
    }
    fn deinit(g: *Grid, gpa: std.mem.Allocator) void {
        gpa.free(g.start);
        gpa.free(g.cell);
        gpa.free(g.order);
    }

    /// Counting sort by cell key: count, prefix sum, scatter. O(n + cells), no allocation.
    fn build(g: *Grid, w: World, xs: []const f32, ys: []const f32, comptime key: fn (World, f32, f32) u32) void {
        // 1. count: start[c] = boids in cell c
        @memset(g.start, 0);
        for (g.cell, xs, ys) |*c, x, y| {
            c.* = key(w, x, y);
            g.start[c.*] += 1;
        }
        // 2. inclusive prefix sum: start[c] = boids in cells 0..=c
        var sum: u32 = 0;
        for (g.start) |*s| {
            sum += s.*;
            s.* = sum;
        }
        // 3. scatter back to front: each boid takes the last free slot of its cell, so start[c]
        //    ends at the first slot of cell c and boids keep their spawn order inside a cell.
        var i = g.cell.len;
        while (i > 0) {
            i -= 1;
            const c = g.cell[i];
            g.start[c] -= 1;
            g.order[g.start[c]] = @intCast(i);
        }
    }

    /// Positions in `order` of cells first..=last (consecutive cell numbers).
    fn span(g: *const Grid, first: u32, last: u32) [2]usize {
        return .{ g.start[first], g.start[last + 1] };
    }
};

// ---- the variants. Each reads `cur`, writes `next` (double buffering) and returns total neighbours. ----

fn stepNaive(w: World, cur: *const Boids, next: *Boids) u64 {
    const n = cur.n;
    const c = cur.c;
    var total: u64 = 0;
    for (0..n) |i| {
        var acc: Acc = .{};
        visitSpan(&acc, c, 0, n, c.x[i], c.y[i]);
        total += acc.n;
        setOut(next.c, i, acc.integrate(w, c.x[i], c.y[i], c.vx[i], c.vy[i]), c.id[i]);
    }
    return total;
}

fn stepGrid(w: World, g: *Grid, cur: *const Boids, next: *Boids) u64 {
    const n = cur.n;
    const c = cur.c;
    g.build(w, c.x[0..n], c.y[0..n], World.rowMajor);
    var total: u64 = 0;
    for (0..n) |i| {
        const xi = c.x[i];
        const yi = c.y[i];
        const b = w.block(xi, yi);
        var acc: Acc = .{};
        for (b[2]..b[3] + 1) |row_| {
            const row: u32 = @intCast(row_);
            // three cells of one row are consecutive in `order`, but the boids they name are anywhere
            const r = g.span(row * w.side + b[0], row * w.side + b[1]);
            for (g.order[r[0]..r[1]]) |j| acc.visit(xi, yi, c.x[j], c.y[j], c.vx[j], c.vy[j]);
        }
        total += acc.n;
        setOut(next.c, i, acc.integrate(w, xi, yi, c.vx[i], c.vy[i]), c.id[i]);
    }
    return total;
}

fn stepSorted(w: World, g: *Grid, cur: *const Boids, s: *Boids, next: *Boids) u64 {
    const n = cur.n;
    g.build(w, cur.c.x[0..n], cur.c.y[0..n], World.rowMajor);
    s.gatherFrom(cur, g.order); // now cell c is s[start[c]..start[c + 1]]
    const c = s.c;
    var total: u64 = 0;
    for (0..n) |k| {
        const xi = c.x[k];
        const yi = c.y[k];
        const b = w.block(xi, yi);
        var acc: Acc = .{};
        for (b[2]..b[3] + 1) |row_| {
            const row: u32 = @intCast(row_);
            const r = g.span(row * w.side + b[0], row * w.side + b[1]);
            visitSpan(&acc, c, r[0], r[1], xi, yi);
        }
        total += acc.n;
        setOut(next.c, k, acc.integrate(w, xi, yi, c.vx[k], c.vy[k]), c.id[k]);
    }
    return total;
}

fn stepMorton(w: World, g: *Grid, cur: *const Boids, s: *Boids, next: *Boids) u64 {
    const n = cur.n;
    g.build(w, cur.c.x[0..n], cur.c.y[0..n], World.mortonKey);
    s.gatherFrom(cur, g.order);
    const c = s.c;
    var total: u64 = 0;
    for (0..n) |k| {
        const xi = c.x[k];
        const yi = c.y[k];
        const b = w.block(xi, yi);
        var acc: Acc = .{};
        for (b[2]..b[3] + 1) |row| {
            for (b[0]..b[1] + 1) |col| {
                const m = morton(@intCast(col), @intCast(row)); // neighbouring cells are no longer consecutive: 9 spans
                const r = g.span(m, m);
                visitSpan(&acc, c, r[0], r[1], xi, yi);
            }
        }
        total += acc.n;
        setOut(next.c, k, acc.integrate(w, xi, yi, c.vx[k], c.vy[k]), c.id[k]);
    }
    return total;
}

const V = @Vector(LANES, f32);
const VU = @Vector(LANES, u32);
const lane_index: VU = std.simd.iota(u32, LANES);

/// Eight independent accumulators: lane l sums elements l, l + 8, l + 16, ... of each span.
/// Zig 0.17.1 turns off LLVM's loop vectorizer, so this is spelled out with @Vector.
const Acc8 = struct {
    n: VU = @splat(0),
    sx: V = @splat(0),
    sy: V = @splat(0),
    ax: V = @splat(0),
    ay: V = @splat(0),
    qx: V = @splat(0),
    qy: V = @splat(0),

    /// Branch-free: every lane computes, and a mask decides what it adds. Lanes past the end of
    /// the span read real (or padding) boids that the index mask throws away.
    inline fn visitSpan(self: *Acc8, b: Cols, a: usize, e: usize, xi: f32, yi: f32) void {
        const zero: V = @splat(0);
        const none: @Vector(LANES, bool) = @splat(false);
        var j = a;
        while (j < e) : (j += LANES) {
            const x: V = b.x[j..][0..LANES].*;
            const y: V = b.y[j..][0..LANES].*;
            const vx: V = b.vx[j..][0..LANES].*;
            const vy: V = b.vy[j..][0..LANES].*;
            const dx = x - @as(V, @splat(xi));
            const dy = y - @as(V, @splat(yi));
            const d2 = dx * dx + dy * dy;
            const in_span = lane_index < @as(VU, @splat(@intCast(e - j)));
            const live = @select(bool, in_span, d2 < @as(V, @splat(NEIGHBOR_R2)), none);
            const close = @select(bool, live, d2 < @as(V, @splat(SEPARATION_R2)), none);
            self.n += @select(u32, live, @as(VU, @splat(1)), @as(VU, @splat(0)));
            self.sx += @select(f32, live, dx, zero);
            self.sy += @select(f32, live, dy, zero);
            self.ax += @select(f32, live, vx, zero);
            self.ay += @select(f32, live, vy, zero);
            self.qx -= @select(f32, close, dx, zero);
            self.qy -= @select(f32, close, dy, zero);
        }
    }

    /// Adds the lanes in order 0..8, the same order as Rust and Odin.
    /// (@reduce(.Add, v) is faster but may add in any order, so the bits would differ.)
    fn reduce(self: Acc8) Acc {
        const sum = struct {
            fn f(v: V) f32 {
                const arr: [LANES]f32 = v;
                var t: f32 = 0;
                for (arr) |e| t += e;
                return t;
            }
        }.f;
        return .{ .n = @reduce(.Add, self.n), .sx = sum(self.sx), .sy = sum(self.sy), .ax = sum(self.ax), .ay = sum(self.ay), .qx = sum(self.qx), .qy = sum(self.qy) };
    }
};

/// The neighbour pass of the SIMD variants for sorted boids k0..k1.
fn simdRange(w: World, g: *const Grid, c: Cols, out: Cols, k0: usize, k1: usize) u64 {
    var total: u64 = 0;
    for (k0..k1) |k| {
        const xi = c.x[k];
        const yi = c.y[k];
        const b = w.block(xi, yi);
        var acc8: Acc8 = .{};
        for (b[2]..b[3] + 1) |row_| {
            const row: u32 = @intCast(row_);
            const r = g.span(row * w.side + b[0], row * w.side + b[1]);
            acc8.visitSpan(c, r[0], r[1], xi, yi);
        }
        const acc = acc8.reduce();
        total += acc.n;
        setOut(out, k, acc.integrate(w, xi, yi, c.vx[k], c.vy[k]), c.id[k]);
    }
    return total;
}

fn stepSimd(w: World, g: *Grid, cur: *const Boids, s: *Boids, next: *Boids) u64 {
    const n = cur.n;
    g.build(w, cur.c.x[0..n], cur.c.y[0..n], World.rowMajor);
    s.gatherFrom(cur, g.order);
    return simdRange(w, g, s.c, next.c, 0, n);
}

/// One thread's share of the output. Padded to a cache line so the two `total`s never share one.
const Job = struct {
    w: World,
    g: *const Grid,
    s: Cols,
    out: Cols,
    k0: usize,
    k1: usize,
    total: u64 align(std.atomic.cache_line) = 0,

    fn run(j: *Job) void {
        j.total = simdRange(j.w, j.g, j.s, j.out, j.k0, j.k1);
    }
};

/// Build and gather stay serial; the neighbour pass is split into THREADS disjoint output ranges.
fn stepThreads(w: World, g: *Grid, cur: *const Boids, s: *Boids, next: *Boids) u64 {
    const n = cur.n;
    g.build(w, cur.c.x[0..n], cur.c.y[0..n], World.rowMajor);
    s.gatherFrom(cur, g.order);
    const chunk = std.math.divCeil(usize, n, THREADS) catch unreachable;
    var jobs: [THREADS]Job = undefined;
    var threads: [THREADS]std.Thread = undefined;
    for (&jobs, &threads, 0..) |*j, *t, i| {
        j.* = .{ .w = w, .g = g, .s = s.c, .out = next.c, .k0 = @min(i * chunk, n), .k1 = @min((i + 1) * chunk, n) };
        t.* = std.Thread.spawn(.{}, Job.run, .{j}) catch @panic("thread spawn failed");
    }
    var total: u64 = 0;
    for (threads, &jobs) |t, *j| {
        t.join(); // read j.total only after the join
        total += j.total;
    }
    return total;
}

// ---- driver ----

const LABELS = [_][]const u8{ "naive", "grid", "sorted", "morton", "sorted simd", "simd 2 threads" };

/// Everything one benchmark call needs; `variant` picks the step function.
const Ctx = struct {
    w: World,
    variant: usize,
    spawned: *const Boids,
    in_rows: *const Boids,
    in_morton: *const Boids,
    g: *Grid,
    gm: *Grid,
    s: *Boids,
    next: *Boids,
};

fn runStep(c: *const Ctx) u64 {
    return switch (c.variant) {
        0 => stepNaive(c.w, c.spawned, c.next),
        1 => stepGrid(c.w, c.g, c.spawned, c.next),
        2 => stepSorted(c.w, c.g, c.in_rows, c.s, c.next),
        3 => stepMorton(c.w, c.gm, c.in_morton, c.s, c.next),
        4 => stepSimd(c.w, c.g, c.in_rows, c.s, c.next),
        else => stepThreads(c.w, c.g, c.in_rows, c.s, c.next),
    };
}

/// The state indexed by spawn id, so outputs stored in different orders can be compared.
fn byId(b: *const Boids, v: [][4]f32) void {
    const c = b.c;
    for (0..b.n) |k| v[c.id[k]] = .{ c.x[k], c.y[k], c.vx[k], c.vy[k] };
}

/// FNV-1a over the bits of the state in spawn order: equal only if every float is bit-identical.
fn checksum(v: []const [4]f32) u64 {
    var h: u64 = 0xCBF2_9CE4_8422_2325;
    for (v) |s| for (s) |f| {
        h = (h ^ @as(u32, @bitCast(f))) *% 0x100_0000_01B3;
    };
    return h;
}

/// Largest difference in any position or velocity component.
fn maxDiff(a: []const [4]f32, b: []const [4]f32) f32 {
    var m: f32 = 0;
    for (a, b) |p, q| for (p, q) |u, v| {
        m = @max(m, @abs(u - v));
    };
    return m;
}

/// Distance checks per step: n² for naive, the sum of 3×3 block sizes for the grid.
fn gridChecks(w: World, g: *const Grid, b: *const Boids) u64 {
    var checks: u64 = 0;
    for (0..b.n) |i| {
        const bl = w.block(b.c.x[i], b.c.y[i]);
        for (bl[2]..bl[3] + 1) |row_| {
            const row: u32 = @intCast(row_);
            const r = g.span(row * w.side + bl[0], row * w.side + bl[1]);
            checks += r[1] - r[0];
        }
    }
    return checks;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    try out.print("ch10 (zig): boids step, {d} boids per unit cell on average, neighbour radius 1, {d} threads; quick={}\n", .{ BOIDS_PER_CELL, THREADS, args.quick });
    var ok = true;
    var e: u6 = 10;
    while (e <= 20) : (e += 2) {
        const n = @as(usize, 1) << e;
        if (n > args.n) break;
        const w = World.forCount(n);
        var spawned = try Boids.spawn(gpa, n, w);
        defer spawned.deinit(gpa);
        var g = try Grid.init(gpa, @as(usize, w.side) * w.side, n);
        defer g.deinit(gpa);
        var gm = try Grid.init(gpa, w.mortonCells(), n);
        defer gm.deinit(gpa);
        g.build(w, spawned.c.x[0..n], spawned.c.y[0..n], World.rowMajor);
        const checks = gridChecks(w, &g, &spawned);
        // Inputs as the previous frame would leave them: spawn order for naive and grid,
        // cell order for the variants that reorder every step.
        var in_rows = try Boids.init(gpa, n);
        defer in_rows.deinit(gpa);
        in_rows.gatherFrom(&spawned, g.order);
        gm.build(w, spawned.c.x[0..n], spawned.c.y[0..n], World.mortonKey);
        var in_morton = try Boids.init(gpa, n);
        defer in_morton.deinit(gpa);
        in_morton.gatherFrom(&spawned, gm.order);

        try out.print("\nN = {d}: world {d}×{d} cells, distance checks per step: naive {d}, grid {d} ({d:.1} per boid)\n", .{
            n, w.side, w.side, @as(u64, n) * n, checks, @as(f64, @floatFromInt(checks)) / @as(f64, @floatFromInt(n)),
        });
        try out.print("  {s:<15} {s:>12} {s:>10} {s:>12} {s:>14}\n", .{ "variant", "median us", "ns/boid", "neighbours", "max |diff|" });
        var s = try Boids.init(gpa, n);
        defer s.deinit(gpa);
        var next = try Boids.init(gpa, n);
        defer next.deinit(gpa);
        const ref_state = try gpa.alloc([4]f32, n);
        defer gpa.free(ref_state);
        const state = try gpa.alloc([4]f32, n);
        defer gpa.free(state);
        var ref_total: ?u64 = null;
        for (LABELS, 0..) |label, v| {
            if (v == 0 and n > NAIVE_MAX) continue;
            const ctx: Ctx = .{ .w = w, .variant = v, .spawned = &spawned, .in_rows = &in_rows, .in_morton = &in_morton, .g = &g, .gm = &gm, .s = &s, .next = &next };
            const total = runStep(&ctx);
            byId(&next, state);
            if (ref_total == null) {
                ref_total = total;
                @memcpy(ref_state, state);
            }
            const diff = maxDiff(ref_state, state);
            const good = total == ref_total.? and diff <= 1e-4;
            ok = ok and good;
            if (v <= 1) try out.print("  ({s} state checksum {x:0>16})\n", .{ label, checksum(state) });
            const runs = benchRuns(io, runStep, &ctx);
            const med = runs[RUNS / 2];
            try out.print("  {s:<15} {d:>12.1} {d:>10.2} {d:>12} {e:>14.2} {s}\n", .{
                label, @as(f64, @floatFromInt(med)) / 1000.0, @as(f64, @floatFromInt(med)) / @as(f64, @floatFromInt(n)), total, diff, if (good) "ok" else "MISMATCH",
            });
            try emitBench(out, "ch10-boids", label, n, &runs);
            try out.flush();
        }
    }
    try out.print("\nall variants agree (neighbour counts exact, state within 1e-4): {s}\n", .{if (ok) "yes" else "NO"});
    try out.flush();
    if (!ok) std.process.exit(1);
}
