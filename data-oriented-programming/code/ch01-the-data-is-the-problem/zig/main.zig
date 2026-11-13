//! Chapter 1: the shapes benchmark (after Casey Muratori, "Clean" Code, Horrible Performance, 2023).
//!
//! The same job four ways: compute the area of every shape into an output array.
//!   1. dynamic dispatch    `[]Shape`, where Shape = { ptr, vtable } (the std.mem.Allocator pattern)
//!   2. tagged union        `[]ShapeUnion`, a `switch` per shape (`inline else`), no pointers
//!   3. coefficient table   `[]FlatShape`, `coef[kind] * width * height`, no branch
//!   4. per-kind arrays     one array per kind and one loop per array, no tag at all (preview of Chapter 7)
//! plus two controls: versions 1 and 2 again on the same shapes sorted by kind, so every branch predicts.
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
const pi: f32 = std.math.pi;

// ---- the shapes: plain structs, shared by every version ----
const Square = struct {
    side: f32,
    fn area(s: Square) f32 {
        return s.side * s.side;
    }
};
const Rectangle = struct {
    width: f32,
    height: f32,
    fn area(r: Rectangle) f32 {
        return r.width * r.height;
    }
};
const Triangle = struct {
    base: f32,
    height: f32,
    fn area(t: Triangle) f32 {
        return 0.5 * t.base * t.height;
    }
};
const Circle = struct {
    radius: f32,
    fn area(c: Circle) f32 {
        return pi * c.radius * c.radius;
    }
};

// ---- 1. dynamic dispatch: a type-erased pointer plus a pointer to a table of function pointers ----
const Shape = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        area: *const fn (ptr: *anyopaque) f32,
        destroy: *const fn (ptr: *anyopaque, gpa: Allocator) void,
    };

    fn area(s: Shape) f32 {
        return s.vtable.area(s.ptr); // load fn pointer from the vtable, indirect call
    }

    /// Heap-allocates `value` and returns a Shape whose vtable is generated at compile time for T.
    fn create(gpa: Allocator, value: anytype) !Shape {
        const T = @TypeOf(value);
        const gen = struct {
            fn areaOf(ptr: *anyopaque) f32 {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.area();
            }
            fn destroyIt(ptr: *anyopaque, a: Allocator) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                a.destroy(self);
            }
            const vtable: VTable = .{ .area = areaOf, .destroy = destroyIt };
        };
        const p = try gpa.create(T);
        p.* = value;
        return .{ .ptr = p, .vtable = &gen.vtable };
    }
};

fn areasDyn(shapes: []const Shape, out: []f32) void {
    for (shapes, out) |s, *o| o.* = s.area();
}

// ---- 2. tagged union: the same structs inside a union(enum), dispatched by `switch` ----
const ShapeUnion = union(enum) {
    square: Square,
    rectangle: Rectangle,
    triangle: Triangle,
    circle: Circle,

    /// `inline else` stamps out one prong per variant, each calling that variant's own `area`.
    fn area(s: ShapeUnion) f32 {
        return switch (s) {
            inline else => |v| v.area(),
        };
    }
};

fn areasSwitch(shapes: []const ShapeUnion, out: []f32) void {
    for (shapes, out) |s, *o| o.* = s.area();
}

// ---- 3. coefficient table: notice that every area is c * width * height ----
const Kind = enum(u8) { square, rectangle, triangle, circle };

/// Squares and circles store their one dimension twice (height = width), as in Muratori's version.
const FlatShape = struct { kind: Kind, width: f32, height: f32 };

const coef = [4]f32{ 1.0, 1.0, 0.5, pi };

fn areasTable(shapes: []const FlatShape, out: []f32) void {
    for (shapes, out) |s, *o| o.* = coef[@backingInt(s.kind)] * s.width * s.height;
}

// ---- 4. per-kind arrays: the kind is which array a shape is in ----
const ShapesByKind = struct {
    squares: std.ArrayList(f32) = .empty, // side
    rectangles: std.ArrayList([2]f32) = .empty, // width, height
    triangles: std.ArrayList([2]f32) = .empty, // base, height
    circles: std.ArrayList(f32) = .empty, // radius

    fn deinit(self: *ShapesByKind, gpa: Allocator) void {
        self.squares.deinit(gpa);
        self.rectangles.deinit(gpa);
        self.triangles.deinit(gpa);
        self.circles.deinit(gpa);
    }
};

/// Four tight loops with no dispatch. `out` is filled kind by kind, so its order differs from the other versions.
fn areasByKind(s: *const ShapesByKind, out: []f32) void {
    var i: usize = 0;
    for (s.squares.items, out[i..][0..s.squares.items.len]) |side, *o| o.* = side * side;
    i += s.squares.items.len;
    for (s.rectangles.items, out[i..][0..s.rectangles.items.len]) |r, *o| o.* = r[0] * r[1];
    i += s.rectangles.items.len;
    for (s.triangles.items, out[i..][0..s.triangles.items.len]) |t, *o| o.* = 0.5 * t[0] * t[1];
    i += s.triangles.items.len;
    for (s.circles.items, out[i..][0..s.circles.items.len]) |r, *o| o.* = pi * r * r;
}

// ---- data: the same seeded generator in Rust, Zig and Odin, so all three see the same shapes ----
const SplitMix64 = struct {
    state: u64,

    fn next(r: *SplitMix64) u64 {
        r.state +%= 0x9E37_79B9_7F4A_7C15;
        var z = r.state;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        return z ^ (z >> 31);
    }
    /// A dimension in [0.5, 16.5) with 12 fractional bits, so it is exact in f32.
    fn dim(r: *SplitMix64) f32 {
        return @as(f32, @floatFromInt(r.next() >> 48)) / 4096.0 + 0.5;
    }
};

/// n shapes in random kind order: (kind, width, height) with height == width for squares and circles.
fn generate(gpa: Allocator, n: usize) ![]FlatShape {
    const flat = try gpa.alloc(FlatShape, n);
    var rng: SplitMix64 = .{ .state = 2023 };
    for (flat) |*s| {
        const kind: Kind = @fromBackingInt(@as(u8, @intCast(rng.next() >> 62)));
        const width = rng.dim();
        const height = if (kind == .square or kind == .circle) width else rng.dim();
        s.* = .{ .kind = kind, .width = width, .height = height };
    }
    return flat;
}

fn toBoxed(gpa: Allocator, flat: []const FlatShape) ![]Shape {
    const shapes = try gpa.alloc(Shape, flat.len);
    for (flat, shapes) |s, *d| d.* = switch (s.kind) {
        .square => try Shape.create(gpa, Square{ .side = s.width }),
        .rectangle => try Shape.create(gpa, Rectangle{ .width = s.width, .height = s.height }),
        .triangle => try Shape.create(gpa, Triangle{ .base = s.width, .height = s.height }),
        .circle => try Shape.create(gpa, Circle{ .radius = s.width }),
    };
    return shapes;
}

fn freeBoxed(gpa: Allocator, shapes: []Shape) void {
    for (shapes) |s| s.vtable.destroy(s.ptr, gpa);
    gpa.free(shapes);
}

fn toUnion(gpa: Allocator, flat: []const FlatShape) ![]ShapeUnion {
    const shapes = try gpa.alloc(ShapeUnion, flat.len);
    for (flat, shapes) |s, *d| d.* = switch (s.kind) {
        .square => .{ .square = .{ .side = s.width } },
        .rectangle => .{ .rectangle = .{ .width = s.width, .height = s.height } },
        .triangle => .{ .triangle = .{ .base = s.width, .height = s.height } },
        .circle => .{ .circle = .{ .radius = s.width } },
    };
    return shapes;
}

/// Order-independent checksum: wrapping sum of the f32 bit patterns. Equal iff every version produced the
/// same multiset of areas, bit for bit.
fn checksum(out: []const f32) u64 {
    var acc: u64 = 0;
    for (out) |a| acc +%= @as(u32, @bitCast(a));
    return acc;
}

// Contexts for benchRuns: each returns the last area so the call has a result to keep alive.
const DynCtx = struct { shapes: []const Shape, out: []f32 };
fn runDyn(c: DynCtx) f32 {
    areasDyn(c.shapes, c.out);
    return c.out[c.out.len - 1];
}
const UnionCtx = struct { shapes: []const ShapeUnion, out: []f32 };
fn runSwitch(c: UnionCtx) f32 {
    areasSwitch(c.shapes, c.out);
    return c.out[c.out.len - 1];
}
const FlatCtx = struct { shapes: []const FlatShape, out: []f32 };
fn runTable(c: FlatCtx) f32 {
    areasTable(c.shapes, c.out);
    return c.out[c.out.len - 1];
}
const KindCtx = struct { shapes: *const ShapesByKind, out: []f32 };
fn runByKind(c: KindCtx) f32 {
    areasByKind(c.shapes, c.out);
    return c.out[c.out.len - 1];
}

fn kindLess(_: void, a: FlatShape, b: FlatShape) bool {
    return @backingInt(a.kind) < @backingInt(b.kind);
}

const Report = struct {
    out: *Io.Writer,
    n: usize,
    sums: [6]u64 = undefined,
    count: usize = 0,

    fn add(r: *Report, label: []const u8, runs: [RUNS]u64, areas: []const f32) !void {
        const sum = checksum(areas);
        var total: f64 = 0;
        for (areas) |a| total += a;
        const ns = @as(f64, @floatFromInt(runs[RUNS / 2])) / @as(f64, @floatFromInt(r.n));
        try r.out.print("{s:<25} {d:7.3} ns/shape   checksum 0x{x:0>16}   total area {d:.1}\n", .{ label, ns, sum, total });
        try emitBench(r.out, "ch01-shapes", label, r.n, &runs);
        r.sums[r.count] = sum;
        r.count += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;

    const args = try parseArgs(init);
    const n = args.n;
    const flat = try generate(gpa, n);
    defer gpa.free(flat);

    const boxed = try toBoxed(gpa, flat);
    defer freeBoxed(gpa, boxed);
    const unions = try toUnion(gpa, flat);
    defer gpa.free(unions);
    var by_kind: ShapesByKind = .{};
    defer by_kind.deinit(gpa);
    for (flat) |s| switch (s.kind) {
        .square => try by_kind.squares.append(gpa, s.width),
        .rectangle => try by_kind.rectangles.append(gpa, .{ s.width, s.height }),
        .triangle => try by_kind.triangles.append(gpa, .{ s.width, s.height }),
        .circle => try by_kind.circles.append(gpa, s.width),
    };

    // Machine-independent facts: how many bytes each representation reads per shape.
    const gaps = try gpa.alloc(usize, n -| 1);
    defer gpa.free(gaps);
    for (gaps, 0..) |*g, i| {
        const a = @intFromPtr(boxed[i].ptr);
        const b = @intFromPtr(boxed[i + 1].ptr);
        g.* = @max(a, b) - @min(a, b);
    }
    std.mem.sort(usize, gaps, {}, std.sort.asc(usize));
    const kind_bytes = 4 * (by_kind.squares.items.len + by_kind.circles.items.len) +
        8 * (by_kind.rectangles.items.len + by_kind.triangles.items.len);
    try out.print("{d} shapes: {d} squares, {d} rectangles, {d} triangles, {d} circles (random order)\n", .{
        n, by_kind.squares.items.len, by_kind.rectangles.items.len, by_kind.triangles.items.len, by_kind.circles.items.len,
    });
    try out.print("bytes per shape read: Shape {d} + heap object (median {d} B apart) | ShapeUnion {d} | FlatShape {d} | per-kind {d:.1} avg\n", .{
        @sizeOf(Shape),                                                   if (gaps.len == 0) 0 else gaps[gaps.len / 2], @sizeOf(ShapeUnion), @sizeOf(FlatShape),
        @as(f64, @floatFromInt(kind_bytes)) / @as(f64, @floatFromInt(n)),
    });

    const areas = try gpa.alloc(f32, n);
    defer gpa.free(areas);
    var rep: Report = .{ .out = out, .n = n };

    try rep.add("dynamic dispatch", benchRuns(io, runDyn, DynCtx{ .shapes = boxed, .out = areas }), areas);
    try rep.add("tagged union", benchRuns(io, runSwitch, UnionCtx{ .shapes = unions, .out = areas }), areas);
    try rep.add("coefficient table", benchRuns(io, runTable, FlatCtx{ .shapes = flat, .out = areas }), areas);
    try rep.add("per-kind arrays", benchRuns(io, runByKind, KindCtx{ .shapes = &by_kind, .out = areas }), areas);

    // Controls: the same shapes sorted by kind (stable), so every branch and call predicts well.
    // The objects are allocated in sorted order, so the heap is walked in order just like above.
    const sorted = try gpa.dupe(FlatShape, flat);
    defer gpa.free(sorted);
    std.mem.sort(FlatShape, sorted, {}, kindLess);
    const boxed_sorted = try toBoxed(gpa, sorted);
    defer freeBoxed(gpa, boxed_sorted);
    const unions_sorted = try toUnion(gpa, sorted);
    defer gpa.free(unions_sorted);
    try rep.add("dynamic dispatch, sorted", benchRuns(io, runDyn, DynCtx{ .shapes = boxed_sorted, .out = areas }), areas);
    try rep.add("tagged union, sorted", benchRuns(io, runSwitch, UnionCtx{ .shapes = unions_sorted, .out = areas }), areas);

    for (rep.sums[1..rep.count]) |s| if (s != rep.sums[0]) {
        try out.flush();
        std.debug.panic("versions disagree: {any}", .{rep.sums[0..rep.count]});
    };
    try out.print("checksums: all {d} runs match\n", .{rep.count});
    try out.flush();
}
