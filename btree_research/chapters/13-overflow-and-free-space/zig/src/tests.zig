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
    for (roles) |role| counts[@backingInt(role)] += 1;
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
        try testing.expectEqual(1, counts[@backingInt(Role.leaf)]);
        try testing.expectEqual(0, counts[@backingInt(Role.interior)]);
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
    try testing.expectEqual(2, counts[@backingInt(Role.trunk)]);
    try testing.expectEqual(db.tree.free_count - 2, counts[@backingInt(Role.free)]);

    try db.reopen(mem.storage(), 4);
    for (0..80) |i| try db.tree.put(try std.fmt.bufPrint(&key, "{d:0>3}", .{i}), value);
    try db.tree.validate();
    try testing.expectEqual(pages, db.pager.pageCount());
    try testing.expectEqual(0, db.tree.free_count);
    counts = try countRoles(&db.tree);
    try testing.expectEqual(0, counts[@backingInt(Role.trunk)]);
    try expectValue(&db.tree, "079", value);
}

test "localLen: SQLite's rule, with this chapter's numbers" {
    try testing.expectEqual(1088, btree.max_local);
    try testing.expectEqual(544, btree.min_local);
    const cases = [_][3]usize{
        // value bytes, bytes in the leaf, overflow pages
        .{ 0, 0, 0 },      .{ 1088, 1088, 0 }, .{ 1089, 544, 1 },
        .{ 3000, 544, 1 }, .{ 4628, 544, 1 },  .{ 4629, 545, 1 },
        .{ 5000, 916, 1 }, .{ 5172, 1088, 1 }, .{ 5173, 544, 2 },
        .{ 9000, 832, 2 }, .{ 14000, 544, 4 }, .{ 65536, 544, 16 },
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
        try testing.expectEqual(btree.overflowPages(size), counts[@backingInt(Role.overflow)]);
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

/// One operation whose every scratch request is refused in turn.
const OomCase = struct {
    /// The flushed file just before the operation.
    file: []const u8,
    op: enum { put, delete },
    key: []const u8,
    value: []const u8 = "",
    /// Scratch requests of the operation, in order.
    requests: usize,
    /// The first request that comes after a page change. A failure from
    /// there on leaves a half-done change; an earlier one leaves the tree
    /// intact. Equal to `requests` if no request comes after a change.
    first_poisoned: usize,
    /// What the operation does when nothing is refused.
    leaf_splits: u64 = 0,
    interior_splits: u64 = 0,
    root_splits: u64 = 0,
    pages_reused: u64 = 0,
    tree_pages_freed: u64 = 0,
    interior_pages_freed: u64 = 0,
    root_collapses: u64 = 0,
};

/// Run the operation of `case` on a copy of its file once per scratch
/// request, refusing request 0, 1, 2, ..., and once more refusing nothing.
/// Returns the number of failure points reached.
///
/// An arena hides most requests from the allocator behind it: it asks for
/// memory only when its buffer is too small, so a failing allocator behind a
/// warm arena is never asked. Here every request is made visible:
///
///   - each run opens a new handle, so the arena starts without a buffer;
///   - the test fills the arena's first buffer to the last byte, so the next
///     request cannot be served from it;
///   - the buffer comes from a FixedBufferAllocator, which can grow its last
///     allocation in place. The arena then grows its buffer by exactly the
///     bytes of each request: one `resize` call per request.
///
/// `resize_fail_index = i` refuses request number i, and `fail_index = 2`
/// refuses the new buffer the arena asks for after that.
fn failEveryRequest(case: OomCase) !usize {
    var reached: usize = 0;
    for (0..case.requests + 1) |fail_at| {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        try mem.bytes.appendSlice(testing.allocator, case.file);
        var pager: Pager = try .init(mem.storage());
        var pool: BufferPool = try .init(testing.allocator, &pager, 4);
        defer pool.deinit(); // asserts that no pin is left

        const scratch_bytes = try testing.allocator.alignedAlloc(u8, .@"16", 256 * 1024);
        defer testing.allocator.free(scratch_bytes);
        var fixed: std.heap.FixedBufferAllocator = .init(scratch_bytes);
        var failing: testing.FailingAllocator = .init(fixed.allocator(), .{});
        var tree: DiskBTree = try .open(failing.allocator(), &pool);
        defer tree.deinit();
        _ = try tree.arena.allocator().alloc(u8, 1);
        _ = try tree.arena.allocator().alloc(u8, tree.arena.queryCapacity() - 1);
        // Two allocations so far: the handle's page flags, then the arena's
        // one buffer, which is now full and the last thing in `fixed`.
        try testing.expectEqual(2, failing.alloc_index);
        try testing.expectEqual(0, failing.resize_index);
        failing.fail_index = 2;
        failing.resize_fail_index = fail_at;

        const result = switch (case.op) {
            .put => tree.put(case.key, case.value),
            .delete => if (tree.delete(case.key)) |found| try testing.expect(found) else |err| err,
        };
        if (fail_at == case.requests) {
            // Nothing refused: the operation makes exactly the requests the
            // case lists, so the runs before this one reached all of them.
            try result;
            try testing.expectEqual(case.requests, failing.resize_index);
            try testing.expectEqual(2, failing.alloc_index);
            try testing.expect(!failing.has_induced_failure);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            const stats = tree.stats;
            try testing.expectEqual(case.leaf_splits, stats.leaf_splits);
            try testing.expectEqual(case.interior_splits, stats.interior_splits);
            try testing.expectEqual(case.root_splits, stats.root_splits);
            try testing.expectEqual(case.pages_reused, stats.pages_reused);
            try testing.expectEqual(case.tree_pages_freed, stats.tree_pages_freed);
            try testing.expectEqual(case.interior_pages_freed, stats.interior_pages_freed);
            try testing.expectEqual(case.root_collapses, stats.root_collapses);
            try tree.validate();
            try expectValue(&tree, case.key, if (case.op == .put) case.value else null);
            continue;
        }

        try testing.expectError(error.OutOfMemory, result);
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(fail_at, failing.resize_index); // the requests before it were served
        try testing.expectEqual(0, pool.pinnedFrames());
        try pool.validate();
        reached += 1;
        failing.fail_index = std.math.maxInt(usize); // memory is back
        failing.resize_fail_index = std.math.maxInt(usize);

        try testing.expectEqual(fail_at >= case.first_poisoned, tree.poisoned);
        if (tree.poisoned) {
            try testing.expectError(error.TreePoisoned, tree.put(case.key, case.value));
            try testing.expectError(error.TreePoisoned, tree.delete(case.key));
            try testing.expectError(error.TreePoisoned, tree.get(testing.allocator, case.key));
            try testing.expectError(error.TreePoisoned, tree.range("", null));
            try testing.expectError(error.TreePoisoned, tree.flush());
            // What is behind the poison: leaked pages or a half-done change,
            // but never a page with two roles or a broken free list. That
            // is what the two ordering rules are for.
            if (tree.validate()) |_| {} else |err| switch (err) {
                error.UnreachablePage, error.LeafChainBroken, error.EmptyPage, error.KeyCountMismatch => {},
                else => return err,
            }
        } else {
            // The operation did not happen at all, and it works when repeated.
            try tree.validate();
            switch (case.op) {
                .put => {
                    try expectValue(&tree, case.key, null);
                    try tree.put(case.key, case.value);
                    try tree.validate();
                    try expectValue(&tree, case.key, case.value);
                },
                .delete => {
                    try testing.expect(try tree.delete(case.key));
                    try tree.validate();
                    try expectValue(&tree, case.key, null);
                },
            }
        }
        try testing.expectEqual(0, pool.pinnedFrames());
    }
    return reached;
}

test "allocation failure at every scratch request of four puts that split and three deletes that free pages" {
    var reached: usize = 0;

    // ---- put ----
    // Keys descend, so every put goes to the leftmost leaf, and the largest
    // cells allowed (three to a page) fill the root after a few leaf splits.
    // Two large values are written and shrunk first: the splits below take
    // their pages from the free list. `file` is the flushed file as it was
    // just before the last put.
    const Put = struct { until_leaf_splits: u64, until_interior_splits: u64, chain: bool = false, requests: usize, first_poisoned: usize, root_splits: u64, pages_reused: u64 };
    const value: [btree.max_local]u8 = @splat('v');
    const chained: [btree.min_local + 4 * btree.overflow_payload]u8 = @splat('c');
    for ([_]Put{
        // The first split: the root leaf moves down, then splits. Requests:
        // the path entry for the root, the page copy, cells, costs. The root
        // has already changed when the first of them is made.
        .{ .until_leaf_splits = 1, .until_interior_splits = 0, .requests = 4, .first_poisoned = 0, .root_splits = 1, .pages_reused = 2 },
        // A leaf that is not the rightmost child splits and its parent has
        // room. Requests: the path, the page copy, cells, costs, and the copy
        // of the parent's key whose pointer changes (`insertSeparator`).
        .{ .until_leaf_splits = 2, .until_interior_splits = 0, .requests = 5, .first_poisoned = 4, .root_splits = 0, .pages_reused = 1 },
        // The root is a full interior page: the leaf splits, the root's
        // content moves down, that page splits. Requests: the path; page
        // copy, cells, costs (`splitLeaf`); page copy, entries, costs
        // (`splitInterior`).
        .{ .until_leaf_splits = 0, .until_interior_splits = 1, .requests = 7, .first_poisoned = 4, .root_splits = 1, .pages_reused = 3 },
        // The same put with a value that has a chain of four pages. The
        // chain is written right after the path: every later request comes
        // after a page change.
        .{ .until_leaf_splits = 0, .until_interior_splits = 1, .chain = true, .requests = 7, .first_poisoned = 1, .root_splits = 1, .pages_reused = 7 },
    }) |put| {
        var file: std.ArrayList(u8) = .empty;
        defer file.deinit(testing.allocator);
        var key: [btree.max_key_len]u8 = @splat('k');
        {
            var mem: MemStorage = .init(testing.allocator);
            defer mem.deinit();
            var db: Db = undefined;
            try db.start(mem.storage(), 4, .create);
            defer db.stop();
            const huge: [btree.max_value_len]u8 = @splat('h');
            for ([_][]const u8{ "~a", "~b" }) |k| try db.tree.put(k, &huge);
            for ([_][]const u8{ "~a", "~b" }) |k| try db.tree.put(k, "");
            try testing.expectEqual(32, db.tree.free_count);
            var i: usize = 0;
            while (db.tree.stats.leaf_splits < put.until_leaf_splits or db.tree.stats.interior_splits < put.until_interior_splits) : (i += 1) {
                try db.tree.flush();
                file.clearRetainingCapacity();
                try file.appendSlice(testing.allocator, mem.bytes.items);
                _ = try std.fmt.bufPrint(key[0..4], "{d:0>4}", .{9999 - i});
                try db.tree.put(&key, &value);
            }
        }
        reached += try failEveryRequest(.{
            .file = file.items,
            .op = .put,
            .key = &key,
            .value = if (put.chain) &chained else &value,
            .requests = put.requests,
            .first_poisoned = put.first_poisoned,
            .leaf_splits = 1,
            .interior_splits = put.until_interior_splits,
            .root_splits = put.root_splits,
            .pages_reused = put.pages_reused,
        });
    }

    // ---- delete ----
    // 2000 keys, then all but two or three are deleted again: what is left
    // is a tall, thin tree in which one more delete empties a leaf and the
    // interior pages above it. Requests: the path, then the list of pages
    // to free (`removeLeaf`), which comes after the left sibling's link has
    // changed, if there is a left sibling.
    const Delete = struct { keep: []const usize, victim: usize, first_poisoned: usize, tree_pages_freed: u64, interior_pages_freed: u64, root_collapses: u64 };
    for ([_]Delete{
        // The last leaf of two: it and its parent go, and the root, left
        // with one child, collapses twice.
        .{ .keep = &.{ 0, 1999 }, .victim = 1999, .first_poisoned = 1, .tree_pages_freed = 4, .interior_pages_freed = 2, .root_collapses = 2 },
        // A leaf in the middle and its parent go; the root keeps two children.
        .{ .keep = &.{ 0, 1000, 1999 }, .victim = 1000, .first_poisoned = 1, .tree_pages_freed = 2, .interior_pages_freed = 1, .root_collapses = 0 },
        // The first leaf has no left sibling: nothing has changed yet when
        // the list of pages to free is asked for.
        .{ .keep = &.{ 0, 1999 }, .victim = 0, .first_poisoned = 2, .tree_pages_freed = 4, .interior_pages_freed = 2, .root_collapses = 2 },
    }) |delete| {
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        var key: [200]u8 = @splat('k');
        {
            var db: Db = undefined;
            try db.start(mem.storage(), 8, .create);
            defer db.stop();
            for (0..2000) |i| {
                _ = try std.fmt.bufPrint(key[0..4], "{d:0>4}", .{i});
                try db.tree.put(&key, "v");
            }
            try testing.expectEqual(3, try db.tree.height());
            for (0..2000) |i| {
                if (std.mem.indexOfScalar(usize, delete.keep, i) != null) continue;
                _ = try std.fmt.bufPrint(key[0..4], "{d:0>4}", .{i});
                try testing.expect(try db.tree.delete(&key));
            }
            try testing.expectEqual(3, try db.tree.height());
            try db.tree.flush();
        }
        _ = try std.fmt.bufPrint(key[0..4], "{d:0>4}", .{delete.victim});
        reached += try failEveryRequest(.{
            .file = mem.bytes.items,
            .op = .delete,
            .key = &key,
            .requests = 2,
            .first_poisoned = delete.first_poisoned,
            .tree_pages_freed = delete.tree_pages_freed,
            .interior_pages_freed = delete.interior_pages_freed,
            .root_collapses = delete.root_collapses,
        });
    }
    try testing.expectEqual((4 + 5 + 7 + 7) + (2 + 2 + 2), reached);
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
        link,
        bounds,
        count,
        orphan,
        twice,
        zeroed,
        emptied,
        depth, // chapter 12's
        cell,
        chain_long,
        chain_short,
        chain_kind,
        chain_shared,
        free_and_used,
        free_count,
        trunk_kind,
        trunk_loop,
        leaked,
    };
    const expected = [_]anyerror{
        error.LeafChainBroken,  error.KeyOutOfBounds,      error.KeyCountMismatch,    error.UnreachablePage,
        error.PageReachedTwice, error.BadPage,             error.EmptyPage,           error.UnevenDepth,
        error.BadCell,          error.OverflowChainBroken, error.OverflowChainBroken, error.OverflowChainBroken,
        error.PageReachedTwice, error.PageInTwoRoles,      error.FreeListBroken,      error.FreeListBroken,
        error.PageReachedTwice, error.UnreachablePage,
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

// ---- a file is untrusted input ------------------------------------------------
//
// The tests below damage a flushed file and open it with a new handle. No
// call may crash or run for ever, whatever the bytes are: it returns a value
// or an error, and it leaves no pin.

const page_size = btree.page_size;

/// Key number `i` of the damage tests' tree: 250 bytes, so that fifteen
/// separators fill an interior page.
fn damageKey(buf: *[250]u8, i: usize) []const u8 {
    @memset(buf, 'k');
    _ = std.fmt.bufPrint(buf[0..4], "{d:0>4}", .{i}) catch unreachable;
    return buf;
}

/// Where the pages of every role are in the file of `buildDamageFile`.
const Layout = struct {
    pages: u32,
    keys: usize,
    /// The root (page 1, interior) and its first two children (interior).
    inner: [2]u32,
    /// The first leaf that holds a value with a chain, the slot of that
    /// value's cell, the leaf after it, and the two pages of the chain.
    leaf: u32,
    slot: usize,
    next_leaf: u32,
    chain: [2]u32,
    /// The only trunk of the free list.
    trunk: u32,

    fn page(file: []u8, id: u32) SlottedPage {
        return SlottedPage.open(file[@as(usize, id) * page_size ..][0..page_size]);
    }
};

/// A file with three levels, values with and without chains, and a free list.
fn buildDamageFile(file: *std.ArrayList(u8)) !Layout {
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    var db: Db = undefined;
    try db.start(mem.storage(), 8, .create);
    defer db.stop();
    const tree = &db.tree;
    var key_buf: [250]u8 = undefined;
    const value: [9000]u8 = @splat('v');
    var keys: usize = 0;
    while (tree.stats.interior_splits == 0) : (keys += 1) {
        // Every fourth value has a chain of two pages.
        try tree.put(damageKey(&key_buf, keys), value[0..if (keys % 4 == 1) 9000 else 1000]);
    }
    // Sixteen pages for the free list: one trunk that lists fifteen.
    const huge: [btree.max_value_len]u8 = @splat('h');
    try tree.put("zz", &huge);
    try testing.expect(try tree.delete("zz"));
    try tree.validate();
    try testing.expectEqual(3, try tree.height());
    try testing.expectEqual(16, tree.free_count);
    try tree.flush();
    try file.appendSlice(testing.allocator, mem.bytes.items);

    var layout: Layout = .{ .pages = db.pager.pageCount(), .keys = keys, .inner = undefined, .leaf = undefined, .slot = undefined, .next_leaf = undefined, .chain = undefined, .trunk = tree.free_head };
    const root = Layout.page(file.items, 1);
    layout.inner = .{ btree.childAt(root, 0), btree.childAt(root, 1) };
    layout.leaf = btree.childAt(Layout.page(file.items, layout.inner[0]), 0);
    find: while (true) : (layout.leaf = layout.next_leaf) {
        const leaf = Layout.page(file.items, layout.leaf);
        layout.next_leaf = btree.link(leaf);
        for (0..leaf.count()) |slot| {
            const ref = try btree.parseField(leaf.value(slot));
            if (ref.first == btree.invalid_page_id) continue;
            layout.slot = slot;
            layout.chain[0] = ref.first;
            layout.chain[1] = std.mem.readInt(u32, file.items[@as(usize, ref.first) * page_size ..][0..4], .little);
            break :find;
        }
    }
    return layout;
}

/// What `poke` saw.
const Poked = struct {
    opened: bool = false,
    valid: bool = false,
    dump_ok: bool = false,
    /// The free-list part of the dump said that the list loops.
    dump_loops: bool = false,
};

/// `Corrupt` is the answer to damage (and `TreePoisoned` what follows it);
/// any other error fails the test.
fn damageOnly(err: anyerror) !void {
    switch (err) {
        error.Corrupt, error.TreePoisoned => {},
        else => return err,
    }
}

/// Open `file` with a new handle and call everything: validate, height,
/// dump, a get for every key, two scans, then puts and deletes that split
/// leaves, write and free chains, and empty the first leaves. Checks after
/// every call that no pin is left.
fn poke(file: []const u8, layout: Layout, frames: u32) !Poked {
    var result: Poked = .{};
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    try mem.bytes.appendSlice(testing.allocator, file);
    var db: Db = undefined;
    db.start(mem.storage(), frames, .open) catch |err| switch (err) {
        error.Corrupt, error.BadMagic, error.UnsupportedVersion => return result,
        else => return err,
    };
    defer db.stop(); // asserts that no pin is left
    result.opened = true;
    const tree = &db.tree;
    const pool = &db.pool;

    if (tree.validate()) |_| {
        result.valid = true;
    } else |err| switch (err) {
        error.OutOfMemory, error.StorageFailure, error.ShortRead, error.AllFramesPinned => return err,
        else => {}, // one of the twelve violations, or Corrupt
    }
    try testing.expectEqual(0, pool.pinnedFrames());

    _ = tree.height() catch |err| try damageOnly(err);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    if (tree.dump(&out.writer)) |_| {
        result.dump_ok = true;
        result.dump_loops = std.mem.indexOf(u8, out.written(), "(the list loops)") != null;
    } else |err| try damageOnly(err);
    try testing.expectEqual(0, pool.pinnedFrames());

    var key_buf: [250]u8 = undefined;
    for (0..layout.keys + 1) |i| {
        const got = tree.get(testing.allocator, damageKey(&key_buf, i)) catch |err| {
            try damageOnly(err);
            continue;
        };
        if (got) |v| testing.allocator.free(v);
    }
    try testing.expectEqual(0, pool.pinnedFrames());

    // A scan ends by itself, with the last entry or with an error. A sound
    // leaf has fewer than 700 cells, and a scan visits each page once.
    var lo_buf: [250]u8 = undefined;
    for ([_][]const u8{ "", damageKey(&lo_buf, layout.keys / 2) }) |lo| {
        var it = tree.range(lo, null) catch |err| {
            try damageOnly(err);
            continue;
        };
        defer it.deinit();
        var entries: usize = 0;
        while (it.next() catch |err| blk: {
            try damageOnly(err);
            break :blk null;
        }) |_| entries += 1;
        try testing.expect(entries <= 700 * @as(usize, layout.pages));
    }
    try testing.expectEqual(0, pool.pinnedFrames());

    // Writes: a new large value, overwrites that free and write chains,
    // deletes that empty the first leaves, puts that split and reuse pages.
    const value: [9000]u8 = @splat('w');
    for (0..12) |i| {
        if (tree.delete(damageKey(&key_buf, i))) |_| {} else |err| try damageOnly(err);
        try testing.expectEqual(0, pool.pinnedFrames());
    }
    for (0..24) |i| {
        const k = damageKey(&key_buf, if (i % 2 == 0) layout.keys + i else i);
        tree.put(k, value[0..if (i % 3 == 0) 9000 else 1000]) catch |err| try damageOnly(err);
        try testing.expectEqual(0, pool.pinnedFrames());
    }
    try pool.validate();
    if (tree.validate()) |_| {} else |err| switch (err) {
        error.OutOfMemory, error.StorageFailure, error.ShortRead, error.AllFramesPinned => return err,
        else => {},
    }
    tree.flush() catch |err| try damageOnly(err);
    return result;
}

/// One field of one page, overwritten.
const FieldDamage = struct {
    name: []const u8,
    page: u32,
    offset: usize,
    bytes: [8]u8 = @splat(0),
    len: usize,

    fn int(comptime T: type, name: []const u8, page: u32, offset: usize, value: T) FieldDamage {
        var d: FieldDamage = .{ .name = name, .page = page, .offset = offset, .len = @sizeOf(T) };
        std.mem.writeInt(T, d.bytes[0..@sizeOf(T)], value, .little);
        return d;
    }

    fn apply(d: FieldDamage, file: []u8) void {
        @memcpy(file[@as(usize, d.page) * page_size + d.offset ..][0..d.len], d.bytes[0..d.len]);
    }
};

/// Every count, length and page id that the tree reads from a page, each
/// with the values that could send a careless reader out of the page, out
/// of the file, or round in a circle.
fn damageList(list: *std.ArrayList(FieldDamage), file: []u8, layout: Layout) !void {
    const gpa = testing.allocator;
    const int = FieldDamage.int;
    const outside = layout.pages + 7;
    const leaf = Layout.page(file, layout.leaf);
    const cell = leaf.cellOffset(layout.slot);
    const field = cell + 4 + leaf.key(layout.slot).len;
    const field_len = leaf.value(layout.slot).len;
    const root_cell = Layout.page(file, 1).cellOffset(0);
    const inner_cell = Layout.page(file, layout.inner[0]).cellOffset(0);

    // The metapage: root, page count, key count, free-list head and count.
    for ([_]u32{ 0, outside, layout.leaf, layout.chain[0], layout.trunk }) |v| try list.append(gpa, int(u32, "meta root", 0, 16, v));
    try list.append(gpa, int(u32, "meta page count", 0, 20, outside));
    for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |v| try list.append(gpa, int(u64, "meta key count", 0, 24, v));
    for ([_]u32{ 0, 1, outside, btree.invalid_page_id, layout.leaf, layout.chain[0] }) |v| try list.append(gpa, int(u32, "meta free head", 0, 32, v));
    for ([_]u32{ 0, 1, 15, 17, layout.pages - 1, layout.pages, std.math.maxInt(u32) }) |v| try list.append(gpa, int(u32, "meta free count", 0, 36, v));

    // The trunk: link, count, the entry that the next allocation takes.
    for ([_]u32{ layout.trunk, 0, 1, outside, layout.leaf }) |v| try list.append(gpa, int(u32, "trunk next", layout.trunk, 0, v));
    for ([_]u16{ 0, 14, 16, btree.trunk_capacity, btree.trunk_capacity + 1, 5000, 0xffff }) |v| try list.append(gpa, int(u16, "trunk count", layout.trunk, 4, v));
    for ([_]u32{ 0, 1, outside, btree.invalid_page_id, layout.trunk, layout.leaf, layout.inner[0], layout.chain[0] }) |v| try list.append(gpa, int(u32, "trunk last entry", layout.trunk, 8 + 4 * 14, v));
    try list.append(gpa, int(u8, "trunk kind", layout.trunk, 7, btree.kind_leaf));

    // An overflow page: its link and its kind.
    for ([_]u32{ layout.chain[0], 0, 1, outside, btree.invalid_page_id, layout.trunk, layout.leaf }) |v| try list.append(gpa, int(u32, "overflow next", layout.chain[0], 0, v));
    for ([_]u32{ layout.chain[0], layout.chain[1], 0, 1, outside, layout.trunk }) |v| try list.append(gpa, int(u32, "last overflow next", layout.chain[1], 0, v));
    for ([_]u8{ 0, btree.kind_leaf, btree.kind_interior, btree.kind_trunk }) |v| try list.append(gpa, int(u8, "overflow kind", layout.chain[0], 7, v));

    // A leaf cell's value field: the total length and the chain's first page.
    for ([_]u32{ 0, 1000, btree.max_local, btree.max_local + 1, 9001, 4916, 13084, btree.max_value_len, btree.max_value_len + 1, std.math.maxInt(u32) }) |v| try list.append(gpa, int(u32, "value length", layout.leaf, field, v));
    for ([_]u32{ 0, 1, outside, btree.invalid_page_id, layout.leaf, layout.trunk, layout.chain[1] }) |v| try list.append(gpa, int(u32, "value first overflow page", layout.leaf, field + field_len - 4, v));

    // A tree page's own numbers: the slotted page header, a slot, a cell
    // header, the link. Leaf, root and the interior page between them.
    for ([_]u32{ layout.leaf, 1, layout.inner[0] }) |id| {
        const at = Layout.page(file, id).cellOffset(0);
        for ([_]u16{ 0, 1, 2, 300, 2040, 0xffff }) |v| try list.append(gpa, int(u16, "cell count", id, 0, v));
        for ([_]u16{ 0, 15, 4092, 4093, 0xffff }) |v| try list.append(gpa, int(u16, "content start", id, 2, v));
        for ([_]u16{ 1, 16, 4090, 4094, 0xffff }) |v| try list.append(gpa, int(u16, "first free block", id, 4, v));
        for ([_]u8{ 0, 3, 4, 255 }) |v| try list.append(gpa, int(u8, "kind", id, 7, v));
        try list.append(gpa, int(u8, "kind", id, 7, if (id == layout.leaf) btree.kind_interior else btree.kind_leaf));
        for ([_]u8{ 0, 5, 255 }) |v| try list.append(gpa, int(u8, "reserved tail", id, 8, v));
        for ([_]u32{ id, 0, 1, outside, layout.trunk, layout.chain[0], layout.leaf, layout.inner[1] }) |v| try list.append(gpa, int(u32, "link", id, 9, v));
        for ([_]u16{ 0, 8, 4091, 4095, 0xffff }) |v| try list.append(gpa, int(u16, "slot 0", id, 16, v));
        for ([_]u16{ 0, 251, 257, 4000, 0xffff }) |v| try list.append(gpa, int(u16, "key length", id, at, v));
        for ([_]u16{ 0, 2, 3, 5, 1097, 4000, 0xffff }) |v| try list.append(gpa, int(u16, "value length in the cell header", id, at + 2, v));
    }
    // A child pointer: up (a circle), sideways, out of the file, to a page
    // that is not a tree page.
    for ([_]u32{ 1, 0, outside, layout.inner[0], layout.inner[1], layout.leaf, layout.trunk, layout.chain[0] }) |v| {
        try list.append(gpa, int(u32, "root child 0", 1, root_cell + 4 + 250, v));
        try list.append(gpa, int(u32, "interior child 0", layout.inner[0], inner_cell + 4 + 250, v));
    }
}

test "damage to every count, length and page id of a page: an error, never a crash or an endless loop" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    const layout = try buildDamageFile(&file);
    var list: std.ArrayList(FieldDamage) = .empty;
    defer list.deinit(testing.allocator);
    try damageList(&list, file.items, layout);
    const sound = try testing.allocator.dupe(u8, file.items);
    defer testing.allocator.free(sound);

    // The file as it is passes, and `poke` leaves a valid tree behind.
    const intact = try poke(sound, layout, 3);
    try testing.expect(intact.opened and intact.valid and intact.dump_ok and !intact.dump_loops);

    var unnoticed: usize = 0;
    var refused_by_open: usize = 0;
    var applied: usize = 0;
    for (list.items) |damage| {
        @memcpy(file.items, sound);
        damage.apply(file.items);
        if (std.mem.eql(u8, file.items, sound)) continue; // the value it has
        applied += 1;
        for ([_]u32{ 2, 5 }) |frames| {
            const seen = try poke(file.items, layout, frames);
            if (seen.opened and seen.valid) unnoticed += 1;
            if (!seen.opened) refused_by_open += 1;
        }
    }
    try testing.expectEqual(236, applied);
    // `open` or `validate` reports every one of them.
    try testing.expectEqual(0, unnoticed);
    try testing.expectEqual(2 * 9, refused_by_open);
}

test "the free list of a damaged file: a count beyond the page, an id that is in use, a trunk that points at itself" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    const layout = try buildDamageFile(&file);
    const trunk = file.items[@as(usize, layout.trunk) * page_size ..][0..page_size];
    const sound: btree.Page = trunk.*;
    const big: [5000]u8 = @splat('v');

    // 1. The count says 5000 ids; a trunk has room for 1021. `allocPage`
    //    must not use it as an index. (`freePage` treats the trunk as full.)
    for ([_]u16{ btree.trunk_capacity + 1, 5000, 0xffff }) |count| {
        trunk.* = sound;
        std.mem.writeInt(u16, trunk[4..6], count, .little);
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        try mem.bytes.appendSlice(testing.allocator, file.items);
        var db: Db = undefined;
        try db.start(mem.storage(), 4, .open);
        defer db.stop();
        try testing.expectError(error.FreeListBroken, db.tree.validate());
        try testing.expectError(error.Corrupt, db.tree.put("k2", &big));
        try testing.expect(!db.tree.poisoned); // nothing had changed yet
        try testing.expectEqual(0, db.pool.pinnedFrames());
    }

    // 2. The id that the next allocation takes is not a free page: page 0,
    //    a page outside the file, the trunk itself.
    for ([_]u32{ 0, layout.pages, layout.trunk }) |id| {
        trunk.* = sound;
        std.mem.writeInt(u32, trunk[8 + 4 * 14 ..][0..4], id, .little);
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        try mem.bytes.appendSlice(testing.allocator, file.items);
        var db: Db = undefined;
        try db.start(mem.storage(), 4, .open);
        defer db.stop();
        try testing.expectError(error.Corrupt, db.tree.put("k2", &big));
        try testing.expect(!db.tree.poisoned);
        try testing.expectEqual(0, db.pool.pinnedFrames());
    }

    // 3. The trunk's link leads back to the trunk. `validate` names it, and
    //    `dump` prints as many trunks as the file has pages, then stops.
    trunk.* = sound;
    std.mem.writeInt(u32, trunk[0..4], layout.trunk, .little);
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    try mem.bytes.appendSlice(testing.allocator, file.items);
    var db: Db = undefined;
    try db.start(mem.storage(), 4, .open);
    defer db.stop();
    try testing.expectError(error.PageReachedTwice, db.tree.validate());
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try db.tree.dump(&out.writer);
    try testing.expect(std.mem.endsWith(u8, out.written(), " | ... (the list loops)\n"));
    try testing.expectEqual(layout.pages, std.mem.count(u8, out.written(), " | trunk "));
    // Allocations still work until the list's count is used up: 15 listed
    // pages, then the trunk itself, which leaves a list that is not one.
    for (0..3) |_| try db.tree.put("k2", &big); // each frees one page and takes one
    try testing.expectEqual(0, db.pool.pinnedFrames());
}

test "a trunk that lists a page of the operation in progress: Corrupt, not one page under two pins" {
    // The root is a full leaf, and the free list's next id is the root. The
    // put below must split: it pins the root, asks for a page to move the
    // root's content to, and would get the root.
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    const value: [1080]u8 = @splat('v');
    const large: [6000]u8 = @splat('v');
    {
        var db: Db = undefined;
        try db.start(mem.storage(), 4, .create);
        defer db.stop();
        try db.tree.put("0", &large); // a chain: pages 2 and 3
        try db.tree.put("0", &value); // page 2 is the trunk and lists page 3
        try db.tree.put("1", &value);
        try db.tree.put("2", &value);
        try testing.expectEqual(1, try db.tree.height());
        try testing.expectEqual(2, db.tree.free_head);
        try db.tree.flush();
    }
    const trunk = mem.bytes.items[2 * page_size ..][0..page_size];
    try testing.expectEqual(1, std.mem.readInt(u16, trunk[4..6], .little));
    try testing.expectEqual(3, std.mem.readInt(u32, trunk[8..12], .little));
    std.mem.writeInt(u32, trunk[8..12], 1, .little);
    var db: Db = undefined;
    try db.start(mem.storage(), 4, .open);
    defer db.stop();
    try testing.expectError(error.Corrupt, db.tree.put("3", &value));
    try testing.expect(!db.tree.poisoned); // nothing had changed yet
    try testing.expectEqual(0, db.pool.pinnedFrames());
    try expectValue(&db.tree, "1", &value);
}

test "pointers that lead in a circle: every walk ends with Corrupt" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    const layout = try buildDamageFile(&file);
    const sound = try testing.allocator.dupe(u8, file.items);
    defer testing.allocator.free(sound);
    var key_buf: [250]u8 = undefined;
    const Case = struct { page: u32, offset: usize, value: u32 };
    const root_child = Layout.page(file.items, 1).cellOffset(0) + 4 + 250;
    const inner_child = Layout.page(file.items, layout.inner[0]).cellOffset(0) + 4 + 250;
    for ([_]Case{
        // The root's first child is the root; an interior page's first
        // child is the root above it.
        .{ .page = 1, .offset = root_child, .value = 1 },
        .{ .page = layout.inner[0], .offset = inner_child, .value = 1 },
    }) |case| {
        @memcpy(file.items, sound);
        std.mem.writeInt(u32, file.items[@as(usize, case.page) * page_size + case.offset ..][0..4], case.value, .little);
        var mem: MemStorage = .init(testing.allocator);
        defer mem.deinit();
        try mem.bytes.appendSlice(testing.allocator, file.items);
        var db: Db = undefined;
        try db.start(mem.storage(), 4, .open);
        defer db.stop();
        const first = damageKey(&key_buf, 0);
        try testing.expectError(error.PageReachedTwice, db.tree.validate());
        try testing.expectError(error.Corrupt, db.tree.get(testing.allocator, first));
        try testing.expectError(error.Corrupt, db.tree.range("", null));
        try testing.expectError(error.Corrupt, db.tree.height());
        try testing.expectError(error.Corrupt, db.tree.put(first, "v"));
        try testing.expectError(error.Corrupt, db.tree.delete(first));
        try testing.expect(!db.tree.poisoned);
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectError(error.Corrupt, db.tree.dump(&out.writer));
        // One line per page at most, however the pointers are bent.
        try testing.expect(std.mem.count(u8, out.written(), "\n") <= layout.pages);
        try testing.expectEqual(0, db.pool.pinnedFrames());
    }

    // A leaf whose link leads back to itself: the scan gives the leaf's
    // entries once per round and stops after as many rounds as the file
    // has pages.
    @memcpy(file.items, sound);
    std.mem.writeInt(u32, file.items[@as(usize, layout.leaf) * page_size + 9 ..][0..4], layout.leaf, .little);
    var mem: MemStorage = .init(testing.allocator);
    defer mem.deinit();
    try mem.bytes.appendSlice(testing.allocator, file.items);
    var db: Db = undefined;
    try db.start(mem.storage(), 4, .open);
    defer db.stop();
    try testing.expectError(error.LeafChainBroken, db.tree.validate());
    var it = try db.tree.range("", null);
    defer it.deinit();
    var entries: usize = 0;
    const end = while (it.next()) |item| {
        if (item == null) break false;
        entries += 1;
    } else |err| err == error.Corrupt;
    try testing.expect(end);
    try testing.expect(entries <= 700 * @as(usize, layout.pages));
    try testing.expectEqual(0, db.pool.pinnedFrames());
}

test "fuzz: flipped bytes, overwritten ids and swapped pages never crash or hang a handle" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    const layout = try buildDamageFile(&file);
    const sound = try testing.allocator.dupe(u8, file.items);
    defer testing.allocator.free(sound);
    var rng = SplitMix64.init(13);
    var noticed: usize = 0;
    const rounds = 600;
    for (0..rounds) |round| {
        @memcpy(file.items, sound);
        // Every page gets its turn; the kind of damage is random.
        const id: u32 = @intCast(round % layout.pages);
        const page = file.items[@as(usize, id) * page_size ..][0..page_size];
        switch (rng.below(8)) {
            // One to four bytes of the page, half of the time among the
            // first 48 (headers, slots, the metapage's fields).
            0, 1, 2, 3 => for (0..rng.range(1, 5)) |_| {
                const at = rng.below(if (rng.chance(1, 2)) 48 else page_size);
                page[at] = switch (rng.below(4)) {
                    0 => 0,
                    1 => 0xff,
                    2 => page[at] ^ (@as(u8, 1) << @intCast(rng.below(8))),
                    else => @truncate(rng.nextU64()),
                };
            },
            // A page id (of a page of this file, or just outside it) at a
            // random place: most of them make a pointer where none was.
            4, 5 => std.mem.writeInt(u32, page[rng.below(page_size - 3)..][0..4], @intCast(rng.below(layout.pages + 2)), .little),
            // Another page's bytes: a sound page in the wrong place.
            6 => page.* = sound[rng.below(layout.pages) * page_size ..][0..page_size].*,
            // Noise, with the kind byte of a tree page half of the time.
            else => {
                for (page) |*b| b.* = @truncate(rng.nextU64());
                if (rng.chance(1, 2)) page[7] = @intCast(rng.range(1, 3));
            },
        }
        const seen = try poke(file.items, layout, if (round % 2 == 0) 2 else 6);
        if (!seen.opened or !seen.valid) noticed += 1;
    }
    // Not every flipped byte matters (most bytes are values), many do.
    try testing.expect(noticed > rounds / 4 and noticed < rounds);
}
