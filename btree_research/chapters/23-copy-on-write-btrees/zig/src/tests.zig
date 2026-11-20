//! Tests of the whole database: path copying, snapshots, deferred reuse,
//! abort, the metapage, seeded model tests with snapshots, allocation
//! failure, and proof that `validate` catches corruption.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const base_node = @import("base_node.zig");
const PageId = base_node.PageId;
const db_ = @import("db.zig");
const Db = db_.Db;
const Snapshot = db_.Snapshot;
const View = @import("read.zig").View;
const Meta = @import("meta.zig").Meta;
const validate = @import("validate.zig").validate;
const dump = @import("dump.zig");
const ops = @import("ops.zig");

const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };
const max_key = std.math.maxInt(u64);

fn buildCanonical(gpa: Allocator) !Db {
    var db: Db = .init(4);
    errdefer db.deinit(gpa);
    for (canonical) |k| _ = try db.put(gpa, k, k * 100);
    return db;
}

fn expectDump(expected: []const u8, view: View, txn_id: u64) !void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try dump.dump(view, txn_id, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

fn expectKeys(expected: []const u64, view: View) !void {
    var it = view.range(0, max_key);
    for (expected) |k| try testing.expectEqual(k, it.next().?.key);
    try testing.expectEqual(null, it.next());
}

fn expectEntries(expected: []const ops.Entry, view: View, lo: u64, hi: u64) !void {
    var it = view.range(lo, hi);
    for (expected) |e| {
        const got = it.next() orelse return error.TestExpectedEqual;
        try testing.expectEqual(e.key, got.key);
        try testing.expectEqual(e.value, got.value);
    }
    try testing.expectEqual(null, it.next());
}

fn reachable(gpa: Allocator, db: *const Db, view: View) ![]bool {
    const marks = try gpa.alloc(bool, db.store.pageCount());
    @memset(marks, false);
    dump.markReachable(view, marks);
    return marks;
}

// ------------------------------------------------------ fixed scenarios

test "canonical example has the shape shown in the README" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);
    try validate(&db, gpa);
    try expectDump(
        \\txn 12: root #9, height 3, 12 keys
        \\  level 0: #9[15]
        \\  level 1: #4[6 10] #8[20]
        \\  leaves : #3(1 3 5) #6(6 7) #0(10 12) | #7(15 17) #1(20 25 30)
        \\
    , db.view(), db.current.txn_id);
    for (canonical) |k| try testing.expectEqual(k * 100, db.get(k).?);
    try testing.expectEqual(null, db.get(13));
}

test "a put copies exactly the root-to-leaf path and shares the rest" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);
    const snap = try db.snapshot(gpa);

    var txn = db.begin(gpa);
    _ = try txn.put(13, 1300);
    const info = try txn.commit(gpa);
    try testing.expectEqual(3, info.copied); // height 3: root, internal, leaf
    try testing.expectEqual(3, info.freed);
    try testing.expectEqual(0, info.released); // the snapshot still needs them

    const old = try reachable(gpa, &db, snap.view(&db));
    defer gpa.free(old);
    const new = try reachable(gpa, &db, db.view());
    defer gpa.free(new);
    var shared: usize = 0;
    var only_old: usize = 0;
    var only_new: usize = 0;
    for (old, new) |o, n| {
        if (o and n) shared += 1;
        if (o and !n) only_old += 1;
        if (n and !o) only_new += 1;
    }
    try testing.expectEqual(5, shared); // 8 pages minus the path of 3
    try testing.expectEqual(3, only_old);
    try testing.expectEqual(3, only_new);

    // The old tree is byte for byte what it was.
    try expectDump(
        \\txn 12: root #9, height 3, 12 keys
        \\  level 0: #9[15]
        \\  level 1: #4[6 10] #8[20]
        \\  leaves : #3(1 3 5) #6(6 7) #0(10 12) | #7(15 17) #1(20 25 30)
        \\
    , snap.view(&db), snap.id);
    try validate(&db, gpa);
    _ = db.release(snap);
    try validate(&db, gpa);
}

test "a snapshot keeps reading its own version across later commits" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);
    const snap = try db.snapshot(gpa);

    _ = try db.put(gpa, 13, 1300);
    _ = try db.put(gpa, 10, 1); // overwrite
    _ = try db.delete(gpa, 5);
    for (40..80) |k| _ = try db.put(gpa, k, k);
    for (canonical) |k| _ = try db.delete(gpa, k);
    try validate(&db, gpa);

    try testing.expectEqual(null, snap.view(&db).get(13));
    try testing.expectEqual(1000, snap.view(&db).get(10).?);
    try testing.expectEqual(500, snap.view(&db).get(5).?);
    try expectKeys(&.{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 }, snap.view(&db));
    try testing.expectEqual(null, db.get(10));
    try testing.expectEqual(41, db.len());
    _ = db.release(snap);
    try validate(&db, gpa);
    try testing.expectEqual(0, db.pending.items.len);
}

test "freed pages are reused only after the snapshots that need them are gone" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);

    // Without a snapshot the pages a commit replaces are free right away,
    // and the store stops growing.
    // (One warm-up commit: a path of 3 needs 3 free pages, the build left 2.)
    _ = try db.put(gpa, 10, 0);
    const pages_before = db.store.pageCount();
    for (0..20) |i| _ = try db.put(gpa, 10, i);
    try testing.expectEqual(pages_before, db.store.pageCount());
    try testing.expectEqual(0, db.pending.items.len);

    // With a snapshot nothing it might reach is reused: the store grows.
    const snap = try db.snapshot(gpa);
    const second = db.retain(snap);
    for (0..20) |i| _ = try db.put(gpa, 10, i);
    try testing.expect(db.store.pageCount() > pages_before);
    try testing.expectEqual(60, db.pending.items.len); // 20 commits x path of 3
    try validate(&db, gpa);

    // Refcount: the root stays pinned until the last handle is released.
    try testing.expectEqual(0, db.release(snap));
    try testing.expectEqual(60, db.pending.items.len);
    try testing.expectEqual(60, db.release(second));
    try testing.expectEqual(0, db.pending.items.len);
    try validate(&db, gpa);

    const pages_after = db.store.pageCount();
    for (0..20) |i| _ = try db.put(gpa, 10, i);
    try testing.expectEqual(pages_after, db.store.pageCount());
}

test "the oldest snapshot holds back every later free, a newer one does not" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);

    const old = try db.snapshot(gpa); // txn 12
    _ = try db.put(gpa, 13, 1300); // txn 13 frees 3 pages
    const young = try db.snapshot(gpa); // txn 13
    _ = try db.put(gpa, 14, 1400); // txn 14 frees 3 pages
    try testing.expectEqual(6, db.pending.items.len);

    // Releasing the YOUNGER snapshot frees nothing: the pages freed by txn
    // 14 are only needed by it, but the rule is "older than T", and the
    // snapshot of txn 12 is older than 14.
    try testing.expectEqual(0, db.release(young));
    try validate(&db, gpa);
    try testing.expectEqual(6, db.release(old));
    try validate(&db, gpa);
}

test "abort leaves the store, the meta slots and the free list untouched" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);
    const meta_before = db.store.meta_slots;
    const free_before = try gpa.dupe(PageId, db.store.free.items);
    defer gpa.free(free_before);
    const pages_before = db.store.pageCount();

    var txn = db.begin(gpa);
    for (100..140) |k| _ = try txn.put(k, k);
    _ = try txn.delete(10);
    try testing.expectEqual(51, txn.view().count);
    try testing.expectEqual(null, db.get(100)); // not visible outside
    txn.abort();

    try testing.expectEqual(meta_before, db.store.meta_slots);
    try testing.expectEqualSlices(PageId, free_before, db.store.free.items);
    try testing.expectEqual(pages_before, db.store.pageCount());
    try testing.expectEqual(1000, db.get(10).?);
    try testing.expectEqual(12, db.len());
    try validate(&db, gpa);
}

test "a transaction copies a page at most once and reads its own writes" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);

    var txn = db.begin(gpa);
    // Three overwrites in the same leaf: one path copy, not three.
    _ = try txn.put(1, 11);
    _ = try txn.put(3, 33);
    _ = try txn.put(5, 55);
    try testing.expectEqual(3, txn.info.copied);
    try testing.expectEqual(33, txn.get(3).?);
    try testing.expectEqual(300, db.get(3).?);
    const info = try txn.commit(gpa);
    try testing.expectEqual(13, info.txn_id); // one commit, one new root
    try testing.expectEqual(33, db.get(3).?);
    try validate(&db, gpa);

    // A transaction that changes nothing publishes nothing.
    var idle = db.begin(gpa);
    try testing.expectEqual(null, try idle.delete(999));
    try testing.expectEqual(0, (try idle.commit(gpa)).txn_id);
    try testing.expectEqual(13, db.current.txn_id);
}

test "deleting everything returns to the empty tree and all pages are reusable" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);
    for (canonical) |k| {
        try testing.expectEqual(k * 100, (try db.delete(gpa, k)).?);
        try validate(&db, gpa);
    }
    try testing.expectEqual(PageId.nil, db.current.root);
    try testing.expectEqual(0, db.len());
    try testing.expectEqual(db.store.pageCount(), db.store.free.items.len);
    try testing.expectEqual(null, db.get(10));
    var it = db.range(0, max_key);
    try testing.expectEqual(null, it.next());
    _ = try db.put(gpa, 7, 70);
    try testing.expectEqual(70, db.get(7).?);
    try validate(&db, gpa);
}

test "range uses the stack to cross leaf and subtree boundaries" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);
    var it = db.range(7, 21); // starts mid-leaf, crosses the root separator 15
    for ([_]u64{ 7, 10, 12, 15, 17, 20 }) |k| try testing.expectEqual(k, it.next().?.key);
    try testing.expectEqual(null, it.next());
    try testing.expectEqual(null, it.next()); // stays finished
    var empty = db.range(31, 99);
    try testing.expectEqual(null, empty.next());
    var gap = db.range(8, 10); // nothing in [8, 10)
    try testing.expectEqual(null, gap.next());
}

// ---------------------------------------------------------- the metapage

test "commits alternate between the meta slots; a torn slot falls back one commit" {
    const gpa = testing.allocator;
    var db: Db = .init(4);
    defer db.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var previous: std.ArrayList(ops.Entry) = .empty; // content one commit ago
    defer previous.deinit(gpa);

    for (0..60) |i| {
        const key: u64 = (i * 37) % 50;
        previous.clearRetainingCapacity();
        try previous.appendSlice(gpa, oracle.range(0, max_key));
        const id_before = db.current.txn_id;
        if (i % 3 == 2) {
            _ = try db.delete(gpa, key);
            _ = oracle.delete(key);
        } else {
            _ = try db.put(gpa, key, i);
            _ = try oracle.put(gpa, key, i);
        }
        const id = db.current.txn_id;
        if (id == id_before) continue; // deleting a missing key commits nothing
        try testing.expectEqual(id, Meta.decode(&db.store.meta_slots[id % 2]).?.txn_id);
        try testing.expectEqual(id - 1, Meta.decode(&db.store.meta_slots[(id - 1) % 2]).?.txn_id);

        if (i % 4 == 3) {
            // The meta write of this commit was torn: after a restart the
            // previous commit must be complete, although this commit already
            // reused pages (only pages the previous root could not reach).
            db.store.meta_slots[id % 2][i % 32] ^= 0x01;
            try db.reopen(gpa);
            try testing.expectEqual(id - 1, db.current.txn_id);
            try validate(&db, gpa);
            try expectEntries(previous.items, db.view(), 0, max_key);
            oracle.entries.clearRetainingCapacity();
            try oracle.entries.appendSlice(gpa, previous.items);
        } else if (i % 4 == 1) {
            try db.reopen(gpa); // a clean restart changes nothing
            try testing.expectEqual(id, db.current.txn_id);
            try validate(&db, gpa);
            try expectEntries(oracle.range(0, max_key), db.view(), 0, max_key);
        }
    }
    db.store.meta_slots[0][0] ^= 1;
    db.store.meta_slots[1][0] ^= 1;
    try testing.expectError(error.NoValidMeta, db.reopen(gpa));
}

// ---------------------------------------------------------- model tests

const Held = struct { snap: Snapshot, saved: []ops.Entry };

fn modelWithSnapshots(gpa: Allocator, order: usize, seed: u64, count: u64, key_space: u64) !void {
    var db: Db = .init(order);
    defer db.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var held: std.ArrayList(Held) = .empty;
    defer {
        for (held.items) |h| gpa.free(h.saved);
        held.deinit(gpa);
    }

    var i: usize = 0;
    var stream = ops.OpStream.init(.{ .seed = seed, .count = count, .key_space = key_space });
    while (stream.next()) |op| : (i += 1) {
        switch (op) {
            .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try db.put(gpa, p.key, p.value)),
            .delete => |d| try testing.expectEqual(oracle.delete(d.key), try db.delete(gpa, d.key)),
            .get => |g| try testing.expectEqual(oracle.get(g.key), db.get(g.key)),
            .range => |r| try expectEntries(oracle.range(r.lo, r.hi), db.view(), r.lo, r.hi),
        }
        try testing.expectEqual(oracle.len(), db.len());

        if (i % 17 == 0) {
            // Take a snapshot and save what the oracle holds right now.
            const saved = try gpa.dupe(ops.Entry, oracle.range(0, max_key));
            errdefer gpa.free(saved);
            try held.append(gpa, .{ .snap = try db.snapshot(gpa), .saved = saved });
        }
        if (i % 29 == 28 and held.items.len > 0) {
            // Release one: sometimes the oldest, sometimes one in the middle.
            const h = held.orderedRemove((i / 29) % held.items.len);
            _ = db.release(h.snap);
            gpa.free(h.saved);
        }
        if (i % 11 == 0) {
            try validate(&db, gpa);
            for (held.items) |h| {
                try testing.expectEqual(h.saved.len, h.snap.count);
                try expectEntries(h.saved, h.snap.view(&db), 0, max_key);
            }
        }
    }
    while (held.pop()) |h| {
        _ = db.release(h.snap);
        gpa.free(h.saved);
    }
    try validate(&db, gpa);
    // With no reader left, every page is either in the tree or free.
    try testing.expectEqual(0, db.pending.items.len);
}

test "model: one transaction per write, snapshots compared with saved oracle copies" {
    for ([_]usize{ 3, 4, 5, 8, 16 }) |order| {
        try modelWithSnapshots(testing.allocator, order, 1000 + order, 4000, 150);
    }
    try modelWithSnapshots(testing.allocator, 4, 7, 2000, 12); // tiny key space: empties often
}

test "model: multi-write transactions, some aborted" {
    const gpa = testing.allocator;
    for ([_]usize{ 3, 4, 6 }) |order| {
        var db: Db = .init(order);
        defer db.deinit(gpa);
        var oracle: ops.Oracle = .{};
        defer oracle.deinit(gpa);
        var saved: std.ArrayList(ops.Entry) = .empty; // oracle at txn begin
        defer saved.deinit(gpa);

        var stream = ops.OpStream.init(.{ .seed = 99 + order, .count = 6000, .key_space = 120 });
        var batch: usize = 0;
        var done = false;
        while (!done) : (batch += 1) {
            saved.clearRetainingCapacity();
            try saved.appendSlice(gpa, oracle.range(0, max_key));
            const before = db.current;

            var txn = db.begin(gpa);
            defer txn.abort();
            for (0..1 + batch % 7) |_| {
                const op = stream.next() orelse {
                    done = true;
                    break;
                };
                switch (op) {
                    .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try txn.put(p.key, p.value)),
                    .delete => |d| try testing.expectEqual(oracle.delete(d.key), try txn.delete(d.key)),
                    .get => |g| try testing.expectEqual(oracle.get(g.key), txn.get(g.key)),
                    .range => |r| try expectEntries(oracle.range(r.lo, r.hi), txn.view(), r.lo, r.hi),
                }
            }
            // Until commit, the outside world sees the old tree.
            try expectEntries(saved.items, db.view(), 0, max_key);
            if (batch % 5 == 4) {
                txn.abort();
                oracle.entries.clearRetainingCapacity();
                try oracle.entries.appendSlice(gpa, saved.items);
                try testing.expectEqual(before, db.current);
            } else {
                _ = try txn.commit(gpa);
            }
            try expectEntries(oracle.range(0, max_key), db.view(), 0, max_key);
            if (batch % 3 == 0) try validate(&db, gpa);
        }
        try validate(&db, gpa);
        try testing.expectEqual(0, db.pending.items.len);
    }
}

// ------------------------------------------------------ allocation failure

/// A scenario that allocates in every way the database can: page copies,
/// splits, merges, snapshot registry, pending list, store growth.
fn scenarioUnderFailure(gpa: Allocator) !void {
    var db: Db = .init(3);
    defer db.deinit(gpa);
    for (0..12) |k| _ = try db.put(gpa, k * 7 % 12, k);
    const snap = try db.snapshot(gpa);
    defer _ = db.release(snap);
    for (0..6) |k| _ = try db.delete(gpa, k);
    var txn = db.begin(gpa);
    defer txn.abort();
    for (20..30) |k| _ = try txn.put(k, k);
    _ = try txn.commit(gpa);
    try validate(&db, gpa);
    try testing.expectEqual(12, snap.count);
}

test "every allocation failure is reported and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, scenarioUnderFailure, .{});
}

test "a transaction that runs out of memory leaves no trace" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);
    const snap = try db.snapshot(gpa);
    defer _ = db.release(snap);

    // The arena asks its backing allocator for a few large blocks, so one
    // transaction has only a handful of failure points. Transactions of
    // different sizes move those points around: each size is retried with
    // the failure one allocation later, until it commits.
    var failures: usize = 0;
    for (1..25) |size| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            const meta_before = db.store.meta_slots;
            const count_before = db.len();
            var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
            const a = failing.allocator();

            var txn = db.begin(a);
            defer txn.abort();
            const result = blk: {
                for (0..size) |k| _ = txn.put(1000 * size + k, k) catch |e| break :blk e;
                _ = txn.delete(canonical[size % canonical.len]) catch |e| break :blk e;
                _ = txn.commit(a) catch |e| break :blk e;
                break :blk {};
            };
            if (result) |_| {
                try validate(&db, gpa);
                break;
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
                // put/delete failed: the transaction is poisoned, commit refuses.
                if (txn.failed) try testing.expectError(error.TxnFailed, txn.commit(a));
                txn.abort();
                // Nothing happened, as far as anyone can tell.
                try testing.expectEqual(meta_before, db.store.meta_slots);
                try testing.expectEqual(count_before, db.len());
                try validate(&db, gpa);
                try expectKeys(&.{ 1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30 }, snap.view(&db));
            }
        }
    }
    std.debug.print("failures={d}\n", .{failures});
}

// ------------------------------------------- validate catches corruption

test "validate names the broken invariant" {
    const gpa = testing.allocator;
    const Case = struct {
        expected: anyerror,
        corrupt: *const fn (db: *Db, snap: Snapshot) void,
    };
    // Every case starts from: canonical tree, snapshot at txn 12, then
    // `put 13` as txn 13. Pages #0 #4 #9 are pending (old path), #2 #5 #10
    // are the new path, #1 #3 #6 #7 #8 are shared by both roots.
    const cases = [_]Case{
        .{ .expected = error.LivePageModified, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                // "Someone" rewrote a shared page in place as transaction 13:
                // legal for the current root, a lie to the snapshot of 12.
                db.store.slots.items[6].written_by = 13;
            }
        }.f },
        .{ .expected = error.ReachablePageIsFree, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                db.store.release(.fromIndex(7)); // a live leaf becomes writable
            }
        }.f },
        .{ .expected = error.ReachablePageIsFree, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                // Reclaim too early: pretend the snapshot is not there.
                const saved = db.snapshots;
                db.snapshots = .empty;
                _ = db.reclaim();
                db.snapshots = saved;
            }
        }.f },
        .{ .expected = error.SnapshotPageUnprotected, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                db.pending.items[0].freed_by = 12; // "freed by 12" would be releasable
                db.pending.items[1].freed_by = 12;
                db.pending.items[2].freed_by = 12;
            }
        }.f },
        .{ .expected = error.FreeListCorrupt, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                db.store.free.appendAssumeCapacity(.fromIndex(1)); // listed but live
            }
        }.f },
        .{ .expected = error.PendingCorrupt, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                db.pending.items[0].page = .fromIndex(10); // a page of the current tree
            }
        }.f },
        .{ .expected = error.PageLeak, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                _ = db.pending.pop(); // forgotten: neither reachable, pending nor free
                db.snapshots.items.len = 0;
            }
        }.f },
        .{ .expected = error.PageReachedTwice, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                // The sibling-link disease: one leaf under two parents.
                const root = &db.store.slots.items[db.current.root.index()].node;
                const left = &db.store.slots.items[root.kind.internal.children[0].index()].node;
                left.kind.internal.children[1] = left.kind.internal.children[0];
            }
        }.f },
        .{ .expected = error.KeyOutOfBounds, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                db.store.slots.items[10].node.keys[2] = 99; // leaf (10 12 13) under [6 10 | 15)
            }
        }.f },
        .{ .expected = error.WrongCount, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                db.snapshots.items[0].snap.count += 1;
            }
        }.f },
        .{ .expected = error.BadMeta, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                db.store.meta_slots[1][3] ^= 0x40; // newest slot torn: current is no longer the winner
            }
        }.f },
        .{ .expected = error.DanglingChild, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                db.store.slots.items[db.current.root.index()].node.kind.internal.children[1] = .fromIndex(500);
            }
        }.f },
    };
    for (cases) |case| {
        var db = try buildCanonical(gpa);
        defer db.deinit(gpa);
        const snap = try db.snapshot(gpa);
        _ = try db.put(gpa, 13, 1300);
        try validate(&db, gpa);
        case.corrupt(&db, snap);
        try testing.expectError(case.expected, validate(&db, gpa));
    }
}
