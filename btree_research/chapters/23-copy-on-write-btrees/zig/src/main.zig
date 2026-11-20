//! Demo program of chapter 23. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Rust program's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const lib = @import("ch23_copy_on_write_btrees");
const Db = lib.Db;
const PageId = lib.PageId;
const CommitInfo = lib.CommitInfo;

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
    var db: Db = .init(4);
    defer db.deinit(gpa);

    try w.writeAll("== 1. Build: canonical keys, M = 4, one transaction per put ==\n");
    for (canonical) |key| {
        var txn = db.begin(gpa);
        defer txn.abort();
        _ = try txn.put(key, key * 100);
        try w.print("put {d:<2}", .{key});
        try printCommit(w, try txn.commit(gpa), &db);
    }
    try lib.dump.dump(db.view(), db.current.txn_id, w);
    try printStore(w, &db);
    try lib.validate(&db, gpa);

    try w.writeAll("\n== 2. Path copying: a snapshot keeps the old root alive ==\n");
    const snap = try db.snapshot(gpa);
    try w.print("snapshot taken at txn {d} (root #{d})\n", .{ snap.id, snap.root.index() });
    {
        var txn = db.begin(gpa);
        defer txn.abort();
        _ = try txn.put(13, 1300);
        try w.writeAll("put 13");
        try printCommit(w, try txn.commit(gpa), &db);
    }
    try w.writeAll("old tree, still readable through the snapshot:\n");
    try lib.dump.dump(snap.view(&db), snap.id, w);
    try w.writeAll("new tree:\n");
    try lib.dump.dump(db.view(), db.current.txn_id, w);
    try printSharing(gpa, w, &db, snap);
    try printStore(w, &db);
    try lib.validate(&db, gpa);

    try w.writeAll("\n== 3. Two readers, two answers; range without sibling links ==\n");
    try w.print("snapshot: get 13 = {?d}, {d} keys\n", .{ snap.view(&db).get(13), snap.count });
    try w.print("current : get 13 = {?d}, {d} keys\n", .{ db.get(13), db.len() });
    try w.writeAll("snapshot range [6, 20):");
    var old_range = snap.view(&db).range(6, 20);
    while (old_range.next()) |e| try w.print(" {d}", .{e.key});
    try w.writeAll("\ncurrent  range [6, 20):");
    var new_range = db.range(6, 20);
    while (new_range.next()) |e| try w.print(" {d}", .{e.key});
    try w.writeByte('\n');

    try w.writeAll("\n== 4. Freed pages wait for the snapshot ==\n");
    for ([_]u64{ 6, 7 }) |key| {
        var txn = db.begin(gpa);
        defer txn.abort();
        _ = try txn.delete(key);
        try w.print("delete {d}", .{key});
        try printCommit(w, try txn.commit(gpa), &db);
    }
    try printStore(w, &db);
    try w.print("snapshot still sees {d} keys, get 6 = {?d}\n", .{ snap.count, snap.view(&db).get(6) });
    try lib.validate(&db, gpa);
    const second = db.retain(snap); // a second reader of the same root
    try w.print("two handles on txn {d}; release the first : {d} pages released\n", .{ snap.id, db.release(snap) });
    try w.print("                       release the second: {d} pages move from pending to the free list\n", .{db.release(second)});
    try printStore(w, &db);
    {
        var txn = db.begin(gpa);
        defer txn.abort();
        _ = try txn.put(8, 800);
        try w.writeAll("put 8 ");
        try printCommit(w, try txn.commit(gpa), &db);
    }
    try lib.dump.dump(db.view(), db.current.txn_id, w);
    try printStore(w, &db);
    try lib.validate(&db, gpa);

    try w.writeAll("\n== 5. A transaction with several writes; abort ==\n");
    for ([_]bool{ false, true }) |do_commit| {
        var txn = db.begin(gpa);
        defer txn.abort();
        for ([_]u64{ 26, 27, 28 }) |key| {
            _ = try txn.put(key, key * 100);
            try w.print("  put {d}: {d} dirty pages, {d} copied so far\n", .{ key, txn.dirty.count(), txn.info.copied });
        }
        try w.print("  inside the txn: get 27 = {?d}; outside: get 27 = {?d}\n", .{ txn.get(27), db.get(27) });
        if (do_commit) {
            try w.writeAll("commit");
            try printCommit(w, try txn.commit(gpa), &db);
        } else {
            txn.abort();
            try w.print("abort : current is still txn {d}, root #{d}, get 27 = {?d}\n", .{ db.current.txn_id, db.current.root.index(), db.get(27) });
            try printStore(w, &db);
        }
    }
    try lib.dump.dump(db.view(), db.current.txn_id, w);
    try lib.validate(&db, gpa);

    try w.writeAll("\n== 6. The two-slot metapage: restarts after damage ==\n");
    try printMeta(w, &db);
    // (a) A torn meta write. Commits alternate, so txn 18 writes slot 0.
    _ = try crashingPut(gpa, &db, 9, 12);
    try w.writeAll("put 9: power fails in the middle of the meta write of txn 18 (slot 0). Restart:\n");
    try printMeta(w, &db);
    try db.reopen(gpa);
    try w.print("get 9 = {?d}, {d} keys (txn 18 never happened; txn 17 is complete)\n", .{ db.get(9), db.len() });
    try printStore(w, &db);
    try lib.validate(&db, gpa);
    {
        var txn = db.begin(gpa);
        defer txn.abort();
        _ = try txn.put(9, 900);
        try w.writeAll("put 9 ");
        try printCommit(w, try txn.commit(gpa), &db);
    }
    try printStore(w, &db);
    // (b) Two faults at once: txn 19 is in flight, and the slot of the
    // newest commit (txn 18, slot 0) cannot be read any more.
    const pages = try crashingPut(gpa, &db, 4, 0);
    db.store.meta_slots[0][8] ^= 0xFF; // damage the root field
    try w.print("put 4: power fails after the {d} page writes of txn 19, before its meta write.\n", .{pages});
    try w.writeAll("On top of that, slot 0 (txn 18, the newest commit) has become unreadable. Restart:\n");
    try printMeta(w, &db);
    try db.reopen(gpa);
    try lib.dump.dump(db.view(), db.current.txn_id, w);
    try w.print("get 9 = {?d}, get 4 = {?d} (txn 18 is lost with its slot; txn 17 is complete, although txn 19 had written pages)\n", .{ db.get(9), db.get(4) });
    try printStore(w, &db);
    try lib.validate(&db, gpa);

    try modelRun(gpa, w);
}

/// `put key` as a transaction whose commit loses power after all of its page
/// writes and `meta_bytes` bytes of its meta slot. Returns the number of
/// page writes. The caller restarts with `db.reopen`.
fn crashingPut(gpa: Allocator, db: *Db, key: u64, meta_bytes: usize) !usize {
    // A dry run tells how many pages the commit will write.
    var txn = db.begin(gpa);
    defer txn.abort();
    _ = try txn.put(key, key * 100);
    const pages = txn.dirty.count();
    txn.abort();
    db.crash_after = pages + meta_bytes;
    if (db.put(gpa, key, key * 100)) |_| unreachable else |err| if (err != error.Crashed) return err;
    return pages;
}

fn printCommit(w: *Writer, info: CommitInfo, db: *const Db) !void {
    try w.print(" -> txn {d:<2} copied {d} reused {d} fresh {d} | freed {d} released {d} | root #{d}\n", .{
        info.txn_id, info.copied, info.reused, info.fresh, info.freed, info.released, db.current.root.index(),
    });
}

fn printStore(w: *Writer, db: *const Db) !void {
    try w.print("store: {d} pages | free:", .{db.store.pageCount()});
    for (db.store.free.items) |id| try w.print(" #{d}", .{id.index()});
    if (db.store.free.items.len == 0) try w.writeAll(" -");
    try w.writeAll(" | pending:");
    for (db.pending.items) |p| try w.print(" #{d}(txn {d})", .{ p.page.index(), p.freed_by });
    if (db.pending.items.len == 0) try w.writeAll(" -");
    try w.writeByte('\n');
}

/// Which pages the snapshot's tree and the current tree have in common.
fn printSharing(gpa: Allocator, w: *Writer, db: *const Db, snap: lib.Snapshot) !void {
    const n = db.store.pageCount();
    const old = try gpa.alloc(bool, n);
    defer gpa.free(old);
    const new = try gpa.alloc(bool, n);
    defer gpa.free(new);
    @memset(old, false);
    @memset(new, false);
    lib.dump.markReachable(snap.view(db), old);
    lib.dump.markReachable(db.view(), new);
    const labels = [_][]const u8{ "shared by both roots:", "only the old root   :", "only the new root   :" };
    for (labels, 0..) |label, which| {
        try w.writeAll(label);
        for (old, new, 0..) |o, c, i| {
            const show = switch (which) {
                0 => o and c,
                1 => o and !c,
                else => c and !o,
            };
            if (show) try w.print(" #{d}", .{i});
        }
        try w.writeByte('\n');
    }
}

fn printMeta(w: *Writer, db: *const Db) !void {
    for (&db.store.meta_slots, 0..) |*slot, i| {
        try w.print("  slot {d}: ", .{i});
        if (lib.Meta.decode(slot)) |m| {
            try w.print("txn {d}, root #{d}, height {d}, {d} keys, {d} pages, crc {x:0>8}  valid", .{
                m.txn_id, m.root.index(), m.height, m.count, m.page_count, lib.Meta.checksum(slot),
            });
        } else {
            try w.print("stored crc {x:0>8} does not match  INVALID", .{lib.Meta.checksum(slot)});
        }
        try w.writeByte('\n');
    }
    const m = lib.Meta.pick(&db.store.meta_slots).?;
    try w.print("  reader picks txn {d}\n", .{m.txn_id});
}

/// Seeded model run: one transaction per write, snapshots taken along the
/// way and compared against saved copies of the oracle.
fn modelRun(gpa: Allocator, w: *Writer) !void {
    try w.writeAll("\n== 7. Model run: 3000 operations, snapshots against saved oracle copies ==\n");
    for ([_]usize{ 4, 5, 8 }) |order| {
        var db: Db = .init(order);
        defer db.deinit(gpa);
        var oracle: lib.ops.Oracle = .{};
        defer oracle.deinit(gpa);

        const Held = struct { snap: lib.Snapshot, saved: []lib.ops.Entry };
        var held: std.ArrayList(Held) = .empty;
        defer {
            for (held.items) |h| gpa.free(h.saved);
            held.deinit(gpa);
        }

        var mismatches: usize = 0;
        var snapshots_checked: usize = 0;
        var peak_pending: usize = 0;
        var i: usize = 0;
        var stream = lib.ops.OpStream.init(.{ .seed = 23, .count = 3000, .key_space = 200 });
        while (stream.next()) |op| : (i += 1) {
            switch (op) {
                .put => |p| {
                    if (try db.put(gpa, p.key, p.value) != try oracle.put(gpa, p.key, p.value)) mismatches += 1;
                },
                .delete => |d| {
                    if (try db.delete(gpa, d.key) != oracle.delete(d.key)) mismatches += 1;
                },
                .get => |g| {
                    if (db.get(g.key) != oracle.get(g.key)) mismatches += 1;
                },
                .range => |r| mismatches += countMismatches(db.view().seek(r.lo), r.hi, oracle.range(r.lo, r.hi)),
            }
            peak_pending = @max(peak_pending, db.pending.items.len);
            if (i % 100 == 0) {
                // Keep at most three snapshots: drop the oldest first.
                if (held.items.len == 3) {
                    const h = held.orderedRemove(0);
                    _ = db.release(h.snap);
                    gpa.free(h.saved);
                }
                const saved = try gpa.dupe(lib.ops.Entry, oracle.entries.items);
                errdefer gpa.free(saved);
                try held.append(gpa, .{ .snap = try db.snapshot(gpa), .saved = saved });
            }
            if (i % 50 == 49) {
                // Every held snapshot must still read exactly what was saved.
                for (held.items) |h| {
                    mismatches += countMismatches(h.snap.view(&db).seek(0), null, h.saved);
                    snapshots_checked += 1;
                }
                try lib.validate(&db, gpa);
            }
        }
        const pages_at_end = db.store.pageCount();
        while (held.pop()) |h| {
            _ = db.release(h.snap);
            gpa.free(h.saved);
        }
        try lib.validate(&db, gpa);
        const s = db.stats;
        try w.print("M={d:<2} keys={d} height={d} commits={d} | pages: store={d} copied={d} reused={d} fresh={d} released={d} peak pending={d} | snapshot checks={d} mismatches={d}\n", .{
            order,             db.len(),       db.current.height, s.commits,        pages_at_end,
            s.pages_copied,    s.pages_reused, s.pages_fresh,     s.pages_released, peak_pending,
            snapshots_checked, mismatches,
        });
    }
}

/// Compares what the cursor yields, up to `hi` (exclusive; null = to the
/// end of the tree), with `expected`.
fn countMismatches(cursor: lib.Cursor, hi: ?u64, expected: []const lib.ops.Entry) usize {
    var mismatches: usize = 0;
    var it = cursor;
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        if (hi != null and e.key >= hi.?) break;
        if (i >= expected.len or e.key != expected[i].key or e.value != expected[i].value) mismatches += 1;
    }
    if (i < expected.len) mismatches += expected.len - i;
    return mismatches;
}

test "run prints exactly expected_output.txt" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
