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
const DiskBTree = btree.DiskBTree;
const crash = @import("crash.zig");
const demo = @import("demo.zig");
const crc = @import("crc32.zig");

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

test "the two files fare differently in the power cut: still the before or the after state" {
    // Nothing ties the fate of the log's unsynced writes to that of the main
    // file's. The first pair is the write-ahead rule seen from outside: the
    // main file keeps every write and the log loses every unsynced one, so
    // a page that reached the main file before its log record was durable
    // would stay there with nothing to explain it.
    const wl = crash.small;
    const always = [_]crash.Fates{ .{ .main = .keep, .log = .drop }, .{ .main = .drop, .log = .keep } };
    // Two more pairs with torn pages, taking turns to keep the test short.
    const in_turn = [_]crash.Fates{ .{ .main = .tear, .log = .random }, .{ .main = .random, .log = .tear } };
    const clean = try crash.runWithLog(testing.allocator, wl, null, null, .drop, .{});
    var tally: crash.Tally = .{};
    var n: u64 = 0;
    while (n <= clean.writes) : (n += 1) {
        for (always ++ .{in_turn[n % 2]}) |fates| {
            const r = try crash.runCut(testing.allocator, wl, .{ .after_write = n }, null, fates, .{});
            tally.add(r.outcome);
        }
    }
    try testing.expectEqual(3 * (clean.writes + 1), tally.runs);
    try testing.expectEqual(tally.runs, tally.exact());
    try testing.expect(tally.before > 0 and tally.after > 0);
}

test "a sync that completes but reports the power cut: the put failed and is stored" {
    // "After write N" never stops the machine between a sync and its
    // return. Here it stops exactly there, at every sync of the workload.
    const wl = crash.small;
    const options: db_mod.Options = .{ .frames = 2, .checkpoint_every = 3 };
    const clean = try crash.runWithLog(testing.allocator, wl, null, null, .drop, options);
    try testing.expect(clean.syncs > wl.puts); // commits, and the two syncs of each checkpoint
    for (crash.modes) |mode| {
        var tally: crash.Tally = .{};
        var k: u64 = 1;
        while (k <= clean.syncs) : (k += 1) {
            const r = try crash.runCut(testing.allocator, wl, .{ .at_sync = k }, null, .{ .main = mode, .log = mode }, options);
            try testing.expectEqual(k, r.syncs);
            tally.add(r.outcome);
        }
        try testing.expectEqual(tally.runs, tally.exact());
        // Syncs 1 and 2 belong to `open` (the first log header, the commit
        // that creates the tree). Every later one is part of a put: the log
        // sync of its commit, or a sync of the checkpoint behind it. The
        // commit record is durable in all of them, so the put that returned
        // an error is in the database: "outcome unknown" is not "not stored".
        try testing.expectEqual(2, tally.before);
        try testing.expectEqual(clean.syncs - 2, tally.after);
    }
}

test "a second power cut during recovery, in the modes the demo leaves out" {
    // The demo prints this loop for `keep` and `random`. `tear` is the mode
    // in which recovery finds a main-file page that its own first attempt
    // tore, and must simply write it again.
    const wl = crash.small;
    const options: db_mod.Options = .{ .frames = 3 };
    const clean = try crash.runWithLog(testing.allocator, wl, null, null, .drop, options);
    var runs: u32 = 0;
    var n: u64 = 2;
    while (n <= clean.writes) : (n += 11) {
        for ([_]crash.CrashMode{ .drop, .tear }) |mode| {
            var m: u64 = 0;
            while (true) : (m += 1) {
                const r = try crash.runWithLog(testing.allocator, wl, n, m, mode, options);
                if (!r.second_crash_hit) break; // recovery finished before write m
                try testing.expect(r.outcome == .before or r.outcome == .after);
                runs += 1;
            }
        }
    }
    try testing.expect(runs > 50);
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

test "a batch with a pair the tree would refuse is refused whole, and the handle stays usable" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    {
        const db = try openDb(&machine, .{});
        defer db.close();
        try db.put("a", "1");
        // The bad pair is the second of three. Nothing of the batch may be
        // applied, not even to the pages in memory.
        try testing.expectError(error.KeyTooLarge, db.putBatch(&.{
            .{ .key = "b1", .value = "x" },
            .{ .key = rep('k', btree.max_key_len + 1), .value = "y" },
            .{ .key = "b3", .value = "z" },
        }));
        try testing.expectError(error.ValueTooLarge, db.putBatch(&.{
            .{ .key = "b1", .value = "x" },
            .{ .key = "b2", .value = rep('v', btree.max_value_len + 1) },
        }));
        try testing.expectError(error.KeyTooLarge, db.put(rep('k', btree.max_key_len + 1), "y"));
        try expectValue(db, "b1", null);
        // Nothing was touched, so this is not a failed handle...
        try testing.expect(!db.failed);
        try db.put("c", "3");
    }
    machine.crash(.drop);
    const db = try openDb(&machine, .{});
    defer db.close();
    // ... and the put that followed did not commit half of the batch.
    try expectValue(db, "b1", null);
    try expectValue(db, "b3", null);
    try expectValue(db, "c", "3");
}

test "a batch that fails after its first put: the handle refuses everything until it is reopened" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    {
        // Five keys of 1000 bytes: an interior root (page 1) and two leaves
        // (pages 2 and 3), all of them checkpointed into the main file.
        const db = try openDb(&machine, .{});
        defer db.close();
        for ("abcde") |c| try db.put(&.{c}, rep('1', 1000));
        try db.checkpoint();
        try testing.expectEqual(4, machine.main.size());
    }
    // Damage the right leaf in the main file. Its checksum will not verify.
    var page: Page = undefined;
    try machine.mainStorage().readPage(3, &page);
    page[2000] ^= 1;
    try machine.mainStorage().writePage(3, &page);
    try machine.mainStorage().sync();
    {
        const db = try openDb(&machine, .{});
        defer db.close();
        try expectValue(db, "a", rep('1', 1000)); // the left leaf is fine
        try testing.expectError(error.StorageFailure, db.get(testing.allocator, "e"));
        try testing.expect(!db.failed); // a failed read changes nothing

        // "a2" goes into the left leaf; "e2" needs the damaged one.
        try testing.expectError(error.StorageFailure, db.putBatch(&.{ .{ .key = "a2", .value = "x" }, .{ .key = "e2", .value = "y" } }));
        // "a2" now sits in a dirty page of the buffer pool. Without the
        // `failed` flag the next put would log that page and commit half of
        // the batch, and a `get` would already show it.
        try testing.expect(db.failed);
        try testing.expectError(error.ReopenRequired, db.put("b2", "z"));
        try testing.expectError(error.ReopenRequired, db.putBatch(&.{.{ .key = "b2", .value = "z" }}));
        try testing.expectError(error.ReopenRequired, db.get(testing.allocator, "a2"));
        try testing.expectError(error.ReopenRequired, db.range("", null));
        try testing.expectError(error.ReopenRequired, db.validate());
        try testing.expectError(error.ReopenRequired, db.checkpoint());
    }
    machine.crash(.keep);
    const db = try openDb(&machine, .{});
    defer db.close();
    try testing.expectEqual(0, db.recovery.valid_records); // the failed batch never reached the log
    try expectValue(db, "a2", null);
    try expectValue(db, "b2", null);
    try expectValue(db, "a", rep('1', 1000));
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

// ---- forged logs -------------------------------------------------------------------

/// Copy `out.len` bytes of the log file, starting at byte `offset`.
fn readLog(machine: *Machine, offset: u64, out: []u8) !void {
    var page: Page = undefined;
    var done: usize = 0;
    while (done < out.len) {
        const at = offset + done;
        const in_page: usize = @intCast(at % page_size);
        try machine.logStorage().readPage(at / page_size, &page);
        const n = @min(out.len - done, page_size - in_page);
        @memcpy(out[done..][0..n], page[in_page..][0..n]);
        done += n;
    }
}

/// Overwrite bytes of the log file, starting at byte `offset`, and sync.
/// Everything else in the file stays as it is.
fn writeLog(machine: *Machine, offset: u64, bytes: []const u8) !void {
    var page: Page = undefined;
    var done: usize = 0;
    while (done < bytes.len) {
        const at = offset + done;
        const in_page: usize = @intCast(at % page_size);
        page = @splat(0);
        if (at / page_size < machine.log.size()) try machine.logStorage().readPage(at / page_size, &page);
        const n = @min(bytes.len - done, page_size - in_page);
        @memcpy(page[in_page..][0..n], bytes[done..][0..n]);
        try machine.logStorage().writePage(at / page_size, &page);
        done += n;
    }
    try machine.logStorage().sync();
}

/// Writes a log by hand, from the format table at the top of wal.zig and
/// from nothing else: it calls no function of wal.zig. So these tests also
/// pin the format, and they can write logs the real writer never would.
const Forge = struct {
    bytes: std.ArrayList(u8) = .empty,
    chain: u32 = 0,

    fn deinit(self: *Forge) void {
        self.bytes.deinit(testing.allocator);
    }

    /// Start over with a header page.
    fn header(self: *Forge, generation: u64, first_lsn: u64) !void {
        var page: Page = @splat(0);
        @memcpy(page[0..8], "WAL22\x00\x00\x00");
        std.mem.writeInt(u32, page[8..12], 1, .little);
        std.mem.writeInt(u32, page[12..16], 4096, .little);
        std.mem.writeInt(u64, page[16..24], generation, .little);
        std.mem.writeInt(u64, page[24..32], first_lsn, .little);
        self.chain = crc.crc32(page[0..32]);
        std.mem.writeInt(u32, page[32..36], self.chain, .little);
        self.bytes.clearRetainingCapacity();
        try self.bytes.appendSlice(testing.allocator, &page);
    }

    /// Append one record, chained from the one before it.
    fn record(self: *Forge, lsn: u64, kind: u32, arg: u32, payload: []const u8) !void {
        var head: [24]u8 = undefined;
        std.mem.writeInt(u64, head[0..8], lsn, .little);
        std.mem.writeInt(u32, head[8..12], kind, .little);
        std.mem.writeInt(u32, head[12..16], arg, .little);
        std.mem.writeInt(u32, head[16..20], @intCast(payload.len), .little);
        var prev: [4]u8 = undefined;
        std.mem.writeInt(u32, &prev, self.chain, .little);
        self.chain = crc.crc32Update(crc.crc32Update(crc.crc32(&prev), head[0..20]), payload);
        std.mem.writeInt(u32, head[20..24], self.chain, .little);
        try self.bytes.appendSlice(testing.allocator, &head);
        try self.bytes.appendSlice(testing.allocator, payload);
    }

    /// One operation: page 0 and page 1, then the commit record.
    fn operation(self: *Forge, first_lsn: u64, images: *const [2]Page) !void {
        try self.record(first_lsn, 1, 0, &images[0]);
        try self.record(first_lsn + 1, 1, 1, &images[1]);
        try self.record(first_lsn + 2, 2, 2, "");
    }

    /// Put the forged bytes at the front of the machine's log file.
    fn install(self: *const Forge, machine: *Machine) !void {
        try writeLog(machine, 0, self.bytes.items);
    }
};

const image_record_len = wal_mod.record_header_len + page_size;
/// Bytes of one operation of 2 page images.
const operation_len = 2 * image_record_len + wal_mod.record_header_len;

/// A machine whose main file holds "a" and whose log holds two committed
/// operations, put "b" and put "c": the raw material of the forgeries.
const Forgery = struct {
    machine: Machine,
    generation: u64 = 0,
    /// LSN of the first record in the log.
    lsn: u64 = 0,
    /// Pages 0 and 1 (metapage and root leaf) as put "b" and put "c" logged them.
    b: [2]Page = undefined,
    c: [2]Page = undefined,
    /// The log file as the real writer left it: the header and 6 records.
    original: [page_size + 2 * operation_len]u8 = undefined,

    /// In place: the machine must not move once a storage points at it.
    fn init(self: *Forgery) !void {
        self.* = .{ .machine = .init(testing.allocator, 1) };
        errdefer self.machine.deinit();
        {
            const db = try openDb(&self.machine, .{ .checkpoint_every = 0 });
            defer db.close();
            try db.put("a", "1");
            try db.checkpoint();
            try db.put("b", "2");
            try db.put("c", "3");
        }
        try readLog(&self.machine, 0, &self.original);
        self.generation = std.mem.readInt(u64, self.original[16..24], .little);
        self.lsn = std.mem.readInt(u64, self.original[24..32], .little);
        // Generation 1 held the creation and "a": records 1 to 6.
        try testing.expectEqual(2, self.generation);
        try testing.expectEqual(7, self.lsn);
        const records = self.original[page_size..];
        self.b[0] = records[wal_mod.record_header_len..][0..page_size].*;
        self.b[1] = records[image_record_len + wal_mod.record_header_len ..][0..page_size].*;
        self.c[0] = records[operation_len + wal_mod.record_header_len ..][0..page_size].*;
        self.c[1] = records[operation_len + image_record_len + wal_mod.record_header_len ..][0..page_size].*;
    }

    fn deinit(self: *Forgery) void {
        self.machine.deinit();
    }

    /// Open the database and compare what recovery found and which of the
    /// keys "b" and "c" exist afterwards. "a" must always be there.
    fn expectRecovery(self: *Forgery, valid_records: u32, committed_ops: u32, has_b: bool, has_c: bool) !void {
        const db = try openDb(&self.machine, .{});
        defer db.close();
        try testing.expectEqual(valid_records, db.recovery.valid_records);
        try testing.expectEqual(committed_ops, db.recovery.committed_ops);
        try db.validate();
        try expectValue(db, "a", "1");
        try expectValue(db, "b", if (has_b) "2" else null);
        try expectValue(db, "c", if (has_c) "3" else null);
    }
};

test "forged log: written by hand from the format table, it equals the real log byte for byte" {
    var fx: Forgery = undefined;
    try fx.init();
    defer fx.deinit();
    var forge: Forge = .{};
    defer forge.deinit();
    try forge.header(fx.generation, fx.lsn);
    try forge.operation(fx.lsn, &fx.b);
    try forge.operation(fx.lsn + 3, &fx.c);
    try testing.expectEqualSlices(u8, &fx.original, forge.bytes.items);
    try forge.install(&fx.machine);
    try fx.expectRecovery(6, 2, true, true);
}

test "forged log: a record with the wrong LSN ends the scan although its checksum chains" {
    {
        // A gap: the second operation carries LSNs 11 to 13 instead of 10 to 12.
        var fx: Forgery = undefined;
        try fx.init();
        defer fx.deinit();
        var forge: Forge = .{};
        defer forge.deinit();
        try forge.header(fx.generation, fx.lsn);
        try forge.operation(fx.lsn, &fx.b);
        try forge.operation(fx.lsn + 4, &fx.c);
        try forge.install(&fx.machine);
        try fx.expectRecovery(3, 1, true, false);
    }
    {
        // The very first record is one too low for what the header announces.
        var fx: Forgery = undefined;
        try fx.init();
        defer fx.deinit();
        var forge: Forge = .{};
        defer forge.deinit();
        try forge.header(fx.generation, fx.lsn);
        try forge.operation(fx.lsn - 1, &fx.b);
        try forge.install(&fx.machine);
        try fx.expectRecovery(0, 0, false, false);
    }
}

test "forged log: stale records with exactly the expected LSNs are rejected, they chain from another header" {
    var fx: Forgery = undefined;
    try fx.init();
    defer fx.deinit();
    var forge: Forge = .{};
    defer forge.deinit();
    // An older generation that happens to use the LSNs the new one will use.
    // (The real writer never reuses an LSN; the chain must not depend on it.)
    try forge.header(fx.generation - 1, fx.lsn);
    try forge.operation(fx.lsn, &fx.b);
    try forge.operation(fx.lsn + 3, &fx.c);
    try forge.install(&fx.machine);
    // The new generation overwrites the header and the first operation with
    // the same LSNs and the same page images. Behind them lies the old "c":
    // right position, right LSNs, a checksum that is good for the old chain.
    try forge.header(fx.generation, fx.lsn);
    try forge.operation(fx.lsn, &fx.b);
    try forge.install(&fx.machine);
    try fx.expectRecovery(3, 1, true, false);
}

test "a commit record with a damaged checksum commits nothing" {
    var fx: Forgery = undefined;
    try fx.init();
    defer fx.deinit();
    // One bit in the CRC field (bytes 20..24) of the commit record of "c".
    var byte = [1]u8{fx.original[page_size + 2 * operation_len - 4]};
    byte[0] ^= 0x01;
    try writeLog(&fx.machine, page_size + 2 * operation_len - 4, &byte);
    {
        const db = try openDb(&fx.machine, .{});
        defer db.close();
        try testing.expectEqual(2, db.recovery.uncommitted_records); // the two images of "c"
    }
    // (That open has already recovered: the log is empty now.)
    try fx.expectRecovery(0, 0, true, false);
}

test "a commit record that counts the wrong number of page records: LogCorrupt" {
    // No power cut produces this: the checksum is right, so the writer wrote
    // it. Recovery refuses to guess which pages belong to the operation.
    for ([_]u32{ 1, 3 }) |count| {
        var fx: Forgery = undefined;
        try fx.init();
        defer fx.deinit();
        var forge: Forge = .{};
        defer forge.deinit();
        try forge.header(fx.generation, fx.lsn);
        try forge.record(fx.lsn, 1, 0, &fx.b[0]);
        try forge.record(fx.lsn + 1, 1, 1, &fx.b[1]);
        try forge.record(fx.lsn + 2, 2, count, "");
        try forge.install(&fx.machine);
        const writes = fx.machine.writes;
        try testing.expectError(error.LogCorrupt, openDb(&fx.machine, .{}));
        try testing.expectEqual(writes, fx.machine.writes); // nothing was replayed, nothing reset
    }
}

test "a damaged log header is LogCorrupt, not an empty log; bytes behind sector 0 do not matter" {
    {
        var fx: Forgery = undefined;
        try fx.init();
        defer fx.deinit();
        // One bit of the generation. Treating this as "no log" would open the
        // database without "b" and "c", both acknowledged.
        try writeLog(&fx.machine, 16, &.{fx.original[16] ^ 0x01});
        try testing.expectError(error.LogCorrupt, openDb(&fx.machine, .{}));
    }
    {
        var fx: Forgery = undefined;
        try fx.init();
        defer fx.deinit();
        // The header page is rewritten in place at every reset. Only its
        // first sector carries anything; a tear further back is harmless.
        try writeLog(&fx.machine, page_storage.sector_size, &@as([page_size - page_storage.sector_size]u8, @splat(0xAB)));
        try fx.expectRecovery(6, 2, true, true);
    }
}

test "recovery leaves an empty log of the next generation, and LSNs go on behind every valid record" {
    var machine: Machine = .init(testing.allocator, 1);
    defer machine.deinit();
    try threeCommits(&machine); // generation 1, LSNs 1 to 12
    // Zero the commit record of "c" (LSN 12): records 10 and 11 stay valid.
    const zeros: [wal_mod.record_header_len]u8 = @splat(0);
    try writeLog(&machine, wal_mod.log_start + 4 * operation_len - zeros.len, &zeros);
    {
        const db = try openDb(&machine, .{ .checkpoint_every = 0 });
        defer db.close();
        try testing.expectEqual(1, db.recovery.generation);
        try testing.expectEqual(11, db.recovery.valid_records);
        // What is on disk now, not what the handle believes:
        var header: [36]u8 = undefined;
        try readLog(&machine, 0, &header);
        try testing.expectEqual(2, std.mem.readInt(u64, header[16..24], .little)); // generation
        try testing.expectEqual(12, std.mem.readInt(u64, header[24..32], .little)); // first LSN
        var scanner: wal_mod.LogScanner = try .init(machine.logStorage());
        var image: Page = undefined;
        try testing.expectEqual(null, try scanner.next(&image)); // the old records no longer chain
        try db.put("d", "4");
    }
    // LSNs 10 and 11 were handed out to records that never committed. They
    // are not handed out again: the new records start at 12.
    var scanner: wal_mod.LogScanner = try .init(machine.logStorage());
    var image: Page = undefined;
    for ([_]u64{ 12, 13, 14 }) |lsn| try testing.expectEqual(lsn, (try scanner.next(&image)).?.lsn);
    try testing.expectEqual(null, try scanner.next(&image));

    const db = try openDb(&machine, .{});
    defer db.close();
    try testing.expectEqual(2, db.recovery.generation);
    try testing.expectEqual(1, db.recovery.committed_ops);
    try expectValue(db, "b", "2");
    try expectValue(db, "c", null);
    try expectValue(db, "d", "4");
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
        try db.put("d", rep('4', 1000));
        try testing.expectError(error.StorageFailure, db.put("e", rep('5', 1000))); // the root splits
        try testing.expectEqual(error.CommitTooLarge, db.wal.last_error.?);
        // The pages of the split stay in memory, and nothing can take them
        // back: this handle is finished, also for a put that would fit.
        try testing.expectError(error.ReopenRequired, db.put("a", "small"));
        try testing.expectError(error.ReopenRequired, db.checkpoint());
    }
    machine.crash(.keep);
    const db = try openDb(&machine, .{});
    defer db.close();
    try db.validate();
    try expectValue(db, "d", rep('4', 1000));
    try expectValue(db, "e", null); // nothing of the failed operation reached a file
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
                db.put(&key, rep('v', 700)) catch {
                    // Memory is back at once (one refusal only), but the
                    // handle does not carry on with what the failure left.
                    try testing.expectError(error.ReopenRequired, db.put(&key, rep('v', 700)));
                    break :run;
                };
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

/// One put that splits, described by the split counters after it and by what
/// the tree asks its scratch arena for (chapter 12's test of the same name).
const OomCase = struct {
    leaf_splits: u64,
    interior_splits: u64,
    root_splits: u64,
    /// Scratch requests of that put, in order.
    requests: usize,
    /// The first request that comes after a page change. A failure from
    /// there on leaves a half-split tree; an earlier one leaves it intact.
    first_poisoned: usize,
};

/// Put key number `i` of the descending series: every put goes to the
/// leftmost leaf, and the largest cells allowed fill pages quickly.
fn oomKey(i: usize, key: *[btree.max_key_len]u8) void {
    key.* = @splat('k');
    _ = std.fmt.bufPrint(key[0..4], "{d:0>4}", .{9999 - i}) catch unreachable;
}

test "allocation failure at every scratch request of a put that splits: nothing of it survives a reopen" {
    // The test above fails the allocator behind the whole database, but the
    // tree's scratch arena hides most of the tree's requests from it: an
    // arena asks for memory only when its buffer is too small. Chapter 12
    // makes every request visible, and this is that test on top of the log:
    //
    //   - the handle gets a new tree object whose arena has no buffer yet;
    //   - the test fills the arena's first buffer to the last byte;
    //   - the buffer comes from a FixedBufferAllocator, which can grow its
    //     last allocation in place, so the arena grows its buffer by exactly
    //     the bytes of each request: one `resize` call per request.
    //
    // `resize_fail_index = i` refuses request i, `fail_index = 1` refuses the
    // new buffer the arena asks for after that. A put that fails after a
    // page change leaves a half-split tree in the buffer pool (chapter 12
    // calls the handle poisoned). With the log underneath that costs
    // nothing: no page of it was committed, so a reopen finds the tree as it
    // was before the put.
    const cases = [_]OomCase{
        // The first split: the root leaf moves down, then splits.
        .{ .leaf_splits = 1, .interior_splits = 0, .root_splits = 1, .requests = 4, .first_poisoned = 0 },
        // A leaf that is not the rightmost child splits, its parent has room.
        .{ .leaf_splits = 2, .interior_splits = 0, .root_splits = 1, .requests = 5, .first_poisoned = 4 },
        // The root is a full interior page: leaf split, root moves down, interior split.
        .{ .leaf_splits = 16, .interior_splits = 1, .root_splits = 2, .requests = 7, .first_poisoned = 4 },
    };
    const value: [btree.max_value_len]u8 = @splat('v');
    var key: [btree.max_key_len]u8 = undefined;
    var reached: usize = 0;

    for (cases) |case| {
        // How many puts until the split in question? `puts` counts it.
        var puts: usize = 0;
        {
            var machine: Machine = .init(testing.allocator, 1);
            defer machine.deinit();
            const db = try openDb(&machine, .{ .frames = 4 });
            defer db.close();
            while (db.tree.stats.leaf_splits != case.leaf_splits) : (puts += 1) {
                oomKey(puts, &key);
                try db.put(&key, &value);
            }
            try testing.expectEqual(case.interior_splits, db.tree.stats.interior_splits);
            try testing.expectEqual(case.root_splits, db.tree.stats.root_splits);
        }

        // Do that last put again and again, refusing request 0, 1, 2, ...
        // The last run refuses nothing and counts the requests.
        for (0..case.requests + 1) |fail_at| {
            var machine: Machine = .init(testing.allocator, 1);
            defer machine.deinit();
            {
                const db = try openDb(&machine, .{ .frames = 4 });
                defer db.close();
                for (0..puts - 1) |i| {
                    oomKey(i, &key);
                    try db.put(&key, &value);
                }
            }
            oomKey(puts - 1, &key);
            const writes_before = machine.writes;
            {
                const db = try openDb(&machine, .{ .frames = 4 }); // recovery replays the puts
                defer db.close();
                var scratch_bytes: [64 * 1024]u8 align(16) = undefined;
                var fixed: std.heap.FixedBufferAllocator = .init(&scratch_bytes);
                var failing: testing.FailingAllocator = .init(fixed.allocator(), .{});
                db.tree.deinit();
                db.tree = try DiskBTree.open(failing.allocator(), &db.pool);
                _ = try db.tree.arena.allocator().alloc(u8, 1);
                _ = try db.tree.arena.allocator().alloc(u8, db.tree.arena.queryCapacity() - 1);
                try testing.expectEqual(1, failing.alloc_index); // the arena's one buffer, now full
                try testing.expectEqual(0, failing.resize_index);
                failing.fail_index = 1;
                failing.resize_fail_index = fail_at;
                const writes_recovered = machine.writes;

                if (fail_at == case.requests) {
                    // Nothing refused: the put makes exactly the requests
                    // counted above, so the earlier runs reached all of them.
                    try db.put(&key, &value);
                    try testing.expectEqual(case.requests, failing.resize_index);
                    try testing.expect(!failing.has_induced_failure);
                    try db.validate();
                    try expectValue(db, &key, &value);
                    continue;
                }

                try testing.expectError(error.OutOfMemory, db.put(&key, &value));
                try testing.expectEqual(fail_at, failing.resize_index); // the requests before it were served
                try testing.expectEqual(0, db.pool.pinnedFrames());
                try testing.expectEqual(fail_at >= case.first_poisoned, db.tree.poisoned);
                reached += 1;
                failing.fail_index = std.math.maxInt(usize); // memory is back
                failing.resize_fail_index = std.math.maxInt(usize);
                // Half-split or not, the handle is finished ...
                try testing.expectError(error.ReopenRequired, db.put(&key, &value));
                try testing.expectError(error.ReopenRequired, db.get(testing.allocator, &key));
                // ... and the failed put wrote to neither file.
                try testing.expectEqual(writes_recovered, machine.writes);
            }
            try testing.expect(machine.writes > writes_before); // (recovery itself did write)
            machine.crash(.keep);
            const db = try openDb(&machine, .{ .frames = 4 });
            defer db.close();
            try testing.expectEqual(0, db.recovery.valid_records);
            try db.validate();
            try testing.expectEqual(puts - 1, db.tree.key_count);
            try expectValue(db, &key, null);
            try db.put(&key, &value); // and now it works
            try db.validate();
            try expectValue(db, &key, &value);
        }
    }
    try testing.expectEqual(4 + 5 + 7, reached);
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
