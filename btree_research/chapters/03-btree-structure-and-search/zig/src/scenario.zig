//! The fixed scenario printed by `zig build run` (and by `cargo run`, byte
//! for byte). The chapter README quotes this output and the visualization
//! checks its JavaScript model against it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tree_mod = @import("tree.zig");
const pool_mod = @import("base_pool.zig");
const trace = @import("trace.zig");
const broken = @import("broken.zig");
const height = @import("height.zig");
const redblack = @import("redblack.zig");
const BumpAllocator = @import("bump.zig").BumpAllocator;
const SplitMix64 = @import("prng.zig").SplitMix64;

const Tree4 = tree_mod.Tree4;
const Writer = std.Io.Writer;

/// Part 2: one lookup per interesting case.
pub const lookups = [_]u64{ 10, 17, 1, 8, 31 };
/// Part 7: the orders checked against the oracle.
pub const oracle_orders = .{ 3, 4, 5, 8 };
pub const oracle_key_space = 2000;
pub const oracle_seed = 3;

pub fn run(gpa: Allocator, w: *Writer) !void {
    try partsOneToThree(gpa, w);

    // Everything below lives in one arena: many small trees and work lists,
    // none of which is ever freed on its own.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    try brokenTrees(&arena_state, w);
    try heights(arena_state.allocator(), w);
    try redBlack(arena_state.allocator(), w);
    try oracleCheck(&arena_state, w);
}

/// Parts 1 to 3 use the hand-written bump allocator as the node store.
fn partsOneToThree(gpa: Allocator, w: *Writer) !void {
    var bump_state: BumpAllocator = .init(gpa);
    defer bump_state.deinit(); // the only free: no walk over the tree
    var t: Tree4 = .empty;
    try tree_mod.canonical(&t, bump_state.allocator());

    try w.writeAll("== 1. The canonical tree, built by hand (M = 4: 1 to 3 keys per node) ==\n");
    try t.render(w, "  ");
    try printShape(w, t.shape());
    try t.validate();
    try w.writeAll("validate: ok\n");
    try w.print("node storage: {d} nodes created, {d} freed one by one, all released together\n", .{
        t.pool.usage.created, t.pool.usage.destroyed,
    });

    try w.writeAll("\n== 2. Search reads one node per level ==\n");
    for (lookups) |key| _ = try trace.explainGet(4, t.root, key, w);

    try w.writeAll("\n== 3. In-order traversal visits the keys in ascending order ==\n");
    var printer: KeyPrinter = .{ .w = w };
    t.inOrder(&printer);
    try printer.finish();
}

/// Visitor for `inOrder`. A visitor cannot return an error, so it remembers
/// the first one and `finish` reports it.
const KeyPrinter = struct {
    w: *Writer,
    count: usize = 0,
    failure: ?Writer.Error = null,

    pub fn visit(self: *KeyPrinter, key: u64, value: u64) void {
        std.debug.assert(value == tree_mod.valueOf(key));
        if (self.failure != null) return;
        if (self.count > 0) self.w.writeByte(' ') catch |e| {
            self.failure = e;
        };
        self.w.print("{d}", .{key}) catch |e| {
            self.failure = e;
        };
        self.count += 1;
    }

    fn finish(self: *KeyPrinter) Writer.Error!void {
        if (self.failure) |e| return e;
        try self.w.writeByte('\n');
    }
};

fn brokenTrees(arena_state: *std.heap.ArenaAllocator, w: *Writer) !void {
    try w.writeAll("\n== 4. Break the canonical tree on purpose: one change, one broken invariant ==\n");
    for (broken.cases, 1..) |case, number| {
        // A broken tree cannot be freed by walking it. The arena does not
        // need to: forget the previous tree, keep the memory for the next.
        _ = arena_state.reset(.retain_capacity);
        var t: Tree4 = .empty;
        try tree_mod.canonical(&t, arena_state.allocator());
        try case.apply(&t, arena_state.allocator());
        try w.print("{d:>2}. {s}\n", .{ number, case.what });
        if (t.validate()) {
            try w.writeAll("    validate: ok");
        } else |violation| {
            try w.print("    validate: {t}", .{violation});
        }
        if (case.searchable) {
            try w.print("; get finds {d} of 12 keys\n", .{broken.keysFound(&t)});
        } else {
            try w.writeAll("; get not tried (it could follow the erased pointer)\n");
        }
    }
}

fn heights(arena: Allocator, w: *Writer) !void {
    try w.writeAll("\n== 5. Height: how few and how many keys fit ==\n");
    {
        var sparse: Tree4 = .empty;
        const leaves = [_]*Tree4.NodeT{
            try sparse.leaf(arena, &.{1}), try sparse.leaf(arena, &.{3}),
            try sparse.leaf(arena, &.{5}), try sparse.leaf(arena, &.{7}),
        };
        const left = try sparse.interior(arena, &.{2}, leaves[0..2]);
        const right = try sparse.interior(arena, &.{6}, leaves[2..4]);
        sparse.root = try sparse.interior(arena, &.{4}, &.{ left, right });
        try sparse.validate();
        try w.print("sparsest tree with 3 levels at M = 4 ({d} keys):\n", .{sparse.len});
        try sparse.render(w, "  ");
    }
    {
        var full: Tree4 = .empty;
        const leaves = [_]*Tree4.NodeT{
            try full.leaf(arena, &.{ 1, 2, 3 }),   try full.leaf(arena, &.{ 5, 6, 7 }),
            try full.leaf(arena, &.{ 9, 10, 11 }), try full.leaf(arena, &.{ 13, 14, 15 }),
        };
        full.root = try full.interior(arena, &.{ 4, 8, 12 }, &leaves);
        try full.validate();
        try w.print("fullest tree with 2 levels at M = 4 ({d} keys):\n", .{full.len});
        try full.render(w, "  ");
    }
    try w.writeAll("keys in a tree of h levels: 2*t^(h-1) - 1 up to M^h - 1, with t = ceil(M/2)\n");
    for ([_]u64{ 4, 256 }) |m| {
        try w.print("  M={d}:", .{m});
        for (1..5) |h| try w.print(" h={d}: {d}..{d}", .{ h, height.minKeys(m, h), height.maxKeys(m, h) });
        try w.writeByte('\n');
    }
    try w.writeAll("possible heights for n keys (shortest..tallest):\n");
    for ([_]u64{ 12, 1000, 1_000_000, 1_000_000_000 }) |n| {
        try w.print("  n={d}:", .{n});
        for ([_]u64{ 4, 16, 256, 1024 }) |m| {
            try w.print(" M={d}: {d}..{d}", .{ m, height.minHeight(m, n), height.maxHeight(m, n) });
        }
        try w.writeByte('\n');
    }
}

fn redBlack(arena: Allocator, w: *Writer) !void {
    try w.writeAll("\n== 6. The 2-3-4 tree as a red-black tree ==\n");
    var t: Tree4 = .empty;
    try tree_mod.canonical(&t, arena);
    try describeNodes(t.root.?, w);
    const summary = try redblack.check(try redblack.fromTree(arena, t.root));
    try w.print("red-black tree: {d} nodes, {d} black nodes on every path (B-tree height {d}), paths of {d} to {d} nodes\n", .{
        summary.nodes, summary.black_height, t.shape().height, summary.shortest_path, summary.longest_path,
    });
}

/// One line per 2-3-4 node, parents before children.
fn describeNodes(node: *const Tree4.NodeT, w: *Writer) !void {
    try w.writeAll("  [");
    for (node.keySlice(), 0..) |key, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("{d}", .{key});
    }
    try w.writeAll("] -> ");
    try redblack.describe(node.keySlice(), w);
    try w.writeByte('\n');
    if (!node.leaf) {
        for (node.children[0 .. node.len + 1]) |child| try describeNodes(child.?, w);
    }
}

fn oracleCheck(arena_state: *std.heap.ArenaAllocator, w: *Writer) !void {
    // The oracle: one bool per possible key. Slow and obviously correct.
    var present: [oracle_key_space]bool = undefined;
    var sorted: [oracle_key_space]u64 = undefined;
    var n: usize = 0;
    var prng = SplitMix64.init(oracle_seed);
    for (&present, 0..) |*p, key| {
        p.* = prng.chance(3, 10);
        if (p.*) {
            sorted[n] = key;
            n += 1;
        }
    }
    try w.print("\n== 7. Oracle check: {d} of the keys 0..{d} (seed {d}), several orders ==\n", .{ n, oracle_key_space - 1, oracle_seed });
    inline for (oracle_orders) |M| {
        _ = arena_state.reset(.retain_capacity);
        var t: tree_mod.HandTree(M, pool_mod.DirectNodes) = .empty;
        try t.fromSorted(arena_state.allocator(), sorted[0..n]);
        try t.validate();
        var agree: usize = 0;
        for (present, 0..) |p, key| {
            const want: ?u64 = if (p) tree_mod.valueOf(key) else null;
            if (t.get(key) == want) agree += 1;
        }
        const s = t.shape();
        try w.print("  M={d}: height={d} (bounds {d}..{d}) nodes={d} fill={d}% validate ok, {d} of {d} lookups agree\n", .{
            M,       s.height,        height.minHeight(M, n), height.maxHeight(M, n),
            s.nodes, s.fillPercent(), agree,                  oracle_key_space,
        });
    }
}

fn printShape(w: *Writer, s: anytype) !void {
    try w.print("shape: height={d} nodes={d} leaves={d} keys={d} fill={d}%\n", .{
        s.height, s.nodes, s.leaves, s.keys, s.fillPercent(),
    });
}

test "run prints exactly expected_output.txt" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // testing.allocator: the run must release every chunk it requested.
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
