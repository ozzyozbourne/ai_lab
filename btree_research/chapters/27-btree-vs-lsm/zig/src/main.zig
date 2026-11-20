//! Demo program of chapter 27. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Rust program's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const lib = @import("ch27_btree_vs_lsm");
const BPlusTree = lib.BPlusTree;
const Lsm = lib.Lsm;
const Entry = lib.Entry;
const bench = lib.bench;

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const w = &file_writer.interface;
    try run(init.gpa, w);
    try w.flush();
}

pub fn run(gpa: Allocator, w: *Writer) !void {
    try trace(gpa, w);
    for (bench.workloads, 0..) |wl, i| try compare(gpa, w, wl, i + 3);
    try growthSweep(gpa, w);
}

// ------------------------------------------------------------ 1. trace

const TraceOp = union(enum) { put: [2]u64, delete: u64, get: u64, scan: [2]u64 };

/// The canonical keys of chapters 03 to 08, then lookups, a delete, an
/// overwrite and more inserts: enough to see a flush, a compaction, a
/// tombstone and a stale version.
const trace_ops = [_]TraceOp{
    .{ .put = .{ 10, 1000 } }, .{ .put = .{ 20, 2000 } }, .{ .put = .{ 5, 500 } },
    .{ .put = .{ 6, 600 } },   .{ .put = .{ 12, 1200 } }, .{ .put = .{ 30, 3000 } },
    .{ .put = .{ 7, 700 } },   .{ .put = .{ 17, 1700 } }, .{ .put = .{ 3, 300 } },
    .{ .put = .{ 25, 2500 } }, .{ .put = .{ 1, 100 } },   .{ .put = .{ 15, 1500 } },
    .{ .get = 15 },            .{ .get = 12 },            .{ .get = 13 },
    .{ .delete = 15 },         .{ .put = .{ 20, 2001 } }, .{ .put = .{ 11, 1100 } },
    .{ .put = .{ 13, 1300 } }, .{ .put = .{ 14, 1400 } }, .{ .get = 15 },
    .{ .get = 20 },            .{ .scan = .{ 5, 14 } },
};

pub const trace_order = 4;
pub const trace_lsm: lib.lsm.Config = .{
    .block_entries = trace_order - 1,
    .index_fanout = trace_order,
    .memtable_entries = 4,
    .l0_runs = 2,
    .growth = 2,
};

fn trace(gpa: Allocator, w: *Writer) !void {
    var tree: BPlusTree = .init(trace_order);
    defer tree.deinit(gpa);
    var lsm: Lsm = .init(gpa, trace_lsm);
    defer lsm.deinit(gpa);
    var tree_out: std.ArrayList(Entry) = .empty;
    defer tree_out.deinit(gpa);
    var lsm_out: std.ArrayList(Entry) = .empty;
    defer lsm_out.deinit(gpa);

    try w.writeAll("== 1. One trace, two structures ==\n");
    try w.writeAll("B+tree: order M = 4, so 3 entries per leaf block.\n");
    try w.writeAll("LSM: 3 slots per data block, memtable of 4 keys, level 0 holds 2 runs, growth 2.\n");
    try w.writeAll("r = blocks read, w = blocks written by that one operation. Every block counts, index\n");
    try w.writeAll("blocks too; nothing is cached; there is no log (the limits are listed under section 3).\n\n");

    for (trace_ops) |op| {
        const t0 = tree.dev.counters;
        const l0 = lsm.dev.counters;
        const ts = tree.stats;
        const th = tree.height;
        const ls = lsm.stats;
        var name_buf: [32]u8 = undefined;
        var answer_buf: [128]u8 = undefined;
        var answer: Writer = .fixed(&answer_buf);
        var name: []const u8 = undefined;
        switch (op) {
            .put => |p| {
                name = try std.fmt.bufPrint(&name_buf, "put {d}", .{p[0]});
                _ = try tree.put(gpa, p[0], p[1]);
                try lsm.put(gpa, p[0], p[1]);
            },
            .delete => |key| {
                name = try std.fmt.bufPrint(&name_buf, "delete {d}", .{key});
                _ = tree.delete(key);
                try lsm.delete(gpa, key);
            },
            .get => |key| {
                name = try std.fmt.bufPrint(&name_buf, "get {d}", .{key});
                const a = tree.get(key);
                const b = lsm.get(key);
                std.debug.assert(a == b);
                if (a) |v| try answer.print(" = {d}", .{v}) else try answer.writeAll(" = none");
            },
            .scan => |r| {
                name = try std.fmt.bufPrint(&name_buf, "scan [{d},{d})", .{ r[0], r[1] });
                tree_out.clearRetainingCapacity();
                lsm_out.clearRetainingCapacity();
                try tree.range(gpa, r[0], r[1], &tree_out);
                try lsm.range(gpa, r[0], r[1], &lsm_out);
                std.debug.assert(tree_out.items.len == lsm_out.items.len);
                try answer.writeAll(" =");
                for (tree_out.items, lsm_out.items) |a, b| {
                    std.debug.assert(a.key == b.key and a.value == b.value);
                    try answer.print(" {d}", .{a.key});
                }
            },
        }
        const t = tree.dev.counters.since(t0);
        const l = lsm.dev.counters.since(l0);
        try w.print("{s:<12}| btree r={d} w={d} | lsm r={d:>2} w={d:>2} |{s}", .{
            name, t.totalReads(), t.totalWrites(), l.totalReads(), l.totalWrites(), answer.buffered(),
        });
        // What the counters mean, from the structures' own statistics.
        if (tree.stats.leaf_splits > ts.leaf_splits) try w.writeAll(" btree: leaf split.");
        if (tree.stats.internal_splits > ts.internal_splits) try w.writeAll(" btree: internal split.");
        if (tree.height > th and th > 0) try w.writeAll(" btree: new root.");
        if (tree.stats.borrows > ts.borrows) try w.writeAll(" btree: borrow.");
        if (tree.stats.merges > ts.merges) try w.writeAll(" btree: merge.");
        if (lsm.stats.flushes > ls.flushes) try w.writeAll(" lsm: flush.");
        if (lsm.stats.l0_compactions > ls.l0_compactions) try w.writeAll(" lsm: compact level 0 into level 1.");
        if (lsm.stats.level_merges > ls.level_merges) try w.writeAll(" lsm: merge a level down.");
        try w.writeByte('\n');
    }
    try tree.validate();
    try lsm.validate();

    try w.writeAll("\n== 2. Where the data ended up ==\n");
    try w.print("B+tree: height {d}, {d} blocks\n", .{ tree.height, tree.dev.live });
    try dumpTree(w, &tree);
    try w.print("LSM: {d} blocks on the device holding {d} slots, {d} key(s) in the memtable\n", .{ lsm.dev.live, lsm.slotsOnDevice(), lsm.mem.count });
    try dumpLsm(w, &lsm);
    const tc = tree.dev.counters;
    const lc = lsm.dev.counters;
    try w.print("totals: btree reads={d} writes={d} | lsm reads={d} writes={d}\n", .{
        tc.totalReads(), tc.totalWrites(), lc.totalReads(), lc.totalWrites(),
    });
    try w.print("lsm compaction dropped {d} stale version(s) and {d} tombstone(s)\n", .{
        lsm.stats.versions_dropped, lsm.stats.tombstones_dropped,
    });
}

/// One line per level: internal nodes as [separators], leaves as (keys).
fn dumpTree(w: *Writer, tree: *const BPlusTree) !void {
    for (1..tree.height + 1) |depth| {
        try w.print("  level {d}:", .{depth});
        try dumpDepth(w, tree, tree.root, depth);
        try w.writeByte('\n');
    }
}

fn dumpDepth(w: *Writer, tree: *const BPlusTree, id: lib.arena.NodeId, depth: usize) !void {
    const n = tree.nodes.get(id);
    if (depth > 1) {
        for (n.childSlice()) |child| try dumpDepth(w, tree, child, depth - 1);
        return;
    }
    try w.writeAll(if (n.isLeaf()) " (" else " [");
    for (n.keySlice(), 0..) |key, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("{d}", .{key});
    }
    try w.writeAll(if (n.isLeaf()) ")" else "]");
}

fn dumpLsm(w: *Writer, lsm: *const Lsm) !void {
    try w.writeAll("  memtable:");
    var it = lsm.mem.first();
    while (it) |node| : (it = node.next[0]) {
        try w.print(" {s}{d}", .{ if (node.value == null) "~" else "", node.key });
    }
    try w.writeAll("\n  level 0 (oldest first):");
    for (lsm.l0[0..lsm.l0_len]) |*r| try dumpRun(w, r);
    if (lsm.l0_len == 0) try w.writeAll(" -");
    try w.writeByte('\n');
    for (0..lsm.deepestLevel()) |i| {
        try w.print("  level {d}:", .{i + 1});
        if (lsm.levels[i]) |*r| try dumpRun(w, r) else try w.writeAll(" -");
        try w.writeByte('\n');
    }
}

fn dumpRun(w: *Writer, r: *const lib.run.Run) !void {
    try w.writeAll(" (");
    for (r.slots.items, 0..) |slot, i| {
        if (i > 0) try w.writeByte(' ');
        try w.print("{s}{d}", .{ if (slot.value == null) "~" else "", slot.key });
    }
    try w.writeByte(')');
}

// ------------------------------------------------- 3 to 5. workloads

/// `num / den` rounded to two decimals (half up), by integer arithmetic
/// only, so that Zig and Rust print the same digits. "-" when there is no
/// data.
fn ratio(buf: []u8, num: u64, den: u64) []const u8 {
    if (den == 0) return "-";
    const hundredths = (num * 200 + den) / (den * 2);
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ hundredths / 100, hundredths % 100 }) catch unreachable;
}

/// What the tables leave out. Printed under every table, because a ratio
/// without its limits is the easiest thing in this chapter to misread.
fn limits(w: *Writer, memtable_entries: usize) !void {
    try w.writeAll("Limits of these numbers (ratios are rounded to two decimals):\n");
    try w.writeAll("  * No cache. Each operation reads every block it looks at from the device, index\n");
    try w.writeAll("    levels included, in both structures. \"data blocks per get\" is what is left if\n");
    try w.writeAll("    every index block of either structure is held in RAM.\n");
    try w.writeAll("  * No write-ahead log, and so NOT the same durability. A B+tree write is on the\n");
    try w.print("    device when it returns. An LSM write is in RAM only until the next flush: up to {d}\n", .{memtable_entries});
    try w.writeAll("    writes are lost in a crash. The \"+ 1 log block\" row is computed, not run: it adds\n");
    try w.writeAll("    one block per LSM write, the price of the same promise without group commit.\n");
    try w.writeAll("  * A B+tree with a log and a buffer pool writes a hot page once for many updates,\n");
    try w.writeAll("    so its write column is an upper bound.\n");
}

fn rowCount(w: *Writer, label: []const u8, a: u64, b: u64) !void {
    try w.print("{s:<42}{d:>10}{d:>10}\n", .{ label, a, b });
}

fn rowRatio(w: *Writer, label: []const u8, a_num: u64, a_den: u64, b_num: u64, b_den: u64) !void {
    var a_buf: [32]u8 = undefined;
    var b_buf: [32]u8 = undefined;
    try w.print("{s:<42}{s:>10}{s:>10}\n", .{ label, ratio(&a_buf, a_num, a_den), ratio(&b_buf, b_num, b_den) });
}

fn packedBlocks(keys: u64, per_block: u64) u64 {
    return (keys + per_block - 1) / per_block;
}

fn compare(gpa: Allocator, w: *Writer, wl: bench.Workload, section: usize) !void {
    const cfg = bench.bench_lsm;
    const r = try bench.runWorkload(gpa, wl, bench.bench_order, cfg);
    const b = &r.btree;
    const l = &r.lsm;
    const index = @intFromEnum(lib.device.Kind.index);
    const data = @intFromEnum(lib.device.Kind.data);
    const per_block: u64 = cfg.block_entries;

    try w.print("\n== {d}. Workload: {s} ==\n", .{ section, wl.name });
    try w.print("seed {d}, preload {d} puts, then {d} operations over {d} keys; put/delete/get/scan = {d}/{d}/{d}/{d}\n", .{
        wl.seed,        wl.preload,        wl.count,       wl.key_space,
        wl.weights.put, wl.weights.delete, wl.weights.get, wl.weights.range,
    });
    try w.print("live keys at the end: {d}; answers that differ from the oracle: {d}\n\n", .{ r.live_keys, r.mismatches });

    try w.print("{s:<42}{s:>10}{s:>10}\n", .{ "", "B+tree", "LSM" });
    try rowCount(w, "write operations (put + delete)", b.writes.ops, l.writes.ops);
    try rowCount(w, "  blocks written", b.writes.io.totalWrites(), l.writes.io.totalWrites());
    try rowRatio(w, "  blocks written per write", b.writes.io.totalWrites(), b.writes.ops, l.writes.io.totalWrites(), l.writes.ops);
    try rowRatio(w, "  WRITE AMPLIFICATION (slots per entry)", b.writes.io.totalWrites() * per_block, b.writes.ops, l.writes.io.totalWrites() * per_block, l.writes.ops);
    // Equal durability, computed: the B+tree already has it, the LSM would
    // append to a log and write the log's last block on every operation.
    try rowRatio(w, "    same, + 1 log block per LSM write", b.writes.io.totalWrites() * per_block, b.writes.ops, (l.writes.io.totalWrites() + l.writes.ops) * per_block, l.writes.ops);
    try rowRatio(w, "  blocks read per write", b.writes.io.totalReads(), b.writes.ops, l.writes.io.totalReads(), l.writes.ops);
    try rowCount(w, "  most blocks written by one write", b.writes.max_writes, l.writes.max_writes);
    try rowCount(w, "point lookups (get)", b.gets.ops, l.gets.ops);
    try rowRatio(w, "  READ AMPLIFICATION (blocks per get)", b.gets.io.totalReads(), b.gets.ops, l.gets.io.totalReads(), l.gets.ops);
    try rowRatio(w, "    index blocks per get", b.gets.io.reads[index], b.gets.ops, l.gets.io.reads[index], l.gets.ops);
    try rowRatio(w, "    data blocks per get", b.gets.io.reads[data], b.gets.ops, l.gets.io.reads[data], l.gets.ops);
    try rowCount(w, "short scans", b.scans.ops, l.scans.ops);
    try rowRatio(w, "  entries returned per scan", b.scans.entries, b.scans.ops, l.scans.entries, l.scans.ops);
    try rowRatio(w, "  blocks read per scan", b.scans.io.totalReads(), b.scans.ops, l.scans.io.totalReads(), l.scans.ops);
    // Space amplification = blocks on the device / data blocks that the keys
    // live AT THAT MOMENT would fill if packed with no index and no slack.
    const packed_end = packedBlocks(r.live_keys, per_block);
    try rowCount(w, "blocks on the device at the end", b.blocks, l.blocks);
    try rowCount(w, "  data blocks if the live keys were packed", packed_end, packed_end);
    try rowRatio(w, "  SPACE AMPLIFICATION (at the end)", b.blocks, packed_end, l.blocks, packed_end);
    const b_packed_peak = packedBlocks(b.peak_live_keys, per_block);
    const l_packed_peak = packedBlocks(l.peak_live_keys, per_block);
    try rowCount(w, "most blocks on the device at any moment", b.peak, l.peak);
    try rowCount(w, "  live keys at that moment", b.peak_live_keys, l.peak_live_keys);
    try rowCount(w, "  data blocks if those were packed", b_packed_peak, l_packed_peak);
    try rowRatio(w, "  SPACE AMPLIFICATION (at the peak)", b.peak, b_packed_peak, l.peak, l_packed_peak);

    const s = r.lsm_stats;
    try w.print("B+tree: height {d}. LSM: {d} level(s) below level 0, {d} run(s) in level 0, {d} slots on the device.\n", .{
        r.btree_height, r.lsm_levels, r.lsm_l0_runs, r.lsm_slots,
    });
    try w.print("LSM maintenance: {d} flushes, {d} level-0 compactions, {d} level merges; dropped {d} stale versions, {d} tombstones.\n", .{
        s.flushes, s.l0_compactions, s.level_merges, s.versions_dropped, s.tombstones_dropped,
    });
    try w.print("LSM lookups: {d} runs probed, {d} of those without finding the key, {d} runs skipped by min/max.\n", .{
        s.runs_probed, s.probes_wasted, s.runs_skipped,
    });
    try limits(w, cfg.memtable_entries);
}

fn growthSweep(gpa: Allocator, w: *Writer) !void {
    try w.writeAll("\n== 6. The growth factor is the tuning knob ==\n");
    try w.writeAll("LSM only, insert-heavy workload again, everything else unchanged: the same counting\n");
    try w.writeAll("rule and the same limits as above (no cache, no log, not durable until a flush).\n\n");
    try w.print("{s:<8}{s:>8}{s:>16}{s:>16}{s:>16}{s:>16}\n", .{ "growth", "levels", "write amp", "blocks per get", "blocks per scan", "peak space amp" });
    for ([_]usize{ 2, 4, 8, 16 }) |growth| {
        var cfg = bench.bench_lsm;
        cfg.growth = growth;
        const r = try bench.runWorkload(gpa, bench.workloads[0], bench.bench_order, cfg);
        const l = &r.lsm;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        var b3: [32]u8 = undefined;
        var b4: [32]u8 = undefined;
        try w.print("{d:<8}{d:>8}{s:>16}{s:>16}{s:>16}{s:>16}\n", .{
            growth,
            r.lsm_levels,
            ratio(&b1, l.writes.io.totalWrites() * cfg.block_entries, l.writes.ops),
            ratio(&b2, l.gets.io.totalReads(), l.gets.ops),
            ratio(&b3, l.scans.io.totalReads(), l.scans.ops),
            ratio(&b4, l.peak, packedBlocks(l.peak_live_keys, cfg.block_entries)),
        });
    }
}

test "run prints exactly expected_output.txt" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
