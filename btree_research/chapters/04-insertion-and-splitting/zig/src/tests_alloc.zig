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

test "what a build asks of the backing allocator: one request per node, or far fewer with MemoryPool" {
    var requests: [2]usize = undefined;
    var node_count: usize = 0;
    inline for (.{ pool.DirectNodes, pool.StdPool }, 0..) |PoolFn, p| {
        var counting: testing.FailingAllocator = .init(testing.allocator, .{});
        const gpa = counting.allocator();
        var tree: BTree(4, PoolFn) = .empty;
        defer tree.deinit(gpa);
        for (0..key_count) |i| _ = try tree.put(gpa, keyAt(i), i);
        try tree.validate();
        node_count = tree.shape().nodes;
        try testing.expectEqual(node_count, tree.pool.usage.live());
        try testing.expectEqual(0, tree.pool.usage.destroyed); // an insert-only tree never frees a node
        requests[p] = counting.allocations;
    }
    try testing.expectEqual(node_count, requests[0]); // DirectNodes: exactly one per node
    // MemoryPool cuts its slots from an arena, and the arena asks for memory
    // in growing blocks, so many nodes share one request.
    try testing.expect(requests[1] < requests[0] / 4);
}

test "MemoryPool.addCapacity: reserve first, then create does not allocate" {
    // The reservation step of `put` as one call: after addCapacity(n) the
    // next n creates are served from the pool's free list and never reach
    // the backing allocator, so they cannot fail.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var nodes: std.heap.MemoryPool(Node(4)) = .empty;
    defer nodes.deinit(gpa);
    try nodes.addCapacity(gpa, 3);
    failing.fail_index = failing.alloc_index; // from now on every allocation fails
    for (0..3) |_| _ = try nodes.create(gpa);
    try testing.expect(!failing.has_induced_failure); // nobody even asked
}
