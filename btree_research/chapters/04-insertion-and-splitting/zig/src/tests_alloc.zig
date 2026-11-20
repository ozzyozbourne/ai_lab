//! The allocator side of this chapter: `std.heap.MemoryPool` as the node
//! pool, and `std.testing.checkAllAllocationFailures` as the proof that a
//! failed bottom-up `put` leaves the tree unchanged.
//!
//! checkAllAllocationFailures(gpa, f, args) calls f once to count its
//! allocations, then once per allocation with exactly that allocation (and
//! all later ones) failing. Each of those runs must return
//! error.OutOfMemory and free everything it allocated.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const BTree = @import("base_btree.zig").BTree;
const pool = @import("base_pool.zig");
const Node = @import("base_node.zig").Node;

const key_count = 120;
fn keyAt(i: usize) u64 {
    return (i * 77) % key_count; // 77 and 120 are coprime: every key once, scattered
}

fn renderTo(tree: anytype, out: *std.Io.Writer.Allocating) !void {
    out.clearRetainingCapacity();
    try tree.render(&out.writer, "");
}

fn Build(comptime M: usize, comptime PoolFn: fn (type) type) type {
    return struct {
        const Tree = BTree(M, PoolFn);

        /// `gpa` is the allocator under test (it will fail). The snapshots
        /// use `testing.allocator` directly, so they are not part of the
        /// experiment.
        fn run(gpa: Allocator) !void {
            var tree: Tree = .empty;
            defer tree.deinit(gpa);
            var before: std.Io.Writer.Allocating = .init(testing.allocator);
            defer before.deinit();
            var after: std.Io.Writer.Allocating = .init(testing.allocator);
            defer after.deinit();
            for (0..key_count) |i| {
                try renderTo(&tree, &before);
                const usage = tree.pool.usage;
                const counters = tree.counters;
                _ = tree.put(gpa, keyAt(i), i) catch |err| {
                    // The put failed. Nothing may have changed: not the
                    // picture of the tree, not a counter.
                    try renderTo(&tree, &after);
                    try testing.expectEqualStrings(before.written(), after.written());
                    try testing.expectEqual(usage, tree.pool.usage);
                    try testing.expectEqual(counters, tree.counters);
                    try testing.expectEqual(i, tree.len);
                    try tree.validate();
                    return err;
                };
            }
            try tree.validate();
        }
    };
}

test "checkAllAllocationFailures: a failed put leaves the tree unchanged (MemoryPool and per-node allocation)" {
    inline for (.{ pool.StdPool, pool.DirectNodes }) |PoolFn| {
        inline for (.{ 3, 4, 7 }) |M| {
            try testing.checkAllAllocationFailures(testing.allocator, Build(M, PoolFn).run, .{});
        }
    }
}

test "MemoryPool asks the backing allocator once per node, DirectNodes too; only the pool keeps freed slots" {
    // Count what a build costs the backing allocator.
    inline for (.{ pool.StdPool, pool.DirectNodes }) |PoolFn| {
        var counting: testing.FailingAllocator = .init(testing.allocator, .{});
        const gpa = counting.allocator();
        var tree: BTree(4, PoolFn) = .empty;
        defer tree.deinit(gpa);
        for (0..key_count) |i| _ = try tree.put(gpa, keyAt(i), i);
        try tree.validate();
        const nodes = tree.shape().nodes;
        try testing.expectEqual(nodes, tree.pool.usage.live());
        // An insert-only tree never destroys a node.
        try testing.expectEqual(0, tree.pool.usage.destroyed);
        try testing.expect(counting.allocations >= 1 and counting.allocations <= nodes);
    }
}

test "MemoryPool.addCapacity: reserve first, then create cannot fail" {
    // The reservation step of `put` in one call: after addCapacity(n) the
    // next n creates are served from the pool's free list and never touch
    // the backing allocator.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var nodes: std.heap.MemoryPool(Node(4)) = .empty;
    defer nodes.deinit(gpa);
    try nodes.addCapacity(gpa, 3);
    failing.fail_index = failing.alloc_index; // from now on every allocation fails
    for (0..3) |_| _ = try nodes.create(gpa);
    try testing.expectError(error.OutOfMemory, nodes.create(gpa));
}
