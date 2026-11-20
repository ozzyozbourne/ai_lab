//! The tests of this chapter: the toolkit pointed at the tree.
//!
//! Every test uses `std.testing.allocator`, so anything the HARNESS forgets
//! to free fails the test as well. Passing tests print nothing; the numbers
//! (seed, step, reproducer) are printed by `zig build run` (scenario.zig).
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const btree = @import("base_btree.zig");
const validation = @import("base_validate.zig");
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
    try testing.expectEqual(fuzz.KeyLayout.spread, c.key_layout);
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
    var every_put_faulted = false;
    var without_drain = false;
    var layouts: [4]bool = @splat(false);
    for (1..scenario.sweep_seeds + 1) |seed| {
        const c = fuzz.swarm(seed);
        try testing.expect(c.weights.put > 0);
        try testing.expect(std.math.isPowerOfTwo(c.key_space)); // `KeyLayout.spread` relies on it
        layouts[@backingInt(c.key_layout)] = true;
        no_delete = no_delete or c.weights.delete == 0;
        tiny_keys = tiny_keys or c.key_space == 4;
        with_faults = with_faults or c.fault_one_in != 0;
        every_put_faulted = every_put_faulted or c.fault_one_in == 1;
        without_drain = without_drain or !c.drain;
    }
    try testing.expect(no_delete and tiny_keys and with_faults and every_put_faulted and without_drain);
    try testing.expectEqual(@as([4]bool, @splat(true)), layouts);
}

test "key layouts: pinned keys, strictly increasing, never maxInt" {
    const max = std.math.maxInt(u64);
    const L = fuzz.KeyLayout;
    try testing.expectEqual(5, L.dense.key(64, 5));
    try testing.expectEqual((1 << 32) - 32, L.around_2_32.key(64, 0)); // 32 keys below 2^32 ...
    try testing.expectEqual((1 << 32) + 31, L.around_2_32.key(64, 63)); // ... and 32 from it upwards
    try testing.expectEqual(3 << 58, L.spread.key(64, 3));
    try testing.expectEqual(255 << 56, L.spread.key(256, 255));
    try testing.expectEqual(max, L.spread.key(4, 4)); // one past the end saturates
    try testing.expectEqual(max - 64, L.top.key(64, 0));
    try testing.expectEqual(max - 1, L.top.key(64, 63)); // the largest key ever used
    try testing.expectEqual(max, L.top.key(64, 64)); // only as an exclusive range bound
    inline for (comptime std.enums.values(L)) |layout| {
        for ([_]u64{ 4, 16, 64, 256 }) |key_space| {
            for (0..key_space) |k| {
                try testing.expect(layout.key(key_space, k) < layout.key(key_space, k + 1));
            }
            try testing.expect(layout.key(key_space, key_space - 1) < max);
        }
    }
}

test "generate: the sweep uses keys a 32-bit or signed comparison would get wrong" {
    // What the keys must offer for a magnitude bug to show (the reviewer's
    // mutant: `put` compares only the low 32 bits of the key):
    const gpa = testing.allocator;
    var small = false; // dense small keys, as before
    var above_32_bits = false;
    var same_low_half = false; // two different keys that agree in their low 32 bits
    var both_sides_of_2_32 = false;
    var both_sides_of_2_63 = false; // different sign if read as i64
    var near_max = false;
    for (1..scenario.sweep_seeds + 1) |seed| {
        const steps = try fuzz.generate(gpa, fuzz.swarm(seed));
        defer gpa.free(steps);
        var lowest: u64 = std.math.maxInt(u64);
        var highest: u64 = 0;
        var previous: ?u64 = null;
        for (steps) |step| switch (step.op) {
            .put => |p| {
                lowest = @min(lowest, p.key);
                highest = @max(highest, p.key);
                if (previous) |q| {
                    if (q != p.key and @as(u32, @truncate(q)) == @as(u32, @truncate(p.key))) same_low_half = true;
                }
                previous = p.key;
            },
            else => {},
        };
        small = small or highest < 256;
        above_32_bits = above_32_bits or highest > std.math.maxInt(u32);
        both_sides_of_2_32 = both_sides_of_2_32 or (lowest < 1 << 32 and highest >= 1 << 32 and highest < 1 << 33);
        both_sides_of_2_63 = both_sides_of_2_63 or (lowest < 1 << 63 and highest >= 1 << 63);
        near_max = near_max or highest >= std.math.maxInt(u64) - 2;
    }
    try testing.expect(small and above_32_bits and same_low_half);
    try testing.expect(both_sides_of_2_32 and both_sides_of_2_63 and near_max);
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
            faults += @intFromBool(step.fault);
        },
        .delete => |d| _ = alive.remove(d.key),
        else => try testing.expect(!step.fault), // only puts allocate
    };
    try testing.expectEqual(0, alive.count());
    try testing.expect(faults > 0);
}

test "generate: ranges also come empty, inverted and up to both ends of u64" {
    // The operation stream alone only ever asks for [lo, hi) with lo < hi
    // between two keys of the case. A scan that stops on `key > hi - 1`
    // (overflow at hi = 0) or on `key -% lo >= hi -% lo` (wrong for lo > hi)
    // passed every test until these shapes were generated.
    const gpa = testing.allocator;
    const max = std.math.maxInt(u64);
    var ordinary: usize = 0;
    var inverted: usize = 0;
    var empty: usize = 0;
    var hi_is_zero: usize = 0;
    var from_zero: usize = 0;
    var to_max: usize = 0;
    var everything: usize = 0;
    for (1..scenario.sweep_seeds + 1) |seed| {
        const case = fuzz.swarm(seed);
        const steps = try fuzz.generate(gpa, case);
        defer gpa.free(steps);
        for (steps) |step| switch (step.op) {
            .range => |r| {
                ordinary += @intFromBool(r.lo < r.hi and r.hi != max);
                inverted += @intFromBool(r.lo > r.hi);
                empty += @intFromBool(r.lo == r.hi);
                hi_is_zero += @intFromBool(r.hi == 0);
                from_zero += @intFromBool(r.lo == 0 and case.key_layout != .dense);
                to_max += @intFromBool(r.hi == max and r.lo != 0);
                everything += @intFromBool(r.lo == 0 and r.hi == max);
            },
            else => {},
        };
    }
    for ([_]usize{ inverted, empty, hi_is_zero, from_zero, to_max, everything }) |n| try testing.expect(n >= 20);
    try testing.expect(ordinary > inverted + empty + from_zero + to_max + everything); // still the common case
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
        // Faults reach deep reservations too: some failed put had already
        // taken three nodes or more. (With faults only at allocation 0, 1
        // or 2 a rollback that hands back at most two nodes passed.)
        try testing.expect(totals.deepest_rollback >= 3);
    }
}

test "range: empty, inverted and extreme bounds on a real tree" {
    const gpa = testing.allocator;
    const max = std.math.maxInt(u64);
    var tree: Tree(4, .none) = .empty;
    defer tree.deinit(gpa);
    const keys = [_]u64{ 0, 1, 5, 9, 1 << 32, 1 << 63, max - 1 }; // three levels at M = 4
    for (keys) |key| _ = try tree.put(gpa, key, key);
    const Count = struct {
        n: usize = 0,
        pub fn visit(self: *@This(), _: u64, _: u64) void {
            self.n += 1;
        }
    };
    const cases = [_]struct { lo: u64, hi: u64, want: usize }{
        .{ .lo = 0, .hi = max, .want = keys.len },
        .{ .lo = 0, .hi = 0, .want = 0 }, // `hi - 1` would overflow here
        .{ .lo = 5, .hi = 5, .want = 0 },
        .{ .lo = 9, .hi = 1, .want = 0 }, // inverted: empty, not "from 9 upward"
        .{ .lo = max, .hi = 0, .want = 0 },
        .{ .lo = max - 1, .hi = max, .want = 1 },
        .{ .lo = 0, .hi = 1, .want = 1 },
        .{ .lo = 1, .hi = (1 << 63) + 1, .want = 5 },
    };
    for (cases) |c| {
        var seen: Count = .{};
        tree.range(c.lo, c.hi, &seen);
        try testing.expectEqual(c.want, seen.n);
    }
    // The one key the fuzzer never uses, because no half-open range (not
    // even its own full scan of the oracle) can contain it.
    try testing.expectEqual(null, try tree.put(gpa, max, 7));
    try testing.expectEqual(7, tree.get(max));
    var widest: Count = .{};
    tree.range(0, max, &widest);
    try testing.expectEqual(keys.len, widest.n); // still without it
    try tree.validate(null);
    try testing.expectEqual(7, tree.delete(gpa, max));
    try testing.expectEqual(null, tree.get(max));
    try tree.validate(null);
}

test "the height bound: put's path array is as long as the tallest tree validate accepts" {
    // `max_height` cannot be reached by any test (64 levels need 2^64 keys),
    // so it is tied to chapter 03's formula instead: `put` does not compile
    // with a smaller constant, and `validate` asserts the formula on every
    // tree the fuzzer builds. Here: the formula is not just generous.
    const insert = @import("base_insert.zig");
    inline for (scenario.orders) |M| {
        try testing.expect(insert.max_height >= validation.maxHeight(M, std.math.maxInt(u64)));
    }
    try testing.expectEqual(insert.max_height, validation.maxHeight(3, std.math.maxInt(u64)));
    // Ascending inserts at M = 3 leave every node at its minimum except on
    // the right edge: the tree is as tall as 2^h - 1 keys allow, whenever
    // the count is one of those numbers.
    const gpa = testing.allocator;
    var tree: Tree(3, .none) = .empty;
    defer tree.deinit(gpa);
    var tight: usize = 0;
    for (1..256) |key| {
        _ = try tree.put(gpa, key, key);
        try tree.validate(null); // asserts height <= maxHeight(3, key)
        const height = tree.shape().height;
        try testing.expect(height <= validation.maxHeight(3, key));
        tight += @intFromBool(height == validation.maxHeight(3, key));
    }
    try testing.expect(tight > 0);
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
        .{ .failing = 191, .seed = 20, .step = 5 },
        .{ .failing = 154, .seed = 68, .step = 8 },
        .{ .failing = 71, .seed = 28, .step = 51 },
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

test "fuzz: a failed put that leaks a reserved node, or leaves its mark on pool.usage, is caught" {
    // Two test-only seams in the rollback of `put` (base_btree.zig, `Bug`).
    // Both leave the tree's shape and contents untouched, so only the
    // accounting checks can see them.
    const gpa = testing.allocator;
    inline for (scenario.orders) |M| {
        // The counting allocator under the tree still holds a node after `deinit`.
        const leaked = (try fuzz.hunt(Tree(M, .rollback_leaks_node), gpa, 1, scenario.sweep_seeds, .{}, null)).?;
        try testing.expectEqual(fuzz.Kind.leak, leaked.failure.kind);
        // `created`, `destroyed` and `peak` count nodes that were never part of the tree.
        const counted = (try fuzz.hunt(Tree(M, .rollback_keeps_usage), gpa, 1, scenario.sweep_seeds, .{}, null)).?;
        try testing.expectEqual(fuzz.Kind.oom_changed_tree, counted.failure.kind);
        // The oracle comparison alone sees neither.
        try testing.expectEqual(null, try fuzz.hunt(Tree(M, .rollback_keeps_usage), gpa, 1, scenario.sweep_seeds, .{ .validate = false, .model = true }, null));
    }
}

test "fuzz: a node that is read after it was freed is caught (Zig)" {
    // Two test-only seams (base_btree.zig, `Bug`). On a bare arena both pass
    // every check: the freed node still reads exactly as before.
    const gpa = testing.allocator;
    inline for (scenario.orders) |M| {
        // Root shrink reads its only child from the freed root. The
        // quarantine has zeroed it, so the tree is suddenly empty.
        const lost = (try fuzz.hunt(Tree(M, .root_read_after_free), gpa, 1, scenario.sweep_seeds, .{}, null)).?;
        try testing.expectEqual(fuzz.Kind{ .invariant = error.WrongKeyCount }, lost.failure.kind);

        // One flag read from a freed node, used only to pick a coverage
        // point: the tree stays correct, so one replay sees nothing ...
        const T = Tree(M, .merge_reads_freed_flag);
        const flag = (try fuzz.hunt(T, gpa, 1, scenario.sweep_seeds, .{}, null)).?;
        try testing.expectEqual(fuzz.Kind.read_after_free, flag.failure.kind);
        const steps = try fuzz.generate(gpa, flag.case);
        defer gpa.free(steps);
        try testing.expectEqual(null, try fuzz.replay(T, gpa, steps, .{}, null));
        // ... and the step `hunt` names is a delete (only deletes merge).
        try testing.expect(steps[flag.failure.step].op == .delete);
        // The oracle comparison alone does not look at memory at all.
        try testing.expectEqual(null, try fuzz.hunt(T, gpa, 1, scenario.sweep_seeds, .{ .validate = false }, null));
    }
    // Pinned (M = 3): the step where the Rust slab panics for the same bug.
    const first = (try fuzz.hunt(Tree(3, .merge_reads_freed_flag), gpa, 1, 1, .{}, null)).?;
    try testing.expectEqual(141, first.failure.step);
}

test "Step prints as one line of a reproducer (also the line of the -Dtrace output)" {
    var buf: [128]u8 = undefined;
    const put: fuzz.Step = .{ .op = .{ .put = .{ .key = 7, .value = 70 } }, .fault = true };
    try testing.expectEqualStrings("put 7 = 70 (each node allocation fails once first)", try std.fmt.bufPrint(&buf, "{f}", .{put}));
    const range: fuzz.Step = .{ .op = .{ .range = .{ .lo = 3, .hi = 9 } } };
    try testing.expectEqualStrings("range [3, 9)", try std.fmt.bufPrint(&buf, "{f}", .{range}));
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

/// True if some contiguous block of `steps` can be removed and the rest
/// still fails like `target`.
fn someBlockIsRemovable(comptime T: type, gpa: Allocator, steps: []const fuzz.Step, target: fuzz.Failure) !bool {
    const shorter = try gpa.alloc(fuzz.Step, steps.len);
    defer gpa.free(shorter);
    for (0..steps.len) |start| {
        for (start + 1..steps.len + 1) |end| {
            if (end - start == steps.len) continue; // nothing left
            @memcpy(shorter[0..start], steps[0..start]);
            @memcpy(shorter[start .. start + steps.len - end], steps[end..]);
            const f = try fuzz.replay(T, gpa, shorter[0 .. steps.len - (end - start)], .{}, null) orelse continue;
            if (f.sameKind(target)) return true;
        }
    }
    return false;
}

test "minimize: no contiguous block of steps can be removed from the result" {
    // The guarantee stated in minimize.zig, checked on the first failing
    // seeds of each variant (not only the hand-picked shortest run). A
    // minimiser whose chunk sizes only shrink fails this for 13 of these 60
    // runs: it leaves pairs of steps that can only be removed together.
    const gpa = testing.allocator;
    inline for (scenario.bugs) |bug| {
        const T = Tree(4, bug);
        var seed: u64 = 1;
        var tried: usize = 0;
        while (tried < 20) : (seed += 1) {
            const found = try fuzz.hunt(T, gpa, seed, 1, .{}, null) orelse continue;
            tried += 1;
            const steps = try fuzz.generate(gpa, found.case);
            defer gpa.free(steps);
            const small = try minimize(T, gpa, steps, found.failure, .{});
            defer gpa.free(small.steps);
            const again = (try fuzz.replay(T, gpa, small.steps, .{}, null)).?;
            try testing.expectEqual(small.steps.len - 1, again.step);
            try testing.expect(again.sameKind(found.failure));
            try testing.expect(!try someBlockIsRemovable(T, gpa, small.steps, found.failure));
        }
    }
}

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
            try testing.expect(!step.fault);
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

test "a node with a garbage key count is rejected by validate and still rendered" {
    const gpa = testing.allocator;
    var tree: Tree(4, .none) = .empty;
    defer tree.deinit(gpa);
    for (1..20) |key| _ = try tree.put(gpa, key, key);
    const victim = tree.root.?.children[0].?;
    const real_len = victim.len;
    victim.len = 9; // more keys than the node has room for
    try testing.expectError(error.NodeOverfull, tree.validate(null));
    _ = tree.shape();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try tree.render(&out.writer, ""); // used to index past the key array
    try testing.expect(std.mem.indexOf(u8, out.written(), " !]") != null);
    victim.len = real_len; // so that deinit frees a sound tree
    try tree.validate(null);
}
