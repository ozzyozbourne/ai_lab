//! tests.zig: what a resumable operation has to prove.
//!
//!   1. It computes the same thing as the blocking code: byte-identical files.
//!   2. Every place where it can stop has been made to stop there.
//!   3. Calling it again before its page arrived changes nothing at all.
//!   4. It never reads, and it holds no pin while it waits.
//!   5. When it dies in the middle (read error, write error, out of memory)
//!      it leaves no pin and no memory behind.
//!   6. Its memory has the right lifetime: the arena outlives every yield,
//!      and a buffer that does not is shown to break the tree.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const btree = @import("disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const PageId = btree.PageId;
const BufferPool = @import("base_buffer_pool.zig").BufferPool;
const Pager = @import("base_pager.zig").Pager;
const SplitMix64 = @import("prng.zig").SplitMix64;
const workload = @import("workload.zig");
const resumable = @import("resumable.zig");
const InsertOp = resumable.InsertOp;
const GetOp = resumable.GetOp;
const State = resumable.State;
const Scheduler = @import("scheduler.zig").Scheduler;
const demo = @import("demo.zig");
const Rig = demo.Rig;

/// A workload whose keys are long enough that 700 puts build three levels,
/// so that every state of the insert is reached.
const Shape = struct { key_space: u64 = 2000, max_key: usize = 200, max_value: usize = 500, puts: usize = 700 };

fn nextPut(rng: *SplitMix64, shape: Shape, key_buf: *[workload.max_key_len]u8, value_buf: *[workload.max_value_len]u8) struct { []const u8, []const u8 } {
    const key = workload.keyFor(rng.below(shape.key_space), shape.max_key, key_buf);
    return .{ key, workload.randomValue(rng, shape.max_value, value_buf) };
}

/// The reference: the same puts through chapter 12's blocking `put`.
fn blockingFile(gpa: Allocator, shape: Shape, seed: u64, out: *std.ArrayList(u8)) !void {
    var rig: Rig = undefined;
    try rig.create(gpa, 8);
    defer rig.deinit();
    var rng = SplitMix64.init(seed);
    var key_buf: [workload.max_key_len]u8 = undefined;
    var value_buf: [workload.max_value_len]u8 = undefined;
    for (0..shape.puts) |_| {
        const key, const value = nextPut(&rng, shape, &key_buf, &value_buf);
        try rig.tree.put(key, value);
    }
    // The shape must really exercise interior and root splits.
    try testing.expect(rig.tree.stats.interior_splits >= 1 and rig.tree.stats.root_splits >= 2);
    try rig.tree.flush();
    try out.appendSlice(gpa, rig.mem.bytes.items);
}

test "the resumable insert writes the same file, byte for byte, as the blocking put" {
    const gpa = testing.allocator;
    const shape: Shape = .{};
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    try blockingFile(gpa, shape, 1, &expected);

    const Case = struct { frames: u32, disk_seed: u64, batch: usize, pressure: bool };
    for ([_]Case{
        .{ .frames = 2, .disk_seed = 1, .batch = 1, .pressure = false },
        .{ .frames = 3, .disk_seed = 2, .batch = 5, .pressure = false },
        .{ .frames = 16, .disk_seed = 3, .batch = 40, .pressure = false },
        .{ .frames = 2, .disk_seed = 4, .batch = 7, .pressure = true },
        .{ .frames = 5, .disk_seed = 5, .batch = 3, .pressure = true },
    }) |case| {
        var rig: Rig = undefined;
        try rig.create(gpa, case.frames);
        defer rig.deinit();
        var model: workload.Model = .init(gpa);
        defer model.deinit();
        var rng = SplitMix64.init(1);
        var probe = SplitMix64.init(case.disk_seed);
        var key_buf: [workload.max_key_len]u8 = undefined;
        var value_buf: [workload.max_value_len]u8 = undefined;

        var done: usize = 0;
        while (done < shape.puts) {
            // One batch: puts interleaved with gets, all submitted before any
            // of them runs. `expect[i]` is what a blocking program running
            // them one by one would have answered.
            var s: Scheduler = .init(gpa, &rig.tree, case.disk_seed +% done);
            defer s.deinit();
            s.insert_options.pressure = case.pressure;
            var tickets: std.ArrayList(struct { ticket: u32, expect: ?[]const u8 }) = .empty;
            defer tickets.deinit(gpa);
            const n = @min(case.batch, shape.puts - done);
            for (0..n) |_| {
                const key, const value = nextPut(&rng, shape, &key_buf, &value_buf);
                _ = try s.submitInsert(gpa, key, value);
                try model.put(key, value);
                for (0..2) |_| {
                    var probe_buf: [workload.max_key_len]u8 = undefined;
                    const wanted = workload.keyFor(probe.below(shape.key_space), shape.max_key, &probe_buf);
                    try tickets.append(gpa, .{ .ticket = try s.submitGet(gpa, wanted), .expect = model.get(wanted) });
                }
            }
            try s.run();
            for (s.slots.items) |slot| try testing.expectEqual(.done, slot.status);
            for (tickets.items) |t| {
                const got = s.result(t.ticket);
                if (t.expect) |e| try testing.expectEqualSlices(u8, e, got.?) else try testing.expectEqual(null, got);
            }
            done += n;
        }
        try rig.tree.validate();
        try testing.expectEqual(model.len(), rig.tree.key_count);
        try rig.tree.flush();
        try testing.expect(std.mem.eql(u8, expected.items, rig.mem.bytes.items));
    }
}

test "every suspension point is exercised" {
    const gpa = testing.allocator;
    const shape: Shape = .{};
    for ([_]bool{ false, true }) |pressure| {
        var rig: Rig = undefined;
        try rig.create(gpa, 4);
        defer rig.deinit();
        var s: Scheduler = .init(gpa, &rig.tree, 9);
        defer s.deinit();
        s.insert_options.pressure = pressure;
        var rng = SplitMix64.init(1);
        var key_buf: [workload.max_key_len]u8 = undefined;
        var value_buf: [workload.max_value_len]u8 = undefined;
        for (0..shape.puts) |_| {
            const key, const value = nextPut(&rng, shape, &key_buf, &value_buf);
            _ = try s.submitInsert(gpa, key, value);
        }
        try s.run();
        try rig.tree.validate();
        if (pressure) {
            // With the pool emptied between transitions, every state had to
            // wait for its page at least once.
            for (s.suspended) |n| try testing.expect(n > 0);
        } else {
            // Left alone, a single writer only ever waits in two states: on
            // the way down, and when it comes back to a parent that the split
            // pushed out of the pool. The other five find the page that the
            // state before them just used. They are still suspension points
            // (another operation, or a smaller pool, can take the page away),
            // which is why the run above forces them.
            for (s.suspended, 0..) |n, i| {
                const state: State = @enumFromInt(i);
                const expected_to_wait = state == .descend or state == .insert_separator;
                try testing.expectEqual(expected_to_wait, n > 0);
            }
        }
    }
}

/// Everything that a call of `step` could possibly change.
const Snapshot = struct {
    state: State,
    cur: PageId,
    path_len: usize,
    changed: bool,
    suspended: [resumable.suspend_points]u32,
    key_count: u64,
    tree_stats: DiskBTree.Stats,
    pool_stats: BufferPool.Stats,
    pager_stats: Pager.Stats,
    hand: u32,
    pinned: u32,
    file_hash: u64,
    frames_hash: u64,

    fn take(rig: *Rig, op: *const InsertOp) Snapshot {
        return .{
            .state = op.state,
            .cur = op.cur,
            .path_len = op.path.items.len,
            .changed = op.changed,
            .suspended = op.suspended,
            .key_count = rig.tree.key_count,
            .tree_stats = rig.tree.stats,
            .pool_stats = rig.pool.stats,
            .pager_stats = rig.pager.stats,
            .hand = rig.pool.hand,
            .pinned = rig.pool.pinnedFrames(),
            .file_hash = std.hash.Wyhash.hash(0, rig.mem.bytes.items),
            .frames_hash = std.hash.Wyhash.hash(0, rig.pool.slab) ^ std.hash.Wyhash.hash(1, std.mem.sliceAsBytes(rig.pool.frames)),
        };
    }
};

test "an operation re-entered before its page arrived makes no progress and changes nothing" {
    const gpa = testing.allocator;
    const shape: Shape = .{};
    var rig: Rig = undefined;
    try rig.create(gpa, 3);
    defer rig.deinit();
    var rng = SplitMix64.init(1);
    var key_buf: [workload.max_key_len]u8 = undefined;
    var value_buf: [workload.max_value_len]u8 = undefined;
    var reentered: [resumable.suspend_points]u32 = @splat(0);

    for (0..shape.puts) |_| {
        const key, const value = nextPut(&rng, shape, &key_buf, &value_buf);
        var op: InsertOp = try .init(gpa, &rig.tree, key, value, .{ .pressure = true });
        defer op.deinit();
        while (true) {
            const first = try op.step();
            if (first == .done) break;
            const before = Snapshot.take(&rig, &op);
            // The caller is impatient: it calls again, and again, although
            // the disk has delivered nothing.
            for (0..3) |_| {
                const again = try op.step();
                try testing.expectEqual(first.io, again.io);
                try testing.expectEqualDeep(before, Snapshot.take(&rig, &op));
            }
            reentered[@intFromEnum(op.state)] += 1;
            try rig.supply(first.io);
        }
    }
    for (reentered) |n| try testing.expect(n > 0); // in every one of the seven states
    try rig.tree.validate();
}

test "step reads nothing and keeps no pin; all reading is done by the disk" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.create(gpa, 2);
    defer rig.deinit();
    for (demo.scenario_keys) |n| try rig.putScenario(n);
    _ = try rig.pool.evictUnpinned();

    const value: [900]u8 = @splat('x');
    var op: InsertOp = try .init(gpa, &rig.tree, "16", &value, .{});
    defer op.deinit();
    var in_step: u64 = 0;
    var by_disk: u64 = 0;
    var yields: u32 = 0;
    while (true) {
        const before = rig.pager.stats.reads;
        const s = try op.step();
        in_step += rig.pager.stats.reads - before;
        try testing.expectEqual(0, rig.pool.pinnedFrames());
        if (s == .done) break;
        yields += 1;
        const mid = rig.pager.stats.reads;
        try rig.supply(s.io);
        by_disk += rig.pager.stats.reads - mid;
    }
    try testing.expectEqual(0, in_step);
    try testing.expectEqual(3, yields); // root, leaf, and the root again after the split
    try testing.expectEqual(3, by_disk);
    try rig.tree.validate();
}

test "a reader let in while a split is half done misses a key: why the writer runs alone" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.create(gpa, 2);
    defer rig.deinit();
    for (demo.scenario_keys) |n| try rig.putScenario(n);

    const value: [1000]u8 = @splat('q');
    var op: InsertOp = try .init(gpa, &rig.tree, "16", &value, .{});
    defer op.deinit();
    var last = try op.step();
    while (op.state != .insert_separator) : (last = try op.step()) try rig.supply(last.io);
    try testing.expect(last == .io and op.changed);

    // The tree in memory is half-split: validate sees it, and a lookup of a
    // key that moved to the new right page comes back empty.
    try testing.expectError(error.UnreachablePage, rig.tree.validate());
    try testing.expectEqual(null, try rig.tree.get(gpa, "18"));

    while (last == .io) : (last = try op.step()) try rig.supply(last.io);
    try rig.tree.validate();
    const found = (try rig.tree.get(gpa, "18")).?;
    defer gpa.free(found);
    try testing.expectEqual(732, found.len);
}

test "the scheduler runs operations in submission order: a get sees exactly the puts before it" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.create(gpa, 3);
    defer rig.deinit();
    var s: Scheduler = .init(gpa, &rig.tree, 77);
    defer s.deinit();
    const before = try s.submitGet(gpa, "k");
    _ = try s.submitInsert(gpa, "k", "one");
    const between = try s.submitGet(gpa, "k");
    _ = try s.submitInsert(gpa, "k", "two");
    const after = try s.submitGet(gpa, "k");
    try s.run();
    try testing.expectEqual(null, s.result(before));
    try testing.expectEqualStrings("one", s.result(between).?);
    try testing.expectEqualStrings("two", s.result(after).?);
    try testing.expectEqual(1, rig.tree.key_count);
}

// ---- failures in the middle of an operation ------------------------------------

const Fault = enum { read, write, memory };

/// Build the 24-key scenario tree, then run twelve inserts that split leaves
/// while fault number `n` of the given kind strikes. Returns whether a fault
/// was actually hit.
fn runWithFault(gpa: Allocator, fault: Fault, n: u64, poisoned_runs: *u32) !bool {
    var rig: Rig = undefined;
    try rig.create(gpa, 2);
    defer rig.deinit();
    for (demo.scenario_keys) |k| try rig.putScenario(k);
    try rig.tree.flush();

    var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = if (fault == .memory) n else std.math.maxInt(usize) });
    const op_gpa = failing.allocator();
    switch (fault) {
        .read => rig.mem.reads_before_failure = n,
        .write => rig.mem.writes_before_failure = n,
        .memory => {},
    }

    var s: Scheduler = .init(gpa, &rig.tree, n);
    defer s.deinit();
    const value: [700]u8 = @splat('v');
    const new_keys = [_][]const u8{ "13", "16", "19", "21", "24", "26", "0a", "0b", "1a", "1b", "2a", "2b" };
    var submitted: [new_keys.len]?u32 = @splat(null);
    for (new_keys, &submitted) |key, *ticket| {
        ticket.* = s.submitInsert(op_gpa, key, &value) catch |err| switch (err) {
            error.OutOfMemory => null, // the operation never existed
            else => return err,
        };
    }
    try s.run();

    // The fault is over; look at what it left behind.
    rig.mem.reads_before_failure = null;
    rig.mem.writes_before_failure = null;
    try testing.expectEqual(0, rig.pool.pinnedFrames());
    try rig.pool.validate();

    var failures: u32 = 0;
    for (submitted) |ticket| {
        if (ticket == null or s.slots.items[ticket.?].status == .failed) failures += 1;
    }
    if (rig.tree.poisoned) {
        // The failed insert had already changed a page: the handle refuses
        // further work, exactly like chapter 12's blocking put.
        poisoned_runs.* += 1;
        try testing.expectError(error.TreePoisoned, rig.tree.validate() catch |e| e);
        return true;
    }
    try rig.tree.validate();
    for (new_keys, submitted) |key, ticket| {
        const applied = ticket != null and s.slots.items[ticket.?].status == .done;
        const found = try rig.tree.get(gpa, key);
        defer if (found) |v| gpa.free(v);
        try testing.expectEqual(applied, found != null); // all of it, or none of it
    }
    return failures > 0;
}

test "a read failure, a write failure or an allocation failure mid-operation leaves no pinned page" {
    // std.testing.allocator fails the test if any operation leaks its arena.
    const gpa = testing.allocator;
    for ([_]Fault{ .read, .write, .memory }) |fault| {
        var hit: u32 = 0;
        var poisoned_runs: u32 = 0;
        var n: u64 = 0;
        while (try runWithFault(gpa, fault, n, &poisoned_runs)) : (n += 1) hit += 1;
        try testing.expect(hit >= 10); // the sweep really went through the operations
        // Reads cannot fail mid-split here without the split having changed a
        // page first, so every kind of fault must have produced both outcomes.
        try testing.expect(poisoned_runs > 0 and poisoned_runs < hit);
    }
}

test "cancelling a waiting insert: nothing pinned, nothing changed, memory returned" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.create(gpa, 2);
    defer rig.deinit();
    for (demo.scenario_keys) |n| try rig.putScenario(n);
    try rig.tree.flush();
    _ = try rig.pool.evictUnpinned();
    const file_before = try gpa.dupe(u8, rig.mem.bytes.items);
    defer gpa.free(file_before);

    var op: InsertOp = try .init(gpa, &rig.tree, "16", "abandoned", .{});
    defer op.deinit();
    try testing.expectEqual(resumable.Step{ .io = 1 }, try op.step());
    try testing.expect(op.arena.queryCapacity() > 0);
    op.cancel();
    try testing.expectEqual(.failed, op.state);
    try testing.expectEqual(0, op.arena.queryCapacity());
    try testing.expectEqual(0, rig.pool.pinnedFrames());
    try testing.expect(!rig.tree.poisoned);
    try rig.tree.flush();
    try testing.expectEqualSlices(u8, file_before, rig.mem.bytes.items);
}

// ---- the lifetime of the operation's memory -------------------------------------

test "the arena survives every resumption and is emptied when the operation completes" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.create(gpa, 2);
    defer rig.deinit();
    for (demo.scenario_keys) |n| try rig.putScenario(n);
    _ = try rig.pool.evictUnpinned();

    // The caller's buffers die right after `init`: the operation has copies.
    var op: InsertOp = undefined;
    {
        var key_buf: [2]u8 = "16".*;
        var value_buf: [1000]u8 = @splat('q');
        op = try .init(gpa, &rig.tree, &key_buf, &value_buf, .{});
        @memset(&key_buf, 0);
        @memset(&value_buf, 0);
    }
    defer op.deinit();
    const key_address = op.key.ptr;

    var yields: u32 = 0;
    var s = try op.step();
    while (s == .io) : (s = try op.step()) {
        yields += 1;
        // Across the suspension: same memory, same content.
        try testing.expectEqual(key_address, op.key.ptr);
        try testing.expectEqualStrings("16", op.key);
        try testing.expect(op.arena.queryCapacity() >= 1000);
        if (op.state == .insert_separator) {
            // The separator computed by the split, two calls ago in program
            // terms, is still readable: it points into the arena.
            try testing.expectEqualStrings("17", op.carry.sep);
        }
        try rig.supply(s.io);
    }
    try testing.expectEqual(3, yields);
    try testing.expectEqual(0, op.arena.queryCapacity()); // one free for everything
    try rig.tree.validate();
}

test "scratch memory that is reused at every yield breaks the tree, but only when the insert yields" {
    const gpa = testing.allocator;
    var violation: []const u8 = "";
    // The right lifetime: fine however often the operation yields.
    try testing.expectEqual(null, try demo.ascendingUntilBroken(gpa, 2, .op_arena, 30, &violation));
    // The wrong lifetime with a pool so large that no split ever waits: the
    // bug is there and does nothing. This is what makes it dangerous.
    try testing.expectEqual(null, try demo.ascendingUntilBroken(gpa, 64, .step_buffer, 30, &violation));
    // The wrong lifetime and a yield between the split and the parent: the
    // separator has been overwritten, the parent gets garbage for a key.
    try testing.expectEqual(10, try demo.ascendingUntilBroken(gpa, 2, .step_buffer, 30, &violation));
    try testing.expectEqualStrings("KeyOutOfBounds", violation);
}

test "init rejects what put rejects" {
    const gpa = testing.allocator;
    var rig: Rig = undefined;
    try rig.create(gpa, 2);
    defer rig.deinit();
    const long_key: [btree.max_key_len + 1]u8 = @splat('k');
    const long_value: [btree.max_value_len + 1]u8 = @splat('v');
    try testing.expectError(error.KeyTooLarge, InsertOp.init(gpa, &rig.tree, &long_key, "", .{}));
    try testing.expectError(error.ValueTooLarge, InsertOp.init(gpa, &rig.tree, "k", &long_value, .{}));
    rig.tree.poisoned = true;
    try testing.expectError(error.TreePoisoned, InsertOp.init(gpa, &rig.tree, "k", "v", .{}));
    try testing.expectError(error.TreePoisoned, GetOp.init(gpa, &rig.tree, "k"));
    rig.tree.poisoned = false;
}
