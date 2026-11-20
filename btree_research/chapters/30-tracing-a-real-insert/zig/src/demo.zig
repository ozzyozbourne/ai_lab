//! demo.zig: the fixed scenario printed by `zig build run`.
//!
//! Every number below is a count made by this program. Part 1 and Part 3 use
//! the small scenario of chapter 12 (two-digit keys with large values, so
//! that a handful of keys fills a page); Part 2 uses its seeded workload.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const btree = @import("disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const PageId = btree.PageId;
const Pager = @import("base_pager.zig").Pager;
const BufferPool = @import("base_buffer_pool.zig").BufferPool;
const MemStorage = @import("base_storage.zig").MemStorage;
const SplitMix64 = @import("prng.zig").SplitMix64;
const workload = @import("workload.zig");
const resumable = @import("resumable.zig");
const InsertOp = resumable.InsertOp;
const State = resumable.State;
const sched = @import("scheduler.zig");
const Scheduler = sched.Scheduler;

/// Chapter 12's scenario keys, in insertion order.
pub const scenario_keys = [_]u8{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15, 8, 22, 28, 14, 2, 27, 18, 9, 23, 11, 29, 4 };

/// Key `n` as two decimal digits, so that byte order is numeric order.
pub fn scenarioKey(n: u8, buf: *[2]u8) []const u8 {
    buf.* = .{ '0' + n / 10, '0' + n % 10 };
    return buf;
}

/// The value of key `n`: 300 + 24 * n copies of one letter.
pub fn scenarioValue(n: u8, buf: *[btree.max_value_len]u8) []const u8 {
    const len = 300 + 24 * @as(usize, n);
    @memset(buf[0..len], 'a' + n % 26);
    return buf[0..len];
}

/// A tree on a memory "disk" with everything under it. Initialised in place
/// because the pool points at the pager and the tree at the pool.
pub const Rig = struct {
    mem: MemStorage,
    pager: Pager,
    pool: BufferPool,
    tree: DiskBTree,

    pub fn create(self: *Rig, gpa: Allocator, frames: u32) !void {
        self.mem = .init(gpa);
        errdefer self.mem.deinit();
        self.pager = try .init(self.mem.storage());
        self.pool = try .init(gpa, &self.pager, frames);
        errdefer self.pool.deinit();
        self.tree = try .create(gpa, &self.pool);
    }

    pub fn deinit(self: *Rig) void {
        self.tree.deinit();
        self.pool.deinit();
        self.mem.deinit();
    }

    pub fn putScenario(self: *Rig, n: u8) !void {
        var key_buf: [2]u8 = undefined;
        var value_buf: [btree.max_value_len]u8 = undefined;
        try self.tree.put(scenarioKey(n, &key_buf), scenarioValue(n, &value_buf));
    }

    /// Complete a read the way the simulated disk does.
    pub fn supply(self: *Rig, id: PageId) !void {
        _ = try self.pool.fetchPage(id);
        self.pool.unpin(id, false);
    }
};

pub fn run(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("Chapter 30: tracing a real insert\n");
    try part1(w, gpa);
    try part2(w, gpa);
    try part3(w, gpa);
    try part4(w, gpa);
    try part5(w, gpa);
}

// ---- Part 1 -------------------------------------------------------------------

/// Run one resumable insert by hand and print every call: the states it
/// passed through and how the call ended.
fn traceInsert(w: *Io.Writer, gpa: Allocator, rig: *Rig, n: u8) !void {
    var key_buf: [2]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    const key = scenarioKey(n, &key_buf);
    const value = scenarioValue(n, &value_buf);
    _ = try rig.pool.evictUnpinned(); // start cold: nothing is in memory
    var op: InsertOp = try .init(gpa, &rig.tree, key, value, .{});
    defer op.deinit();
    try w.print("insert {s} ({d}-byte value), nothing cached:\n", .{ key, value.len });

    const reads_before = rig.pager.stats.reads;
    var disk_reads: u64 = 0;
    var call: u32 = 1;
    while (true) : (call += 1) {
        try w.print("  call {d}: ", .{call});
        var first = true;
        // One `step` call, spelled out so that the states can be printed.
        const end: resumable.Step = while (true) {
            try w.print("{s}{t}", .{ if (first) "" else ", ", op.state });
            first = false;
            switch (try op.advance()) {
                .again => {},
                .done => break .done,
                .io => |id| break .{ .io = id },
            }
        };
        switch (end) {
            .done => {
                try w.writeAll(" -> Done\n");
                break;
            },
            .io => |id| {
                try w.print(" -> Io(page {d})\n", .{id});
                const in_step = rig.pager.stats.reads;
                try rig.supply(id);
                disk_reads += rig.pager.stats.reads - in_step;
                try w.print("          the disk reads page {d} into the pool\n", .{id});
            },
        }
    }
    try w.print("  {d} calls; pages read by the disk: {d}, by the insert itself: {d}\n", .{
        call, disk_reads, rig.pager.stats.reads - reads_before - disk_reads,
    });
}

fn part1(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 1: one insert, call by call (2-frame pool) ==\n");
    var rig: Rig = undefined;
    try rig.create(gpa, 2);
    defer rig.deinit();
    for (scenario_keys[0..6]) |n| try rig.putScenario(n);
    try w.print("6 keys on {d} pages; the root (page 1) is still a leaf\n", .{rig.pager.pageCount()});
    try traceInsert(w, gpa, &rig, 7);
    try rig.tree.dump(w);
    for (scenario_keys[7..11]) |n| try rig.putScenario(n);
    try traceInsert(w, gpa, &rig, 15);
    try rig.tree.dump(w);
    try rig.tree.validate();
}

// ---- Part 2 -------------------------------------------------------------------

const part2_puts = 2000;

fn printSuspensions(w: *Io.Writer, s: *const Scheduler) !void {
    try w.print("  {d} calls of step, {d} of them returned Io\n  suspended in:", .{ s.steps, s.yields });
    for (s.suspended, 0..) |n, i| {
        const state: State = @fromBackingInt(@intCast(i));
        try w.print("{s} {t} {d}", .{ if (i == 0) "" else ",", state, n });
    }
    try w.writeAll("\n");
}

fn part2(w: *Io.Writer, gpa: Allocator) !void {
    try w.print("\n== Part 2: {d} puts, blocking and resumable (4-frame pools) ==\n", .{part2_puts});
    var key_buf: [workload.max_key_len]u8 = undefined;
    var value_buf: [workload.max_value_len]u8 = undefined;

    var blocking: Rig = undefined;
    try blocking.create(gpa, 4);
    defer blocking.deinit();
    var rng = SplitMix64.init(30);
    for (0..part2_puts) |_| {
        const key = workload.keyFor(rng.below(3000), 64, &key_buf);
        try blocking.tree.put(key, workload.randomValue(&rng, 300, &value_buf));
    }
    try blocking.tree.flush();
    const t = &blocking.tree;
    try w.print("blocking put: {d} keys, {d} pages, height {d}; splits: {d} leaf, {d} interior, {d} root\n", .{
        t.key_count,         blocking.pager.pageCount(), try t.height(),
        t.stats.leaf_splits, t.stats.interior_splits,    t.stats.root_splits,
    });

    for ([_]bool{ false, true }) |pressure| {
        var rig: Rig = undefined;
        try rig.create(gpa, 4);
        defer rig.deinit();
        var s: Scheduler = .init(gpa, &rig.tree, 30);
        defer s.deinit();
        s.insert_options.pressure = pressure;
        rng = SplitMix64.init(30);
        for (0..part2_puts) |_| {
            const key = workload.keyFor(rng.below(3000), 64, &key_buf);
            _ = try s.submitInsert(gpa, key, workload.randomValue(&rng, 300, &value_buf));
        }
        try s.run();
        try rig.tree.validate();
        try rig.tree.flush();
        try w.print("resumable insert{s}:\n", .{if (pressure) ", every unpinned page dropped between transitions" else ""});
        try printSuspensions(w, &s);
        try w.print("  pages read by the disk: {d}; file identical to the blocking one: {}\n", .{
            rig.pager.stats.reads, std.mem.eql(u8, rig.mem.bytes.items, blocking.mem.bytes.items),
        });
    }
}

// ---- Part 3 -------------------------------------------------------------------

fn part3(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 3: five operations on one thread (8-frame pool, nothing cached) ==\n");
    var rig: Rig = undefined;
    try rig.create(gpa, 8);
    defer rig.deinit();
    for (scenario_keys) |n| try rig.putScenario(n);
    _ = try rig.pool.evictUnpinned();

    var events: std.ArrayList(Scheduler.Event) = .empty;
    defer events.deinit(gpa);
    var s: Scheduler = .init(gpa, &rig.tree, 3);
    defer s.deinit();
    s.events = &events;

    var value_buf: [btree.max_value_len]u8 = undefined;
    const names = [_][]const u8{ "get 17", "get 03", "get 28", "put 24", "get 24" };
    _ = try s.submitGet(gpa, "17");
    _ = try s.submitGet(gpa, "03");
    _ = try s.submitGet(gpa, "28");
    _ = try s.submitInsert(gpa, "24", scenarioValue(24, &value_buf));
    _ = try s.submitGet(gpa, "24");
    try s.run();

    for (events.items) |e| {
        const name = names[e.op];
        switch (e.kind) {
            .admit => try w.print("  #{d} {s}: admitted\n", .{ e.op, name }),
            .yield => try w.print("  #{d} {s}: Io(page {d})\n", .{ e.op, name, e.page }),
            .complete => try w.print("  disk: page {d} is in the pool, wake #{d}\n", .{ e.page, e.op }),
            .failed => try w.print("  #{d} {s}: failed\n", .{ e.op, name }),
            .done => {
                try w.print("  #{d} {s}: Done", .{ e.op, name });
                switch (s.slots.items[e.op].op) {
                    .insert => try w.writeAll("\n"),
                    .get => |*op| if (op.value) |v| try w.print(", {d} bytes\n", .{v.len}) else try w.writeAll(", not found\n"),
                }
            },
        }
    }
    try rig.tree.validate();
}

// ---- Part 4 -------------------------------------------------------------------

fn part4(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 4: why the writer runs alone (2-frame pool) ==\n");
    var rig: Rig = undefined;
    try rig.create(gpa, 2);
    defer rig.deinit();
    for (scenario_keys) |n| try rig.putScenario(n);

    // A value large enough that the leaf holding 12 .. 18 must split.
    const value: [1000]u8 = @splat('q');
    var op: InsertOp = try .init(gpa, &rig.tree, "16", &value, .{});
    defer op.deinit();
    // Step until the leaf has been split but the parent does not know yet.
    var last: resumable.Step = try op.step();
    while (op.state != .insert_separator) : (last = try op.step()) try rig.supply(last.io);
    try w.print("insert 16 has split a leaf into pages {d} and {d} and waits for page {d} in state {t}\n", .{
        op.carry.left, op.carry.right, last.io, op.state,
    });
    // A reader that is let in now walks the tree as it is in memory.
    for ([_][]const u8{ "15", "18" }) |key| {
        const found = try rig.tree.get(gpa, key);
        defer if (found) |v| gpa.free(v);
        try w.print("  a get of {s} let in now: {s}\n", .{ key, if (found != null) "found" else "NOT FOUND, although the key is in the tree" });
    }
    while (last == .io) : (last = try op.step()) try rig.supply(last.io);
    const found = try rig.tree.get(gpa, "18");
    defer if (found) |v| gpa.free(v);
    try w.print("after the insert is done, get 18: {s}\n", .{if (found != null) "found" else "not found"});
    try rig.tree.validate();
}

// ---- Part 5 -------------------------------------------------------------------

/// Insert 01, 02, ... in order through the scheduler, validating after each.
/// Returns the first key after which the tree is broken, or null.
pub fn ascendingUntilBroken(gpa: Allocator, frames: u32, scratch: resumable.Scratch, last_key: u8, violation: *[]const u8) !?u8 {
    var rig: Rig = undefined;
    try rig.create(gpa, frames);
    defer rig.deinit();
    var key_buf: [2]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    var n: u8 = 1;
    while (n <= last_key) : (n += 1) {
        var s: Scheduler = .init(gpa, &rig.tree, 5);
        defer s.deinit();
        s.insert_options.scratch = scratch;
        _ = try s.submitInsert(gpa, scenarioKey(n, &key_buf), scenarioValue(n, &value_buf));
        try s.run();
        rig.tree.validate() catch |err| {
            violation.* = @errorName(err);
            return n;
        };
    }
    return null;
}

fn part5(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 5: where the scratch memory of a split must live ==\n");
    const cases = [_]struct { frames: u32, scratch: resumable.Scratch, label: []const u8 }{
        .{ .frames = 2, .scratch = .op_arena, .label = "owned by the operation, 2-frame pool" },
        .{ .frames = 64, .scratch = .step_buffer, .label = "buffer reused per call, 64-frame pool" },
        .{ .frames = 2, .scratch = .step_buffer, .label = "buffer reused per call, 2-frame pool" },
    };
    for (cases) |case| {
        var violation: []const u8 = "";
        if (try ascendingUntilBroken(gpa, case.frames, case.scratch, 30, &violation)) |n| {
            try w.print("{s}: tree broken after insert {d:0>2} ({s})\n", .{ case.label, n, violation });
        } else {
            try w.print("{s}: 30 inserts, validate ok after each\n", .{case.label});
        }
    }
}
