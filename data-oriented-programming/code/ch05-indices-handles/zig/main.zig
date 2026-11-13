// Chapter 5: Indices, Handles and Generations.
//   1. A generational pool (pool.zig) and a stale-handle demo (tests: `zig test pool.zig`).
//   2. The same binary search tree built two ways: individually allocated nodes linked by
//      pointers, and one ArrayList of nodes linked by typed u32 indices.
//   3. What the generation check costs: random lookups through plain indices vs pool handles.
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

const Allocator = std.mem.Allocator;
const Pool = @import("pool.zig").Pool;

/// Memory figures are not times: "ns" is 0 and "value" carries bytes per node.
fn emitMemory(out: *Io.Writer, label: []const u8, n: usize, bytes_per_node: f64) !void {
    try out.print("BENCH {{\"id\":\"ch05-memory\",\"label\":\"{s}\",\"lang\":\"zig\",\"n\":{d},\"ns\":0,\"value\":{d:.2},\"unit\":\"B/node\"}}\n", .{ label, n, bytes_per_node });
}

/// splitmix64: the same key sequence in all three languages.
const Rng = struct {
    s: u64,
    fn next(r: *Rng) u64 {
        r.s +%= 0x9E37_79B9_7F4A_7C15;
        var z = r.s;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        return z ^ (z >> 31);
    }
};

// ---------------------------------------------------------------------------
// Pointer tree: every node is its own allocation (gpa.create).
// ---------------------------------------------------------------------------
const PNode = struct {
    key: u32,
    left: ?*PNode = null, // 8 bytes: optional pointers use null as "none"
    right: ?*PNode = null,
};
comptime {
    std.debug.assert(@sizeOf(PNode) == 24); // 4 + 4 padding + 8 + 8, align 8
}

const PtrTree = struct {
    root: ?*PNode = null,

    /// Inserts `key` and returns the depth it landed at (the sum of depths is our build checksum).
    fn insert(t: *PtrTree, gpa: Allocator, key: u32) !u64 {
        const node = try gpa.create(PNode);
        node.* = .{ .key = key };
        var link = &t.root;
        var depth: u64 = 0;
        while (link.*) |n| : (depth += 1) link = if (key < n.key) &n.left else &n.right;
        link.* = node;
        return depth;
    }

    fn destroy(gpa: Allocator, node: ?*PNode) void {
        const n = node orelse return;
        destroy(gpa, n.left);
        destroy(gpa, n.right);
        gpa.destroy(n);
    }
};

/// In-order walk folding the keys into an order-sensitive hash.
fn ptrWalk(node: ?*const PNode, h0: u64) u64 {
    const n = node orelse return h0;
    var h = ptrWalk(n.left, h0);
    h = h *% 31 +% n.key;
    return ptrWalk(n.right, h);
}

fn ptrSpan(node: ?*const PNode, lo: *usize, hi: *usize) void {
    const n = node orelse return;
    const a = @intFromPtr(n);
    lo.* = @min(lo.*, a);
    hi.* = @max(hi.*, a + @sizeOf(PNode));
    ptrSpan(n.left, lo, hi);
    ptrSpan(n.right, lo, hi);
}

// ---------------------------------------------------------------------------
// Index tree: one ArrayList, links are typed 32-bit indices.
// ---------------------------------------------------------------------------
/// A non-exhaustive enum: a u32 that is its own type, so a NodeId cannot be passed where a
/// plain integer (or some other enum(u32) id) is expected. `none` is the null value.
const NodeId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    fn from(i: usize) NodeId {
        return @fromBackingInt(@intCast(i));
    }
    fn index(id: NodeId) usize {
        return @backingInt(id);
    }
};

const INode = struct {
    key: u32,
    left: NodeId = .none,
    right: NodeId = .none,
};
comptime {
    std.debug.assert(@sizeOf(NodeId) == 4);
    std.debug.assert(@sizeOf(INode) == 12 and @alignOf(INode) == 4);
}

const Tree = struct {
    nodes: std.ArrayList(INode) = .empty,
    root: NodeId = .none,

    fn deinit(t: *Tree, gpa: Allocator) void {
        t.nodes.deinit(gpa);
    }

    fn insert(t: *Tree, gpa: Allocator, key: u32) !u64 {
        const id: NodeId = .from(t.nodes.items.len);
        try t.nodes.append(gpa, .{ .key = key });
        if (t.root == .none) {
            t.root = id;
            return 0;
        }
        var at = t.root;
        var depth: u64 = 1;
        while (true) : (depth += 1) {
            const n = &t.nodes.items[at.index()];
            const link = if (key < n.key) &n.left else &n.right;
            if (link.* == .none) {
                link.* = id;
                return depth;
            }
            at = link.*;
        }
    }

    fn walk(t: *const Tree, node: NodeId, h0: u64) u64 {
        if (node == .none) return h0;
        const n = t.nodes.items[node.index()];
        var h = t.walk(n.left, h0);
        h = h *% 31 +% n.key;
        return t.walk(n.right, h);
    }

    /// Indices are positions, not addresses, so we can move every node and fix the links:
    /// copy the tree in pre-order (a node, then its left subtree, then its right subtree).
    fn relayoutPreorder(t: *const Tree, gpa: Allocator) !Tree {
        var out: Tree = .{};
        try out.nodes.ensureTotalCapacityPrecise(gpa, t.nodes.items.len);
        out.root = t.copyPreorder(t.root, &out);
        return out;
    }

    fn copyPreorder(t: *const Tree, node: NodeId, out: *Tree) NodeId {
        if (node == .none) return .none;
        const n = t.nodes.items[node.index()];
        const me = out.nodes.items.len;
        out.nodes.appendAssumeCapacity(.{ .key = n.key });
        const l = t.copyPreorder(n.left, out);
        const r = t.copyPreorder(n.right, out);
        out.nodes.items[me].left = l;
        out.nodes.items[me].right = r;
        return .from(me);
    }
};

// ---- benchmark bodies: one ctx struct each, so benchRuns can call f(ctx) ----
const WalkPtr = struct { root: ?*const PNode };
fn walkPtr(c: WalkPtr) u64 {
    return ptrWalk(c.root, 0);
}
fn walkIdx(t: *const Tree) u64 {
    return t.walk(t.root, 0);
}

const BuildCtx = struct { gpa: Allocator, keys: []const u32 };
fn buildPtr(c: BuildCtx) u64 {
    var t: PtrTree = .{};
    defer PtrTree.destroy(c.gpa, t.root); // freeing is part of the timing
    var depth_sum: u64 = 0;
    for (c.keys) |k| depth_sum += t.insert(c.gpa, k) catch @panic("OOM");
    return depth_sum;
}
fn buildIdx(c: BuildCtx) u64 {
    var t: Tree = .{};
    defer t.deinit(c.gpa);
    var depth_sum: u64 = 0;
    for (c.keys) |k| depth_sum += t.insert(c.gpa, k) catch @panic("OOM");
    return depth_sum;
}

const LookupPlain = struct { values: []const u64, order: []const u32 };
fn lookupPlain(c: LookupPlain) u64 {
    var s: u64 = 0;
    for (c.order) |j| s +%= c.values[j];
    return s;
}
const LookupPool = struct { pool: *Pool(u64), picked: []const Pool(u64).Handle };
fn lookupPool(c: LookupPool) u64 {
    var s: u64 = 0;
    for (c.picked) |h| s +%= if (c.pool.get(h)) |v| v.* else 0;
    return s;
}

const Monster = struct { hp: i32 };

fn poolDemo(gpa: Allocator, out: *Io.Writer) !void {
    var pool: Pool(Monster) = .empty;
    defer pool.deinit(gpa);
    const orc = try pool.insert(gpa, .{ .hp = 10 });
    const elf = try pool.insert(gpa, .{ .hp = 20 });
    _ = pool.remove(orc);
    const goblin = try pool.insert(gpa, .{ .hp = 30 }); // reuses slot 0, generation 2
    try out.print("pool: orc={d}v{d} elf={d}v{d} goblin={d}v{d} (goblin reused orc's slot)\n", .{
        orc.index, orc.generation, elf.index, elf.generation, goblin.index, goblin.generation,
    });
    try out.print("pool: get(orc) = {?}  <- stale handle detected\n", .{pool.get(orc)});
    try out.print("pool: get(goblin).hp = {d}\n", .{pool.get(goblin).?.hp});
    std.debug.assert(pool.get(orc) == null and goblin.index == orc.index and goblin.generation == orc.generation + 1);
    try out.print("pool: @sizeOf(Handle) = {d} B, live = {d}, slots = {d}\n", .{ @sizeOf(Pool(Monster).Handle), pool.len, pool.slotCount() });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    const n = args.n;
    try poolDemo(gpa, out);

    // ---- build both trees from the same keys ----
    const keys = try gpa.alloc(u32, n);
    defer gpa.free(keys);
    var rng: Rng = .{ .s = 42 };
    for (keys) |*k| k.* = @truncate(rng.next() >> 32);

    var ptree: PtrTree = .{};
    defer PtrTree.destroy(gpa, ptree.root);
    var itree: Tree = .{};
    defer itree.deinit(gpa);
    var pdepth: u64 = 0;
    var idepth: u64 = 0;
    for (keys) |k| pdepth += try ptree.insert(gpa, k);
    for (keys) |k| idepth += try itree.insert(gpa, k);
    var dtree = try itree.relayoutPreorder(gpa);
    defer dtree.deinit(gpa);
    if (pdepth != idepth) return error.ShapeMismatch;

    var lo: usize = std.math.maxInt(usize);
    var hi: usize = 0;
    ptrSpan(ptree.root, &lo, &hi);
    const nf: f64 = @floatFromInt(n);
    const span_per_node = @as(f64, @floatFromInt(hi - lo)) / nf;
    const cap_per_node = @as(f64, @floatFromInt(itree.nodes.capacity * @sizeOf(INode))) / nf;
    try out.print("tree: n={d} average depth {d:.1}; pointer node {d} B (heap span {d:.1} B/node), index node {d} B (ArrayList capacity {d:.1} B/node)\n", .{
        n, @as(f64, @floatFromInt(pdepth)) / nf, @sizeOf(PNode), span_per_node, @sizeOf(INode), cap_per_node,
    });
    try emitMemory(out, "pointers: node size", n, @sizeOf(PNode));
    try emitMemory(out, "pointers: heap span", n, span_per_node);
    try emitMemory(out, "indices: node size", n, @sizeOf(INode));
    try emitMemory(out, "indices: array capacity", n, cap_per_node);

    // ---- traversal: the same in-order walk, three memory layouts ----
    const p = benchRuns(io, walkPtr, WalkPtr{ .root = ptree.root });
    const i = benchRuns(io, walkIdx, @as(*const Tree, &itree));
    const d = benchRuns(io, walkIdx, @as(*const Tree, &dtree));
    const hp = ptrWalk(ptree.root, 0);
    const hi_ = itree.walk(itree.root, 0);
    const hd = dtree.walk(dtree.root, 0);
    try out.print("traverse checksum: pointers 0x{x:0>16}  indices 0x{x:0>16}  indices/DFS 0x{x:0>16}\n", .{ hp, hi_, hd });
    if (hp != hi_ or hi_ != hd) return error.ChecksumMismatch;
    const walks = [_]struct { []const u8, [RUNS]u64 }{ .{ "pointer nodes", p }, .{ "u32 indices", i }, .{ "u32 indices, DFS order", d } };
    for (walks) |w| {
        const med = w[1][RUNS / 2];
        try out.print("traverse {s:<24} {d:>10} ns  ({d:.2} ns/node)\n", .{ w[0], med, @as(f64, @floatFromInt(med)) / nf });
        try emitBench(out, "ch05-traverse", w[0], n, &w[1]);
    }

    // ---- build + free: n allocations vs one growing ArrayList ----
    const bctx: BuildCtx = .{ .gpa = gpa, .keys = keys };
    const pb = benchRuns(io, buildPtr, bctx);
    const ib = benchRuns(io, buildIdx, bctx);
    try out.print("build+free checksum (sum of depths): pointers {d}  indices {d}\n", .{ pdepth, idepth });
    const builds = [_]struct { []const u8, [RUNS]u64 }{ .{ "pointer nodes", pb }, .{ "u32 indices", ib } };
    for (builds) |b| {
        try out.print("build+free {s:<22} {d:>10} ns\n", .{ b[0], b[1][RUNS / 2] });
        try emitBench(out, "ch05-build", b[0], n, &b[1]);
    }

    // ---- what does the generation check cost? n random lookups ----
    var pool: Pool(u64) = .empty;
    defer pool.deinit(gpa);
    const plain = try gpa.alloc(u64, n);
    defer gpa.free(plain);
    const handles = try gpa.alloc(Pool(u64).Handle, n);
    defer gpa.free(handles);
    for (plain, handles, 0..) |*v, *h, j| {
        v.* = j;
        h.* = try pool.insert(gpa, j);
    }
    const order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    const picked = try gpa.alloc(Pool(u64).Handle, n);
    defer gpa.free(picked);
    var r2: Rng = .{ .s = 7 };
    for (order, picked) |*o, *h| {
        o.* = @intCast(r2.next() % n);
        h.* = handles[o.*];
    }
    const lctx: LookupPlain = .{ .values = plain, .order = order };
    const pctx: LookupPool = .{ .pool = &pool, .picked = picked };
    const lv = benchRuns(io, lookupPlain, lctx);
    const lp = benchRuns(io, lookupPool, pctx);
    const cv = lookupPlain(lctx);
    const cp = lookupPool(pctx);
    try out.print("lookup checksum: plain {d}  pool {d}\n", .{ cv, cp });
    if (cv != cp) return error.ChecksumMismatch;
    const looks = [_]struct { []const u8, [RUNS]u64 }{ .{ "array[index]", lv }, .{ "pool.get(handle)", lp } };
    for (looks) |l| {
        const med = l[1][RUNS / 2];
        try out.print("lookup {s:<22} {d:>10} ns  ({d:.2} ns/lookup)\n", .{ l[0], med, @as(f64, @floatFromInt(med)) / nf });
        try emitBench(out, "ch05-lookup", l[0], n, &l[1]);
    }
    try out.flush();
}
