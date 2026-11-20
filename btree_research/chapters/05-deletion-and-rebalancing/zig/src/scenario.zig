//! The fixed scenario printed by `zig build run` (and by `cargo run`, byte
//! for byte). The chapter README quotes this output and the visualization
//! replays parts 1 to 3 with a JavaScript model.
const std = @import("std");
const Allocator = std.mem.Allocator;
const btree = @import("btree.zig");
const pool = @import("pool.zig");
const ops = @import("ops.zig");

/// The guide's canonical insertion order (chapters 03 to 08), M = 4.
pub const canonical_keys = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };
/// Part 2: one delete per case, on the canonical tree.
pub const case_deletes = [_]u64{ 3, 7, 6, 20, 10, 12, 15, 17, 30, 25 };
/// Part 3: a three-level tree (keys 1..13 in ascending order), where an
/// underflow travels up through an interior node.
pub const tall_count = 13;
pub const tall_deletes = [_]u64{ 9, 13, 10, 1, 2, 3 };

const Tree = btree.BTree(4, pool.FreeListPool);

pub fn run(gpa: Allocator, w: *std.Io.Writer) !void {
    try w.writeAll("== 1. Build the canonical tree (M = 4: 1 to 3 keys per node) ==\n");
    var tree: Tree = .empty;
    defer tree.deinit(gpa);
    try w.writeAll("put");
    for (canonical_keys) |key| {
        _ = try tree.put(gpa, key, key * 10);
        try w.print(" {d}", .{key});
    }
    try w.writeByte('\n');
    try tree.render(w, "  ");
    try printShape(w, &tree);

    try w.writeAll("\n== 2. Delete, one case at a time ==\n");
    for (case_deletes) |key| try deleteAndShow(gpa, w, &tree, key);

    try w.writeAll("\n== 3. An underflow that travels up (keys 1..13 inserted in order) ==\n");
    var tall: Tree = .empty;
    defer tall.deinit(gpa);
    for (1..tall_count + 1) |key| _ = try tall.put(gpa, key, key * 10);
    try tall.render(w, "  ");
    for (tall_deletes) |key| try deleteAndShow(gpa, w, &tall, key);

    try w.writeAll("\n== 4. Random workload: 20000 operations on 500 possible keys (seed 5) ==\n");
    var big: Tree = .empty;
    defer big.deinit(gpa);
    var stream = ops.OpStream.init(.{ .seed = 5, .count = 20_000, .key_space = 500 });
    var checksum: u64 = 0; // folds every answer, so Zig and Rust must agree on all of them
    while (stream.next()) |op| switch (op) {
        .put => |p| checksum +%= (try big.put(gpa, p.key, p.value)) orelse 1,
        .delete => |d| checksum +%= big.delete(gpa, d.key) orelse 2,
        .get => |g| checksum +%= big.get(g.key) orelse 3,
        .range => |r| {
            var sum: Sum = .{};
            big.range(r.lo, r.hi, &sum);
            checksum +%= sum.total;
        },
    };
    try big.validate();
    try w.print("answers checksum: {x:0>16}\n", .{checksum});
    try printShape(w, &big);
    try printCounters(w, &big);

    try w.writeAll("\n== 5. Delete every remaining key in ascending order ==\n");
    for (0..500) |key| _ = big.delete(gpa, key);
    try big.validate();
    try big.render(w, "  ");
    try printShape(w, &big);
    try printCounters(w, &big);
    const usage = big.pool.usage;
    try w.print("node pool: created={d} destroyed={d} live={d} peak={d} reused={d}\n", .{
        usage.created,              usage.destroyed, usage.live(), usage.peak,
        // Every create beyond the peak was served from the free list.
        usage.created - usage.peak,
    });
}

const Sum = struct {
    total: u64 = 0,
    pub fn visit(self: *Sum, key: u64, value: u64) void {
        self.total +%= key ^ value;
    }
};

/// Delete one key and say which repairs it needed (from the counter deltas).
fn deleteAndShow(gpa: Allocator, w: *std.Io.Writer, tree: *Tree, key: u64) !void {
    const before = tree.counters;
    const removed = tree.delete(gpa, key);
    try tree.validate();
    const after = tree.counters;
    try w.print("delete {d}:", .{key});
    if (removed == null) try w.writeAll(" not found");
    if (after.predecessor_swaps > before.predecessor_swaps) {
        try w.writeAll(" interior key, replaced by its predecessor;");
    } else if (removed != null) {
        try w.writeAll(" leaf key;");
    }
    var repairs: usize = 0;
    const parts = [_]struct { n: u64, text: []const u8 }{
        // In the order they happen: merges first (each one passes the
        // underflow up a level), then at most one borrow, which ends it.
        .{ .n = after.merges - before.merges, .text = "merge" },
        .{ .n = after.borrows_left - before.borrows_left, .text = "borrow from left" },
        .{ .n = after.borrows_right - before.borrows_right, .text = "borrow from right" },
        .{ .n = after.root_shrinks - before.root_shrinks, .text = "root shrink" },
    };
    for (parts) |part| {
        if (part.n == 0) continue;
        try w.writeAll(if (repairs == 0) " " else ", ");
        if (part.n > 1) try w.print("{d} x ", .{part.n});
        try w.writeAll(part.text);
        repairs += 1;
    }
    if (repairs == 0 and removed != null) try w.writeAll(" no underflow");
    try w.writeByte('\n');
    try tree.render(w, "  ");
}

fn printShape(w: *std.Io.Writer, tree: *const Tree) !void {
    const s = tree.shape();
    try w.print("shape: height={d} nodes={d} leaves={d} keys={d} fill={d}%\n", .{
        s.height, s.nodes, s.leaves, s.keys, s.fillPercent(),
    });
}

fn printCounters(w: *std.Io.Writer, tree: *const Tree) !void {
    const c = tree.counters;
    try w.print("counters: splits={d} root_splits={d} predecessor_swaps={d} borrows_left={d} borrows_right={d} merges={d} root_shrinks={d}\n", .{
        c.splits, c.root_splits, c.predecessor_swaps, c.borrows_left, c.borrows_right, c.merges, c.root_shrinks,
    });
}

test "run prints exactly expected_output.txt" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
