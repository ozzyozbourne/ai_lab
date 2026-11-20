//! Demo program of chapter 07. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Rust program's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const lib = @import("ch07_bplus_trees");
const BPlusTree = lib.BPlusTree;
const LeafWalker = lib.LeafWalker;

/// Canonical hand example of chapters 03 to 08.
const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &file_writer.interface;
    try run(init.gpa, w);
    try w.flush();
}

pub fn run(gpa: Allocator, w: *Writer) !void {
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);

    try w.writeAll("== 1. Build: canonical keys, order M = 4 (at most 3 keys per node) ==\n");
    for (canonical) |key| {
        const before = snapshot(&tree);
        _ = try tree.put(gpa, key, key * 100);
        try w.print("put {d}:", .{key});
        try reportChange(w, before, &tree);
    }
    try tree.validate();

    try w.writeAll("\n== 2. The leaf chain ==\n");
    try w.writeAll("forward  (next links):");
    var walker = LeafWalker.first(&tree);
    while (walker.next()) |e| try w.print(" {d}", .{e.key});
    try w.writeAll("\nbackward (prev links), leaf handles:");
    try lib.dump.dumpChainBackward(&tree, w);
    try w.writeAll("\nseparators:");
    try printSeparators(w, &tree);

    try w.writeAll("\n== 3. Lookups always end in a leaf ==\n");
    for ([_]u64{ 15, 12, 13 }) |key| {
        try w.print("get {d} = {?d}\n", .{ key, tree.get(key) });
    }

    try w.writeAll("\n== 4. Delete: stale separator, borrow, merge, shrink ==\n");
    for ([_]u64{ 15, 17, 20, 25, 30, 12 }) |key| {
        const before = snapshot(&tree);
        _ = tree.delete(key);
        try w.print("delete {d}:", .{key});
        try reportChange(w, before, &tree);
        if (key == 15) {
            try w.print("  get 15 = {?d}, but separators:", .{tree.get(15)});
            try printSeparators(w, &tree);
        }
    }
    try tree.validate();

    try w.writeAll("\n== 5. Handles: freed slots are reused ==\n");
    try printArena(w, &tree);
    for ([_]u64{ 11, 13, 14 }) |key| {
        const before = snapshot(&tree);
        _ = try tree.put(gpa, key, key * 100);
        try w.print("put {d}:", .{key});
        try reportChange(w, before, &tree);
    }
    try printArena(w, &tree);
    try tree.validate();

    try duplicatesDemo(gpa, w);
    try modelRun(gpa, w);
}

const Snapshot = struct { stats: lib.Stats, height: usize, nodes: usize };

fn snapshot(tree: *const BPlusTree) Snapshot {
    return .{ .stats = tree.stats, .height = tree.height, .nodes = tree.nodes.liveCount() };
}

/// Says what the last operation did to the structure, and prints the tree
/// whenever a node was created, freed or rebalanced.
fn reportChange(w: *Writer, before: Snapshot, tree: *const BPlusTree) !void {
    const s = tree.stats;
    const old = before.stats;
    var events: usize = 0;
    if (before.height == 0 and tree.height == 1) try event(w, &events, "first leaf", 1);
    try event(w, &events, "leaf split (copy-up)", s.leaf_splits - old.leaf_splits);
    try event(w, &events, "internal split (push-up)", s.internal_splits - old.internal_splits);
    // Within one delete, merges happen below the borrow that ends the repair.
    try event(w, &events, "merge", s.merges - old.merges);
    try event(w, &events, "borrow", s.borrows - old.borrows);
    if (before.height != 0 and tree.height > before.height) try event(w, &events, "new root", 1);
    if (tree.height < before.height) try event(w, &events, "root removed", 1);
    if (events == 0) return w.writeAll(" no structural change\n");
    try w.writeAll("\n  ");
    try lib.dump.dump(tree, w);
}

fn event(w: *Writer, events: *usize, name: []const u8, times: usize) !void {
    if (times == 0) return;
    try w.writeAll(if (events.* == 0) " " else ", ");
    try w.writeAll(name);
    if (times > 1) try w.print(" x{d}", .{times});
    events.* += 1;
}

/// Lists every separator of every internal node and marks the ones that no
/// longer exist as a key in any leaf.
fn printSeparators(w: *Writer, tree: *const BPlusTree) !void {
    if (tree.height < 2) return w.writeAll(" none\n");
    try printSeparatorsOf(w, tree, tree.root);
    try w.writeByte('\n');
}

fn printSeparatorsOf(w: *Writer, tree: *const BPlusTree, id: lib.NodeId) !void {
    const n = tree.nodes.get(id);
    if (n.isLeaf()) return;
    for (n.childSlice(), 0..) |child, i| {
        try printSeparatorsOf(w, tree, child);
        if (i < n.len) {
            const stale = tree.get(n.keys[i]) == null;
            try w.print(" {d}{s}", .{ n.keys[i], if (stale) "(stale)" else "" });
        }
    }
}

fn printArena(w: *Writer, tree: *const BPlusTree) !void {
    try w.print("arena: {d} slots, {d} live, {d} free; free list:", .{
        tree.nodes.slotCount(), tree.nodes.liveCount(), tree.nodes.freeCount().?,
    });
    var id = tree.nodes.free_head;
    while (id != .nil) : (id = tree.nodes.slots.items[id.index()].free) {
        try w.print(" #{d}", .{id.index()});
    }
    try w.writeByte('\n');
}

/// Duplicate user keys through a tie-breaker: the tree key is
/// (user key, row id) packed into one u64, so every tree key is unique and
/// all rows of one user key are adjacent in the leaf chain.
fn duplicatesDemo(gpa: Allocator, w: *Writer) !void {
    try w.writeAll("\n== 6. Duplicates through a tie-breaker: key = (user key, row id) ==\n");
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);
    const rows = [_][2]u64{ .{ 7, 1 }, .{ 3, 2 }, .{ 7, 3 }, .{ 9, 4 }, .{ 7, 5 }, .{ 3, 6 }, .{ 7, 7 } };
    for (rows) |row| {
        const old = try tree.put(gpa, composite(row[0], row[1]), row[1]);
        std.debug.assert(old == null); // never an overwrite: the row id makes it unique
    }
    try tree.validate();
    try w.writeAll("leaf order (user key, row id):");
    var all = LeafWalker.first(&tree);
    while (all.next()) |e| try w.print(" ({d},{d})", .{ e.key >> 32, e.key & 0xFFFF_FFFF });
    try w.writeByte('\n');
    for ([_]u64{ 7, 3, 8 }) |user_key| {
        try w.print("row ids with user key {d}:", .{user_key});
        // Seek to (user_key, 0) and walk while the user key still matches.
        var walker = LeafWalker.seek(&tree, composite(user_key, 0));
        while (walker.next()) |e| {
            if (e.key >> 32 != user_key) break;
            try w.print(" {d}", .{e.key & 0xFFFF_FFFF});
        }
        try w.writeByte('\n');
    }
}

fn composite(user_key: u64, row_id: u64) u64 {
    // 32 bits each: anything larger would collide with another pair.
    std.debug.assert(user_key <= std.math.maxInt(u32) and row_id <= std.math.maxInt(u32));
    return (user_key << 32) | row_id;
}

/// A seeded random workload against the reference oracle; prints only counts.
fn modelRun(gpa: Allocator, w: *Writer) !void {
    try w.writeAll("\n== 7. Model run: 20000 random operations against a sorted-array oracle ==\n");
    for ([_]usize{ 3, 4, 16 }) |order| {
        var tree: BPlusTree = .init(order);
        defer tree.deinit(gpa);
        var oracle: lib.ops.Oracle = .{};
        defer oracle.deinit(gpa);
        var stream = lib.ops.OpStream.init(.{ .seed = 7, .count = 20_000, .key_space = 500 });
        var mismatches: usize = 0;
        while (stream.next()) |op| switch (op) {
            .put => |p| {
                if (try tree.put(gpa, p.key, p.value) != try oracle.put(gpa, p.key, p.value)) mismatches += 1;
            },
            .delete => |d| {
                if (tree.delete(d.key) != oracle.delete(d.key)) mismatches += 1;
            },
            .get => |g| {
                if (tree.get(g.key) != oracle.get(g.key)) mismatches += 1;
            },
            .range => |r| {
                var walker = LeafWalker.seek(&tree, r.lo);
                for (oracle.range(r.lo, r.hi)) |expected| {
                    const got = walker.next();
                    if (got == null or got.?.key != expected.key or got.?.value != expected.value) mismatches += 1;
                }
                if (walker.next()) |after| {
                    if (after.key < r.hi) mismatches += 1;
                }
            },
        };
        try tree.validate();
        const s = tree.stats;
        try w.print("M={d:<2} keys={d} height={d} nodes={d} slots={d} | leaf splits={d} internal splits={d} borrows={d} merges={d} | mismatches={d}\n", .{
            order,         tree.len(),        tree.height, tree.nodes.liveCount(), tree.nodes.slotCount(),
            s.leaf_splits, s.internal_splits, s.borrows,   s.merges,               mismatches,
        });
    }
}

test "run prints exactly expected_output.txt" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
