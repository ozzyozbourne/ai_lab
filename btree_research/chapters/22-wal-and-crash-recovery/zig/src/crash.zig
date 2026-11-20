//! crash.zig: the crash loop. "Stop the machine after write number N, for
//! every N", in the style of a deterministic simulation: one seed fixes the
//! workload and every fault, so a failing (N, mode) pair is a reproducible
//! test case, not a lucky find.
//!
//! One run:
//!   1. a fresh `Machine` (seeded); power fails after N page writes
//!   2. open the database, apply the workload's puts until one fails;
//!      `acked` = puts that returned success
//!   3. crash(mode): each unsynced write is dropped, kept or torn
//!   4. reopen (with the log: recovery runs here), validate, and compare the
//!      contents with the oracle
//!
//! The oracle allows exactly two states: the workload's first `acked` puts
//! ("before"), or those plus the one put that was in flight ("after"). The
//! in-flight put may count either way because its commit record can become
//! durable just before the power fails, when nobody is left to hear the
//! answer. Anything else (a tree that does not validate, a missing
//! acknowledged key, half an operation) is a failure.
//!
//! The same loop runs twice: with the log (`Db`), and without it (chapter
//! 12's tree directly on the disk through `PageFile`, flushed after every
//! put). The second one is the control experiment.
const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitMix64 = @import("prng.zig").SplitMix64;
const machine_mod = @import("machine.zig");
const Machine = machine_mod.Machine;
pub const CrashMode = machine_mod.CrashMode;
const PageFile = @import("adapter.zig").PageFile;
const Pager = @import("base_pager.zig").Pager;
const BufferPool = @import("base_buffer_pool.zig").BufferPool;
const btree = @import("base_disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const Model = @import("base_workload.zig").Model;
const db_mod = @import("db.zig");
const Db = db_mod.Db;
const Recovery = @import("wal.zig").Recovery;

pub const modes = [_]CrashMode{ .drop, .keep, .tear, .random };

/// A fixed, seeded list of puts. Long keys and large values, so that a few
/// dozen puts already split leaves, split an interior page and grow the tree
/// to three levels (a leaf holds about 3 cells, an interior page about 15).
pub const Workload = struct {
    seed: u64,
    puts: u32,
    /// Keys are drawn from this many distinct keys; repeats overwrite.
    key_space: u32,

    pub const Op = struct { key: []const u8, value: []const u8 };

    /// Put number `i` (0-based). A function of (seed, i) alone.
    pub fn op(self: Workload, i: u32, key_buf: *[btree.max_key_len]u8, value_buf: *[btree.max_value_len]u8) Op {
        var rng = SplitMix64.init(self.seed *% 0x9E3779B97F4A7C15 +% i);
        const n: usize = @intCast(rng.below(self.key_space));
        // "k" + three digits, padded with one letter to 240..256 bytes.
        const key_len = 240 + (n * 7) % 17;
        @memset(key_buf[0..key_len], 'a' + @as(u8, @intCast(n % 26)));
        key_buf[0..4].* = .{ 'k', '0' + @as(u8, @intCast(n / 100 % 10)), '0' + @as(u8, @intCast(n / 10 % 10)), '0' + @as(u8, @intCast(n % 10)) };
        const value_len: usize = @intCast(700 + rng.below(324));
        @memset(value_buf[0..value_len], 'A' + @as(u8, @intCast(i % 26)));
        return .{ .key = key_buf[0..key_len], .value = value_buf[0..value_len] };
    }
};

/// The default workload of the tests and of the demo.
pub const small: Workload = .{ .seed = 22, .puts = 40, .key_space = 36 };
/// A longer one, used when the build flag `-Dlong=true` is given.
pub const long: Workload = .{ .seed = 2222, .puts = 120, .key_space = 100 };

pub const Outcome = enum { before, after, open_failed, invalid, wrong_contents };

pub const Result = struct {
    outcome: Outcome,
    /// Puts that returned success before the power failed.
    acked: u32,
    /// Page writes the machine accepted before the (first) crash.
    writes: u64,
    /// With the log: what the final recovery found.
    recovery: Recovery = .{},
    /// Tree statistics at the end of the run phase (meaningful if no crash).
    stats: DiskBTree.Stats = .{},
    /// With a second crash: did the power fail during the first recovery?
    second_crash_hit: bool = false,
};

pub const Tally = struct {
    runs: u32 = 0,
    before: u32 = 0,
    after: u32 = 0,
    open_failed: u32 = 0,
    invalid: u32 = 0,
    wrong_contents: u32 = 0,

    pub fn add(self: *Tally, outcome: Outcome) void {
        self.runs += 1;
        switch (outcome) {
            .before => self.before += 1,
            .after => self.after += 1,
            .open_failed => self.open_failed += 1,
            .invalid => self.invalid += 1,
            .wrong_contents => self.wrong_contents += 1,
        }
    }

    /// Runs that ended in exactly the before or the after state.
    pub fn exact(self: Tally) u32 {
        return self.before + self.after;
    }
};

pub const Error = Db.Error || DiskBTree.ValidateError || error{
    /// A put failed although the power was still on: a bug, not a crash.
    UnexpectedFailure,
    /// The recovered database could not take another put.
    RecoveredDbUnusable,
};

fn applyOps(model: *Model, w: Workload, from: u32, to: u32) Allocator.Error!void {
    var key_buf: [btree.max_key_len]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    for (from..to) |i| {
        const o = w.op(@intCast(i), &key_buf, &value_buf);
        try model.put(o.key, o.value);
    }
}

/// One full scan of the tree against the oracle. A read error counts as a
/// difference.
fn sameContents(tree: *DiskBTree, model: *const Model) bool {
    var it = tree.range("", null) catch return false;
    var count: usize = 0;
    while (it.next() catch return false) |item| : (count += 1) {
        if (count >= model.len()) return false;
        const expected = model.entries.items[count];
        if (!std.mem.eql(u8, item.key, expected.key) or !std.mem.eql(u8, item.value, expected.value)) return false;
    }
    return count == model.len();
}

/// Step 4 of a run: validate, then decide which oracle state the tree is in.
fn classify(gpa: Allocator, tree: *DiskBTree, w: Workload, acked: u32) Allocator.Error!Outcome {
    tree.validate() catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else .invalid;
    var model: Model = .init(gpa);
    defer model.deinit();
    try applyOps(&model, w, 0, acked);
    if (sameContents(tree, &model)) return .before;
    if (acked < w.puts) {
        try applyOps(&model, w, acked, acked + 1);
        if (sameContents(tree, &model)) return .after;
    }
    return .wrong_contents;
}

/// One run WITH the log. `n` = page writes before the power fails (null =
/// never: the whole workload runs). `second` = if set, the power fails again
/// after that many writes of the recovery, and recovery runs a second time.
pub fn runWithLog(gpa: Allocator, w: Workload, n: ?u64, second: ?u64, mode: CrashMode, options: db_mod.Options) Error!Result {
    var machine: Machine = .init(gpa, w.seed);
    defer machine.deinit();
    if (n) |limit| machine.powerOffAfterWrites(limit);

    var result: Result = .{ .outcome = .open_failed, .acked = 0, .writes = 0 };
    var key_buf: [btree.max_key_len]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    run: {
        const db = Db.open(gpa, machine.mainStorage(), machine.logStorage(), options) catch |err| {
            if (!machine.isPoweredOff()) return err;
            break :run;
        };
        defer db.close();
        while (result.acked < w.puts) : (result.acked += 1) {
            const o = w.op(result.acked, &key_buf, &value_buf);
            db.put(o.key, o.value) catch |err| {
                if (!machine.isPoweredOff()) return err;
                break :run;
            };
        }
        result.stats = db.tree.stats;
    }
    result.writes = machine.writes;
    machine.crash(mode);

    if (second) |limit| {
        // Crash during recovery: recovery must be restartable.
        machine.powerOffAfterWrites(limit);
        if (Db.open(gpa, machine.mainStorage(), machine.logStorage(), options)) |db| {
            db.close();
        } else |err| {
            if (!machine.isPoweredOff()) return err;
        }
        result.second_crash_hit = machine.isPoweredOff();
        machine.crash(mode);
    }

    const db = Db.open(gpa, machine.mainStorage(), machine.logStorage(), options) catch |err| {
        if (err == error.OutOfMemory) return err;
        return result; // open_failed
    };
    defer db.close();
    result.recovery = db.recovery;
    result.outcome = try classify(gpa, &db.tree, w, result.acked);
    if (result.outcome == .before or result.outcome == .after) {
        // The recovered database must be a working database.
        db.put("zz after recovery", "still alive") catch return error.RecoveredDbUnusable;
        db.validate() catch return error.RecoveredDbUnusable;
        const got = db.get(gpa, "zz after recovery") catch return error.RecoveredDbUnusable;
        defer if (got) |v| gpa.free(v);
        if (got == null or !std.mem.eql(u8, got.?, "still alive")) return error.RecoveredDbUnusable;
    }
    return result;
}

/// A chapter 12 tree directly on a page storage: no log, no checksums.
const Plain = struct {
    file: PageFile,
    pager: Pager,
    pool: BufferPool,
    tree: DiskBTree,

    /// Initialise in place: the parts point at each other.
    fn open(self: *Plain, gpa: Allocator, machine: *Machine) DiskBTree.Error!void {
        self.file = .{ .inner = machine.mainStorage() };
        self.pager = try .init(self.file.storage());
        self.pool = try .init(gpa, &self.pager, 8);
        errdefer self.pool.deinit();
        self.tree = if (self.pager.pageCount() == 0) try .create(gpa, &self.pool) else try .open(gpa, &self.pool);
    }

    fn close(self: *Plain) void {
        self.tree.deinit();
        self.pool.deinit();
    }
};

/// The same run WITHOUT the log: put, then flush (write the dirty pages in
/// place, sync). This is all chapter 12 can do for durability.
pub fn runWithoutLog(gpa: Allocator, w: Workload, n: ?u64, mode: CrashMode) Error!Result {
    var machine: Machine = .init(gpa, w.seed);
    defer machine.deinit();
    if (n) |limit| machine.powerOffAfterWrites(limit);

    var result: Result = .{ .outcome = .open_failed, .acked = 0, .writes = 0 };
    var key_buf: [btree.max_key_len]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    run: {
        var plain: Plain = undefined;
        plain.open(gpa, &machine) catch |err| {
            if (!machine.isPoweredOff()) return err;
            break :run;
        };
        defer plain.close();
        while (result.acked < w.puts) : (result.acked += 1) {
            const o = w.op(result.acked, &key_buf, &value_buf);
            const done = if (plain.tree.put(o.key, o.value)) |_| plain.tree.flush() else |err| err;
            done catch |err| {
                if (!machine.isPoweredOff()) return err;
                break :run;
            };
        }
        result.stats = plain.tree.stats;
    }
    result.writes = machine.writes;
    machine.crash(mode);

    var plain: Plain = undefined;
    plain.open(gpa, &machine) catch |err| {
        if (err == error.OutOfMemory) return err;
        return result; // open_failed
    };
    defer plain.close();
    result.outcome = try classify(gpa, &plain.tree, w, result.acked);
    return result;
}

pub const Loop = struct {
    /// Page writes of the whole workload when nothing goes wrong.
    total_writes: u64,
    /// One tally per crash mode, in the order of `modes`.
    tallies: [modes.len]Tally,
};

/// THE loop: for every N from 0 to the total number of writes, and for every
/// crash mode, one run. With `with_log` false it is the control experiment.
pub fn crashLoop(gpa: Allocator, w: Workload, with_log: bool, options: db_mod.Options) Error!Loop {
    const clean = if (with_log) try runWithLog(gpa, w, null, null, .drop, options) else try runWithoutLog(gpa, w, null, .drop);
    std.debug.assert(clean.acked == w.puts and clean.outcome == .before);
    var loop: Loop = .{ .total_writes = clean.writes, .tallies = @splat(.{}) };
    var n: u64 = 0;
    while (n <= clean.writes) : (n += 1) {
        for (modes, &loop.tallies) |mode, *tally| {
            const r = if (with_log) try runWithLog(gpa, w, n, null, mode, options) else try runWithoutLog(gpa, w, n, mode);
            tally.add(r.outcome);
        }
    }
    return loop;
}
