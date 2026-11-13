//! Chapter 7: branches, batches and existence (Zig 0.17.1). The same four sections as the
//! Rust and Odin programs, with the same inputs, so all three print the same checksums.
//!
//! 1. Branches: a filter over L1/L2-resident data, branchy vs branchless, swept over predictability.
//! 2. Existence: "alive" as a field, a bool array, a std.bit_set.Dynamic, or a MultiArrayList table.
//! 3. Batches: one pipeline, three stages called through function pointers, batch size 1 .. N.
//! 4. Lookup: classify bytes with comparisons vs a 256-entry comptime table.
//!
//! Run: `zig run -O fast main.zig -- [N] [--quick]`

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

/// What every section needs: the Io (for the clock), stdout and an allocator.
const Env = struct { io: Io, out: *Io.Writer, gpa: Allocator };

/// splitmix64. All three programs use it with the same seeds, so they build identical
/// inputs and print identical checksums.
const Rng = struct {
    state: u64,

    fn next(r: *Rng) u64 {
        r.state +%= 0x9E37_79B9_7F4A_7C15;
        var z = r.state;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        return z ^ (z >> 31);
    }

    /// Integer in 0..n (multiply-high, no division).
    fn below(r: *Rng, n: u64) u64 {
        return @intCast((@as(u128, r.next()) * n) >> 64);
    }
};

fn perElem(ns: u64, n: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
}

// =====================================================================================
// 1. Branches: a filter (stream compaction) with a predictable or unpredictable branch
// =====================================================================================

/// Branchy: push `x` into the output only when it passes. The store itself is conditional,
/// so the compiler cannot turn this into a conditional move: it must keep the jump.
noinline fn filterBranchy(input: []const u32, t: u32, out: []u32) usize {
    var n: usize = 0;
    for (input) |x| {
        if (x < t) {
            out[n] = x;
            n += 1;
        }
    }
    return n;
}

/// Branchless: always write, then advance the cursor by 0 or 1. `out` must be as long as
/// `input`. `@intFromBool` turns the comparison into a number: no jump to predict.
noinline fn filterBranchless(input: []const u32, t: u32, out: []u32) usize {
    var n: usize = 0;
    for (input) |x| {
        out[n] = x;
        n += @intFromBool(x < t);
    }
    return n;
}

/// The famous sorted-array loop: sum the elements below `t`. No store depends on the
/// condition, so the optimizer is free to make it branchless.
noinline fn sumIf(input: []const u32, t: u32) u64 {
    var s: u64 = 0;
    for (input) |x| {
        if (x < t) s += x;
    }
    return s;
}

/// Values in 0..100. Keeping `x < p` keeps about p% of them, in random order.
fn randomValues(gpa: Allocator, n: usize, rng: *Rng) ![]u32 {
    const v = try gpa.alloc(u32, n);
    for (v) |*x| x.* = @intCast(rng.below(100));
    return v;
}

/// A pattern of `k` random keep/drop decisions, repeated. Keeping `x < 50` keeps half.
/// Short periods are learnable by the predictor; long ones look random.
fn periodicValues(gpa: Allocator, n: usize, k: usize, rng: *Rng) ![]u32 {
    const bits = try gpa.alloc(bool, k);
    defer gpa.free(bits);
    for (bits) |*b| b.* = rng.next() & 1 == 1;
    const v = try gpa.alloc(u32, n);
    for (v, 0..) |*x, i| {
        const r: u32 = @intCast(rng.below(50));
        x.* = if (bits[i % k]) r else 50 + r;
    }
    return v;
}

const FilterFn = fn ([]const u32, u32, []u32) usize;
const FilterCtx = struct { input: []const u32, t: u32, reps: usize, out: []u32 };

/// One timed run: `reps` passes of filter `f` over the same input.
fn repeated(comptime f: FilterFn) fn (FilterCtx) usize {
    return struct {
        fn run(c: FilterCtx) usize {
            var total: usize = 0;
            for (0..c.reps) |_| {
                std.mem.doNotOptimizeAway(c.input.ptr); // memory barrier: each pass really runs
                total += f(c.input, c.t, c.out);
            }
            return total;
        }
    }.run;
}

/// Runs both filters, checks they agree, emits two BENCH lines. The reported ns are the
/// measured ns for `reps * input.len` elements times `scale` (see the Rust version).
fn filterPair(e: Env, id: []const u8, labels: [2][]const u8, input: []const u32, t: u32, reps: usize, buf: []u32, x_n: usize, scale: f64) ![2]u64 {
    var kept: [2]usize = undefined;
    var sums: [2]u64 = .{ 0, 0 };
    var med: [2]u64 = undefined;
    inline for (.{ filterBranchy, filterBranchless }, 0..) |f, v| {
        const runs = benchRuns(e.io, repeated(f), FilterCtx{ .input = input, .t = t, .reps = reps, .out = buf });
        kept[v] = f(input, t, buf);
        for (buf[0..kept[v]]) |x| sums[v] += x;
        med[v] = runs[RUNS / 2];
        var scaled: [RUNS]u64 = undefined;
        for (runs, &scaled) |r, *s| s.* = @intFromFloat(@as(f64, @floatFromInt(r)) * scale);
        try emitBench(e.out, id, labels[v], x_n, &scaled);
    }
    if (kept[0] != kept[1] or sums[0] != sums[1]) @panic("filters disagree");
    return med;
}

const SumCtx = struct { input: []const u32, reps: usize };

fn repeatedSum(c: SumCtx) u64 {
    var s: u64 = 0;
    for (0..c.reps) |_| {
        std.mem.doNotOptimizeAway(c.input.ptr); // without it LLVM computes sumIf once, not reps times
        s += sumIf(c.input, 50);
    }
    return s;
}

fn branches(e: Env, quick: bool) !void {
    const n: usize = if (quick) 1 << 12 else 1 << 16; // 16 KiB (L1) or 256 KiB (L2) of u32, same again for output
    const reps: usize = if (quick) 16 else (1 << 20) / n;
    const total = n * reps;
    const buf = try e.gpa.alloc(u32, n);
    defer e.gpa.free(buf);
    try e.out.print("== branches: filter {d} u32 values ({d} KiB), {d} passes per run\n", .{ n, n * 4 / 1024, reps });

    // (a) random values, keep p% of them
    var rng: Rng = .{ .state = 7 };
    const vals = try randomValues(e.gpa, n, &rng);
    defer e.gpa.free(vals);
    try e.out.writeAll("  keep%  branchy ns/elem  branchless ns/elem\n");
    var p: u32 = 0;
    while (p <= 100) : (p += 10) {
        var l0: [32]u8 = undefined;
        var l1: [32]u8 = undefined;
        const labels = [2][]const u8{
            try std.mem.print(&l0, "branchy {d}%", .{p}),
            try std.mem.print(&l1, "branchless {d}%", .{p}),
        };
        const m = try filterPair(e, "ch07-predict", labels, vals, p, reps, buf, total, 1.0);
        try e.out.print("  {d:>4}%  {d:>15.2}  {d:>18.2}\n", .{ p, perElem(m[0], total), perElem(m[1], total) });
    }

    // (b) the same values sorted: the branch flips once
    const sorted = try e.gpa.dupe(u32, vals);
    defer e.gpa.free(sorted);
    std.mem.sortUnstable(u32, sorted, {}, std.sort.asc(u32));
    const r = try filterPair(e, "ch07-patterns", .{ "branchy, random", "branchless, random" }, vals, 50, reps, buf, total, 1.0);
    const s = try filterPair(e, "ch07-patterns", .{ "branchy, sorted", "branchless, sorted" }, sorted, 50, reps, buf, total, 1.0);
    try e.out.print("  keep 50%: branchy random {d:.2} / sorted {d:.2} ns/elem, branchless random {d:.2} / sorted {d:.2}\n", .{
        perElem(r[0], total), perElem(s[0], total), perElem(r[1], total), perElem(s[1], total),
    });

    // (c) the sorted-array demo itself: sum the elements below 50
    var sums: [2]u64 = undefined;
    for ([2][]const u32{ vals, sorted }, [2][]const u8{ "if-sum, random", "if-sum, sorted" }, 0..) |data, label, i| {
        const runs = benchRuns(e.io, repeatedSum, SumCtx{ .input = data, .reps = reps });
        sums[i] = sumIf(data, 50);
        try emitBench(e.out, "ch07-patterns", label, total, &runs);
        try e.out.print("  {s}: {d:.2} ns/elem\n", .{ label, perElem(runs[RUNS / 2], total) });
    }
    if (sums[0] != sums[1]) @panic("sumIf: sorting changed the sum");

    // (d) period-k patterns, keep 50%: where does the predictor stop learning?
    try e.out.writeAll("  period k  branchy ns/elem  branchless ns/elem\n");
    var k: usize = 2;
    while (k <= n) : (k *= 4) {
        var krng: Rng = .{ .state = 11 + k };
        const data = try periodicValues(e.gpa, n, k, &krng);
        defer e.gpa.free(data);
        // report time per period: n = k, ns scaled by k / total
        const scale = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(total));
        const m = try filterPair(e, "ch07-period", .{ "branchy", "branchless" }, data, 50, reps, buf, k, scale);
        try e.out.print("  {d:>8}  {d:>15.2}  {d:>18.2}\n", .{ k, perElem(m[0], total), perElem(m[1], total) });
    }
    try e.out.writeAll("  checksums: branchy == branchless for every pattern (asserted)\n");
}

// =====================================================================================
// 2. Existence: where does "alive" live?
// =====================================================================================

/// Version 1: the flag is a field. 17 bytes of data, 20 with padding.
const Entity = struct { x: i32, y: i32, vx: i32, vy: i32, alive: bool };

/// Versions 2-4: the same data without the flag. 16 bytes.
const Body = struct { x: i32, y: i32, vx: i32, vy: i32 };

comptime {
    std.debug.assert(@sizeOf(Entity) == 20);
    std.debug.assert(@sizeOf(Body) == 16);
}

fn coord(rng: *Rng) i32 {
    return @as(i32, @intCast(rng.below(2001))) - 1000;
}

fn makeBody(rng: *Rng) Body {
    const x = coord(rng);
    const y = coord(rng);
    const vx = @divTrunc(coord(rng), 100);
    const vy = @divTrunc(coord(rng), 100);
    return .{ .x = x, .y = y, .vx = vx, .vy = vy };
}

/// Does entity `id` die during setup? A hash, so all three programs agree.
fn dies(id: u32, dead_pct: u64) bool {
    var r: Rng = .{ .state = id ^ 0xD1E };
    return r.next() % 100 < dead_pct;
}

noinline fn updateFlag(es: []Entity) usize {
    for (es) |*e| {
        if (e.alive) {
            e.x += e.vx;
            e.y += e.vy;
        }
    }
    return es.len;
}

const BoolCtx = struct { bodies: []Body, alive: []const bool };

noinline fn updateBoolArray(c: BoolCtx) usize {
    for (c.bodies, c.alive) |*b, a| {
        if (a) {
            b.x += b.vx;
            b.y += b.vy;
        }
    }
    return c.bodies.len;
}

const BitsCtx = struct { bodies: []Body, alive: *const std.bit_set.Dynamic };

/// Out-of-band bits: the bit set's iterator visits only the set bits.
noinline fn updateBitset(c: BitsCtx) usize {
    var it = c.alive.iterator(.{});
    while (it.next()) |i| {
        const b = &c.bodies[i];
        b.x += b.vx;
        b.y += b.vy;
    }
    return c.bodies.len;
}

/// A table per state: MultiArrayList keeps `id` and `body` in two columns.
const Row = struct { id: u32, body: Body };
const Table = std.MultiArrayList(Row);

/// Changing state is moving a row from one table to another.
fn killWhere(gpa: Allocator, alive: *Table, dead: *Table, dead_pct: u64) !void {
    var row: usize = 0;
    while (row < alive.len) {
        if (dies(alive.items(.id)[row], dead_pct)) {
            try dead.append(gpa, alive.get(row));
            alive.swapRemove(row); // the last row moves into the hole, in every column
            // do not advance: the row now holds what was the last element
        } else row += 1;
    }
}

/// Existence: no flag, no branch. Every row in this table is alive.
noinline fn updateAlive(alive: []Body) usize {
    for (alive) |*b| {
        b.x += b.vx;
        b.y += b.vy;
    }
    return alive.len;
}

fn mix(acc: u64, x: i32, y: i32) u64 {
    return acc +% @as(u64, @bitCast(@as(i64, x) * 3 + y));
}

fn existence(e: Env, n: usize, dead_pct: u64, id: []const u8) !void {
    const gpa = e.gpa;
    var rng: Rng = .{ .state = 42 };
    const bodies = try gpa.alloc(Body, n);
    defer gpa.free(bodies);
    for (bodies) |*b| b.* = makeBody(&rng);

    // 1. flag in the struct
    const ents = try gpa.alloc(Entity, n);
    defer gpa.free(ents);
    for (ents, bodies, 0..) |*en, b, i| en.* = .{ .x = b.x, .y = b.y, .vx = b.vx, .vy = b.vy, .alive = !dies(@intCast(i), dead_pct) };
    // 2. out-of-band bool array
    const b2 = try gpa.dupe(Body, bodies);
    defer gpa.free(b2);
    const alive2 = try gpa.alloc(bool, n);
    defer gpa.free(alive2);
    for (alive2, 0..) |*a, i| a.* = !dies(@intCast(i), dead_pct);
    // 3. out-of-band bit set
    const b3 = try gpa.dupe(Body, bodies);
    defer gpa.free(b3);
    var bits: std.bit_set.Dynamic = try .initEmpty(gpa, n);
    defer bits.deinit(gpa);
    for (0..n) |i| if (!dies(@intCast(i), dead_pct)) bits.set(i);
    // 4. one table per state, filled by moving rows with swap-and-pop
    var alive: Table = .empty;
    defer alive.deinit(gpa);
    var dead: Table = .empty;
    defer dead.deinit(gpa);
    try alive.ensureTotalCapacity(gpa, n);
    for (bodies, 0..) |b, i| alive.appendAssumeCapacity(.{ .id = @intCast(i), .body = b });
    try killWhere(gpa, &alive, &dead, dead_pct);

    const live = alive.len;
    try e.out.print("== existence: {d} entities, {d} alive ({d}%), Entity {d} B, Body {d} B\n", .{ n, live, 100 - dead_pct, @sizeOf(Entity), @sizeOf(Body) });
    try e.out.print("  bytes read per update: flag {d} | bool array {d} | bitset {d} + {d} | table {d}\n", .{
        n * @sizeOf(Entity), n * (@sizeOf(Body) + 1), live * @sizeOf(Body), (n + 63) / 64 * 8, live * @sizeOf(Body),
    });

    const r1 = benchRuns(e.io, updateFlag, ents);
    const r2 = benchRuns(e.io, updateBoolArray, BoolCtx{ .bodies = b2, .alive = alive2 });
    const r3 = benchRuns(e.io, updateBitset, BitsCtx{ .bodies = b3, .alive = &bits });
    const r4 = benchRuns(e.io, updateAlive, alive.items(.body));

    // 8 updates each (1 warm-up + 7 timed). Same entities alive, so the same checksum.
    var c: [4]u64 = .{ 0, 0, 0, 0 };
    for (ents) |en| if (en.alive) {
        c[0] = mix(c[0], en.x, en.y);
    };
    for (b2, alive2) |b, a| if (a) {
        c[1] = mix(c[1], b.x, b.y);
    };
    var it = bits.iterator(.{});
    while (it.next()) |i| c[2] = mix(c[2], b3[i].x, b3[i].y);
    for (alive.items(.body)) |b| c[3] = mix(c[3], b.x, b.y);
    const labels = [4][]const u8{ "flag in struct + if", "bool array + if", "bitset, set bits only", "alive table, no branch" };
    for (labels, [4][RUNS]u64{ r1, r2, r3, r4 }, c) |label, runs, sum| {
        try e.out.print("  {s:<24} {d:>8.2} ns/entity  checksum 0x{x:0>16}\n", .{ label, perElem(runs[RUNS / 2], n), sum });
        try emitBench(e.out, id, label, n, &runs);
    }
    if (c[0] != c[1] or c[1] != c[2] or c[2] != c[3]) @panic("existence: checksums differ");
    std.debug.assert(dead.len + live == n);
}

/// A dirty list: remember *which* rows changed, once each, instead of a dirty flag per row
/// that every consumer has to scan for.
const DirtyList = struct {
    seen: std.bit_set.Dynamic, // one bit per row: already listed?
    rows: std.ArrayList(u32) = .empty,

    fn mark(d: *DirtyList, gpa: Allocator, row: u32) !void {
        if (!d.seen.isSet(row)) {
            d.seen.set(row);
            try d.rows.append(gpa, row);
        }
    }

    /// Hand the dirty rows to the caller, then forget them. Cost: O(dirty), not O(rows).
    /// The returned slice is valid until the next `mark`.
    fn drain(d: *DirtyList) []const u32 {
        for (d.rows.items) |row| d.seen.unset(row);
        defer d.rows.clearRetainingCapacity();
        return d.rows.items;
    }
};

fn dirtyDemo(e: Env, n: usize) !void {
    var rng: Rng = .{ .state = 5 };
    var d: DirtyList = .{ .seen = try .initEmpty(e.gpa, n) };
    defer d.seen.deinit(e.gpa);
    defer d.rows.deinit(e.gpa);
    for (0..n / 8) |_| try d.mark(e.gpa, @intCast(rng.below(n / 4))); // repeats are common: listed once
    var count: u64 = 0;
    var sum: u64 = 0;
    for (d.drain()) |row| {
        count += 1;
        sum += row;
    }
    try e.out.print("== dirty list: {d} marks over {d} rows -> {d} distinct dirty rows, row sum {d}\n", .{ n / 8, n / 4, count, sum });
}

/// Several bools per entity, packed into one byte and kept out of band in their own column.
const Flags = packed struct(u8) { alive: bool, visible: bool, dirty: bool, selected: bool, _: u4 = 0 };

fn flagsDemo(e: Env, n: usize) !void {
    var rng: Rng = .{ .state = 9 };
    const flags = try e.gpa.alloc(Flags, n);
    defer e.gpa.free(flags);
    for (flags) |*f| f.* = @bitCast(@as(u8, @truncate(rng.next() & 0xF)));
    var count: usize = 0;
    for (flags) |f| count += @intFromBool(f.alive and f.visible and !f.dirty);
    try e.out.print("== flags: {d} entities x {d} B of flags (4 separate bools: 4 B); alive, visible and clean: {d}\n", .{ n, @sizeOf(Flags), count });
}

// =====================================================================================
// 3. Batches: the same pipeline, items pushed through in batches of size B
// =====================================================================================

/// One stage of a tiny vectorised interpreter (X100-style): a function pointer plus a
/// parameter. It processes a whole batch per call.
const Stage = struct {
    k: u64,
    runFn: *const fn (k: u64, base: u64, inp: []const u64, out: []u64) void,
};

fn gen(_: u64, base: u64, _: []const u64, out: []u64) void {
    for (out, 0..) |*o, i| o.* = (base + i) *% 0x9E37_79B9_7F4A_7C15;
}
fn mixStage(_: u64, _: u64, inp: []const u64, out: []u64) void {
    for (out, inp) |*o, x| o.* = x ^ (x >> 29);
}
fn scaleStage(k: u64, _: u64, inp: []const u64, out: []u64) void {
    for (out, inp) |*o, x| o.* = x *% k;
}

const PipeCtx = struct { stages: []const Stage, total: usize, batch: usize, a: []u64, b: []u64 };

/// Push `total` items through gen -> mix -> scale -> sum, `batch` at a time.
/// Per batch: three indirect calls and a sum. Working set: two buffers of `batch` u64.
noinline fn runPipeline(c: PipeCtx) u64 {
    var sum: u64 = 0;
    var base: usize = 0;
    const s = c.stages;
    while (base < c.total) {
        const len = @min(c.batch, c.total - base);
        const a = c.a[0..len];
        const b = c.b[0..len];
        s[0].runFn(s[0].k, base, &.{}, a);
        s[1].runFn(s[1].k, base, a, b);
        s[2].runFn(s[2].k, base, b, a);
        for (a) |x| sum +%= x;
        base += len;
    }
    return sum;
}

fn batches(e: Env, quick: bool) !void {
    const total: usize = if (quick) 1 << 16 else 1 << 22;
    const stages = [_]Stage{
        .{ .k = 0, .runFn = gen },
        .{ .k = 0, .runFn = mixStage },
        .{ .k = 0xBF58_476D_1CE4_E5B9, .runFn = scaleStage },
    };
    try e.out.print("== batches: {d} items through 3 stages; per item ns by batch size (working set = 16 B x batch)\n", .{total});
    var first: ?u64 = null;
    var batch: usize = 1;
    while (batch <= total) : (batch *= 4) {
        const a = try e.gpa.alloc(u64, batch);
        defer e.gpa.free(a);
        const b = try e.gpa.alloc(u64, batch);
        defer e.gpa.free(b);
        const ctx: PipeCtx = .{ .stages = &stages, .total = total, .batch = batch, .a = a, .b = b };
        const runs = benchRuns(e.io, runPipeline, ctx);
        const sum = runPipeline(ctx);
        if (first == null) first = sum;
        if (first.? != sum) @panic("batch size changed the result");
        // n = batch size; ns = time per batch, so ns/n is time per item
        var scaled: [RUNS]u64 = undefined;
        const scale = @as(f64, @floatFromInt(batch)) / @as(f64, @floatFromInt(total));
        for (runs, &scaled) |r, *x| x.* = @intFromFloat(@as(f64, @floatFromInt(r)) * scale);
        try emitBench(e.out, "ch07-batch", "pipeline", batch, &scaled);
        try e.out.print("  batch {d:>8} ({d:>9} B): {d:>6.2} ns/item  checksum 0x{x:0>16}\n", .{ batch, 16 * batch, perElem(runs[RUNS / 2], total), sum });
    }
}

// =====================================================================================
// 4. Lookup tables: classify bytes with comparisons or with a 256-entry table
// =====================================================================================

noinline fn countIdentBranchy(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') n += 1;
    }
    return n;
}

/// Built at compile time: 1 for [A-Za-z0-9_], else 0.
const IDENT: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (&t, 0..) |*x, c| x.* = @intFromBool(std.ascii.isAlphanumeric(c) or c == '_');
    break :blk t;
};

noinline fn countIdentLut(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| n += IDENT[c];
    return n;
}

const TextCtx = struct { text: []const u8, reps: usize };

fn repeatBranchy(c: TextCtx) usize {
    var s: usize = 0;
    for (0..c.reps) |_| {
        std.mem.doNotOptimizeAway(c.text.ptr);
        s += countIdentBranchy(c.text);
    }
    return s;
}
fn repeatLut(c: TextCtx) usize {
    var s: usize = 0;
    for (0..c.reps) |_| {
        std.mem.doNotOptimizeAway(c.text.ptr);
        s += countIdentLut(c.text);
    }
    return s;
}

fn lookup(e: Env, quick: bool) !void {
    const n: usize = if (quick) 1 << 12 else 1 << 16;
    const reps = 16;
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ (){}[];.,+-*/=<>\n\t\"'";
    var rng: Rng = .{ .state = 3 };
    const text = try e.gpa.alloc(u8, n);
    defer e.gpa.free(text);
    for (text) |*c| c.* = alphabet[rng.below(alphabet.len)];
    const ctx: TextCtx = .{ .text = text, .reps = reps };
    const r1 = benchRuns(e.io, repeatBranchy, ctx);
    const r2 = benchRuns(e.io, repeatLut, ctx);
    const c1 = countIdentBranchy(text);
    if (c1 != countIdentLut(text)) @panic("lookup: counts differ");
    const total = n * reps;
    try e.out.print("== lookup: {d} bytes, {d} identifier bytes\n", .{ n, c1 });
    for ([2][]const u8{ "comparisons", "256-entry table" }, [2][RUNS]u64{ r1, r2 }) |label, runs| {
        try e.out.print("  {s:<16} {d:.3} ns/byte\n", .{ label, perElem(runs[RUNS / 2], total) });
        try emitBench(e.out, "ch07-lut", label, total, &runs);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    const e: Env = .{ .io = io, .out = out, .gpa = init.gpa };
    try branches(e, args.quick);
    try existence(e, args.n, 50, "ch07-exist");
    try existence(e, args.n, 90, "ch07-exist-10");
    try dirtyDemo(e, args.n);
    try flagsDemo(e, args.n);
    try batches(e, args.quick);
    try lookup(e, args.quick);
    try out.flush();
}
