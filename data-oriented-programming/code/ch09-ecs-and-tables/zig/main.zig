// Chapter 9: ECS and Thinking in Tables.
// A tiny ECS with generational entity ids (entity.zig) and two storages for the same data:
//   1. sparse sets, one per component type (sparse.zig), the EnTT layout;
//   2. one table per component combination (archetype.zig), the Unity/Bevy/flecs layout.
// The same world is built in both: N entities with Pos, every 2nd with Vel, every 4th with Hp.
// Benchmarks: add/remove churn (toggle Vel on N/16 random entities), then iteration of a
// 2-component query (Pos += Vel) and a 3-component query (Pos, Vel -> Hp). Checksums must match.
// Usage (from code/ch09-ecs-and-tables/zig): zig run -O fast main.zig -- [N] [--quick]

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
const Entity = @import("entity.zig").Entity;
const sparse = @import("sparse.zig");
const SparseWorld = sparse.SparseWorld;
const archetype = @import("archetype.zig");
const ArchWorld = archetype.ArchWorld;
const POS = archetype.POS;
const VEL = archetype.VEL;
const HP = archetype.HP;

pub const Pos = struct { x: i32, y: i32 };
pub const Vel = struct { x: i32, y: i32 };
pub const Hp = struct { v: i32 };

/// splitmix64: the same sequence in all three languages (as in Chapter 5).
const Rng = struct {
    s: u64,
    fn below(r: *Rng, n: usize) usize {
        r.s +%= 0x9E37_79B9_7F4A_7C15;
        var z = r.s;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        return @intCast((z ^ (z >> 31)) % n);
    }
};
const SEED = 9;

const Initial = struct { pos: Pos, vel: ?Vel, hp: ?Hp };

fn initial(i: usize) Initial {
    const k: i32 = @intCast(i);
    return .{
        .pos = .{ .x = k, .y = -k },
        .vel = if (i % 2 == 0) .{ .x = @as(i32, @intCast(i % 7)) - 3, .y = 1 } else null,
        .hp = if (i % 4 == 0) .{ .v = 100 } else null,
    };
}

fn velFor(e: Entity) Vel {
    return .{ .x = @as(i32, @intCast(e.index % 5)) - 2, .y = -1 };
}

fn bits(x: i32) u64 {
    return @as(u32, @bitCast(x));
}

/// Order-independent: wrapping sums commute, so both storages must agree whatever their row order.
fn mix(p: ?Pos, v: ?Vel, h: ?Hp) u64 {
    var s: u64 = 0;
    if (p) |q| s +%= bits(q.x *% 31 +% q.y *% 17);
    if (v) |q| s +%= bits((q.x *% 7) ^ q.y) +% (1 << 32);
    if (h) |q| s +%= bits(q.v *% 3) +% (1 << 40);
    return s;
}

// ---- sparse-set systems ----
fn moveOne(s: *u64, p: *Pos, v: *const Vel) void {
    p.x +%= v.x;
    p.y +%= v.y;
    s.* +%= bits(p.x);
}

fn damageOne(s: *u64, p: *const Pos, v: *const Vel, h: *Hp) void {
    h.v = h.v -% (p.x & 15) +% v.y;
    s.* +%= bits(h.v);
}

fn sparseMove(w: *SparseWorld) u64 {
    var s: u64 = 0;
    sparse.query2(&w.pos, &w.vel, &s, moveOne);
    return s;
}

fn sparseDamage(w: *SparseWorld) u64 {
    var s: u64 = 0;
    sparse.query3(&w.pos, &w.vel, &w.hp, &s, damageOne);
    return s;
}

/// What a churn run needs: the world, an allocator (adding may grow arrays), the random stream.
fn Churn(comptime W: type) type {
    return struct { w: *W, gpa: Allocator, rng: Rng, k: usize };
}

fn sparseToggle(c: *Churn(SparseWorld)) u64 {
    const w = c.w;
    for (0..c.k) |_| {
        const e = w.entities.at(c.rng.below(w.entities.capacity()));
        if (w.vel.remove(e) == null) w.vel.insert(c.gpa, e, velFor(e)) catch @panic("out of memory");
    }
    return w.vel.len();
}

fn sparseChecksum(w: *SparseWorld) u64 {
    var s: u64 = 0;
    for (0..w.entities.capacity()) |i| {
        const e = w.entities.at(i);
        if (!w.entities.alive(e)) continue;
        s +%= mix(
            if (w.pos.get(e)) |p| p.* else null,
            if (w.vel.get(e)) |v| v.* else null,
            if (w.hp.get(e)) |h| h.* else null,
        );
    }
    return s;
}

// ---- archetype systems: a query is a loop over matching tables, then plain zipped columns ----
fn archMove(w: *ArchWorld) u64 {
    var s: u64 = 0;
    for (&w.tables) |*t| {
        if (t.mask & (POS | VEL) != POS | VEL) continue;
        for (t.pos.items, t.vel.items) |*p, v| {
            p.x +%= v.x;
            p.y +%= v.y;
            s +%= bits(p.x);
        }
    }
    return s;
}

fn archDamage(w: *ArchWorld) u64 {
    var s: u64 = 0;
    for (&w.tables) |*t| {
        if (t.mask & (POS | VEL | HP) != POS | VEL | HP) continue;
        for (t.pos.items, t.vel.items, t.hp.items) |p, v, *h| {
            h.v = h.v -% (p.x & 15) +% v.y;
            s +%= bits(h.v);
        }
    }
    return s;
}

fn archToggle(c: *Churn(ArchWorld)) u64 {
    const w = c.w;
    for (0..c.k) |_| {
        const e = w.entities.at(c.rng.below(w.entities.capacity()));
        if (w.has(e, VEL)) {
            _ = w.removeVel(c.gpa, e) catch @panic("out of memory");
        } else {
            w.addVel(c.gpa, e, velFor(e)) catch @panic("out of memory");
        }
    }
    return w.countWith(VEL);
}

fn archChecksum(w: *ArchWorld) u64 {
    var s: u64 = 0;
    for (0..w.entities.capacity()) |i| {
        const e = w.entities.at(i);
        if (!w.entities.alive(e)) continue;
        const r = w.get(e);
        s +%= mix(r.pos, r.vel, r.hp);
    }
    return s;
}

/// Generations at work: a despawned id must stop resolving in both storages, even after its
/// index is reused.
fn staleIdDemo(gpa: Allocator, out: *Io.Writer) !void {
    var sw: SparseWorld = .{};
    defer sw.deinit(gpa);
    var aw: ArchWorld = .{};
    defer aw.deinit(gpa);
    var old_s: Entity = undefined;
    var old_a: Entity = undefined;
    for (0..4) |i| {
        const r = initial(i);
        const a = try sw.spawn(gpa, r.pos, r.vel, r.hp);
        const b = try aw.spawn(gpa, r.pos, r.vel, r.hp);
        if (i == 2) {
            old_s = a;
            old_a = b;
        }
    }
    if (!(try sw.despawn(gpa, old_s)) or !(try aw.despawn(gpa, old_a))) return error.DespawnFailed;
    const new_s = try sw.spawn(gpa, .{ .x = 7, .y = 7 }, null, null);
    const new_a = try aw.spawn(gpa, .{ .x = 7, .y = 7 }, null, null);
    std.debug.assert(new_s.index == old_s.index and new_s.generation == old_s.generation + 1 and new_a == new_s);
    std.debug.assert(sw.pos.get(old_s) == null and !aw.has(old_a, POS) and !(try sw.despawn(gpa, old_s)));
    std.debug.assert(sw.pos.get(new_s).?.x == 7 and aw.get(new_a).pos.?.x == 7);
    try out.print("stale id check: despawned {d}v{d}, respawn reused it as {d}v{d}; the old id resolves to nothing in both storages\n", .{ old_s.index, old_s.generation, new_s.index, new_s.generation });
}

fn perEntity(ns: u64, n: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    const n = args.n;
    const k = @max(n / 16, 1);
    try staleIdDemo(gpa, out);

    var sw: SparseWorld = .{};
    defer sw.deinit(gpa);
    var aw: ArchWorld = .{};
    defer aw.deinit(gpa);
    for (0..n) |i| {
        const r = initial(i);
        _ = try sw.spawn(gpa, r.pos, r.vel, r.hp);
        _ = try aw.spawn(gpa, r.pos, r.vel, r.hp);
    }
    try out.print("{d} entities: Pos {d}, Vel {d}, Hp {d}; Entity = {d} B, sparse slot = 4 B\n", .{ n, sw.pos.len(), sw.vel.len(), sw.hp.len(), @sizeOf(Entity) });

    // 1. structural churn: toggle Vel on k random entities per run (8 runs incl. warm-up)
    var cs: Churn(SparseWorld) = .{ .w = &sw, .gpa = gpa, .rng = .{ .s = SEED }, .k = k };
    const rs = benchRuns(io, sparseToggle, &cs);
    try emitBench(out, "ch09-churn", "sparse set: toggle Vel", k, &rs);
    var ca: Churn(ArchWorld) = .{ .w = &aw, .gpa = gpa, .rng = .{ .s = SEED }, .k = k };
    const ra = benchRuns(io, archToggle, &ca);
    try emitBench(out, "ch09-churn", "archetype: toggle Vel", k, &ra);
    try out.print("churn, {d} toggles: sparse {d:.1} ns/op, archetype {d:.1} ns/op; Vel now on {d} | {d} entities\n", .{ k, perEntity(rs[RUNS / 2], k), perEntity(ra[RUNS / 2], k), sw.vel.len(), aw.countWith(VEL) });
    try out.print("archetype table sizes by mask [-, P, V, PV, H, PH, VH, PVH]: [", .{});
    for (&aw.tables, 0..) |*t, m| try out.print("{s}{d}", .{ if (m == 0) "" else ", ", t.entities.items.len });
    try out.print("]\n", .{});

    // 2. iteration: the same two systems over both storages
    inline for (.{
        .{ "move P+=V", sparseMove, archMove },
        .{ "damage P,V->H", sparseDamage, archDamage },
    }) |sys| {
        const s_runs = benchRuns(io, sys[1], &sw);
        const a_runs = benchRuns(io, sys[2], &aw);
        try emitBench(out, "ch09-iterate", "sparse set: " ++ sys[0], n, &s_runs);
        try emitBench(out, "ch09-iterate", "archetype: " ++ sys[0], n, &a_runs);
        try out.print("{s:<14} sparse {d:>7.2} ns/entity  archetype {d:>7.2} ns/entity  ({d:.1}x)\n", .{
            sys[0],                                                          perEntity(s_runs[RUNS / 2], n), perEntity(a_runs[RUNS / 2], n),
            perEntity(s_runs[RUNS / 2], 1) / perEntity(a_runs[RUNS / 2], 1),
        });
    }

    const c1 = sparseChecksum(&sw);
    const c2 = archChecksum(&aw);
    try out.print("checksum sparse 0x{x:0>16} archetype 0x{x:0>16} {s}\n", .{ c1, c2, if (c1 == c2) "(match)" else "MISMATCH" });
    try out.flush();
    if (c1 != c2) return error.ChecksumMismatch;
}
