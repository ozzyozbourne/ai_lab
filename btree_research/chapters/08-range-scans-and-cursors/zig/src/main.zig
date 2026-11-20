//! Demo program of chapter 08. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Rust program's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const lib = @import("ch08_range_scans_and_cursors");
const Tree = lib.Tree;
const Bound = lib.Bound;
const Direction = lib.Direction;
const LinkCursor = lib.LinkCursor;
const StackCursor = lib.StackCursor;
const StackPosition = lib.StackPosition;
const Scan = lib.Scan;

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
    // One arena for everything a scan needs besides the tree: the stack
    // cursor's path and materialised results. Reset between sections.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);

    try w.writeAll("== 1. The tree: canonical keys, order M = 4 ==\n");
    try lib.dump.dump(&tree.base, w);

    try w.writeAll("\n== 2. Bounds matrix: every combination for the bounds 6 and 17 ==\n");
    const lows = [_]Bound{ .unbounded, .{ .included = 6 }, .{ .excluded = 6 } };
    const highs = [_]Bound{ .unbounded, .{ .included = 17 }, .{ .excluded = 17 } };
    for (lows) |lo| for (highs) |hi| try printRange(w, &tree, lo, hi, .forward, "");
    try w.writeAll("edge cases:\n");
    const max = std.math.maxInt(u64);
    try printRange(w, &tree, .{ .included = 12 }, .{ .included = 12 }, .forward, "one key");
    try printRange(w, &tree, .{ .excluded = 12 }, .{ .excluded = 15 }, .forward, "neighbours, both excluded");
    try printRange(w, &tree, .{ .included = 13 }, .{ .included = 14 }, .forward, "both bounds in one gap");
    try printRange(w, &tree, .{ .included = 17 }, .{ .included = 6 }, .forward, "inverted");
    try printRange(w, &tree, .{ .included = 12 }, .{ .excluded = 12 }, .forward, "half open, same key");
    try printRange(w, &tree, .unbounded, .{ .excluded = 0 }, .forward, "below the smallest u64");
    try printRange(w, &tree, .{ .excluded = max }, .unbounded, .forward, "above the largest u64, no overflow");

    try w.writeAll("\n== 3. Backward: seek to the upper bound, step with prev ==\n");
    try printRange(w, &tree, .unbounded, .unbounded, .backward, "");
    try printRange(w, &tree, .{ .included = 6 }, .{ .excluded = 17 }, .backward, "");
    try printRange(w, &tree, .{ .excluded = 6 }, .{ .included = 17 }, .backward, "");
    try printRange(w, &tree, .{ .included = 13 }, .unbounded, .backward, "");

    try w.writeAll("\n== 4. Two cursor designs, one result ==\n");
    try traceBoth(arena, w, &tree);
    _ = arena_state.reset(.retain_capacity);
    try w.writeAll("node visits (every move of a cursor to another node):\n");
    try compareCosts(arena, w, &tree, .{ .included = 5 }, .{ .included = 20 }, .forward);
    try compareCosts(arena, w, &tree, .{ .included = 5 }, .{ .included = 20 }, .backward);
    try compareCosts(arena, w, &tree, .unbounded, .unbounded, .forward);
    try compareCosts(arena, w, &tree, .{ .included = 12 }, .{ .included = 12 }, .forward);
    _ = arena_state.reset(.retain_capacity);

    try prefixDemo(gpa, w);

    try w.writeAll("\n== 6. The tree changes under the cursor ==\n");
    try changeDemo(gpa, arena, w, &tree);
    _ = arena_state.reset(.retain_capacity);
    try deleteWhileScanning(gpa, arena, w);

    try w.writeAll("\n== 7. Model run: 20000 random operations, two long-lived cursors stepping in between ==\n");
    for ([_]usize{ 3, 4, 16 }) |order| {
        const r = try lib.model.run(gpa, .{ .order = order, .seed = 8, .count = 20_000, .key_space = 500 });
        try w.print("M={d:<2} keys={d} height={d} scans={d} cursor steps={d} re-seeks={d} | node visits: link={d} stack={d} | mismatches={d}\n", .{
            order, r.keys, r.height, r.scans, r.cursor_steps, r.link.reseeks, r.link.node_visits, r.stack.node_visits, r.mismatches,
        });
        std.debug.assert(r.link.reseeks == r.stack.reseeks);
    }
}

fn buildCanonical(gpa: Allocator) !Tree {
    var tree: Tree = .init(4);
    errdefer tree.deinit(gpa);
    for (canonical) |key| _ = try tree.put(gpa, key, key * 100);
    try tree.validate();
    return tree;
}

/// "[6, 17)" in interval notation: square = included, round = excluded.
fn rangeLabel(buf: []u8, lo: Bound, hi: Bound) []const u8 {
    var w: Writer = .fixed(buf);
    switch (lo) {
        .unbounded => w.writeAll("(-inf") catch unreachable,
        .included => |k| w.print("[{d}", .{k}) catch unreachable,
        .excluded => |k| w.print("({d}", .{k}) catch unreachable,
    }
    switch (hi) {
        .unbounded => w.writeAll(", +inf)") catch unreachable,
        .included => |k| w.print(", {d}]", .{k}) catch unreachable,
        .excluded => |k| w.print(", {d})", .{k}) catch unreachable,
    }
    return w.buffered();
}

fn printRange(w: *Writer, tree: *const Tree, lo: Bound, hi: Bound, direction: Direction, note: []const u8) !void {
    var buf: [64]u8 = undefined;
    try w.print("{s:<12} :", .{rangeLabel(&buf, lo, hi)});
    var it = if (direction == .forward) tree.range(lo, hi) else tree.rangeBackward(lo, hi);
    var n: usize = 0;
    while (it.next()) |e| : (n += 1) try w.print(" {d}", .{e.key});
    if (n == 0) try w.writeAll(" (nothing)");
    if (note.len != 0) try w.print("   <- {s}", .{note});
    try w.writeByte('\n');
}

/// "#7.0 #2.1": in node #7 the path goes down child 0, in node #2 child 1.
fn pathLabel(buf: []u8, pos: *const StackPosition) []const u8 {
    var w: Writer = .fixed(buf);
    for (pos.path(), 0..) |frame, i| {
        if (i != 0) w.writeByte(' ') catch unreachable;
        w.print("#{d}.{d}", .{ frame.node.index(), frame.child }) catch unreachable;
    }
    return w.buffered();
}

/// Scans [5, 20] with both cursors side by side and prints where each one is.
fn traceBoth(arena: Allocator, w: *Writer, tree: *const Tree) !void {
    try w.writeAll("scan [5, 20] forward; \"#0[2]\" = leaf #0, entry 2; \"#7.0\" = in node #7, down child 0\n");
    try w.writeAll("key  link cursor  stack cursor\n");
    var link: Scan(LinkCursor) = .init(tree, .init(.{}), .{ .included = 5 }, .{ .included = 20 }, .forward);
    var stack: Scan(StackCursor) = .init(tree, .init(try StackPosition.init(arena)), .{ .included = 5 }, .{ .included = 20 }, .forward);
    while (link.next()) |a| {
        const b = stack.next().?;
        std.debug.assert(a.key == b.key and a.value == b.value);
        var buf: [64]u8 = undefined;
        const lp = &link.cursor.pos;
        const sp = &stack.cursor.pos;
        try w.print("{d:<4} #{d}[{d}]        {s} -> #{d}[{d}]\n", .{
            a.key, lp.leaf.index(), lp.index, pathLabel(&buf, sp), sp.leaf.index(), sp.index,
        });
    }
    std.debug.assert(stack.next() == null);
}

fn compareCosts(arena: Allocator, w: *Writer, tree: *const Tree, lo: Bound, hi: Bound, direction: Direction) !void {
    var link: Scan(LinkCursor) = .init(tree, .init(.{}), lo, hi, direction);
    var stack: Scan(StackCursor) = .init(tree, .init(try StackPosition.init(arena)), lo, hi, direction);
    const a = try link.collect(arena);
    const b = try stack.collect(arena);
    std.debug.assert(a.len == b.len);
    for (a, b) |x, y| std.debug.assert(x.key == y.key and x.value == y.value);
    var buf: [64]u8 = undefined;
    try w.print("{s:<12} {s:<8} : {d:>2} entries, link {d:>2}, stack {d:>2}\n", .{
        rangeLabel(&buf, lo, hi),         @tagName(direction),            a.len,
        link.cursor.stats.node_visits, stack.cursor.stats.node_visits,
    });
}

fn composite(user_key: u64, row_id: u64) u64 {
    return (user_key << 32) | row_id;
}

/// Prefix scan as a range, on the composite keys of chapter 07, section 6.
fn prefixDemo(gpa: Allocator, w: *Writer) !void {
    try w.writeAll("\n== 5. Prefix scan as a range: key = (user key << 32) | row id ==\n");
    var tree: Tree = .init(4);
    defer tree.deinit(gpa);
    const last_user = 0xFFFF_FFFF;
    const rows = [_][2]u64{ .{ 7, 1 }, .{ 3, 2 }, .{ 7, 3 }, .{ 9, 4 }, .{ 7, 5 }, .{ 3, 6 }, .{ 7, 7 }, .{ last_user, 8 }, .{ last_user, 9 } };
    for (rows) |row| _ = try tree.put(gpa, composite(row[0], row[1]), row[1]);
    try tree.validate();
    for ([_]u64{ 7, 3, 8, last_user }) |user_key| {
        const r = lib.bounds.prefixRange(user_key, 32);
        var buf: [64]u8 = undefined;
        try w.print("user key {d}: range {s}, row ids:", .{ user_key, rangeLabel(&buf, r.lo, r.hi) });
        var it = tree.range(r.lo, r.hi);
        var n: usize = 0;
        while (it.next()) |e| : (n += 1) try w.print(" {d}", .{e.value});
        if (n == 0) try w.writeAll(" (nothing)");
        try w.writeByte('\n');
    }
}

fn printOptionalKey(w: *Writer, e: ?lib.Entry) !void {
    if (e) |found| try w.print("{d}", .{found.key}) else try w.writeAll("none");
}

/// A split and a merge between two steps of the same cursors.
fn changeDemo(gpa: Allocator, arena: Allocator, w: *Writer, tree: *Tree) !void {
    var link: LinkCursor = .init(.{});
    var stack: StackCursor = .init(try StackPosition.init(arena));
    _ = link.seek(tree, .{ .ge = 10 });
    _ = stack.seek(tree, .{ .ge = 10 });
    const on_link = link.next(tree).?;
    const on_stack = stack.next(tree).?;
    var buf: [64]u8 = undefined;
    try w.print("both cursors: seek >= 10, next. link on {d} at #{d}[{d}], stack on {d} at {s} -> #{d}[{d}]\n", .{
        on_link.key,                 link.pos.leaf.index(),  link.pos.index, on_stack.key,
        pathLabel(&buf, &stack.pos), stack.pos.leaf.index(), stack.pos.index,
    });

    try w.writeAll("put 11, 13, 14: leaf #1 fills up and splits\n  ");
    for ([_]u64{ 11, 13, 14 }) |key| _ = try tree.put(gpa, key, key * 100);
    try tree.validate();
    try lib.dump.dump(&tree.base, w);
    // What a cursor WITHOUT the version check would do: trust (leaf, index).
    var naive = link.pos;
    var ignored: lib.cursor.Stats = .{};
    try w.print("  the old position #{d}[{d}] now holds {d}; stepping from it would return {d} a second time\n", .{
        naive.leaf.index(), naive.index, naive.entry(&tree.base).key, naive.next(&tree.base, &ignored).?.key,
    });
    try w.print("  link  next -> {d} (re-seek: first key > 12), now at #{d}[{d}]\n", .{
        link.next(tree).?.key, link.pos.leaf.index(), link.pos.index,
    });
    try w.print("  stack next -> {d} (re-seek: first key > 12), now at {s} -> #{d}[{d}]\n", .{
        stack.next(tree).?.key, pathLabel(&buf, &stack.pos), stack.pos.leaf.index(), stack.pos.index,
    });

    try w.writeAll("delete 13 (the entry under both cursors), 14, 15, 17: leaves merge\n  ");
    for ([_]u64{ 13, 14, 15, 17 }) |key| _ = tree.delete(key);
    try tree.validate();
    try lib.dump.dump(&tree.base, w);
    try w.writeAll("  link  entry -> ");
    try printOptionalKey(w, link.entry(tree));
    try w.writeAll(" (deleted), next -> ");
    try printOptionalKey(w, link.next(tree));
    try w.writeAll(", prev -> ");
    try printOptionalKey(w, link.prev(tree));
    try w.writeAll("\n  stack entry -> ");
    try printOptionalKey(w, stack.entry(tree));
    try w.writeAll(" (deleted), prev -> ");
    try printOptionalKey(w, stack.prev(tree));
    try w.writeAll(", next -> ");
    try printOptionalKey(w, stack.next(tree));
    try w.print("\n  put 12 again with a new value (an overwrite moves nothing): link entry -> ", .{});
    _ = try tree.put(gpa, 12, 1212);
    const reseeks_before = link.stats.reseeks;
    _ = link.seek(tree, .{ .ge = 12 });
    _ = try tree.put(gpa, 12, 1200);
    try w.print("{d}={d}, re-seeks caused: {d}\n", .{ link.entry(tree).?.key, link.entry(tree).?.value, link.stats.reseeks - reseeks_before });
    try w.print("  re-seeks so far: link {d}, stack {d}\n", .{ link.stats.reseeks, stack.stats.reseeks });
}

/// The classic use: delete rows while scanning them.
fn deleteWhileScanning(gpa: Allocator, arena: Allocator, w: *Writer) !void {
    try w.writeAll("delete every even key while scanning the whole tree forward:\n");
    inline for (.{ LinkCursor, StackCursor }, .{ "link ", "stack" }) |C, name| {
        var tree = try buildCanonical(gpa);
        defer tree.deinit(gpa);
        const cursor: C = if (C == LinkCursor) .init(.{}) else .init(try StackPosition.init(arena));
        var it: Scan(C) = .init(&tree, cursor, .unbounded, .unbounded, .forward);
        try w.print("  {s} returned:", .{name});
        while (it.next()) |e| {
            try w.print(" {d}", .{e.key});
            if (e.key % 2 == 0) _ = tree.delete(e.key);
        }
        try tree.validate();
        try w.print(" | re-seeks {d} | left:", .{it.cursor.stats.reseeks});
        var rest = tree.range(.unbounded, .unbounded);
        while (rest.next()) |e| try w.print(" {d}", .{e.key});
        try w.writeByte('\n');
    }
}

test "run prints exactly expected_output.txt" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
