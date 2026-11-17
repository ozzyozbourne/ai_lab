//! Tests of the whole tree. (Each section file also has its own unit tests.)
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const BTree = @import("btree.zig").BTree;
const pool = @import("pool.zig");
const ops = @import("ops.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;
const scenario = @import("scenario.zig");

/// Tests default to DirectNodes: with `testing.allocator` every node is an
/// allocation of its own, so a node the tree forgets fails the test as a
/// leak, and a node freed twice aborts it as a double free.
const Tree4 = BTree(4, pool.DirectNodes);

fn expectTree(tree: anytype, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try tree.render(&out.writer, "");
    try testing.expectEqualStrings(expected, out.written());
    try tree.validate();
}

fn buildCanonical(gpa: Allocator) !Tree4 {
    var tree: Tree4 = .empty;
    errdefer tree.deinit(gpa);
    for (scenario.canonical_keys) |key| _ = try tree.put(gpa, key, key * 10);
    return tree;
}

test "put: the canonical example, step by step" {
    const gpa = testing.allocator;
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    try expectTree(&tree, "(empty)\n");
    for ([_]u64{ 10, 20, 5 }) |key| _ = try tree.put(gpa, key, key * 10);
    try expectTree(&tree, "[5 10 20]\n");
    _ = try tree.put(gpa, 6, 60); // overflow: split, 10 becomes the root
    try expectTree(&tree, "[10]\n[5 6] [20]\n");
    for ([_]u64{ 12, 30, 7, 17 }) |key| _ = try tree.put(gpa, key, key * 10);
    try expectTree(&tree, "[10 20]\n[5 6 7] [12 17] [30]\n");
    for ([_]u64{ 3, 25, 1, 15 }) |key| _ = try tree.put(gpa, key, key * 10);
    try expectTree(&tree, "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n");
    try testing.expectEqual(3, tree.counters.splits);
    try testing.expectEqual(1, tree.counters.root_splits);
}

test "put overwrites, get finds keys in leaves and interior nodes" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    try testing.expectEqual(12, tree.len);
    try testing.expectEqual(100, tree.get(10)); // interior
    try testing.expectEqual(150, tree.get(15)); // leaf
    try testing.expectEqual(null, tree.get(11));
    try testing.expectEqual(100, try tree.put(gpa, 10, 111));
    try testing.expectEqual(111, tree.get(10));
    try testing.expectEqual(12, tree.len);
}

test "shape and fill statistics" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    const s = tree.shape();
    try testing.expectEqual(2, s.height);
    try testing.expectEqual(5, s.nodes);
    try testing.expectEqual(4, s.leaves);
    try testing.expectEqual(12, s.keys);
    try testing.expectEqual(15, s.capacity); // 5 nodes * 3 keys
    try testing.expectEqual(80, s.fillPercent());
}

test "delete: leaf key without underflow" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    try testing.expectEqual(30, tree.delete(gpa, 3));
    try expectTree(&tree, "[6 10 20]\n[1 5] [7] [12 15 17] [25 30]\n");
    try testing.expectEqual(null, tree.delete(gpa, 3)); // already gone: no change
    try testing.expectEqual(null, tree.delete(gpa, 11));
    try expectTree(&tree, "[6 10 20]\n[1 5] [7] [12 15 17] [25 30]\n");
    try testing.expectEqual(11, tree.len);
}

test "delete: borrow from the left sibling rotates through the parent" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    _ = tree.delete(gpa, 7); // [7] becomes empty; [1 3 5] can spare a key
    try expectTree(&tree, "[5 10 20]\n[1 3] [6] [12 15 17] [25 30]\n");
    try testing.expectEqual(1, tree.counters.borrows_left);
    try testing.expectEqual(0, tree.counters.merges);
    try testing.expectEqual(60, tree.get(6)); // values travel with their keys
    try testing.expectEqual(50, tree.get(5));
}

test "delete: borrow from the right sibling when the left one is at minimum" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    for ([_]u64{ 3, 7 }) |key| _ = tree.delete(gpa, key);
    try expectTree(&tree, "[5 10 20]\n[1] [6] [12 15 17] [25 30]\n");
    _ = tree.delete(gpa, 6); // left [1] is at minimum, right [12 15 17] is not
    try expectTree(&tree, "[5 12 20]\n[1] [10] [15 17] [25 30]\n");
    try testing.expectEqual(1, tree.counters.borrows_right);
}

test "delete: interior key is replaced by its predecessor" {
    const gpa = testing.allocator;
    var tree = try buildCanonical(gpa);
    defer tree.deinit(gpa);
    try testing.expectEqual(200, tree.delete(gpa, 20));
    try expectTree(&tree, "[6 10 17]\n[1 3 5] [7] [12 15] [25 30]\n");
    try testing.expectEqual(1, tree.counters.predecessor_swaps);
    try testing.expectEqual(170, tree.get(17));
    // Predecessor taken from a minimal leaf: the leaf underflows and is repaired.
    try testing.expectEqual(100, tree.delete(gpa, 10));
    try expectTree(&tree, "[5 7 17]\n[1 3] [6] [12 15] [25 30]\n");
}

test "delete: merge, then the root shrinks" {
    const gpa = testing.allocator;
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    for ([_]u64{ 10, 20, 30, 40 }) |key| _ = try tree.put(gpa, key, key);
    try expectTree(&tree, "[30]\n[10 20] [40]\n");
    _ = tree.delete(gpa, 10);
    try expectTree(&tree, "[30]\n[20] [40]\n");
    try testing.expectEqual(3, tree.pool.usage.live());
    _ = tree.delete(gpa, 40); // nobody can lend: [20] + 30 + [] merge, root is empty
    try expectTree(&tree, "[20 30]\n");
    try testing.expectEqual(1, tree.counters.merges);
    try testing.expectEqual(1, tree.counters.root_shrinks);
    try testing.expectEqual(1, tree.pool.usage.live()); // two nodes went back to the pool
    _ = tree.delete(gpa, 20);
    _ = tree.delete(gpa, 30);
    try expectTree(&tree, "(empty)\n");
    try testing.expectEqual(0, tree.pool.usage.live());
    try testing.expectEqual(1, tree.counters.root_shrinks); // emptying a leaf root is not a shrink
}

test "delete: an underflow travels up through interior nodes" {
    const gpa = testing.allocator;
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    for (1..scenario.tall_count + 1) |key| _ = try tree.put(gpa, key, key * 10);
    try expectTree(&tree, "[9]\n[3 6] [12]\n[1 2] [4 5] [7 8] | [10 11] [13]\n");
    _ = tree.delete(gpa, 9); // predecessor 8 comes from two levels down
    _ = tree.delete(gpa, 13);
    try expectTree(&tree, "[8]\n[3 6] [11]\n[1 2] [4 5] [7] | [10] [12]\n");
    // Leaf merge empties interior node [11]; it borrows from interior [3 6],
    // and the child [7] changes parent together with the borrowed key.
    _ = tree.delete(gpa, 10);
    try expectTree(&tree, "[6]\n[3] [8]\n[1 2] [4 5] | [7] [11 12]\n");
    try testing.expectEqual(70, tree.get(7));
    _ = tree.delete(gpa, 1);
    _ = tree.delete(gpa, 2);
    try expectTree(&tree, "[6]\n[4] [8]\n[3] [5] | [7] [11 12]\n");
    // Leaf merge, interior merge, root shrink: three levels become two.
    const merges_before = tree.counters.merges;
    _ = tree.delete(gpa, 3);
    try expectTree(&tree, "[6 8]\n[4 5] [7] [11 12]\n");
    try testing.expectEqual(merges_before + 2, tree.counters.merges);
    try testing.expectEqual(1, tree.counters.root_shrinks);
}

/// Checks a range scan against the oracle's answer, entry by entry.
const RangeCheck = struct {
    expected: []const ops.Entry,
    seen: usize = 0,
    ok: bool = true,
    pub fn visit(self: *RangeCheck, key: u64, value: u64) void {
        if (self.seen >= self.expected.len or
            self.expected[self.seen].key != key or self.expected[self.seen].value != value) self.ok = false;
        self.seen += 1;
    }
};

fn modelTest(comptime M: usize, comptime PoolFn: fn (type) type, seed: u64) !void {
    const gpa = testing.allocator;
    var tree: BTree(M, PoolFn) = .empty;
    defer tree.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    // A small key space makes overwrites and deletes of present keys common.
    var stream = ops.OpStream.init(.{ .seed = seed, .count = 3000, .key_space = 120, .weights = .{ .put = 4, .delete = 4, .get = 2, .range = 1 } });
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try tree.put(gpa, p.key, p.value)),
            .delete => |d| try testing.expectEqual(oracle.delete(d.key), tree.delete(gpa, d.key)),
            .get => |g| try testing.expectEqual(oracle.get(g.key), tree.get(g.key)),
            .range => |r| {
                var check: RangeCheck = .{ .expected = oracle.range(r.lo, r.hi) };
                tree.range(r.lo, r.hi, &check);
                try testing.expect(check.ok and check.seen == check.expected.len);
            },
        }
        try testing.expectEqual(oracle.len(), tree.len);
        try tree.validate(); // every invariant, after every operation
    }
    var all: RangeCheck = .{ .expected = oracle.range(0, 120) };
    tree.inOrder(&all);
    try testing.expect(all.ok and all.seen == oracle.len());
}

test "model test: every order from 3 to 9, every pool, against the oracle" {
    inline for (.{ pool.DirectNodes, pool.FreeListPool, pool.StdPool }, 0..) |PoolFn, p| {
        inline for (3..10) |M| try modelTest(M, PoolFn, 100 * p + M);
    }
}

test "model test: the three pools produce the identical tree" {
    const gpa = testing.allocator;
    var a: BTree(4, pool.DirectNodes) = .empty;
    defer a.deinit(gpa);
    var b: BTree(4, pool.FreeListPool) = .empty;
    defer b.deinit(gpa);
    var c: BTree(4, pool.StdPool) = .empty;
    defer c.deinit(gpa);
    var stream = ops.OpStream.init(.{ .seed = 7, .count = 5000, .key_space = 300 });
    while (stream.next()) |op| switch (op) {
        .put => |p| {
            _ = try a.put(gpa, p.key, p.value);
            _ = try b.put(gpa, p.key, p.value);
            _ = try c.put(gpa, p.key, p.value);
        },
        .delete => |d| {
            _ = a.delete(gpa, d.key);
            _ = b.delete(gpa, d.key);
            _ = c.delete(gpa, d.key);
        },
        else => {},
    };
    var out_a: std.Io.Writer.Allocating = .init(gpa);
    defer out_a.deinit();
    try a.render(&out_a.writer, "");
    try expectTree(&b, out_a.written());
    try expectTree(&c, out_a.written());
    try testing.expectEqual(a.counters, b.counters);
    try testing.expectEqual(a.pool.usage, c.pool.usage);
    // The free list did its job: far fewer slots than create() calls.
    try testing.expectEqual(b.pool.usage.peak, b.pool.carved);
    try testing.expect(b.pool.carved < b.pool.usage.created);
}

test "delete everything in random order: every node goes back" {
    const gpa = testing.allocator;
    inline for (.{ 3, 4, 5, 8 }) |M| {
        var tree: BTree(M, pool.DirectNodes) = .empty;
        defer tree.deinit(gpa);
        var keys: [400]u64 = undefined;
        for (&keys, 0..) |*k, i| k.* = i * 3;
        var rng = SplitMix64.init(M);
        rng.shuffle(&keys);
        for (keys) |key| _ = try tree.put(gpa, key, key + 1);
        try tree.validate();
        try testing.expect(tree.shape().height >= 3);
        rng.shuffle(&keys);
        for (keys, 0..) |key, i| {
            try testing.expectEqual(key + 1, tree.delete(gpa, key));
            try testing.expectEqual(null, tree.get(key));
            if (i % 7 == 0) try tree.validate();
        }
        try testing.expectEqual(null, tree.root);
        try testing.expectEqual(0, tree.pool.usage.live());
        try testing.expectEqual(tree.pool.usage.created, tree.pool.usage.destroyed);
        // Every root split was undone by exactly one root shrink.
        try testing.expectEqual(tree.counters.root_splits, tree.counters.root_shrinks);
    }
}

test "put under allocation failure leaves the tree unchanged" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    // Keys 1..9 in order give [3 6] over [1 2] [4 5] [7 8 9]: the next
    // ascending key splits the right-most leaf, which needs one new node.
    for (1..10) |key| _ = try tree.put(gpa, key, key);
    try expectTree(&tree, "[3 6]\n[1 2] [4 5] [7 8 9]\n");

    failing.fail_index = failing.alloc_index; // the very next allocation fails
    try testing.expectError(error.OutOfMemory, tree.put(gpa, 10, 10));
    try expectTree(&tree, "[3 6]\n[1 2] [4 5] [7 8 9]\n"); // nothing changed, nothing leaked
    try testing.expectEqual(9, tree.len);

    // Overwrites and inserts into a node with room need no memory at all.
    try testing.expectEqual(5, try tree.put(gpa, 5, 55));
    _ = tree.delete(gpa, 9);
    try testing.expectEqual(null, try tree.put(gpa, 9, 9));

    // A cascade needs several nodes; fail the LAST one. The earlier
    // reservations must be handed back (the errdefer in insert.zig).
    for ([_]u64{ 10, 11, 12 }) |key| {
        failing.fail_index = std.math.maxInt(usize);
        _ = try tree.put(gpa, key, key);
    }
    try expectTree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");
    const live = tree.pool.usage.live();
    failing.fail_index = failing.alloc_index + 2; // leaf split ok, root split ok, new root fails
    try testing.expectError(error.OutOfMemory, tree.put(gpa, 13, 13));
    try testing.expectEqual(live, tree.pool.usage.live());
    try expectTree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");

    failing.fail_index = std.math.maxInt(usize); // memory is back: the same put succeeds
    _ = try tree.put(gpa, 13, 13);
    try expectTree(&tree, "[9]\n[3 6] [12]\n[1 2] [4 5] [7 8] | [10 11] [13]\n");
}

/// checkAllAllocationFailures wants a plain `fn (Allocator, ...) !void`, so
/// the comptime pool choice is wrapped in a type.
fn BuildThenDrain(comptime PoolFn: fn (type) type) type {
    return struct {
        fn run(gpa: Allocator) !void {
            var tree: BTree(4, PoolFn) = .empty;
            defer tree.deinit(gpa);
            for (0..80) |i| _ = try tree.put(gpa, (i * 37) % 80, i);
            try tree.validate();
            for (0..80) |key| _ = tree.delete(gpa, key);
            try testing.expectEqual(null, tree.root);
        }
    };
}

test "every allocation in a build-and-drain run may fail without a leak" {
    // Runs the function once per allocation it makes, failing that one.
    inline for (.{ pool.DirectNodes, pool.FreeListPool, pool.StdPool }) |PoolFn| {
        try testing.checkAllAllocationFailures(testing.allocator, BuildThenDrain(PoolFn).run, .{});
    }
}

test "SafeAllocator reports nodes a broken tree would leak" {
    // Simulate the classic merge bug "unlink the node but forget to free it"
    // by dropping a whole tree without deinit. A private SafeAllocator keeps
    // the deliberate leak from failing this test; with testing.allocator the
    // same leak fails the test run.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const gpa = safe.allocator();
    var tree: Tree4 = .empty;
    for (scenario.canonical_keys) |key| _ = try tree.put(gpa, key, key);
    try testing.expectEqual(5, tree.shape().nodes);
    try testing.expectEqual(5, safe.deinitLog(false)); // one leak per node
}
