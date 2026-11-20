//! tests.zig: everything that tests DiskBTree through its public API.
//!
//! The model tests compare the tree with the oracle of workload.zig after
//! every operation, on memory and on a real file, with pools as small as two
//! frames, with reopens in the middle, and with injected I/O and allocation
//! failures. `std.testing.allocator` fails a test that leaks memory and
//! `BufferPool.deinit` asserts that no pin is left, so every test below is
//! also a leak test for both.
const std = @import("std");
const testing = std.testing;

const storage_mod = @import("base_storage.zig");
const Storage = storage_mod.Storage;
const MemStorage = storage_mod.MemStorage;
const FileStorage = storage_mod.FileStorage;
const Pager = @import("base_pager.zig").Pager;
const BufferPool = @import("base_buffer_pool.zig").BufferPool;
const SlottedPage = @import("base_slotted_page.zig").SlottedPage;
const btree = @import("disk_btree.zig");
const DiskBTree = btree.DiskBTree;
const demo = @import("demo.zig");
const workload = @import("workload.zig");
const Model = workload.Model;
const SplitMix64 = @import("prng.zig").SplitMix64;

/// Pager + pool + tree over one storage, at a stable address.
const Db = struct {
    pager: Pager,
    pool: BufferPool,
    tree: DiskBTree,

    const Mode = enum { create, open };

    fn start(self: *Db, storage: Storage, frames: u32, mode: Mode) !void {
        self.pager = try .init(storage);
        self.pool = try .init(testing.allocator, &self.pager, frames);
        errdefer self.pool.deinit();
        self.tree = switch (mode) {
            .create => try .create(testing.allocator, &self.pool),
            .open => try .open(testing.allocator, &self.pool),
        };
    }

    /// Forget everything in memory WITHOUT flushing.
    fn stop(self: *Db) void {
        self.tree.deinit();
        self.pool.deinit();
    }

    fn reopen(self: *Db, storage: Storage, frames: u32) !void {
        try self.tree.flush();
        self.stop();
        try self.start(storage, frames, .open);
    }
};

fn expectValue(tree: *DiskBTree, key: []const u8, expected: ?[]const u8) !void {
    const got = try tree.get(testing.allocator, key);
    defer if (got) |v| testing.allocator.free(v);
    if (expected) |e| {
        try testing.expect(got != null);
        try testing.expectEqualSlices(u8, e, got.?);
    } else try testing.expectEqual(null, got);
}

fn expectRange(tree: *DiskBTree, model: *const Model, lo: []const u8, hi: ?[]const u8) !void {
    var it = try tree.range(lo, hi);
    for (model.range(lo, hi)) |expected| {
        const item = (try it.next()) orelse return error.TestExpectedMoreEntries;
        try testing.expectEqualSlices(u8, expected.key, item.key);
        try testing.expectEqualSlices(u8, expected.value, item.value);
    }
    try testing.expectEqual(null, try it.next());
    try testing.expectEqual(null, try it.next()); // stays at the end
}

/// The tree holds exactly what the model holds.
fn expectSameContent(tree: *DiskBTree, model: *const Model) !void {
    try tree.validate();
    try testing.expectEqual(model.len(), tree.key_count);
    try expectRange(tree, model, "", null);
}

const Shape = struct {
    frames: u32,
    key_space: u64,
    max_key: usize,
    max_value: usize,
    ops: usize = 0,
    reopen_every: usize = 1,
    /// How many operations in ten are puts; the rest are gets (2), a range
    /// scan and a flush.
    puts: u64 = 6,
};

/// One random operation against tree and model. Returns the tree's error;
/// the model is only changed when the tree succeeded.
fn randomOp(tree: *DiskBTree, model: *Model, rng: *SplitMix64, shape: Shape) !void {
    var key_buf: [workload.max_key_len]u8 = undefined;
    var hi_buf: [workload.max_key_len]u8 = undefined;
    var value_buf: [workload.max_value_len]u8 = undefined;
    const key = workload.keyFor(rng.below(shape.key_space), shape.max_key, &key_buf);
    const pick = rng.below(10);
    if (pick < shape.puts) {
        const value = workload.randomValue(rng, shape.max_value, &value_buf);
        try tree.put(key, value);
        try model.put(key, value);
    } else switch (pick) {
        6, 7 => try expectValue(tree, key, model.get(key)),
        8 => {
            const hi = workload.keyFor(rng.below(shape.key_space), shape.max_key, &hi_buf);
            try expectRange(tree, model, key, if (rng.chance(1, 4)) null else hi);
        },
        else => try tree.flush(),
    }
}

fn runModel(storage: Storage, seed: u64, shape: Shape) !void {
    var model: Model = .init(testing.allocator);
    defer model.deinit();
    var db: Db = undefined;
    try db.start(storage, shape.frames, .create);
    defer db.stop();
    var rng = SplitMix64.init(seed);

    for (1..shape.ops + 1) |i| {
        try randomOp(&db.tree, &model, &rng, shape);
        try testing.expectEqual(0, db.pool.pinnedFrames());
        if (i % 500 == 0) try expectSameContent(&db.tree, &model);
        if (i % shape.reopen_every == 0) try db.reopen(storage, shape.frames);
    }
    try expectSameContent(&db.tree, &model);
    try db.pool.validate();
    try testing.expectEqual(1, db.tree.root); // the root never moved
    try testing.expect(try db.tree.height() >= 2);
}

test "model: memory storage, tiny pools, reopen mid-run" {
    const shapes = [_]Shape{
        // 3 frames: nearly every page access evicts, also in the middle of a split.
        .{ .frames = 3, .key_space = 700, .max_key = 24, .max_value = 120, .ops = 5000, .reopen_every = 1700 },
        // 2 frames is the minimum: a split pins two pages.
        .{ .frames = 2, .key_space = 500, .max_key = 40, .max_value = 300, .ops = 3000, .reopen_every = 900 },
        // The largest keys and values allowed: three or four cells per leaf.
        .{ .frames = 4, .key_space = 400, .max_key = btree.max_key_len, .max_value = btree.max_value_len, .ops = 3000, .reopen_every = 1100 },
        // Long keys, empty-ish values: interior pages split often.
        .{ .frames = 16, .key_space = 5000, .max_key = btree.max_key_len, .max_value = 8, .ops = 6000, .reopen_every = 2500 },
    };
    for (shapes, 1..) |shape, seed| {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        try runModel(mem.storage(), seed, shape);
    }
}

test "model: a real file, closed and opened again" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const shape: Shape = .{ .frames = 5, .key_space = 800, .max_key = 48, .max_value = 400, .ops = 3000, .reopen_every = 700 };
    {
        var file: FileStorage = try .create(io, tmp.dir, "tree.db");
        defer file.close();
        try runModel(file.storage(), 42, shape);
    }
    // Replay the same puts into a model and compare with the file as it
    // was left by the run above: nothing but the file carries the data.
    var model: Model = .init(testing.allocator);
    defer model.deinit();
    {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var db: Db = undefined;
        try db.start(mem.storage(), 64, .create);
        defer db.stop();
        var rng = SplitMix64.init(42);
        for (0..shape.ops) |_| try randomOp(&db.tree, &model, &rng, shape);
    }
    var file: FileStorage = try .open(io, tmp.dir, "tree.db");
    defer file.close();
    var db: Db = undefined;
    try db.start(file.storage(), shape.frames, .open);
    defer db.stop();
    try expectSameContent(&db.tree, &model);
}

test "injected I/O failures: an error, no leaked pin, and a tree that is intact or poisoned" {
    const shapes = [2]Shape{
        .{ .frames = 3, .key_space = 600, .max_key = 32, .max_value = 200 },
        // Only puts of large cells: the failure often lands inside a split.
        .{ .frames = 3, .key_space = 5000, .max_key = 200, .max_value = 1000, .puts = 10 },
    };
    var clean_failures: usize = 0;
    var poisoned_failures: usize = 0;
    for ([_]bool{ false, true }) |fail_reads| {
        var countdown: u64 = 0;
        while (countdown < 150) : (countdown += 1) {
            const shape = shapes[countdown % 2];
            var mem: MemStorage = .init(testing.allocator);
            defer mem.deinit();
            var model: Model = .init(testing.allocator);
            defer model.deinit();
            var db: Db = undefined;
            try db.start(mem.storage(), shape.frames, .create);
            defer db.stop(); // asserts that no pin is left
            var rng = SplitMix64.init(1000 + countdown);
            for (0..250) |_| try randomOp(&db.tree, &model, &rng, shape);

            if (fail_reads) mem.reads_before_failure = countdown else mem.writes_before_failure = countdown;
            for (0..300) |_| {
                randomOp(&db.tree, &model, &rng, shape) catch |err| {
                    try testing.expectEqual(error.StorageFailure, err);
                    try testing.expectEqual(0, db.pool.pinnedFrames());
                    try db.pool.validate();
                    mem.reads_before_failure = null;
                    mem.writes_before_failure = null;
                    if (db.tree.poisoned) {
                        // The failure hit between two page changes of a split.
                        poisoned_failures += 1;
                        try testing.expectError(error.TreePoisoned, db.tree.put("k", "v"));
                        try testing.expectError(error.TreePoisoned, db.tree.get(testing.allocator, "k"));
                        try testing.expectError(error.TreePoisoned, db.tree.range("", null));
                        try testing.expectError(error.TreePoisoned, db.tree.flush());
                    } else {
                        // The failed operation did not happen at all.
                        clean_failures += 1;
                        try expectSameContent(&db.tree, &model);
                        for (0..50) |_| try randomOp(&db.tree, &model, &rng, shape);
                        try expectSameContent(&db.tree, &model);
                    }
                    break;
                };
            }
        }
    }
    // Both outcomes must have been exercised.
    try testing.expect(clean_failures > 50);
    try testing.expect(poisoned_failures >= 3);
}

test "a failure between the page changes of a split poisons the handle" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 8, .create);
    defer db.stop();
    const value: [1000]u8 = @splat('v');
    for ([_][]const u8{ "a", "b", "c", "d" }) |key| try db.tree.put(key, &value);

    // The fifth cell does not fit. Splitting the root leaf allocates two
    // pages; let the first allocation succeed and the second fail.
    mem.writes_before_failure = 1;
    try testing.expectError(error.StorageFailure, db.tree.put("e", &value));
    mem.writes_before_failure = null;
    try testing.expect(db.tree.poisoned);
    try testing.expectEqual(0, db.pool.pinnedFrames());
    // The four calls that would act on the half-split tree refuse.
    try testing.expectError(error.TreePoisoned, db.tree.put("e", &value));
    try testing.expectError(error.TreePoisoned, db.tree.get(testing.allocator, "a"));
    try testing.expectError(error.TreePoisoned, db.tree.range("", null));
    try testing.expectError(error.TreePoisoned, db.tree.flush());
    // The three that only look do not: they are how the damage is examined.
    // Here the root moved down (page 1 is an interior page without a key,
    // page 2 has its four cells) and the split of page 2 never started.
    try testing.expectError(error.EmptyPage, db.tree.validate());
    try testing.expectEqual(2, try db.tree.height());
    var dump: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dump.deinit();
    try db.tree.dump(&dump.writer);
    try testing.expectEqualStrings(
        \\page 1  interior  0 keys  0/4076 bytes  | (2)
        \\  page 2  leaf      4 keys  4028/4076 bytes  next -  | a:1000 b:1000 c:1000 d:1000
        \\
    , dump.written());
    try testing.expectEqual(0, db.pool.pinnedFrames());

    // A failure BEFORE the first page change leaves a working tree.
    var mem2: MemStorage = .init(testing.allocator);
    defer mem2.deinit();
    var db2: Db = undefined;
    try db2.start(mem2.storage(), 8, .create);
    defer db2.stop();
    for ([_][]const u8{ "a", "b", "c", "d" }) |key| try db2.tree.put(key, &value);
    mem2.writes_before_failure = 0;
    try testing.expectError(error.StorageFailure, db2.tree.put("e", &value));
    mem2.writes_before_failure = null;
    try testing.expect(!db2.tree.poisoned);
    try db2.tree.validate();
    try db2.tree.put("e", &value);
    try db2.tree.validate();
    try testing.expectEqual(5, db2.tree.key_count);
}

test "allocation failure in put: OutOfMemory, no leaked pin, intact or poisoned" {
    const shape: Shape = .{ .frames = 4, .key_space = 3000, .max_key = btree.max_key_len, .max_value = 30 };
    var induced: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var model: Model = .init(testing.allocator);
        defer model.deinit();
        var pager: Pager = try .init(mem.storage());
        var pool: BufferPool = try .init(testing.allocator, &pager, shape.frames);
        defer pool.deinit();
        // Only the tree's scratch arena draws from the failing allocator.
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        var tree: DiskBTree = try .create(failing.allocator(), &pool);
        defer tree.deinit();
        var rng = SplitMix64.init(7);

        for (0..1500) |_| {
            randomOp(&tree, &model, &rng, shape) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expect(failing.has_induced_failure);
                try testing.expectEqual(0, pool.pinnedFrames());
                induced += 1;
                failing.fail_index = std.math.maxInt(usize); // memory is back
                if (!tree.poisoned) {
                    try expectSameContent(&tree, &model);
                    for (0..200) |_| try randomOp(&tree, &model, &rng, shape);
                    try expectSameContent(&tree, &model);
                }
                break;
            };
        }
    }
    // The arena keeps its memory between operations, so only its first few
    // requests ever reach the backing allocator.
    try testing.expect(induced >= 3);
}

fn buildScenario(db: *Db, mem: *MemStorage) !void {
    try db.start(mem.storage(), 8, .create);
    var value: [btree.max_value_len]u8 = undefined;
    for (demo.scenario_keys) |n| {
        const key = [2]u8{ '0' + n / 10, '0' + n % 10 };
        @memset(&value, 'a' + n % 26);
        try db.tree.put(&key, value[0 .. 300 + 24 * @as(usize, n)]);
    }
    try db.tree.validate();
}

test "the root page id is stable while the tree grows to three levels" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 8, .create);
    defer db.stop();
    try testing.expectEqual(1, db.tree.root);
    try testing.expectEqual(1, try db.tree.height());

    // Keys of 200 bytes: about 19 separators per interior page.
    var key: [200]u8 = @splat('k');
    for (0..2000) |i| {
        _ = try std.fmt.bufPrint(key[0..6], "{d:0>6}", .{i * 7919 % 2000});
        try db.tree.put(&key, "v");
    }
    try db.tree.validate();
    try testing.expectEqual(3, try db.tree.height());
    try testing.expectEqual(2, db.tree.stats.root_splits);
    try testing.expect(db.tree.stats.interior_splits > 0);
    try testing.expectEqual(1, db.tree.root);

    // The metapage on disk agrees after a reopen.
    try db.reopen(mem.storage(), 8);
    try testing.expectEqual(1, db.tree.root);
    try testing.expectEqual(2000, db.tree.key_count);
    try db.tree.validate();
}

test "full is a number of bytes, not a number of keys" {
    // Cells of 1010 bytes: four fit in 4076 bytes, the fifth splits.
    // Cells of 18 bytes: 226 fit, the 227th splits.
    const cases = [_]struct { value_len: usize, fit: usize }{ .{ .value_len = 1000, .fit = 4 }, .{ .value_len = 8, .fit = 226 } };
    for (cases) |case| {
        try testing.expect(case.fit * btree.cellCost(4, case.value_len) <= btree.page_capacity);
        try testing.expect((case.fit + 1) * btree.cellCost(4, case.value_len) > btree.page_capacity);
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var db: Db = undefined;
        try db.start(mem.storage(), 8, .create);
        defer db.stop();
        const value: [1000]u8 = @splat('v');
        var key: [4]u8 = undefined;
        for (0..case.fit) |i| {
            _ = try std.fmt.bufPrint(&key, "{d:0>4}", .{i});
            try db.tree.put(&key, value[0..case.value_len]);
        }
        try testing.expectEqual(0, db.tree.stats.leaf_splits);
        try db.tree.put("9999", value[0..case.value_len]);
        try testing.expectEqual(1, db.tree.stats.leaf_splits);
        try db.tree.validate();
    }
}

test "splitPoint: the shortest prefix with at least half of the bytes" {
    try testing.expectEqual(2, btree.splitPoint(&.{ 10, 10, 10, 10 }, 1));
    try testing.expectEqual(1, btree.splitPoint(&.{ 100, 1, 1, 1 }, 1));
    try testing.expectEqual(3, btree.splitPoint(&.{ 1, 1, 1, 100 }, 1)); // the right half is never empty
    try testing.expectEqual(3, btree.splitPoint(&.{ 5, 5, 5, 5, 5 }, 2));
    try testing.expectEqual(2, btree.splitPoint(&.{ 1, 1, 1, 100 }, 2)); // interior: one entry right of the middle
}

test "limits: keys and values that are too large are refused, the largest are accepted" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 4, .create);
    defer db.stop();
    const big: [btree.max_value_len + 1]u8 = @splat('x');
    try testing.expectError(error.KeyTooLarge, db.tree.put(big[0 .. btree.max_key_len + 1], "v"));
    try testing.expectError(error.ValueTooLarge, db.tree.put("k", &big));
    try testing.expectEqual(0, db.tree.key_count);

    // Every cell as large as allowed: any three fit in a page.
    var key: [btree.max_key_len]u8 = @splat('k');
    for (0..200) |i| {
        _ = try std.fmt.bufPrint(key[0..3], "{d:0>3}", .{i * 37 % 200});
        try db.tree.put(&key, big[0..btree.max_value_len]);
    }
    try db.tree.validate();
    try testing.expectEqual(200, db.tree.key_count);
    // The empty key and the empty value are legal.
    try db.tree.put("", "");
    try expectValue(&db.tree, "", "");
    // Overwriting with a larger value can split, with a smaller one cannot.
    try db.tree.put(&key, "small");
    try expectValue(&db.tree, &key, "small");
    try db.tree.validate();
    try testing.expectEqual(201, db.tree.key_count);
}

test "range: bounds are half-open, leaves are followed through their links" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try buildScenario(&db, &mem);
    defer db.stop();

    const Case = struct { lo: []const u8, hi: ?[]const u8, first: ?[]const u8, count: usize };
    const cases = [_]Case{
        .{ .lo = "", .hi = null, .first = "01", .count = 24 },
        .{ .lo = "10", .hi = "20", .first = "10", .count = 7 }, // 20 itself is excluded
        .{ .lo = "13", .hi = "13", .first = null, .count = 0 },
        .{ .lo = "13", .hi = "16", .first = "14", .count = 2 }, // neither bound is a key
        .{ .lo = "20", .hi = "10", .first = null, .count = 0 },
        .{ .lo = "29", .hi = null, .first = "29", .count = 2 },
        .{ .lo = "31", .hi = null, .first = null, .count = 0 },
    };
    for (cases) |case| {
        var it = try db.tree.range(case.lo, case.hi);
        var count: usize = 0;
        var previous: [2]u8 = .{ 0, 0 };
        while (try it.next()) |item| : (count += 1) {
            if (count == 0) try testing.expectEqualStrings(case.first.?, item.key);
            try testing.expect(std.mem.order(u8, &previous, item.key) == .lt);
            previous = item.key[0..2].*;
        }
        try testing.expectEqual(case.count, count);
        try testing.expectEqual(0, db.pool.pinnedFrames());
    }
}

/// Keys that a tree of byte strings must get right and that `keyFor` (1 to
/// n letters 'a' to 'f') never produces: the empty key, the bytes 0x00 and
/// 0xFF, and long chains in which every key is a prefix of the next.
/// The Rust twin issues the same puts in the same order.
fn putEdgeKeys(tree: *DiskBTree, model: *Model) !void {
    var key: [btree.max_key_len]u8 = undefined;
    var value: [500]u8 = undefined;
    const Run = struct { byte: u8, lens: []const usize };
    const runs = [_]Run{
        .{ .byte = 0x00, .lens = &.{ 0, 1, 2, 3, 4 } }, // length 0 is the empty key
        .{ .byte = 0xFF, .lens = &.{ 1, 2, 3, 4, btree.max_key_len } },
    };
    for (runs) |run| for (run.lens) |len| {
        @memset(key[0..len], run.byte);
        const v = edgeValue(key[0..len], &value);
        try tree.put(key[0..len], v);
        try model.put(key[0..len], v);
    };
    // "a", "aa", ... up to 256 bytes, longest first: every put is a prefix
    // of all the keys already there and must land in front of them.
    var len: usize = btree.max_key_len;
    while (len >= 1) : (len -= 1) {
        @memset(key[0..len], 'a');
        const v = edgeValue(key[0..len], &value);
        try tree.put(key[0..len], v);
        try model.put(key[0..len], v);
    }
    // 0x00 and 0xFF after a common prefix sort before and after every "aa...".
    for ([_][]const u8{ "a\x00", "a\xff", "a\x00\xff", "a\xff\x00" }) |k| {
        const v = edgeValue(k, &value);
        try tree.put(k, v);
        try model.put(k, v);
    }
}

/// A value that depends on the key, so that a get which finds the wrong
/// key cannot return the right bytes.
fn edgeValue(key: []const u8, buf: *[500]u8) []const u8 {
    const len = key.len * 37 % 500;
    const first: u8 = if (key.len == 0) 0xAA else key[0];
    @memset(buf[0..len], first ^ @as(u8, @truncate(key.len)));
    return buf[0..len];
}

fn expectEdgeKeys(tree: *DiskBTree, model: *const Model) !void {
    try expectSameContent(tree, model);
    for (model.entries.items) |entry| try expectValue(tree, entry.key, entry.value);
    try testing.expectEqual(5 + 5 + 256 + 4, model.len());

    // Order: the empty key is the smallest, a key sorts before everything it
    // is a prefix of, 0x00 sorts first and 0xFF last (bytes are unsigned).
    const all_ff: [btree.max_key_len]u8 = @splat(0xFF);
    var it = try tree.range("", null);
    const expected_head = [_][]const u8{ "", "\x00", "\x00\x00", "\x00\x00\x00", "\x00\x00\x00\x00", "a", "a\x00", "a\x00\xff", "aa", "aaa" };
    for (expected_head) |k| try testing.expectEqualSlices(u8, k, (try it.next()).?.key);
    var last: [btree.max_key_len]u8 = undefined;
    var last_len: usize = 0;
    while (try it.next()) |item| {
        last_len = item.key.len;
        @memcpy(last[0..last_len], item.key);
    }
    try testing.expectEqualSlices(u8, &all_ff, last[0..last_len]);

    // Bounds made of these bytes.
    const Case = struct { lo: []const u8, hi: ?[]const u8, count: usize };
    const cases = [_]Case{
        .{ .lo = "", .hi = "", .count = 0 },
        .{ .lo = "", .hi = "\x00", .count = 1 }, // the empty key alone
        .{ .lo = "\x00", .hi = "\x00\x00\x00", .count = 2 },
        .{ .lo = "\x00\x00\x00\x00\x00", .hi = "a", .count = 0 }, // five zero bytes: not a key
        .{ .lo = "a", .hi = "b", .count = 256 + 4 },
        .{ .lo = "a\xff", .hi = null, .count = 2 + 5 }, // a FF, a FF 00, and the five FF runs
        .{ .lo = "\xff", .hi = null, .count = 5 },
        .{ .lo = &all_ff, .hi = null, .count = 1 },
    };
    for (cases) |case| {
        try expectRange(tree, model, case.lo, case.hi);
        try testing.expectEqual(case.count, model.range(case.lo, case.hi).len);
    }
    // Neighbours that are not keys.
    try expectValue(tree, "\x00\x00\x00\x00\x00", null);
    try expectValue(tree, "a\x00\x00", null);
    try expectValue(tree, all_ff[0 .. btree.max_key_len - 1], null);
    try expectValue(tree, "b", null);
}

test "the empty key, 0x00 and 0xFF bytes, and keys that are prefixes of each other" {
    // 2 frames: every one of these puts works with the minimum of memory.
    for ([_]u32{ 2, 8 }) |frames| {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var model: Model = .init(testing.allocator);
        defer model.deinit();
        var db: Db = undefined;
        try db.start(mem.storage(), frames, .create);
        defer db.stop();

        try putEdgeKeys(&db.tree, &model);
        try expectEdgeKeys(&db.tree, &model);
        try testing.expect(try db.tree.height() >= 3); // long keys: interior pages split too
        try testing.expect(db.tree.stats.interior_splits > 0);

        // The same from the file alone.
        try db.reopen(mem.storage(), frames);
        try expectEdgeKeys(&db.tree, &model);

        // Overwriting the empty key and the longest key changes only them.
        const all_ff: [btree.max_key_len]u8 = @splat(0xFF);
        try db.tree.put("", "empty key, new value");
        try model.put("", "empty key, new value");
        try db.tree.put(&all_ff, "");
        try model.put(&all_ff, "");
        try expectEdgeKeys(&db.tree, &model);
    }
}

/// FNV-1a, 64 bits: small enough to write out twice, and any change of one
/// byte of the file changes it.
fn fnv1a64(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |b| hash = (hash ^ b) *% 0x100000001b3;
    return hash;
}

test "the file is the format: a fixed run of puts gives the same bytes in Zig and in Rust" {
    // The constants below are also in tests.rs. If a change to the tree, the
    // slotted page or the pool moves one byte of the file, this test fails
    // in the language that changed; change both or neither.
    try testing.expectEqual(0xaf63dc4c8601ec8c, fnv1a64("a"));

    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var model: Model = .init(testing.allocator);
    defer model.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 3, .create);
    defer db.stop();

    try putEdgeKeys(&db.tree, &model);
    try db.reopen(mem.storage(), 3);
    var rng = SplitMix64.init(12);
    var key_buf: [workload.max_key_len]u8 = undefined;
    var value_buf: [workload.max_value_len]u8 = undefined;
    for (0..400) |_| {
        const key = workload.keyFor(rng.below(250), 40, &key_buf);
        const value = workload.randomValue(&rng, 300, &value_buf);
        try db.tree.put(key, value);
        try model.put(key, value);
    }
    try db.tree.flush();
    try expectSameContent(&db.tree, &model);

    try testing.expectEqual(71, db.pager.pageCount());
    try testing.expectEqual(478, db.tree.key_count);
    try testing.expectEqual(71 * btree.page_size, mem.bytes.items.len);
    try testing.expectEqual(0x27e1691c52907390, fnv1a64(mem.bytes.items));
}

test "validate detects each kind of damage" {
    const Damage = enum { link, bounds, count, orphan, twice, zeroed, emptied, depth };
    const expected = [_]anyerror{
        error.LeafChainBroken,  error.KeyOutOfBounds, error.KeyCountMismatch, error.UnreachablePage,
        error.PageReachedTwice, error.BadPage,        error.EmptyPage,        error.UnevenDepth,
    };
    for (std.enums.values(Damage), expected) |damage, want| {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var db: Db = undefined;
        try buildScenario(&db, &mem);
        defer db.stop();
        // In the scenario tree page 1 is the root, page 2 the leftmost leaf
        // and page 7 the leaf after it (see expected_output.txt).
        const pool = &db.pool;
        switch (damage) {
            .link => {
                const leaf = SlottedPage.open(try pool.fetchPage(2));
                std.mem.writeInt(u32, leaf.userArea()[0..4], 3, .little); // skips page 7
                pool.unpin(2, true);
            },
            .bounds => {
                const leaf = SlottedPage.open(try pool.fetchPage(7));
                try leaf.put("99", "far too large for this leaf");
                pool.unpin(7, true);
            },
            .count => db.tree.key_count += 1,
            .orphan => pool.unpin((try pool.newPage()).id, false),
            .twice => {
                const root = SlottedPage.open(try pool.fetchPage(1));
                std.mem.writeInt(u32, root.userArea()[0..4], 2, .little); // rightmost child = first child
                pool.unpin(1, true);
            },
            .zeroed => {
                @memset(try pool.fetchPage(7), 0);
                pool.unpin(7, true);
            },
            .emptied => {
                const leaf = SlottedPage.open(try pool.fetchPage(7));
                while (leaf.count() > 0) leaf.deleteAt(0);
                pool.unpin(7, true);
            },
            .depth => {
                // Turn leaf 2 into an interior page over two new leaves that
                // hold its keys: every invariant holds except T4.
                const a = try pool.newPage();
                const b = try pool.newPage();
                const old = SlottedPage.open(try pool.fetchPage(2));
                a.page.* = old.buf.*;
                b.page.* = old.buf.*;
                const left = SlottedPage.open(a.page);
                const right = SlottedPage.open(b.page);
                while (left.count() > 3) left.deleteAt(3);
                for (0..3) |_| right.deleteAt(0);
                std.mem.writeInt(u32, left.userArea()[0..4], b.id, .little);
                var sep: [2]u8 = undefined;
                @memcpy(&sep, right.key(0));
                const parent = SlottedPage.initReserved(old.buf, btree.reserved_tail);
                parent.setKind(btree.kind_interior);
                std.mem.writeInt(u32, parent.userArea()[0..4], b.id, .little);
                var child: [4]u8 = undefined;
                std.mem.writeInt(u32, &child, a.id, .little);
                try parent.insertAt(0, &sep, &child);
                pool.unpin(2, true);
                pool.unpin(a.id, true);
                pool.unpin(b.id, true);
            },
        }
        try testing.expectError(want, db.tree.validate());
        try testing.expectEqual(0, pool.pinnedFrames());
    }
}

test "open and create check what they are given" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager: Pager = try .init(mem.storage());
    var pool: BufferPool = try .init(testing.allocator, &pager, 4);
    defer pool.deinit();

    try testing.expectError(error.BadMagic, DiskBTree.open(testing.allocator, &pool)); // empty storage
    {
        var tree: DiskBTree = try .create(testing.allocator, &pool);
        defer tree.deinit();
        try tree.put("k", "v");
        try tree.flush();
    }
    try testing.expectError(error.NotEmpty, DiskBTree.create(testing.allocator, &pool));

    // Damage the metapage in three ways; each time `open` must refuse.
    const Patch = struct { offset: usize, byte: u8, want: anyerror };
    for ([_]Patch{
        .{ .offset = 0, .byte = 'X', .want = error.BadMagic },
        .{ .offset = 8, .byte = 9, .want = error.UnsupportedVersion },
        .{ .offset = 16, .byte = 77, .want = error.Corrupt }, // root page id outside the file
        .{ .offset = 20, .byte = 99, .want = error.Corrupt }, // more pages than the file has
    }) |patch| {
        const meta = try pool.fetchPage(0);
        const saved = meta[patch.offset];
        meta[patch.offset] = patch.byte;
        try testing.expectError(patch.want, DiskBTree.open(testing.allocator, &pool));
        meta[patch.offset] = saved;
        pool.unpin(0, false);
    }
    var tree: DiskBTree = try .open(testing.allocator, &pool);
    defer tree.deinit();
    try expectValue(&tree, "k", "v");
    try testing.expectEqual(0, pool.pinnedFrames());
}

test "every tree page keeps its last four bytes free for a checksum" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try buildScenario(&db, &mem);
    defer db.stop();
    try db.tree.flush();
    const bytes = mem.bytes.items;
    try testing.expectEqual(8 * btree.page_size, bytes.len);
    for (0..8) |page| {
        const tail = bytes[(page + 1) * btree.page_size - btree.reserved_tail ..][0..btree.reserved_tail];
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, tail);
    }
    try testing.expectEqualStrings(btree.magic, bytes[0..8]);
}

test "a split interrupted between page writes leaves a broken file" {
    // The same experiment as part 4 of the demo, with the outcomes pinned.
    const before = try demo.crashDuringSplit(testing.allocator, 0);
    try testing.expect(!before.completed and before.validate_error == null);
    try testing.expectEqual(demo.crash_put, before.old_keys_readable);
    try testing.expect(!before.new_key_readable); // the old tree, untouched

    var broken: usize = 0;
    var lost_keys: usize = 0;
    var writes: u64 = 1;
    const after = while (true) : (writes += 1) {
        const o = try demo.crashDuringSplit(testing.allocator, writes);
        if (o.completed) break o;
        try testing.expectEqual(null, o.open_error);
        // Neither the tree before the put nor the tree after it:
        try testing.expect(o.validate_error != null);
        broken += 1;
        if (o.old_keys_readable < demo.crash_put) lost_keys += 1;
    };
    try testing.expectEqual(5, writes); // allocation + metapage + three tree pages
    try testing.expectEqual(4, broken);
    try testing.expectEqual(2, lost_keys); // keys that were safely on disk are gone
    try testing.expect(after.validate_error == null and after.new_key_readable);
    try testing.expectEqual(demo.crash_put, after.old_keys_readable);
}
