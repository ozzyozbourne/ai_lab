//! tests.zig: the log, recovery, and the crash loop.
const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
const page_storage = @import("base_page_storage.zig");
const Page = page_storage.Page;
const page_size = page_storage.page_size;
const btree = @import("base_disk_btree.zig");
const wal_mod = @import("wal.zig");
const db_mod = @import("db.zig");
const Db = db_mod.Db;
const crash = @import("crash.zig");
const demo = @import("demo.zig");

/// `n` copies of one byte, as a compile-time constant.
fn rep(comptime c: u8, comptime n: usize) *const [n]u8 {
    const bytes: [n]u8 = comptime @splat(c);
    return &bytes;
}

fn openDb(machine: *Machine, options: db_mod.Options) !*Db {
    return Db.open(testing.allocator, machine.mainStorage(), machine.logStorage(), options);
}

fn expectValue(db: *Db, key: []const u8, expected: ?[]const u8) !void {
    const got = try db.get(testing.allocator, key);
    defer if (got) |v| testing.allocator.free(v);
    if (expected) |e| try testing.expectEqualStrings(e, got orelse return error.TestExpectedEqual) else try testing.expectEqual(null, got);
}

// ---- THE central test ---------------------------------------------------------

fn expectAllExact(loop: crash.Loop) !void {
    for (loop.tallies) |t| {
        try testing.expectEqual(loop.total_writes + 1, t.runs);
        try testing.expectEqual(t.runs, t.exact()); // never invalid, never a mix, never a lost key
        try testing.expect(t.before > 0 and t.after > 0);
    }
}

test "crash after every write, in every crash mode: recovery gives the before or the after state" {
    const wl = crash.small;
    // The workload must be worth the trouble: leaf, interior and root splits.
    const clean = try crash.runWithLog(testing.allocator, wl, null, null, .drop, .{});
    try testing.expectEqual(wl.puts, clean.acked);
    try testing.expect(clean.stats.leaf_splits >= 10 and clean.stats.interior_splits >= 1 and clean.stats.root_splits >= 2);

    // A 2-frame pool: dirty pages are evicted in the middle of every split.
    // (The demo runs the same loop with 3 frames and a checkpoint every 4.)
    const loop = try crash.crashLoop(testing.allocator, wl, true, .{ .frames = 2, .checkpoint_every = 3 });
    try expectAllExact(loop);
}

test "the same loop without the log fails: the control experiment" {
    const loop = try crash.crashLoop(testing.allocator, crash.small, false, .{});
    const drop = loop.tallies[0];
    const keep = loop.tallies[1];
    const tear = loop.tallies[2];
    const random = loop.tallies[3];
    // If every unsynced write vanishes the file is always the last flushed
    // one. That is luck with this crash mode, not a property of the tree.
    try testing.expectEqual(drop.runs, drop.before);
    // Any other fate of the unsynced writes breaks the tree most of the time.
    for ([_]crash.Tally{ keep, tear, random }) |t| try testing.expect(t.invalid > t.runs / 2);
    // Worst of all: a tree that validates but lost acknowledged keys.
    try testing.expect(random.wrong_contents > 0);
}

test "long crash loop (only with -Dlong=true)" {
    if (!build_options.long) return error.SkipZigTest;
    const loop = try crash.crashLoop(testing.allocator, crash.long, true, .{ .frames = 4, .checkpoint_every = 7 });
    try expectAllExact(loop);
}

test "a batch commits all of its puts or none, at every crash point" {
    const pairs = [_]db_mod.KeyValue{
        .{ .key = "b1", .value = rep('x', 900) }, .{ .key = "b2", .value = rep('y', 900) }, .{ .key = "b3", .value = rep('z', 900) },
        .{ .key = "b4", .value = rep('u', 900) }, .{ .key = "b5", .value = rep('v', 900) }, .{ .key = "b6", .value = rep('w', 900) },
    };
    var none: u32 = 0;
    var all: u32 = 0;
    var n: u64 = 0;
    while (true) : (n += 1) {
        var machine: Machine = .init(testing.allocator, n);
        defer machine.deinit();
        {
            const db = try openDb(&machine, .{});
            defer db.close();
            try db.put("a0", "already here");
            machine.powerOffAfterWrites(n);
            db.putBatch(&pairs) catch {};
        }
        const finished = !machine.isPoweredOff();
        machine.crash(.random);
        const db = try openDb(&machine, .{});
        defer db.close();
        try db.validate();
        try expectValue(db, "a0", "already here");
        var present: u32 = 0;
        for (pairs) |kv| {
            const got = try db.get(testing.allocator, kv.key);
            if (got) |v| {
                defer testing.allocator.free(v);
                try testing.expectEqualStrings(kv.value, v);
                present += 1;
            }
        }
        try testing.expect(present == 0 or present == pairs.len);
        if (present == 0) none += 1 else all += 1;
        if (finished) break;
    }
    try testing.expect(none > 0 and all > 0);
    try testing.expect(n >= 6); // the batch split leaves: several log pages
}

// ---- the write-ahead rule ------------------------------------------------------

test "write-ahead rule: no main-file write while the log has unsynced records" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    machine.tracing = true;
    const db = try openDb(&machine, .{ .frames = 2, .checkpoint_every = 3 });
    defer db.close();
    var key_buf: [btree.max_key_len]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    for (0..crash.small.puts) |i| {
        const o = crash.small.op(@intCast(i), &key_buf, &value_buf);
        try db.put(o.key, o.value);
    }
    var log_unsynced = false;
    var main_writes: u32 = 0;
    for (machine.trace.items) |e| switch (e.file) {
        .log => log_unsynced = e.kind == .write,
        .main => if (e.kind == .write) {
            try testing.expect(!log_unsynced);
            main_writes += 1;
        },
    };
    try testing.expect(main_writes > 0);
    try testing.expectEqual(db.wal.stats.main_page_writes, main_writes);
}

test "eviction goes through the log: a 2-frame pool never touches the main file before a checkpoint" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    var key_buf: [btree.max_key_len]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    {
        const db = try openDb(&machine, .{ .frames = 2, .checkpoint_every = 0 });
        defer db.close();
        for (0..crash.small.puts) |i| {
            const o = crash.small.op(@intCast(i), &key_buf, &value_buf);
            try db.put(o.key, o.value);
        }
        try testing.expect(db.pool.stats.writebacks > 0); // dirty pages were evicted mid-operation
        try testing.expectEqual(0, db.wal.stats.main_page_writes);
        try testing.expectEqual(0, machine.main.size()); // the main file does not even exist yet
        try db.validate(); // every read is served from the log's images
    }
    machine.crash(.drop);
    const db = try openDb(&machine, .{});
    defer db.close();
    try testing.expectEqual(crash.small.puts + 1, db.recovery.committed_ops); // + the creation
    try testing.expect(machine.main.size() > 0);
    try db.validate();
}

// ---- the checksum chain ----------------------------------------------------------

/// Three one-key commits after the creation: 4 commits of 2 page images each.
fn threeCommits(machine: *Machine) !void {
    const db = try openDb(machine, .{ .checkpoint_every = 0 });
    defer db.close();
    try db.put("a", "1");
    try db.put("b", "2");
    try db.put("c", "3");
    try testing.expectEqual(4, db.wal.stats.commits);
    try testing.expectEqual(8, db.wal.stats.page_records);
}

test "recovery stops at the first record whose checksum chain breaks" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    try threeCommits(&machine);

    // Flip one bit inside the first record of the commit of "b": record 7,
    // which starts 2 commits (2 * (2 * 4120 + 24) bytes) into the records.
    const offset = wal_mod.log_start + 2 * (2 * (wal_mod.record_header_len + page_size) + wal_mod.record_header_len) + 100;
    var page: Page = undefined;
    try machine.logStorage().readPage(offset / page_size, &page);
    page[offset % page_size] ^= 0x10;
    try machine.logStorage().writePage(offset / page_size, &page);
    try machine.logStorage().sync();

    const db = try openDb(&machine, .{});
    defer db.close();
    try testing.expectEqual(6, db.recovery.valid_records);
    try testing.expectEqual(2, db.recovery.committed_ops); // creation and "a"
    try db.validate();
    try expectValue(db, "a", "1");
    try expectValue(db, "b", null);
    // "c" is lost too, although its own bytes are intact: a record is only
    // as good as the chain in front of it.
    try expectValue(db, "c", null);
}

test "a trailing operation without a commit record is ignored" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    try threeCommits(&machine);
    // Zero the last 24 bytes of the log: the commit record of "c".
    const end = wal_mod.log_start + 4 * (2 * (wal_mod.record_header_len + page_size) + wal_mod.record_header_len);
    var page: Page = undefined;
    try machine.logStorage().readPage((end - 1) / page_size, &page);
    @memset(page[(end - 24) % page_size ..][0..24], 0);
    try machine.logStorage().writePage((end - 1) / page_size, &page);
    try machine.logStorage().sync();

    const db = try openDb(&machine, .{});
    defer db.close();
    try testing.expectEqual(11, db.recovery.valid_records);
    try testing.expectEqual(3, db.recovery.committed_ops);
    try testing.expectEqual(2, db.recovery.uncommitted_records);
    try expectValue(db, "b", "2");
    try expectValue(db, "c", null);
}

test "records of an earlier generation are stale: they do not chain from the new header" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    {
        const db = try openDb(&machine, .{ .checkpoint_every = 0 });
        defer db.close();
        try db.put("a", "1");
        try db.put("b", "2");
        try db.checkpoint(); // new generation; the 9 old records stay in the file
        try db.put("c", "3"); // overwrites the first three of them
        try testing.expectEqual(2, db.wal.generation);
    }
    try testing.expect(machine.log.size() > 4); // the old records are physically still there
    var scanner: wal_mod.LogScanner = try .init(machine.logStorage());
    var image: Page = undefined;
    var records: u32 = 0;
    var first_lsn: u64 = 0;
    while (try scanner.next(&image)) |rec| : (records += 1) {
        if (records == 0) first_lsn = rec.lsn;
    }
    try testing.expectEqual(3, records); // two page images and a commit: only "c"
    try testing.expectEqual(10, first_lsn); // LSNs continue across generations: 1..9 were used

    const db = try openDb(&machine, .{});
    defer db.close();
    try testing.expectEqual(1, db.recovery.committed_ops);
    try expectValue(db, "a", "1");
    try expectValue(db, "c", "3");
}

test "a damaged page in the main file is detected by its checksum" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    {
        const db = try openDb(&machine, .{});
        defer db.close();
        try db.put("a", "1");
        try db.checkpoint();
    }
    var page: Page = undefined;
    try machine.mainStorage().readPage(1, &page);
    page[2000] ^= 1;
    try machine.mainStorage().writePage(1, &page);
    try machine.mainStorage().sync();

    const db = try openDb(&machine, .{}); // the metapage is fine
    defer db.close();
    try testing.expectError(error.StorageFailure, db.get(testing.allocator, "a"));
    try testing.expectEqual(1, db.wal.stats.checksum_failures);
}

// ---- memory ------------------------------------------------------------------------

test "the record buffer is a hard limit: CommitTooLarge" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    {
        // Room for 2 page images per commit: enough for a put into the root
        // leaf (leaf + metapage), not for a split (4 pages).
        const db = try openDb(&machine, .{ .max_commit_pages = 2 });
        defer db.close();
        try db.put("a", rep('1', 1000));
        try db.put("b", rep('2', 1000));
        try db.put("c", rep('3', 1000));
        try testing.expectError(error.StorageFailure, db.put("d", rep('4', 1000))); // the root splits
        try testing.expectEqual(error.CommitTooLarge, db.wal.last_error.?);
    }
    machine.crash(.keep);
    const db = try openDb(&machine, .{});
    defer db.close();
    try db.validate();
    try expectValue(db, "c", rep('3', 1000));
    try expectValue(db, "d", null); // nothing of the failed operation reached a file
}

test "allocation failure at any point leaves a recoverable database and leaks nothing" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var machine: Machine = .init(testing.allocator, 1);
        defer machine.deinit();
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        var acked: usize = 0;
        run: {
            const db = Db.open(failing.allocator(), machine.mainStorage(), machine.logStorage(), .{ .frames = 3, .checkpoint_every = 2 }) catch break :run;
            defer db.close();
            for (demo.scenario_keys) |k| {
                const key = [2]u8{ '0' + k / 10, '0' + k % 10 };
                db.put(&key, rep('v', 700)) catch break :run;
                acked += 1;
            }
        }
        // Whatever happened, a healthy process can open the files.
        machine.crash(.keep);
        const db = try openDb(&machine, .{});
        defer db.close();
        try db.validate();
        try testing.expect(db.tree.key_count == acked or db.tree.key_count == acked + 1);
        for (demo.scenario_keys[0..acked]) |k| try expectValue(db, &.{ '0' + k / 10, '0' + k % 10 }, rep('v', 700));
        if (!failing.has_induced_failure) break;
    }
    try testing.expect(fail_index > 20); // many distinct failure points were exercised
}

test "PageTable keeps images sorted by page id and replaces in place" {
    var table: wal_mod.PageTable = .{};
    defer table.deinit(testing.allocator);
    var page: Page = @splat('a');
    try table.put(testing.allocator, 7, &page);
    try table.put(testing.allocator, 2, &page);
    page = @splat('b');
    try table.put(testing.allocator, 7, &page);
    try testing.expectEqual(2, table.len());
    try testing.expectEqual(8, table.pageCount());
    try testing.expectEqual(2, table.entries.items[0].id);
    try testing.expectEqual('b', table.find(7).?[0]);
    try testing.expectEqual(null, table.find(3));
}
