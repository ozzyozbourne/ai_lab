//! Tests of the top-down insert, always next to the bottom-up one: both must
//! give valid trees that hold the same keys. The shapes may differ.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const BTree = @import("base_btree.zig").BTree;
const pool = @import("base_pool.zig");
const ops = @import("ops.zig");
const topdown = @import("topdown.zig");
const base_tests = @import("base_tests_insert.zig");

const Tree4 = base_tests.Tree4; // BTree(4, DirectNodes): every node is a tracked allocation
const expectTree = base_tests.expectTree;
const canonical_keys = base_tests.canonical_keys;

test "top-down put: the canonical example, step by step" {
    const gpa = testing.allocator;
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    for ([_]u64{ 10, 20, 5 }) |key| _ = try topdown.put(Tree4, &tree, gpa, key, key * 10);
    try expectTree(&tree, "[5 10 20]\n");
    // The root is full, so it is split BEFORE 6 is placed: 1 + median + 1.
    _ = try topdown.put(Tree4, &tree, gpa, 6, 60);
    try expectTree(&tree, "[10]\n[5 6] [20]\n");
    for ([_]u64{ 12, 30, 7, 17, 3 }) |key| _ = try topdown.put(Tree4, &tree, gpa, key, key * 10);
    // Up to here the tree is the one bottom-up builds.
    try expectTree(&tree, "[6 10 20]\n[3 5] [7] [12 17] [30]\n");
    // 25 belongs in the leaf [30], which has room. Bottom-up would just put
    // it there. Top-down meets a full root first and splits it anyway.
    _ = try topdown.put(Tree4, &tree, gpa, 25, 250);
    try expectTree(&tree, "[10]\n[6] [20]\n[3 5] [7] | [12 17] [25 30]\n");
    for ([_]u64{ 1, 15 }) |key| _ = try topdown.put(Tree4, &tree, gpa, key, key * 10);
    try expectTree(&tree, "[10]\n[6] [20]\n[1 3 5] [7] | [12 15 17] [25 30]\n");
    try testing.expectEqual(4, tree.counters.splits);
    try testing.expectEqual(2, tree.counters.root_splits);
    for (canonical_keys) |key| try testing.expectEqual(key * 10, tree.get(key));
}

test "top-down overwrite returns the old value, also when the key is the median that moves up" {
    const gpa = testing.allocator;
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    for ([_]u64{ 10, 20, 5, 6, 7 }) |key| _ = try topdown.put(Tree4, &tree, gpa, key, key * 10);
    try expectTree(&tree, "[10]\n[5 6 7] [20]\n");
    // The leaf [5 6 7] is full, so it is split on the way down; its median 6
    // moves into the root, and 6 is the key being written.
    try testing.expectEqual(60, try topdown.put(Tree4, &tree, gpa, 6, 61));
    try expectTree(&tree, "[6 10]\n[5] [7] [20]\n"); // an overwrite that changed the shape
    try testing.expectEqual(61, tree.get(6));
    try testing.expectEqual(5, tree.len);
    try testing.expectEqual(200, try topdown.put(Tree4, &tree, gpa, 20, 201)); // found in a leaf
    try testing.expectEqual(100, try topdown.put(Tree4, &tree, gpa, 10, 101)); // found in the root
}

test "the worked example continued: put 2 splits a leaf and then the interior root" {
    const gpa = testing.allocator;
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    for (canonical_keys) |key| _ = try tree.put(gpa, key, key * 10);
    try expectTree(&tree, "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n");
    const before = tree.counters;
    // Leaf [1 2 3 5]: 3 goes up. Root [3 6 10 20] with five children: 10
    // goes up, [3 6] keeps the first three children, [20] gets the last two.
    try testing.expectEqual(null, try tree.put(gpa, 2, 20));
    try expectTree(&tree, "[10]\n[3 6] [20]\n[1 2] [5] [7] | [12 15 17] [25 30]\n");
    try testing.expectEqual(2, tree.counters.splits - before.splits);
    try testing.expectEqual(1, tree.counters.root_splits - before.root_splits);
    try tree.validate();

    // Top-down splits its interior root one put earlier (at 25, in "the
    // canonical example, step by step"); 2 then splits only the leaf. For
    // these thirteen keys both variants end with the same tree.
    var top: Tree4 = .empty;
    defer top.deinit(gpa);
    for (canonical_keys) |key| _ = try topdown.put(Tree4, &top, gpa, key, key * 10);
    const top_before = top.counters;
    try testing.expectEqual(null, try topdown.put(Tree4, &top, gpa, 2, 20));
    try expectTree(&top, "[10]\n[3 6] [20]\n[1 2] [5] [7] | [12 15 17] [25 30]\n");
    try testing.expectEqual(1, top.counters.splits - top_before.splits);
    try top.validate();
}

test "exercise 1: ascending keys, the first interior splits (root at 13, below the root at 22)" {
    const gpa = testing.allocator;
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    for (1..13) |key| _ = try tree.put(gpa, key, key);
    try expectTree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");
    // 13: leaf [10 11 12 13], 12 goes up. Root [3 6 9 12] with five
    // children: 9 goes up, [3 6] keeps three children, [12] gets two.
    var before = tree.counters;
    _ = try tree.put(gpa, 13, 13);
    try expectTree(&tree, "[9]\n[3 6] [12]\n[1 2] [4 5] [7 8] | [10 11] [13]\n");
    try testing.expectEqual(2, tree.counters.splits - before.splits);
    try testing.expectEqual(1, tree.counters.root_splits - before.root_splits);
    // 14 to 21: two leaf splits (at 16 and 19) fill the interior node [12 15 18].
    for (14..22) |key| _ = try tree.put(gpa, key, key);
    try expectTree(&tree, "[9]\n[3 6] [12 15 18]\n[1 2] [4 5] [7 8] | [10 11] [13 14] [16 17] [19 20 21]\n");
    // 22: leaf [19 20 21 22], 21 goes up. [12 15 18 21] is an interior node
    // that is NOT the root: its median 18 goes into the existing root, which
    // has room. No new root, same height.
    before = tree.counters;
    _ = try tree.put(gpa, 22, 22);
    try expectTree(&tree, "[9 18]\n[3 6] [12 15] [21]\n[1 2] [4 5] [7 8] | [10 11] [13 14] [16 17] | [19 20] [22]\n");
    try testing.expectEqual(2, tree.counters.splits - before.splits);
    try testing.expectEqual(0, tree.counters.root_splits - before.root_splits);
    try tree.validate();
}

test "neither variant is always the taller one" {
    const gpa = testing.allocator;
    // The canonical keys make the top-down tree taller (height 3 against 2,
    // see the first test of this file). These ten keys make it SHORTER. The
    // two variants cut at different points (bottom-up cuts M keys and leaves
    // M / 2 on the left, top-down cuts M - 1 keys and leaves M / 2 - 1 on
    // each side), so the keys spread over the nodes differently, and the put
    // that overflows the root of one tree does not overflow the other.
    var bottom: Tree4 = .empty;
    defer bottom.deinit(gpa);
    var top: Tree4 = .empty;
    defer top.deinit(gpa);
    for ([_]u64{ 82, 83, 57, 74, 11, 67, 62, 48, 9, 29 }) |key| {
        _ = try bottom.put(gpa, key, key);
        _ = try topdown.put(Tree4, &top, gpa, key, key);
    }
    try expectTree(&bottom, "[67]\n[29 57] [82]\n[9 11] [48] [62] | [74] [83]\n");
    try expectTree(&top, "[11 57 82]\n[9] [29 48] [62 67 74] [83]\n");
    try bottom.validate();
    try top.validate();
}

test "why top-down needs an even M: the arithmetic" {
    // A full node has M - 1 keys; without its median, M - 2 are left for two
    // halves that each need min_keys = ceil(M/2) - 1.
    inline for (.{ 4, 6, 8, 64 }) |M| try testing.expect((M - 2) / 2 >= (M + 1) / 2 - 1);
    inline for (.{ 3, 5, 7, 63 }) |M| try testing.expect((M - 2) / 2 < (M + 1) / 2 - 1);
    // Bottom-up splits M keys (the new one included): M - 1 to share, enough for every M.
    inline for (.{ 3, 4, 5, 6, 7, 8 }) |M| try testing.expect((M - 1) / 2 >= (M + 1) / 2 - 1);
    // `topdown.put(BTree(5, ...), ...)` is a compile error with that message.
}

/// The same operation stream goes into a bottom-up tree, a top-down tree and
/// the oracle. Every answer must agree and both trees must stay valid.
fn modelTestBothVariants(comptime M: usize, comptime PoolFn: fn (type) type, seed: u64) !void {
    const gpa = testing.allocator;
    const Tree = BTree(M, PoolFn);
    var bottom: Tree = .empty;
    defer bottom.deinit(gpa);
    var top: Tree = .empty;
    defer top.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var stream = ops.OpStream.init(.{ .seed = seed, .count = 1500, .key_space = 400, .weights = .{ .put = 5, .delete = 0, .get = 2, .range = 1 } });
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| {
                const want = try oracle.put(gpa, p.key, p.value);
                try testing.expectEqual(want, try bottom.put(gpa, p.key, p.value));
                try testing.expectEqual(want, try topdown.put(Tree, &top, gpa, p.key, p.value));
            },
            .delete => unreachable, // weight 0
            .get => |g| {
                try testing.expectEqual(oracle.get(g.key), bottom.get(g.key));
                try testing.expectEqual(oracle.get(g.key), top.get(g.key));
            },
            .range => |r| {
                var a: base_tests.RangeCheck = .{ .expected = oracle.range(r.lo, r.hi) };
                bottom.range(r.lo, r.hi, &a);
                var b: base_tests.RangeCheck = .{ .expected = oracle.range(r.lo, r.hi) };
                top.range(r.lo, r.hi, &b);
                try testing.expect(a.ok and b.ok and a.seen == a.expected.len and b.seen == b.expected.len);
            },
        }
        try testing.expectEqual(oracle.len(), top.len);
        try bottom.validate();
        try top.validate(); // every invariant, after every operation
    }
    // Same keys and values, in the same order, in both trees.
    var all_bottom: base_tests.RangeCheck = .{ .expected = oracle.range(0, 400) };
    bottom.inOrder(&all_bottom);
    var all_top: base_tests.RangeCheck = .{ .expected = oracle.range(0, 400) };
    top.inOrder(&all_top);
    try testing.expect(all_bottom.ok and all_bottom.seen == oracle.len());
    try testing.expect(all_top.ok and all_top.seen == oracle.len());
    // Nothing is asserted about the two heights: either tree can be the
    // taller one (see "neither variant is always the taller one").
}

test "model test: bottom-up and top-down hold the same keys, every even order from 4 to 12, both pools" {
    inline for (.{ pool.DirectNodes, pool.StdPool }, 0..) |PoolFn, p| {
        inline for (.{ 4, 6, 8, 10, 12 }) |M| try modelTestBothVariants(M, PoolFn, 100 * p + M);
    }
}

test "top-down put under allocation failure: valid tree, same keys, the finished splits stay" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    for (1..13) |key| _ = try tree.put(gpa, key, key);
    try expectTree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");

    // The root split needs two nodes. If the second is missing, the first is
    // handed back and nothing has changed, counters included.
    const usage = tree.pool.usage;
    failing.fail_index = failing.alloc_index + 1;
    try testing.expectError(error.OutOfMemory, topdown.put(Tree4, &tree, gpa, 13, 13));
    try testing.expectEqual(usage, tree.pool.usage);
    try testing.expectEqual(3, tree.counters.splits);
    try expectTree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");

    // Now the root split succeeds and the leaf split below it fails. The
    // root split is not undone: the tree is valid and holds the same 12
    // keys, one level taller.
    failing.fail_index = failing.alloc_index + 2;
    try testing.expectError(error.OutOfMemory, topdown.put(Tree4, &tree, gpa, 13, 13));
    try expectTree(&tree, "[6]\n[3] [9]\n[1 2] [4 5] | [7 8] [10 11 12]\n");
    try testing.expectEqual(12, tree.len);
    try testing.expectEqual(null, tree.get(13));
    try testing.expectEqual(usage.created + 2, tree.pool.usage.created); // real nodes of the tree

    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(null, try topdown.put(Tree4, &tree, gpa, 13, 13));
    try expectTree(&tree, "[6]\n[3] [9 11]\n[1 2] [4 5] | [7 8] [10] [12 13]\n");
}

fn TopDownBuild(comptime PoolFn: fn (type) type) type {
    return struct {
        const Tree = BTree(4, PoolFn);

        /// For checkAllAllocationFailures: every allocation of this build
        /// fails once. The put that hits it must leave a valid tree with
        /// exactly the keys inserted so far.
        fn run(gpa: Allocator) !void {
            var tree: Tree = .empty;
            defer tree.deinit(gpa);
            for (0..base_build_count) |i| {
                _ = topdown.put(Tree, &tree, gpa, buildKey(i), i) catch |err| {
                    try testing.expectEqual(i, tree.len);
                    try testing.expectEqual(null, tree.get(buildKey(i)));
                    for (0..i) |j| try testing.expectEqual(j, tree.get(buildKey(j)));
                    try tree.validate();
                    return err;
                };
            }
            try tree.validate();
        }
    };
}

const base_build_count = 80;
fn buildKey(i: usize) u64 {
    return (i * 37) % base_build_count; // 37 and 80 are coprime: every key once, scattered
}

test "top-down: every allocation in a build may fail; the tree stays valid and nothing leaks" {
    inline for (.{ pool.DirectNodes, pool.StdPool }) |PoolFn| {
        try testing.checkAllAllocationFailures(testing.allocator, TopDownBuild(PoolFn).run, .{});
    }
}
