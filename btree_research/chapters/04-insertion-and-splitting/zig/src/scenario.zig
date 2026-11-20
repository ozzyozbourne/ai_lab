//! The fixed scenario printed by `zig build run` (and by `cargo run`, byte
//! for byte). The chapter README quotes this output and the visualization
//! replays parts 1, 2 and rows of part 4 with a JavaScript model.
const std = @import("std");
const Allocator = std.mem.Allocator;
const btree = @import("base_btree.zig");
const pool = @import("base_pool.zig");
const topdown = @import("topdown.zig");
const measure = @import("measure.zig");

/// The guide's canonical insertion order (chapters 03 to 08), M = 4.
pub const canonical_keys = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };
/// Part 3: keys 1..12 in ascending order, then 13.
pub const failure_count = 12;
/// Parts 4 and 5: this many distinct keys per measurement.
pub const measure_count = 100_000;
pub const measure_seed = 4;
pub const bottom_up_orders = .{ 3, 4, 5, 8, 16, 32, 64, 128, 256 };
pub const top_down_orders = .{ 4, 8, 16, 64, 256 };

/// `std.heap.MemoryPool` is the node allocator of the demonstrations.
const Tree = btree.BTree(4, pool.StdPool);
/// Part 3 wants to fail one particular NODE allocation. That needs a pool
/// in which one node is one allocation.
const TrackedTree = btree.BTree(4, pool.DirectNodes);

pub fn run(gpa: Allocator, w: *std.Io.Writer) !void {
    try w.writeAll("== 1. Bottom-up insert: the canonical keys (M = 4: at most 3 keys per node) ==\n");
    var bottom: Tree = .empty;
    defer bottom.deinit(gpa);
    for (canonical_keys) |key| {
        const before = bottom.counters;
        _ = try bottom.put(gpa, key, key * 10);
        try describePut(w, "put", key, before, bottom.counters, bottom.shape().height);
        try bottom.render(w, "  ");
    }
    try bottom.validate();
    try printShape(w, &bottom);

    try w.writeAll("\n== 2. Top-down insert (textbook, CLRS): the same keys ==\n");
    var top: Tree = .empty;
    defer top.deinit(gpa);
    for (canonical_keys) |key| {
        const before = top.counters;
        _ = try topdown.put(Tree, &top, gpa, key, key * 10);
        try describePut(w, "put", key, before, top.counters, top.shape().height);
    }
    try top.validate();
    try top.render(w, "  ");
    try printShape(w, &top);
    var same: SameKeys = .{ .other = &bottom };
    top.inOrder(&same);
    try w.print("same keys and values as the bottom-up tree: {s}\n", .{if (same.ok and same.seen == bottom.len) "yes" else "NO"});

    try w.writeAll("\n== 3. A put that runs out of memory (the third node allocation fails) ==\n");
    try failureDemo(gpa, w);

    try w.print("\n== 4. Fill and split cost, bottom-up: {d} distinct keys per row (random: seed {d}) ==\n", .{ measure_count, measure_seed });
    const keys = try gpa.alloc(u64, measure_count);
    defer gpa.free(keys);
    try printTableHeader(w);
    inline for (.{ measure.KeyOrder.ascending, measure.KeyOrder.random }) |order| {
        measure.fillKeys(keys, order, measure_seed);
        inline for (bottom_up_orders) |M| {
            try printRow(w, M, @tagName(order), "bottom-up", try measure.build(M, .bottom_up, gpa, keys));
        }
    }
    try w.writeAll("references: all nodes at the minimum = about 50%; textbook (Yao 1978), random inserts, large M: ln 2 = 69.3%\n");

    try w.writeAll("\n== 5. Top-down against bottom-up on the same keys (even M only) ==\n");
    try printTableHeader(w);
    inline for (.{ measure.KeyOrder.ascending, measure.KeyOrder.random }) |order| {
        measure.fillKeys(keys, order, measure_seed);
        inline for (top_down_orders) |M| {
            try printRow(w, M, @tagName(order), "bottom-up", try measure.build(M, .bottom_up, gpa, keys));
            try printRow(w, M, @tagName(order), "top-down", try measure.build(M, .top_down, gpa, keys));
        }
    }
}

/// One line per put: what it did to the structure (from the counter deltas).
fn describePut(w: *std.Io.Writer, verb: []const u8, key: u64, before: btree.Counters, after: btree.Counters, height: usize) !void {
    const splits = after.splits - before.splits;
    try w.print("{s} {d}:", .{ verb, key });
    if (splits == 0) {
        try w.writeAll(" no split\n");
        return;
    }
    try w.print(" {d} split{s}", .{ splits, if (splits == 1) "" else "s" });
    if (after.root_splits > before.root_splits) try w.print(", the root split: height {d}", .{height});
    try w.writeByte('\n');
}

fn failureDemo(gpa: Allocator, w: *std.Io.Writer) !void {
    // FailingAllocator passes every request on to `gpa` until `fail_index`
    // is reached; from then on every allocation fails.
    var failing: std.testing.FailingAllocator = .init(gpa, .{});
    const fgpa = failing.allocator();
    var bottom: TrackedTree = .empty;
    defer bottom.deinit(fgpa);
    var top: TrackedTree = .empty;
    defer top.deinit(fgpa);
    // Both trees are built the same way, so they start out identical.
    for (1..failure_count + 1) |key| {
        _ = try bottom.put(fgpa, key, key);
        _ = try top.put(fgpa, key, key);
    }
    try w.writeAll("both trees before:\n");
    try bottom.render(w, "  ");

    // Key 13 goes into the full leaf [10 11 12] under the full root: the
    // put needs three nodes (leaf half, root half, new root).
    failing.fail_index = failing.alloc_index + 2;
    const bottom_before = bottom.counters;
    if (bottom.put(fgpa, 13, 13)) |_| return error.ExpectedOutOfMemory else |_| {}
    try bottom.validate();
    try w.print("bottom-up put 13: OutOfMemory; splits done: {d}; keys: {d}; tree unchanged:\n", .{ bottom.counters.splits - bottom_before.splits, bottom.len });
    try bottom.render(w, "  ");

    failing.fail_index = failing.alloc_index + 2;
    const top_before = top.counters;
    if (topdown.put(TrackedTree, &top, fgpa, 13, 13)) |_| return error.ExpectedOutOfMemory else |_| {}
    try top.validate();
    try w.print("top-down put 13: OutOfMemory; splits done: {d}; keys: {d}; valid tree, same keys, new shape:\n", .{ top.counters.splits - top_before.splits, top.len });
    try top.render(w, "  ");

    failing.fail_index = std.math.maxInt(usize); // memory is back
    _ = try bottom.put(fgpa, 13, 13);
    _ = try topdown.put(TrackedTree, &top, fgpa, 13, 13);
    try bottom.validate();
    try top.validate();
    try w.writeAll("with memory again, bottom-up put 13:\n");
    try bottom.render(w, "  ");
    try w.writeAll("with memory again, top-down put 13:\n");
    try top.render(w, "  ");
}

/// Visitor: every entry of the visited tree is in `other` with the same value.
const SameKeys = struct {
    other: *const Tree,
    seen: usize = 0,
    ok: bool = true,
    pub fn visit(self: *SameKeys, key: u64, value: u64) void {
        if (self.other.get(key) != value) self.ok = false;
        self.seen += 1;
    }
};

fn printShape(w: *std.Io.Writer, tree: *const Tree) !void {
    const s = tree.shape();
    try w.print("shape: height={d} nodes={d} leaves={d} keys={d} fill={d}% splits={d} root_splits={d}\n", .{
        s.height, s.nodes, s.leaves, s.keys, s.fillPercent(), tree.counters.splits, tree.counters.root_splits,
    });
}

fn printTableHeader(w: *std.Io.Writer) !void {
    try w.writeAll("   M  keys       variant    height   nodes    fill  splits  per 1000 puts  most in one put\n");
}

fn printRow(w: *std.Io.Writer, comptime M: usize, order: []const u8, variant: []const u8, r: measure.Measured) !void {
    const fill = r.fillPermille();
    const rate = r.splitsPer1000Tenths();
    try w.print("{d:>4}  {s:<9}  {s:<9}  {d:>6}  {d:>6}  {d:>3}.{d}%  {d:>6}  {d:>11}.{d}  {d:>15}\n", .{
        M,                        order,     variant,  r.shape.height, r.shape.nodes,
        fill / 10,                fill % 10, r.splits, rate / 10,      rate % 10,
        r.most_splits_in_one_put,
    });
}

test "run prints exactly expected_output.txt" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
