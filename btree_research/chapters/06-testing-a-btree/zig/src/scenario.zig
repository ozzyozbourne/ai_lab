//! The fixed scenario printed by `zig build run` (and by `cargo run`, byte
//! for byte). The chapter README quotes this output and the visualization
//! reproduces part 4 with a JavaScript port of the fuzzer.
const std = @import("std");
const Allocator = std.mem.Allocator;
const btree = @import("base_btree.zig");
const pool = @import("base_pool.zig");
const coverage = @import("coverage.zig");
const fuzz = @import("fuzz.zig");
const minimize = @import("minimize.zig").minimize;
const FaultAllocator = @import("fault_alloc.zig").FaultAllocator;

/// Node orders the sweep runs: the smallest legal one, the guide's default,
/// and one odd and one even order above it (odd and even split differently).
pub const orders = [_]usize{ 3, 4, 5, 6 };
pub const sweep_seeds = 150;
pub const hunt_seeds = 200;
pub const bugs = [_]btree.Bug{ .split_wrong_value, .merge_leaks_node, .borrow_forgets_child };

/// One allocation per node, so the allocator wrapper sees every node.
pub fn Tree(comptime M: usize, comptime bug: btree.Bug) type {
    return btree.BTreeWith(M, pool.DirectNodes, bug);
}

pub fn run(gpa: Allocator, w: *std.Io.Writer) !void {
    try w.writeAll("== 1. One seed is one test case ==\n");
    for ([_]u64{ 1, 2, 3 }) |seed| {
        const case = fuzz.swarm(seed);
        try printCase(w, case);
        const steps = try fuzz.generate(gpa, case);
        defer gpa.free(steps);
        var totals: fuzz.Totals = .{};
        const failure = try fuzz.replay(Tree(4, .none), gpa, steps, .{}, &totals);
        try w.print("  M=4: {d} steps replayed, {d} allocation failures injected, max height {d}, max keys {d}: {s}\n", .{
            totals.steps, totals.injected_faults, totals.max_height, totals.max_keys, if (failure == null) "ok" else "FAILED",
        });
    }

    try w.print("\n== 2. Swarm sweep of the correct tree: seeds 1..{d} at each order ==\n", .{sweep_seeds});
    var all: fuzz.Totals = .{};
    inline for (orders) |M| {
        var totals: fuzz.Totals = .{};
        const found = try fuzz.hunt(Tree(M, .none), gpa, 1, sweep_seeds, .{}, &totals);
        try w.print("M={d}: {d} cases, {d} steps, {d} injected allocation failures, max height {d}, coverage {d}/{d}: {s}\n", .{
            M,                 totals.cases,                 totals.steps,          totals.injected_faults,
            totals.max_height, totals.coverage.reached(),    coverage.point_count,  if (found == null) "ok" else "FAILED",
        });
        all.coverage.add(&totals.coverage);
    }
    try w.writeAll("hits per coverage point, all orders together:\n");
    try printCoverage(w, &all.coverage);
    // Tiny nodes are a test parameter, not a detail: the same seeds with 31
    // keys per node never touch an interior node.
    var large: fuzz.Totals = .{};
    _ = try fuzz.hunt(Tree(32, .none), gpa, 1, sweep_seeds, .{}, &large);
    try printReach(w, "the same seeds at M=32", &large);

    try w.print("\n== 3. A fixed mix against the swarm (M = 4, seeds 1..{d}) ==\n", .{sweep_seeds});
    var fixed: fuzz.Totals = .{};
    for (1..sweep_seeds + 1) |seed| {
        const steps = try fuzz.generate(gpa, fuzz.fixedMix(seed));
        defer gpa.free(steps);
        _ = try fuzz.replay(Tree(4, .none), gpa, steps, .{}, &fixed);
    }
    var swarmed: fuzz.Totals = .{};
    _ = try fuzz.hunt(Tree(4, .none), gpa, 1, sweep_seeds, .{}, &swarmed);
    try printReach(w, "fixed mix", &fixed);
    try printReach(w, "swarm    ", &swarmed);

    try w.print("\n== 4. Three broken trees (M = 4, swarm seeds 1..{d}) ==\n", .{hunt_seeds});
    inline for (bugs) |bug| try huntAndMinimize(Tree(4, bug), gpa, w);

    try w.writeAll("\n== 5. Fault injection: fail every node allocation of every put once ==\n");
    const sweep = try faultSweep(Tree(4, .none), gpa, 40);
    try w.print("puts={d} nodes created={d} injected failures={d} reserved nodes handed back={d}\n", .{
        sweep.puts, sweep.nodes_created, sweep.injected, sweep.handed_back,
    });
    try w.print("tree unchanged after every failed put: {s}; live allocations after deinit: {d}\n", .{
        if (sweep.unchanged) "yes" else "NO", sweep.live_after_deinit,
    });
}

fn printCase(w: *std.Io.Writer, case: fuzz.Case) !void {
    try w.print("seed {d}: {d} ops on {d} keys, put:delete:get:range = {d}:{d}:{d}:{d}, ", .{
        case.seed,           case.count,       case.key_space,
        case.weights.put,    case.weights.delete, case.weights.get,
        case.weights.range,
    });
    if (case.fault_one_in == 0) {
        try w.writeAll("no faults");
    } else {
        try w.print("fault in 1 of {d} puts", .{case.fault_one_in});
    }
    try w.print(", drain {s}\n", .{if (case.drain) "yes" else "no"});
}

fn printCoverage(w: *std.Io.Writer, cov: *const coverage.Coverage) !void {
    for (0..coverage.point_count) |i| {
        const point: coverage.Point = @enumFromInt(i);
        try w.print("  {t:<22} {d}\n", .{ point, cov.count(point) });
    }
}

fn printReach(w: *std.Io.Writer, label: []const u8, totals: *const fuzz.Totals) !void {
    try w.print("{s}: {d} steps, max height {d}, coverage {d}/{d}", .{
        label, totals.steps, totals.max_height, totals.coverage.reached(), coverage.point_count,
    });
    var first = true;
    for (0..coverage.point_count) |i| {
        const point: coverage.Point = @enumFromInt(i);
        if (totals.coverage.count(point) != 0) continue;
        try w.print("{s}{t}", .{ if (first) ", never reached: " else ", ", point });
        first = false;
    }
    try w.writeByte('\n');
}

/// Find the swarm seed that exposes the bug in the fewest steps, show which family of
/// checks is needed to see it, and print the minimised reproducer.
fn huntAndMinimize(comptime T: type, gpa: Allocator, w: *std.Io.Writer) !void {
    try w.print("bug {t}\n", .{T.bug});
    const census = try fuzz.huntShortest(T, gpa, 1, hunt_seeds, .{});
    const found = census.shortest orelse {
        try w.writeAll("  NOT CAUGHT\n");
        return;
    };
    const steps = try fuzz.generate(gpa, found.case);
    defer gpa.free(steps);
    try w.print("  caught by {d} of {d} seeds; shortest failing run: seed {d}, step {d} of {d}\n", .{
        census.failing_seeds, hunt_seeds, found.case.seed, found.failure.step + 1, steps.len,
    });
    try w.print("  {f}\n", .{found.failure});
    // Which half of the checks does the work? Replay the same steps with one
    // half switched off. (Only safe because of what these three bugs do: see
    // the README before trying this with a bug that corrupts pointers.)
    if (found.failure.kind == .invariant) {
        const silent = found.failure.kind.invariant == error.NodeCountMismatch and
            try fuzz.replay(T, gpa, steps, .{ .validate = false }, null) == null;
        try w.print("  with the oracle comparison alone: {s}\n", .{if (silent) "not caught" else "not tried (the tree is malformed)"});
    } else {
        const silent = try fuzz.replay(T, gpa, steps, .{ .model = false }, null) == null;
        try w.print("  with validate alone: {s}\n", .{if (silent) "not caught" else "caught"});
    }
    const small = try minimize(T, gpa, steps, found.failure, .{});
    defer gpa.free(small.steps);
    try w.print("  minimised to {d} steps in {d} replays:\n", .{ small.steps.len, small.replays });
    try fuzz.writeSteps(w, small.steps, "    ");
    try w.print("    -> {f}\n", .{small.failure});
}

pub const FaultSweep = struct {
    puts: u64 = 0,
    nodes_created: u64 = 0,
    injected: u64 = 0,
    handed_back: u64 = 0,
    unchanged: bool = true,
    live_after_deinit: u64 = 0,
};

/// Insert the keys 1..count. For each put, fail its first node allocation,
/// then (on a fresh attempt) its second, and so on until the put gets
/// through. After each failure the tree must be exactly as before.
/// This is `std.testing.checkAllAllocationFailures` done by hand, with one
/// thing that function cannot do: carry on with the same tree afterwards.
pub fn faultSweep(comptime T: type, gpa: Allocator, count: u64) Allocator.Error!FaultSweep {
    var result: FaultSweep = .{};
    var fault: FaultAllocator = .init(gpa);
    const a = fault.allocator();
    var tree: T = .empty;
    for (1..count + 1) |key| {
        var n: u64 = 0;
        while (true) : (n += 1) {
            const usage_before = tree.pool.usage;
            const injected_before = fault.injected;
            fault.failNth(n);
            const outcome = tree.put(a, key, key * 10);
            fault.disarm();
            if (outcome) |_| break else |err| {
                if (fault.injected == injected_before) return err;
                result.handed_back += n; // n nodes were reserved before the failure
                const same = tree.len == key - 1 and tree.get(key) == null and
                    std.meta.eql(tree.pool.usage, usage_before) and
                    fault.liveAllocations() == tree.pool.usage.live();
                tree.validate(null) catch {
                    result.unchanged = false;
                };
                if (!same) result.unchanged = false;
            }
        }
        result.puts += 1;
    }
    result.nodes_created = tree.pool.usage.created;
    result.injected = fault.injected;
    tree.deinit(a);
    result.live_after_deinit = fault.liveAllocations();
    return result;
}

test "run prints exactly expected_output.txt" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try run(std.testing.allocator, &out.writer);
    try std.testing.expectEqualStrings(@embedFile("expected_output"), out.written());
}
