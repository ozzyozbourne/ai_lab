//! Tests of the whole database: path copying, snapshots, deferred reuse,
//! abort, the metapage, restarts after crashes and slot damage, seeded model
//! tests with snapshots, allocation failure, and proof that `validate`
//! catches corruption.
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

/// The whole tree. NOT `range(0, max_key)`: `hi` is exclusive, so that
/// would silently skip the key maxInt(u64).
fn expectKeys(expected: []const u64, view: View) !void {
    var it = view.seek(0);
    for (expected) |k| try testing.expectEqual(k, it.next().?.key);
    try testing.expectEqual(null, it.next());
}

fn expectAll(expected: []const ops.Entry, view: View) !void {
    var it = view.seek(0);
    for (expected) |e| {
        const got = it.next() orelse return error.TestExpectedEqual;
        try testing.expectEqual(e.key, got.key);
        try testing.expectEqual(e.value, got.value);
    }
    try testing.expectEqual(null, it.next());
}

/// With no reader left, the only pages still waiting are the ones the
/// newest commit replaced: the previous root (the fallback) reaches them.
fn expectOnlyFallbackPending(db: *const Db) !void {
    for (db.pending.items) |p| try testing.expectEqual(db.current.txn_id, p.freed_by);
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
        \\txn 12: root #11, height 3, 12 keys
        \\  level 0: #11[15]
        \\  level 1: #7[6 10] #10[20]
        \\  leaves : #5(1 3 5) #8(6 7) #0(10 12) | #9(15 17) #3(20 25 30)
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
    // Released: the 2 pages txn 12 replaced. The 3 this commit replaced stay.
    try testing.expectEqual(2, info.released);
    try testing.expectEqual(3, db.pending.items.len);

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
        \\txn 12: root #11, height 3, 12 keys
        \\  level 0: #11[15]
        \\  level 1: #7[6 10] #10[20]
        \\  leaves : #5(1 3 5) #8(6 7) #0(10 12) | #9(15 17) #3(20 25 30)
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
    try expectOnlyFallbackPending(&db);
}

test "freed pages are reused only after the snapshots that need them are gone" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);

    // Without a snapshot the pages a commit replaces are free one commit
    // later, and the store stops growing: it holds the tree plus two paths
    // (the one being written and the one the fallback root still needs).
    // (Two warm-up commits, until the free list holds a path of 3.)
    for (0..2) |i| _ = try db.put(gpa, 10, i);
    const pages_before = db.store.pageCount();
    for (0..20) |i| _ = try db.put(gpa, 10, i);
    try testing.expectEqual(pages_before, db.store.pageCount());
    try testing.expectEqual(3, db.pending.items.len); // the newest commit's
    try expectOnlyFallbackPending(&db);

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
    // All but the newest commit's 3: the fallback root still reaches those.
    try testing.expectEqual(57, db.release(second));
    try expectOnlyFallbackPending(&db);
    try testing.expectEqual(3, db.pending.items.len);
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
    // Now the oldest protected root is the fallback, txn 13: the pages
    // freed by 13 go, the pages freed by 14 wait for the next commit.
    try testing.expectEqual(3, db.release(old));
    try expectOnlyFallbackPending(&db);
    try validate(&db, gpa);
    _ = try db.put(gpa, 15, 1); // txn 15 overwrites the slot of txn 13
    try testing.expectEqual(3, db.pending.items.len);
    try expectOnlyFallbackPending(&db);
}

test "pages replaced by a commit become reusable one commit later, not at once" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);
    var before: std.ArrayList(PageId) = .empty; // pages of the tree of txn 12
    defer before.deinit(gpa);
    {
        const marks = try reachable(gpa, &db, db.view());
        defer gpa.free(marks);
        for (marks, 0..) |m, i| if (m) try before.append(gpa, .fromIndex(i));
    }
    try testing.expectEqual(12, db.previous.?.txn_id + 1);

    // Txn 13 replaces a path of 3. No snapshot is held, and still none of
    // the 3 is free: meta slot 0 names txn 12, and a restart may choose it.
    var txn = db.begin(gpa);
    _ = try txn.put(13, 1300);
    const info = try txn.commit(gpa);
    try testing.expectEqual(3, info.freed);
    try testing.expectEqual(12, db.previous.?.txn_id);
    for (before.items) |id| try testing.expect(db.store.isLive(id));
    try testing.expectEqual(3, db.pending.items.len);

    // Txn 14 could use them (it does not get them), and releases them once
    // its own meta slot has replaced the one of txn 12.
    _ = try db.put(gpa, 14, 1400);
    try testing.expectEqual(13, db.previous.?.txn_id);
    var freed: usize = 0;
    for (before.items) |id| {
        if (!db.store.isLive(id)) freed += 1;
    }
    try testing.expectEqual(3, freed);
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
    // Every page is free except the last leaf: the fallback root (the tree
    // with one key) still reaches it until the next commit.
    try testing.expectEqual(1, db.pending.items.len);
    try testing.expectEqual(db.store.pageCount() - 1, db.store.free.items.len);
    try testing.expectEqual(null, db.get(10));
    try expectKeys(&.{}, db.view());
    _ = try db.put(gpa, 7, 70);
    try testing.expectEqual(0, db.pending.items.len);
    try testing.expectEqual(db.store.pageCount() - 1, db.store.free.items.len);
    try testing.expectEqual(70, db.get(7).?);
    try validate(&db, gpa);
}

test "a full scan reaches the largest key; range(lo, hi) excludes hi" {
    const gpa = testing.allocator;
    var db: Db = .init(4);
    defer db.deinit(gpa);
    _ = try db.put(gpa, max_key, 1);
    _ = try db.put(gpa, 5, 2);
    _ = try db.put(gpa, 0, 3);
    try expectKeys(&.{ 0, 5, max_key }, db.view());
    try testing.expectEqual(1, db.get(max_key).?);
    var it = db.range(0, max_key); // half-open: stops before max_key
    try testing.expectEqual(0, it.next().?.key);
    try testing.expectEqual(5, it.next().?.key);
    try testing.expectEqual(null, it.next());
    try testing.expectEqual(1, (try db.delete(gpa, max_key)).?);
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
        try previous.appendSlice(gpa, oracle.entries.items);
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
            // The newest slot is unreadable: after a restart the previous
            // commit must be complete, although this commit already reused
            // pages (only pages the previous root could not reach).
            db.store.meta_slots[id % 2][i % 32] ^= 0x01;
            try db.reopen(gpa);
            try testing.expectEqual(id - 1, db.current.txn_id);
            try validate(&db, gpa);
            try expectAll(previous.items, db.view());
            try testing.expectEqual(null, db.previous); // no second slot to fall back to
            oracle.entries.clearRetainingCapacity();
            try oracle.entries.appendSlice(gpa, previous.items);
        } else if (i % 4 == 1) {
            const fallback = db.previous;
            try db.reopen(gpa); // a clean restart changes nothing
            try testing.expectEqual(id, db.current.txn_id);
            try testing.expectEqual(fallback, db.previous); // and keeps the fallback protected
            try validate(&db, gpa);
            try expectAll(oracle.entries.items, db.view());
        }
    }
    db.store.meta_slots[0][0] ^= 1;
    db.store.meta_slots[1][0] ^= 1;
    try testing.expectError(error.NoValidMeta, db.reopen(gpa));
}

// ------------------------------------------- restarts after crash and damage

/// What survives a power failure: the pages and the two meta slots. The
/// in-memory half of the copy is that of a fresh database (wrong on
/// purpose): `reopen` has to rebuild all of it from the "disk".
fn diskImage(gpa: Allocator, db: *const Db) !Db {
    var copy: Db = .init(db.order);
    errdefer copy.deinit(gpa);
    try copy.store.grow(gpa, db.store.pageCount());
    @memcpy(copy.store.slots.items, db.store.slots.items);
    copy.store.meta_slots = db.store.meta_slots;
    return copy;
}

/// A complete copy, so that one commit can be crashed many times.
fn cloneDb(gpa: Allocator, db: *const Db) !Db {
    var copy = try diskImage(gpa, db);
    errdefer copy.deinit(gpa);
    copy.store.free.appendSliceAssumeCapacity(db.store.free.items);
    try copy.pending.appendSlice(gpa, db.pending.items);
    copy.current = db.current;
    copy.previous = db.previous;
    return copy;
}

const Damage = enum { none, bit_flip, zeroed, ones };

fn damage(slot: *[32]u8, how: Damage, salt: usize) void {
    switch (how) {
        .none => {},
        .bit_flip => slot[(salt / 8) % 32] ^= @as(u8, 1) << @intCast(salt % 8),
        .zeroed => @memset(slot, 0),
        .ones => @memset(slot, 0xFF),
    }
}

/// THE property of the two-slot metapage. `history[t]` is the content
/// transaction t committed. Whatever is left on the disk: if a meta slot is
/// readable, a restart succeeds and finds exactly the content of the newest
/// readable commit, in a store that passes `validate` and can go on working.
fn expectCleanRestart(gpa: Allocator, disk: *Db, history: []const []const ops.Entry) !?u64 {
    const a = Meta.decode(&disk.store.meta_slots[0]);
    const b = Meta.decode(&disk.store.meta_slots[1]);
    if (a == null and b == null) {
        try testing.expectError(error.NoValidMeta, disk.reopen(gpa));
        return null;
    }
    const want = @max(if (a) |m| m.txn_id else 0, if (b) |m| m.txn_id else 0);
    try disk.reopen(gpa);
    try testing.expectEqual(want, disk.current.txn_id);
    try validate(disk, gpa);
    try expectAll(history[want], disk.view());
    // Life goes on: commit twice (the second reuses pages the first freed),
    // and restart once more.
    _ = try disk.put(gpa, 1_000_000, 1);
    try validate(disk, gpa);
    _ = try disk.put(gpa, 1_000_001, 2);
    try validate(disk, gpa);
    try disk.reopen(gpa);
    try validate(disk, gpa);
    try testing.expectEqual(history[want].len + 2, disk.len());
    return want;
}

test "the reviewer's case: newest slot unreadable while the next commit is in flight" {
    const gpa = testing.allocator;
    var db = try buildCanonical(gpa);
    defer db.deinit(gpa);
    // Txn 13 writes its 3 pages and loses power before its meta write.
    db.crash_after = 3;
    try testing.expectError(error.Crashed, db.put(gpa, 13, 1300));
    // On top of that the slot of txn 12 has rotted. The only readable slot
    // is that of txn 11, which was one write away from being overwritten.
    db.store.meta_slots[0][3] ^= 1;
    try db.reopen(gpa);
    try testing.expectEqual(11, db.current.txn_id);
    try validate(&db, gpa);
    try expectKeys(&.{ 1, 3, 5, 6, 7, 10, 12, 17, 20, 25, 30 }, db.view()); // no 15, no 13
}

test "restart after a crash at any write, with either slot damaged, finds a complete committed tree" {
    const gpa = testing.allocator;
    var fell_back_two: usize = 0; // restarts that landed on T-2 while T was in flight
    var cases: usize = 0;
    for ([_]usize{ 3, 4 }) |order| {
        var db: Db = .init(order);
        defer db.deinit(gpa);
        var oracle: ops.Oracle = .{};
        defer oracle.deinit(gpa);
        var history: std.ArrayList([]ops.Entry) = .empty;
        defer {
            for (history.items) |h| gpa.free(h);
            history.deinit(gpa);
        }
        try history.append(gpa, try gpa.alloc(ops.Entry, 0)); // txn 0: empty

        // Small key space: splits, borrows, merges, root growth and shrink.
        var stream = ops.OpStream.init(.{ .seed = 40 + order, .count = 150, .key_space = 14 });
        while (stream.next()) |op| {
            const key, const value, const is_put = switch (op) {
                .put => |p| .{ p.key, p.value, true },
                .delete => |d| .{ d.key, 0, false },
                else => continue,
            };
            if (!is_put and oracle.get(key) == null) continue; // commits nothing
            if (is_put) _ = try oracle.put(gpa, key, value) else _ = oracle.delete(key);
            const t = db.current.txn_id + 1;
            {
                const content = try gpa.dupe(ops.Entry, oracle.entries.items);
                errdefer gpa.free(content);
                try history.append(gpa, content); // history[t]
            }

            // Crash the commit of transaction t after w device writes, for
            // every w, until it gets through.
            var w: usize = 0;
            while (true) : (w += 1) {
                var trial = try cloneDb(gpa, &db);
                defer trial.deinit(gpa);
                trial.crash_after = w;
                const crashed = if (is_put) blk: {
                    _ = trial.put(gpa, key, value) catch |e| break :blk e;
                    break :blk {};
                } else blk: {
                    _ = trial.delete(gpa, key) catch |e| break :blk e;
                    break :blk {};
                };
                if (crashed) |_| {} else |e| try testing.expectEqual(error.Crashed, e);

                // The disk as the crash left it, then with one slot damaged.
                for ([_]usize{ 0, 1 }) |slot| {
                    for ([_]Damage{ .none, .bit_flip, .zeroed, .ones }) |how| {
                        if (how == .none and slot == 1) continue;
                        var disk = try diskImage(gpa, &trial);
                        defer disk.deinit(gpa);
                        damage(&disk.store.meta_slots[slot], how, w * 31 + t);
                        const landed = try expectCleanRestart(gpa, &disk, history.items);
                        cases += 1;
                        if (how == .none) {
                            // No damage: a crash loses the commit in flight and
                            // nothing else. (A crash before the LAST meta bytes
                            // can leave a complete slot, when those bytes
                            // happen to equal the ones they replace.)
                            const done = if (crashed) |_| true else |_| false;
                            if (done) try testing.expectEqual(t, landed.?);
                            if (w == 0) try testing.expectEqual(t - 1, landed.?);
                            try testing.expect(landed.? == t or landed.? == t - 1);
                        } else if (landed != null and landed.? + 2 == t) {
                            fell_back_two += 1;
                        }
                    }
                }
                if (crashed) |_| break else |_| {}
            }
            // The real line of history moves on without a crash.
            if (is_put) _ = try db.put(gpa, key, value) else _ = try db.delete(gpa, key);
            try testing.expectEqual(t, db.current.txn_id);
        }
    }
    std.debug.print("cases {d} two {d}\n", .{cases, fell_back_two});
    try testing.expect(cases > 20_000);
    try testing.expect(fell_back_two > 1_000); // the double fault really was exercised
}

test "a long life of crashes, damaged slots and restarts never shows a mixed tree" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(2323);
    const rnd = prng.random();
    var db: Db = .init(4);
    defer db.deinit(gpa);
    // content[t] = what the newest commit with id t wrote (ids repeat after
    // a fallback: the lost transaction's id is handed out again).
    var content: std.ArrayList([]ops.Entry) = .empty;
    defer {
        for (content.items) |c| gpa.free(c);
        content.deinit(gpa);
    }
    try content.append(gpa, try gpa.alloc(ops.Entry, 0));
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var held: ?Held = null; // one reader, to mix snapshots into the rule
    defer if (held) |h| gpa.free(h.saved);
    var restarts: usize = 0;
    var fallbacks: usize = 0;

    for (0..4000) |step| {
        const key = rnd.uintLessThan(u64, 40);
        const is_put = rnd.uintLessThan(u8, 5) < 3;
        const before = db.current.txn_id;
        if (rnd.uintLessThan(u8, 6) == 0) db.crash_after = rnd.uintLessThan(usize, 44);
        const result = if (is_put) db.put(gpa, key, step) else db.delete(gpa, key);
        var restart = false;
        if (result) |_| {
            db.crash_after = null; // the commit was shorter than the fuse
            if (db.current.txn_id != before) {
                if (is_put) _ = try oracle.put(gpa, key, step) else _ = oracle.delete(key);
                const t = db.current.txn_id;
                const copy = try gpa.dupe(ops.Entry, oracle.entries.items);
                if (t < content.items.len) {
                    gpa.free(content.items[t]);
                    content.items[t] = copy;
                } else {
                    errdefer gpa.free(copy);
                    try testing.expectEqual(content.items.len, t);
                    try content.append(gpa, copy);
                }
            }
            restart = rnd.uintLessThan(u8, 25) == 0; // sometimes the power just goes
        } else |e| {
            try testing.expectEqual(error.Crashed, e);
            restart = true;
        }

        if (restart) {
            const slots = &db.store.meta_slots;
            // One slot may rot, as long as the other one is readable.
            if (Meta.decode(&slots[0]) != null and Meta.decode(&slots[1]) != null and rnd.boolean()) {
                damage(&slots[rnd.uintLessThan(usize, 2)], .bit_flip, rnd.uintLessThan(usize, 256));
            }
            const a = Meta.decode(&slots[0]);
            const b = Meta.decode(&slots[1]);
            const want = @max(if (a) |m| m.txn_id else 0, if (b) |m| m.txn_id else 0);
            try db.reopen(gpa);
            restarts += 1;
            if (want < before) fallbacks += 1;
            try testing.expectEqual(want, db.current.txn_id);
            try expectAll(content.items[want], db.view());
            oracle.entries.clearRetainingCapacity();
            try oracle.entries.appendSlice(gpa, content.items[want]);
            if (held) |h| gpa.free(h.saved); // a restart forgets its readers
            held = null;
        }
        try validate(&db, gpa);
        try expectAll(oracle.entries.items, db.view());

        if (held) |h| {
            try expectAll(h.saved, h.snap.view(&db));
            if (rnd.uintLessThan(u8, 10) == 0) {
                _ = db.release(h.snap);
                gpa.free(h.saved);
                held = null;
            }
        } else if (rnd.uintLessThan(u8, 8) == 0) {
            const saved = try gpa.dupe(ops.Entry, oracle.entries.items);
            errdefer gpa.free(saved);
            held = .{ .snap = try db.snapshot(gpa), .saved = saved };
        }
    }
    std.debug.print("restarts {d} fallbacks {d}\n", .{restarts, fallbacks});
    try testing.expect(restarts > 300);
    try testing.expect(fallbacks > 50);
}

test "reopen reports a tree that is not all there instead of walking into it" {
    const gpa = testing.allocator;
    const Forge = struct {
        /// Changes the newest meta (a valid checksum is added afterwards)
        /// or the pages. Each case is damage the checksum cannot see.
        f: *const fn (m: *Meta, db: *Db) void,
    };
    const forgeries = [_]Forge{
        .{ .f = struct {
            fn f(m: *Meta, _: *Db) void {
                m.root = .fromIndex(500); // root outside the store
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, _: *Db) void {
                m.page_count = 1_000_000; // a store that is not there
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, _: *Db) void {
                m.page_count = 3; // the root lies beyond the end
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, _: *Db) void {
                m.height = 4_000_000_000; // would be a very deep recursion
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, _: *Db) void {
                m.height = 2; // leaves are deeper than that
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, _: *Db) void {
                m.height = 0;
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, _: *Db) void {
                m.count += 1;
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, _: *Db) void {
                m.root = .nil; // "empty", but with 12 keys
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, db: *Db) void {
                m.root = db.store.free.items[0]; // a page of no tree (a stale leaf)
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, db: *Db) void {
                // A cycle: the root's first child points back at the root.
                const root = &db.store.slots.items[m.root.index()].node;
                const child = &db.store.slots.items[root.kind.internal.children[0].index()].node;
                child.kind.internal.children[0] = m.root;
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, db: *Db) void {
                db.store.slots.items[m.root.index()].node.kind.internal.children[1] = .fromIndex(77);
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, db: *Db) void {
                db.store.slots.items[m.root.index()].node.kind.internal.children[1] = .nil;
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, db: *Db) void {
                // A page of this tree was overwritten by a later transaction:
                // what a stale slot looks like when its pages were reused.
                db.store.slots.items[m.root.index()].written_by = m.txn_id + 1;
            }
        }.f },
        .{ .f = struct {
            fn f(m: *Meta, db: *Db) void {
                db.store.slots.items[m.root.index()].node.len = 99; // more keys than a node holds
            }
        }.f },
    };
    for (forgeries) |forge| {
        var db = try buildCanonical(gpa);
        defer db.deinit(gpa);
        var m = db.current;
        forge.f(&m, &db);
        db.store.meta_slots[m.txn_id % 2] = m.encode();
        const pages = db.store.pageCount();
        try testing.expectError(error.CorruptTree, db.reopen(gpa));
        // A failed restart changes nothing.
        try testing.expectEqual(12, db.current.txn_id);
        try testing.expectEqual(pages, db.store.pageCount());
    }

    // A grown store whose new pages were never written: the slot names one.
    {
        var db = try buildCanonical(gpa);
        defer db.deinit(gpa);
        try db.store.grow(gpa, 20);
        var m = db.current;
        m.root = .fromIndex(19);
        m.page_count = 20;
        m.height = 1;
        db.store.meta_slots[0] = m.encode();
        try testing.expectError(error.CorruptTree, db.reopen(gpa));
    }

    // Random slots with a valid checksum: an error or a walkable tree,
    // never a panic, never a hang.
    var prng: std.Random.DefaultPrng = .init(77);
    const rnd = prng.random();
    var survived: usize = 0;
    for (0..3000) |_| {
        var db = try buildCanonical(gpa);
        defer db.deinit(gpa);
        const m: Meta = .{
            .txn_id = rnd.uintLessThan(u64, 30),
            .root = if (rnd.uintLessThan(u8, 10) == 0) .nil else .fromIndex(rnd.uintLessThan(usize, 16)),
            .height = rnd.uintLessThan(u32, 5),
            .count = rnd.uintLessThan(u64, 14),
            .page_count = rnd.uintLessThan(u32, 16),
        };
        db.store.meta_slots[rnd.uintLessThan(usize, 2)] = m.encode();
        if (db.reopen(gpa)) |_| {
            survived += 1;
            var n: u64 = 0;
            var it = db.view().seek(0);
            while (it.next()) |_| n += 1;
            try testing.expectEqual(db.current.count, n);
        } else |e| try testing.expectEqual(error.CorruptTree, e);
    }
    try testing.expect(survived > 0 and survived < 3000);
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
            const saved = try gpa.dupe(ops.Entry, oracle.entries.items);
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
                try expectAll(h.saved, h.snap.view(&db));
            }
        }
    }
    while (held.pop()) |h| {
        _ = db.release(h.snap);
        gpa.free(h.saved);
    }
    try validate(&db, gpa);
    // With no reader left, every page is in the tree, free, or kept for the
    // fallback root.
    try expectOnlyFallbackPending(&db);
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
            try saved.appendSlice(gpa, oracle.entries.items);
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
            try expectAll(saved.items, db.view());
            if (batch % 5 == 4) {
                txn.abort();
                oracle.entries.clearRetainingCapacity();
                try oracle.entries.appendSlice(gpa, saved.items);
                try testing.expectEqual(before, db.current);
            } else {
                _ = try txn.commit(gpa);
            }
            try expectAll(oracle.entries.items, db.view());
            if (batch % 3 == 0) try validate(&db, gpa);
        }
        try validate(&db, gpa);
        try expectOnlyFallbackPending(&db);
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

/// Restarts allocate too (the reachability marks, the pending list).
fn restartUnderFailure(gpa: Allocator) !void {
    var db: Db = .init(3);
    defer db.deinit(gpa);
    for (0..12) |k| _ = try db.put(gpa, k * 7 % 12, k);
    const before = db.current;
    try db.reopen(gpa); // keeps the fallback: pending is rebuilt
    try testing.expectEqual(before, db.current);
    try testing.expect(db.pending.items.len > 0);
    try validate(&db, gpa);
    _ = try db.put(gpa, 50, 50);
    db.store.meta_slots[db.current.txn_id % 2][0] ^= 1;
    try db.reopen(gpa); // falls back
    try testing.expectEqual(before, db.current);
    try validate(&db, gpa);
}

test "every allocation failure is reported and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, scenarioUnderFailure, .{});
    try testing.checkAllAllocationFailures(testing.allocator, restartUnderFailure, .{});
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
    try testing.expect(failures > 40);
}

// ------------------------------------------- validate catches corruption

test "validate names the broken invariant" {
    const gpa = testing.allocator;
    const Case = struct {
        expected: anyerror,
        corrupt: *const fn (db: *Db, snap: Snapshot) void,
    };
    // Every case starts from: canonical tree, snapshot at txn 12, then
    // `put 13` as txn 13. Pages #0 #7 #11 are pending (old path), #2 #6 #12
    // are the new path, #3 #5 #8 #9 #10 are shared by both roots. The
    // fallback root (`previous`) is txn 12, the same root as the snapshot.
    const cases = [_]Case{
        .{
            .expected = error.LivePageModified,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    // "Someone" rewrote a shared page in place as transaction 13:
                    // legal for the current root, a lie to the snapshot of 12.
                    db.store.slots.items[8].written_by = 13;
                }
            }.f,
        },
        .{
            .expected = error.ReachablePageIsFree,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    db.store.release(.fromIndex(9)); // a live leaf becomes writable
                }
            }.f,
        },
        .{
            .expected = error.ReachablePageIsFree,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    // Reclaim too early: pretend nobody needs the old root.
                    const snapshots = db.snapshots;
                    const previous = db.previous;
                    db.snapshots = .empty;
                    db.previous = null;
                    _ = db.reclaim();
                    db.snapshots = snapshots;
                    db.previous = previous;
                }
            }.f,
        },
        .{
            .expected = error.ReachablePageIsFree,
            .corrupt = struct {
                fn f(db: *Db, snap: Snapshot) void {
                    // The rule without its second half: no reader is left, so
                    // the pages txn 13 replaced are freed at once. But meta
                    // slot 0 still names txn 12, and its tree now has holes.
                    _ = db.release(snap);
                    const previous = db.previous;
                    db.previous = null;
                    _ = db.reclaim();
                    db.previous = previous;
                }
            }.f,
        },
        .{
            .expected = error.FallbackUnprotected,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    db.previous = null; // slot 0 can still be chosen by a restart
                }
            }.f,
        },
        .{
            .expected = error.SnapshotPageUnprotected,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    db.pending.items[0].freed_by = 12; // "freed by 12" would be releasable
                    db.pending.items[1].freed_by = 12;
                    db.pending.items[2].freed_by = 12;
                }
            }.f,
        },
        .{
            .expected = error.FreeListCorrupt,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    db.store.free.appendAssumeCapacity(.fromIndex(3)); // listed but live
                }
            }.f,
        },
        .{
            .expected = error.PendingCorrupt,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    db.pending.items[0].page = .fromIndex(10); // a page of the current tree
                }
            }.f,
        },
        .{
            .expected = error.PageLeak,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    _ = db.pending.pop(); // forgotten: neither reachable, pending nor free
                    db.snapshots.items.len = 0;
                }
            }.f,
        },
        .{
            .expected = error.PageReachedTwice,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    // The sibling-link disease: one leaf under two parents.
                    const root = &db.store.slots.items[db.current.root.index()].node;
                    const left = &db.store.slots.items[root.kind.internal.children[0].index()].node;
                    left.kind.internal.children[1] = left.kind.internal.children[0];
                }
            }.f,
        },
        .{
            .expected = error.KeyOutOfBounds,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    db.store.slots.items[12].node.keys[2] = 99; // leaf (10 12 13) under [6 10 | 15)
                }
            }.f,
        },
        .{ .expected = error.WrongCount, .corrupt = struct {
            fn f(db: *Db, _: Snapshot) void {
                db.snapshots.items[0].snap.count += 1;
            }
        }.f },
        .{
            .expected = error.BadMeta,
            .corrupt = struct {
                fn f(db: *Db, _: Snapshot) void {
                    db.store.meta_slots[1][3] ^= 0x40; // newest slot torn: current is no longer the winner
                }
            }.f,
        },
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
