// Copied from chapters/05-deletion-and-rebalancing/zig/src/pool.zig; do not edit here.
// Trimmed: the contract, `Usage` and `DirectNodes` are kept; `FreeListPool` and
// `StdPool` (chapters 05 and 04) and their tests are left out.
//! SECTION 2: node allocation.
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
//! in ANOTHER file works as long as it has these five members. Two rules come
//! with it:
//!
//!   * Every pool keeps `usage` up to date: `usage.onCreate()` after each
//!     successful `create`, `usage.onDestroy()` in each `destroy`. The tree
//!     relies on it (`validate` compares `usage.live()` with the nodes
//!     reachable from the root).
//!   * A pool that cannot give a single node back (a bump allocator, an
//!     arena) still counts in `destroy` and otherwise does nothing; its
//!     memory is released in `deinit`.
//!
//! The backing allocator `gpa` is passed to every call (Zig's "unmanaged"
//! style): the pool stores no allocator, and the caller can see exactly where
//! memory may be requested.
//!
//!   DirectNodes   one `gpa.create` / `gpa.destroy` per node. Slow, but with
//!                 `std.testing.allocator` every single node is tracked, so a
//!                 forgotten node is a reported leak and a node destroyed
//!                 twice is a reported double free. Used by the tests.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Counters every pool keeps, so the tree can check "no node was lost"
/// (`live() == number of nodes reachable from the root`) even when the
/// backing allocator cannot see individual nodes.
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

const TestItem = struct { a: u64, b: u64 };

test "DirectNodes: create, destroy, counters" {
    const gpa = std.testing.allocator;
    var pool: DirectNodes(TestItem) = .empty;
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
