//! Tests of the B-link tree. Deterministic first: the interesting states of
//! a concurrent split are reached WITHOUT threads, through two hooks:
//!
//!   * `setAbandonSplits(true)` makes a writer stop between step 1 and step 2
//!     of a split, leaving the state a crashed or failed writer leaves;
//!   * `Descent.step` runs a search one node at a time, so a test can put a
//!     complete split between "read the parent" and "visit the child".
//!
//! Only the last tests use threads, and they assert nothing about timing.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const blink = @import("blink.zig");
const BLinkTree = blink.BLinkTree;
const NodeId = blink.NodeId;
const Descent = @import("search.zig").Descent;
const dump = @import("dump.zig");
const ops = @import("ops.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;
const stress = @import("stress.zig");

const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

fn id(i: usize) NodeId {
    return NodeId.fromIndex(i);
}

fn buildCanonical(io: Io, capacity: usize) !BLinkTree {
    var tree = try BLinkTree.init(testing.allocator, 4, capacity);
    errdefer tree.deinit(testing.allocator);
    for (canonical) |key| try testing.expectEqual(null, try tree.put(io, key, key * 100));
    try tree.validate();
    return tree;
}

fn expectDump(tree: *const BLinkTree, expected: []const u8) !void {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump.dump(tree, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

/// Every key answers with `key * 100` when right links are followed.
fn expectAllFound(tree: *BLinkTree, io: Io, keys: []const u64) !void {
    for (keys) |key| try testing.expectEqual(key * 100, tree.get(io, key));
}

/// No latch is held on any node: every one can be taken exclusively.
fn expectNoLatchHeld(tree: *BLinkTree, io: Io) !void {
    for (tree.slots[0..tree.nodeCount()]) |*slot| {
        try testing.expect(slot.latch.tryLock(io));
        slot.latch.unlock(io);
    }
}

test "canonical build has the shape of chapter 07 plus high keys and right links" {
    const io = testing.io;
    var tree = try buildCanonical(io, 16);
    defer tree.deinit(testing.allocator);
    try expectDump(&tree,
        \\height 3, 12 keys, 8 nodes
        \\  level 2: #7[15]
        \\  level 1: #2[6 10]<15 -> #6[20]
        \\  level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25 30)
        \\
    );
    try testing.expectEqual(0, tree.incompleteSplits());
    try testing.expectEqual(null, tree.get(io, 13));
    try testing.expectEqual(1200, try tree.put(io, 12, 1201)); // overwrite returns the old value
    try testing.expectEqual(1201, tree.get(io, 12));
    try testing.expectEqual(12, tree.len());
}

test "paused between step 1 and step 2: every key is found by moving right" {
    const io = testing.io;
    var tree = try buildCanonical(io, 16);
    defer tree.deinit(testing.allocator);

    tree.setAbandonSplits(true);
    try testing.expectEqual(null, try tree.put(io, 26, 2600)); // splits leaf #3, step 1 only
    tree.setAbandonSplits(false);

    // The half-finished state is a VALID state of the tree.
    try tree.validate();
    try testing.expectEqual(1, tree.incompleteSplits());
    try testing.expect(tree.page(id(3)).incomplete_split);
    try testing.expectEqual(id(8), tree.page(id(3)).right);
    try testing.expectEqual(26, tree.page(id(3)).high_key);
    // The parent level has not been touched.
    try testing.expectEqualSlices(u64, &.{20}, tree.page(id(6)).node.keySlice());
    try testing.expectEqual(1, tree.stats().half_splits - tree.stats().completed_splits);

    try expectAllFound(&tree, io, &(canonical ++ [_]u64{26}));
    // Keys in the right half are reached through the right link ...
    for ([_]u64{ 26, 30 }) |key| try testing.expectEqual(1, tree.lookup(io, key, .follow_right_links).moves_right);
    // ... keys in the left half are not affected.
    try testing.expectEqual(0, tree.lookup(io, 25, .follow_right_links).moves_right);
    try expectNoLatchHeld(&tree, io);
}

test "the same state with move-right disabled misses exactly the moved keys" {
    const io = testing.io;
    var tree = try buildCanonical(io, 16);
    defer tree.deinit(testing.allocator);
    tree.setAbandonSplits(true);
    _ = try tree.put(io, 26, 2600);
    tree.setAbandonSplits(false);

    var missed: std.ArrayList(u64) = .empty;
    defer missed.deinit(testing.allocator);
    for (canonical ++ [_]u64{26}) |key| {
        if (tree.lookup(io, key, .ignore_right_links).value == null) try missed.append(testing.allocator, key);
    }
    // 30 was in the tree long before the split began, and is now invisible.
    try testing.expectEqualSlices(u64, &.{ 30, 26 }, missed.items);
}

test "an insert that meets the flag finishes the split before its own work" {
    const io = testing.io;
    var tree = try buildCanonical(io, 16);
    defer tree.deinit(testing.allocator);
    tree.setAbandonSplits(true);
    _ = try tree.put(io, 26, 2600);
    tree.setAbandonSplits(false);

    // A writer that never latches the flagged node does not finish anything.
    _ = try tree.put(io, 2, 200);
    try testing.expectEqual(1, tree.incompleteSplits());
    try testing.expectEqual(0, tree.stats().finished_later);

    // 27 belongs to the right half #8. The writer is sent to #3 (the only
    // node with a downlink), sees the flag, finishes, then moves right.
    _ = try tree.put(io, 27, 2700);
    try tree.validate();
    try testing.expectEqual(0, tree.incompleteSplits());
    try testing.expectEqual(1, tree.stats().finished_later);
    try testing.expectEqualSlices(u64, &.{ 20, 26 }, tree.page(id(6)).node.keySlice());
    try testing.expectEqualSlices(NodeId, &.{ id(5), id(3), id(8) }, tree.page(id(6)).node.childSlice());
    try testing.expectEqualSlices(u64, &.{ 26, 27, 30 }, tree.page(id(8)).node.keySlice());

    // With the downlink in place even the broken search finds everything.
    for (canonical ++ [_]u64{ 2, 26, 27 }) |key| {
        try testing.expectEqual(key * 100, tree.lookup(io, key, .ignore_right_links).value);
    }
    try expectNoLatchHeld(&tree, io);
}

test "a reader overtaken by a complete split recovers by moving right" {
    const io = testing.io;
    var tree = try buildCanonical(io, 16);
    defer tree.deinit(testing.allocator);

    // The reader reads the root and the level-1 node. It now knows "30 is in
    // leaf #3" and holds no latch at all.
    var reader = Descent.begin(&tree, 30, .follow_right_links);
    try testing.expectEqual(id(6), reader.step(&tree, io).descended.to);
    try expectNoLatchHeld(&tree, io); // one latch at a time means none in between
    try testing.expectEqual(id(3), reader.step(&tree, io).descended.to);
    try expectNoLatchHeld(&tree, io);

    // A writer splits #3 completely (both steps): 30 moves to the new #8.
    _ = try tree.put(io, 26, 2600);
    try testing.expectEqual(0, tree.incompleteSplits());

    // The reader's knowledge is stale. The high key of #3 tells it so.
    const moved = reader.step(&tree, io).moved_right;
    try testing.expectEqual(id(3), moved.from);
    try testing.expectEqual(id(8), moved.to);
    try testing.expectEqual(26, moved.high_key);
    try testing.expectEqual(3000, reader.step(&tree, io).done.value);

    // The same interleaving without right links: wrong answer, no error.
    var broken = Descent.begin(&tree, 30, .ignore_right_links);
    _ = broken.step(&tree, io);
    try testing.expectEqual(id(8), broken.step(&tree, io).descended.to);
    _ = try tree.put(io, 27, 2700); // #8 = (26 27 30), full
    _ = try tree.put(io, 28, 2800); // splits #8: 28 and 30 move to #9
    const answer = broken.step(&tree, io).done;
    try testing.expectEqual(id(8), answer.leaf);
    try testing.expectEqual(null, answer.value);
    try testing.expectEqual(3000, tree.get(io, 30));
}

test "a reader that starts at an old root still finds everything" {
    const io = testing.io;
    var tree = try BLinkTree.init(testing.allocator, 4, 8);
    defer tree.deinit(testing.allocator);
    for ([_]u64{ 1, 2, 3 }) |key| _ = try tree.put(io, key, key * 100);

    // Reads the root pointer (#0) and is then overtaken by a root split.
    var reader = Descent.begin(&tree, 4, .follow_right_links);
    _ = try tree.put(io, 4, 400);
    try testing.expectEqual(2, tree.height);
    try testing.expectEqual(id(2), tree.rootId());
    try testing.expectEqual(id(1), reader.step(&tree, io).moved_right.to);
    try testing.expectEqual(400, reader.step(&tree, io).done.value);
}

test "a root split paused after step 1, then finished by the next writer" {
    const io = testing.io;
    var tree = try BLinkTree.init(testing.allocator, 4, 8);
    defer tree.deinit(testing.allocator);
    for ([_]u64{ 1, 2, 3 }) |key| _ = try tree.put(io, key, key * 100);
    tree.setAbandonSplits(true);
    _ = try tree.put(io, 4, 400);
    tree.setAbandonSplits(false);

    try tree.validate();
    try expectDump(&tree,
        \\height 1, 4 keys, 2 nodes
        \\  level 0: #0(1 2)<3 {incomplete} -> #1(3 4) {no downlink}
        \\
    );
    try expectAllFound(&tree, io, &.{ 1, 2, 3, 4 });
    try testing.expectEqual(null, tree.lookup(io, 4, .ignore_right_links).value);

    _ = try tree.put(io, 5, 500);
    try tree.validate();
    try expectDump(&tree,
        \\height 2, 5 keys, 3 nodes
        \\  level 1: #2[3]
        \\  level 0: #0(1 2)<3 -> #1(3 4 5)
        \\
    );
    try testing.expectEqual(1, tree.stats().finished_later);
}

test "an internal node paused after step 1" {
    const io = testing.io;
    var tree = try BLinkTree.init(testing.allocator, 3, 256);
    defer tree.deinit(testing.allocator);
    // Order 3: two keys per node. Ascending inserts with the hook always on:
    // every put first finishes the previous half split, and that step 2 is
    // what overflows a parent and leaves an INTERNAL node half split.
    tree.setAbandonSplits(true);
    var key: u64 = 1;
    var seen_internal = false;
    while (key <= 40) : (key += 1) {
        _ = try tree.put(io, key, key * 100);
        try tree.validate();
        for (1..key + 1) |k| try testing.expectEqual(k * 100, tree.get(io, k));
        for (tree.slots[0..tree.nodeCount()]) |*slot| {
            if (slot.page.level > 0 and slot.page.incomplete_split) seen_internal = true;
        }
    }
    try testing.expect(seen_internal);
    try testing.expect(tree.stats().finished_later > 0);

    // Hook off: ordinary inserts clean up every flag they pass.
    tree.setAbandonSplits(false);
    while (key <= 60) : (key += 1) _ = try tree.put(io, key, key * 100);
    try tree.validate();
    try testing.expectEqual(0, tree.incompleteSplits());
    for (1..key) |k| try testing.expectEqual(k * 100, tree.get(io, k));
    try expectNoLatchHeld(&tree, io);
}

test "a full node table: put fails cleanly, or leaves a legal incomplete split" {
    const io = testing.io;
    var saw_incomplete = false;
    var saw_clean_failure = false;
    // Every table size from 1 to 40 nodes: the table runs out at a leaf
    // split, at an internal split and at a root split in turn.
    for (1..41) |capacity| {
        var tree = try BLinkTree.init(testing.allocator, 4, capacity);
        defer tree.deinit(testing.allocator);
        var inserted: u64 = 0;
        var key: u64 = 0;
        while (key < 400) : (key += 1) {
            const before = tree.len();
            if (tree.put(io, key, key * 100)) |old| {
                try testing.expectEqual(null, old);
                inserted += 1;
            } else |err| {
                // The contract of the error: nothing was inserted.
                try testing.expectEqual(error.OutOfNodes, err);
                try testing.expectEqual(before, tree.len());
                try testing.expectEqual(null, tree.get(io, key));
                saw_clean_failure = true;
                break;
            }
        }
        try testing.expect(key < 400); // the table did run out
        try tree.validate();
        try testing.expectEqual(inserted, tree.len());
        try testing.expectEqual(capacity, tree.nodeCount());
        for (0..inserted) |k| try testing.expectEqual(k * 100, tree.get(io, k));
        // A put succeeded although the PARENT could not be split: the key is
        // in, and the leaf split simply stays incomplete.
        if (tree.incompleteSplits() > 0) saw_incomplete = true;
        // Overwrites need no node and still work, unless the leaf is flagged
        // and cannot be finished.
        if (tree.put(io, 0, 1)) |old| try testing.expectEqual(0, old) else |_| {}
        try tree.validate();
        try expectNoLatchHeld(&tree, io);
    }
    try testing.expect(saw_clean_failure);
    try testing.expect(saw_incomplete);
}

fn initPutDeinit(gpa: std.mem.Allocator, io: Io) !void {
    var tree = try BLinkTree.init(gpa, 4, 16);
    defer tree.deinit(gpa);
    for (canonical) |key| _ = try tree.put(io, key, key);
    try tree.validate();
}

test "the only allocation is the node table: init fails cleanly, put never allocates" {
    try testing.checkAllAllocationFailures(testing.allocator, initPutDeinit, .{testing.io});
    // Proof that put does not allocate: build a tree, then run puts while
    // the allocator that built it is one that always fails.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var tree = try BLinkTree.init(failing.allocator(), 4, 16);
    defer tree.deinit(failing.allocator());
    for (canonical) |key| _ = try tree.put(testing.io, key, key);
    try testing.expectEqual(1, failing.allocations);
}

test "validate names the broken invariant" {
    const io = testing.io;
    var tree = try buildCanonical(io, 16);
    defer tree.deinit(testing.allocator);
    tree.setAbandonSplits(true);
    _ = try tree.put(io, 26, 2600);
    tree.setAbandonSplits(false);
    try tree.validate();

    const left = tree.page(id(3));
    // The flag is the only thing that excuses #8's missing downlink.
    left.incomplete_split = false;
    try testing.expectError(error.MissingDownlink, tree.validate());
    left.incomplete_split = true;

    // A high key that does not bound the keys of the node.
    left.high_key = 25;
    try testing.expectError(error.KeyOutOfBounds, tree.validate());
    left.high_key = 26;

    // A right link without a high key.
    left.high_key = null;
    try testing.expectError(error.BrokenRightLink, tree.validate());
    left.high_key = 26;

    // A flag on the rightmost node of a level has nothing to point at.
    tree.page(id(8)).incomplete_split = true;
    try testing.expectError(error.BadSplitFlag, tree.validate());
    tree.page(id(8)).incomplete_split = false;

    // A separator that disagrees with the child's lower bound.
    tree.page(id(6)).node.keys[0] = 19;
    try testing.expectError(error.SeparatorMismatch, tree.validate());
    tree.page(id(6)).node.keys[0] = 20;

    _ = tree.count.fetchAdd(1, .monotonic);
    try testing.expectError(error.WrongCount, tree.validate());
    _ = tree.count.fetchSub(1, .monotonic);
    try tree.validate();
}

test "model test: seeded puts and gets against the oracle, splits abandoned by a seeded coin" {
    const io = testing.io;
    for ([_]usize{ 3, 4, 5, 16 }) |order| {
        var tree = try BLinkTree.init(testing.allocator, order, 2048);
        defer tree.deinit(testing.allocator);
        var oracle: ops.Oracle = .{};
        defer oracle.deinit(testing.allocator);
        var stream = ops.OpStream.init(.{
            .seed = 20 + order,
            .count = 6000,
            .key_space = 700,
            .weights = .{ .put = 4, .delete = 0, .get = 3, .range = 0 },
        });
        var coin = SplitMix64.init(order);
        var n: usize = 0;
        while (stream.next()) |op| : (n += 1) {
            switch (op) {
                .put => |p| {
                    tree.setAbandonSplits(coin.chance(1, 3));
                    try testing.expectEqual(try oracle.put(testing.allocator, p.key, p.value), try tree.put(io, p.key, p.value));
                },
                .get => |g| try testing.expectEqual(oracle.get(g.key), tree.get(io, g.key)),
                .delete, .range => unreachable,
            }
            if (n % 64 == 0) try tree.validate();
        }
        try tree.validate();
        try testing.expectEqual(oracle.len(), tree.len());
        for (oracle.entries.items) |e| try testing.expectEqual(e.value, tree.get(io, e.key));
        const s = tree.stats();
        try testing.expect(s.finished_later > 0 and s.moves_right > 0);
        try testing.expectEqual(s.half_splits - s.completed_splits, tree.incompleteSplits());
    }
}

test "stress: 4 threads, normal splits" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const r = try stress.run(testing.allocator, testing.io, .{
        .puts_per_thread = 5000,
        .key_space = 8000,
        .preload = 500,
        .seed = 1,
        .capacity = 8192,
    });
    try testing.expectEqual(stress.Report{
        .keys = r.expected_keys,
        .expected_keys = r.expected_keys,
        .valid = true,
    }, r);
    try testing.expect(r.keys > 500);
}

test "stress: 4 threads, every split abandoned and finished by another writer" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    for ([_]usize{ 3, 4, 16 }) |order| {
        var r = try stress.run(testing.allocator, testing.io, .{
            .order = order,
            .puts_per_thread = 3000,
            .key_space = 5000,
            .preload = 200,
            .seed = 2 + order,
            .capacity = 16384,
            .abandon_splits = true,
        });
        // How many flags are left depends on the interleaving.
        r.incomplete_splits = 0;
        try testing.expectEqual(stress.Report{
            .keys = r.expected_keys,
            .expected_keys = r.expected_keys,
            .valid = true,
        }, r);
    }
}
