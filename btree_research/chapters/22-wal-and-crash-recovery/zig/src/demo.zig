//! demo.zig: the fixed, deterministic scenario printed by `zig build run`.
//!
//! Part 1  no log: the leaf split of chapter 12 on a disk that loses power.
//!         (Visualization page 1 replays it.)
//! Part 2  the same split through the write-ahead log: the records of the
//!         commit, every storage write, and recovery after a power cut at
//!         each of them. (Visualization page 2 replays it.)
//! Part 3  the crash loop: a seeded workload, a power cut after every write,
//!         four crash modes, with the log and without it.
//! Part 4  what the log costs.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
const CrashMode = machine_mod.CrashMode;
const btree = @import("base_disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const Model = @import("base_workload.zig").Model;
const wal_mod = @import("wal.zig");
const db_mod = @import("db.zig");
const Db = db_mod.Db;
const crash = @import("crash.zig");

/// Chapter 12's scenario: the first eleven keys are stored, the twelfth
/// (key 15) splits a leaf under a parent that already exists.
pub const scenario_keys = [_]u8{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };
pub const old_keys = scenario_keys.len - 1;

fn scenarioKey(n: u8, buf: *[2]u8) []const u8 {
    buf.* = .{ '0' + n / 10, '0' + n % 10 };
    return buf;
}

/// 300 + 24 * n copies of one letter.
fn scenarioValue(n: u8, buf: *[btree.max_value_len]u8) []const u8 {
    const len = 300 + 24 * @as(usize, n);
    @memset(buf[0..len], 'a' + n % 26);
    return buf[0..len];
}

pub const State = enum { before, after, open_failed, invalid, wrong_contents };

/// What one interrupted split left behind.
pub const SplitOutcome = struct {
    state: State = .open_failed,
    /// The error of a failed open or validate.
    err: ?anyerror = null,
    recovery: wal_mod.Recovery = .{},
    /// Page writes of the split (and checkpoint) when nothing interrupts it.
    writes: u64 = 0,
};

/// Is the tree valid, and does it hold exactly the first 11 keys (before) or
/// all 12 (after)?
fn classify(gpa: Allocator, tree: *DiskBTree, outcome: *SplitOutcome) !void {
    tree.validate() catch |err| {
        outcome.state = .invalid;
        outcome.err = err;
        return;
    };
    var model: Model = .init(gpa);
    defer model.deinit();
    var key_buf: [2]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    for (scenario_keys[0..old_keys]) |n| try model.put(scenarioKey(n, &key_buf), scenarioValue(n, &value_buf));
    outcome.state = .wrong_contents;
    if (crash.sameContents(tree, &model)) outcome.state = .before;
    const last = scenario_keys[old_keys];
    try model.put(scenarioKey(last, &key_buf), scenarioValue(last, &value_buf));
    if (crash.sameContents(tree, &model)) outcome.state = .after;
}

fn printTrace(w: *Io.Writer, machine: *const Machine, new_page: u64) !void {
    var write_no: u32 = 0;
    var seen_new_page = false;
    for (machine.trace.items) |e| {
        if (e.kind == .sync) {
            try w.print("  sync {t}\n", .{e.file});
            continue;
        }
        write_no += 1;
        try w.print("  write {d}: {t} page {d}", .{ write_no, e.file, e.page_no });
        if (e.file == .main and e.page_no == new_page and !seen_new_page) {
            seen_new_page = true;
            if (machine.trace.items[0].file == .main) try w.writeAll("  (zeroes: the file grows by one page)");
        }
        try w.writeAll("\n");
    }
}

/// Part 1. Eleven keys flushed; then put 15 and flush, with the power
/// failing after `n` writes. `out` (clean run only) receives the narration.
pub fn splitWithoutLog(gpa: Allocator, n: ?u64, mode: CrashMode, out: ?*Io.Writer) !SplitOutcome {
    var machine: Machine = .init(gpa, 22);
    defer machine.deinit();
    var outcome: SplitOutcome = .{};
    var key_buf: [2]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    {
        var plain: crash.Plain = undefined;
        try plain.open(gpa, &machine);
        defer plain.close();
        for (scenario_keys[0..old_keys]) |k| try plain.tree.put(scenarioKey(k, &key_buf), scenarioValue(k, &value_buf));
        try plain.tree.flush();
        if (out) |w| {
            try w.print("{d} keys are on disk, flushed and synced:\n", .{old_keys});
            try plain.tree.dump(w);
        }
        const base = machine.writes;
        const new_page = plain.pager.pageCount();
        machine.tracing = true;
        if (n) |limit| machine.powerOffAfterWrites(limit);
        const last = scenario_keys[old_keys];
        const done = if (plain.tree.put(scenarioKey(last, &key_buf), scenarioValue(last, &value_buf))) |_| plain.tree.flush() else |err| err;
        done catch |err| if (!machine.isPoweredOff()) return err;
        outcome.writes = machine.writes - base;
        if (out) |w| {
            try w.print("put {s} splits leaf page 2; the new right half is page {d}. put + flush issue:\n", .{ scenarioKey(last, &key_buf), new_page });
            try printTrace(w, &machine, new_page);
            try w.writeAll("the tree after the split:\n");
            try plain.tree.dump(w);
        }
    }
    machine.crash(mode);

    var plain: crash.Plain = undefined;
    plain.open(gpa, &machine) catch |err| {
        outcome.err = err;
        return outcome;
    };
    defer plain.close();
    try classify(gpa, &plain.tree, &outcome);
    return outcome;
}

pub const split_write_count = 5;
pub const SplitWrite = struct { page_no: u64, image: wal_mod.Page };

/// The five page writes of the split of part 1, in order, with their bytes.
pub fn splitWrites(gpa: Allocator) ![split_write_count]SplitWrite {
    var machine: Machine = .init(gpa, 22);
    defer machine.deinit();
    var key_buf: [2]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    var plain: crash.Plain = undefined;
    try plain.open(gpa, &machine);
    defer plain.close();
    for (scenario_keys[0..old_keys]) |k| try plain.tree.put(scenarioKey(k, &key_buf), scenarioValue(k, &value_buf));
    try plain.tree.flush();
    machine.tracing = true;
    const last = scenario_keys[old_keys];
    try plain.tree.put(scenarioKey(last, &key_buf), scenarioValue(last, &value_buf));
    try plain.tree.flush();

    var writes: [split_write_count]SplitWrite = undefined;
    var count: usize = 0;
    for (machine.trace.items) |e| {
        if (e.kind != .write) continue;
        writes[count].page_no = e.page_no;
        // The first write is the zero page that grows the file; every later
        // one carries the final contents of its page.
        if (count == 0) writes[count].image = @splat(0) else try machine.mainStorage().readPage(e.page_no, &writes[count].image);
        count += 1;
    }
    std.debug.assert(count == split_write_count);
    return writes;
}

/// Part 1, the general case: the old tree is on disk, and of the five
/// writes exactly those whose bit is set in `mask` (bit i = write i + 1)
/// reached the disk before the power failed.
pub fn splitSubset(gpa: Allocator, writes: *const [split_write_count]SplitWrite, mask: u8) !SplitOutcome {
    var machine: Machine = .init(gpa, 22);
    defer machine.deinit();
    var outcome: SplitOutcome = .{};
    var key_buf: [2]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    {
        var plain: crash.Plain = undefined;
        try plain.open(gpa, &machine);
        defer plain.close();
        for (scenario_keys[0..old_keys]) |k| try plain.tree.put(scenarioKey(k, &key_buf), scenarioValue(k, &value_buf));
        try plain.tree.flush();
    }
    for (writes, 0..) |write, i| {
        if (mask & (@as(u8, 1) << @intCast(i)) != 0) try machine.mainStorage().writePage(write.page_no, &write.image);
    }
    try machine.mainStorage().sync();

    var plain: crash.Plain = undefined;
    plain.open(gpa, &machine) catch |err| {
        outcome.err = err;
        return outcome;
    };
    defer plain.close();
    try classify(gpa, &plain.tree, &outcome);
    return outcome;
}

/// Part 2. Eleven keys committed and checkpointed (the log is empty); then
/// put 15 (a commit) and a checkpoint, with the power failing after `n`
/// writes; then reopen, which runs recovery.
pub fn splitWithLog(gpa: Allocator, n: ?u64, mode: CrashMode, out: ?*Io.Writer) !SplitOutcome {
    var machine: Machine = .init(gpa, 22);
    defer machine.deinit();
    var outcome: SplitOutcome = .{};
    const options: db_mod.Options = .{ .checkpoint_every = 0 }; // checkpoints by hand here
    var key_buf: [2]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    {
        const db = try Db.open(gpa, machine.mainStorage(), machine.logStorage(), options);
        defer db.close();
        for (scenario_keys[0..old_keys]) |k| try db.put(scenarioKey(k, &key_buf), scenarioValue(k, &value_buf));
        try db.checkpoint();
        if (out) |w| try w.print("{d} keys are in the main file (checkpointed); the log is empty, generation {d}\n", .{ old_keys, db.wal.generation });
        const base = machine.writes;
        const new_page = db.pager.pageCount();
        machine.tracing = true;
        if (n) |limit| machine.powerOffAfterWrites(limit);
        const last = scenario_keys[old_keys];
        step: {
            db.put(scenarioKey(last, &key_buf), scenarioValue(last, &value_buf)) catch |err| {
                if (!machine.isPoweredOff()) return err;
                break :step;
            };
            if (out) |w| {
                try w.print("put {s} changes 4 pages in memory; its commit appends to the log:\n", .{scenarioKey(last, &key_buf)});
                try printLog(w, &machine);
            }
            db.checkpoint() catch |err| if (!machine.isPoweredOff()) return err;
        }
        outcome.writes = machine.writes - base;
        if (out) |w| {
            try w.writeAll("storage calls of the put and of the checkpoint after it:\n");
            try printTrace(w, &machine, new_page);
        }
    }
    machine.crash(mode);

    const db = Db.open(gpa, machine.mainStorage(), machine.logStorage(), options) catch |err| {
        outcome.err = err;
        return outcome;
    };
    defer db.close();
    outcome.recovery = db.recovery;
    try classify(gpa, &db.tree, &outcome);
    return outcome;
}

/// Walk the valid records of the log and print one line each.
fn printLog(w: *Io.Writer, machine: *Machine) !void {
    var scanner: wal_mod.LogScanner = try .init(machine.logStorage());
    var image: wal_mod.Page = undefined;
    while (try scanner.next(&image)) |rec| {
        try w.print("  LSN {d}  log bytes {d}..{d}  ", .{ rec.lsn, rec.offset, scanner.pos });
        if (rec.kind == wal_mod.kind_page) {
            try w.print("image of page {d}", .{rec.arg});
        } else {
            try w.print("commit ({d} pages)", .{rec.arg});
        }
        try w.print("  crc {x:0>8}\n", .{rec.crc});
    }
}

fn printOutcome(w: *Io.Writer, mode: CrashMode, o: SplitOutcome, with_log: bool) !void {
    try w.print("{t}: ", .{mode});
    try printState(w, o);
    if (with_log) try w.print(" [{d} records, {d} commit]", .{ o.recovery.valid_records, o.recovery.committed_ops });
}

fn printState(w: *Io.Writer, o: SplitOutcome) !void {
    switch (o.state) {
        .before, .after => try w.print("{t}", .{o.state}),
        .open_failed => try w.print("open fails ({t})", .{o.err.?}),
        .invalid => try w.print("invalid ({t})", .{o.err.?}),
        .wrong_contents => try w.writeAll("valid tree, wrong contents"),
    }
}

fn part1(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 1: no log: one leaf split on a disk that loses power ==\n");
    const clean = try splitWithoutLog(gpa, null, .drop, w);
    try w.writeAll("the power fails after N writes; the unsynced writes are then dropped, kept or torn:\n");
    var n: u64 = 0;
    while (n <= clean.writes) : (n += 1) {
        try w.print("N = {d}: ", .{n});
        for ([_]CrashMode{ .drop, .keep, .tear }, 0..) |mode, i| {
            if (i > 0) try w.writeAll(" | ");
            try printOutcome(w, mode, try splitWithoutLog(gpa, n, mode, null), false);
        }
        try w.writeAll("\n");
    }
    try w.writeAll("(before = the 11 old keys, valid tree; after = all 12 keys, valid tree)\n");

    // An operating system may write unsynced pages in any order, so any
    // subset of the five writes can be what a power cut leaves behind.
    try w.writeAll("any subset of the 5 writes may be what reached the disk (digit i = write i; 1 = on disk, 0 = lost):\n");
    const writes = try splitWrites(gpa);
    var counts: [5]u32 = @splat(0);
    for (0..32) |mask| {
        const o = try splitSubset(gpa, &writes, @intCast(mask));
        counts[@intFromEnum(o.state)] += 1;
        var cell_buf: [64]u8 = undefined;
        var cell: Io.Writer = .fixed(&cell_buf);
        for (0..split_write_count) |i| try cell.writeByte(if (mask & (@as(usize, 1) << @intCast(i)) != 0) '1' else '0');
        try cell.writeByte(' ');
        try printState(&cell, o);
        if (mask % 2 == 0) try w.print("  {s:<34}", .{cell.buffered()}) else try w.print("{s}\n", .{cell.buffered()});
    }
    try w.print("of the 32 subsets: {d} before, {d} after, {d} cannot be opened, {d} invalid, {d} valid with wrong contents\n", .{
        counts[@intFromEnum(State.before)],  counts[@intFromEnum(State.after)],          counts[@intFromEnum(State.open_failed)],
        counts[@intFromEnum(State.invalid)], counts[@intFromEnum(State.wrong_contents)],
    });
}

fn part2(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 2: the same split through the write-ahead log ==\n");
    const clean = try splitWithLog(gpa, null, .drop, w);
    try w.writeAll("the power fails after N writes; reopening runs recovery [what it found in the log]:\n");
    var n: u64 = 0;
    while (n <= clean.writes) : (n += 1) {
        try w.print("N = {d}: ", .{n});
        for ([_]CrashMode{ .drop, .keep, .tear }, 0..) |mode, i| {
            if (i > 0) try w.writeAll(" | ");
            try printOutcome(w, mode, try splitWithLog(gpa, n, mode, null), true);
        }
        try w.writeAll("\n");
    }
}

fn printLoop(w: *Io.Writer, loop: crash.Loop) !u32 {
    try w.writeAll("  mode    runs  before  after  open fails  invalid  wrong contents\n");
    var exact: u32 = 0;
    for (crash.modes, loop.tallies) |mode, t| {
        try w.print("  {t:<6} {d:>5} {d:>7} {d:>6} {d:>11} {d:>8} {d:>15}\n", .{ mode, t.runs, t.before, t.after, t.open_failed, t.invalid, t.wrong_contents });
        exact += t.exact();
    }
    return exact;
}

fn part3(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 3: a power cut after every write, four crash modes ==\n");
    const wl = crash.small;
    const options: db_mod.Options = .{ .frames = 3 };
    const clean = try crash.runWithLog(gpa, wl, null, null, .drop, options);
    try w.print("workload: {d} puts (seed {d}), keys of 240 to 256 bytes, values of 700 to 1023 bytes\n", .{ wl.puts, wl.seed });
    try w.print("no crash: splits: {d} leaf, {d} interior, {d} root (the tree grows to 3 levels)\n", .{ clean.stats.leaf_splits, clean.stats.interior_splits, clean.stats.root_splits });

    const with_log = try crash.crashLoop(gpa, wl, true, options);
    try w.print("WITH the log (3-frame pool, checkpoint every 4 commits): {d} page writes, power cut after N = 0..{d}\n", .{ with_log.total_writes, with_log.total_writes });
    const exact_with = try printLoop(w, with_log);
    const without = try crash.crashLoop(gpa, wl, false, options);
    try w.print("WITHOUT the log (chapter 12: put, then flush): {d} page writes, power cut after N = 0..{d}\n", .{ without.total_writes, without.total_writes });
    const exact_without = try printLoop(w, without);
    const runs_with: u64 = (with_log.total_writes + 1) * crash.modes.len;
    const runs_without: u64 = (without.total_writes + 1) * crash.modes.len;
    try w.print("exactly the before or the after state: with the log {d} of {d} runs, without {d} of {d}\n", .{ exact_with, runs_with, exact_without, runs_without });

    // A second power cut, during recovery itself.
    var runs: u32 = 0;
    var exact: u32 = 0;
    var n: u64 = 0;
    while (n <= with_log.total_writes) : (n += 5) {
        for ([_]CrashMode{ .keep, .random }) |mode| {
            var m: u64 = 0;
            while (true) : (m += 1) {
                const r = try crash.runWithLog(gpa, wl, n, m, mode, options);
                if (!r.second_crash_hit) break; // recovery finished before write m
                runs += 1;
                if (r.outcome == .before or r.outcome == .after) exact += 1;
            }
        }
    }
    try w.print("a second power cut during recovery (every 5th N, after each recovery write, keep and random): {d} of {d} runs exact\n", .{ exact, runs });
}

fn part4(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 4: what the log costs (the same 36 puts, no crash) ==\n");
    const wl = crash.small;
    var payload: u64 = 0;
    var key_buf: [btree.max_key_len]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    for (0..wl.puts) |i| {
        const o = wl.op(@intCast(i), &key_buf, &value_buf);
        payload += o.key.len + o.value.len;
    }
    try w.print("the puts carry {d} bytes of keys and values\n", .{payload});
    try w.writeAll("  checkpoint  log bytes  largest  page     log page  main page  syncs\n");
    try w.writeAll("  every       appended   log      records  writes    writes\n");
    for ([_]u32{ 1, 4, 16, 0 }) |every| {
        const r = try crash.runWithLog(gpa, wl, null, null, .drop, .{ .checkpoint_every = every });
        const s = r.wal_stats;
        var label_buf: [8]u8 = undefined;
        const label = if (every == 0) "never" else try std.fmt.bufPrint(&label_buf, "{d}", .{every});
        try w.print("  {s:<10} {d:>10} {d:>8} {d:>8} {d:>9} {d:>10} {d:>6}\n", .{ label, s.log_bytes, s.max_log_bytes, s.page_records, s.log_page_writes, s.main_page_writes, s.log_syncs + s.main_syncs });
        if (every == 4) try w.print("  (largest commit: {d} page images; {d} commits)\n", .{ s.largest_commit, s.commits });
    }
    const plain = try crash.runWithoutLog(gpa, wl, null, .drop);
    try w.print("without the log: {d} page writes in place, no second copy, and Part 3's failures\n", .{plain.writes});
}

pub fn run(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("Chapter 22: write-ahead log and crash recovery\n");
    try part1(w, gpa);
    try part2(w, gpa);
    try part3(w, gpa);
    try part4(w, gpa);
}
