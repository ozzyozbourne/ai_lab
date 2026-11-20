//! demo.zig: the fixed, deterministic scenario printed by `zig build run`.
//!
//! Part 1  24 keys with values of 324 to 1020 bytes in a real file, through
//!         a 3-frame buffer pool. The visualization replays exactly this
//!         part and checks its tree and its counters.
//! Part 2  a seeded workload of variable-length keys and values on an
//!         in-memory storage, with a reopen in the middle.
//! Part 3  integer keys: big-endian bytes make memcmp order numeric order.
//! Part 4  not crash-safe: the same split, stopped after every page write.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const storage_mod = @import("base_storage.zig");
const MemStorage = storage_mod.MemStorage;
const FileStorage = storage_mod.FileStorage;
const Pager = @import("base_pager.zig").Pager;
const BufferPool = @import("base_buffer_pool.zig").BufferPool;
const btree = @import("disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const workload = @import("workload.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;

pub const db_name = "ch12_demo.db";

/// The keys of parts 1 and 4, in insertion order. The first twelve are the
/// guide's canonical example.
pub const scenario_keys = [_]u8{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15, 8, 22, 28, 14, 2, 27, 18, 9, 23, 11, 29, 4 };

/// Key `n` as two decimal digits, so that byte order is numeric order.
fn scenarioKey(n: u8, buf: *[2]u8) []const u8 {
    buf.* = .{ '0' + n / 10, '0' + n % 10 };
    return buf;
}

/// The value of key `n`: 300 + 24 * n copies of one letter. Small keys have
/// small values, so the leaves on the left hold more cells than the leaves
/// on the right.
fn scenarioValue(n: u8, buf: *[btree.max_value_len]u8) []const u8 {
    const len = 300 + 24 * @as(usize, n);
    @memset(buf[0..len], 'a' + n % 26);
    return buf[0..len];
}

fn scenarioPut(tree: *DiskBTree, n: u8) !void {
    var key_buf: [2]u8 = undefined;
    var value_buf: [btree.max_value_len]u8 = undefined;
    try tree.put(scenarioKey(n, &key_buf), scenarioValue(n, &value_buf));
}

pub fn run(w: *Io.Writer, gpa: Allocator, io: Io, dir: Io.Dir) !void {
    try w.writeAll("Chapter 12: a disk-backed B+tree\n");
    // Remove the demo file on every path out of here, errors included.
    defer dir.deleteFile(io, db_name) catch {};
    try part1(w, gpa, io, dir);
    try part2(w, gpa);
    try part3(w, gpa);
    try part4(w, gpa);
}

fn printCounters(w: *Io.Writer, tree: *DiskBTree) !void {
    const pool = tree.pool;
    try w.print("tree:  {d} keys, {d} pages, height {d}; splits: {d} leaf, {d} interior, {d} root\n", .{
        tree.key_count,           pool.pager.pageCount(), try tree.height(),
        tree.stats.leaf_splits, tree.stats.interior_splits, tree.stats.root_splits,
    });
    try w.print("pool:  {d} hits, {d} misses, {d} evictions, {d} write-backs\n", .{ pool.stats.hits, pool.stats.misses, pool.stats.evictions, pool.stats.writebacks });
    try w.print("pager: {d} reads, {d} writes, {d} allocations, {d} syncs\n", .{ pool.pager.stats.reads, pool.pager.stats.writes, pool.pager.stats.allocations, pool.pager.stats.syncs });
}

fn part1(w: *Io.Writer, gpa: Allocator, io: Io, dir: Io.Dir) !void {
    try w.writeAll("\n== Part 1: a tree of pages in a real file (3-frame pool) ==\n");
    try w.print("a page offers {d} bytes to cells; a key may have {d} bytes, a value {d}\n", .{ btree.page_capacity, btree.max_key_len, btree.max_value_len });
    {
        var file: FileStorage = try .create(io, dir, db_name);
        defer file.close();
        var pager: Pager = try .init(file.storage());
        var pool: BufferPool = try .init(gpa, &pager, 3);
        defer pool.deinit();
        var tree: DiskBTree = try .create(gpa, &pool);
        defer tree.deinit();
        try w.print("created {s}: {d} pages (page 0 = metapage, page {d} = root)\n", .{ db_name, pager.pageCount(), tree.root });

        var key_buf: [2]u8 = undefined;
        for (scenario_keys, 1..) |n, i| {
            const before = tree.stats;
            try scenarioPut(&tree, n);
            const leaf_split = tree.stats.leaf_splits != before.leaf_splits;
            if (!leaf_split) continue;
            const grew = tree.stats.root_splits != before.root_splits;
            try w.print("put #{d} key {s} ({d} bytes) splits a leaf{s}: {d} pages\n", .{
                i,                                               scenarioKey(n, &key_buf),                      btree.cellCost(2, 300 + 24 * @as(usize, n)),
                if (grew) " and moves the root down" else "", pager.pageCount(),
            });
            if (grew) try tree.dump(w);
        }
        try w.writeAll("after 24 puts:\n");
        try tree.dump(w);
        try tree.validate();
        try printCounters(w, &tree);
        try tree.flush();
        try w.print("flushed: file size = {d} bytes\n", .{try file.storage().size()});
    }
    var file: FileStorage = try .open(io, dir, db_name);
    defer file.close();
    var pager: Pager = try .init(file.storage());
    var pool: BufferPool = try .init(gpa, &pager, 3);
    defer pool.deinit();
    var tree: DiskBTree = try .open(gpa, &pool);
    defer tree.deinit();
    try tree.validate();
    try w.print("reopened: root = page {d}, {d} keys, height {d}, validate ok\n", .{ tree.root, tree.key_count, try tree.height() });

    const value = (try tree.get(gpa, "17")).?;
    defer gpa.free(value);
    try w.print("get 17 -> {d} bytes of '{c}'\n", .{ value.len, value[0] });
    try w.print("get 13 -> {s}\n", .{if (try tree.get(gpa, "13")) |_| "found?!" else "not found"});
    try w.writeAll("range [10, 20) ->");
    var it = try tree.range("10", "20");
    while (try it.next()) |item| try w.print(" {s}:{d}", .{ item.key, item.value.len });
    try w.writeAll("\n");
}

fn part2(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 2: 4000 random puts, keys of 1 to 64 bytes, values of 0 to 300 bytes (8-frame pool) ==\n");
    var mem: MemStorage = .init(gpa);
    defer mem.deinit();
    var model: workload.Model = .init(gpa);
    defer model.deinit();
    var rng = SplitMix64.init(12);
    var key_buf: [workload.max_key_len]u8 = undefined;
    var value_buf: [workload.max_value_len]u8 = undefined;

    for (0..2) |half| {
        var pager: Pager = try .init(mem.storage());
        var pool: BufferPool = try .init(gpa, &pager, 8);
        defer pool.deinit();
        var tree: DiskBTree = if (half == 0) try .create(gpa, &pool) else try .open(gpa, &pool);
        defer tree.deinit();
        for (0..2000) |_| {
            const key = workload.keyFor(rng.below(3000), 64, &key_buf);
            const value = workload.randomValue(&rng, 300, &value_buf);
            try tree.put(key, value);
            try model.put(key, value);
        }
        try tree.validate();
        try w.print("{s}\n", .{if (half == 0) "first 2000 puts:" else "reopened, 2000 more puts:"});
        try printCounters(w, &tree);
        try tree.flush();
        if (half == 0) continue;

        // Compare everything with the oracle: one full scan.
        var it = try tree.range("", null);
        var same = true;
        var count: usize = 0;
        while (try it.next()) |item| : (count += 1) {
            const expected = model.entries.items[count];
            same = same and std.mem.eql(u8, item.key, expected.key) and std.mem.eql(u8, item.value, expected.value);
        }
        try w.print("full scan: {d} entries, oracle has {d}, identical: {}\n", .{ count, model.len(), same and count == model.len() });
    }
}

fn part3(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 3: integer keys as big-endian bytes (chapter 11) ==\n");
    var mem: MemStorage = .init(gpa);
    defer mem.deinit();
    var pager: Pager = try .init(mem.storage());
    var pool: BufferPool = try .init(gpa, &pager, 8);
    defer pool.deinit();
    var tree: DiskBTree = try .create(gpa, &pool);
    defer tree.deinit();

    // 1 .. 1000 in a shuffled order; the value is the number as text.
    var numbers: [1000]u64 = undefined;
    for (&numbers, 1..) |*n, i| n.* = i;
    var rng = SplitMix64.init(3);
    rng.shuffle(&numbers);
    var key: [8]u8 = undefined;
    var text: [20]u8 = undefined;
    for (numbers) |n| {
        std.mem.writeInt(u64, &key, n, .big);
        try tree.put(&key, try std.fmt.bufPrint(&text, "{d}", .{n}));
    }
    try tree.validate();
    try w.print("1000 keys, {d} pages, height {d}\n", .{ pager.pageCount(), try tree.height() });

    var lo: [8]u8 = undefined;
    var hi: [8]u8 = undefined;
    std.mem.writeInt(u64, &lo, 254, .big);
    std.mem.writeInt(u64, &hi, 259, .big);
    try w.writeAll("range [254, 259) ->");
    var it = try tree.range(&lo, &hi);
    while (try it.next()) |item| try w.print(" {s}", .{item.value});
    try w.writeAll("\n(255 = 00..00ff and 256 = 00..0100: adjacent as bytes only because the high byte comes first)\n");
}

// ---- Part 4 -------------------------------------------------------------------

/// What is left in the storage when a split is cut short.
pub const CrashOutcome = struct {
    /// The put and the flush both finished: there was no crash.
    completed: bool = false,
    open_error: ?anyerror = null,
    validate_error: ?anyerror = null,
    old_keys_readable: usize = 0,
    new_key_readable: bool = false,
};

/// The index into `scenario_keys` of the put that causes the second leaf
/// split (the first one that has to update an existing parent).
pub const crash_put = 11;

/// Build the scenario tree up to (not including) `crash_put` and flush it.
/// Then let only `writes_allowed` more page writes reach the storage while
/// the next put splits a leaf and the tree is flushed. Finally forget
/// everything in memory, as a crash does, reopen and look.
pub fn crashDuringSplit(gpa: Allocator, writes_allowed: u64) !CrashOutcome {
    var mem: MemStorage = .init(gpa);
    defer mem.deinit();
    var outcome: CrashOutcome = .{};
    {
        var pager: Pager = try .init(mem.storage());
        var pool: BufferPool = try .init(gpa, &pager, 8);
        defer pool.deinit(); // no flush: dirty pages in memory are lost
        var tree: DiskBTree = try .create(gpa, &pool);
        defer tree.deinit();
        for (scenario_keys[0..crash_put]) |n| try scenarioPut(&tree, n);
        try tree.flush();

        mem.writes_before_failure = writes_allowed;
        const splits_before = tree.stats.leaf_splits;
        if (scenarioPut(&tree, scenario_keys[crash_put])) |_| {
            std.debug.assert(tree.stats.leaf_splits == splits_before + 1);
            if (tree.flush()) |_| {
                outcome.completed = true;
            } else |_| {}
        } else |_| {}
        mem.writes_before_failure = null;
    }

    var pager: Pager = try .init(mem.storage());
    var pool: BufferPool = try .init(gpa, &pager, 8);
    defer pool.deinit();
    var tree = DiskBTree.open(gpa, &pool) catch |err| {
        outcome.open_error = err;
        return outcome;
    };
    defer tree.deinit();
    tree.validate() catch |err| {
        outcome.validate_error = err;
    };
    var key_buf: [2]u8 = undefined;
    for (scenario_keys[0 .. crash_put + 1], 0..) |n, i| {
        // A lookup that runs into a broken page counts as "not readable".
        const found = tree.get(gpa, scenarioKey(n, &key_buf)) catch null;
        if (found) |value| {
            gpa.free(value);
            if (i == crash_put) outcome.new_key_readable = true else outcome.old_keys_readable += 1;
        }
    }
    return outcome;
}

fn part4(w: *Io.Writer, gpa: Allocator) !void {
    try w.writeAll("\n== Part 4: not crash-safe: one split, stopped after every page write ==\n");
    var key_buf: [2]u8 = undefined;
    try w.print("{d} keys are on disk; put {s} splits a leaf, then flush; the storage fails after N writes\n", .{ crash_put, scenarioKey(scenario_keys[crash_put], &key_buf) });
    var writes: u64 = 0;
    while (true) : (writes += 1) {
        const o = try crashDuringSplit(gpa, writes);
        try w.print("N = {d}: ", .{writes});
        if (o.completed) try w.writeAll("no crash, all writes done; ");
        if (o.open_error) |err| {
            try w.print("open fails with error.{t}\n", .{err});
            continue;
        }
        if (o.validate_error) |err| try w.print("validate fails with error.{t}", .{err}) else try w.writeAll("validate ok");
        try w.print("; {d} of {d} old keys readable; new key {s}\n", .{ o.old_keys_readable, crash_put, if (o.new_key_readable) "readable" else "missing" });
        if (o.completed) break;
    }
}
