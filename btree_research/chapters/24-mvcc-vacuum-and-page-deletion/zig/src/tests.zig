//! Tests of the whole model: fixed scenarios for every mechanism, the two
//! page-deletion tests the chapter is built around, allocation failure, a
//! seeded model test against the oracle, and proof that `validate` catches
//! corruption. (The base_* files and store.zig carry their own unit tests.)
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const db_ = @import("db.zig");
const Db = db_.Db;
const Cursor = db_.Cursor;
const NodeId = @import("base_arena.zig").NodeId;
const node = @import("base_node.zig");
const dump = @import("dump.zig");
const ops = @import("ops.zig");

const everything = std.math.maxInt(u64);

fn expectDump(expected: []const u8, db: *const Db) !void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump.dump(db, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

/// Keys of a full scan under a snapshot opened (and closed) for it.
fn expectKeys(expected: []const u64, db: *Db) !void {
    const s = try db.store.openSnapshot();
    defer db.store.closeSnapshot(s);
    var cursor = Cursor.seek(db, s, 0, everything);
    for (expected) |k| try testing.expectEqual(k, (try cursor.next(db)).?.key);
    try testing.expectEqual(null, try cursor.next(db));
}

/// Rows 10..120, rows 30..80 deleted, entries vacuumed, empty pages kept:
///   #0(10 20) -> #1() -> #3() -> #4() -> #5(90 100) -> #8(110 120)
/// with #1 and #3 under internal page #2 and #4 the first child of #6.
fn buildWithEmptyLeaves(gpa: Allocator) !Db {
    var db: Db = .init(4);
    errdefer db.deinit(gpa);
    var key: u64 = 10;
    while (key <= 120) : (key += 10) _ = try db.put(gpa, key, key * 10);
    key = 30;
    while (key <= 80) : (key += 10) _ = db.delete(key);
    try testing.expectEqual(6, db.vacuum(.{ .delete_pages = false }).entries_removed);
    try db.validate();
    return db;
}

fn id(i: usize) NodeId {
    return .fromIndex(i);
}

test "a snapshot keeps seeing the versions that existed when it was taken" {
    const gpa = testing.allocator;
    var db: Db = .init(4);
    defer db.deinit(gpa);
    try testing.expectEqual(null, try db.put(gpa, 1, 100));
    try testing.expectEqual(null, try db.put(gpa, 2, 200));
    const old = try db.store.openSnapshot();
    try testing.expectEqual(100, try db.put(gpa, 1, 101)); // update
    try testing.expectEqual(200, db.delete(2));
    try testing.expectEqual(null, try db.put(gpa, 3, 300)); // insert
    try testing.expectEqual(null, db.delete(2)); // already deleted
    const new = try db.store.openSnapshot();

    try testing.expectEqual(100, try db.get(old, 1));
    try testing.expectEqual(200, try db.get(old, 2));
    try testing.expectEqual(null, try db.get(old, 3));
    try testing.expectEqual(101, try db.get(new, 1));
    try testing.expectEqual(null, try db.get(new, 2));
    try testing.expectEqual(300, try db.get(new, 3));
    // An update added an entry; a delete removed none: 4 entries for 2 rows.
    try testing.expectEqual(4, db.index.count);
    try db.validate();
    db.store.closeSnapshot(old);
    db.store.closeSnapshot(new);
}

test "hints are set only for versions dead to everyone, and save heap visits" {
    const gpa = testing.allocator;
    var db: Db = .init(8);
    defer db.deinit(gpa);
    for (1..6) |k| _ = try db.put(gpa, k, k);
    const old = try db.store.openSnapshot();
    _ = db.delete(2);
    _ = db.delete(4);
    const new = try db.store.openSnapshot();

    // `old` still sees rows 2 and 4, so they are invisible to `new` but not dead.
    var cursor = Cursor.seek(&db, new, 0, everything);
    while (try cursor.next(&db)) |_| {}
    try testing.expectEqual(0, db.reads.hints_set);
    try testing.expectEqual(5, db.reads.heap_fetches);

    db.store.closeSnapshot(old);
    cursor = Cursor.seek(&db, new, 0, everything);
    while (try cursor.next(&db)) |_| {}
    try testing.expectEqual(2, db.reads.hints_set);
    try testing.expectEqual(10, db.reads.heap_fetches);
    try db.validate(); // includes "no hint lies"

    cursor = Cursor.seek(&db, new, 0, everything);
    while (try cursor.next(&db)) |_| {}
    try testing.expectEqual(2, db.reads.hint_skips);
    try testing.expectEqual(13, db.reads.heap_fetches); // 3 this time, not 5
    db.store.closeSnapshot(new);
}

test "a full leaf drops hinted entries instead of splitting (simple deletion)" {
    const gpa = testing.allocator;
    var db: Db = .init(4);
    defer db.deinit(gpa);
    db.index.bottom_up = false; // isolate the hint path
    for ([_]u64{ 10, 20, 30 }) |k| _ = try db.put(gpa, k, k);
    _ = db.delete(20);
    // Without a hint the insert cannot know that 20 is garbage: it splits.
    _ = try db.put(gpa, 40, 40);
    try testing.expectEqual(1, db.index.stats.leaf_splits);
    try expectKeys(&.{ 10, 30, 40 }, &db); // this scan hints the entry of 20
    try testing.expectEqual(1, db.reads.hints_set);
    // 20 sits in the left leaf (10, 20): fill it and insert once more.
    _ = try db.put(gpa, 12, 12);
    _ = try db.put(gpa, 14, 14);
    try testing.expectEqual(1, db.index.stats.simple_deleted);
    try testing.expectEqual(1, db.index.stats.splits_avoided);
    try testing.expectEqual(1, db.index.stats.leaf_splits);
    try expectKeys(&.{ 10, 12, 14, 30, 40 }, &db);
    try db.validate();
}

test "bottom-up deletion absorbs version churn unless a snapshot needs the versions" {
    const gpa = testing.allocator;
    var db: Db = .init(4);
    defer db.deinit(gpa);
    for (0..50) |i| _ = try db.put(gpa, 7, i); // 50 versions of one row
    try testing.expectEqual(0, db.index.stats.leaf_splits);
    try testing.expectEqual(1, db.index.nodes.liveCount());
    try testing.expect(db.index.stats.bottom_up_deleted > 0);
    // Version slots are reused too: the store never held more than 3 at once.
    try testing.expectEqual(3, db.store.versions.slotCount());

    const pin = try db.store.openSnapshot();
    for (50..60) |i| _ = try db.put(gpa, 7, i);
    try testing.expect(db.index.stats.leaf_splits > 0); // nothing was removable
    try testing.expectEqual(49, try db.get(pin, 7));
    db.store.closeSnapshot(pin);
    try db.validate();
}

test "vacuum removes exactly what the oldest snapshot cannot see" {
    const gpa = testing.allocator;
    var db: Db = .init(4);
    defer db.deinit(gpa);
    for (1..10) |k| _ = try db.put(gpa, k, k);
    const pin = try db.store.openSnapshot();
    for (1..10) |k| _ = db.delete(k);
    try testing.expectEqual(0, db.vacuum(.{}).entries_removed);
    try testing.expectEqual(9, db.index.count);
    var cursor = Cursor.seek(&db, pin, 0, everything);
    for (1..10) |k| try testing.expectEqual(k, (try cursor.next(&db)).?.key);

    db.store.closeSnapshot(pin);
    const report = db.vacuum(.{});
    try testing.expectEqual(9, report.entries_removed);
    try testing.expectEqual(0, db.index.count);
    try testing.expectEqual(0, db.store.versions.liveCount());
    try testing.expectEqual(report.pages_unlinked, report.pages_recycled);
    try testing.expectEqual(0, report.pages_waiting);
    try expectKeys(&.{}, &db);
    try db.validate();
}

test "page deletion: phase 1 rewires the parent, phase 2 the sibling chain" {
    const gpa = testing.allocator;
    var db = try buildWithEmptyLeaves(gpa);
    defer db.deinit(gpa);
    try expectDump(
        \\now=18 horizon=18 | height 3, 6 entries, 9 pages
        \\  level 0: #7[70.6]
        \\  level 1: #2[30.2 50.4] #6[90.8 110.10]
        \\  leaves : #0(10:1- 20:2-) -> #1() -> #3() -> #4() -> #5(90:9- 100:10-) -> #8(110:11- 120:12-)
        \\
    , &db);

    // Not allowed: non-empty, rightmost child of its parent, internal, root, nil.
    for ([_]NodeId{ id(0), id(3), id(8), id(2), id(7), .nil }) |bad| {
        try testing.expect(!db.index.markHalfDead(bad));
    }

    try testing.expect(db.index.markHalfDead(id(1)));
    try testing.expect(!db.index.markHalfDead(id(1))); // not twice
    // Slot 1 of #2 now points at #3 and separator 50 is gone: #3 inherited
    // the key range of #1 and no key in any leaf was touched.
    try testing.expectEqualSlices(NodeId, &.{ id(0), id(3) }, db.index.nodes.get(id(2)).childSlice());
    try testing.expectEqual(id(3), db.index.findLeaf(node.packLow(35)));
    try testing.expectEqual(id(1), db.index.nodes.get(id(0)).kind.leaf.next); // still chained
    try db.validate();

    db.index.unlinkHalfDead(&db.store, db.index.leftSibling(id(1)), id(1));
    try expectDump(
        \\now=19 horizon=19 | height 3, 6 entries, 9 pages
        \\  level 0: #7[70.6]
        \\  level 1: #2[30.2] #6[90.8 110.10]
        \\  leaves : #0(10:1- 20:2-) -> #3() -> #4() -> #5(90:9- 100:10-) -> #8(110:11- 120:12-)
        \\  deleted: #1@19->#3
        \\
    , &db);
    try db.validate();
    try testing.expectEqual(1, db.index.recycle(db.store.horizon()));
    try testing.expectEqual(8, db.index.nodes.liveCount());
    try db.validate();
}

test "a scan about to step onto a page that is then deleted moves right safely" {
    const gpa = testing.allocator;
    var db = try buildWithEmptyLeaves(gpa);
    defer db.deinit(gpa);

    // The scan reads leaf #0 and remembers its right link, #1.
    const s = try db.store.openSnapshot();
    var cursor = Cursor.seek(&db, s, 0, everything);
    try testing.expectEqual(10, (try cursor.next(&db)).?.key);
    try testing.expectEqual(20, (try cursor.next(&db)).?.key);
    try testing.expectEqual(id(1), cursor.next_leaf);

    // While it is paused, VACUUM deletes #1 (and #4) in both phases.
    const report = db.vacuum(.{});
    try testing.expectEqual(2, report.pages_unlinked);
    // ... but may not recycle them: snapshot s is older than their stamps.
    try testing.expectEqual(0, report.pages_recycled);
    try testing.expectEqual(2, report.pages_waiting);
    try testing.expectEqual(0, db.index.recycle(db.store.horizon()));
    try testing.expect(s < db.index.nodes.get(id(1)).kind.leaf.state.deleted);
    try db.validate();

    // Writers keep going; their splits must grow the array, not reuse #1.
    const slots = db.index.nodes.slotCount();
    for ([_]u64{ 11, 12, 13, 14 }) |k| _ = try db.put(gpa, k, k);
    try testing.expect(db.index.nodes.slotCount() > slots);
    try testing.expectEqual(0, db.index.stats.pages_reused);

    // The scan follows its stale link, finds a deleted page whose own right
    // link is intact, and moves right. Nothing is missed or repeated.
    for ([_]u64{ 90, 100, 110, 120 }) |k| try testing.expectEqual(k, (try cursor.next(&db)).?.key);
    try testing.expectEqual(null, try cursor.next(&db));
    try testing.expect(db.reads.moved_right >= 1);

    // Once the snapshot is gone the pages are recycled, and the next split
    // reuses one of them instead of growing the page array.
    db.store.closeSnapshot(s);
    try testing.expectEqual(2, db.index.recycle(db.store.horizon()));
    try testing.expectEqual(2, db.index.nodes.freeCount());
    const slots_after = db.index.nodes.slotCount();
    for ([_]u64{ 91, 92 }) |k| _ = try db.put(gpa, k, k);
    try testing.expectEqual(1, db.index.stats.pages_reused);
    try testing.expectEqual(slots_after, db.index.nodes.slotCount());
    try expectKeys(&.{ 10, 11, 12, 13, 14, 20, 90, 91, 92, 100, 110, 120 }, &db);
    try db.validate();
}

test "recycling a deleted page too early breaks the same scan" {
    const gpa = testing.allocator;
    var db = try buildWithEmptyLeaves(gpa);
    defer db.deinit(gpa);
    const s = try db.store.openSnapshot();
    defer db.store.closeSnapshot(s);
    var cursor = Cursor.seek(&db, s, 0, everything);
    _ = try cursor.next(&db);
    _ = try cursor.next(&db); // 10, 20; paused before #1

    try testing.expect(db.index.markHalfDead(id(1)));
    db.index.unlinkHalfDead(&db.store, id(0), id(1));
    try testing.expectEqual(0, db.index.recycle(db.store.horizon())); // the rule says no
    try testing.expectEqual(1, db.index.recycleIgnoringSnapshots()); // the bug

    // Failure 1: the page is on the free list; the link points at nothing.
    var early = cursor;
    try testing.expectError(error.DanglingLink, early.next(&db));

    // Failure 2 (worse): a split at the far right end reuses page #1. The
    // scan lands in the middle of somebody else's keys, returns the one row
    // its snapshot can see there, and never visits #5 and #8.
    for ([_]u64{ 111, 112 }) |k| _ = try db.put(gpa, k, k);
    try testing.expectEqual(1, db.index.stats.pages_reused);
    try testing.expectEqual(120, (try cursor.next(&db)).?.key);
    try testing.expectEqual(null, try cursor.next(&db)); // 90, 100, 110 lost
    try db.validate(); // the TREE is fine; only the reader was betrayed
}

test "a deletion interrupted after phase 1 is harmless and finished by the next vacuum" {
    const gpa = testing.allocator;
    var db = try buildWithEmptyLeaves(gpa);
    defer db.deinit(gpa);
    try testing.expect(db.index.markHalfDead(id(1)));
    try db.validate();
    // Scans skip the half-dead page; inserts into its old key range go to
    // the right sibling, because the parent no longer points at it.
    try expectKeys(&.{ 10, 20, 90, 100, 110, 120 }, &db);
    _ = try db.put(gpa, 35, 350);
    try testing.expectEqual(0, db.index.nodes.get(id(1)).len);
    try testing.expectEqual(1, db.index.nodes.get(id(3)).len);
    try expectKeys(&.{ 10, 20, 35, 90, 100, 110, 120 }, &db);

    const report = db.vacuum(.{});
    try testing.expectEqual(2, report.pages_unlinked); // #1 finished, #4 start to end
    try testing.expectEqual(2, report.pages_recycled);
    try db.validate();
}

test "the leftmost leaf can be deleted; the chain gets a new head" {
    const gpa = testing.allocator;
    var db: Db = .init(4);
    defer db.deinit(gpa);
    for (1..9) |k| _ = try db.put(gpa, k, k);
    _ = db.delete(1);
    _ = db.delete(2);
    const head = db.index.first_leaf;
    const report = db.vacuum(.{});
    try testing.expectEqual(1, report.pages_unlinked);
    try testing.expect(db.index.first_leaf != head);
    try testing.expect(!db.index.nodes.isLive(head));
    try expectKeys(&.{ 3, 4, 5, 6, 7, 8 }, &db);
    try testing.expectEqual(null, db.delete(1));
    _ = try db.put(gpa, 1, 11); // lands in the new head
    try expectKeys(&.{ 1, 3, 4, 5, 6, 7, 8 }, &db);
    try db.validate();
}

test "put under allocation failure changes nothing" {
    // Fail the 1st, 2nd, 3rd ... allocation of the whole workload in turn.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();
        var db: Db = .init(4);
        defer db.deinit(gpa);
        var failed = false;
        for (0..40) |i| {
            const key = (i * 7) % 20;
            const entries = db.index.count;
            const now = db.store.now;
            if (db.put(gpa, key, i)) |_| {} else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                // Not even the transaction counter moved.
                try testing.expectEqual(entries, db.index.count);
                try testing.expectEqual(now, db.store.now);
                failed = true;
                break;
            }
        }
        try db.validate();
        if (!failed) break; // the workload needs fewer than fail_index allocations
    }
    try testing.expect(fail_index > 2);
}

test "model: random operations with a long-lived snapshot match the oracle" {
    const gpa = testing.allocator;
    for ([_]usize{ 3, 4, 5, 16 }) |order| {
        var db: Db = .init(order);
        defer db.deinit(gpa);
        db.index.bottom_up = order != 5; // one run without it
        var oracle: ops.Oracle = .{};
        defer oracle.deinit(gpa);
        var frozen: std.ArrayList(ops.Entry) = .empty;
        defer frozen.deinit(gpa);
        var long: ?u64 = null;
        var stream = ops.OpStream.init(.{ .seed = 0xC0FFEE + order, .count = 6000, .key_space = 150 });
        var step: usize = 0;
        while (stream.next()) |op| : (step += 1) {
            switch (op) {
                .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try db.put(gpa, p.key, p.value)),
                .delete => |d| try testing.expectEqual(oracle.delete(d.key), db.delete(d.key)),
                .get => |g| {
                    const s = try db.store.openSnapshot();
                    defer db.store.closeSnapshot(s);
                    try testing.expectEqual(oracle.get(g.key), try db.get(s, g.key));
                },
                .range => |r| {
                    const s = try db.store.openSnapshot();
                    defer db.store.closeSnapshot(s);
                    try expectScan(&db, s, r.lo, r.hi, oracle.range(r.lo, r.hi));
                },
            }
            if (step % 300 == 50) {
                long = try db.store.openSnapshot();
                frozen.clearRetainingCapacity();
                try frozen.appendSlice(gpa, oracle.entries.items);
            }
            if (step % 300 == 250) {
                try expectScan(&db, long.?, 0, 150, frozen.items);
                db.store.closeSnapshot(long.?);
                long = null;
            }
            if (step % 97 == 96) _ = db.vacuum(.{});
            if (step % 50 == 49) try db.validate();
        }
        if (long) |s| db.store.closeSnapshot(s);
        try testing.expect(db.index.stats.pages_recycled > 0 or order == 16);
        try testing.expect(db.index.stats.vacuum_deleted > 0);

        // Delete every row and vacuum: every entry and every version is
        // reclaimed, and only the pages the rules protect remain.
        for (0..150) |k| _ = db.delete(k);
        const report = db.vacuum(.{});
        try testing.expectEqual(0, db.index.count);
        try testing.expectEqual(0, db.store.versions.liveCount());
        try testing.expectEqual(0, report.pages_waiting);
        try db.validate();
        // Reclaimed slots are reused: loading the rows again needs no more
        // version slots and no more pages than the arenas already hold.
        const version_slots = db.store.versions.slotCount();
        const page_slots = db.index.nodes.slotCount();
        for (oracle.entries.items) |e| _ = try db.put(gpa, e.key, e.value);
        try testing.expectEqual(version_slots, db.store.versions.slotCount());
        try testing.expectEqual(page_slots, db.index.nodes.slotCount());
        try db.validate();
    }
    // `testing.allocator` now checks that deinit released every byte,
    // including pages that were still half-dead, deleted or on a free list.
}

fn expectScan(db: *Db, snapshot: u64, lo: u64, hi: u64, expected: []const ops.Entry) !void {
    var cursor = Cursor.seek(db, snapshot, lo, hi);
    for (expected) |e| {
        const row = (try cursor.next(db)).?;
        try testing.expectEqual(e.key, row.key);
        try testing.expectEqual(e.value, row.value);
    }
    try testing.expectEqual(null, try cursor.next(db));
}

test "validate names the broken invariant" {
    const gpa = testing.allocator;
    var db = try buildWithEmptyLeaves(gpa);
    defer db.deinit(gpa);
    const leaf0 = db.index.nodes.ptr(id(0));

    leaf0.kind.leaf.dead[0] = true; // row 10 is alive
    try testing.expectError(error.LyingHint, db.validate());
    leaf0.kind.leaf.dead[0] = false;

    const key0 = leaf0.keys[0];
    leaf0.keys[0] = node.pack(10, id(1)); // tid of row 20
    try testing.expectError(error.DanglingTid, db.validate());
    leaf0.keys[0] = key0;

    leaf0.kind.leaf.next = id(3); // chain skips #1, the tree does not
    try testing.expectError(error.BrokenLeafChain, db.validate());
    leaf0.kind.leaf.next = id(1);

    db.index.nodes.ptr(id(1)).kind.leaf.state = .half_dead; // still has a downlink
    try testing.expectError(error.DeadPageInTree, db.validate());
    db.index.nodes.ptr(id(1)).kind.leaf.state = .live;

    db.store.versions.ptr(node.tidOf(key0)).xmin = 99; // from the future
    try testing.expectError(error.BadTimestamp, db.validate());
    db.store.versions.ptr(node.tidOf(key0)).xmin = 1;
    try db.validate();
}
