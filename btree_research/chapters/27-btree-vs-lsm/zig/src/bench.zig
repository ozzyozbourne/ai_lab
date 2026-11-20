//! The comparison harness: one operation stream, applied to the B+tree, to
//! the LSM-tree and to the oracle, with the device counters of each structure
//! read before and after every single operation.
//!
//! Only counts come out of here. No timings: block counts are what the
//! structure decides; how long a block takes is the hardware's business.
const std = @import("std");
const Allocator = std.mem.Allocator;

const device = @import("device.zig");
const Counters = device.Counters;
const BPlusTree = @import("base_tree.zig").BPlusTree;
const Entry = @import("base_node.zig").Entry;
const lsm_ = @import("lsm.zig");
const Lsm = lsm_.Lsm;
const ops = @import("ops.zig");

/// Device activity of all operations of one kind.
pub const Tally = struct {
    ops: u64 = 0,
    io: Counters = .{},
    /// Most blocks written by a single operation: the latency spike.
    max_writes: u64 = 0,
    /// Entries returned (scans only).
    entries: u64 = 0,

    fn record(self: *Tally, io: Counters) void {
        self.ops += 1;
        self.io.add(io);
        self.max_writes = @max(self.max_writes, io.totalWrites());
    }
};

/// One structure's side of a comparison.
pub const Side = struct {
    /// put + delete
    writes: Tally = .{},
    gets: Tally = .{},
    scans: Tally = .{},
    /// Blocks allocated at the end, and the most at any moment.
    blocks: u64 = 0,
    peak: u64 = 0,
};

pub const Workload = struct {
    name: []const u8,
    seed: u64,
    /// Puts applied before measuring starts (same key space).
    preload: u64,
    /// Measured operations.
    count: u64,
    key_space: u64,
    weights: ops.Weights,
    /// A scan covers [lo, lo + scan_span) at most.
    scan_span: u64,
};

pub const Report = struct {
    btree: Side = .{},
    lsm: Side = .{},
    live_keys: usize = 0,
    /// Answers that differed from the oracle's (must be 0).
    mismatches: usize = 0,
    btree_height: usize = 0,
    lsm_levels: usize = 0,
    lsm_l0_runs: usize = 0,
    lsm_slots: usize = 0,
    lsm_stats: lsm_.Stats = .{},
};

fn sameEntries(got: []const Entry, want: []const ops.Entry) bool {
    if (got.len != want.len) return false;
    for (got, want) |g, w| {
        if (g.key != w.key or g.value != w.value) return false;
    }
    return true;
}

pub fn runWorkload(gpa: Allocator, wl: Workload, order: usize, cfg: lsm_.Config) !Report {
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

    // Preload: puts only, from a different seed, not measured.
    var load = ops.OpStream.init(.{
        .seed = wl.seed +% 1,
        .count = wl.preload,
        .key_space = wl.key_space,
        .weights = .{ .put = 1, .delete = 0, .get = 0, .range = 0 },
    });
    while (load.next()) |op| {
        _ = try tree.put(gpa, op.put.key, op.put.value);
        try lsm.put(gpa, op.put.key, op.put.value);
        _ = try oracle.put(gpa, op.put.key, op.put.value);
    }
    tree.dev.peak = tree.dev.live;
    lsm.dev.peak = lsm.dev.live;
    lsm.stats = .{};

    var report: Report = .{};
    var stream = ops.OpStream.init(.{ .seed = wl.seed, .count = wl.count, .key_space = wl.key_space, .weights = wl.weights });
    while (stream.next()) |op| {
        const t0 = tree.dev.counters;
        const l0 = lsm.dev.counters;
        var tree_tally: *Tally = undefined;
        var lsm_tally: *Tally = undefined;
        switch (op) {
            .put => |p| {
                const old = try oracle.put(gpa, p.key, p.value);
                if (try tree.put(gpa, p.key, p.value) != old) report.mismatches += 1;
                try lsm.put(gpa, p.key, p.value);
                tree_tally = &report.btree.writes;
                lsm_tally = &report.lsm.writes;
            },
            .delete => |d| {
                const old = oracle.delete(d.key);
                if (tree.delete(d.key) != old) report.mismatches += 1;
                try lsm.delete(gpa, d.key);
                tree_tally = &report.btree.writes;
                lsm_tally = &report.lsm.writes;
            },
            .get => |g| {
                const want = oracle.get(g.key);
                if (tree.get(g.key) != want) report.mismatches += 1;
                if (lsm.get(g.key) != want) report.mismatches += 1;
                tree_tally = &report.btree.gets;
                lsm_tally = &report.lsm.gets;
            },
            .range => |r| {
                // The generator's ranges are arbitrarily long; cut them down
                // to SHORT scans, which is where the two structures differ.
                const hi = @min(r.hi, r.lo + wl.scan_span);
                const want = oracle.range(r.lo, hi);
                tree_out.clearRetainingCapacity();
                lsm_out.clearRetainingCapacity();
                try tree.range(gpa, r.lo, hi, &tree_out);
                try lsm.range(gpa, r.lo, hi, &lsm_out);
                if (!sameEntries(tree_out.items, want)) report.mismatches += 1;
                if (!sameEntries(lsm_out.items, want)) report.mismatches += 1;
                tree_tally = &report.btree.scans;
                lsm_tally = &report.lsm.scans;
                tree_tally.entries += want.len;
                lsm_tally.entries += want.len;
            },
        }
        tree_tally.record(tree.dev.counters.since(t0));
        lsm_tally.record(lsm.dev.counters.since(l0));
    }

    try tree.validate();
    try lsm.validate();
    report.live_keys = oracle.len();
    report.btree.blocks = tree.dev.live;
    report.btree.peak = tree.dev.peak;
    report.btree_height = tree.height;
    report.lsm.blocks = lsm.dev.live;
    report.lsm.peak = lsm.dev.peak;
    report.lsm_levels = lsm.deepestLevel();
    report.lsm_l0_runs = lsm.l0_len;
    report.lsm_slots = lsm.slotsOnDevice();
    report.lsm_stats = lsm.stats;
    return report;
}

/// The three seeded workloads of the chapter.
pub const workloads = [_]Workload{
    .{
        .name = "insert-heavy",
        .seed = 271,
        .preload = 0,
        .count = 12_000,
        .key_space = 1_000_000,
        .weights = .{ .put = 90, .delete = 0, .get = 8, .range = 2 },
        .scan_span = 2_000,
    },
    .{
        .name = "read-heavy",
        .seed = 272,
        .preload = 8_000,
        .count = 12_000,
        .key_space = 12_000,
        .weights = .{ .put = 5, .delete = 0, .get = 80, .range = 15 },
        .scan_span = 40,
    },
    .{
        .name = "update-heavy",
        .seed = 273,
        .preload = 4_000,
        .count = 12_000,
        .key_space = 4_000,
        .weights = .{ .put = 70, .delete = 15, .get = 10, .range = 5 },
        .scan_span = 32,
    },
};

/// B+tree order used for the comparison, and the matching LSM geometry:
/// a data block holds what a leaf holds, an index block what an internal
/// node holds.
pub const bench_order = 16;
pub const bench_lsm: lsm_.Config = .{
    .block_entries = bench_order - 1,
    .index_fanout = bench_order,
    .memtable_entries = 60,
    .l0_runs = 4,
    .growth = 4,
};
