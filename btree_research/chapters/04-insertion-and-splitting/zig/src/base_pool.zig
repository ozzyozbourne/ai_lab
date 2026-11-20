// Copied from chapters/05-deletion-and-rebalancing/zig/src/pool.zig; fixes go there first
//! Node allocation.
//!
//! The tree never calls an allocator directly. It asks a *node pool* for a
//! node and gives nodes back to it. A node pool is any type `P(T)` with:
//!
//!     pub const empty: P(T);
//!     pub fn create(self: *P(T), gpa: Allocator) Allocator.Error!*T   // contents undefined
//!     pub fn destroy(self: *P(T), gpa: Allocator, item: *T) void
//!     pub fn deinit(self: *P(T), gpa: Allocator) void                 // release everything
//!     usage: Usage                                                    // counters
//!
//! The contract is structural (duck typing at compile time): a pool written
//! in ANOTHER file works with `BTree(M, PoolFn)` as long as it has these five
//! members. Two rules come with it:
//!
//!   * Every pool keeps `usage` up to date: `usage.onCreate()` after each
//!     successful `create`, `usage.onDestroy()` in each `destroy`. The tree
//!     relies on it (`deinit` asserts `usage.live() == 0`, `validate`
//!     compares `usage.live()` with the nodes reachable from the root).
//!   * A pool that cannot give a single node back (a bump allocator, an
//!     arena) still counts in `destroy` and otherwise does nothing; its
//!     memory is released in `deinit`.
//!
//! base_tests_insert.zig has such an outside pool ("a pool written outside
//! base_pool.zig satisfies the contract").
//!
//! The backing allocator `gpa` is passed to every call (Zig's "unmanaged"
//! style): the pool stores no allocator, and the caller can see exactly where
//! memory may be requested.
//!
//! Two implementations, same interface, chosen at compile time with
//! `BTree(M, PoolFn)` (chapter 05 adds a hand-written free-list pool; it was
//! trimmed from this copy):
//!
//!   DirectNodes   one `gpa.create` / `gpa.destroy` per node. Slow, but with
//!                 `std.testing.allocator` every single node is tracked, so a
//!                 forgotten node is a reported leak. Used by the tests.
//!   StdPool       `std.heap.MemoryPool`: this chapter's node allocator.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Counters every pool keeps, so the tree can check "no node was lost"
/// (`live() == number of nodes reachable from the root`) even when the
/// backing allocator cannot see individual nodes.
///
/// `put` restores `usage` when it fails (base_insert.zig), so the counters always
/// describe nodes that were part of the tree, never returned reservations.
pub const Usage = struct {
    created: u64 = 0,
    destroyed: u64 = 0,
    peak: u64 = 0,

    pub fn live(self: Usage) u64 {
        return self.created - self.destroyed;
    }

    /// Call after every successful `create`.
    pub fn onCreate(self: *Usage) void {
        self.created += 1;
        self.peak = @max(self.peak, self.live());
    }

    /// Call in every `destroy`.
    pub fn onDestroy(self: *Usage) void {
        std.debug.assert(self.live() > 0); // more destroys than creates: a double free
        self.destroyed += 1;
    }
};

/// No pooling at all: every node is its own allocation.
pub fn DirectNodes(comptime T: type) type {
    return struct {
        const Self = @This();
        usage: Usage = .{},

        pub const empty: Self = .{};

        pub fn create(self: *Self, gpa: Allocator) Allocator.Error!*T {
            const item = try gpa.create(T);
            self.usage.onCreate();
            return item;
        }

        pub fn destroy(self: *Self, gpa: Allocator, item: *T) void {
            self.usage.onDestroy();
            gpa.destroy(item);
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            _ = gpa; // nothing is held back: live nodes are the caller's leak
            self.* = undefined;
        }
    };
}

/// `std.heap.MemoryPool` behind the same interface. All nodes have the same
/// size, so the pool hands out fixed-size slots: a destroyed slot goes on a
/// free list and is reused first (LIFO), otherwise a fresh slot is cut from
/// an internal arena. Memory returns to `gpa` only in `deinit`.
pub fn StdPool(comptime T: type) type {
    return struct {
        const Self = @This();
        inner: std.heap.MemoryPool(T) = .empty,
        usage: Usage = .{},

        pub const empty: Self = .{};

        pub fn create(self: *Self, gpa: Allocator) Allocator.Error!*T {
            const item = try self.inner.create(gpa);
            self.usage.onCreate();
            return item;
        }

        pub fn destroy(self: *Self, gpa: Allocator, item: *T) void {
            _ = gpa;
            self.usage.onDestroy();
            self.inner.destroy(item);
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.inner.deinit(gpa);
            self.* = undefined;
        }
    };
}

const TestItem = struct { a: u64, b: u64 };

test "every pool: create, destroy, counters" {
    const gpa = std.testing.allocator;
    inline for (.{ DirectNodes, StdPool }) |PoolFn| {
        var pool: PoolFn(TestItem) = .empty;
        defer pool.deinit(gpa);
        const x = try pool.create(gpa);
        const y = try pool.create(gpa);
        x.* = .{ .a = 1, .b = 2 };
        y.* = .{ .a = 3, .b = 4 };
        try std.testing.expectEqual(1, x.a); // y did not overwrite x
        pool.destroy(gpa, x);
        try std.testing.expectEqual(1, pool.usage.live());
        pool.destroy(gpa, y);
        try std.testing.expectEqual(2, pool.usage.created);
        try std.testing.expectEqual(2, pool.usage.peak);
        try std.testing.expectEqual(0, pool.usage.live());
    }
}

test "StdPool hands a destroyed slot out again (LIFO)" {
    const gpa = std.testing.allocator;
    var pool: StdPool(TestItem) = .empty;
    defer pool.deinit(gpa); // forgetting this line fails the test: the pool's memory leaks
    const a = try pool.create(gpa);
    const b = try pool.create(gpa);
    pool.destroy(gpa, a);
    pool.destroy(gpa, b);
    try std.testing.expectEqual(b, try pool.create(gpa)); // last freed, first reused
    try std.testing.expectEqual(a, try pool.create(gpa));
}

test "StdPool reports allocation failure and stays usable" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var pool: StdPool(TestItem) = .empty;
    try std.testing.expectError(error.OutOfMemory, pool.create(failing.allocator()));
    try std.testing.expectEqual(0, pool.usage.created);
    defer pool.deinit(std.testing.allocator);
    _ = try pool.create(std.testing.allocator);
}

test "SafeAllocator sees a node that DirectNodes forgot, but not one a pool forgot" {
    // A private SafeAllocator, so the leaks made on purpose do not fail this test.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const gpa = safe.allocator();

    var direct: DirectNodes(TestItem) = .empty;
    _ = try direct.create(gpa); // never destroyed
    direct.deinit(gpa);

    var pooled: StdPool(TestItem) = .empty;
    _ = try pooled.create(gpa); // never destroyed either ...
    try std.testing.expectEqual(1, pooled.usage.live()); // ... only the counter knows
    pooled.deinit(gpa); // ... because the pool frees all its memory here

    try std.testing.expectEqual(1, safe.deinitLog(false)); // exactly one leak: the direct node
}
