//! Chapter 29: zone maps and vector indexes.
//!
//! Library root. `runScenario` prints the chapter's fixed scenario; main.zig
//! sends it to stdout and a test below compares it with expected_output.txt.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const zonemap = @import("zonemap.zig");
pub const zorder = @import("zorder.zig");
pub const ivf = @import("ivf.zig");
pub const SplitMix64 = @import("prng.zig").SplitMix64;

const ZoneMap = zonemap.ZoneMap;
const Filter = zonemap.Filter;
const Ivf = ivf.Ivf;
const Hit = ivf.Hit;

// ---- scenario parameters (the visualization pages use the same numbers) ----
pub const zone_rows = 2000;
pub const zone_chunk = 100;
pub const zone_seed = 29;
pub const grid_side = 16;
pub const blob_seed = 2901;
pub const train_seed = 2902;
pub const query_seed = 2903;
pub const wide_seed = 2904;

pub const Layout = enum { sorted, arrival, shuffled };

/// The same 2000 rows' worth of values in three physical orders.
///   sorted:   v = row number (a column the table is clustered on)
///   arrival:  v = row number + a delay of 0..299 (timestamps that arrive
///             roughly, not exactly, in order)
///   shuffled: 0..1999 in random order (no correlation with position)
pub fn fillLayout(gpa: Allocator, zm: *ZoneMap, layout: Layout) Allocator.Error!void {
    var rng = SplitMix64.init(zone_seed);
    switch (layout) {
        .sorted => for (0..zone_rows) |i| try zm.append(gpa, i),
        .arrival => for (0..zone_rows) |i| try zm.append(gpa, i + rng.below(300)),
        .shuffled => {
            var vs: [zone_rows]u64 = undefined;
            for (&vs, 0..) |*v, i| v.* = i;
            rng.shuffle(&vs);
            try zm.appendSlice(gpa, &vs);
        },
    }
}

const NamedFilter = struct { text: []const u8, filter: Filter };
pub const zone_filters = [_]NamedFilter{
    .{ .text = "v = 777", .filter = .{ .cmp = .{ .op = .eq, .c = 777 } } },
    .{ .text = "v >= 1500", .filter = .{ .cmp = .{ .op = .ge, .c = 1500 } } },
    .{ .text = "v < 250", .filter = .{ .cmp = .{ .op = .lt, .c = 250 } } },
    .{ .text = "400 <= v <= 449", .filter = .{ .between = .{ .lo = 400, .hi = 449 } } },
    .{ .text = "v != 777", .filter = .{ .cmp = .{ .op = .ne, .c = 777 } } },
};

/// n points in 2-D, drawn around `blobs` random centres. Each coordinate is
/// centre + (sum of two uniform draws) - spread, clamped to 0..999, which
/// gives a soft triangular bump without any floating point.
pub fn genBlobs(gpa: Allocator, seed: u64, n: usize, blobs: usize, spread: u64) Allocator.Error![]i32 {
    var rng = SplitMix64.init(seed);
    const centres = try gpa.alloc(i32, blobs * 2);
    defer gpa.free(centres);
    for (centres) |*c| c.* = @intCast(rng.range(150, 850));
    const data = try gpa.alloc(i32, n * 2);
    for (0..n) |i| {
        for (0..2) |j| {
            const offset: i32 = @intCast(rng.below(spread + 1) + rng.below(spread + 1));
            const v = centres[(i % blobs) * 2 + j] + offset - @as(i32, @intCast(spread));
            data[i * 2 + j] = std.math.clamp(v, 0, 999);
        }
    }
    return data;
}

/// Queries that look like the data: a random stored 2-D point moved by up to
/// `jitter` in each coordinate. (Queries far from all data are easy for IVF:
/// the interesting ones fall near a cell boundary.)
pub fn genNearData(gpa: Allocator, seed: u64, data: []const i32, nq: usize, jitter: u64) Allocator.Error![]i32 {
    var rng = SplitMix64.init(seed);
    const queries = try gpa.alloc(i32, nq * 2);
    for (0..nq) |q| {
        const src: usize = @intCast(rng.below(data.len / 2));
        for (0..2) |j| {
            const offset: i32 = @intCast(rng.below(2 * jitter + 1));
            queries[q * 2 + j] = std.math.clamp(data[src * 2 + j] + offset - @as(i32, @intCast(jitter)), 0, 999);
        }
    }
    return queries;
}

pub fn genUniform(gpa: Allocator, seed: u64, n: usize, dim: usize) Allocator.Error![]i32 {
    var rng = SplitMix64.init(seed);
    const data = try gpa.alloc(i32, n * dim);
    for (data) |*x| x.* = @intCast(rng.below(1000));
    return data;
}

pub fn runScenario(gpa: Allocator, w: *Writer) !void {
    try zoneSection(gpa, w);
    try orderSection(w);
    try ivfSection2d(gpa, w);
    try ivfSectionWide(gpa, w);
}

fn zoneSection(gpa: Allocator, w: *Writer) !void {
    try w.print("== 1. zone maps: {d} rows in {d} chunks of {d} ==\n", .{ zone_rows, zone_rows / zone_chunk, zone_chunk });
    try w.writeAll("layout    predicate        skip  all  scan  rows compared  matches\n");
    for ([_]Layout{ .sorted, .arrival, .shuffled }) |layout| {
        var zm = ZoneMap.init(zone_chunk);
        defer zm.deinit(gpa);
        try fillLayout(gpa, &zm, layout);
        try zm.validate();
        for (zone_filters) |nf| {
            const s = zm.scan(nf.filter);
            try w.print("{s:<9} {s:<15} {d:>5} {d:>4} {d:>5} {d:>14} {d:>8}\n", .{
                @tagName(layout), nf.text, s.chunks_skipped, s.chunks_all, s.chunks_scanned, s.rows_compared, s.matches,
            });
        }
    }
    // Maintenance is append-only: new rows widen the last zone or open one.
    var zm = ZoneMap.init(zone_chunk);
    defer zm.deinit(gpa);
    try fillLayout(gpa, &zm, .sorted);
    for (0..150) |i| try zm.append(gpa, 5000 - i);
    try zm.validate();
    const last = zm.zones.items[zm.zones.items.len - 1];
    try w.print("append 150 rows (5000 down to 4851) to 'sorted': {d} chunks, last chunk has {d} rows, min {d}, max {d}\n\n", .{
        zm.zones.items.len, last.count, last.min, last.max,
    });
}

fn orderSection(w: *Writer) !void {
    try w.print("== 2. one sort order for two dimensions: touching cells on a {d} x {d} grid ==\n", .{ grid_side, grid_side });
    try w.print("order      pairs  gap >= {d}  largest gap  sum of gaps\n", .{grid_side});
    for ([_]zorder.Curve{ .row_major, .z_order }) |curve| {
        const s = zorder.gapStats(curve, grid_side);
        try w.print("{s:<9} {d:>6} {d:>10} {d:>12} {d:>12}\n", .{ @tagName(curve), s.pairs, s.far_pairs, s.max_gap, s.sum_gap });
    }
    try w.writeAll("\n");
}

/// Run every query at every nprobe in `probes` and print the recall table.
fn recallTable(gpa: Allocator, w: *Writer, index: *const Ivf, data: []const i32, queries: []const i32, comptime k: usize, probes: []const usize) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const dim = index.dim;
    const nq = queries.len / dim;
    try w.writeAll("nprobe  vectors scanned  of brute force  true neighbours found  recall\n");
    for (probes) |nprobe| {
        var scanned: u64 = 0;
        var found: u64 = 0;
        for (0..nq) |q| {
            // One arena for all queries: reset keeps the memory, so after the
            // first query the ranking buffer costs no allocation at all.
            _ = arena_state.reset(.retain_capacity);
            const query = queries[q * dim ..][0..dim];
            var want: [k]Hit = undefined;
            var got: [k]Hit = undefined;
            const want_len = ivf.flatSearch(data, dim, query, &want);
            const stats = try index.search(arena_state.allocator(), query, nprobe, &got);
            scanned += stats.vectors_scanned;
            found += ivf.overlap(got[0..stats.hits], want[0..want_len]);
        }
        const total = nq * k;
        try w.print("{d:>6} {d:>16} {d:>15} {d:>15} / {d:<4} {d:>6}%\n", .{
            nprobe, scanned, nq * (data.len / dim), found, total, found * 100 / total,
        });
    }
}

fn ivfSection2d(gpa: Allocator, w: *Writer) !void {
    const n = 240;
    const nlist = 8;
    const k = 5;
    const nq = 24;
    const data = try genBlobs(gpa, blob_seed, n, 6, 110);
    defer gpa.free(data);
    const queries = try genNearData(gpa, query_seed, data, nq, 40);
    defer gpa.free(queries);
    var index = try Ivf.build(gpa, data, 2, nlist, train_seed, 50);
    defer index.deinit(gpa);
    try index.validate(data);

    try w.print("== 3. IVF in 2 dimensions: {d} points, {d} lists, k = {d}, {d} queries ==\n", .{ n, nlist, k, nq });
    try w.print("k-means: assignments stopped changing after {d} centroid updates\n", .{index.iterations});
    try w.writeAll("list  size  centroid\n");
    for (0..nlist) |c| {
        const cen = index.centroid(c);
        try w.print("{d:>4} {d:>5}  ({d}, {d})\n", .{ c, index.listLen(c), cen[0], cen[1] });
    }
    try recallTable(gpa, w, &index, data, queries, k, &.{ 1, 2, 3, 4, 8 });

    // The boundary problem, on one concrete query: the first query whose
    // true nearest neighbour is not in the list of its nearest centroid.
    var order: [nlist]Hit = undefined;
    for (0..nq) |q| {
        const query = queries[q * 2 ..][0..2];
        var best: [1]Hit = undefined;
        _ = ivf.flatSearch(data, 2, query, &best);
        index.rankLists(query, &order);
        const home = index.assign[best[0].id];
        if (home == order[0].id) continue;
        var rank: usize = 0;
        while (order[rank].id != home) rank += 1;
        try w.print("first miss: query {d} at ({d}, {d})\n", .{ q, query[0], query[1] });
        try w.print("  true nearest: id {d} at ({d}, {d}), dist2 {d}, stored in list {d}\n", .{
            best[0].id, data[best[0].id * 2], data[best[0].id * 2 + 1], best[0].dist, home,
        });
        try w.print("  nearest centroid: list {d} (dist2 {d}); list {d} ranks {d} (dist2 {d})\n", .{
            order[0].id, order[0].dist, home, rank + 1, order[rank].dist,
        });
        try w.print("  so nprobe must be at least {d} to find it\n", .{rank + 1});
        break;
    }
    try w.writeAll("\n");
}

fn ivfSectionWide(gpa: Allocator, w: *Writer) !void {
    const n = 2000;
    const dim = 16;
    const nlist = 16;
    const k = 10;
    const nq = 50;
    const data = try genUniform(gpa, wide_seed, n, dim);
    defer gpa.free(data);
    const queries = try genUniform(gpa, wide_seed + 1, nq, dim);
    defer gpa.free(queries);
    var index = try Ivf.build(gpa, data, dim, nlist, train_seed, 25);
    defer index.deinit(gpa);
    try index.validate(data);

    try w.print("== 4. IVF in {d} dimensions: {d} uniform points, {d} lists, k = {d}, {d} queries ==\n", .{ dim, n, nlist, k, nq });
    try w.print("k-means: {d} centroid updates (limit 25)\n", .{index.iterations});
    var smallest: u32 = std.math.maxInt(u32);
    var largest: u32 = 0;
    for (0..nlist) |c| {
        smallest = @min(smallest, index.listLen(c));
        largest = @max(largest, index.listLen(c));
    }
    try w.print("list sizes: smallest {d}, largest {d}\n", .{ smallest, largest });
    try recallTable(gpa, w, &index, data, queries, k, &.{ 1, 2, 4, 8, 16 });
}

test "run output matches expected_output.txt" {
    var aw: Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try runScenario(std.testing.allocator, &aw.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), aw.written());
}

test "layouts: same row count, sorted and shuffled hold the same values" {
    const gpa = std.testing.allocator;
    var sums: [3]u64 = @splat(0);
    for ([_]Layout{ .sorted, .arrival, .shuffled }, 0..) |layout, i| {
        var zm = ZoneMap.init(zone_chunk);
        defer zm.deinit(gpa);
        try fillLayout(gpa, &zm, layout);
        try zm.validate();
        try std.testing.expectEqual(zone_rows, zm.values.items.len);
        for (zm.values.items) |v| sums[i] += v;
    }
    try std.testing.expectEqual(sums[0], sums[2]);
}

test {
    // Pull in the tests of every file of the chapter.
    _ = zonemap;
    _ = zorder;
    _ = ivf;
    _ = @import("prng.zig");
}
