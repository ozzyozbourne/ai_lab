// Started as a copy of chapters/12-disk-backed-bplus-tree/zig/src/tests.zig.
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
const Role = btree.Role;
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
    defer it.deinit();
    for (model.range(lo, hi)) |expected| {
        const item = (try it.next()) orelse return error.TestExpectedMoreEntries;
        try testing.expectEqualSlices(u8, expected.key, item.key);
        try testing.expectEqualSlices(u8, expected.value, item.value);
        // Heap exactly when the value had an overflow chain.
        try testing.expectEqual(item.value.len > btree.max_local, it.valueOnHeap());
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

fn countRoles(tree: *DiskBTree) ![7]usize {
    const roles = try tree.pageMap(testing.allocator);
    defer testing.allocator.free(roles);
    var counts: [7]usize = @splat(0);
    for (roles) |role| counts[@intFromEnum(role)] += 1;
    return counts;
}

const Shape = struct {
    frames: u32,
    key_space: u64,
    max_key: usize,
    max_value: usize,
    /// Values from `mixedValue` (every size class) or from `randomValue`.
    mixed: bool = true,
    ops: usize = 0,
    reopen_every: usize = 1,
    /// Out of ten operations: this many puts, then this many deletes; the
    /// rest are two gets, a range scan and a flush, in that order.
    puts: u64 = 4,
    deletes: u64 = 2,
    /// Every `sweep_every` operations, delete `sweep_len` neighbouring keys:
    /// random deletes alone almost never empty a whole leaf.
    sweep_every: usize = 0,
    sweep_len: usize = 0,
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
        const value = if (shape.mixed) workload.mixedValue(rng, shape.max_value, &value_buf) else workload.randomValue(rng, shape.max_value, &value_buf);
        try tree.put(key, value);
        try model.put(key, value);
    } else if (pick < shape.puts + shape.deletes) {
        const expected = model.get(key) != null;
        try testing.expectEqual(expected, try tree.delete(key));
        _ = model.delete(key);
    } else switch (pick) {
        6, 7 => try expectValue(tree, key, model.get(key)),
        8 => {
            const hi = workload.keyFor(rng.below(shape.key_space), shape.max_key, &hi_buf);
            try expectRange(tree, model, key, if (rng.chance(1, 4)) null else hi);
        },
        else => try tree.flush(),
    }
}

/// Delete up to `count` keys that follow each other in key order, starting
/// at a random one.
fn sweep(tree: *DiskBTree, model: *Model, rng: *SplitMix64, count: usize) !void {
    if (model.len() == 0) return;
    const from: usize = @intCast(rng.below(model.len()));
    for (0..@min(count, model.len() - from)) |_| {
        // The model's arena keeps the key bytes alive after its delete.
        const key = model.entries.items[from].key;
        try testing.expect(try tree.delete(key));
        try testing.expect(model.delete(key));
    }
}

/// A reopen starts a new handle with new counters; keep a running sum.
fn addStats(total: *DiskBTree.Stats, s: DiskBTree.Stats) void {
    total.interior_splits += s.interior_splits;
    total.tree_pages_freed += s.tree_pages_freed;
    total.interior_pages_freed += s.interior_pages_freed;
    total.pages_freed += s.pages_freed;
    total.pages_reused += s.pages_reused;
    total.overflow_pages_written += s.overflow_pages_written;
}

fn runModel(storage: Storage, seed: u64, shape: Shape) !DiskBTree.Stats {
    var model: Model = .init(testing.allocator);
    defer model.deinit();
    var db: Db = undefined;
    try db.start(storage, shape.frames, .create);
    defer db.stop();
    var rng = SplitMix64.init(seed);
    var total: DiskBTree.Stats = .{};

    for (1..shape.ops + 1) |i| {
        try randomOp(&db.tree, &model, &rng, shape);
        try testing.expectEqual(0, db.pool.pinnedFrames());
        if (shape.sweep_every != 0 and i % shape.sweep_every == 0) try sweep(&db.tree, &model, &rng, shape.sweep_len);
        if (i % 250 == 0) try expectSameContent(&db.tree, &model);
        if (i % shape.reopen_every == 0) {
            addStats(&total, db.tree.stats);
            try db.reopen(storage, shape.frames);
        }
    }
    try expectSameContent(&db.tree, &model);
    try db.pool.validate();
    try testing.expectEqual(1, db.tree.root); // the root never moved
    try db.tree.flush(); // the caller may look at the storage afterwards
    addStats(&total, db.tree.stats);
    return total;
}

test "model: memory storage, tiny pools, values of every size, deletes, reopen mid-run" {
    const shapes = [_]Shape{
        // 3 frames: nearly every page access evicts, also in the middle of a chain.
        .{ .frames = 3, .key_space = 300, .max_key = 24, .max_value = 20000, .ops = 3000, .reopen_every = 1100 },
        // 2 frames is the minimum: a split, and a chain being written, pin two pages.
        .{ .frames = 2, .key_space = 200, .max_key = 40, .max_value = 9000, .ops = 2500, .reopen_every = 900 },
        // The largest values allowed (16 overflow pages) and the longest keys.
        .{ .frames = 4, .key_space = 60, .max_key = btree.max_key_len, .max_value = btree.max_value_len, .ops = 700, .reopen_every = 300 },
        // Long keys, tiny values, three levels: interior pages split, and
        // the sweeps empty whole leaves and the interior pages above them.
        .{ .frames = 16, .key_space = 6000, .max_key = btree.max_key_len, .max_value = 8, .mixed = false, .ops = 9000, .reopen_every = 4000, .puts = 5, .deletes = 1, .sweep_every = 2900, .sweep_len = 1500 },
    };
    for (shapes, 1..) |shape, seed| {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        const stats = try runModel(mem.storage(), seed, shape);
        try testing.expect(stats.pages_freed > 0 and stats.pages_reused > 0);
        if (shape.mixed) try testing.expect(stats.overflow_pages_written > 100);
        if (!shape.mixed) try testing.expect(stats.tree_pages_freed > 20 and stats.interior_pages_freed > 0 and stats.interior_splits > 0);
    }
}

test "model: a real file, closed and opened again" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const shape: Shape = .{ .frames = 5, .key_space = 300, .max_key = 48, .max_value = 12000, .ops = 2500, .reopen_every = 700 };
    {
        var file: FileStorage = try .create(io, tmp.dir, "tree.db");
        defer file.close();
        _ = try runModel(file.storage(), 42, shape);
    }
    // Replay the same operations into a model and compare with the file as
    // it was left by the run above: nothing but the file carries the data.
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

test "the file stops growing under a steady insert/delete load" {
    // Part 3 of the demo: its page counts are pinned in expected_output.txt.
    var pages: [12]u32 = undefined;
    var stats: DiskBTree.Stats = undefined;
    try demo.steadyState(testing.allocator, pages.len, &pages, &stats);
    try testing.expectEqual(pages[6], pages[11]); // no growth in the second half
    try testing.expect(stats.pages_reused > 10 * @as(u64, pages[11]));

    // The general statement: the file only grows when the free list is
    // empty, so it is never larger than the most pages ever in use at once
    // (measured between operations) plus what one operation holds briefly:
    // the new chain of an overwrite, allocated before the old one is freed.
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var model: Model = .init(testing.allocator);
    defer model.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 6, .create);
    defer db.stop();
    var rng = SplitMix64.init(99);
    const shape: Shape = .{ .frames = 6, .key_space = 150, .max_key = 16, .max_value = 16000, .puts = 5, .deletes = 5 };
    var most_in_use: u32 = 0;
    for (0..6000) |_| {
        try randomOp(&db.tree, &model, &rng, shape);
        most_in_use = @max(most_in_use, db.pager.pageCount() - db.tree.free_count);
    }
    try expectSameContent(&db.tree, &model);
    const slack: u32 = @intCast(btree.overflowPages(shape.max_value) + 2);
    try testing.expect(db.pager.pageCount() <= most_in_use + slack);
    try testing.expect(db.tree.stats.pages_reused > 5 * @as(u64, db.pager.pageCount()));
}

test "delete everything: an empty root leaf, every other page free, and nothing grows when it all comes back" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 8, .create);
    defer db.stop();

    // Keys of 200 bytes: three levels, as in chapter 12.
    var key: [200]u8 = @splat('k');
    const n = 2000;
    for (0..2) |round| {
        for (0..n) |i| {
            _ = try std.fmt.bufPrint(key[0..6], "{d:0>6}", .{i * 7919 % n});
            try db.tree.put(&key, "v");
        }
        try db.tree.validate();
        try testing.expectEqual(3, try db.tree.height());
        const pages = db.pager.pageCount();
        // Second round: every page came from the free list.
        try testing.expectEqual(if (round == 0) pages else 0, db.pager.stats.allocations);

        // Delete in another order than the keys were inserted.
        for (0..n) |i| {
            _ = try std.fmt.bufPrint(key[0..6], "{d:0>6}", .{i * 6007 % n});
            try testing.expect(try db.tree.delete(&key));
            if (i % 97 == 0) try db.tree.validate();
        }
        try testing.expect(!try db.tree.delete(&key));
        try db.tree.validate();
        try testing.expectEqual(0, db.tree.key_count);
        try testing.expectEqual(1, try db.tree.height());
        try testing.expectEqual(1, db.tree.root);
        try testing.expectEqual(pages, db.pager.pageCount());
        try testing.expectEqual(pages - 2, db.tree.free_count); // all but the metapage and the root
        const counts = try countRoles(&db.tree);
        try testing.expectEqual(1, counts[@intFromEnum(Role.leaf)]);
        try testing.expectEqual(0, counts[@intFromEnum(Role.interior)]);
        try testing.expectEqual(2, db.tree.stats.root_collapses);
        try testing.expect(db.tree.stats.interior_pages_freed > 10);
        try db.reopen(mem.storage(), 8);
    }
}

test "more free pages than one trunk lists: a second trunk, and both are used up again" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 4, .create);
    defer db.stop();
    const value = try testing.allocator.alloc(u8, btree.max_value_len);
    defer testing.allocator.free(value);
    for (value, 0..) |*b, i| b.* = @truncate(i *% 31);

    // 80 values of 16 overflow pages each: 1280 pages to free.
    try testing.expectEqual(16, btree.overflowPages(btree.max_value_len));
    var key: [3]u8 = undefined;
    for (0..80) |i| try db.tree.put(try std.fmt.bufPrint(&key, "{d:0>3}", .{i}), value);
    const pages = db.pager.pageCount();
    for (0..80) |i| try testing.expect(try db.tree.delete(try std.fmt.bufPrint(&key, "{d:0>3}", .{i})));
    try db.tree.validate();
    try testing.expect(db.tree.free_count > btree.trunk_capacity + 1);
    var counts = try countRoles(&db.tree);
    try testing.expectEqual(2, counts[@intFromEnum(Role.trunk)]);
    try testing.expectEqual(db.tree.free_count - 2, counts[@intFromEnum(Role.free)]);

    try db.reopen(mem.storage(), 4);
    for (0..80) |i| try db.tree.put(try std.fmt.bufPrint(&key, "{d:0>3}", .{i}), value);
    try db.tree.validate();
    try testing.expectEqual(pages, db.pager.pageCount());
    try testing.expectEqual(0, db.tree.free_count);
    counts = try countRoles(&db.tree);
    try testing.expectEqual(0, counts[@intFromEnum(Role.trunk)]);
    try expectValue(&db.tree, "079", value);
}

test "localLen: SQLite's rule, with this chapter's numbers" {
    try testing.expectEqual(1088, btree.max_local);
    try testing.expectEqual(544, btree.min_local);
    const cases = [_][3]usize{
        // value bytes, bytes in the leaf, overflow pages
        .{ 0, 0, 0 },           .{ 1088, 1088, 0 },      .{ 1089, 544, 1 },
        .{ 3000, 544, 1 },      .{ 4628, 544, 1 },       .{ 4629, 545, 1 },
        .{ 5000, 916, 1 },      .{ 5172, 1088, 1 },      .{ 5173, 544, 2 },
        .{ 9000, 832, 2 },      .{ 14000, 544, 4 },      .{ 65536, 544, 16 },
    };
    for (cases) |case| {
        try testing.expectEqual(case[1], btree.localLen(case[0]));
        try testing.expectEqual(case[2], btree.overflowPages(case[0]));
    }
    var full_chains: usize = 0;
    for (btree.max_local + 1..btree.max_value_len + 1) |total| {
        const local = btree.localLen(total);
        const pages = btree.overflowPages(total);
        try testing.expect(local >= btree.min_local and local <= btree.max_local);
        // The chain is exactly as long as the tail needs.
        const tail = total - local;
        try testing.expect(tail > (pages - 1) * btree.overflow_payload and tail <= pages * btree.overflow_payload);
        // More than the minimum stays local only to make every page full.
        if (local > btree.min_local) try testing.expectEqual(pages * btree.overflow_payload, tail);
        if (tail == pages * btree.overflow_payload) full_chains += 1;
    }
    // 545 remainders out of every 4084 end in a full last page.
    try testing.expect(full_chains * 8 > btree.max_value_len - btree.max_local);
}

test "overwrites that change the size class free the old chain and keep the tree valid" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 3, .create);
    defer db.stop();
    const value = try testing.allocator.alloc(u8, 30000);
    defer testing.allocator.free(value);
    for (value, 0..) |*b, i| b.* = @truncate(i *% 7);

    try db.tree.put("a", "x");
    try db.tree.put("z", "y");
    const sizes = [_]usize{ 10, 5000, 1088, 1089, 30000, 0, 9000, 9000, 9001, 544, 20000, 3 };
    var chain_pages: usize = 0;
    for (sizes) |size| {
        try db.tree.put("k", value[0..size]);
        try db.tree.validate();
        try expectValue(&db.tree, "k", value[0..size]);
        chain_pages += btree.overflowPages(size);
        // Exactly the pages of the current value are in use.
        const counts = try countRoles(&db.tree);
        try testing.expectEqual(btree.overflowPages(size), counts[@intFromEnum(Role.overflow)]);
        try testing.expectEqual(db.pager.pageCount() - 2 - btree.overflowPages(size), db.tree.free_count);
    }
    try testing.expectEqual(chain_pages, db.tree.stats.overflow_pages_written);
    try testing.expectEqual(chain_pages - btree.overflowPages(3), db.tree.stats.pages_freed);
    try testing.expectEqual(3, db.tree.key_count);
    // The file is as large as the largest moment needed: the 30000-byte
    // chain (8 pages) was written while the 1089-byte one (1 page) was live.
    try testing.expectEqual(2 + 8 + 1, db.pager.pageCount());
    try expectValue(&db.tree, "a", "x");
    try expectValue(&db.tree, "z", "y");
}

test "values are assembled where the caller says: stack buffer first, heap if larger" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 4, .create);
    defer db.stop();
    const big: [7000]u8 = @splat('b');
    try db.tree.put("big", &big);
    try db.tree.put("small", big[0..btree.max_local]);

    var stack_buf: [btree.max_local]u8 = undefined;
    var chain: std.heap.BufferFirstAllocator = .init(&stack_buf, testing.allocator);
    const allocator = chain.allocator();
    {
        const value = (try db.tree.get(allocator, "small")).?;
        defer allocator.free(value);
        try testing.expect(chain.fixed_buffer_allocator.ownsPtr(value.ptr));
        try testing.expectEqualSlices(u8, big[0..btree.max_local], value);
    }
    {
        // Freed above, so the buffer is whole again; 7000 bytes do not fit.
        const value = (try db.tree.get(allocator, "big")).?;
        defer allocator.free(value);
        try testing.expect(!chain.fixed_buffer_allocator.ownsPtr(value.ptr));
        try testing.expectEqualSlices(u8, &big, value);
    }

    // A caller without memory gets OutOfMemory and the tree keeps no pin.
    var none: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&none);
    try testing.expectError(error.OutOfMemory, db.tree.get(fixed.allocator(), "big"));
    try testing.expectEqual(0, db.pool.pinnedFrames());
    // 7000 bytes of fixed buffer: the same value without any heap.
    var some: [7000]u8 = undefined;
    fixed = .init(&some);
    const whole = (try db.tree.get(fixed.allocator(), "big")).?;
    try testing.expectEqual(7000, whole.len);

    // The iterator: an abandoned scan frees its heap value in `deinit`.
    var it = try db.tree.range("", null);
    defer it.deinit();
    try testing.expectEqualStrings("big", (try it.next()).?.key);
    try testing.expect(it.valueOnHeap());
    try testing.expect(@sizeOf(DiskBTree.RangeIterator) < 1500);
}

test "allocation failure in the range iterator: OutOfMemory, no leaked pin, the scan can go on" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var pager: Pager = try .init(mem.storage());
    var pool: BufferPool = try .init(testing.allocator, &pager, 3);
    defer pool.deinit();
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var tree: DiskBTree = try .create(failing.allocator(), &pool);
    defer tree.deinit();
    const big: [9000]u8 = @splat('b');
    try tree.put("a", "small");
    try tree.put("b", &big);
    try tree.put("c", "small");

    var it = try tree.range("", null);
    defer it.deinit();
    try testing.expectEqualStrings("a", (try it.next()).?.key); // inline: no allocation
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, it.next());
    try testing.expectEqual(0, pool.pinnedFrames());
    failing.fail_index = std.math.maxInt(usize); // memory is back
    const item = (try it.next()).?; // the same entry again
    try testing.expectEqualStrings("b", item.key);
    try testing.expectEqualSlices(u8, &big, item.value);
    try testing.expectEqualStrings("c", (try it.next()).?.key);
    try testing.expectEqual(null, try it.next());
}

test "injected I/O failures: an error, no leaked pin, and a tree that is intact or poisoned" {
    const shapes = [2]Shape{
        .{ .frames = 3, .key_space = 200, .max_key = 32, .max_value = 9000 },
        // Small cells with long keys, many deletes: splits and freed leaves.
        .{ .frames = 3, .key_space = 400, .max_key = 200, .max_value = 600, .mixed = false, .puts = 5, .deletes = 4 },
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
                        // The failure hit after the operation's first page change.
                        poisoned_failures += 1;
                        try testing.expectError(error.TreePoisoned, db.tree.put("k", "v"));
                        try testing.expectError(error.TreePoisoned, db.tree.delete("k"));
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
    try testing.expect(poisoned_failures > 20);
}

test "a failure after the first page change poisons the handle; before it, nothing happened" {
    const big: [9000]u8 = @splat('v'); // two overflow pages
    // writes allowed -> poisoned? Growing the file writes a (zero) page, so
    // the first chain page is write 0 and the second is write 1.
    for ([_]struct { writes: u64, poisoned: bool }{ .{ .writes = 0, .poisoned = false }, .{ .writes = 1, .poisoned = true } }) |case| {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var db: Db = undefined;
        try db.start(mem.storage(), 8, .create);
        defer db.stop();
        try db.tree.put("a", "1");
        mem.writes_before_failure = case.writes;
        try testing.expectError(error.StorageFailure, db.tree.put("b", &big));
        mem.writes_before_failure = null;
        try testing.expectEqual(case.poisoned, db.tree.poisoned);
        try testing.expectEqual(0, db.pool.pinnedFrames());
        if (case.poisoned) {
            try testing.expectError(error.TreePoisoned, db.tree.put("b", &big));
            try testing.expectError(error.TreePoisoned, db.tree.delete("a"));
            // The half-written chain is one page that nothing points to.
            try testing.expectError(error.UnreachablePage, db.tree.validate());
        } else {
            try db.tree.validate();
            try db.tree.put("b", &big);
            try db.tree.validate();
            try testing.expectEqual(2, db.tree.key_count);
        }
    }
}

test "allocation failure in put and delete: OutOfMemory, no leaked pin, intact or poisoned" {
    const shape: Shape = .{ .frames = 4, .key_space = 600, .max_key = btree.max_key_len, .max_value = 30, .mixed = false, .puts = 5, .deletes = 3 };
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

test "full is a number of bytes, not a number of keys" {
    // Cells of 1014 bytes (4 of them are the value's length): four fit in
    // 4076 bytes, the fifth splits. Cells of 22 bytes: 185 fit.
    const cases = [_]struct { value_len: usize, fit: usize }{ .{ .value_len = 1000, .fit = 4 }, .{ .value_len = 8, .fit = 185 } };
    for (cases) |case| {
        const cost = btree.cellCost(4, 4 + case.value_len);
        try testing.expect(case.fit * cost <= btree.page_capacity);
        try testing.expect((case.fit + 1) * cost > btree.page_capacity);
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

test "limits: the largest key with the largest local part still packs three to a page" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 4, .create);
    defer db.stop();
    const big = try testing.allocator.alloc(u8, btree.max_value_len + 1);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try testing.expectError(error.KeyTooLarge, db.tree.put(big[0 .. btree.max_key_len + 1], "v"));
    try testing.expectError(error.ValueTooLarge, db.tree.put("k", big));
    try testing.expect(!try db.tree.delete(big[0 .. btree.max_key_len + 1]));
    try testing.expectEqual(0, db.tree.key_count);

    // 5172 bytes keep X = 1088 in the leaf: the costliest cell there is.
    try testing.expectEqual(btree.max_local, btree.localLen(5172));
    var key: [btree.max_key_len]u8 = @splat('k');
    for (0..120) |i| {
        _ = try std.fmt.bufPrint(key[0..3], "{d:0>3}", .{i * 37 % 120});
        try db.tree.put(&key, big[0..5172]);
    }
    try db.tree.validate();
    try testing.expectEqual(120, db.tree.key_count);
    // The empty key and the empty value are legal, and so is the largest value.
    try db.tree.put("", "");
    try expectValue(&db.tree, "", "");
    try db.tree.put(&key, big[0..btree.max_value_len]);
    try expectValue(&db.tree, &key, big[0..btree.max_value_len]);
    try db.tree.put(&key, "small");
    try expectValue(&db.tree, &key, "small");
    try db.tree.validate();
    try testing.expectEqual(121, db.tree.key_count);
}

/// The tree of the demo's part 1 after its first `steps` steps.
/// After 8 steps (see expected_output.txt): page 1 is the root, pages 4 and
/// 5 are the leaves, page 6 is the chain of key 60, page 2 is a trunk that
/// lists page 3. Page map: M I T F L L O.
fn buildScenario(db: *Db, mem: *MemStorage, steps: usize) !void {
    try db.start(mem.storage(), 8, .create);
    for (demo.scenario[0..steps]) |step| try demo.applyStep(&db.tree, testing.allocator, step);
    try db.tree.validate();
}

test "range: bounds are half-open, leaves are followed through their links" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try buildScenario(&db, &mem, 9);
    defer db.stop();

    const Case = struct { lo: []const u8, hi: ?[]const u8, first: ?[]const u8, count: usize };
    const cases = [_]Case{
        .{ .lo = "", .hi = null, .first = "10", .count = 8 },
        .{ .lo = "20", .hi = "40", .first = "20", .count = 4 }, // 40 itself is excluded
        .{ .lo = "33", .hi = "33", .first = null, .count = 0 },
        .{ .lo = "26", .hi = "36", .first = "30", .count = 2 }, // neither bound is a key
        .{ .lo = "40", .hi = "20", .first = null, .count = 0 },
        .{ .lo = "50", .hi = null, .first = "50", .count = 2 },
        .{ .lo = "61", .hi = null, .first = null, .count = 0 },
    };
    for (cases) |case| {
        var it = try db.tree.range(case.lo, case.hi);
        defer it.deinit();
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

test "the scenario's page map, step by step" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try buildScenario(&db, &mem, 0);
    defer db.stop();
    const maps = [_][]const u8{ "ML", "ML", "ML", "ML", "ML", "MIOOLL", "MIOOLLO", "MITFLLO", "MITOLLO", "MITOLLF", "MITFLLF", "MITFLLF", "MITFLLF", "MLTFFFF", "MLTOOOO", "MLOOOOO" };
    for (demo.scenario, maps) |step, want| {
        try demo.applyStep(&db.tree, testing.allocator, step);
        const roles = try db.tree.pageMap(testing.allocator);
        defer testing.allocator.free(roles);
        var letters: [16]u8 = undefined;
        for (roles, 0..) |role, i| letters[i] = role.letter();
        try testing.expectEqualStrings(want, letters[0..roles.len]);
    }
}

fn putU32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .little);
}

test "validate detects each kind of damage" {
    const Damage = enum {
        link, bounds, count, orphan, twice, zeroed, emptied, depth, // chapter 12's
        cell, chain_long, chain_short, chain_kind, chain_shared, free_and_used, free_count, trunk_kind, trunk_loop, leaked,
    };
    const expected = [_]anyerror{
        error.LeafChainBroken,     error.KeyOutOfBounds,      error.KeyCountMismatch,    error.UnreachablePage,
        error.PageReachedTwice,    error.BadPage,             error.EmptyPage,           error.UnevenDepth,
        error.BadCell,             error.OverflowChainBroken, error.OverflowChainBroken, error.OverflowChainBroken,
        error.PageReachedTwice,    error.PageInTwoRoles,      error.FreeListBroken,      error.FreeListBroken,
        error.PageReachedTwice,    error.UnreachablePage,
    };
    // A value field for a 3000-byte value whose chain starts at page 6.
    var field_3000: [4 + 544 + 4]u8 = @splat('x');
    putU32(field_3000[0..4], 3000);
    putU32(field_3000[548..552], 6);

    for (std.enums.values(Damage), expected) |damage, want| {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var db: Db = undefined;
        try buildScenario(&db, &mem, 8);
        defer db.stop();
        const pool = &db.pool;
        switch (damage) {
            .link => {
                const leaf = SlottedPage.open(try pool.fetchPage(4));
                putU32(leaf.userArea()[0..4], btree.invalid_page_id); // skips page 5
                pool.unpin(4, true);
            },
            .bounds => {
                const leaf = SlottedPage.open(try pool.fetchPage(4));
                try leaf.put("99", "\x01\x00\x00\x00v"); // far too large for this leaf
                pool.unpin(4, true);
            },
            .count => db.tree.key_count += 1,
            .orphan => pool.unpin((try pool.newPage()).id, false),
            .twice => {
                const root = SlottedPage.open(try pool.fetchPage(1));
                putU32(root.userArea()[0..4], 4); // rightmost child = first child
                pool.unpin(1, true);
            },
            .zeroed => {
                @memset(try pool.fetchPage(5), 0);
                pool.unpin(5, true);
            },
            .emptied => {
                const leaf = SlottedPage.open(try pool.fetchPage(4));
                while (leaf.count() > 0) leaf.deleteAt(0);
                pool.unpin(4, true);
                db.tree.key_count -= 3;
            },
            .depth => {
                // Turn leaf 4 into an interior page over two new leaves that
                // hold its keys: every invariant holds except T4.
                const a = try pool.newPage();
                const b = try pool.newPage();
                const old = SlottedPage.open(try pool.fetchPage(4));
                a.page.* = old.buf.*;
                b.page.* = old.buf.*;
                const left = SlottedPage.open(a.page);
                const right = SlottedPage.open(b.page);
                left.deleteAt(2);
                for (0..2) |_| right.deleteAt(0);
                putU32(left.userArea()[0..4], b.id);
                var sep: [2]u8 = undefined;
                @memcpy(&sep, right.key(0));
                const parent = SlottedPage.initReserved(old.buf, btree.reserved_tail);
                parent.setKind(btree.kind_interior);
                putU32(parent.userArea()[0..4], b.id);
                var child: [4]u8 = undefined;
                putU32(&child, a.id);
                try parent.insertAt(0, &sep, &child);
                pool.unpin(4, true);
                pool.unpin(a.id, true);
                pool.unpin(b.id, true);
            },
            .cell => {
                // A length of 5 in front of 3 bytes.
                const leaf = SlottedPage.open(try pool.fetchPage(4));
                try leaf.put("25", "\x05\x00\x00\x00abc");
                pool.unpin(4, true);
            },
            .chain_long => {
                // The 3000-byte value's single page points on, at page 3.
                putU32((try pool.fetchPage(6))[0..4], 3);
                pool.unpin(6, true);
            },
            .chain_short => {
                // A cell that claims 9000 bytes over a chain of one page.
                var field: [4 + 832 + 4]u8 = @splat('x');
                putU32(field[0..4], 9000);
                putU32(field[836..840], 6);
                const leaf = SlottedPage.open(try pool.fetchPage(5));
                try leaf.put("60", &field);
                pool.unpin(5, true);
            },
            .chain_kind => {
                (try pool.fetchPage(6))[7] = btree.kind_trunk;
                pool.unpin(6, true);
            },
            .chain_shared => {
                // A second cell points at the chain of key 60.
                const leaf = SlottedPage.open(try pool.fetchPage(4));
                try leaf.put("25", &field_3000);
                pool.unpin(4, true);
            },
            .free_and_used => {
                // The trunk lists leaf 4 as free.
                const trunk = try pool.fetchPage(2);
                putU32(trunk[12..16], 4);
                trunk[4] = 2;
                pool.unpin(2, true);
                db.tree.free_count += 1;
            },
            .free_count => db.tree.free_count += 1,
            .trunk_kind => {
                (try pool.fetchPage(2))[7] = btree.kind_overflow;
                pool.unpin(2, true);
            },
            .trunk_loop => {
                putU32((try pool.fetchPage(2))[0..4], 2);
                pool.unpin(2, true);
            },
            .leaked => {
                // Page 3 drops off the list: free, but nobody knows.
                (try pool.fetchPage(2))[4] = 0;
                pool.unpin(2, true);
                db.tree.free_count -= 1;
            },
        }
        try testing.expectError(want, db.tree.validate());
        try testing.expectEqual(0, pool.pinnedFrames());
    }
}

test "operations report a damaged chain or free list as Corrupt, without leaking a pin" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try buildScenario(&db, &mem, 8);
    defer db.stop();
    const pool = &db.pool;

    // The chain of key 60 runs into a page that is not an overflow page.
    (try pool.fetchPage(6))[7] = 0;
    pool.unpin(6, true);
    try testing.expectError(error.Corrupt, db.tree.get(testing.allocator, "60"));
    var it = try db.tree.range("60", null);
    defer it.deinit();
    try testing.expectError(error.Corrupt, it.next());
    try testing.expectError(error.Corrupt, db.tree.delete("60"));
    try testing.expect(db.tree.poisoned); // the cell was already gone

    var mem2: MemStorage = .init(testing.allocator);
    defer mem2.deinit();
    var db2: Db = undefined;
    try buildScenario(&db2, &mem2, 8);
    defer db2.stop();
    // The free-list head is not a trunk: nothing can be allocated or freed.
    (try db2.pool.fetchPage(2))[7] = 0;
    db2.pool.unpin(2, true);
    const big: [5000]u8 = @splat('v');
    try testing.expectError(error.Corrupt, db2.tree.put("70", &big));
    try testing.expect(!db2.tree.poisoned); // nothing had changed yet
    try testing.expectEqual(0, db2.pool.pinnedFrames());
    try testing.expectEqual(0, pool.pinnedFrames());
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
        const big: [5000]u8 = @splat('v');
        try tree.put("k", &big);
        try tree.put("k", "v"); // page 2 becomes a trunk
        try tree.flush();
        try testing.expectEqual(2, tree.free_head);
    }
    try testing.expectError(error.NotEmpty, DiskBTree.create(testing.allocator, &pool));

    // Damage the metapage; each time `open` must refuse.
    const Patch = struct { offset: usize, byte: u8, want: anyerror };
    for ([_]Patch{
        .{ .offset = 0, .byte = 'X', .want = error.BadMagic },
        .{ .offset = 8, .byte = 1, .want = error.UnsupportedVersion }, // chapter 12's format
        .{ .offset = 16, .byte = 77, .want = error.Corrupt }, // root page id outside the file
        .{ .offset = 20, .byte = 99, .want = error.Corrupt }, // more pages than the file has
        .{ .offset = 32, .byte = 0, .want = error.Corrupt }, // the metapage as the free-list head
        .{ .offset = 32, .byte = 50, .want = error.Corrupt }, // a head outside the file
        .{ .offset = 36, .byte = 0, .want = error.Corrupt }, // a head but no free pages
        .{ .offset = 36, .byte = 200, .want = error.Corrupt }, // more free pages than pages
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
    try testing.expectEqual(1, tree.free_count);
    try testing.expectEqual(0, pool.pinnedFrames());
}

test "every page of every role keeps its last four bytes free for a checksum" {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try buildScenario(&db, &mem, 13); // M I T F L L F: every role at once
    defer db.stop();
    try db.tree.flush();
    const bytes = mem.bytes.items;
    try testing.expectEqual(7 * btree.page_size, bytes.len);
    for (0..7) |page| {
        const tail = bytes[(page + 1) * btree.page_size - btree.reserved_tail ..][0..btree.reserved_tail];
        try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, tail);
    }
    try testing.expectEqualStrings(btree.magic, bytes[0..8]);
    // A full overflow page: the 3000-byte value was freed from page 6, the
    // 5000-byte one from page 3, whose 4084 payload bytes end at 4092.
    try testing.expectEqual(btree.kind_overflow, bytes[3 * btree.page_size + 7]);
    try testing.expectEqual('j', bytes[3 * btree.page_size + 4091]);
}

test "a crash between freeing a page and reusing it leaves a file that validates and lies" {
    // The same experiment as part 5 of the demo, with the outcomes pinned.
    const before = try demo.crashDuringReuse(testing.allocator, 0);
    try testing.expect(!before.completed and before.validate_error == null);
    try testing.expectEqual(.intact, before.old.state);
    try testing.expectEqual(.missing, before.new.state);

    var lies: usize = 0;
    var writes: u64 = 1;
    const after = while (true) : (writes += 1) {
        const o = try demo.crashDuringReuse(testing.allocator, writes);
        if (o.completed) break o;
        try testing.expectEqual(null, o.validate_error); // nothing looks wrong
        if (o.new.state == .wrong_bytes) {
            // The new cell is on disk, its overflow page is not: the page
            // still holds the tail of the value that owned it before.
            try testing.expectEqual('n', o.new.first);
            try testing.expectEqual('o', o.new.last);
            lies += 1;
        }
    };
    try testing.expectEqual(3, writes); // metapage, leaf, overflow page
    try testing.expectEqual(1, lies);
    try testing.expect(after.validate_error == null);
    try testing.expectEqual(.intact, after.new.state);
    try testing.expectEqual(.missing, after.old.state);
}

test "Zig and Rust write the same bytes" {
    // The Rust twin has this test with the same two numbers: FNV-1a hashes
    // of the file after part 1's sixteen steps and after a seeded workload.
    {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var db: Db = undefined;
        try buildScenario(&db, &mem, 16);
        defer db.stop();
        try db.tree.flush();
        try testing.expectEqual(@as(u64, 4600392725701261712), std.hash.Fnv1a_64.hash(mem.bytes.items));
    }
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var model: Model = .init(testing.allocator);
    defer model.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 4, .create);
    defer db.stop();
    var rng = SplitMix64.init(77);
    const shape: Shape = .{ .frames = 4, .key_space = 300, .max_key = 24, .max_value = 12000 };
    for (0..2000) |_| try randomOp(&db.tree, &model, &rng, shape);
    try db.tree.flush();
    try testing.expectEqual(@as(u64, 10315806560220619977), std.hash.Fnv1a_64.hash(mem.bytes.items));
}
