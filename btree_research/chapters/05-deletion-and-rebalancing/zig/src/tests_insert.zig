//! Tests of the tree that need only search and insert (chapters 03 and 04):
//! nothing in this file calls `delete`. The delete tests are in
//! tests_delete.zig, which reuses the helpers declared `pub` here.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const BTree = @import("btree.zig").BTree;
const pool = @import("pool.zig");
const ops = @import("ops.zig");

/// Tests default to DirectNodes: with `testing.allocator` every node is an
/// allocation of its own, so a node the tree forgets fails the test as a
/// leak, and a node freed twice aborts it as a double free.
pub const Tree4 = BTree(4, pool.DirectNodes);

/// The guide's canonical insertion order (chapters 03 to 08), M = 4.
pub const canonical_keys = [_]u64{ 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 };

pub fn expectTree(tree: anytype, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try tree.render(&out.writer, "");
    try testing.expectEqualStrings(expected, out.written());
    try tree.validate();
}

pub fn buildCanonical(gpa: Allocator) !Tree4 {
    var tree: Tree4 = .empty;
    errdefer tree.deinit(gpa);
    for (canonical_keys) |key| _ = try tree.put(gpa, key, key * 10);
    return tree;
}

/// Checks a range scan against the oracle's answer, entry by entry.
pub const RangeCheck = struct {
    expected: []const ops.Entry,
    seen: usize = 0,
    ok: bool = true,
    pub fn visit(self: *RangeCheck, key: u64, value: u64) void {
        if (self.seen >= self.expected.len or
            self.expected[self.seen].key != key or self.expected[self.seen].value != value) self.ok = false;
        self.seen += 1;
    }
};

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

test "the extreme keys 0 and maxInt(u64) are ordinary keys" {
    const gpa = testing.allocator;
    const max = std.math.maxInt(u64);
    var tree: Tree4 = .empty;
    defer tree.deinit(gpa);
    for ([_]u64{ max, 0, max - 1, 1, max - 2, 2 }) |key| _ = try tree.put(gpa, key, key ^ 5);
    try tree.validate();
    try testing.expectEqual(max ^ 5, tree.get(max));
    try testing.expectEqual(5, tree.get(0));
}

test "validate reports a leaked node" {
    // Simulate the classic merge bug "unlink the node but forget to free it":
    // one node is live in the pool that the root cannot reach. This works
    // with every pool, including those the leak checker cannot see into.
    const gpa = testing.allocator;
    inline for (.{ pool.DirectNodes, pool.FreeListPool, pool.StdPool }) |PoolFn| {
        var tree: BTree(4, PoolFn) = .empty;
        defer tree.deinit(gpa);
        for (canonical_keys) |key| _ = try tree.put(gpa, key, key * 10);
        try tree.validate();
        const orphan = try tree.pool.create(gpa);
        try testing.expectError(error.NodeCountMismatch, tree.validate());
        tree.pool.destroy(gpa, orphan);
        try tree.validate();
    }
}

test "a tree that validate rejects can still be printed and torn down" {
    // What a fuzz test of a broken tree does (chapter 06): validate returns
    // an error, the report prints the tree, the deferred deinit runs. None of
    // that may abort. Break the canonical tree by unlinking the leaf [7]: the
    // root keeps 3 keys but has only 3 of its 4 children, and one node is
    // live in the pool that deinit will not reach.
    const gpa = testing.allocator;
    inline for (.{ pool.DirectNodes, pool.FreeListPool, pool.StdPool }) |PoolFn| {
        var tree: BTree(4, PoolFn) = .empty;
        defer tree.deinit(gpa);
        for (canonical_keys) |key| _ = try tree.put(gpa, key, key * 10);
        const root = tree.root.?;
        const orphan = root.children[1].?;
        root.children[1] = null;
        try testing.expectError(error.MissingChild, tree.validate());
        try testing.expectEqual(4, tree.shape().nodes);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try tree.render(&out.writer, "");
        try testing.expectEqualStrings("[6 10 20]\n[1 3 5] [12 15 17] [25 30]\n", out.written());
        try testing.expectEqual(5, tree.pool.usage.live());
        // With one allocation per node the test allocator would (rightly)
        // report the orphan as a leak, so hand that one back. The pooling
        // pools keep it: their deinit frees it with its chunk.
        if (PoolFn(u64) == pool.DirectNodes(u64)) tree.pool.destroy(gpa, orphan);
    }
}

/// A node pool defined OUTSIDE pool.zig, to show what the contract in
/// pool.zig asks for. It is the simplest pool there is, a bump allocator
/// over a fixed array: `create` takes the next unused slot, `destroy` cannot
/// give a slot back and only counts. (Chapter 03 writes a real one.)
fn BumpPool(comptime T: type) type {
    return struct {
        const Self = @This();
        slots: [24]T = undefined,
        used: usize = 0,
        usage: pool.Usage = .{},

        pub const empty: Self = .{};

        pub fn create(self: *Self, gpa: Allocator) Allocator.Error!*T {
            _ = gpa; // all memory is inside the pool
            if (self.used == self.slots.len) return error.OutOfMemory;
            const item = &self.slots[self.used];
            self.used += 1;
            self.usage.onCreate();
            return item;
        }

        pub fn destroy(self: *Self, gpa: Allocator, item: *T) void {
            _ = .{ gpa, item };
            self.usage.onDestroy(); // count only: a bump allocator frees nothing
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            _ = gpa;
            self.* = undefined;
        }
    };
}

test "a pool written outside pool.zig satisfies the contract" {
    const gpa = testing.failing_allocator; // proves the tree asks only the pool
    var tree: BTree(4, BumpPool) = .empty;
    defer tree.deinit(gpa);
    for (canonical_keys) |key| _ = try tree.put(gpa, key, key * 10);
    try expectTree(&tree, "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n");
    try testing.expectEqual(5, tree.pool.usage.live());
    // Fill the pool: the put that needs a 25th node fails and changes nothing.
    var key: u64 = 100;
    const err = while (key < 200) : (key += 1) {
        _ = tree.put(gpa, key, key) catch |e| break e;
    } else return error.TestExpectedError;
    try testing.expectEqual(error.OutOfMemory, err);
    try testing.expectEqual(null, tree.get(key));
    try tree.validate();
}

fn modelTestPutOnly(comptime M: usize, comptime PoolFn: fn (type) type, seed: u64) !void {
    const gpa = testing.allocator;
    var tree: BTree(M, PoolFn) = .empty;
    defer tree.deinit(gpa);
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    // No deletes: the tree only grows. 400 possible keys in 1500 operations
    // give both fresh inserts and overwrites.
    var stream = ops.OpStream.init(.{ .seed = seed, .count = 1500, .key_space = 400, .weights = .{ .put = 5, .delete = 0, .get = 2, .range = 1 } });
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try tree.put(gpa, p.key, p.value)),
            .delete => unreachable, // weight 0
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
    var all: RangeCheck = .{ .expected = oracle.range(0, 400) };
    tree.inOrder(&all);
    try testing.expect(all.ok and all.seen == oracle.len());
    try testing.expect(tree.shape().height >= 3);
}

test "model test, puts only: every order from 3 to 9, every pool, against the oracle" {
    inline for (.{ pool.DirectNodes, pool.FreeListPool, pool.StdPool }, 0..) |PoolFn, p| {
        inline for (3..10) |M| try modelTestPutOnly(M, PoolFn, 100 * p + M);
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

    failing.fail_index = failing.alloc_index; // the next allocation fails, and all after it
    try testing.expectError(error.OutOfMemory, tree.put(gpa, 10, 10));
    try expectTree(&tree, "[3 6]\n[1 2] [4 5] [7 8 9]\n"); // nothing changed, nothing leaked
    try testing.expectEqual(9, tree.len);

    // Overwrites and inserts into a node with room need no memory at all.
    try testing.expectEqual(5, try tree.put(gpa, 5, 55));
    try testing.expectEqual(null, try tree.put(gpa, 0, 0));
    try expectTree(&tree, "[3 6]\n[0 1 2] [4 5] [7 8 9]\n");

    // A cascade needs several nodes; fail the LAST one. The earlier
    // reservations must be handed back (the errdefer in insert.zig).
    failing.fail_index = std.math.maxInt(usize);
    for ([_]u64{ 10, 11, 12 }) |key| _ = try tree.put(gpa, key, key);
    try expectTree(&tree, "[3 6 9]\n[0 1 2] [4 5] [7 8] [10 11 12]\n");
    const usage = tree.pool.usage;
    const counters = tree.counters;
    failing.fail_index = failing.alloc_index + 2; // leaf split ok, root split ok, new root fails
    try testing.expectError(error.OutOfMemory, tree.put(gpa, 13, 13));
    // Not only live(): created, destroyed and peak are as before too, so the
    // two reservations that were handed back left no trace in the statistics.
    try testing.expectEqual(usage, tree.pool.usage);
    try testing.expectEqual(counters, tree.counters);
    try testing.expectEqual(null, tree.get(13));
    try expectTree(&tree, "[3 6 9]\n[0 1 2] [4 5] [7 8] [10 11 12]\n");

    failing.fail_index = std.math.maxInt(usize); // memory is back: the same put succeeds
    _ = try tree.put(gpa, 13, 13);
    try expectTree(&tree, "[9]\n[3 6] [12]\n[0 1 2] [4 5] [7 8] | [10 11] [13]\n");
    try testing.expectEqual(usage.created + 3, tree.pool.usage.created);
}

const build_count = 80;
fn buildKey(i: usize) u64 {
    return (i * 37) % build_count; // 37 and 80 are coprime: every key once, scattered
}

/// checkAllAllocationFailures wants a plain `fn (Allocator, ...) !void`, so
/// the comptime pool choice is wrapped in a type.
fn Build(comptime PoolFn: fn (type) type) type {
    return struct {
        fn run(gpa: Allocator) !void {
            var tree: BTree(4, PoolFn) = .empty;
            defer tree.deinit(gpa);
            for (0..build_count) |i| _ = try tree.put(gpa, buildKey(i), i);
            try tree.validate();
        }

        /// Build the same tree, but allocation number `fail_at` fails. The
        /// put that hits it must change nothing, and must succeed when it is
        /// repeated with memory available. Returns false if the build needed
        /// fewer than `fail_at + 1` allocations.
        fn runWithOneFailure(fail_at: usize, out: *std.Io.Writer) !bool {
            var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_at });
            const gpa = failing.allocator();
            var tree: BTree(4, PoolFn) = .empty;
            defer tree.deinit(gpa);
            var failed = false;
            for (0..build_count) |i| {
                const usage = tree.pool.usage;
                const counters = tree.counters;
                if (tree.put(gpa, buildKey(i), i)) |old| {
                    try testing.expectEqual(null, old);
                    continue;
                } else |_| {}
                failed = true;
                try testing.expectEqual(usage, tree.pool.usage);
                try testing.expectEqual(counters, tree.counters);
                try testing.expectEqual(i, tree.len);
                try testing.expectEqual(null, tree.get(buildKey(i)));
                try tree.validate();
                failing.fail_index = std.math.maxInt(usize);
                try testing.expectEqual(null, try tree.put(gpa, buildKey(i), i));
            }
            try tree.validate();
            try tree.render(out, "");
            return failed;
        }
    };
}

test "every allocation in a build may fail without a leak" {
    // Runs the function once per allocation it makes, failing that one.
    inline for (.{ pool.DirectNodes, pool.FreeListPool, pool.StdPool }) |PoolFn| {
        try testing.checkAllAllocationFailures(testing.allocator, Build(PoolFn).run, .{});
    }
}

test "a put that fails in the middle of a build changes nothing, and the build goes on" {
    inline for (.{ pool.DirectNodes, pool.FreeListPool, pool.StdPool }) |PoolFn| {
        var want: std.Io.Writer.Allocating = .init(testing.allocator);
        defer want.deinit();
        try testing.expect(!try Build(PoolFn).runWithOneFailure(std.math.maxInt(usize), &want.writer));
        var fail_at: usize = 0;
        while (true) : (fail_at += 1) {
            var got: std.Io.Writer.Allocating = .init(testing.allocator);
            defer got.deinit();
            const failed = try Build(PoolFn).runWithOneFailure(fail_at, &got.writer);
            // The failure is invisible afterwards: same tree as without it.
            try testing.expectEqualStrings(want.written(), got.written());
            if (!failed) break;
        }
        try testing.expect(fail_at >= 2); // at least: first chunk, a later chunk
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
    for (canonical_keys) |key| _ = try tree.put(gpa, key, key);
    try testing.expectEqual(5, tree.shape().nodes);
    try testing.expectEqual(5, safe.deinitLog(false)); // one leak per node
}
