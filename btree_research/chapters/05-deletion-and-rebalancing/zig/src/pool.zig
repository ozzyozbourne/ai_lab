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
//! tests_insert.zig has such an outside pool ("a pool written outside
//! pool.zig satisfies the contract").
//!
//! The backing allocator `gpa` is passed to every call (Zig's "unmanaged"
//! style): the pool stores no allocator, and the caller can see exactly where
//! memory may be requested.
//!
//! Three implementations, same interface, chosen at compile time with
//! `BTree(M, PoolFn)`:
//!
//!   DirectNodes   one `gpa.create` / `gpa.destroy` per node. Slow, but with
//!                 `std.testing.allocator` every single node is tracked, so a
//!                 forgotten node is a reported leak and a node destroyed
//!                 twice is a reported double free. Used by the tests.
//!   FreeListPool  hand-written: nodes are carved from chunks; destroyed nodes
//!                 go on an intrusive free list and are handed out again.
//!   StdPool       the same idea from the standard library: `std.heap.MemoryPool`.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Counters every pool keeps, so the tree can check "no node was lost"
/// (`live() == number of nodes reachable from the root`) even when the
/// backing allocator cannot see individual nodes.
///
/// `put` restores `usage` when it fails (insert.zig), so the counters always
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

/// Hand-written fixed-size pool.
///
/// Memory is requested from `gpa` one chunk (`chunk_len` slots) at a time.
/// A slot is in one of three states:
///   never used   beyond `chunk.used` in the newest chunk
///   live         handed out by `create`
///   free         returned by `destroy`; its first bytes are reused to store
///                the pointer to the next free slot (an *intrusive* list:
///                the list costs no memory of its own)
/// `create` pops the free list (LIFO: the most recently freed, cache-warm
/// slot first) and only carves a new slot when the list is empty. Memory goes
/// back to `gpa` only in `deinit`.
pub fn FreeListPool(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const chunk_len = 32;

        const FreeLink = struct { next: ?*FreeLink };
        const Chunk = struct { next: ?*Chunk, used: usize, slots: [chunk_len]T };

        comptime {
            // A free slot must be able to hold a FreeLink.
            std.debug.assert(@sizeOf(T) >= @sizeOf(FreeLink));
            std.debug.assert(@alignOf(T) >= @alignOf(FreeLink));
        }

        /// Head of the free list.
        free: ?*FreeLink = null,
        /// All chunks, newest first. Only the newest can have never-used slots.
        chunks: ?*Chunk = null,
        /// Slots ever carved from chunks (never-used -> live transitions).
        /// Equals `usage.peak` unless a `put` failed half-way through its
        /// reservation: the slot carved for a returned reservation stays on
        /// the free list.
        carved: u64 = 0,
        usage: Usage = .{},

        pub const empty: Self = .{};

        pub fn create(self: *Self, gpa: Allocator) Allocator.Error!*T {
            if (self.free) |link| {
                self.free = link.next;
                self.usage.onCreate();
                return @ptrCast(@alignCast(link));
            }
            if (self.chunks == null or self.chunks.?.used == chunk_len) {
                const chunk = try gpa.create(Chunk); // the only place that can fail
                chunk.next = self.chunks;
                chunk.used = 0;
                self.chunks = chunk;
            }
            const chunk = self.chunks.?;
            const item = &chunk.slots[chunk.used];
            chunk.used += 1;
            self.carved += 1;
            self.usage.onCreate();
            return item;
        }

        pub fn destroy(self: *Self, gpa: Allocator, item: *T) void {
            _ = gpa; // the slot stays ours; nothing goes back to the allocator
            self.usage.onDestroy();
            item.* = undefined; // debug builds fill with 0xAA: use-after-free shows up fast
            const link: *FreeLink = @ptrCast(@alignCast(item));
            link.next = self.free;
            self.free = link;
        }

        /// Frees every chunk. Any node still in use becomes a dangling pointer,
        /// so the tree must be done with all of them.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            var chunk = self.chunks;
            while (chunk) |c| {
                chunk = c.next;
                gpa.destroy(c);
            }
            self.* = undefined;
        }
    };
}

/// `std.heap.MemoryPool` behind the same interface. It does what
/// `FreeListPool` does (free list first, otherwise fresh memory from an
/// internal arena).
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
    inline for (.{ DirectNodes, FreeListPool, StdPool }) |PoolFn| {
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

test "FreeListPool and StdPool hand a destroyed slot out again (LIFO)" {
    const gpa = std.testing.allocator;
    inline for (.{ FreeListPool, StdPool }) |PoolFn| {
        var pool: PoolFn(TestItem) = .empty;
        defer pool.deinit(gpa);
        const a = try pool.create(gpa);
        const b = try pool.create(gpa);
        pool.destroy(gpa, a);
        pool.destroy(gpa, b);
        try std.testing.expectEqual(b, try pool.create(gpa)); // last freed, first reused
        try std.testing.expectEqual(a, try pool.create(gpa));
    }
}

test "FreeListPool grows by whole chunks and carves each slot once" {
    const gpa = std.testing.allocator;
    const Pool = FreeListPool(TestItem);
    var pool: Pool = .empty;
    defer pool.deinit(gpa); // forgetting this line fails the test: the chunks leak
    var items: [Pool.chunk_len + 1]*TestItem = undefined;
    for (&items) |*slot| slot.* = try pool.create(gpa);
    try std.testing.expect(pool.chunks.?.next != null); // second chunk exists
    try std.testing.expectEqual(1, pool.chunks.?.used);
    for (items) |item| pool.destroy(gpa, item);
    for (&items) |*slot| slot.* = try pool.create(gpa);
    try std.testing.expectEqual(Pool.chunk_len + 1, pool.carved); // all reused, none carved
    try std.testing.expectEqual(2 * (Pool.chunk_len + 1), pool.usage.created);
}

test "FreeListPool reports allocation failure and stays usable" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var pool: FreeListPool(TestItem) = .empty;
    try std.testing.expectError(error.OutOfMemory, pool.create(failing.allocator()));
    try std.testing.expectEqual(0, pool.usage.created);
    defer pool.deinit(std.testing.allocator);
    _ = try pool.create(std.testing.allocator);
}

test "FreeListPool does not notice a double destroy" {
    // The bug: destroy(a) twice. The second call links the slot to itself,
    // so the free list never runs out and every later create returns `a`.
    // No counter looks wrong (two creates, two destroys). With DirectNodes
    // and std.testing.allocator the second destroy stops the program:
    // "panic: double free of [addr: ..., len: 16 ...]" (README, exercise 5).
    const gpa = std.testing.allocator;
    var pool: FreeListPool(TestItem) = .empty;
    defer pool.deinit(gpa);
    const a = try pool.create(gpa);
    _ = try pool.create(gpa);
    pool.destroy(gpa, a);
    pool.destroy(gpa, a);
    try std.testing.expectEqual(2, pool.usage.destroyed);
    for (0..3) |_| try std.testing.expectEqual(a, try pool.create(gpa)); // one slot, three owners
    try std.testing.expectEqual(4, pool.usage.live()); // plausible, and wrong
    try std.testing.expectEqual(2, pool.carved);
}

test "SafeAllocator sees a node that DirectNodes forgot, but not one a pool forgot" {
    // A private SafeAllocator, so the leaks made on purpose do not fail this test.
    var safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    const gpa = safe.allocator();

    var direct: DirectNodes(TestItem) = .empty;
    _ = try direct.create(gpa); // never destroyed
    direct.deinit(gpa);

    var pooled: FreeListPool(TestItem) = .empty;
    _ = try pooled.create(gpa); // never destroyed either ...
    try std.testing.expectEqual(1, pooled.usage.live()); // ... only the counter knows
    pooled.deinit(gpa); // ... because the chunk it lives in is freed here

    try std.testing.expectEqual(1, safe.deinitLog(false)); // exactly one leak: the direct node
}
