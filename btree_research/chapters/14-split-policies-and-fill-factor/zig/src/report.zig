//! Chapter 14: the experiment. Four insert workloads, four split policies,
//! and a text report of what each policy did to the pages.
//!
//! Everything here writes to a `*std.Io.Writer`, so `main` can point it at
//! stdout and the test can point it at memory and compare with
//! expected_output.txt.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const split = @import("split.zig");
const pages = @import("pages.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;

const Policy = split.Policy;
const Tree = pages.Tree;

pub const page_capacity: u32 = 4096;

/// The order in which keys arrive. The row id (tid) of the i-th insert is
/// always i: rows are numbered in arrival order, like heap TIDs mostly are.
pub const Workload = enum {
    /// key = i: a sequence, a timestamp, an auto-increment id.
    ascending,
    /// keys 0..n in shuffled order: every page is hit equally often.
    random,
    /// n/8 distinct keys picked at random: short runs of equal keys.
    dup_groups,
    /// n/1000 + 2 distinct keys: each key fills many pages.
    dup_heavy,

    pub fn label(self: Workload) []const u8 {
        return switch (self) {
            .ascending => "ascending",
            .random => "random",
            .dup_groups => "dup-groups",
            .dup_heavy => "dup-heavy",
        };
    }
};

pub const all_workloads = [_]Workload{ .ascending, .random, .dup_groups, .dup_heavy };
pub const all_policies = pages.all_policies;

/// "half", "fill-90", "rightmost-90", "adaptive-90".
pub fn policyLabel(buf: []u8, policy: Policy) []const u8 {
    return switch (policy) {
        .half => "half",
        .fill => |ff| std.fmt.bufPrint(buf, "fill-{d}", .{ff}) catch unreachable,
        .rightmost => |ff| std.fmt.bufPrint(buf, "rightmost-{d}", .{ff}) catch unreachable,
        .adaptive => |ff| std.fmt.bufPrint(buf, "adaptive-{d}", .{ff}) catch unreachable,
    };
}

/// Insert `n` cells of 40 to 120 bytes into a fresh tree. The caller owns the
/// tree. One PRNG, seeded with `seed`, drives keys and sizes in a fixed draw
/// order (shuffle first if any, then per insert: key if any, then size), so
/// the Rust port and the JavaScript model replay exactly the same inserts.
pub fn runWorkload(gpa: Allocator, workload: Workload, policy: Policy, n: u64, seed: u64) !Tree {
    var tree: Tree = try .init(gpa, page_capacity, policy);
    errdefer tree.deinit();
    var rng = SplitMix64.init(seed);

    var order: []u64 = &.{};
    defer gpa.free(order);
    if (workload == .random) {
        order = try gpa.alloc(u64, n);
        for (order, 0..) |*k, i| k.* = i;
        rng.shuffle(order);
    }

    for (0..n) |i| {
        const key: u64 = switch (workload) {
            .ascending => i,
            .random => order[i],
            .dup_groups => rng.below(n / 8),
            .dup_heavy => rng.below(n / 1000 + 2),
        };
        const size: u16 = @intCast(rng.range(40, 121));
        _ = try tree.put(key, i, size);
    }
    return tree;
}

fn writePercent(w: *Writer, permille: u64) Writer.Error!void {
    try w.print("{d:>3}.{d}%", .{ permille / 10, permille % 10 });
}

/// Part 1: the hand example of the README, one overfull page of capacity 100.
fn writeHandExample(gpa: Allocator, w: *Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    const items = &split.hand_items;
    const cap = split.hand_capacity;

    try w.print("== 1. One split by hand (page capacity {d} bytes) ==\n", .{cap});
    try w.writeAll("imaginary page, (key,tid):bytes, new cell marked *\n ");
    for (items, 0..) |c, i| {
        try w.print(" {s}({d},{d}):{d}", .{ if (i == split.hand_new_index) "*" else "", c.key, c.tid, c.size });
    }
    try w.writeAll("\n\ncandidate split points (cut before index s)\n");
    try w.writeAll("  s  left  right  delta 50:50  delta 90:10  separator\n");
    const cands = try split.candidates(scratch, items, cap);
    for (cands) |c| {
        const fr = items[c.first_right];
        try w.print("{d:>3}  {d:>4}  {d:>5}  {d:>11}  {d:>11}  ", .{
            c.first_right,             c.left_bytes,
            c.right_bytes,             split.deltaOf(c, cap, null),
            split.deltaOf(c, cap, 90),
        });
        if (split.penaltyOf(items, c) == 1) {
            try w.print("({d})      8 bytes\n", .{fr.key});
        } else {
            try w.print("({d},{d})   16 bytes\n", .{ fr.key, fr.tid });
        }
    }

    try w.writeAll("\nchoice when the page is NOT the rightmost page (upper bound 40)\n");
    try writeHandChoices(scratch, w, 40);
    try w.writeAll("\nchoice when the page IS the rightmost page\n");
    try writeHandChoices(scratch, w, null);
}

fn writeHandChoices(scratch: Allocator, w: *Writer, upper_key: ?u64) !void {
    var buf: [32]u8 = undefined;
    for (all_policies) |policy| {
        const c = try split.chooseSplit(scratch, &split.hand_items, split.hand_new_index, .{
            .capacity = split.hand_capacity,
            .upper_key = upper_key,
        }, policy);
        try w.print("  {s:<13} s={d}  left {d:>2}  right {d:>2}  separator {d:>2} bytes  {t}\n", .{
            policyLabel(&buf, policy), c.first_right,          c.left_bytes,
            c.right_bytes,             @as(u8, 8) * c.penalty, c.strategy,
        });
    }
}

/// Part 2: every workload under every policy, at full page size.
fn writeExperiment(gpa: Allocator, w: *Writer, n: u64, seed: u64) !void {
    try w.print("\n== 2. {d} inserts of 40..120 byte cells, page capacity {d} ==\n", .{ n, page_capacity });
    var buf: [32]u8 = undefined;
    for (all_workloads) |workload| {
        var fills: [all_policies.len]pages.Fill = undefined;

        try w.print("\nworkload {s}\n", .{workload.label()});
        try w.writeAll("  policy         pages  avg fill  min fill  splits  default/manydup/single  tid seps  sep bytes\n");
        for (all_policies, 0..) |policy, p| {
            var tree = try runWorkload(gpa, workload, policy, n, seed);
            defer tree.deinit();
            try tree.validate();
            const f = tree.fill();
            fills[p] = f;
            const s = tree.stats.by_strategy;
            try w.print("  {s:<13}  {d:>5}    ", .{ policyLabel(&buf, policy), f.pages });
            try writePercent(w, f.avgPermille(page_capacity));
            try w.writeAll("    ");
            try writePercent(w, @as(u64, f.min_used) * 1000 / page_capacity);
            try w.print("  {d:>6}  {d:>7}/{d:>7}/{d:>6}  {d:>8}  {d:>9}\n", .{
                tree.stats.splits, s[0], s[1], s[2], f.tid_seps, f.sep_bytes,
            });
        }

        try w.writeAll("  pages by fill    0-9  10-  20-  30-  40-  50-  60-  70-  80-  90-100%\n");
        for (all_policies, 0..) |policy, p| {
            try w.print("  {s:<13}", .{policyLabel(&buf, policy)});
            for (fills[p].histogram) |count| try w.print("  {d:>3}", .{count});
            try w.writeAll("\n");
        }
    }
}

/// Part 3: a small run whose complete final state fits on a few lines. The
/// visualization replays it with its own JavaScript model and compares.
pub const scenario_n: u64 = 300;
pub const scenario_seed: u64 = 14;

fn writeScenario(gpa: Allocator, w: *Writer) !void {
    try w.print("\n== 3. Fixed scenario: {d} inserts, seed {d}, bytes used per page in key order ==\n", .{ scenario_n, scenario_seed });
    var buf: [32]u8 = undefined;
    for (all_workloads) |workload| {
        try w.print("workload {s}\n", .{workload.label()});
        for (all_policies) |policy| {
            var tree = try runWorkload(gpa, workload, policy, scenario_n, scenario_seed);
            defer tree.deinit();
            try tree.validate();
            try w.print("  {s:<13}", .{policyLabel(&buf, policy)});
            for (tree.dir.items) |entry| try w.print(" {d}", .{tree.leaves.items[entry.leaf].used});
            try w.writeAll("\n");
        }
    }
}

pub const experiment_n: u64 = 20_000;
pub const experiment_seed: u64 = 2014;

pub fn writeReport(gpa: Allocator, w: *Writer) !void {
    try writeHandExample(gpa, w);
    try writeExperiment(gpa, w, experiment_n, experiment_seed);
    try writeScenario(gpa, w);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the report is exactly expected_output.txt" {
    // build.zig makes ../expected_output.txt importable under this name.
    const expected = @embedFile("expected_output");
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeReport(testing.allocator, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "workloads are deterministic and keep every cell" {
    for (all_workloads) |workload| {
        var a = try runWorkload(testing.allocator, workload, .{ .adaptive = 90 }, 500, 3);
        defer a.deinit();
        var b = try runWorkload(testing.allocator, workload, .{ .adaptive = 90 }, 500, 3);
        defer b.deinit();
        try a.validate();
        try testing.expectEqual(500, a.len);
        try testing.expectEqual(a.fill(), b.fill());
        // The policy changes where cells live, never which cells exist.
        var c = try runWorkload(testing.allocator, workload, .half, 500, 3);
        defer c.deinit();
        try testing.expectEqual(a.fill().used_bytes, c.fill().used_bytes);
        try testing.expectEqual(a.range(0, 500), c.range(0, 500));
    }
}

test "the policies rank as the chapter claims" {
    const gpa = testing.allocator;
    const n = 4000;
    const pagesOf = struct {
        fn f(workload: Workload, policy: Policy) !pages.Fill {
            var tree = try runWorkload(gpa, workload, policy, n, 9);
            defer tree.deinit();
            return tree.fill();
        }
    }.f;
    // Appends: the rightmost rule saves pages, and adaptive inherits it.
    try testing.expect((try pagesOf(.ascending, .{ .rightmost = 90 })).pages < (try pagesOf(.ascending, .half)).pages);
    try testing.expectEqual((try pagesOf(.ascending, .{ .rightmost = 90 })).pages, (try pagesOf(.ascending, .{ .adaptive = 90 })).pages);
    // Random inserts: packing the left page everywhere costs pages.
    try testing.expect((try pagesOf(.random, .{ .fill = 90 })).pages > (try pagesOf(.random, .half)).pages);
    // Duplicates: adaptive needs fewer separators that carry a tid.
    try testing.expect((try pagesOf(.dup_groups, .{ .adaptive = 90 })).tid_seps < (try pagesOf(.dup_groups, .half)).tid_seps);
    try testing.expect((try pagesOf(.dup_heavy, .{ .adaptive = 90 })).pages < (try pagesOf(.dup_heavy, .half)).pages);
}
