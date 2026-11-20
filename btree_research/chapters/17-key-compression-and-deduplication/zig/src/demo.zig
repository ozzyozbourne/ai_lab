//! The chapter's deterministic program output: separators by hand, a small
//! fixed scenario (also embedded in the visualization), and fanout / space
//! measurements for the four combinations of truncation and deduplication.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const t = @import("tree.zig");
const Tree = t.Tree;
const SplitMix64 = @import("prng.zig").SplitMix64;

pub const Put = struct { key: []const u8, tid: t.Tid };

/// The fixed scenario: an index on a "fruit" column of a small table.
/// TIDs are row numbers; most rows arrive in order, the last few do not
/// (think of updates that reuse old row slots).
pub const scenario = [_]Put{
    .{ .key = "cherry", .tid = 1 },        .{ .key = "apple", .tid = 2 },       .{ .key = "blackberry", .tid = 3 },
    .{ .key = "apple", .tid = 4 },         .{ .key = "fig", .tid = 5 },         .{ .key = "blueberry", .tid = 6 },
    .{ .key = "apple", .tid = 7 },         .{ .key = "cherry", .tid = 8 },      .{ .key = "grape", .tid = 9 },
    .{ .key = "apple", .tid = 10 },        .{ .key = "banana", .tid = 11 },     .{ .key = "cherry", .tid = 12 },
    .{ .key = "apple", .tid = 13 },        .{ .key = "elderberry", .tid = 14 }, .{ .key = "apple", .tid = 16 },
    .{ .key = "cherry", .tid = 17 },       .{ .key = "apricot", .tid = 18 },    .{ .key = "apple", .tid = 19 },
    .{ .key = "cranberry", .tid = 20 },    .{ .key = "cherry", .tid = 21 },     .{ .key = "apple", .tid = 22 },
    .{ .key = "date", .tid = 23 },         .{ .key = "cherry", .tid = 24 },     .{ .key = "apple", .tid = 25 },
    .{ .key = "grapefruit", .tid = 26 },   .{ .key = "cherry", .tid = 27 },     .{ .key = "apple", .tid = 28 },
    .{ .key = "blackcurrant", .tid = 29 }, .{ .key = "cherry", .tid = 30 },     .{ .key = "apple", .tid = 31 },
    .{ .key = "avocado", .tid = 32 },      .{ .key = "cherry", .tid = 33 },     .{ .key = "guava", .tid = 34 },
    .{ .key = "apple", .tid = 35 },        .{ .key = "cherry", .tid = 36 },     .{ .key = "coconut", .tid = 37 },
    .{ .key = "apple", .tid = 15 },        .{ .key = "cherry", .tid = 9 },      .{ .key = "apple", .tid = 1 },
};
pub const scenario_page_size = 256;

fn writeSep(w: *Io.Writer, sep: ?t.Sep, infinity: []const u8) Io.Writer.Error!void {
    const s = sep orelse return w.writeAll(infinity);
    try w.print("\"{s}\"", .{s.key});
    if (s.tid) |tid| try w.print("@{d}", .{tid});
}

/// Depth-first dump. The visualization's JavaScript model prints the same
/// text for the same scenario; its self-test compares the two.
pub fn dump(w: *Io.Writer, tree: *const Tree, id: t.PageId, depth: usize) Io.Writer.Error!void {
    const p = &tree.pages.items[id];
    try w.splatByteAll(' ', depth * 2);
    try w.print("page {d} {s} low=", .{ id, if (p.is_leaf) "leaf" else "internal" });
    try writeSep(w, p.low, "-inf");
    try w.writeAll(" high=");
    try writeSep(w, p.high, "+inf");
    try w.print(" used={d}/{d}\n", .{ p.usedBytes(), tree.cfg.page_size });
    try w.splatByteAll(' ', depth * 2 + 2);
    if (p.is_leaf) {
        for (p.cells.items, 0..) |c, i| {
            if (i != 0) try w.writeByte(' ');
            try w.print("{s}@", .{c.key});
            if (c.tids.len == 1) {
                try w.print("{d}", .{c.tids[0]});
            } else {
                for (c.tids, 0..) |tid, j| try w.print("{c}{d}", .{ @as(u8, if (j == 0) '[' else ','), tid });
                try w.writeByte(']');
            }
        }
        try w.writeByte('\n');
        return;
    }
    try w.writeAll("separators:");
    for (p.seps.items) |s| {
        try w.writeByte(' ');
        try writeSep(w, s, "");
    }
    try w.writeByte('\n');
    for (p.children.items) |child| try dump(w, tree, child, depth + 1);
}

/// num / den with one decimal, computed in integers so that Zig and Rust
/// print the same digits.
fn tenths(buf: []u8, num: usize, den: usize) []const u8 {
    if (den == 0) return "-";
    const x = (num * 10 + den / 2) / den;
    return std.fmt.bufPrint(buf, "{d}.{d}", .{ x / 10, x % 10 }) catch unreachable;
}

fn configName(cfg: t.Config) []const u8 {
    if (cfg.truncate) return if (cfg.dedup) "truncate + dedup" else "truncate";
    return if (cfg.dedup) "dedup" else "neither";
}

const table_header = "  config            height  leaves  internal  fanout  sep bytes  bytes/entry  leaf splits  dedup passes\n";

fn statsRow(w: *Io.Writer, tree: *const Tree) Io.Writer.Error!void {
    const s = tree.stats();
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    try w.print("  {s:<16}  {d:>6}  {d:>6}  {d:>8}  {s:>6}  {s:>9}  {s:>11}  {d:>11}  {d:>12}\n", .{
        configName(tree.cfg),                      s.height,                         s.leaf_pages,                         s.internal_pages,
        tenths(&b1, s.children, s.internal_pages), tenths(&b2, s.sep_bytes, s.seps), tenths(&b3, s.used_bytes, s.entries), tree.counters.leaf_splits,
        tree.counters.dedup_passes,
    });
}

const Workload = enum { hashes, categories, paths };

fn workloadKey(buf: []u8, rng: *SplitMix64, workload: Workload) []const u8 {
    return switch (workload) {
        // 32 hex digits, like a content hash: neighbours differ early.
        .hashes => blk: {
            const a = rng.nextU64();
            const b = rng.nextU64();
            break :blk std.fmt.bufPrint(buf, "{x:0>16}{x:0>16}", .{ a, b }) catch unreachable;
        },
        // 50 distinct values, 400 rows each on average.
        .categories => std.fmt.bufPrint(buf, "category-{d:0>2}", .{rng.below(50)}) catch unreachable,
        // Hierarchical keys: neighbours share a long prefix and differ late.
        .paths => blk: {
            const user = rng.below(2000);
            const order = rng.below(10000);
            break :blk std.fmt.bufPrint(buf, "user/{d:0>6}/order/{d:0>6}", .{ user, order }) catch unreachable;
        },
    };
}

fn measure(gpa: Allocator, w: *Io.Writer, workload: Workload, n: usize) !void {
    try w.writeAll(table_header);
    for ([_]t.Config{
        .{ .truncate = false, .dedup = false },
        .{ .truncate = true, .dedup = false },
        .{ .truncate = false, .dedup = true },
        .{ .truncate = true, .dedup = true },
    }) |cfg| {
        var tree = try Tree.init(gpa, cfg);
        defer tree.deinit();
        var rng = SplitMix64.init(17); // same keys for every configuration
        var buf: [40]u8 = undefined;
        for (0..n) |i| _ = try tree.put(workloadKey(&buf, &rng, workload), i);
        try tree.validate();
        try statsRow(w, &tree);
    }
}

pub fn run(gpa: Allocator, w: *Io.Writer) !void {
    try w.writeAll("== 1. Separators are not keys ==\n");
    try w.writeAll("  last on left       first on right     full separator     truncated separator\n");
    const Pair = struct { left: Put, right: Put };
    for ([_]Pair{
        .{ .left = .{ .key = "banana", .tid = 11 }, .right = .{ .key = "blackberry", .tid = 3 } },
        .{ .left = .{ .key = "blackberry", .tid = 3 }, .right = .{ .key = "blueberry", .tid = 6 } },
        .{ .left = .{ .key = "grape", .tid = 9 }, .right = .{ .key = "grapefruit", .tid = 26 } },
        .{ .left = .{ .key = "date", .tid = 23 }, .right = .{ .key = "dates", .tid = 40 } },
        .{ .left = .{ .key = "cherry", .tid = 12 }, .right = .{ .key = "cherry", .tid = 17 } },
    }) |pair| {
        var lt = [_]t.Tid{pair.left.tid};
        var rt = [_]t.Tid{pair.right.tid};
        const l: t.LeafCell = .{ .key = pair.left.key, .tids = &lt };
        const r: t.LeafCell = .{ .key = pair.right.key, .tids = &rt };
        var cols: [4][32]u8 = undefined;
        var texts: [4][]const u8 = undefined;
        const seps = [4]t.Sep{
            .{ .key = l.key, .tid = l.tids[0] },
            .{ .key = r.key, .tid = r.tids[0] },
            t.separator(false, l, r),
            t.separator(true, l, r),
        };
        for (seps, 0..) |s, i| {
            var cw: Io.Writer = .fixed(&cols[i]);
            try writeSep(&cw, s, "");
            texts[i] = cw.buffered();
        }
        try w.print("  {s:<17}  {s:<17}  {s:<17}  {s}\n", .{ texts[0], texts[1], texts[2], texts[3] });
    }

    try w.print("\n== 2. Fixed scenario: {d} puts, page_size = {d} ==\n", .{ scenario.len, scenario_page_size });
    var tree = try Tree.init(gpa, .{ .page_size = scenario_page_size });
    defer tree.deinit();
    for (scenario) |p| _ = try tree.put(p.key, p.tid);
    try tree.validate();
    try dump(w, &tree, tree.root, 0);
    try w.print("  posting list splits (a TID landed inside a posting list): {d}\n", .{tree.counters.posting_swaps});
    try w.writeAll("\n  The same puts under each configuration:\n");
    try w.writeAll(table_header);
    for ([_]t.Config{
        .{ .page_size = scenario_page_size, .truncate = false, .dedup = false },
        .{ .page_size = scenario_page_size, .truncate = true, .dedup = false },
        .{ .page_size = scenario_page_size, .truncate = false, .dedup = true },
        .{ .page_size = scenario_page_size, .truncate = true, .dedup = true },
    }) |cfg| {
        var other = try Tree.init(gpa, cfg);
        defer other.deinit();
        for (scenario) |p| _ = try other.put(p.key, p.tid);
        try other.validate();
        try statsRow(w, &other);
    }

    try w.writeAll("\n== 3. Searching through truncated separators ==\n");
    for ([_][]const u8{ "apple", "blueberry", "cherry", "c", "coconut", "kiwi" }) |key| {
        try w.print("  get(\"{s}\"): page {d}", .{ key, tree.root });
        var id = tree.root;
        while (!tree.pages.items[id].is_leaf) {
            const page = &tree.pages.items[id];
            const i = Tree.childIndex(page, key, 0);
            id = page.children.items[i];
            try w.print(" -> child {d} = page {d}", .{ i, id });
        }
        const tids = try tree.get(gpa, key);
        defer gpa.free(tids);
        try w.writeAll(" -> [");
        for (tids, 0..) |tid, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", tid });
        try w.writeAll("]\n");
    }

    try w.writeAll("\n== 4. Measurements, page_size = 4096 ==\n");
    try w.writeAll("A. 20000 unique 32-byte keys (hex hashes), random order\n");
    try measure(gpa, w, .hashes, 20000);
    try w.writeAll("B. 20000 rows over 50 distinct keys (\"category-NN\")\n");
    try measure(gpa, w, .categories, 20000);
    try w.writeAll("C. 20000 hierarchical keys (\"user/NNNNNN/order/NNNNNN\"), random order\n");
    try measure(gpa, w, .paths, 20000);
    try w.writeAll(
        \\
        \\fanout      = average number of children per internal page
        \\sep bytes   = average separator payload in internal pages (key bytes, plus 6 when a TID is kept)
        \\bytes/entry = bytes in use on all pages / number of (key, TID) entries
        \\
    );
}
