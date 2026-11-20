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
const MemStorage = @import("base_storage.zig").MemStorage;
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
                const state: State = @fromBackingInt(@intCast(i));
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
            reentered[@backingInt(op.state)] += 1;
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

    // The tree in memory is half-split: validate sees it (the leaf chain
    // already contains a page that no parent leads to), and a lookup of a
    // key that moved to that page comes back empty.
    try testing.expectError(error.LeafChainBroken, rig.tree.validate());
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
        try testing.expectError(error.TreePoisoned, rig.tree.flush());
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
        // A failed read or write must have produced both outcomes: an insert
        // that never started changing pages, and one caught half-way. (Out of
        // memory strikes these twelve inserts only before their first page
        // change; the next test goes after the other case.)
        try testing.expect(poisoned_runs < hit);
        if (fault != .memory) try testing.expect(poisoned_runs > 0);
    }
}

test "out of memory or a failed page allocation in the middle of a cascading split: no pin, no leak, and the handle is poisoned" {
    const gpa = testing.allocator;
    const shape: Shape = .{};
    // Pilot run: which put is the first to split an interior page?
    var target: usize = 0;
    {
        var rig: Rig = undefined;
        try rig.create(gpa, 8);
        defer rig.deinit();
        var rng = SplitMix64.init(1);
        var key_buf: [workload.max_key_len]u8 = undefined;
        var value_buf: [workload.max_value_len]u8 = undefined;
        while (rig.tree.stats.interior_splits == 0) : (target += 1) {
            const key, const value = nextPut(&rng, shape, &key_buf, &value_buf);
            try rig.tree.put(key, value);
        }
        target -= 1;
    }

    for ([_]Fault{ .memory, .write }) |fault| {
        var before_change: u32 = 0;
        var after_change: u32 = 0;
        var n: usize = 0;
        while (true) : (n += 1) {
            var rig: Rig = undefined;
            try rig.create(gpa, 8);
            defer rig.deinit();
            var rng = SplitMix64.init(1);
            var key_buf: [workload.max_key_len]u8 = undefined;
            var value_buf: [workload.max_value_len]u8 = undefined;
            for (0..target) |_| {
                const key, const value = nextPut(&rng, shape, &key_buf, &value_buf);
                try rig.tree.put(key, value);
            }
            const key, const value = nextPut(&rng, shape, &key_buf, &value_buf);

            // Fault number `n` of this kind strikes the one insert below.
            var failing: testing.FailingAllocator = .init(gpa, .{ .fail_index = if (fault == .memory) n else std.math.maxInt(usize) });
            var op = InsertOp.init(failing.allocator(), &rig.tree, key, value, .{ .pressure = true }) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                before_change += 1;
                continue;
            };
            defer op.deinit();
            if (fault == .write) rig.mem.writes_before_failure = n;
            const outcome = while (true) {
                const s = op.step() catch |err| break err;
                switch (s) {
                    .done => break {},
                    .io => |id| try rig.supply(id),
                }
            };
            rig.mem.writes_before_failure = null;
            if (outcome) |_| {
                try testing.expect(!failing.has_induced_failure);
                try testing.expectEqual(1, rig.tree.stats.interior_splits);
                try rig.tree.validate();
                break; // the sweep has passed the operation's last allocation / write
            } else |err| {
                try testing.expectEqual(if (fault == .memory) error.OutOfMemory else error.StorageFailure, err);
                try testing.expectEqual(.failed, op.state);
                try testing.expectEqual(0, rig.pool.pinnedFrames());
                try testing.expectEqual(0, op.arena.queryCapacity());
                if (rig.tree.poisoned) {
                    after_change += 1;
                } else {
                    before_change += 1;
                    try rig.tree.validate(); // untouched
                }
            }
        }
        try testing.expect(before_change > 0 and after_change > 0);
    }
}

/// One put that splits, described by the split counters after it and by what
/// the code says it asks its scratch allocator for.
const OomCase = struct {
    leaf_splits: u64,
    interior_splits: u64,
    root_splits: u64,
    /// Scratch requests of that put, in order, [blocking put, resumable insert].
    requests: [2]usize,
    /// The first request that comes after a page change. A failure from
    /// there on leaves a half-split tree; an earlier one leaves it intact.
    first_poisoned: [2]usize,
};

const OomDriver = enum { blocking, resumable };

fn expectValue(tree: *DiskBTree, key: []const u8, expected: ?[]const u8) !void {
    const got = try tree.get(testing.allocator, key);
    defer if (got) |v| testing.allocator.free(v);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualSlices(u8, e, got.?);
    } else try testing.expectEqual(null, got);
}

test "allocation failure at every scratch request of a put that splits a leaf, an interior page and the root, blocking and resumable" {
    // (The blocking half is chapter 12's test.) An arena hides most requests
    // from the allocator behind it: it asks for memory only when its buffer
    // is too small, so a failing allocator behind a warm arena is never
    // asked. Here every request is made visible:
    //
    //   - each run starts with a new arena (a new tree handle for the
    //     blocking put, a new operation for the resumable insert);
    //   - the test fills the arena's buffer to the last byte, so the next
    //     request cannot be served from it;
    //   - the buffer comes from a FixedBufferAllocator, which can grow its
    //     last allocation in place. The arena then grows its buffer by
    //     exactly the bytes of each request: one `resize` call per request.
    //
    // `resize_fail_index` refuses one chosen request, and `fail_index`
    // refuses the new buffer the arena asks for after that.
    const cases = [_]OomCase{
        // The first split: the root leaf moves down, then splits. Requests:
        // the path entry for the root, the page copy, cells, costs. The
        // blocking put appends the path entry after the root has changed;
        // the resumable insert reserves it before (`push_root_leaf`), so only
        // its later requests come after a page change.
        .{ .leaf_splits = 1, .interior_splits = 0, .root_splits = 1, .requests = .{ 4, 4 }, .first_poisoned = .{ 0, 1 } },
        // A leaf that is not the rightmost child splits and its parent has
        // room. Requests: the path, the page copy, cells, costs, and the copy
        // of the parent's key whose pointer changes (`insertSeparator`).
        .{ .leaf_splits = 2, .interior_splits = 0, .root_splits = 1, .requests = .{ 5, 5 }, .first_poisoned = .{ 4, 4 } },
        // The root is a full interior page: the leaf splits, the root's
        // content moves down, that page splits. Requests: the path; page
        // copy, cells, costs (`splitLeaf`); page copy, entries, costs
        // (`splitInterior`).
        .{ .leaf_splits = 16, .interior_splits = 1, .root_splits = 2, .requests = .{ 7, 7 }, .first_poisoned = .{ 4, 4 } },
    };
    const value: [btree.max_value_len]u8 = @splat('v');
    var reached: usize = 0;

    for (cases) |case| {
        // Build the tree up to the put in question. Keys descend, so every
        // put goes to the leftmost leaf; the largest cells allowed make the
        // root fill up after 16 leaf splits. `image` is the flushed file as
        // it was just before the last put.
        var image: std.ArrayList(u8) = .empty;
        defer image.deinit(testing.allocator);
        var key: [btree.max_key_len]u8 = @splat('k');
        var before: DiskBTree.Stats = undefined;
        {
            var rig: Rig = undefined;
            try rig.create(testing.allocator, 4);
            defer rig.deinit();
            var i: usize = 0;
            while (rig.tree.stats.leaf_splits != case.leaf_splits) : (i += 1) {
                try rig.tree.flush();
                image.clearRetainingCapacity();
                try image.appendSlice(testing.allocator, rig.mem.bytes.items);
                before = rig.tree.stats;
                _ = try std.fmt.bufPrint(key[0..4], "{d:0>4}", .{9999 - i});
                try rig.tree.put(&key, &value);
            }
            try testing.expectEqual(case.interior_splits, rig.tree.stats.interior_splits);
            try testing.expectEqual(case.root_splits, rig.tree.stats.root_splits);
            try testing.expectEqual(case.leaf_splits - 1, before.leaf_splits);
        }

        // Run that put again and again on a copy of the image, refusing
        // request 0, 1, 2, ... The last run refuses nothing and counts.
        for ([_]OomDriver{ .blocking, .resumable }) |driver| {
            const requests = case.requests[@backingInt(driver)];
            const first_poisoned = case.first_poisoned[@backingInt(driver)];
            for (0..requests + 1) |fail_at| {
                var mem: MemStorage = .init(testing.allocator);
                defer mem.deinit();
                try mem.bytes.appendSlice(testing.allocator, image.items);
                var pager: Pager = try .init(mem.storage());
                var pool: BufferPool = try .init(testing.allocator, &pager, 4);
                defer pool.deinit(); // asserts that no pin is left

                var scratch_bytes: [64 * 1024]u8 align(16) = undefined;
                var fixed: std.heap.FixedBufferAllocator = .init(&scratch_bytes);
                var failing: testing.FailingAllocator = .init(fixed.allocator(), .{});

                // The blocking put takes its scratch memory from the tree's
                // arena, the resumable insert from the operation's.
                var tree: DiskBTree = try .open(if (driver == .blocking) failing.allocator() else testing.allocator, &pool);
                defer tree.deinit();
                var op: InsertOp = undefined;
                if (driver == .resumable) op = try .init(failing.allocator(), &tree, &key, &value, .{});
                defer if (driver == .resumable) op.deinit();
                const arena = if (driver == .blocking) &tree.arena else &op.arena;

                // Fill the arena's one buffer: single bytes, until the arena
                // has to grow the buffer for one of them. The operation's
                // arena already holds the copies of the key and the value.
                const filled_at = failing.resize_index;
                while (failing.resize_index == filled_at) _ = try arena.allocator().alloc(u8, 1);
                try testing.expectEqual(1, failing.alloc_index); // one buffer, now full
                const base = failing.resize_index;
                failing.fail_index = failing.alloc_index;
                failing.resize_fail_index = base + fail_at;

                const outcome: DiskBTree.Error!void = switch (driver) {
                    .blocking => tree.put(&key, &value),
                    .resumable => while (true) {
                        const s = op.step() catch |err| break err;
                        switch (s) {
                            .done => break {},
                            .io => |id| {
                                _ = try pool.fetchPage(id);
                                pool.unpin(id, false);
                            },
                        }
                    },
                };

                if (fail_at == requests) {
                    // Nothing refused: the put makes exactly the requests
                    // listed above, so the runs before this one reached all
                    // of them.
                    try outcome;
                    try testing.expectEqual(requests, failing.resize_index - base);
                    try testing.expectEqual(1, failing.alloc_index);
                    try testing.expect(!failing.has_induced_failure);
                    try testing.expectEqual(case.leaf_splits - before.leaf_splits, tree.stats.leaf_splits);
                    try testing.expectEqual(case.interior_splits - before.interior_splits, tree.stats.interior_splits);
                    try testing.expectEqual(case.root_splits - before.root_splits, tree.stats.root_splits);
                    try tree.validate();
                    try expectValue(&tree, &key, &value);
                    continue;
                }

                try testing.expectError(error.OutOfMemory, outcome);
                try testing.expect(failing.has_induced_failure);
                try testing.expectEqual(fail_at, failing.resize_index - base); // the requests before it were served
                try testing.expectEqual(0, pool.pinnedFrames());
                try pool.validate();
                if (driver == .resumable) {
                    try testing.expectEqual(.failed, op.state);
                    try testing.expectEqual(0, op.arena.queryCapacity());
                }
                reached += 1;
                failing.fail_index = std.math.maxInt(usize); // memory is back
                failing.resize_fail_index = std.math.maxInt(usize);

                try testing.expectEqual(fail_at >= first_poisoned, tree.poisoned);
                if (tree.poisoned) {
                    try testing.expectError(error.TreePoisoned, tree.put(&key, &value));
                    try testing.expectError(error.TreePoisoned, tree.get(testing.allocator, &key));
                    try testing.expectError(error.TreePoisoned, tree.range("", null));
                    try testing.expectError(error.TreePoisoned, tree.flush());
                    try testing.expectError(error.TreePoisoned, InsertOp.init(testing.allocator, &tree, &key, &value, .{}));
                    try testing.expectError(error.TreePoisoned, GetOp.init(testing.allocator, &tree, &key));
                } else {
                    // The put did not happen at all, and it works when repeated.
                    try tree.validate();
                    try expectValue(&tree, &key, null);
                    try tree.put(&key, &value);
                    try tree.validate();
                    try expectValue(&tree, &key, &value);
                }
                try testing.expectEqual(0, pool.pinnedFrames());
            }
        }
    }
    try testing.expectEqual(2 * (4 + 5 + 7), reached);
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
