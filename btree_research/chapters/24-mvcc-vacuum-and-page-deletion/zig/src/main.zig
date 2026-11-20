//! Demo program of chapter 24. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Rust program's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const lib = @import("ch24_mvcc_vacuum_and_page_deletion");
const Db = lib.Db;
const Cursor = lib.Cursor;
const NodeId = lib.NodeId;

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &file_writer.interface;
    try run(init.gpa, w);
    try w.flush();
}

pub fn run(gpa: Allocator, w: *Writer) !void {
    try versionsAndHints(gpa, w);
    try vacuumAndPageDeletion(gpa, w);
    try recyclingTooEarly(gpa, w);
    try modelRuns(gpa, w);
}

// ------------------------------------------------------------- helpers

fn show(db: *const Db, w: *Writer) !void {
    try w.writeAll("  ");
    try lib.dump.dump(db, w);
    try w.flush(); // DEBUG
}

/// `put` plus one line saying which transaction it was and what the index
/// had to do to make room.
fn put(db: *Db, gpa: Allocator, w: *Writer, key: u64, value: u64) !void {
    const before = db.index.stats;
    const old = try db.put(gpa, key, value);
    try w.print("put {d}={d}: xid {d}", .{ key, value, db.store.now });
    if (old) |o| try w.print(", ends the version holding {d}", .{o});
    const s = db.index.stats;
    if (s.simple_deleted > before.simple_deleted) {
        try w.print("; page full: simple deletion removed {d}", .{s.simple_deleted - before.simple_deleted});
    }
    if (s.bottom_up_deleted > before.bottom_up_deleted) {
        try w.print("; page full: bottom-up deletion removed {d}", .{s.bottom_up_deleted - before.bottom_up_deleted});
    }
    if (s.leaf_splits > before.leaf_splits) {
        try w.writeAll("; page full: leaf split");
        if (s.pages_reused > before.pages_reused) try w.writeAll(" into a recycled page");
    }
    try w.writeByte('\n');
}

fn delete(db: *Db, w: *Writer, key: u64) !void {
    const old = db.delete(key);
    try w.print("delete {d}: xid {d}, sets xmax on the version holding {?d}; index untouched\n", .{ key, db.store.now, old });
}

/// Scans everything under `snapshot` and reports what the scan cost.
fn scan(db: *Db, w: *Writer, name: []const u8, snapshot: u64) !void {
    const before = db.reads;
    try w.print("scan under {s}={d}:", .{ name, snapshot });
    var cursor = Cursor.seek(db, snapshot, 0, std.math.maxInt(u64));
    while (try cursor.next(db)) |row| try w.print(" {d}={d}", .{ row.key, row.value });
    const r = db.reads;
    try w.print(" | heap fetches {d}, skipped by hint {d}, hints set {d}\n", .{
        r.heap_fetches - before.heap_fetches, r.hint_skips - before.hint_skips, r.hints_set - before.hints_set,
    });
}

fn vacuum(db: *Db, w: *Writer, options: lib.VacuumOptions) !void {
    const r = db.vacuum(options);
    try w.print("vacuum (horizon {d}): removed {d} entries, unlinked {d} pages, recycled {d}, waiting {d}\n", .{
        r.horizon, r.entries_removed, r.pages_unlinked, r.pages_recycled, r.pages_waiting,
    });
}

fn printRows(w: *Writer, cursor: *Cursor, db: *Db, limit: usize) !void {
    var n: usize = 0;
    while (n < limit) : (n += 1) {
        const row = try cursor.next(db) orelse break;
        try w.print(" {d}", .{row.key});
    }
}

// ------------------------------------------------------------ sections

fn versionsAndHints(gpa: Allocator, w: *Writer) !void {
    var db: Db = .init(4);
    defer db.deinit(gpa);

    try w.writeAll("== 1. Versions and snapshots (order M = 4: at most 3 entries per leaf) ==\n");
    for ([_]u64{ 10, 20, 30 }) |key| try put(&db, gpa, w, key, key * 10);
    const a = try db.store.openSnapshot();
    try w.print("open snapshot A = {d}\n", .{a});
    try put(&db, gpa, w, 20, 201);
    try delete(&db, w, 30);
    const b = try db.store.openSnapshot();
    try w.print("open snapshot B = {d}\n", .{b});
    try show(&db, w);
    for ([_]u64{ 20, 30 }) |key| {
        try w.print("get {d}: under A = {?d}, under B = {?d}\n", .{ key, try db.get(a, key), try db.get(b, key) });
    }

    try w.writeAll("\n== 2. A scan leaves hints, but only for versions dead to everyone ==\n");
    try scan(&db, w, "B", b);
    db.store.closeSnapshot(a);
    try w.print("close snapshot A: horizon is now {d}\n", .{db.store.horizon()});
    try scan(&db, w, "B", b);
    try show(&db, w);
    try scan(&db, w, "B", b);

    try w.writeAll("\n== 3. A full leaf: garbage first, split last ==\n");
    try put(&db, gpa, w, 25, 250);
    try put(&db, gpa, w, 27, 270);
    try show(&db, w);
    db.store.closeSnapshot(b);
    try w.print("close snapshot B: horizon is now {d}\n", .{db.store.horizon()});
    for ([_]u64{ 251, 252, 253 }) |value| try put(&db, gpa, w, 25, value);
    try show(&db, w);
    const c = try db.store.openSnapshot();
    try w.print("open snapshot C = {d}\n", .{c});
    for ([_]u64{ 254, 255 }) |value| try put(&db, gpa, w, 25, value);
    try show(&db, w);
    db.store.closeSnapshot(c);
    try db.validate();
    const s = db.index.stats;
    try w.print("totals: leaf splits {d}, splits avoided {d}, simple deletion {d}, bottom-up deletion {d}\n", .{
        s.leaf_splits, s.splits_avoided, s.simple_deleted, s.bottom_up_deleted,
    });
}

/// Twelve rows 10..120, then rows 40..90 deleted while snapshot R is open.
fn buildWithDeletedRange(db: *Db, gpa: Allocator) !u64 {
    var key: u64 = 10;
    while (key <= 120) : (key += 10) _ = try db.put(gpa, key, key * 10);
    const r = try db.store.openSnapshot();
    key = 40;
    while (key <= 90) : (key += 10) _ = db.delete(key);
    return r;
}

fn vacuumAndPageDeletion(gpa: Allocator, w: *Writer) !void {
    var db: Db = .init(4);
    defer db.deinit(gpa);

    try w.writeAll("\n== 4. VACUUM removes only what the oldest snapshot cannot see ==\n");
    const r = try buildWithDeletedRange(&db, gpa);
    try w.print("put 10..120 (xid 1..12), open snapshot R = {d}, delete 40..90 (xid 13..18)\n", .{r});
    try show(&db, w);
    try vacuum(&db, w, .{ .delete_pages = false });
    try scan(&db, w, "R", r);
    db.store.closeSnapshot(r);
    try w.print("close snapshot R: horizon is now {d}\n", .{db.store.horizon()});
    try vacuum(&db, w, .{ .delete_pages = false });
    try show(&db, w);

    try w.writeAll("\n== 5. Deleting an empty leaf: half-dead, unlinked, recycled ==\n");
    const s = try db.store.openSnapshot();
    var cursor = Cursor.seek(&db, s, 0, std.math.maxInt(u64));
    try w.print("open snapshot S = {d}; a scan under S returns:", .{s});
    try printRows(w, &cursor, &db, 2);
    const target = cursor.next_leaf;
    try w.print(" and pauses; the next page it will read is #{d}\n", .{target.index()});

    try w.print("phase 1, mark #{d} half-dead: {s}\n", .{ target.index(), if (db.index.markHalfDead(target)) "done" else "refused" });
    try show(&db, w);
    db.index.unlinkHalfDead(&db.store, db.index.leftSibling(target), target);
    try w.print("phase 2, unlink #{d}: stamped with epoch {d}\n", .{ target.index(), db.store.now });
    try show(&db, w);
    try w.print("recycle (horizon {d}): {d} pages\n", .{ db.store.horizon(), db.index.recycle(db.store.horizon()) });
    const moved_before = db.reads.moved_right;
    try w.writeAll("the scan resumes:");
    try printRows(w, &cursor, &db, 100);
    try w.print(" | moved right past {d} dead page(s)\n", .{db.reads.moved_right - moved_before});
    db.store.closeSnapshot(s);
    try w.print("close snapshot S; recycle (horizon {d}): {d} pages\n", .{ db.store.horizon(), db.index.recycle(db.store.horizon()) });
    try show(&db, w);
    try put(&db, gpa, w, 11, 110);
    try put(&db, gpa, w, 12, 120);
    try show(&db, w);
    try vacuum(&db, w, .{});
    try show(&db, w);
    const last = db.index.leftSibling(.nil);
    try w.print("mark the rightmost leaf #{d} half-dead: {s}\n", .{ last.index(), if (db.index.markHalfDead(last)) "done" else "refused" });
    try db.validate();
}

fn recyclingTooEarly(gpa: Allocator, w: *Writer) !void {
    var db: Db = .init(4);
    defer db.deinit(gpa);

    try w.writeAll("\n== 6. Recycling too early breaks a scan ==\n");
    const r = try buildWithDeletedRange(&db, gpa);
    db.store.closeSnapshot(r);
    _ = db.vacuum(.{ .delete_pages = false });
    const s = try db.store.openSnapshot();
    var cursor = Cursor.seek(&db, s, 0, std.math.maxInt(u64));
    try w.writeAll("same tree as in section 5; the scan returns:");
    try printRows(w, &cursor, &db, 2);
    const target = cursor.next_leaf;
    try w.print(" and pauses before #{d}\n", .{target.index()});
    _ = db.index.markHalfDead(target);
    db.index.unlinkHalfDead(&db.store, db.index.leftSibling(target), target);
    try w.print("#{d} is deleted with stamp {d}; snapshot S = {d} is older, but we recycle anyway: {d} page\n", .{
        target.index(), db.store.now, s, db.index.recycleIgnoringSnapshots(),
    });
    var early = cursor; // a copy of the paused scan
    if (early.next(&db)) |_| {
        try w.writeAll("the scan resumes: (unexpectedly fine)\n");
    } else |err| {
        try w.print("the scan resumes at once: error.{t} (the page is on the free list)\n", .{err});
    }
    try put(&db, gpa, w, 11, 110);
    try put(&db, gpa, w, 12, 120);
    try show(&db, w);
    try w.writeAll("the scan resumes after that:");
    try printRows(w, &cursor, &db, 100);
    try w.writeAll(" <- rows 100..120 are missing and the scan cannot tell\n");
}

const ModelConfig = struct {
    name: []const u8,
    order: usize,
    bottom_up: bool = true,
    /// Run VACUUM after every this many operations (0 = never).
    vacuum_every: u64 = 250,
};

/// 20000 random operations against the sorted-array oracle. Current reads
/// use a snapshot taken for the one read. In addition one long-lived
/// snapshot at a time is held for 300 operations together with a copy of the
/// oracle taken at the same moment, and must still read exactly that copy.
fn modelRuns(gpa: Allocator, w: *Writer) !void {
    try w.writeAll("\n== 7. Model run: 20000 random operations, long snapshots, different collectors ==\n");
    const configs = [_]ModelConfig{
        .{ .name = "M=4  all collectors      ", .order = 4 },
        .{ .name = "M=4  no bottom-up        ", .order = 4, .bottom_up = false },
        .{ .name = "M=4  hints only, no vacuum", .order = 4, .bottom_up = false, .vacuum_every = 0 },
        .{ .name = "M=16 all collectors      ", .order = 16 },
    };
    for (configs) |config| try modelRun(gpa, w, config);
}

fn modelRun(gpa: Allocator, w: *Writer, config: ModelConfig) !void {
    var db: Db = .init(config.order);
    defer db.deinit(gpa);
    db.index.bottom_up = config.bottom_up;
    var oracle: lib.ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var frozen: std.ArrayList(lib.ops.Entry) = .empty; // oracle copy of the long snapshot
    defer frozen.deinit(gpa);
    var long_snapshot: ?u64 = null;
    var stream = lib.ops.OpStream.init(.{ .seed = 24, .count = 20_000, .key_space = 400 });
    var mismatches: usize = 0;
    var step: u64 = 0;
    while (stream.next()) |op| : (step += 1) {
        switch (op) {
            .put => |p| {
                if (try db.put(gpa, p.key, p.value) != try oracle.put(gpa, p.key, p.value)) mismatches += 1;
            },
            .delete => |d| {
                if (db.delete(d.key) != oracle.delete(d.key)) mismatches += 1;
            },
            .get => |g| {
                const s = try db.store.openSnapshot();
                if (try db.get(s, g.key) != oracle.get(g.key)) mismatches += 1;
                db.store.closeSnapshot(s);
            },
            .range => |r| {
                const s = try db.store.openSnapshot();
                mismatches += try compareScan(&db, s, r.lo, r.hi, oracle.range(r.lo, r.hi));
                db.store.closeSnapshot(s);
            },
        }
        if (step % 500 == 100) {
            long_snapshot = try db.store.openSnapshot();
            frozen.clearRetainingCapacity();
            try frozen.appendSlice(gpa, oracle.entries.items);
        }
        if (step % 500 == 400) {
            mismatches += try compareScan(&db, long_snapshot.?, 0, 400, frozen.items);
            db.store.closeSnapshot(long_snapshot.?);
            long_snapshot = null;
        }
        if (config.vacuum_every != 0 and step % config.vacuum_every == config.vacuum_every - 1) _ = db.vacuum(.{});
    }
    try db.validate();
    const s = db.index.stats;
    try w.print("{s} | rows {d} entries {d} pages {d} slots {d} | splits {d} avoided {d} | removed: simple {d} bottom-up {d} vacuum {d} | pages unlinked {d} recycled {d} reused {d} | mismatches {d}\n", .{
        config.name,         oracle.len(),     db.index.count,         db.index.nodes.liveCount(), db.index.nodes.slotCount(),
        s.leaf_splits + s.internal_splits, s.splits_avoided, s.simple_deleted,       s.bottom_up_deleted,        s.vacuum_deleted,
        s.pages_unlinked,    s.pages_recycled, s.pages_reused,         mismatches,
    });
}

/// Number of differences between a scan of [lo, hi) and the expected rows.
fn compareScan(db: *Db, snapshot: u64, lo: u64, hi: u64, expected: []const lib.ops.Entry) !usize {
    var differences: usize = 0;
    var cursor = Cursor.seek(db, snapshot, lo, hi);
    for (expected) |e| {
        const row = try cursor.next(db);
        if (row == null or row.?.key != e.key or row.?.value != e.value) differences += 1;
    }
    if (try cursor.next(db) != null) differences += 1;
    return differences;
}

test "run prints exactly expected_output.txt" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
