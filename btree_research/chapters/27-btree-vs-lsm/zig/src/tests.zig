//! Tests of chapter 27. The per-file unit tests live next to the code; here
//! are the tests of the two structures as wholes: exact block counts for
//! small hand-checked cases, model tests against the oracle with identical
//! operation streams, allocation failure, and `validate` catching damage.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const BPlusTree = @import("base_tree.zig").BPlusTree;
const Entry = @import("base_node.zig").Entry;
const device = @import("device.zig");
const Counters = device.Counters;
const lsm_ = @import("lsm.zig");
const Lsm = lsm_.Lsm;
const run_ = @import("run.zig");
const bench = @import("bench.zig");
const ops = @import("ops.zig");

const canonical = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

/// 3 slots per block, memtable of 4, two runs in level 0, growth 2:
/// the configuration of the hand example.
const tiny: lsm_.Config = .{ .block_entries = 3, .index_fanout = 4, .memtable_entries = 4, .l0_runs = 2, .growth = 2 };

fn io(reads: u64, writes: u64, c: Counters) !void {
    try testing.expectEqual(reads, c.totalReads());
    try testing.expectEqual(writes, c.totalWrites());
}

// ------------------------------------------------- B+tree: block counts

test "btree: a put reads the path and writes what it dirtied" {
    const gpa = testing.allocator;
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);

    // Empty tree: nothing to read, one new leaf to write.
    var before = tree.dev.counters;
    _ = try tree.put(gpa, 10, 1);
    try io(0, 1, tree.dev.counters.since(before));

    // Root is a leaf: read it, write it.
    before = tree.dev.counters;
    _ = try tree.put(gpa, 20, 2);
    _ = try tree.put(gpa, 5, 3);
    try io(2, 2, tree.dev.counters.since(before));

    // Fourth key overflows the root leaf: left half, new right half and a
    // new root are written; only the old leaf was read.
    before = tree.dev.counters;
    _ = try tree.put(gpa, 6, 4);
    try io(1, 3, tree.dev.counters.since(before));
    try testing.expectEqual(3, tree.dev.live);

    // An overwrite still rewrites the whole leaf block.
    before = tree.dev.counters;
    try testing.expectEqual(4, try tree.put(gpa, 6, 44));
    try io(2, 1, tree.dev.counters.since(before));
    try tree.validate();
}

test "btree: a leaf split in the middle of the chain dirties four blocks" {
    const gpa = testing.allocator;
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);
    for ([_]u64{ 10, 20, 30, 40 }) |k| _ = try tree.put(gpa, k, k); // (10 20) (30 40)
    _ = try tree.put(gpa, 15, 15); // (10 15 20) (30 40)
    const before = tree.dev.counters;
    _ = try tree.put(gpa, 12, 12); // left leaf splits; its old right neighbour needs a new prev link
    const d = tree.dev.counters.since(before);
    // Read: root, the leaf, and the neighbour (only to fix its back link).
    try testing.expectEqual([2]u64{ 1, 2 }, d.reads);
    // Written: root (new separator), left half, new right half, neighbour.
    try testing.expectEqual([2]u64{ 1, 3 }, d.writes);
    try tree.validate();
}

test "btree: get costs exactly `height` reads, hit or miss; scans add one per extra leaf" {
    const gpa = testing.allocator;
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);
    for (canonical) |k| _ = try tree.put(gpa, k, k * 100);
    try testing.expectEqual(3, tree.height);

    var before = tree.dev.counters;
    try testing.expectEqual(1200, tree.get(12));
    try testing.expectEqual(null, tree.get(13));
    var d = tree.dev.counters.since(before);
    try testing.expectEqual([2]u64{ 4, 2 }, d.reads); // 2 internal + 1 leaf, twice
    try testing.expectEqual(0, d.totalWrites());

    // Leaves: (1 3 5) (6 7) (10 12) (15 17) (20 25 30).
    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(gpa);
    before = tree.dev.counters;
    try tree.range(gpa, 6, 16, &out);
    d = tree.dev.counters.since(before);
    try testing.expectEqual(5, out.items.len); // 6 7 10 12 15
    try testing.expectEqual(6, out.items[0].key);
    try testing.expectEqual(3 + 2, d.totalReads()); // descent to (6 7), then (10 12) and (15 17)
    try tree.validate();
}

test "btree: delete with borrow and merge counts the siblings it looked at" {
    const gpa = testing.allocator;
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);
    for (canonical) |k| _ = try tree.put(gpa, k, k);
    var total_before = tree.dev.counters;
    // A miss reads the path and writes nothing.
    try testing.expectEqual(null, tree.delete(999));
    try io(3, 0, tree.dev.counters.since(total_before));
    // Delete everything; every operation must leave the device consistent.
    total_before = tree.dev.counters;
    for (canonical) |k| {
        const before = tree.dev.counters;
        try testing.expectEqual(k, tree.delete(k));
        const d = tree.dev.counters.since(before);
        try testing.expect(d.totalWrites() <= d.totalReads()); // delete never creates a block
        try tree.validate();
    }
    try testing.expect(tree.stats.borrows > 0 and tree.stats.merges > 0);
    try testing.expectEqual(0, tree.dev.live);
    try testing.expectEqual(0, tree.height);
}

// ---------------------------------------------------- LSM: block counts

test "lsm: writes are free until the memtable is full, then one flush" {
    const gpa = testing.allocator;
    var lsm: Lsm = .init(gpa, tiny);
    defer lsm.deinit(gpa);
    for ([_]u64{ 10, 20, 5, 6 }) |k| try lsm.put(gpa, k, k * 100);
    try io(0, 0, lsm.dev.counters);
    try testing.expectEqual(600, lsm.get(6)); // from the memtable
    try io(0, 0, lsm.dev.counters);

    // The fifth put finds the memtable full: 4 slots = 2 data blocks + 1 index.
    try lsm.put(gpa, 12, 1200);
    try testing.expectEqual([2]u64{ 1, 2 }, lsm.dev.counters.writes);
    try testing.expectEqual(1, lsm.l0_len);
    try testing.expectEqual(1, lsm.mem.count);
    try testing.expectEqual(3, lsm.dev.live);

    // A lookup in the run: one index block + one data block.
    const before = lsm.dev.counters;
    try testing.expectEqual(1000, lsm.get(10));
    try testing.expectEqual([2]u64{ 1, 1 }, lsm.dev.counters.since(before).reads);
    // Outside the run's key range: answered from the manifest, no I/O.
    try testing.expectEqual(null, lsm.get(99));
    try testing.expectEqual(null, lsm.get(1));
    try io(2, 0, lsm.dev.counters.since(before));
    // Inside the range but absent: the probe is paid for and wasted.
    try testing.expectEqual(null, lsm.get(7));
    try io(4, 0, lsm.dev.counters.since(before));
    try testing.expectEqual(1, lsm.stats.probes_wasted);
    try testing.expectEqual(2, lsm.stats.runs_skipped);
    try lsm.validate();
}

test "lsm: a run's index is a tree, and every level of it is read and written" {
    // Regression test: the index used to be one level deep, with the choice
    // of the right index block made for free "in RAM". The B+tree paid for
    // every level, so the comparison was tilted.
    const gpa = testing.allocator;
    var lsm: Lsm = .init(gpa, .{ .block_entries = 1, .index_fanout = 2, .memtable_entries = 8, .l0_runs = 1, .growth = 2 });
    defer lsm.deinit(gpa);
    for (1..10) |k| try lsm.put(gpa, k, k * 10);
    // The ninth put flushed keys 1..8 (8 data blocks; 4 + 2 + 1 index blocks)
    // and compacted that run into level 1: every block read once, and the
    // same 15 blocks written again.
    try testing.expectEqual(8, lsm.levels[0].?.len());
    try testing.expectEqual(3, lsm.cfg.geometry().indexHeight(8));
    try testing.expectEqual([2]u64{ 14, 16 }, lsm.dev.counters.writes);
    try testing.expectEqual([2]u64{ 7, 8 }, lsm.dev.counters.reads);
    try testing.expectEqual(15, lsm.dev.live);
    try testing.expectEqual(30, lsm.dev.peak);

    // A point lookup walks root, level 2, level 1, data block: like a B+tree
    // of height 4.
    var before = lsm.dev.counters;
    try testing.expectEqual(50, lsm.get(5));
    try testing.expectEqual([2]u64{ 3, 1 }, lsm.dev.counters.since(before).reads);

    // A scan pays the same path to find its first block, then only the
    // index blocks it newly moves under. Keys 3 and 4 are data blocks 2 and
    // 3; the cursor then steps on to block 4, which lies under another
    // level-1 block and another level-2 block, but under the same root.
    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(gpa);
    before = lsm.dev.counters;
    try lsm.range(gpa, 3, 5, &out);
    try testing.expectEqual(2, out.items.len);
    try testing.expectEqual([2]u64{ 3 + 2, 3 }, lsm.dev.counters.since(before).reads);
    try lsm.validate();
}

test "lsm: newest version wins, a tombstone hides older runs, compaction drops both" {
    const gpa = testing.allocator;
    var lsm: Lsm = .init(gpa, tiny);
    defer lsm.deinit(gpa);
    for ([_]u64{ 1, 2, 3, 4 }) |k| try lsm.put(gpa, k, k);
    try lsm.put(gpa, 2, 22); // flushes (1 2 3 4); newer version of 2 in the memtable
    try lsm.delete(gpa, 3); // tombstone in the memtable
    try testing.expectEqual(22, lsm.get(2));
    try testing.expectEqual(null, lsm.get(3));
    try testing.expectEqual(1, lsm.l0_len);

    try lsm.put(gpa, 5, 5);
    try lsm.put(gpa, 6, 6); // memtable: 2' ~3 5 6
    try lsm.put(gpa, 7, 7); // flush -> two runs in level 0 -> compaction into level 1
    try testing.expectEqual(0, lsm.l0_len);
    try testing.expectEqual(1, lsm.deepestLevel());
    // (1 2 3 4) + (2' ~3 5 6): the old 2 and the old 3 are shadowed, and the
    // tombstone itself is dropped because nothing lies below level 1.
    try testing.expectEqual(2, lsm.stats.versions_dropped);
    try testing.expectEqual(1, lsm.stats.tombstones_dropped);
    try testing.expectEqual(5, lsm.levels[0].?.len()); // 1 2' 4 5 6
    try testing.expectEqual(22, lsm.get(2));
    try testing.expectEqual(null, lsm.get(3));
    try lsm.validate();
}

test "lsm: a tombstone stays on the device until compaction reaches the bottom" {
    const gpa = testing.allocator;
    var lsm: Lsm = .init(gpa, tiny);
    defer lsm.deinit(gpa);
    for (0..8) |k| try lsm.put(gpa, k, k);
    try lsm.delete(gpa, 0); // flush + compaction: level 1 = (0 .. 7); memtable: ~0
    try lsm.delete(gpa, 1);
    try lsm.put(gpa, 8, 8);
    try lsm.put(gpa, 9, 9);
    try lsm.put(gpa, 10, 10); // flush: level 0 = (~0 ~1 8 9) on top of level 1
    try testing.expectEqual(1, lsm.l0_len);
    // Both the tombstones and the values they hide are on the device now.
    try testing.expectEqual(run_.Lookup.tombstone, lsm.l0[0].find(0));
    try testing.expectEqual(run_.Lookup{ .value = 0 }, lsm.levels[0].?.find(0));
    try testing.expectEqual(12, lsm.slotsOnDevice()); // for 8 live keys on the device
    try testing.expectEqual(null, lsm.get(0));
    try testing.expectEqual(0, lsm.stats.tombstones_dropped);

    for (11..15) |k| try lsm.put(gpa, k, k); // second flush -> compaction into level 1
    try testing.expectEqual(2, lsm.stats.tombstones_dropped);
    try testing.expectEqual(2, lsm.stats.versions_dropped);
    try testing.expectEqual(12, lsm.levels[0].?.len()); // 2 .. 13
    try testing.expectEqual(null, lsm.get(0));
    try lsm.validate();
}

test "lsm: a scan merges every overlapping run and pays for each" {
    const gpa = testing.allocator;
    var lsm: Lsm = .init(gpa, tiny);
    defer lsm.deinit(gpa);
    for (canonical) |k| try lsm.put(gpa, k, k * 100);
    try lsm.delete(gpa, 15); // flushes (1 3 15 25) to level 0; level 1 holds the first eight keys
    try testing.expectEqual(1, lsm.l0_len);
    try testing.expectEqual(8, lsm.levels[0].?.len());

    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(gpa);
    const before = lsm.dev.counters;
    try lsm.range(gpa, 3, 16, &out);
    // 3 (level 0), 5 6 7 10 12 (level 1); 15 is hidden by the tombstone.
    var keys: [8]u64 = undefined;
    for (out.items, 0..) |e, i| keys[i] = e.key;
    try testing.expectEqualSlices(u64, &.{ 3, 5, 6, 7, 10, 12 }, keys[0..out.items.len]);
    const d = lsm.dev.counters.since(before);
    // Level 0 run (1 3 15 | 25): index + both data blocks (the cursor moves
    // on to 25 after 15). Level 1 (5 6 7 | 10 12 17 | 20 30): index + two.
    try testing.expectEqual([2]u64{ 2, 4 }, d.reads);
    try lsm.validate();
}

test "lsm: deleting costs space first and gives it back only through compaction" {
    const gpa = testing.allocator;
    var lsm: Lsm = .init(gpa, tiny);
    defer lsm.deinit(gpa);
    for (0..64) |k| try lsm.put(gpa, k, k);
    const full = lsm.dev.live;
    for (0..64) |k| try lsm.delete(gpa, k);
    for (0..64) |k| try testing.expectEqual(null, lsm.get(k));
    // No live key is left, yet the device is as full as before: tombstones
    // are data, and some of them still sit above the values they hide.
    try testing.expect(lsm.dev.live >= full);
    try testing.expect(lsm.dev.peak > 2 * full);
    // Later writes push the tombstones down until they meet the bottom.
    for (100..164) |k| try lsm.put(gpa, k, k);
    try testing.expectEqual(64, lsm.stats.tombstones_dropped);
    try testing.expectEqual(64, lsm.slotsOnDevice() + lsm.mem.count);
    try lsm.validate();
}

// ----------------------------------------------------------- model tests

/// Applies one operation stream to the B+tree, the LSM-tree and the oracle,
/// and checks every answer of both structures.
fn modelTest(gpa: Allocator, order: usize, cfg: lsm_.Config, seed: u64, count: u64, key_space: u64, weights: ops.Weights) !void {
    var tree: BPlusTree = .init(order);
    defer tree.deinit(gpa);
    var lsm: Lsm = .init(gpa, cfg);
    defer lsm.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var tree_out: std.ArrayList(Entry) = .empty;
    defer tree_out.deinit(gpa);
    var lsm_out: std.ArrayList(Entry) = .empty;
    defer lsm_out.deinit(gpa);

    var stream = ops.OpStream.init(.{ .seed = seed, .count = count, .key_space = key_space, .weights = weights });
    var step: usize = 0;
    while (stream.next()) |op| : (step += 1) {
        switch (op) {
            .put => |p| {
                const old = try oracle.put(gpa, p.key, p.value);
                try testing.expectEqual(old, try tree.put(gpa, p.key, p.value));
                try lsm.put(gpa, p.key, p.value);
            },
            .delete => |d| {
                try testing.expectEqual(oracle.delete(d.key), tree.delete(d.key));
                try lsm.delete(gpa, d.key);
            },
            .get => |g| {
                try testing.expectEqual(oracle.get(g.key), tree.get(g.key));
                try testing.expectEqual(oracle.get(g.key), lsm.get(g.key));
            },
            .range => |r| {
                const want = oracle.range(r.lo, r.hi);
                tree_out.clearRetainingCapacity();
                lsm_out.clearRetainingCapacity();
                try tree.range(gpa, r.lo, r.hi, &tree_out);
                try lsm.range(gpa, r.lo, r.hi, &lsm_out);
                try testing.expectEqual(want.len, tree_out.items.len);
                try testing.expectEqual(want.len, lsm_out.items.len);
                for (want, tree_out.items, lsm_out.items) |w, t, l| {
                    try testing.expectEqual(w.key, t.key);
                    try testing.expectEqual(w.value, t.value);
                    try testing.expectEqual(w.key, l.key);
                    try testing.expectEqual(w.value, l.value);
                }
            },
        }
        if (step % 16 == 0) {
            try tree.validate();
            try lsm.validate();
        }
    }
    try tree.validate();
    try lsm.validate();
    // Final sweep: every key of the key space, on both.
    for (0..key_space) |key| {
        try testing.expectEqual(oracle.get(key), tree.get(key));
        try testing.expectEqual(oracle.get(key), lsm.get(key));
    }
}

test "model test: both structures against the oracle, same operation stream" {
    const gpa = testing.allocator;
    // Small memtables and growth factors make many levels out of few keys.
    const configs = [_]lsm_.Config{
        tiny,
        .{ .block_entries = 1, .index_fanout = 2, .memtable_entries = 1, .l0_runs = 1, .growth = 2 },
        .{ .block_entries = 2, .index_fanout = 3, .memtable_entries = 3, .l0_runs = 3, .growth = 3 },
        .{ .block_entries = 5, .index_fanout = 4, .memtable_entries = 8, .l0_runs = 4, .growth = 4 },
        .{ .block_entries = 15, .index_fanout = 16, .memtable_entries = 60, .l0_runs = 4, .growth = 8 },
    };
    for (configs, 0..) |cfg, i| {
        const order = cfg.block_entries + 1 + @intFromBool(cfg.block_entries == 1);
        try modelTest(gpa, order, cfg, 100 + i, 3000, 40, .{});
        try modelTest(gpa, order, cfg, 200 + i, 3000, 2000, .{});
        try modelTest(gpa, order, cfg, 300 + i, 2000, 300, .{ .put = 6, .delete = 1, .get = 2, .range = 1 });
    }
}

test "model test: delete-heavy stream, tombstones everywhere" {
    try modelTest(testing.allocator, 4, tiny, 11, 5000, 6, .{ .put = 2, .delete = 5, .get = 1, .range = 1 });
    try modelTest(testing.allocator, 4, tiny, 12, 5000, 200, .{ .put = 3, .delete = 5, .get = 1, .range = 1 });
    const one: lsm_.Config = .{ .block_entries = 1, .index_fanout = 2, .memtable_entries = 2, .l0_runs = 1, .growth = 2 };
    try modelTest(testing.allocator, 3, one, 13, 5000, 64, .{ .put = 4, .delete = 5, .get = 1, .range = 1 });
}

test "the three workloads of the chapter agree with the oracle (shortened)" {
    for (bench.workloads) |full| {
        var wl = full;
        wl.preload = @min(wl.preload, 1000);
        wl.count = 2000;
        const r = try bench.runWorkload(testing.allocator, wl, bench.bench_order, bench.bench_lsm);
        try testing.expectEqual(0, r.mismatches);
        try testing.expectEqual(r.btree.writes.ops, r.lsm.writes.ops);
        // The LSM never reads in order to write except while compacting, and
        // batches its writes: fewer blocks written, more blocks per lookup.
        try testing.expect(r.lsm.writes.io.totalWrites() < r.btree.writes.io.totalWrites());
        try testing.expect(r.lsm.writes.max_writes > r.btree.writes.max_writes);
    }
}

test "the peak is compared with the keys that were live at the peak" {
    // Regression test: "space amplification at the peak" used to divide the
    // peak by the packed size at the END of the run. The insert-heavy
    // workload only grows, so the LSM's peak (its last big compaction) comes
    // before the end, with fewer keys live.
    const r = try bench.runWorkload(testing.allocator, bench.workloads[0], bench.bench_order, bench.bench_lsm);
    try testing.expect(r.lsm.peak > r.lsm.blocks);
    try testing.expect(r.lsm.peak_live_keys > 0 and r.lsm.peak_live_keys < r.live_keys);
    try testing.expect(r.btree.peak >= r.btree.blocks);
    try testing.expect(r.btree.peak_live_keys <= r.live_keys);

    // With no measured operation the peak is the preloaded state.
    var wl = bench.workloads[1];
    wl.count = 0;
    const idle = try bench.runWorkload(testing.allocator, wl, bench.bench_order, bench.bench_lsm);
    try testing.expectEqual(idle.lsm.blocks, idle.lsm.peak);
    try testing.expectEqual(idle.live_keys, idle.lsm.peak_live_keys);
    try testing.expectEqual(idle.live_keys, idle.btree.peak_live_keys);
}

// ------------------------------------------------------ allocation failure

fn buildLsmUnderFailure(gpa: Allocator) !void {
    var lsm: Lsm = .init(gpa, tiny);
    defer lsm.deinit(gpa);
    for (0..60) |i| {
        const key: u64 = (i * 37) % 64;
        try lsm.put(gpa, key, i);
        if (i % 5 == 4) try lsm.delete(gpa, key / 2);
    }
    try lsm.validate();
}

test "lsm: every allocation failure during a build is reported and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, buildLsmUnderFailure, .{});
}

fn buildTreeUnderFailure(gpa: Allocator) !void {
    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);
    for (canonical) |k| _ = try tree.put(gpa, k, k);
    try tree.validate();
}

test "btree: every allocation failure during a build is reported and leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, buildTreeUnderFailure, .{});
}

test "btree: a put that runs out of memory changes neither the tree nor the device" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var tree: BPlusTree = .init(3);
    defer tree.deinit(gpa);
    var failures: usize = 0;
    for (0..500) |i| {
        const key: u64 = (i * 37) % 503;
        // Make the next allocation fail, whenever it comes.
        // (Growing the node array in place counts as a "resize".)
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        const counters = tree.dev.counters;
        const live = tree.dev.live;
        if (tree.put(gpa, key, key)) |_| {
            // No allocation was needed (spare capacity in the node array).
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try testing.expectEqual(counters, tree.dev.counters);
            try testing.expectEqual(live, tree.dev.live);
            try tree.validate();
            try testing.expectEqual(i, tree.len());
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            try testing.expectEqual(null, try tree.put(gpa, key, key));
        }
        try tree.validate();
    }
    try testing.expect(failures >= 5);
}

test "lsm: a write that runs out of memory changes no answer, and the retry finishes the job" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var lsm: Lsm = .init(gpa, tiny);
    defer lsm.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(testing.allocator);

    var failures: usize = 0;
    var pending_after_failure: usize = 0;
    for (0..400) |i| {
        const key: u64 = (i * 37) % 97;
        const is_delete = i % 7 == 6;
        // Let a few allocations through, then fail: the failure lands in the
        // memtable, in a flush or in the middle of a compaction cascade.
        failing.fail_index = failing.alloc_index + i % 3;
        var attempts: usize = 0;
        while (true) : (attempts += 1) {
            const result = if (is_delete) lsm.delete(gpa, key) else lsm.put(gpa, key, i);
            if (result) |_| break else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                failures += 1;
                // Structure intact, and every key still has its old answer.
                try lsm.validateStructure();
                if (lsm.needsMaintenance()) pending_after_failure += 1;
                for (0..97) |k| try testing.expectEqual(oracle.get(k), lsm.get(k));
                failing.fail_index = std.math.maxInt(usize);
            }
        }
        try testing.expect(attempts <= 1);
        if (is_delete) _ = oracle.delete(key) else _ = try oracle.put(testing.allocator, key, i);
        failing.fail_index = std.math.maxInt(usize);
        try lsm.validate(); // a successful write leaves no maintenance behind
    }
    try testing.expect(failures > 20);
    try testing.expect(pending_after_failure > 0);
    for (0..97) |k| try testing.expectEqual(oracle.get(k), lsm.get(k));
}

// ------------------------------------------- validate catches corruption

test "validate names the broken invariant" {
    const gpa = testing.allocator;
    var lsm: Lsm = .init(gpa, tiny);
    defer lsm.deinit(gpa);
    for (canonical) |k| try lsm.put(gpa, k, k);
    try lsm.put(gpa, 99, 99); // flush: one run in level 0, one in level 1
    try lsm.validate();
    const run = &lsm.levels[0].?;

    std.mem.swap(u64, &run.slots.items[0].key, &run.slots.items[1].key);
    try testing.expectError(error.RunNotSorted, lsm.validate());
    std.mem.swap(u64, &run.slots.items[0].key, &run.slots.items[1].key);

    run.max_key += 1; // the manifest lies about the key range
    try testing.expectError(error.RunBoundsWrong, lsm.validate());
    run.max_key -= 1;

    lsm.dev.live += 1; // a leaked block
    try testing.expectError(error.DeviceAccounting, lsm.validate());
    lsm.dev.live -= 1;

    const saved = lsm.cfg.l0_runs;
    lsm.cfg.l0_runs = 1; // level 0 now counts as full
    try testing.expectError(error.LevelOverLimit, lsm.validate());
    try lsm.validateStructure();
    lsm.cfg.l0_runs = saved;
    try lsm.validate();

    var tree: BPlusTree = .init(4);
    defer tree.deinit(gpa);
    for (canonical) |k| _ = try tree.put(gpa, k, k);
    try tree.validate();
    tree.dev.live -= 1; // a block the device forgot
    try testing.expectError(error.DeviceAccounting, tree.validate());
    tree.dev.live += 1;
    tree.dev.pin(0, .data); // an operation that never ended
    try testing.expectError(error.DeviceAccounting, tree.validate());
    tree.dev.endOp();
    try tree.validate();

    // Regression test (ported from chapter 07): a length beyond the node's
    // arrays is reported before it is used to slice them, not a crash.
    const saved_len = tree.nodes.ptr(tree.last_leaf).len;
    tree.nodes.ptr(tree.last_leaf).len = @import("base_node.zig").key_capacity + 1;
    try testing.expectError(error.NodeOverfull, tree.validate());
    tree.nodes.ptr(tree.last_leaf).len = saved_len;
    try tree.validate();
}
