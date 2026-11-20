//! Tests of the B-link tree. Deterministic first: the interesting states of
//! a concurrent split are reached WITHOUT threads, through three hooks:
//!
//!   * `setAbandonSplits(true)` makes a writer stop between step 1 and step 2
//!     of a split, leaving the state a crashed or failed writer leaves;
//!   * `Descent.step` runs a search one node at a time, so a test can put a
//!     complete split between "read the parent" and "visit the child";
//!   * `putFrom` starts a writer at a former root and can pause it on its
//!     leaf (`Pause`), so a test can split, half-split or outgrow the
//!     parents that writer remembers before it climbs back up. It can also
//!     stop the writer between filling a new root and publishing it.
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
        // An overwrite needs no node. It still fails if a node on its path
        // (the root, an internal node or the leaf) is flagged, because the
        // writer must finish that split first: see the next test.
        if (tree.put(io, 0, 1)) |old| try testing.expectEqual(0, old) else |_| {}
        try tree.validate();
        try expectNoLatchHeld(&tree, io);
    }
    try testing.expect(saw_clean_failure);
    try testing.expect(saw_incomplete);
}

test "a full table: puts that need no node fail too when a flag on their path cannot be cleared" {
    const io = testing.io;
    {
        // Six nodes. put 10 splits leaf #4; its parent #2 is full and there
        // is no node left to split it, so #4 stays flagged.
        var tree = try BLinkTree.init(testing.allocator, 4, 6);
        defer tree.deinit(testing.allocator);
        for (1..11) |key| try testing.expectEqual(null, try tree.put(io, key, key * 100));
        const state =
            \\height 2, 10 keys, 6 nodes
            \\  level 1: #2[3 5 7]
            \\  level 0: #0(1 2)<3 -> #1(3 4)<5 -> #3(5 6)<7 -> #4(7 8)<9 {incomplete} -> #5(9 10) {no downlink}
            \\
        ;
        try expectDump(&tree, state);
        // Puts that do not come through #4 work: these are overwrites.
        for (1..7) |key| try testing.expectEqual(key * 100, try tree.put(io, key, key * 100));
        // Every put that is routed to #4 must finish its split first and
        // cannot: an overwrite (7 to 10) fails exactly like an insert (11),
        // although #5 has room for 11.
        for (7..12) |key| try testing.expectError(error.OutOfNodes, tree.put(io, key, 1));
        // Nothing was changed by the failed puts, and readers do not care.
        try expectDump(&tree, state);
        for (1..11) |key| try testing.expectEqual(key * 100, tree.get(io, key));
        try tree.validate();
        try expectNoLatchHeld(&tree, io);
    }
    {
        // Two nodes: the root leaf splits and there is no node for the new
        // root. Every put starts at the flagged root, so every put fails.
        var tree = try BLinkTree.init(testing.allocator, 4, 2);
        defer tree.deinit(testing.allocator);
        for (1..5) |key| try testing.expectEqual(null, try tree.put(io, key, key * 100));
        const state =
            \\height 1, 4 keys, 2 nodes
            \\  level 0: #0(1 2)<3 {incomplete} -> #1(3 4) {no downlink}
            \\
        ;
        try expectDump(&tree, state);
        for (1..6) |key| try testing.expectError(error.OutOfNodes, tree.put(io, key, 1));
        try expectDump(&tree, state);
        for (1..5) |key| try testing.expectEqual(key * 100, tree.get(io, key));
        try tree.validate();
        try expectNoLatchHeld(&tree, io);
    }
}

// ---------------------------------------------------------------------
// Stale WRITERS. A reader goes stale between two nodes; a writer goes stale
// between its way down and its way up: the parents it remembers may have
// split, been left half split, or stopped being the top of the tree. The
// second hook, `putFrom` with a `Pause`, stops one writer on its leaf and
// lets the test run other writers in that gap. Still one thread, no sleeps.
// ---------------------------------------------------------------------

/// Order 3 (two keys per node): a root with three FULL leaves, so that one
/// more key anywhere splits a leaf and the next split splits the root.
fn buildThreeFullLeaves(io: Io) !BLinkTree {
    var tree = try BLinkTree.init(testing.allocator, 3, 16);
    errdefer tree.deinit(testing.allocator);
    for ([_]u64{ 10, 20, 30, 40, 15, 25 }) |key| _ = try tree.put(io, key, key * 100);
    try expectDump(&tree,
        \\height 2, 6 keys, 4 nodes
        \\  level 1: #2[20 30]
        \\  level 0: #0(10 15)<20 -> #1(20 25)<30 -> #3(30 40)
        \\
    );
    return tree;
}

/// A put made by "another writer" while one writer is paused. A callback
/// cannot return an error, and none is possible with these table sizes.
fn otherPut(tree: *BLinkTree, io: Io, key: u64) void {
    _ = tree.put(io, key, key * 100) catch @panic("unexpected OutOfNodes in a paused-writer test");
}

test "a paused writer whose parent split meanwhile re-finds the downlink by moving right" {
    const io = testing.io;
    var tree = try buildThreeFullLeaves(io);
    defer tree.deinit(testing.allocator);

    const Others = struct {
        fn run(_: ?*anyopaque, t: *BLinkTree, io_: Io, leaf_id: NodeId, leaf: *const blink.Page) void {
            // The paused writer holds exactly its leaf, exclusively.
            std.debug.assert(leaf_id == id(3) and leaf.node.len == 2 and !t.slots[3].latch.tryLock(io_));
            // Another writer splits leaf #0. Its downlink overflows #2, the
            // node the paused writer remembers as "my parent" and as "the
            // root". #2 splits; the downlink to #3 moves into the new #5.
            otherPut(t, io_, 12);
        }
    };
    // put 32 goes down #2 -> #3 and is paused there. #3 is full: it will split.
    try testing.expectEqual(null, try tree.putFrom(io, tree.rootId(), 32, 3200, .{ .at_leaf = Others.run }));

    // Step 2 for #3 started at the remembered #2, did not find #3 among its
    // children, moved right to #5 and inserted (32, #7) there.
    try tree.validate();
    try expectDump(&tree,
        \\height 3, 8 keys, 8 nodes
        \\  level 2: #6[20]
        \\  level 1: #2[12]<20 -> #5[30 32]
        \\  level 0: #0(10)<12 -> #4(12 15)<20 -> #1(20 25)<30 -> #3(30)<32 -> #7(32 40)
        \\
    );
    try testing.expectEqual(0, tree.incompleteSplits());
    try expectAllFound(&tree, io, &.{ 10, 12, 15, 20, 25, 30, 32, 40 });
    try expectNoLatchHeld(&tree, io);
}

test "two paused writers, a half-split parent and a grown root: finish first, then find the parent level" {
    const io = testing.io;
    var tree = try buildThreeFullLeaves(io);
    defer tree.deinit(testing.allocator);

    // Three writers. The first is paused on leaf #0, the second on leaf #1,
    // and the third runs to the end while both stand still.
    const Third = struct {
        fn run(_: ?*anyopaque, t: *BLinkTree, io_: Io, _: NodeId, _: *const blink.Page) void {
            t.setAbandonSplits(true);
            otherPut(t, io_, 35); // leaf #3 splits, step 1 only: #3 -> #4
            // 31 is routed to the flagged #3. Finishing that split puts a
            // third key into the root #2, which splits, step 1 only.
            otherPut(t, io_, 31);
            t.setAbandonSplits(false);
            // #2 is still the root, is flagged, and has a right sibling #5
            // that nothing points down to. It is the one unfinished split.
            // (Counted from the statistics, as the Rust version must: its
            // `incomplete_splits()` latches every node, including the two
            // leaves the paused writers hold.)
            std.debug.assert(t.rootId() == id(2) and t.page(id(2)).incomplete_split);
            std.debug.assert(t.page(id(2)).right == id(5));
            std.debug.assert(t.stats().half_splits - t.stats().completed_splits == 1);
        }
    };
    const Second = struct {
        fn run(_: ?*anyopaque, t: *BLinkTree, io_: Io, _: NodeId, _: *const blink.Page) void {
            // put 22: paused on #1 while the third writer runs. Afterwards
            // #1 splits. Its remembered parent #2 is flagged: the split of
            // #2 is finished first (that builds the new root #7), and only
            // then does #2 receive the downlink (22, #6).
            _ = t.putFrom(io_, t.rootId(), 22, 2200, .{ .at_leaf = Third.run }) catch @panic("OutOfNodes");
            std.debug.assert(t.rootId() == id(7));
            std.debug.assert(t.stats().half_splits == t.stats().completed_splits);
            std.debug.assert(t.stats().finished_later == 2); // #3 by the third writer, #2 by the second
        }
    };
    // put 12: paused on #0. When it started, #2 was the root, so it remembers
    // no node above #2.
    try testing.expectEqual(null, try tree.putFrom(io, tree.rootId(), 12, 1200, .{ .at_leaf = Second.run }));

    // After the pause #0 splits. Its downlink is the third key for #2, so #2
    // splits again, and step 2 of THAT split has no remembered parent. #2 is
    // not the root any more: the parent level is found through level_head.
    try tree.validate();
    try expectDump(&tree,
        \\height 3, 10 keys, 10 nodes
        \\  level 2: #7[20 30]
        \\  level 1: #2[12]<20 -> #9[22]<30 -> #5[35]
        \\  level 0: #0(10)<12 -> #8(12 15)<20 -> #1(20)<22 -> #6(22 25)<30 -> #3(30 31)<35 -> #4(35 40)
        \\
    );
    try testing.expectEqual(0, tree.incompleteSplits());
    try expectAllFound(&tree, io, &.{ 10, 12, 15, 20, 22, 25, 30, 31, 35, 40 });
    try expectNoLatchHeld(&tree, io);
}

test "a writer that starts at an old root: moves right, then finds the parent level through level_head" {
    const io = testing.io;
    var tree = try BLinkTree.init(testing.allocator, 4, 8);
    defer tree.deinit(testing.allocator);
    for ([_]u64{ 1, 2, 3 }) |key| _ = try tree.put(io, key, key * 100);

    // A writer loads the root pointer: #0, a leaf. Before it latches
    // anything, two other puts split #0 and build the root #2.
    const old_root = tree.rootId();
    for ([_]u64{ 4, 5 }) |key| _ = try tree.put(io, key, key * 100);
    try testing.expectEqual(id(2), tree.rootId());
    try testing.expectEqual(id(0), tree.level_head[0]);

    // The writer continues from #0: move right to #1(3 4 5), which is full.
    // It splits. The writer came through no node of level 1 and #1 is not
    // the root, so step 2 starts at level_head[1]. It must NOT build a root.
    const before = tree.stats().moves_right;
    try testing.expectEqual(null, try tree.putFrom(io, old_root, 6, 600, null));
    try testing.expectEqual(1, tree.stats().moves_right - before);
    try tree.validate();
    try expectDump(&tree,
        \\height 2, 6 keys, 4 nodes
        \\  level 1: #2[3 5]
        \\  level 0: #0(1 2)<3 -> #1(3 4)<5 -> #3(5 6)
        \\
    );
    try expectAllFound(&tree, io, &.{ 1, 2, 3, 4, 5, 6 });
    try expectNoLatchHeld(&tree, io);
}

test "a root split fills the new root before it publishes it" {
    const io = testing.io;
    var tree = try BLinkTree.init(testing.allocator, 4, 8);
    defer tree.deinit(testing.allocator);
    for ([_]u64{ 1, 2, 3 }) |key| _ = try tree.put(io, key, key * 100);

    // Readers load the root pointer without a lock. The moment it changes,
    // a reader may be inside the new root, so the node must be complete
    // BEFORE the pointer is stored. The hook stands between the two and
    // writes down what a reader arriving at that moment would get.
    const Seen = struct {
        calls: usize = 0,
        root_pointer: NodeId = .nil,
        new_root_id: NodeId = .nil,
        new_root: blink.Page = undefined,

        fn rootBuilt(context: ?*anyopaque, t: *BLinkTree, new_root_id: NodeId, new_root: *const blink.Page) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.root_pointer = t.rootId();
            self.new_root_id = new_root_id;
            self.new_root = new_root.*;
        }
    };
    var seen: Seen = .{};
    // put 4 splits the root leaf #0 (new sibling #1) and builds the root #2.
    try testing.expectEqual(null, try tree.putFrom(io, tree.rootId(), 4, 400, .{ .context = &seen, .root_built = Seen.rootBuilt }));

    try testing.expectEqual(1, seen.calls);
    // Not published yet: a descent that starts now starts at the old root.
    try testing.expectEqual(id(0), seen.root_pointer);
    // And already complete: one separator, two children.
    try testing.expectEqual(id(2), seen.new_root_id);
    try testing.expectEqual(1, seen.new_root.level);
    try testing.expectEqualSlices(u64, &.{3}, seen.new_root.node.keySlice());
    try testing.expectEqualSlices(NodeId, &.{ id(0), id(1) }, seen.new_root.node.childSlice());

    // Afterwards it is the root.
    try testing.expectEqual(id(2), tree.rootId());
    try tree.validate();
    try expectAllFound(&tree, io, &.{ 1, 2, 3, 4 });
    try expectNoLatchHeld(&tree, io);
}

test "moving right on an INTERNAL level: a stale reader and a stale writer" {
    const io = testing.io;
    var tree = try buildCanonical(io, 32);
    defer tree.deinit(testing.allocator);
    // #6 = [20 26 28] is full, and so is its last leaf #9(28 30 32).
    for ([_]u64{ 26, 27, 28, 32 }) |key| _ = try tree.put(io, key, key * 100);

    // The reader reads the root and is told "#6". It holds nothing.
    var reader = Descent.begin(&tree, 32, .follow_right_links);
    try testing.expectEqual(id(6), reader.step(&tree, io).descended.to);
    // put 31 splits leaf #9, and that splits #6 into #6[20 26]<28 -> #11[31].
    _ = try tree.put(io, 31, 3100);
    try expectDump(&tree,
        \\height 3, 17 keys, 12 nodes
        \\  level 2: #7[15 28]
        \\  level 1: #2[6 10]<15 -> #6[20 26]<28 -> #11[31]
        \\  level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25)<26 -> #8(26 27)<28 -> #9(28 30)<31 -> #10(31 32)
        \\
    );
    // The reader's next node is the INTERNAL node #6, and 32 >= 28.
    const moved = reader.step(&tree, io).moved_right;
    try testing.expectEqual(id(6), moved.from);
    try testing.expectEqual(1, tree.page(moved.from).level);
    try testing.expectEqual(id(11), moved.to);
    try testing.expectEqual(id(10), reader.step(&tree, io).descended.to);
    try testing.expectEqual(3200, reader.step(&tree, io).done.value);
    try testing.expectEqual(1, reader.moves_right);

    // A writer that loaded the root pointer when #2 was the root (it is the
    // leftmost node of level 1): two hops on level 1, none on the leaves.
    // Without the internal hops it would still arrive, by descending from
    // #2 into leaf #1 and walking five leaves to the right: moving right on
    // the leaf level is what makes the search correct, moving right on the
    // internal levels is what keeps the walk short.
    try testing.expectEqual(id(2), tree.level_head[1]);
    const before = tree.stats().moves_right;
    try testing.expectEqual(null, try tree.putFrom(io, id(2), 33, 3300, null));
    try testing.expectEqual(2, tree.stats().moves_right - before);
    try testing.expectEqual(3300, tree.get(io, 33));
    try tree.validate();
}

/// State of the seeded test below, handed to the callback as `context`.
const PausedModel = struct {
    const key_space = 300;
    rng: SplitMix64,
    present: [key_space]bool = @splat(false),
    /// Puts the other writers make during the next pause.
    others: usize = 0,
    hook_runs: usize = 0,

    fn value(key: u64) u64 {
        return key * 100 + 1;
    }

    fn put(self: *PausedModel, tree: *BLinkTree, io: Io, key: u64) void {
        _ = tree.put(io, key, value(key)) catch @panic("unexpected OutOfNodes in a paused-writer test");
        self.present[key] = true;
    }

    fn atLeaf(context: ?*anyopaque, tree: *BLinkTree, io: Io, leaf_id: NodeId, leaf: *const blink.Page) void {
        const self: *PausedModel = @ptrCast(@alignCast(context.?));
        self.hook_runs += 1;
        // The key range of the latched leaf: its lower bound is the high key
        // of its left neighbour, found by walking the leaf level.
        var low: u64 = 0;
        var at = tree.level_head[0];
        while (at != leaf_id) : (at = tree.page(at).right) low = tree.page(at).high_key.?;
        const high = leaf.high_key orelse std.math.maxInt(u64);
        for (0..self.others) |_| {
            const key = self.rng.below(key_space);
            if (key >= low and key < high) continue; // would wait for the paused writer
            tree.setAbandonSplits(self.rng.chance(1, 2));
            self.put(tree, io, key);
        }
        tree.setAbandonSplits(false);
    }
};

test "model test with paused writers: stale parents, flagged parents, old roots, seeded" {
    const io = testing.io;
    var level_head_starts: usize = 0;
    for ([_]usize{ 3, 4, 5 }) |order| {
        for (1..41) |seed| {
            var tree = try BLinkTree.init(testing.allocator, order, 1024);
            defer tree.deinit(testing.allocator);
            var model: PausedModel = .{ .rng = SplitMix64.init(seed * 977 + order) };
            for (0..model.rng.below(40)) |_| {
                tree.setAbandonSplits(model.rng.chance(1, 3));
                model.put(&tree, io, model.rng.below(PausedModel.key_space));
            }
            tree.setAbandonSplits(false);
            for (0..25) |_| {
                const key = model.rng.below(PausedModel.key_space);
                // Start at the root, or at any node that was the root once.
                const level = model.rng.below(tree.height);
                if (level + 1 < tree.height) level_head_starts += 1;
                model.others = model.rng.below(25);
                _ = try tree.putFrom(io, tree.level_head[level], key, PausedModel.value(key), .{
                    .context = &model,
                    .at_leaf = PausedModel.atLeaf,
                });
                model.present[key] = true;
                try tree.validate();
                for (model.present, 0..) |present, k| {
                    try testing.expectEqual(@as(?u64, if (present) PausedModel.value(k) else null), tree.get(io, k));
                }
                try expectNoLatchHeld(&tree, io);
            }
            try testing.expectEqual(25, model.hook_runs);
        }
    }
    try testing.expect(level_head_starts > 0);
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
