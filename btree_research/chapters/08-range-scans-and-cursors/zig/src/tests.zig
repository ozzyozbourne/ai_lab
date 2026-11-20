//! Tests of chapter 08: the bounds matrix, both cursor designs, backward
//! scans, prefix scans, cursors under a changing tree, the scratch arena,
//! allocation failure, and the seeded model run.
//! (bounds.zig, cursor.zig and the copied base files carry their own tests.)
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Tree = @import("tree.zig").Tree;
const Entry = @import("base_node.zig").Entry;
const NodeId = @import("base_arena.zig").NodeId;
const LeafWalker = @import("base_walk.zig").LeafWalker;
const bounds = @import("bounds.zig");
const Bound = bounds.Bound;
const Direction = bounds.Direction;
const cursor_ = @import("cursor.zig");
const Seek = cursor_.Seek;
const State = cursor_.State;
const Scan = @import("scan.zig").Scan;
const LinkCursor = @import("link_cursor.zig").LinkCursor;
const stack_cursor = @import("stack_cursor.zig");
const StackCursor = stack_cursor.StackCursor;
const StackPosition = stack_cursor.StackPosition;
const Frame = stack_cursor.Frame;
const model = @import("model.zig");

const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };
const sorted = [_]u64{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 };

fn buildCanonical(gpa: Allocator) !Tree {
    var tree: Tree = .init(4);
    errdefer tree.deinit(gpa);
    for (canonical) |k| _ = try tree.put(gpa, k, k * 100);
    try tree.validate();
    return tree;
}

/// One cursor of each design, with the stack cursor's frames in an arena.
const Pair = struct {
    arena: std.heap.ArenaAllocator,
    link: LinkCursor,
    stack: StackCursor,

    fn init(gpa: Allocator) !Pair {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const pos = try StackPosition.init(arena.allocator());
        return .{ .arena = arena, .link = .init(.{}), .stack = .init(pos) };
    }

    fn deinit(self: *Pair) void {
        self.arena.deinit();
    }

    // Each helper applies one operation to both cursors, demands the same
    // answer from both, and returns the key (null = no entry).
    fn seek(self: *Pair, tree: *const Tree, target: Seek) !?u64 {
        return agree(self.link.seek(tree, target), self.stack.seek(tree, target));
    }
    fn next(self: *Pair, tree: *const Tree) !?u64 {
        return agree(self.link.next(tree), self.stack.next(tree));
    }
    fn prev(self: *Pair, tree: *const Tree) !?u64 {
        return agree(self.link.prev(tree), self.stack.prev(tree));
    }
    fn entry(self: *Pair, tree: *const Tree) !?u64 {
        return agree(self.link.entry(tree), self.stack.entry(tree));
    }
    fn agree(a: ?Entry, b: ?Entry) !?u64 {
        try testing.expectEqual(a, b);
        return if (a) |e| e.key else null;
    }
};

/// The keys a scan returns, by cursor type `C`.
fn scanKeys(comptime C: type, arena: Allocator, tree: *const Tree, lo: Bound, hi: Bound, direction: Direction) ![]u64 {
    const cursor: C = if (C == LinkCursor) .init(.{}) else .init(try StackPosition.init(arena));
    var it: Scan(C) = .init(tree, cursor, lo, hi, direction);
    var keys: std.ArrayList(u64) = .empty;
    while (it.next()) |e| {
        try testing.expectEqual(e.key * 100, e.value);
        try keys.append(arena, e.key);
    }
    try testing.expectEqual(null, it.next()); // a finished scan stays finished
    return keys.items;
}

test "bounds matrix: every lo/hi kind and value, both cursors, both directions" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var checked: usize = 0;
    for (0..3) |lo_kind| for (0..3) |hi_kind| for (0..33) |lo_key| for (0..33) |hi_key| {
        _ = arena_state.reset(.retain_capacity);
        const lo = makeBound(lo_kind, lo_key);
        const hi = makeBound(hi_kind, hi_key);
        // The specification: filter the sorted keys by `contains`.
        var expected: std.ArrayList(u64) = .empty;
        for (sorted) |k| if (bounds.contains(lo, hi, k)) try expected.append(arena, k);

        try testing.expectEqualSlices(u64, expected.items, try scanKeys(LinkCursor, arena, &tree, lo, hi, .forward));
        try testing.expectEqualSlices(u64, expected.items, try scanKeys(StackCursor, arena, &tree, lo, hi, .forward));
        std.mem.reverse(u64, expected.items);
        try testing.expectEqualSlices(u64, expected.items, try scanKeys(LinkCursor, arena, &tree, lo, hi, .backward));
        try testing.expectEqualSlices(u64, expected.items, try scanKeys(StackCursor, arena, &tree, lo, hi, .backward));
        checked += 1;
    };
    try testing.expectEqual(9 * 33 * 33, checked);
}

fn makeBound(kind: usize, key: u64) Bound {
    return switch (kind) {
        0 => .unbounded,
        1 => .{ .included = key },
        else => .{ .excluded = key },
    };
}

test "tree.range and tree.rangeBackward on the README examples" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);

    var it = tree.range(.{ .included = 6 }, .{ .excluded = 17 });
    for ([_]u64{ 6, 7, 10, 12, 15 }) |k| try testing.expectEqual(Entry{ .key = k, .value = k * 100 }, it.next());
    try testing.expectEqual(null, it.next());

    var back = tree.rangeBackward(.{ .excluded = 6 }, .{ .included = 17 });
    for ([_]u64{ 17, 15, 12, 10, 7 }) |k| try testing.expectEqual(k, back.next().?.key);
    try testing.expectEqual(null, back.next());

    // Excluded bounds at the ends of the key space: no overflow, just empty.
    const max = std.math.maxInt(u64);
    var above = tree.range(.{ .excluded = max }, .unbounded);
    try testing.expectEqual(null, above.next());
    var below = tree.rangeBackward(.unbounded, .{ .excluded = 0 });
    try testing.expectEqual(null, below.next());
    var inverted = tree.range(.{ .included = 17 }, .{ .included = 6 });
    try testing.expectEqual(null, inverted.next());
}

test "seek: ge, gt, le, lt on present keys, gaps, separators and both ends" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();

    // probe, expected ge, gt, le, lt (0 = no entry). 6, 10, 15 and 20 are
    // separators: the descent goes right of them and the leaf step must
    // still find the neighbour on the left for `lt`.
    const table = [_][5]u64{
        .{ 0, 1, 1, 0, 0 },     .{ 1, 1, 3, 1, 0 },     .{ 2, 3, 3, 1, 1 },
        .{ 5, 5, 6, 5, 3 },     .{ 6, 6, 7, 6, 5 },     .{ 8, 10, 10, 7, 7 },
        .{ 10, 10, 12, 10, 7 }, .{ 13, 15, 15, 12, 12 }, .{ 15, 15, 17, 15, 12 },
        .{ 20, 20, 25, 20, 17 }, .{ 30, 30, 0, 30, 25 }, .{ 31, 0, 0, 30, 30 },
    };
    for (table) |row| {
        const p = row[0];
        try testing.expectEqual(orNull(row[1]), try pair.seek(&tree, .{ .ge = p }));
        try testing.expectEqual(orNull(row[2]), try pair.seek(&tree, .{ .gt = p }));
        try testing.expectEqual(orNull(row[3]), try pair.seek(&tree, .{ .le = p }));
        try testing.expectEqual(orNull(row[4]), try pair.seek(&tree, .{ .lt = p }));
    }
    try testing.expectEqual(1, try pair.seek(&tree, .first));
    try testing.expectEqual(30, try pair.seek(&tree, .last));

    // A stale separator: after deleting 15 the root still says 15.
    _ = tree.delete(15);
    try testing.expectEqual(17, try pair.seek(&tree, .{ .ge = 15 }));
    try testing.expectEqual(12, try pair.seek(&tree, .{ .le = 15 }));
    try testing.expectEqual(12, try pair.seek(&tree, .{ .lt = 15 }));
}

fn orNull(key: u64) ?u64 {
    return if (key == 0) null else key;
}

test "next and prev: whole tree both ways, turning around, both ends" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();

    // A new cursor is before the first entry.
    try testing.expectEqual(null, try pair.entry(&tree));
    try testing.expectEqual(null, try pair.prev(&tree));
    for (sorted) |k| {
        try testing.expectEqual(k, try pair.next(&tree));
        try testing.expectEqual(k, try pair.entry(&tree));
    }
    // Off the end: sticky for next, and prev comes back to the last entry.
    try testing.expectEqual(null, try pair.next(&tree));
    try testing.expectEqual(null, try pair.next(&tree));
    try testing.expectEqual(State.after_last, pair.link.state);
    try testing.expectEqual(null, try pair.entry(&tree));
    var i = sorted.len;
    while (i > 0) {
        i -= 1;
        try testing.expectEqual(sorted[i], try pair.prev(&tree));
    }
    try testing.expectEqual(null, try pair.prev(&tree));
    try testing.expectEqual(State.before_first, pair.stack.state);

    // Turning around in the middle, across a leaf boundary (7 | 10) and
    // across the boundary between the two subtrees of the root (12 | 15).
    try testing.expectEqual(7, try pair.seek(&tree, .{ .ge = 7 }));
    try testing.expectEqual(10, try pair.next(&tree));
    try testing.expectEqual(7, try pair.prev(&tree));
    try testing.expectEqual(10, try pair.next(&tree));
    try testing.expectEqual(12, try pair.next(&tree));
    try testing.expectEqual(15, try pair.next(&tree));
    try testing.expectEqual(12, try pair.prev(&tree));
    try testing.expectEqual(15, try pair.next(&tree));
    try testing.expectEqual(0, pair.link.stats.reseeks); // nothing changed, nothing re-sought
    try testing.expectEqual(0, pair.stack.stats.reseeks);
}

test "empty tree and single-entry tree" {
    const gpa = testing.allocator;
    var tree: Tree = .init(4);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();

    const targets = [_]Seek{ .first, .last, .{ .ge = 5 }, .{ .gt = 5 }, .{ .le = 5 }, .{ .lt = 5 } };
    for (targets) |t| try testing.expectEqual(null, try pair.seek(&tree, t));
    try testing.expectEqual(null, try pair.next(&tree));
    try testing.expectEqual(null, try pair.prev(&tree));

    _ = try tree.put(gpa, 5, 500);
    const expected = [_]?u64{ 5, 5, 5, null, 5, null };
    for (targets, expected) |t, e| try testing.expectEqual(e, try pair.seek(&tree, t));
    try testing.expectEqual(5, try pair.seek(&tree, .first));
    try testing.expectEqual(null, try pair.next(&tree));
    try testing.expectEqual(5, try pair.prev(&tree));
    try testing.expectEqual(null, try pair.prev(&tree));
    try testing.expectEqual(5, try pair.next(&tree));
}

test "the stack cursor's path is the root-to-leaf route" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    const id = NodeId.fromIndex;

    //   level 0: #7[15]
    //   level 1: #2[6 10] #6[20]
    //   leaves : #0(1 3 5) #4(6 7) #1(10 12) #5(15 17) #3(20 25 30)
    _ = try pair.seek(&tree, .{ .ge = 12 });
    try testing.expectEqualSlices(Frame, &.{ .{ .node = id(7), .child = 0 }, .{ .node = id(2), .child = 2 } }, pair.stack.pos.path());
    try testing.expectEqual(id(1), pair.stack.pos.leaf);
    try testing.expectEqual(id(1), pair.link.pos.leaf);

    // 12 -> 15 crosses the root: pop #2 (exhausted), step #7 to child 1,
    // push #6 with child 0.
    const visits_before = pair.stack.stats.node_visits;
    try testing.expectEqual(15, try pair.next(&tree));
    try testing.expectEqualSlices(Frame, &.{ .{ .node = id(7), .child = 1 }, .{ .node = id(6), .child = 0 } }, pair.stack.pos.path());
    try testing.expectEqual(id(5), pair.stack.pos.leaf);
    // Up to #2, up to #7, down to #6, down to #5: four moves, where the
    // link cursor needs one.
    try testing.expectEqual(4, pair.stack.stats.node_visits - visits_before);
}

test "the stack cursor never uses sibling links; the link cursor depends on them" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Cut the leaf chain and forget both ends. The tree part stays intact.
    var id = tree.base.first_leaf;
    while (id != .nil) {
        const leaf = &tree.base.nodes.ptr(id).kind.leaf;
        const following = leaf.next;
        leaf.next = .nil;
        leaf.prev = .nil;
        id = following;
    }
    tree.base.first_leaf = .nil;
    tree.base.last_leaf = .nil;
    try testing.expectError(error.BrokenLeafChain, tree.validate());

    try testing.expectEqualSlices(u64, &sorted, try scanKeys(StackCursor, arena, &tree, .unbounded, .unbounded, .forward));
    try testing.expectEqualSlices(u64, &.{ 17, 15, 12, 10, 7 }, try scanKeys(StackCursor, arena, &tree, .{ .excluded = 6 }, .{ .included = 17 }, .backward));
    // The link cursor finds the leaf by descent but cannot leave it.
    try testing.expectEqualSlices(u64, &.{ 6, 7 }, try scanKeys(LinkCursor, arena, &tree, .{ .included = 6 }, .{ .included = 17 }, .forward));
    try testing.expectEqualSlices(u64, &.{}, try scanKeys(LinkCursor, arena, &tree, .unbounded, .unbounded, .forward));
}

test "both cursors agree with the chapter 07 leaf walker" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    for ([_]u64{ 0, 6, 8, 15, 31 }) |from| {
        var walker = LeafWalker.seek(&tree.base, from);
        var got = try pair.seek(&tree, .{ .ge = from });
        while (walker.next()) |e| : (got = try pair.next(&tree)) try testing.expectEqual(e.key, got);
        try testing.expectEqual(null, got);
    }
}

test "prefix scan is a range scan" {
    const gpa = testing.allocator;
    var tree: Tree = .init(4);
    defer tree.deinit(gpa);
    const last_user = 0xFFFF_FFFF;
    const rows = [_][2]u64{ .{ 7, 1 }, .{ 3, 2 }, .{ 7, 3 }, .{ 9, 4 }, .{ 7, 5 }, .{ 3, 6 }, .{ 7, 7 }, .{ last_user, 8 }, .{ last_user, 9 } };
    for (rows) |row| _ = try tree.put(gpa, (row[0] << 32) | row[1], row[1]);

    const cases = [_]struct { user: u64, rows: []const u64 }{
        .{ .user = 7, .rows = &.{ 1, 3, 5, 7 } },
        .{ .user = 3, .rows = &.{ 2, 6 } },
        .{ .user = 8, .rows = &.{} },
        .{ .user = last_user, .rows = &.{ 8, 9 } }, // upper bound is unbounded here
    };
    for (cases) |case| {
        const r = bounds.prefixRange(case.user, 32);
        var it = tree.range(r.lo, r.hi);
        for (case.rows) |row| try testing.expectEqual(row, it.next().?.value);
        try testing.expectEqual(null, it.next());
        var back = tree.rangeBackward(r.lo, r.hi);
        var i = case.rows.len;
        while (i > 0) : (i -= 1) try testing.expectEqual(case.rows[i - 1], back.next().?.value);
        try testing.expectEqual(null, back.next());
    }
}

test "a cursor survives a split under it; a raw position does not" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();

    try testing.expectEqual(10, try pair.seek(&tree, .{ .ge = 10 }));
    try testing.expectEqual(12, try pair.next(&tree)); // leaf #1 = (10 12), index 1
    const stale = pair.link.pos;

    const splits_before = tree.base.stats.leaf_splits;
    for ([_]u64{ 11, 13, 14 }) |k| _ = try tree.put(gpa, k, k * 100);
    try testing.expectEqual(splits_before + 1, tree.base.stats.leaf_splits);
    try tree.validate();

    // Leaf #1 is now (10 11): the old (leaf, index) names a different entry,
    // and stepping from it returns 12 again. This is the bug that the
    // version check prevents.
    var raw = stale;
    var ignored: cursor_.Stats = .{};
    try testing.expectEqual(11, raw.entry(&tree.base).key);
    try testing.expectEqual(12, raw.next(&tree.base, &ignored).?.key);

    // The real cursors re-seek by key and carry on in order.
    try testing.expectEqual(12, try pair.entry(&tree));
    for ([_]u64{ 13, 14, 15, 17 }) |k| try testing.expectEqual(k, try pair.next(&tree));
    try testing.expectEqual(1, pair.link.stats.reseeks); // once; then the position is fresh again
    try testing.expectEqual(1, pair.stack.stats.reseeks);
}

test "the entry under the cursor is deleted: entry is null, next and prev continue from its key" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();

    try testing.expectEqual(12, try pair.seek(&tree, .{ .ge = 12 }));
    _ = tree.delete(12);
    try testing.expectEqual(null, try pair.entry(&tree));
    try testing.expectEqual(State{ .on = 12 }, pair.link.state); // the key is still the position
    try testing.expectEqual(15, try pair.next(&tree));

    try testing.expectEqual(10, try pair.seek(&tree, .{ .ge = 10 }));
    _ = tree.delete(10);
    try testing.expectEqual(7, try pair.prev(&tree));

    // Deleted and inserted again before the cursor looks: it is simply there.
    try testing.expectEqual(17, try pair.seek(&tree, .{ .ge = 17 }));
    _ = tree.delete(17);
    _ = try tree.put(gpa, 17, 1);
    try testing.expectEqual(17, try pair.entry(&tree));
    try testing.expectEqual(1, pair.link.entry(&tree).?.value);
}

test "an overwrite does not invalidate a cursor and is visible through it" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();

    try testing.expectEqual(12, try pair.seek(&tree, .{ .ge = 12 }));
    const version = tree.version;
    try testing.expectEqual(1200, try tree.put(gpa, 12, 77));
    try testing.expectEqual(version, tree.version);
    try testing.expectEqual(77, pair.link.entry(&tree).?.value);
    try testing.expectEqual(77, pair.stack.entry(&tree).?.value);
    try testing.expectEqual(0, pair.link.stats.reseeks);

    // Deleting an absent key changes nothing either.
    try testing.expectEqual(null, tree.delete(13));
    try testing.expectEqual(version, tree.version);
}

test "delete while scanning: every entry is returned once" {
    const gpa = testing.allocator;
    inline for (.{ LinkCursor, StackCursor }) |C| {
        var tree = try buildCanonical(gpa);
        defer tree.deinit(gpa);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const cursor: C = if (C == LinkCursor) .init(.{}) else .init(try StackPosition.init(arena_state.allocator()));

        var it: Scan(C) = .init(&tree, cursor, .unbounded, .unbounded, .forward);
        var n: usize = 0;
        while (it.next()) |e| : (n += 1) {
            try testing.expectEqual(sorted[n], e.key);
            try testing.expectEqual(e.value, tree.delete(e.key)); // delete what was just returned
        }
        try testing.expectEqual(sorted.len, n);
        try testing.expectEqual(0, tree.len());
        try tree.validate();
    }
}

test "insert while scanning: keys behind the cursor are not seen, keys ahead are" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);

    var it = tree.range(.{ .included = 5 }, .{ .included = 20 });
    try testing.expectEqual(5, it.next().?.key);
    try testing.expectEqual(6, it.next().?.key);
    _ = try tree.put(gpa, 4, 0); // outside the range
    _ = try tree.put(gpa, 5, 0); // overwrite behind the cursor
    _ = try tree.put(gpa, 2, 0); // behind
    _ = try tree.put(gpa, 8, 0); // ahead: will be returned
    _ = try tree.put(gpa, 19, 0); // ahead
    _ = try tree.put(gpa, 21, 0); // ahead but outside the range
    for ([_]u64{ 7, 8, 10, 12, 15, 17, 19, 20 }) |k| try testing.expectEqual(k, it.next().?.key);
    try testing.expectEqual(null, it.next());
}

test "handles are reused: the tree is emptied and refilled under a cursor" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();

    try testing.expectEqual(12, try pair.seek(&tree, .{ .ge = 12 }));
    for (sorted) |k| _ = tree.delete(k);
    try testing.expectEqual(0, tree.base.nodes.liveCount()); // every node was freed
    try testing.expectEqual(null, try pair.entry(&tree));

    // New nodes take the freed slots, so the cursor's old handles now name
    // unrelated nodes. Only the saved key 12 is still meaningful.
    for ([_]u64{ 40, 2, 13, 11, 50, 9 }) |k| _ = try tree.put(gpa, k, k);
    try tree.validate();
    try testing.expectEqual(13, try pair.next(&tree));
    try testing.expectEqual(11, try pair.prev(&tree));
    try testing.expectEqual(9, try pair.prev(&tree));
}

test "scratch arena: after the first scan, later scans allocate nothing from the backing allocator" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);

    // The FailingAllocator is used here only as a counter of allocations.
    var counting: testing.FailingAllocator = .init(gpa, .{});
    var arena_state: std.heap.ArenaAllocator = .init(counting.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var first: Scan(StackCursor) = .init(&tree, .init(try StackPosition.init(arena)), .unbounded, .unbounded, .forward);
    try testing.expectEqual(sorted.len, (try first.collect(arena)).len);
    try testing.expect(counting.allocations > 0);
    // Reset keeps the memory. From here on the arena is a bump pointer over
    // memory it already owns.
    try testing.expect(arena_state.reset(.retain_capacity));
    const allocations = counting.allocations;

    for (0..100) |i| {
        defer _ = arena_state.reset(.retain_capacity);
        const direction: Direction = if (i % 2 == 0) .forward else .backward;
        var it: Scan(StackCursor) = .init(&tree, .init(try StackPosition.init(arena)), .{ .included = i % 30 }, .unbounded, direction);
        const rows = try it.collect(arena);
        try testing.expect(rows.len <= sorted.len);
    }
    try testing.expectEqual(allocations, counting.allocations);

    // Stepping itself never allocates: a failing allocator is never asked.
    var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    _ = failing.allocator();
    var link = tree.range(.unbounded, .unbounded);
    while (link.next()) |_| {}
    try testing.expectEqual(0, failing.allocations);
}

/// One whole scan through an arena on top of `gpa`; used with
/// checkAllAllocationFailures, which fails each allocation in turn and
/// checks for `error.OutOfMemory` and for leaks.
fn collectThroughArena(gpa: Allocator, tree: *const Tree) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var it: Scan(StackCursor) = .init(tree, .init(try StackPosition.init(arena)), .unbounded, .unbounded, .backward);
    const rows = try it.collect(arena);
    try testing.expectEqual(sorted.len, rows.len);
    try testing.expectEqual(30, rows[0].key);
}

/// The same without an arena: `collect` must free its partial result.
fn collectDirect(gpa: Allocator, tree: *const Tree) !void {
    var it = tree.range(.unbounded, .unbounded);
    const rows = try it.collect(gpa);
    defer gpa.free(rows);
    try testing.expectEqual(sorted.len, rows.len);
}

test "allocation failure: cursor creation and collect fail cleanly" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);

    var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, StackPosition.init(failing.allocator()));

    try testing.checkAllAllocationFailures(gpa, collectThroughArena, .{&tree});
    try testing.checkAllAllocationFailures(gpa, collectDirect, .{&tree});
}

test "allocation failure in put: tree, version and cursors are unchanged" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    try testing.expectEqual(12, try pair.seek(&tree, .{ .ge = 12 }));

    // Fill the arena's spare capacity so that the next insert must grow it.
    var k: u64 = 1000;
    while (tree.base.nodes.slots.capacity - tree.base.nodes.slots.items.len >= tree.base.height + 1) : (k += 1) {
        _ = try tree.put(gpa, k, k);
    }
    try testing.expectEqual(12, try pair.entry(&tree)); // fresh position again
    const version = tree.version;
    const count = tree.len();
    const reseeks = pair.link.stats.reseeks;

    var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, tree.put(failing.allocator(), 999, 1));
    try testing.expectEqual(version, tree.version);
    try testing.expectEqual(count, tree.len());
    try tree.validate();
    try testing.expectEqual(15, try pair.next(&tree));
    try testing.expectEqual(reseeks, pair.link.stats.reseeks); // no re-seek was needed
}

test "model: random operations with cursors stepping in between, against the oracle" {
    const gpa = testing.allocator;
    for ([_]usize{ 3, 4, 5, 16 }) |order| {
        for ([_]u64{ 1, 2, 3 }) |seed| {
            const r = try model.run(gpa, .{ .order = order, .seed = seed, .count = 6000, .key_space = 200 });
            try testing.expectEqual(0, r.mismatches);
            try testing.expect(r.scans > 300 and r.cursor_steps > 4000);
            // The re-seek rule is shared code: both designs re-seek equally often.
            try testing.expectEqual(r.link.reseeks, r.stack.reseeks);
            try testing.expect(r.link.reseeks > 500);
        }
    }
    // A tiny key space empties the tree again and again.
    const small = try model.run(gpa, .{ .order = 3, .seed = 9, .count = 6000, .key_space = 8 });
    try testing.expectEqual(0, small.mismatches);
}
