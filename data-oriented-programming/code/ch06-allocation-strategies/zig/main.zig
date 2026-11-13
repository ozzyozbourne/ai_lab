// Chapter 6: allocation strategies. Same workloads as ../rust/src/main.rs and ../odin/main.odin.
//   1. frame: every tick builds many short-lived byte strings, uses them, throws them away.
//      heap per object (init.gpa) vs a frame arena (ArenaAllocator, reset once per tick),
//      plus a FixedBufferAllocator over one preallocated buffer.
//   2. pool: projectiles with individual lifetimes. gpa.create per object vs std.heap.MemoryPool.
//   3. the arena + growing array pitfall, and 4. reserve-then-commit, as printed counters.
// Run: zig run -O fast main.zig -- [N] [--quick]

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

const TICKS = 16; // frames per benchmark run
const MAX_MSG = 71; // longest message in bytes
const POOL_TICKS = 64;
const MAX_TTL = 16;

/// A splitmix64-style mix of (tick, i). Every language computes the same numbers.
fn mix(tick_index: u64, i: u64) u64 {
    var h = (i *% 0x9E37_79B9_7F4A_7C15) ^ (tick_index *% 0xBF58_476D_1CE4_E5B9);
    h ^= h >> 31;
    h *%= 0x94D0_49BB_1331_11EB;
    return h ^ (h >> 29);
}

// ---- 1. frame workload ----

/// One frame: build `count` short-lived messages (8..=71 bytes), use them, drop them.
/// The same code runs on any allocator. With an arena there is nothing to free one by one.
fn tick(alloc: Allocator, t: u64, count: usize, comptime free_each: bool) Allocator.Error!u64 {
    var msgs: std.ArrayList([]u8) = try .initCapacity(alloc, count);
    defer if (free_each) msgs.deinit(alloc);
    for (0..count) |i| {
        const h = mix(t, i);
        const m = try alloc.alloc(u8, 8 + @as(usize, @intCast(h >> 58)));
        for (m, 0..) |*b, j| b.* = @as(u8, @truncate(h)) +% @as(u8, @truncate(j));
        msgs.appendAssumeCapacity(m);
    }
    var sum: u64 = 0;
    for (msgs.items) |m| {
        var bytes: u64 = 0;
        for (m) |b| bytes += b;
        sum +%= bytes ^ (@as(u64, m.len) << 32);
    }
    if (free_each) for (msgs.items) |m| alloc.free(m);
    return sum;
}

const Frame = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    fba: *std.heap.FixedBufferAllocator,
    count: usize,
};

fn framesHeap(f: Frame) u64 {
    var acc: u64 = 0;
    for (0..TICKS) |t| acc +%= tick(f.gpa, t, f.count, true) catch @panic("out of memory");
    return acc;
}

fn framesArena(f: Frame) u64 {
    var acc: u64 = 0;
    for (0..TICKS) |t| {
        acc +%= tick(f.arena.allocator(), t, f.count, false) catch @panic("out of memory");
        _ = f.arena.reset(.retain_capacity); // keep the block, drop its contents
    }
    return acc;
}

fn framesFixed(f: Frame) u64 {
    var acc: u64 = 0;
    for (0..TICKS) |t| {
        acc +%= tick(f.fba.allocator(), t, f.count, false) catch @panic("out of memory");
        f.fba.reset(); // end_index = 0
    }
    return acc;
}

// ---- 2. pool workload ----

const Projectile = struct { x: i32, y: i32, vx: i32, vy: i32, ttl: u32, id: u32 };
comptime {
    std.debug.assert(@sizeOf(Projectile) == 24);
}

fn score(p: *const Projectile) u64 {
    return @as(u64, @as(u32, @bitCast(p.x))) ^ (@as(u64, @as(u32, @bitCast(p.y))) << 20) ^ (@as(u64, p.id) << 40);
}

/// Where projectiles come from: one `create`/`destroy` per object on the general-purpose heap...
const HeapSource = struct {
    gpa: Allocator,
    fn create(s: HeapSource) !*Projectile {
        return s.gpa.create(Projectile);
    }
    fn destroy(s: HeapSource, p: *Projectile) void {
        s.gpa.destroy(p);
    }
};

/// ...or a MemoryPool: a free list threaded through equal-size chunks.
const PoolSource = struct {
    pool: *std.heap.MemoryPool(Projectile),
    gpa: Allocator, // only used if the pool has to grow
    fn create(s: PoolSource) !*Projectile {
        return s.pool.create(s.gpa);
    }
    fn destroy(s: PoolSource, p: *Projectile) void {
        s.pool.destroy(@alignCast(p)); // pool chunks are 8-aligned (they double as free-list nodes)
    }
};

const Sim = struct { gpa: Allocator, pool: *std.heap.MemoryPool(Projectile), spawn: usize };

/// Spawn `spawn` projectiles per tick, move them, despawn each when its ttl runs out.
/// Every projectile is its own allocation with its own lifetime.
fn simulate(src: anytype, gpa: Allocator, spawn: usize) !u64 {
    var live: std.ArrayList(*Projectile) = .empty;
    defer live.deinit(gpa);
    var sum: u64 = 0;
    for (0..POOL_TICKS) |t| {
        for (0..spawn) |i| {
            const h = mix(t + 1000, i);
            const p = try src.create();
            p.* = .{
                .x = @intCast(h & 0xFFFF),
                .y = @intCast((h >> 16) & 0xFFFF),
                .vx = @as(i32, @intCast((h >> 32) & 15)) - 8,
                .vy = @as(i32, @intCast((h >> 36) & 15)) - 8,
                .ttl = 1 + @as(u32, @intCast((h >> 40) % MAX_TTL)),
                .id = @truncate(t * spawn + i),
            };
            try live.append(gpa, p);
        }
        var k: usize = 0;
        while (k < live.items.len) {
            const p = live.items[k];
            p.x += p.vx;
            p.y += p.vy;
            p.ttl -= 1;
            if (p.ttl == 0) {
                sum +%= score(p);
                src.destroy(p); // gpa.free, or a push onto the pool's free list
                _ = live.swapRemove(k);
            } else k += 1;
        }
    }
    for (live.items) |p| {
        sum +%= score(p);
        src.destroy(p);
    }
    return sum;
}

fn simHeap(s: Sim) u64 {
    const src: HeapSource = .{ .gpa = s.gpa };
    return simulate(src, s.gpa, s.spawn) catch @panic("out of memory");
}

fn simPool(s: Sim) u64 {
    const src: PoolSource = .{ .pool = s.pool, .gpa = s.gpa };
    return simulate(src, s.gpa, s.spawn) catch @panic("out of memory");
}

// ---- 4. reserve, then commit ----

/// Resident set size in bytes, from /proc/self/statm (Linux only; 0 if unreadable).
fn rssBytes(io: Io) usize {
    var buf: [128]u8 = undefined;
    const statm = std.Io.Dir.cwd().readFile(io, "/proc/self/statm", &buf) catch return 0;
    var it = std.mem.tokenizeScalar(u8, statm, ' ');
    _ = it.next();
    const pages = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
    return pages * 4096;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa; // smp_allocator in -O fast, SafeAllocator (leak-checking) in -O debug/safe
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    const per_tick = @max(args.n / TICKS, 1);
    const n = per_tick * TICKS;
    try out.print("ch06 frame workload: {d} ticks x {d} messages (8..={d} B), quick={}\n", .{ TICKS, per_tick, MAX_MSG, args.quick });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Worst case per tick: one slice header and MAX_MSG bytes per message (TigerStyle: size it once).
    // It lives as long as the program, so it comes from init.arena and is never freed by hand.
    const fixed = try init.arena.allocator().alloc(u8, per_tick * (@sizeOf([]u8) + MAX_MSG) + 64);
    var fba: std.heap.FixedBufferAllocator = .init(fixed);
    const frame: Frame = .{ .gpa = gpa, .arena = &arena, .fba = &fba, .count = per_tick };

    std.mem.doNotOptimizeAway(try tick(fba.allocator(), 0, per_tick, false));
    try out.print("  one tick: {d} allocations, fixed-buffer high-water mark {d} of {d} B ({d:.1} B/message)\n", .{
        per_tick + 1, fba.end_index, fixed.len, @as(f64, @floatFromInt(fba.end_index)) / @as(f64, @floatFromInt(per_tick)),
    });
    fba.reset();

    const heap_sum = framesHeap(frame);
    const arena_sum = framesArena(frame);
    const fixed_sum = framesFixed(frame);
    try out.print("  checksum heap=0x{x:0>16} arena=0x{x:0>16} fixed=0x{x:0>16} match={}\n", .{ heap_sum, arena_sum, fixed_sum, heap_sum == arena_sum and arena_sum == fixed_sum });
    if (heap_sum != arena_sum or arena_sum != fixed_sum) return error.ChecksumMismatch;
    try out.print("  arena capacity after reset(.retain_capacity): {d} B\n", .{arena.queryCapacity()});

    const heap = benchRuns(io, framesHeap, frame);
    const arena_t = benchRuns(io, framesArena, frame);
    const fixed_t = benchRuns(io, framesFixed, frame);
    const nf: f64 = @floatFromInt(n);
    const h_ns = @as(f64, @floatFromInt(heap[RUNS / 2])) / nf;
    const a_ns = @as(f64, @floatFromInt(arena_t[RUNS / 2])) / nf;
    const f_ns = @as(f64, @floatFromInt(fixed_t[RUNS / 2])) / nf;
    try out.print("  heap per object: {d:.1} ns/message\n", .{h_ns});
    try out.print("  frame arena:     {d:.1} ns/message ({d:.1}x)\n", .{ a_ns, h_ns / a_ns });
    try out.print("  fixed buffer:    {d:.1} ns/message ({d:.1}x)\n", .{ f_ns, h_ns / f_ns });
    try emitBench(out, "ch06-frame", "heap per object", n, &heap);
    try emitBench(out, "ch06-frame", "frame arena", n, &arena_t);
    try emitBench(out, "ch06-frame", "FixedBufferAllocator", n, &fixed_t);

    // ---- 2. pool ----
    const spawn = @max(args.n / POOL_TICKS / 4, 1);
    const total = spawn * POOL_TICKS;
    var pool: std.heap.MemoryPool(Projectile) = try .initCapacity(gpa, spawn * MAX_TTL);
    defer pool.deinit(gpa);
    try out.print("ch06 pool workload: {d} ticks x {d} spawns, 24 B projectiles, ttl 1..={d}\n", .{ POOL_TICKS, spawn, MAX_TTL });
    const sim: Sim = .{ .gpa = gpa, .pool = &pool, .spawn = spawn };
    const heap_p = simHeap(sim);
    const pool_p = simPool(sim);
    try out.print("  checksum heap=0x{x:0>16} pool=0x{x:0>16} match={}\n", .{ heap_p, pool_p, heap_p == pool_p });
    if (heap_p != pool_p) return error.ChecksumMismatch;
    const ph = benchRuns(io, simHeap, sim);
    const pp = benchRuns(io, simPool, sim);
    const tf: f64 = @floatFromInt(total);
    const ph_ns = @as(f64, @floatFromInt(ph[RUNS / 2])) / tf;
    const pp_ns = @as(f64, @floatFromInt(pp[RUNS / 2])) / tf;
    try out.print("  create per object: {d:.1} ns/projectile\n", .{ph_ns});
    try out.print("  MemoryPool:        {d:.1} ns/projectile ({d:.1}x)\n", .{ pp_ns, ph_ns / pp_ns });
    try emitBench(out, "ch06-pool", "heap per object", total, &ph);
    try emitBench(out, "ch06-pool", "pool", total, &pp);

    // ---- 3. pitfall: growing arrays inside an arena leave dead copies behind ----
    {
        var scratch_buf: [1 << 16]u8 = undefined;
        var scratch: std.heap.FixedBufferAllocator = .init(&scratch_buf);
        const sa = scratch.allocator();
        var a: std.ArrayList(u32) = .empty;
        var b: std.ArrayList(u32) = .empty;
        for (0..1000) |i| {
            try a.append(sa, @intCast(i)); // the two lists take turns at the end of the buffer, so
            try b.append(sa, @intCast(i)); // neither can grow in place: each regrow copies and abandons
        }
        const live = (a.capacity + b.capacity) * 4;
        try out.print("arena + growing ArrayList: 2 x 1000 u32, live {d} B, arena used {d} B ({d:.1}x)\n", .{
            live, scratch.end_index, @as(f64, @floatFromInt(scratch.end_index)) / @as(f64, @floatFromInt(live)),
        });
    }

    // ---- 4. reserve, then commit ----
    // Reserve 1 GiB of address space. MAP_NORESERVE: no RAM or swap is set aside; the kernel backs
    // each 4 KiB page only when it is first written.
    const before = rssBytes(io);
    const region = try std.posix.mmap(null, 1 << 30, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
    defer std.posix.munmap(region);
    const reserved = rssBytes(io);
    var big: std.heap.FixedBufferAllocator = .init(region);
    const used = try big.allocator().alloc(u8, 16 << 20);
    var off: usize = 0;
    while (off < used.len) : (off += 4096) used[off] = 1;
    std.mem.doNotOptimizeAway(used.ptr);
    const touched = rssBytes(io);
    const mib = 1024.0 * 1024.0;
    try out.print("1 GiB mmap reservation: RSS +{d:.1} MiB after mmap, +{d:.1} MiB after touching 16 MiB\n", .{
        @as(f64, @floatFromInt(reserved -| before)) / mib, @as(f64, @floatFromInt(touched -| before)) / mib,
    });
    try out.flush();
}
