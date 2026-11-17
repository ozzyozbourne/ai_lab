//! The chapter's fixed scenario. `zig build run` prints it; the test at the
//! bottom checks it against ../expected_output.txt, and the Rust version
//! prints exactly the same bytes.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bptree = @import("bptree.zig");
const bulk = @import("bulk.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;
const Tree = bptree.Tree;
const Entry = bptree.Entry;

/// Print the nodes of one level, left to right. Leaves show their keys in
/// [ ], interior nodes show their separators (keys[1..]) in ( ).
fn writeLevel(w: *Io.Writer, tree: *const Tree, id: u32, depth: usize, wanted: usize) Io.Writer.Error!void {
    const node = &tree.nodes.items[id];
    if (depth < wanted) {
        for (node.slots[0..node.len]) |child| try writeLevel(w, tree, @intCast(child), depth + 1, wanted);
        return;
    }
    const first: usize = if (node.is_leaf) 0 else 1;
    try w.writeAll(if (node.is_leaf) " [" else " (");
    for (node.keys[first..node.len], 0..) |key, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("{d}", .{key});
    }
    try w.writeAll(if (node.is_leaf) "]" else ")");
}

fn writeTree(w: *Io.Writer, tree: *const Tree) Io.Writer.Error!void {
    var depth: usize = 1;
    while (depth <= tree.height) : (depth += 1) {
        try w.print("  level {d}:", .{tree.height - depth});
        try writeLevel(w, tree, tree.root, 1, depth);
        try w.writeByte('\n');
    }
    const s = tree.shape();
    try w.print("  pages {d}, page writes {d}, splits {d}\n", .{ s.pages(), tree.stats.page_writes, tree.stats.splits });
}

/// Leaf fill in percent, rounded down: entries / (leaves * capacity).
fn leafFill(tree: *const Tree) usize {
    const s = tree.shape();
    if (s.leaves == 0) return 0;
    return s.entries * 100 / (s.leaves * tree.leafCap());
}

fn writeRow(w: *Io.Writer, name: []const u8, tree: *const Tree) Io.Writer.Error!void {
    const s = tree.shape();
    try w.print("{s:<22}{d:>7}{d:>8}{d:>7}{d:>7}{d:>10}%{d:>13}{d:>12}{d:>8}\n", .{
        name,          s.height,               s.leaves,              s.inner, s.pages(),
        leafFill(tree), tree.stats.page_writes, tree.stats.page_reads, tree.stats.splits,
    });
}

fn insertAll(gpa: Allocator, order: usize, entries: []const Entry) !Tree {
    var tree = Tree.init(gpa, order);
    errdefer tree.deinit();
    for (entries) |e| try tree.put(e.key, e.value);
    return tree;
}

pub fn write(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("Chapter 16: bulk loading\n");

    // ---- 1. the hand example from the README ----
    try w.writeAll("\n== 1. Hand example: keys 1..13, order M = 4 ==\n");
    {
        var entries: [13]Entry = undefined;
        for (&entries, 1..) |*e, k| e.* = .{ .key = k, .value = k * 10 };

        try w.writeAll("bulk load, fill 100%:\n");
        var loaded = try bulk.bulkLoad(gpa, 4, &entries, .{});
        defer loaded.deinit();
        try loaded.validate();
        try writeTree(w, &loaded);

        try w.writeAll("one-by-one insert, ascending:\n");
        var inserted = try insertAll(gpa, 4, &entries);
        defer inserted.deinit();
        try inserted.validate();
        try writeTree(w, &inserted);
    }

    // ---- 2. cost of building a larger tree four ways ----
    const n = 10_000;
    const order = 16;
    const entries = try gpa.alloc(Entry, n);
    defer gpa.free(entries);
    for (entries, 0..) |*e, i| e.* = .{ .key = i * 10, .value = i };

    try w.print("\n== 2. Building n = {d} keys, order M = {d} ==\n", .{ n, order });
    try w.writeAll("method                 height  leaves  inner  pages  leaf fill  page writes  page reads  splits\n");
    {
        var t = try bulk.bulkLoad(gpa, order, entries, .{});
        defer t.deinit();
        try t.validate();
        try writeRow(w, "bulk load 100%", &t);
    }
    {
        var t = try bulk.bulkLoad(gpa, order, entries, .{ .leaf_fill = 90, .inner_fill = 70 });
        defer t.deinit();
        try t.validate();
        try writeRow(w, "bulk load 90% / 70%", &t);
    }
    {
        var t = try insertAll(gpa, order, entries);
        defer t.deinit();
        try t.validate();
        try writeRow(w, "insert, ascending", &t);
    }
    {
        // The same entries in a random order (Fisher-Yates over the indices).
        const perm = try gpa.alloc(u64, n);
        defer gpa.free(perm);
        for (perm, 0..) |*p, i| p.* = i;
        var rng = SplitMix64.init(16);
        rng.shuffle(perm);
        var t = Tree.init(gpa, order);
        defer t.deinit();
        for (perm) |i| try t.put(entries[@intCast(i)].key, entries[@intCast(i)].value);
        try t.validate();
        try writeRow(w, "insert, shuffled", &t);
    }

    // ---- 3. what the fill factor buys once inserts start ----
    const extra = 1000;
    try w.print("\n== 3. {d} random inserts after the bulk load ==\n", .{extra});
    try w.writeAll("leaf / inner fill  pages before  splits  page writes  pages after\n");
    for ([_][2]u8{ .{ 100, 100 }, .{ 90, 70 }, .{ 70, 70 } }) |fill| {
        var t = try bulk.bulkLoad(gpa, order, entries, .{ .leaf_fill = fill[0], .inner_fill = fill[1] });
        defer t.deinit();
        const before = t.shape().pages();
        t.stats = .{}; // count only the inserts
        var rng = SplitMix64.init(1616);
        for (0..extra) |i| {
            // Loaded keys are multiples of 10; these never are.
            const key = rng.below(n) * 10 + 1 + rng.below(9);
            try t.put(key, i);
        }
        try t.validate();
        try w.print("{d:>4}% / {d:>3}%     {d:>12}{d:>8}{d:>13}{d:>13}\n", .{
            fill[0], fill[1], before, t.stats.splits, t.stats.page_writes, t.shape().pages(),
        });
    }
}

test "the report matches expected_output.txt" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, std.testing.allocator);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
