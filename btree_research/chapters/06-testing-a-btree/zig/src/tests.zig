//! The tests of this chapter: the toolkit pointed at the tree.
//!
//! Every test uses `std.testing.allocator`, so anything the HARNESS forgets
//! to free fails the test as well. Passing tests print nothing; the numbers
//! (seed, step, reproducer) are printed by `zig build run` (scenario.zig).
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const btree = @import("base_btree.zig");
const pool = @import("base_pool.zig");
const coverage = @import("coverage.zig");
const fuzz = @import("fuzz.zig");
const minimize = @import("minimize.zig").minimize;
const scenario = @import("scenario.zig");
const FaultAllocator = @import("fault_alloc.zig").FaultAllocator;
const Tree = scenario.Tree;

// ---- the generator ---------------------------------------------------------

test "swarm: one seed fixes the whole case (pinned, same numbers in Rust)" {
    const c = fuzz.swarm(1);
    try testing.expectEqual(256, c.count);
    try testing.expectEqual(64, c.key_space);
    try testing.expectEqual(@as(@TypeOf(c.weights), .{ .put = 8, .delete = 4, .get = 4, .range = 1 }), c.weights);
    try testing.expectEqual(2, c.fault_one_in);
    try testing.expectEqual(true, c.drain);
    try testing.expectEqual(11168034603498703870, c.stream_seed);
    try testing.expectEqual(8392123148533390784, c.aux_seed);
}

test "swarm: the seeds really differ in the dimensions that matter" {
    var no_delete = false;
    var tiny_keys = false;
    var with_faults = false;
    var without_drain = false;
    for (1..scenario.sweep_seeds + 1) |seed| {
        const c = fuzz.swarm(seed);
        try testing.expect(c.weights.put > 0);
        no_delete = no_delete or c.weights.delete == 0;
        tiny_keys = tiny_keys or c.key_space == 4;
        with_faults = with_faults or c.fault_one_in != 0;
        without_drain = without_drain or !c.drain;
    }
    try testing.expect(no_delete and tiny_keys and with_faults and without_drain);
}

test "generate: same case, same steps; a drained case ends with no key alive" {
    const gpa = testing.allocator;
    const case = fuzz.swarm(1);
    const a = try fuzz.generate(gpa, case);
    defer gpa.free(a);
    const b = try fuzz.generate(gpa, case);
    defer gpa.free(b);
    try testing.expectEqual(294, a.len); // 256 generated + 38 drain deletes
    try testing.expectEqualDeep(a, b);

    var alive: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer alive.deinit(gpa);
    var faults: usize = 0;
    for (a) |step| switch (step.op) {
        .put => |p| {
            try alive.put(gpa, p.key, {});
            faults += @intFromBool(step.fault != null);
        },
        .delete => |d| _ = alive.remove(d.key),
        else => try testing.expectEqual(null, step.fault), // only puts allocate
    };
    try testing.expectEqual(0, alive.count());
    try testing.expect(faults > 0);
}

// ---- the correct tree ------------------------------------------------------

test "fuzz: the correct tree passes at every order, and every branch was reached" {
    inline for (scenario.orders) |M| {
        var totals: fuzz.Totals = .{};
        const found = try fuzz.hunt(Tree(M, .none), testing.allocator, 1, scenario.sweep_seeds, .{}, &totals);
        try testing.expectEqual(null, found);
        // The coverage assert: a green run that never split an interior node
        // or never rolled back a reservation has not tested those paths.
        try testing.expectEqual(null, totals.coverage.firstMissing());
        try testing.expect(totals.max_height >= 4);
        try testing.expect(totals.injected_faults > 0);
    }
}

test "fuzz: tiny nodes are what reaches the interior cases" {
    // Same seeds, same operations, 31 keys per node: at most 256 distinct
    // keys never build a third level, so nothing ever happens to an
    // interior node.
    var totals: fuzz.Totals = .{};
    try testing.expectEqual(null, try fuzz.hunt(Tree(32, .none), testing.allocator, 1, scenario.sweep_seeds, .{}, &totals));
    try testing.expectEqual(2, totals.max_height);
    for ([_]coverage.Point{ .split_interior, .root_split_interior, .borrow_left_interior, .borrow_right_interior, .merge_interior }) |point| {
        try testing.expectEqual(0, totals.coverage.count(point));
    }
    try testing.expectEqual(coverage.point_count - 5, totals.coverage.reached());
}

test "fuzz: the harness is generic over the node pool" {
    // With FreeListPool one allocation is a chunk of 32 nodes, so an
    // injected fault only bites when a new chunk is needed; the promises
    // (failed put changes nothing, no leak after deinit) are the same.
    const T = btree.BTree(4, pool.FreeListPool);
    try testing.expectEqual(null, try fuzz.hunt(T, testing.allocator, 1, 40, .{}, null));
}

// ---- the broken trees ------------------------------------------------------

test "fuzz: each broken variant is caught at every order" {
    const gpa = testing.allocator;
    inline for (scenario.orders) |M| {
        const wrong_value = (try fuzz.hunt(Tree(M, .split_wrong_value), gpa, 1, scenario.hunt_seeds, .{}, null)).?;
        try testing.expect(wrong_value.failure.kind == .wrong_result or wrong_value.failure.kind == .wrong_contents);

        const leak = (try fuzz.hunt(Tree(M, .merge_leaks_node), gpa, 1, scenario.hunt_seeds, .{}, null)).?;
        try testing.expectEqual(fuzz.Kind{ .invariant = error.NodeCountMismatch }, leak.failure.kind);

        const lost_child = (try fuzz.hunt(Tree(M, .borrow_forgets_child), gpa, 1, scenario.hunt_seeds, .{}, null)).?;
        try testing.expectEqual(fuzz.Kind{ .invariant = error.MissingChild }, lost_child.failure.kind);
        try testing.expect(lost_child.failure.diag.depth >= 1); // an interior node below the root
    }
}

test "fuzz: seed and step of the shortest failing run (M = 4), as printed by `run`" {
    const gpa = testing.allocator;
    const expected = [_]struct { failing: u64, seed: u64, step: usize }{
        .{ .failing = 191, .seed = 72, .step = 4 },
        .{ .failing = 154, .seed = 68, .step = 8 },
        .{ .failing = 74, .seed = 28, .step = 51 },
    };
    inline for (scenario.bugs, expected) |bug, want| {
        const census = try fuzz.huntShortest(Tree(4, bug), gpa, 1, scenario.hunt_seeds, .{});
        try testing.expectEqual(want.failing, census.failing_seeds);
        try testing.expectEqual(want.seed, census.shortest.?.case.seed);
        try testing.expectEqual(want.step, census.shortest.?.failure.step);
    }
}

test "fuzz: each family of checks sees a bug the other one cannot" {
    const gpa = testing.allocator;
    {
        // A leaked node: every answer is still right. Only validate (pool
        // accounting) notices.
        const T = Tree(4, .merge_leaks_node);
        const found = (try fuzz.hunt(T, gpa, 1, scenario.hunt_seeds, .{}, null)).?;
        const steps = try fuzz.generate(gpa, found.case);
        defer gpa.free(steps);
        try testing.expectEqual(null, try fuzz.replay(T, gpa, steps, .{ .validate = false }, null));
    }
    {
        // A wrong value in a well-formed tree: validate has nothing to say.
        const T = Tree(4, .split_wrong_value);
        const found = (try fuzz.hunt(T, gpa, 1, scenario.hunt_seeds, .{}, null)).?;
        const steps = try fuzz.generate(gpa, found.case);
        defer gpa.free(steps);
        try testing.expectEqual(null, try fuzz.replay(T, gpa, steps, .{ .model = false }, null));
    }
}

test "Failure prints what broke and where" {
    var buf: [128]u8 = undefined;
    const located: fuzz.Failure = .{ .step = 3, .kind = .{ .invariant = error.MissingChild }, .diag = .{ .depth = 1, .first_key = 9 } };
    try testing.expectEqualStrings(
        "invariant MissingChild at depth 1 (node starts with key 9)",
        try std.fmt.bufPrint(&buf, "{f}", .{located}),
    );
    const whole_tree: fuzz.Failure = .{ .step = 3, .kind = .{ .invariant = error.NodeCountMismatch } };
    try testing.expectEqualStrings("invariant NodeCountMismatch", try std.fmt.bufPrint(&buf, "{f}", .{whole_tree}));
    try testing.expect(located.sameKind(.{ .step = 99, .kind = .{ .invariant = error.MissingChild } }));
    try testing.expect(!located.sameKind(whole_tree));
}

// ---- minimisation ----------------------------------------------------------

test "minimize: short, still failing the same way, and 1-minimal" {
    const gpa = testing.allocator;
    const expected_len = [_]usize{ 5, 6, 11 };
    inline for (scenario.bugs, expected_len) |bug, want_len| {
        const T = Tree(4, bug);
        const found = (try fuzz.huntShortest(T, gpa, 1, scenario.hunt_seeds, .{})).shortest.?;
        const steps = try fuzz.generate(gpa, found.case);
        defer gpa.free(steps);
        const small = try minimize(T, gpa, steps, found.failure, .{});
        defer gpa.free(small.steps);

        try testing.expectEqual(want_len, small.steps.len);
        // It is a reproducer: replaying it fails at its last step, same kind.
        const again = (try fuzz.replay(T, gpa, small.steps, .{}, null)).?;
        try testing.expectEqual(small.steps.len - 1, again.step);
        try testing.expect(again.sameKind(found.failure));
        // The correct tree runs the same steps without complaint.
        try testing.expectEqual(null, try fuzz.replay(Tree(4, .none), gpa, small.steps, .{}, null));
        // 1-minimal: take any single step away and this failure is gone.
        const shorter = try gpa.alloc(fuzz.Step, small.steps.len - 1);
        defer gpa.free(shorter);
        for (0..small.steps.len) |skip| {
            @memcpy(shorter[0..skip], small.steps[0..skip]);
            @memcpy(shorter[skip..], small.steps[skip + 1 ..]);
            const f = try fuzz.replay(T, gpa, shorter, .{}, null);
            try testing.expect(f == null or !f.?.sameKind(found.failure));
        }
        // Readable: keys renumbered from 1, the n-th put writes n, no faults.
        var puts: u64 = 0;
        for (small.steps) |step| {
            try testing.expectEqual(null, step.fault);
            switch (step.op) {
                .put => |p| {
                    puts += 1;
                    try testing.expectEqual(puts, p.value);
                    try testing.expect(p.key >= 1 and p.key <= 2 * small.steps.len); // ranks, not random numbers
                },
                else => {},
            }
        }
    }
}

// ---- fault injection -------------------------------------------------------

fn buildCanonical(gpa: Allocator) !void {
    var tree: Tree(4, .none) = .empty;
    defer tree.deinit(gpa);
    for ([_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 }) |key| _ = try tree.put(gpa, key, key * 10);
    try tree.validate(null);
}

test "faults: std.testing.checkAllAllocationFailures on a sequence of puts" {
    // The standard tool: run once to count the allocations, then once per
    // allocation with that one (and all later ones) failing. It checks that
    // the function returns OutOfMemory and frees everything it allocated.
    try testing.checkAllAllocationFailures(testing.allocator, buildCanonical, .{});
}

test "faults: the hand-written sweep also checks that the tree is unchanged and usable" {
    const sweep = try scenario.faultSweep(Tree(4, .none), testing.allocator, 40);
    try testing.expectEqual(40, sweep.puts);
    try testing.expectEqual(sweep.nodes_created, sweep.injected); // every allocation point failed once
    try testing.expect(sweep.handed_back > 0); // some failures hit a half-made reservation
    try testing.expect(sweep.unchanged);
    try testing.expectEqual(0, sweep.live_after_deinit);
}

test "faults: delete never asks for memory" {
    var fault: FaultAllocator = .init(testing.allocator);
    const a = fault.allocator();
    var tree: Tree(4, .none) = .empty;
    defer tree.deinit(a);
    for (1..41) |key| _ = try tree.put(a, key, key);
    const attempts = fault.attempts;
    const node_bytes = fault.live_bytes / fault.liveAllocations();
    try testing.expectEqual(@sizeOf(Tree(4, .none).NodeT), node_bytes); // one allocation per node
    fault.failNth(0); // any allocation from here on would fail
    for (1..41) |key| try testing.expectEqual(key, tree.delete(a, key));
    try testing.expectEqual(attempts, fault.attempts);
    try testing.expectEqual(0, fault.liveAllocations());
    try testing.expectEqual(0, fault.injected);
    fault.disarm();
}

// ---- a rejected tree can still be shown and torn down ----------------------

test "a tree that validate rejects can be rendered and deinit-ed without aborting" {
    // A private SafeAllocator, so the node leaked on purpose (merge bug)
    // does not fail this test; its leak count is asserted instead.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const gpa = safe.allocator();
    const steps = [_]u64{ 10, 9, 3, 7, 8, 1, 6, 5, 4, 2 }; // the minimised reproducer of `run`
    inline for (.{ btree.Bug.merge_leaks_node, btree.Bug.borrow_forgets_child }) |bug| {
        var tree: Tree(4, bug) = .empty;
        for (steps) |key| _ = try tree.put(gpa, key, key);
        _ = tree.delete(gpa, 9);
        try testing.expect(std.meta.isError(tree.validate(null)));
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try tree.render(&out.writer, "");
        if (bug == .borrow_forgets_child) try testing.expect(std.mem.indexOf(u8, out.written(), "[?]") != null);
        _ = tree.shape();
        tree.deinit(gpa);
    }
    try testing.expect(safe.deinitLog(false) > 0); // the lost nodes are leaks, not a crash
}
