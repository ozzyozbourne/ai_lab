//! Demo program of chapter 20. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Rust program's.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const lib = @import("ch20_blink_trees");
const BLinkTree = lib.BLinkTree;
const Descent = lib.Descent;

/// Canonical hand example of chapters 03 to 08.
const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &file_writer.interface;
    try run(init.gpa, init.io, w);
    try w.flush();
}

pub fn run(gpa: Allocator, io: Io, w: *Writer) !void {
    var tree = try BLinkTree.init(gpa, 4, 64);
    defer tree.deinit(gpa);

    try w.writeAll("== 1. Build: canonical keys, order M = 4; every node has a high key and a right link ==\n");
    for (canonical) |key| _ = try tree.put(io, key, key * 100);
    try tree.validate();
    try lib.dump.dump(&tree, w);
    try w.writeAll("legend: #n node, [..] separators, (..) leaf keys, <k high key (keys in the node are below k), -> right link\n");

    try w.writeAll("\n== 2. Step 1 of a split, and nothing else ==\n");
    try w.writeAll("put 26 into the full leaf #3(20 25 30); the writer stops between the two steps\n");
    tree.setAbandonSplits(true);
    _ = try tree.put(io, 26, 2600);
    tree.setAbandonSplits(false);
    try tree.validate();
    try lib.dump.dump(&tree, w);
    try w.print("incomplete splits: {d}; validate: ok\n", .{tree.incompleteSplits()});

    try w.writeAll("\n== 3. Searching in that state ==\n");
    for ([_]u64{ 25, 26, 30 }) |key| {
        const r = tree.lookup(io, key, .follow_right_links);
        try w.print("get {d} = {?d} (visited {d} nodes, moved right {d})\n", .{ key, r.value, r.visited, r.moves_right });
    }
    for ([_]u64{ 25, 26, 30 }) |key| {
        const r = tree.lookup(io, key, .ignore_right_links);
        try w.print("without right links: get {d} = {?d}{s}\n", .{ key, r.value, if (r.value == null) "  <- MISSED" else "" });
    }
    try printFound(io, w, &tree, &(canonical ++ [_]u64{26}));

    try w.writeAll("\n== 4. The next writer finishes the split ==\n");
    try w.writeAll("put 27: lands on #3, sees the flag, inserts the downlink to #8 first, then does its own work\n");
    const before = tree.stats();
    _ = try tree.put(io, 27, 2700);
    const after = tree.stats();
    try tree.validate();
    try lib.dump.dump(&tree, w);
    try w.print("splits finished by a later writer: {d}; incomplete splits: {d}\n", .{
        after.finished_later - before.finished_later, tree.incompleteSplits(),
    });
    try printFound(io, w, &tree, &(canonical ++ [_]u64{ 26, 27 }));

    try w.writeAll("\n== 5. A reader overtaken by a complete split (stale downlink) ==\n");
    for ([_]lib.search.Mode{ .follow_right_links, .ignore_right_links }) |mode| {
        // Each pass splits one leaf: #8 in the first pass, #9 in the second.
        const split_key: u64, const probe: u64 = if (mode == .follow_right_links) .{ 28, 30 } else .{ 31, 32 };
        _ = try tree.put(io, probe, probe * 100);
        try w.print("{s}: get {d}\n", .{ if (mode == .follow_right_links) "with right links" else "without right links", probe });
        var reader = Descent.begin(&tree, probe, mode);
        // Two visits: the root, then the level-1 node. The reader now holds
        // the handle of a leaf and no latch.
        for (0..2) |_| try printStep(w, &tree, probe, reader.step(&tree, io));
        const halves = tree.stats().half_splits;
        _ = try tree.put(io, split_key, split_key * 100);
        try w.print("  writer: put {d} splits that leaf, both steps (half splits +{d}, incomplete {d})\n", .{
            split_key, tree.stats().half_splits - halves, tree.incompleteSplits(),
        });
        while (true) {
            const step = reader.step(&tree, io);
            try printStep(w, &tree, probe, step);
            if (step == .done) break;
        }
    }
    try tree.validate();
    try lib.dump.dump(&tree, w);

    try rootSplitDemo(gpa, io, w);
    try modelRun(gpa, io, w);
    try stressRun(gpa, io, w);
}

fn printFound(io: Io, w: *Writer, tree: *BLinkTree, keys: []const u64) !void {
    var with: usize = 0;
    var without: usize = 0;
    for (keys) |key| {
        if (tree.lookup(io, key, .follow_right_links).value != null) with += 1;
        if (tree.lookup(io, key, .ignore_right_links).value != null) without += 1;
    }
    try w.print("keys found: {d} of {d} with right links, {d} of {d} without\n", .{ with, keys.len, without, keys.len });
}

fn printStep(w: *Writer, tree: *const BLinkTree, key: u64, step: lib.search.Step) !void {
    try w.writeAll("  reader: visits ");
    switch (step) {
        .descended => |s| {
            try lib.dump.printNode(tree, s.from, w);
            try w.print(", follows the downlink to #{d}\n", .{s.to.index()});
        },
        .moved_right => |s| {
            try lib.dump.printNode(tree, s.from, w);
            try w.print(", {d} >= high key {d}, follows the right link to #{d}\n", .{ key, s.high_key, s.to.index() });
        },
        .done => |s| {
            try lib.dump.printNode(tree, s.leaf, w);
            if (s.value) |v| try w.print(", finds {d} = {d}\n", .{ key, v }) else try w.print(", does not find {d}  <- MISSED\n", .{key});
        },
    }
}

/// The root is not special: its split is the same two steps, and step 2 is
/// "build a new root".
fn rootSplitDemo(gpa: Allocator, io: Io, w: *Writer) !void {
    try w.writeAll("\n== 6. A root split is the same two steps ==\n");
    var tree = try BLinkTree.init(gpa, 4, 8);
    defer tree.deinit(gpa);
    for ([_]u64{ 1, 2, 3 }) |key| _ = try tree.put(io, key, key * 100);
    tree.setAbandonSplits(true);
    _ = try tree.put(io, 4, 400);
    tree.setAbandonSplits(false);
    try w.writeAll("put 4, stopped after step 1: the root has a right sibling and there is no new root yet\n");
    try tree.validate();
    try lib.dump.dump(&tree, w);
    const r = tree.lookup(io, 4, .follow_right_links);
    try w.print("get 4 = {?d} (moved right {d})\n", .{ r.value, r.moves_right });
    _ = try tree.put(io, 5, 500);
    try w.writeAll("put 5 finishes it: step 2 of a root split builds the new root\n");
    try tree.validate();
    try lib.dump.dump(&tree, w);
}

/// A seeded single-threaded workload against the reference oracle. A seeded
/// coin decides before every put whether splits are abandoned after step 1,
/// so the tree is full of half-finished splits most of the time.
fn modelRun(gpa: Allocator, io: Io, w: *Writer) !void {
    try w.writeAll("\n== 7. Model run: 20000 puts and gets, a seeded coin abandons splits after step 1 ==\n");
    for ([_]usize{ 3, 4, 16 }) |order| {
        var tree = try BLinkTree.init(gpa, order, 4096);
        defer tree.deinit(gpa);
        var oracle: lib.ops.Oracle = .{};
        defer oracle.deinit(gpa);
        var stream = lib.ops.OpStream.init(.{
            .seed = 20,
            .count = 20_000,
            .key_space = 2000,
            .weights = .{ .put = 4, .delete = 0, .get = 3, .range = 0 },
        });
        var coin = lib.prng.SplitMix64.init(99);
        var mismatches: usize = 0;
        var missed_without: usize = 0;
        while (stream.next()) |op| switch (op) {
            .put => |p| {
                tree.setAbandonSplits(coin.chance(1, 4));
                if (try tree.put(io, p.key, p.value) != try oracle.put(gpa, p.key, p.value)) mismatches += 1;
            },
            .get => |g| {
                const expected = oracle.get(g.key);
                if (tree.get(io, g.key) != expected) mismatches += 1;
                if (tree.lookup(io, g.key, .ignore_right_links).value != expected) missed_without += 1;
            },
            .delete, .range => unreachable, // weight 0
        };
        try tree.validate();
        const s = tree.stats();
        try w.print("M={d:<2} keys={d} height={d} nodes={d} | half splits={d} completed={d} (by a later writer={d}) still incomplete={d} | gets wrong={d}, wrong without right links={d}\n", .{
            order,         tree.len(),         tree.height,      tree.nodeCount(),
            s.half_splits, s.completed_splits, s.finished_later, tree.incompleteSplits(),
            mismatches,    missed_without,
        });
    }
}

fn stressRun(gpa: Allocator, io: Io, w: *Writer) !void {
    try w.writeAll("\n== 8. Stress: 4 threads, 4000 seeded puts each, every put followed by 3 gets ==\n");
    for ([_]bool{ false, true }) |abandon| {
        const r = try lib.stress.run(gpa, io, .{
            .puts_per_thread = 4000,
            .key_space = 6000,
            .preload = 500,
            .seed = 2020,
            .capacity = 8192,
            .abandon_splits = abandon,
        });
        try w.print("{s}: keys={d} expected={d} lost reads={d} failed puts={d} mismatches={d} validate={s}", .{
            if (abandon) "every split abandoned after step 1" else "normal splits",
            r.keys,
            r.expected_keys,
            r.lost,
            r.failed_puts,
            r.mismatches,
            if (r.valid) "ok" else "FAILED",
        });
        // With the hook on, how many flags are left depends on the
        // interleaving, so it is not printed.
        if (!abandon) try w.print(" incomplete splits={d}", .{r.incomplete_splits});
        try w.writeByte('\n');
    }
}

test "run prints exactly expected_output.txt" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, std.testing.io, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
