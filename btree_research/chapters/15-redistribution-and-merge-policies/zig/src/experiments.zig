//! The chapter's `run` program: a fixed hand-sized scenario, then the policy
//! comparisons. Everything is deterministic and printed with integers only,
//! so the Zig and Rust programs produce the same bytes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const pages = @import("pages.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;
const Tree = pages.Tree;

pub const Error = Allocator.Error || Writer.Error || error{ CellTooLarge, Invalid };

/// Print one redistribution: the cells of each page with the page totals.
fn printStrip(w: *Writer, label: []const u8, sizes: []const u32, ends: []const u32) Writer.Error!void {
    try w.print("  {s:<10}", .{label});
    var first: u32 = 0;
    for (ends, 0..) |end, p| {
        if (p != 0) try w.writeAll(" |");
        var used: u32 = 0;
        for (sizes[first..end]) |s| {
            try w.print(" {d}", .{s});
            used += s;
        }
        try w.print(" ={d}", .{used});
        first = end;
    }
    try w.writeAll("\n");
}

/// Part 1: `packLeft` and `evenOut` on three hand-made sibling groups.
fn redistributionByHand(scratch: Allocator, w: *Writer) Error!void {
    const Case = struct { name: []const u8, sizes: []const u32, ends: []const u32 };
    const cases = [_]Case{
        .{ .name = "redistribute: the middle page is overfull, its neighbours have room", .sizes = &.{ 20, 20, 20, 30, 20, 20, 20, 25, 25, 10, 10 }, .ends = &.{ 3, 8, 11 } },
        .{ .name = "split: three full pages and one cell too many", .sizes = &.{ 25, 25, 25, 25, 20, 20, 20, 20, 20, 15, 25, 25, 25, 25 }, .ends = &.{ 4, 10, 14 } },
        .{ .name = "merge: three pages that are mostly free", .sizes = &.{ 20, 15, 10, 25, 20, 30, 10 }, .ends = &.{ 2, 4, 7 } },
    };
    try w.writeAll("== 1. Redistribution by hand (capacity 100) ==\n");
    for (cases) |case| {
        try w.print("{s}\n", .{case.name});
        try printStrip(w, "before", case.sizes, case.ends);
        const ends = try pages.packLeft(scratch, case.sizes, 100);
        try printStrip(w, "pack left", case.sizes, ends);
        pages.evenOut(case.sizes, ends);
        try printStrip(w, "even out", case.sizes, ends);
        try w.print("  pages: {d} in, {d} out\n", .{ case.ends.len, ends.len });
    }
}

const Step = struct { text: []const u8, puts: []const pages.Cell = &.{}, deletes: []const u64 = &.{} };

/// The fixed scenario. The visualization replays exactly these steps and
/// checks its final picture against the one printed here.
pub const scenario = [_]Step{
    .{ .text = "put 10 20 30 40 (25 bytes each): one full leaf", .puts = &.{ .{ .key = 10, .size = 25 }, .{ .key = 20, .size = 25 }, .{ .key = 30, .size = 25 }, .{ .key = 40, .size = 25 } } },
    .{ .text = "put 50: append fast path, nothing moves", .puts = &.{.{ .key = 50, .size = 25 }} },
    .{ .text = "put 60 70 80: the right-most leaf fills up", .puts = &.{ .{ .key = 60, .size = 20 }, .{ .key = 70, .size = 30 }, .{ .key = 80, .size = 25 } } },
    .{ .text = "put 35: p0 overflows, 2 siblings in, 3 out (split)", .puts = &.{.{ .key = 35, .size = 20 }} },
    .{ .text = "put 15: p0 overflows again, 3 in, 3 out (redistribution)", .puts = &.{.{ .key = 15, .size = 20 }} },
    .{ .text = "delete 70: p2 is more than 2/3 free, 3 in, 3 out (redistribution)", .deletes = &.{70} },
    .{ .text = "delete 80: 3 in, 2 out (merge), p2 goes to the free list", .deletes = &.{80} },
};

fn fixedScenario(gpa: Allocator, w: *Writer) Error!void {
    try w.writeAll("\n== 2. Fixed scenario (capacity 100, 3 siblings, quick append, merge below 1/3) ==\n");
    var tree: Tree = try .init(gpa, .{ .capacity = 100 });
    defer tree.deinit();
    for (scenario) |step| {
        for (step.puts) |cell| try tree.put(cell.key, cell.size);
        for (step.deletes) |key| _ = tree.delete(key);
        try tree.validate();
        try w.print("{s}\n", .{step.text});
        try tree.dump(w);
    }
    // Reads do not care how the cells are spread over the pages.
    try w.print("get 35 -> {?d}, get 70 -> {?d}, range [20, 50) ->", .{ tree.get(35), tree.get(70) });
    var found: std.ArrayList(pages.Cell) = .empty;
    defer found.deinit(gpa);
    try tree.range(gpa, 20, 50, &found);
    for (found.items) |cell| try w.print(" {d}", .{cell.key});
    try w.writeAll("\n");
    const s = tree.stats;
    try w.print("stats: balances={d} quick_appends={d} allocated={d} freed={d} leaf_writes={d} parent_writes={d} moved={d} moved_to_old={d}\n", .{
        s.balances, s.quick_appends, s.pages_allocated, s.pages_freed, s.leaf_writes, s.parent_writes, s.cells_moved, s.cells_moved_to_old,
    });
}

pub const key_count = 20_000;

/// Cell size for a key: 40..200 bytes, fixed per key so that every policy
/// sees the same cells whatever the insertion order.
pub fn sizeOf(key: u64) u32 {
    var rng = SplitMix64.init(key);
    return @intCast(40 + rng.below(161));
}

/// Keys 1..key_count, shuffled when `seed` is given.
fn makeKeys(gpa: Allocator, seed: ?u64) Allocator.Error![]u64 {
    const keys = try gpa.alloc(u64, key_count);
    for (keys, 1..) |*k, i| k.* = i;
    if (seed) |s| {
        var rng = SplitMix64.init(s);
        rng.shuffle(keys);
    }
    return keys;
}

fn printRow(w: *Writer, label: []const u8, tree: *const Tree, since: pages.Stats) Writer.Error!void {
    const s = tree.stats;
    const fill = tree.fillPermille();
    try w.print("{s:<22}{d:>6}{d:>5}.{d}%{d:>9}{d:>8}{d:>8}{d:>9}{d:>9}\n", .{
        label,                                           tree.childCount(),                 fill / 10,                         fill % 10,
        s.balances - since.balances,                     s.leaf_writes - since.leaf_writes, s.pages_freed - since.pages_freed, s.cells_moved - since.cells_moved,
        s.cells_moved_to_old - since.cells_moved_to_old,
    });
}

const table_header = "policy                 pages   fill balances  writes   freed    moved   to old\n";

const InsertPolicy = struct { label: []const u8, siblings: u8, quick: bool };
const insert_policies = [_]InsertPolicy{
    .{ .label = "split alone", .siblings = 1, .quick = false },
    .{ .label = "split alone + quick", .siblings = 1, .quick = true },
    .{ .label = "balance 2", .siblings = 2, .quick = false },
    .{ .label = "balance 3", .siblings = 3, .quick = false },
    .{ .label = "balance 3 + quick", .siblings = 3, .quick = true },
};

fn insertPolicies(gpa: Allocator, w: *Writer) Error!void {
    try w.print("\n== 3. Overflow policies: {d} inserts, cells of 40..200 bytes, capacity 4096 ==\n", .{key_count});
    const orders = [_]struct { name: []const u8, seed: ?u64 }{
        .{ .name = "ascending keys", .seed = null },
        .{ .name = "random order", .seed = 15 },
    };
    for (orders) |order| {
        const keys = try makeKeys(gpa, order.seed);
        defer gpa.free(keys);
        try w.print("-- {s} --\n{s}", .{ order.name, table_header });
        for (insert_policies) |policy| {
            var tree: Tree = try .init(gpa, .{ .insert_siblings = policy.siblings, .quick_append = policy.quick, .merge = .never });
            defer tree.deinit();
            for (keys) |key| try tree.put(key, sizeOf(key));
            try tree.validate();
            try printRow(w, policy.label, &tree, .{});
        }
    }
}

const MergeRow = struct { label: []const u8, merge: pages.MergePolicy };
const merge_policies = [_]MergeRow{
    .{ .label = "never", .merge = .never },
    .{ .label = "at empty", .merge = .at_empty },
    .{ .label = "below 1/3 (balance 3)", .merge = .below_third },
    .{ .label = "below 1/2 (balance 3)", .merge = .below_half },
};

fn buildRandom(gpa: Allocator, merge: pages.MergePolicy) Error!Tree {
    const keys = try makeKeys(gpa, 15);
    defer gpa.free(keys);
    var tree: Tree = try .init(gpa, .{ .merge = merge });
    errdefer tree.deinit();
    for (keys) |key| try tree.put(key, sizeOf(key));
    return tree;
}

fn mergePolicies(gpa: Allocator, w: *Writer) Error!void {
    try w.print("\n== 4. Underflow policies (tree built by {d} random inserts, balance 3 + quick) ==\n", .{key_count});
    try w.print("-- delete 90% of the keys in random order (counters: the deletes only) --\n{s}", .{table_header});
    for (merge_policies) |policy| {
        var tree = try buildRandom(gpa, policy.merge);
        defer tree.deinit();
        const since = tree.stats;
        const victims = try makeKeys(gpa, 16);
        defer gpa.free(victims);
        for (victims[0 .. key_count / 10 * 9]) |key| _ = tree.delete(key);
        try tree.validate();
        try printRow(w, policy.label, &tree, since);
    }
    try w.print("-- delete the 90% smallest keys, a queue being drained --\n{s}", .{table_header});
    for (merge_policies) |policy| {
        var tree = try buildRandom(gpa, policy.merge);
        defer tree.deinit();
        const since = tree.stats;
        for (1..key_count / 10 * 9 + 1) |key| _ = tree.delete(key);
        try tree.validate();
        try printRow(w, policy.label, &tree, since);
    }
    try w.print("-- steady churn: {d} times, toggle a random key (delete it if present, else insert it) --\n{s}", .{ 2 * key_count, table_header });
    for (merge_policies) |policy| {
        var tree = try buildRandom(gpa, policy.merge);
        defer tree.deinit();
        const since = tree.stats;
        var rng = SplitMix64.init(17);
        for (0..2 * key_count) |_| {
            const key = rng.range(1, key_count + 1);
            if (!tree.delete(key)) try tree.put(key, sizeOf(key));
        }
        try tree.validate();
        try printRow(w, policy.label, &tree, since);
    }
}

/// Everything `zig build run` prints.
pub fn writeReport(gpa: Allocator, w: *Writer) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    try redistributionByHand(scratch.allocator(), w);
    try fixedScenario(gpa, w);
    try insertPolicies(gpa, w);
    try mergePolicies(gpa, w);
}
