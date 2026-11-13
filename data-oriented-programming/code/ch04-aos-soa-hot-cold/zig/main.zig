// Chapter 4: one particle update in four layouts (AoS, hot/cold, SoA, AoSoA) plus three controls:
// read every field (AoS catches up), random whole-record reads (AoS wins), and 16 page-aligned
// columns versus staggered columns (cache-set aliasing). Every variant of one experiment must print
// the same checksum, in all three languages.
//
//   zig run -O fast main.zig -- [N] [--quick]
//
// Sizes: N/64, N and 4N particles (default N = 1 << 20; --quick caps N at 4096).

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

/// A power of two, so `v * dt` is exact and fused or unfused multiply-add give the same bits.
const dt: f32 = 1.0 / 64.0;
/// AoSoA block width: eight f32 lanes, one AVX2 register.
const lanes = 8;

// ---- the data: a fat 64-byte particle ----
// zig fmt: off
/// Sixteen 4-byte fields. The update reads 6 of them (24 B) and writes 3.
const Particle = struct {
    px: f32, py: f32, pz: f32, // hot: read and written every frame
    vx: f32, vy: f32, vz: f32, // hot: read every frame
    mass: f32, age: f32, life: f32, size: f32, // cold from here on
    color: u32, id: u32, flags: u32, seed: u32, emitter: u32, group: u32,
};
comptime {
    std.debug.assert(@sizeOf(Particle) == 64);
}
// zig fmt: on

/// lowbias32 (Chris Wellons): the same integer hash in all three languages, so the data is identical.
fn hash(x0: u32) u32 {
    var x = x0;
    x ^= x >> 16;
    x *%= 0x7feb352d;
    x ^= x >> 15;
    x *%= 0x846ca68b;
    return x ^ (x >> 16);
}

/// 24 random bits as an exact f32 in [0, 1).
fn unit(h: u32) f32 {
    return @as(f32, @floatFromInt(h >> 8)) / 16777216.0;
}

fn particle(index: usize) Particle {
    const i: u32 = @intCast(index);
    const b = i *% 16;
    // zig fmt: off
    return .{
        .px = unit(hash(b + 0)) * 128.0, .py = unit(hash(b + 1)) * 128.0, .pz = unit(hash(b + 2)) * 128.0,
        .vx = unit(hash(b + 3)) - 0.5, .vy = unit(hash(b + 4)) - 0.5, .vz = unit(hash(b + 5)) - 0.5,
        .mass = unit(hash(b + 6)) + 1.0, .age = unit(hash(b + 7)), .life = unit(hash(b + 8)) * 4.0, .size = unit(hash(b + 9)),
        .color = hash(b + 10), .id = i, .flags = hash(b + 12) & 0xff,
        .seed = hash(b + 13), .emitter = hash(b + 14) & 63, .group = hash(b + 15) & 7,
    };
    // zig fmt: on
}

/// The record checksum: the bit patterns of all 16 fields, summed as integers (exact, any order).
/// Field order does not matter, so `inline for` over the struct's fields covers all of them.
fn fieldSum(p: Particle) u64 {
    var s: u64 = 0;
    inline for (@typeInfo(Particle).@"struct".field_names) |name| {
        const bits: u32 = @bitCast(@field(p, name));
        s += bits;
    }
    return s;
}

fn posSum(p: Particle) u64 {
    const x: u32 = @bitCast(p.px);
    const y: u32 = @bitCast(p.py);
    const z: u32 = @bitCast(p.pz);
    return @as(u64, x) + y + z;
}

// ---- 1. AoS: one aligned slice of 64-byte records ----
const Aos = struct {
    pub const label = "AoS";
    pub const update_bytes = 64;
    ps: []align(64) Particle, // one particle = exactly one cache line

    fn build(gpa: Allocator, n: usize) !Aos {
        const ps = try gpa.alignedAlloc(Particle, .fromByteUnits(64), n);
        for (ps, 0..) |*p, i| p.* = particle(i);
        return .{ .ps = ps };
    }
    fn deinit(self: *Aos, gpa: Allocator) void {
        gpa.free(self.ps);
    }
    fn update(self: *Aos) void {
        for (self.ps) |*p| {
            p.px += p.vx * dt;
            p.py += p.vy * dt;
            p.pz += p.vz * dt;
        }
    }
    fn get(self: *const Aos, i: usize) Particle {
        return self.ps[i];
    }
    fn len(self: *const Aos) usize {
        return self.ps.len;
    }
    fn every(self: *const Aos) u64 {
        var s: u64 = 0;
        for (self.ps) |p| s +%= fieldSum(p);
        return s;
    }
};

// ---- 2. hot/cold split: a MultiArrayList with two columns, each an AoS ----
const Hot = struct { px: f32, py: f32, pz: f32, vx: f32, vy: f32, vz: f32 };
// zig fmt: off
const Cold = struct {
    mass: f32, age: f32, life: f32, size: f32,
    color: u32, id: u32, flags: u32, seed: u32, emitter: u32, group: u32,
};
// zig fmt: on
comptime {
    std.debug.assert(@sizeOf(Hot) == 24 and @sizeOf(Cold) == 40);
}

const HotCold = struct {
    pub const label = "hot/cold";
    pub const update_bytes = 24;
    list: std.MultiArrayList(struct { hot: Hot, cold: Cold }),

    fn build(gpa: Allocator, n: usize) !HotCold {
        var self: HotCold = .{ .list = .empty };
        try self.list.ensureTotalCapacity(gpa, n);
        for (0..n) |i| {
            const p = particle(i);
            // zig fmt: off
            self.list.appendAssumeCapacity(.{
                .hot = .{ .px = p.px, .py = p.py, .pz = p.pz, .vx = p.vx, .vy = p.vy, .vz = p.vz },
                .cold = .{
                    .mass = p.mass, .age = p.age, .life = p.life, .size = p.size, .color = p.color,
                    .id = p.id, .flags = p.flags, .seed = p.seed, .emitter = p.emitter, .group = p.group,
                },
            });
            // zig fmt: on
        }
        return self;
    }
    fn deinit(self: *HotCold, gpa: Allocator) void {
        self.list.deinit(gpa);
    }
    fn update(self: *HotCold) void {
        for (self.list.items(.hot)) |*h| {
            h.px += h.vx * dt;
            h.py += h.vy * dt;
            h.pz += h.vz * dt;
        }
    }
    /// Glue one hot and one cold record back into a whole particle.
    fn join(h: Hot, c: Cold) Particle {
        // zig fmt: off
        return .{
            .px = h.px, .py = h.py, .pz = h.pz, .vx = h.vx, .vy = h.vy, .vz = h.vz,
            .mass = c.mass, .age = c.age, .life = c.life, .size = c.size, .color = c.color,
            .id = c.id, .flags = c.flags, .seed = c.seed, .emitter = c.emitter, .group = c.group,
        };
        // zig fmt: on
    }
    fn get(self: *const HotCold, i: usize) Particle {
        const s = self.list.slice();
        return join(s.items(.hot)[i], s.items(.cold)[i]);
    }
    fn len(self: *const HotCold) usize {
        return self.list.len;
    }
    fn every(self: *const HotCold) u64 {
        // Walk both columns in lockstep, like the other layouts (no per-record slice() or get(i)).
        const cols = self.list.slice();
        var s: u64 = 0;
        for (cols.items(.hot), cols.items(.cold)) |h, c| s +%= fieldSum(join(h, c));
        return s;
    }
};

// ---- 3. SoA: std.MultiArrayList(Particle), one column per field in one allocation ----
const Soa = SoaLayout(false);
/// Zig 0.17.1 builds with LLVM's loop vectorizer switched off (src/zig_llvm.cpp), so a plain
/// `for` over columns stays scalar. This variant spells out the 8-wide vectors with @Vector.
const SoaVec = SoaLayout(true);

fn SoaLayout(comptime vectorized: bool) type {
    return struct {
        const Self = @This();
        pub const label = if (vectorized) "SoA @Vector" else "SoA";
        pub const update_bytes = 24;
        list: std.MultiArrayList(Particle),
        cols: std.MultiArrayList(Particle).Slice, // column pointers, computed once (valid until the list grows)

        fn build(gpa: Allocator, n: usize) !Self {
            var list = try std.MultiArrayList(Particle).initCapacity(gpa, n); // exactly n: no rounding up
            for (0..n) |i| list.appendAssumeCapacity(particle(i));
            return .{ .list = list, .cols = list.slice() };
        }
        fn deinit(self: *Self, gpa: Allocator) void {
            self.list.deinit(gpa);
        }
        fn update(self: *Self) void {
            const s = self.cols;
            if (vectorized) {
                integrateVec(s.items(.px), s.items(.vx));
                integrateVec(s.items(.py), s.items(.vy));
                integrateVec(s.items(.pz), s.items(.vz));
            } else {
                for (s.items(.px), s.items(.py), s.items(.pz), s.items(.vx), s.items(.vy), s.items(.vz)) |*x, *y, *z, vx, vy, vz| {
                    x.* += vx * dt;
                    y.* += vy * dt;
                    z.* += vz * dt;
                }
            }
        }
        fn get(self: *const Self, i: usize) Particle {
            return self.cols.get(i); // gathers 16 columns into one struct
        }
        fn len(self: *const Self) usize {
            return self.list.len;
        }
        fn every(self: *const Self) u64 {
            // Row by row over the 16 columns: the same loop as the aliasing experiment below.
            var cols: [cols_n][]const u32 = undefined;
            inline for (@typeInfo(Particle).@"struct".field_names, 0..) |name, k| {
                cols[k] = @ptrCast(self.cols.items(@field(std.MultiArrayList(Particle).Field, name)));
            }
            return sumColumns(&cols);
        }
    };
}

/// p += v * dt, eight lanes at a time, then a scalar tail.
fn integrateVec(p: []f32, v: []const f32) void {
    const V = @Vector(lanes, f32);
    const dtv: V = @splat(dt);
    var i: usize = 0;
    while (i + lanes <= p.len) : (i += lanes) {
        const pv: V = p[i..][0..lanes].*;
        const vv: V = v[i..][0..lanes].*;
        p[i..][0..lanes].* = pv + vv * dtv;
    }
    for (p[i..], v[i..]) |*x, u| x.* += u * dt;
}

// ---- 4. AoSoA: blocks of 8 particles, SoA inside each block ----
// zig fmt: off
const Block = struct {
    px: [lanes]f32, py: [lanes]f32, pz: [lanes]f32,
    vx: [lanes]f32, vy: [lanes]f32, vz: [lanes]f32,
    mass: [lanes]f32, age: [lanes]f32, life: [lanes]f32, size: [lanes]f32,
    color: [lanes]u32, id: [lanes]u32, flags: [lanes]u32,
    seed: [lanes]u32, emitter: [lanes]u32, group: [lanes]u32,
    // zig fmt: on

    /// Gather lane j into a whole record (field names match Particle).
    fn lane(b: *const Block, j: usize) Particle {
        var p: Particle = undefined;
        inline for (@typeInfo(Particle).@"struct".field_names) |name| @field(p, name) = @field(b, name)[j];
        return p;
    }
    fn setLane(b: *Block, j: usize, p: Particle) void {
        inline for (@typeInfo(Particle).@"struct".field_names) |name| @field(b, name)[j] = @field(p, name);
    }
};
comptime {
    std.debug.assert(@sizeOf(Block) == 16 * 4 * lanes);
}

const Aosoa = struct {
    pub const label = "AoSoA";
    pub const update_bytes = 24;
    blocks: []align(64) Block,

    fn build(gpa: Allocator, n: usize) !Aosoa {
        std.debug.assert(n % lanes == 0);
        const blocks = try gpa.alignedAlloc(Block, .fromByteUnits(64), n / lanes);
        for (0..n) |i| blocks[i / lanes].setLane(i % lanes, particle(i));
        return .{ .blocks = blocks };
    }
    fn deinit(self: *Aosoa, gpa: Allocator) void {
        gpa.free(self.blocks);
    }
    fn update(self: *Aosoa) void {
        for (self.blocks) |*b| {
            for (&b.px, &b.py, &b.pz, b.vx, b.vy, b.vz) |*x, *y, *z, vx, vy, vz| {
                x.* += vx * dt;
                y.* += vy * dt;
                z.* += vz * dt;
            }
        }
    }
    fn get(self: *const Aosoa, i: usize) Particle {
        return self.blocks[i / lanes].lane(i % lanes);
    }
    fn len(self: *const Aosoa) usize {
        return self.blocks.len * lanes;
    }
    fn every(self: *const Aosoa) u64 {
        var s: u64 = 0;
        for (self.blocks) |*b| {
            for (0..lanes) |j| s +%= fieldSum(b.lane(j));
        }
        return s;
    }
};

// ---- the experiments ----
/// Random whole-record reads: the access pattern where AoS wins.
fn RandomCtx(comptime L: type) type {
    return struct { l: *const L, idx: []const u32 };
}

fn randomReads(comptime L: type) fn (RandomCtx(L)) u64 {
    return struct {
        fn f(c: RandomCtx(L)) u64 {
            var s: u64 = 0;
            for (c.idx) |i| s +%= fieldSum(c.l.get(i));
            return s;
        }
    }.f;
}

const Row = struct { label: []const u8, bytes: usize, ns: [3]u64, sums: [3]u64 };

fn run(comptime L: type, gpa: Allocator, io: Io, out: *Io.Writer, n: usize, idx: []const u32) !Row {
    var l = try L.build(gpa, n);
    defer l.deinit(gpa);
    const up = benchRuns(io, L.update, &l); // 1 warm-up + 7 timed = 8 updates
    var pos: u64 = 0;
    for (0..n) |i| pos +%= posSum(l.get(i));
    const every = benchRuns(io, L.every, @as(*const L, &l));
    const rctx: RandomCtx(L) = .{ .l = &l, .idx = idx };
    const rnd = benchRuns(io, randomReads(L), rctx);
    try emitBench(out, "ch04-update", L.label, n, &up);
    try emitBench(out, "ch04-every", L.label, n, &every);
    try emitBench(out, "ch04-random", L.label, n, &rnd);
    return .{
        .label = L.label,
        .bytes = L.update_bytes,
        .ns = .{ up[RUNS / 2], every[RUNS / 2], rnd[RUNS / 2] },
        .sums = .{ pos, l.every(), randomReads(L)(rctx) },
    };
}

// ---- 16 columns in one buffer: 4 KiB apart vs staggered by one cache line ----
const cols_n = 16;

fn sumColumns(cols: *const [cols_n][]const u32) u64 {
    var total: u64 = 0;
    for (0..cols[0].len) |i| {
        var s: u64 = 0;
        inline for (cols) |c| s += c[i];
        total +%= s;
    }
    return total;
}

/// Column k starts at k * stride elements. stride = n (n a power of two): every column start is a
/// multiple of 4 KiB from the first, so element i of all 16 columns maps to the same L1 set.
fn aliasExperiment(gpa: Allocator, io: Io, out: *Io.Writer, n: usize) ![2]u64 {
    const skew = 16; // 16 u32 = 64 B = one cache line
    const buf = try gpa.alignedAlloc(u32, .fromByteUnits(64), cols_n * (n + skew));
    defer gpa.free(buf);
    var sums: [2]u64 = undefined;
    const cases = [_]struct { stride: usize, label: []const u8 }{
        .{ .stride = n, .label = "4 KiB-aligned columns" },
        .{ .stride = n + skew, .label = "staggered columns" },
    };
    for (cases, 0..) |case, s| {
        var cols: [cols_n][]const u32 = undefined;
        for (&cols, 0..) |*c, k| {
            const col = buf[k * case.stride ..][0..n];
            for (col, 0..) |*x, i| x.* = hash(@intCast(i * cols_n + k));
            c.* = col;
        }
        const runs = benchRuns(io, sumColumns, &cols);
        sums[s] = sumColumns(&cols);
        try out.print("  {s:<22} {d:>8.3} ns/elem  checksum {x:0>16}  column starts mod 4096: {d}, {d}, {d}, {d} ...\n", .{
            case.label,                      perElem(runs[RUNS / 2], n),      sums[s],
            @intFromPtr(cols[0].ptr) % 4096, @intFromPtr(cols[1].ptr) % 4096, @intFromPtr(cols[2].ptr) % 4096,
            @intFromPtr(cols[3].ptr) % 4096,
        });
        try emitBench(out, "ch04-alias", case.label, n, &runs);
    }
    return sums;
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
    const base = @max(args.n, 64) / lanes * lanes;
    try out.print("ch04 (zig): @sizeOf Particle {d} B, Hot {d} B, Cold {d} B, Block {d} B; quick={}\n", .{
        @sizeOf(Particle), @sizeOf(Hot), @sizeOf(Cold), @sizeOf(Block), args.quick,
    });

    // Where MultiArrayList puts its columns: back to back, so a power-of-two capacity
    // makes every column start a multiple of 4 KiB from the first.
    {
        var probe: std.MultiArrayList(Particle) = .empty;
        defer probe.deinit(gpa);
        try probe.setCapacity(gpa, 4096);
        const s = probe.slice();
        const p0 = @intFromPtr(s.items(.px).ptr);
        try out.print("MultiArrayList(Particle), capacity 4096: px, vx, seed columns start at +{d}, +{d}, +{d} B (mod 4096: {d}, {d}, {d})\n", .{
            0,         @intFromPtr(s.items(.vx).ptr) - p0,   @intFromPtr(s.items(.seed).ptr) - p0,
            p0 % 4096, @intFromPtr(s.items(.vx).ptr) % 4096, @intFromPtr(s.items(.seed).ptr) % 4096,
        });
    }

    var ok = true;
    for ([_]usize{ base / 64 / lanes * lanes, base, base * 4 }) |n0| {
        const n = @max(n0, lanes);
        const idx = try gpa.alloc(u32, n);
        defer gpa.free(idx);
        for (idx, 0..) |*x, k| x.* = hash(@as(u32, @intCast(k)) ^ 0x9e3779b9) % @as(u32, @intCast(n));

        try out.print("\nn = {d} particles ({d} KiB of AoS)\n", .{ n, n * 64 / 1024 });
        try out.print("  {s:<11} {s:>7} {s:>14} {s:>14} {s:>16}   checksums (update / every / random)\n", .{ "layout", "B/p", "update ns/p", "every ns/p", "random ns/read" });
        const rows = [_]Row{
            try run(Aos, gpa, io, out, n, idx),
            try run(HotCold, gpa, io, out, n, idx),
            try run(Soa, gpa, io, out, n, idx),
            try run(SoaVec, gpa, io, out, n, idx),
            try run(Aosoa, gpa, io, out, n, idx),
        };
        for (rows) |r| {
            try out.print("  {s:<11} {d:>7} {d:>14.3} {d:>14.3} {d:>16.3}   {x:0>16} / {x:0>16} / {x:0>16}\n", .{
                r.label,   r.bytes,   perElem(r.ns[0], n), perElem(r.ns[1], n), perElem(r.ns[2], n),
                r.sums[0], r.sums[1], r.sums[2],
            });
            ok = ok and std.mem.eql(u64, &r.sums, &rows[0].sums);
        }
        // Columns of n u32 are a multiple of 4 KiB apart only when n is a multiple of 1024.
        if (n % 1024 == 0) {
            const a = try aliasExperiment(gpa, io, out, n);
            ok = ok and a[0] == a[1];
        } else {
            try out.print("  (alias experiment skipped: {d} u32 columns are not a multiple of 4 KiB)\n", .{n});
        }
        try out.flush();
    }
    try out.print("\nchecksums match across layouts: {s}\n", .{if (ok) "yes" else "NO"});
    try out.flush();
    if (!ok) return error.LayoutsDisagree;
}
