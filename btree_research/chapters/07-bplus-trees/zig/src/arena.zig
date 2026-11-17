//! Index arena: every node of the tree lives in ONE growable array and is
//! named by a 32-bit handle (`NodeId`), never by a pointer.
//!
//! Why handles instead of `*Node`:
//!   * a handle is 4 bytes (a pointer is 8), so internal nodes get denser;
//!   * a handle stays valid when the array grows and moves; a pointer does not;
//!   * a handle is exactly what an on-disk tree stores (a page number), so the
//!     code in this chapter keeps its shape when nodes become pages (chapter 12);
//!   * the whole tree is freed by freeing one array.
//!
//! Freed slots are threaded onto a free list (each free slot stores the id of
//! the next free slot) and are reused last-in-first-out, so the array never has
//! to shrink and `alloc` / `free` are O(1).
//!
//! THE RULE for pointers: `ptr(id)` and `get(id)` return pointers INTO the
//! array. They stay valid until the next call that may grow the array, which is
//! only `reserve` (and `alloc`, which calls it). `allocAssumeCapacity` and
//! `free` never move anything. The tree therefore reserves once at the top of
//! `put` and may keep node pointers for the rest of the operation.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Handle of a node: an index into the arena. `.nil` plays the role of a null
/// pointer (or of "page 0 = no page" in an on-disk format).
///
/// A non-exhaustive enum instead of a bare `u32` so that the compiler refuses
/// to mix handles up with key counts and array indices.
pub const NodeId = enum(u32) {
    nil = std.math.maxInt(u32),
    _,

    /// Position in the arena's slot array. Never call on `.nil`.
    pub fn index(self: NodeId) usize {
        assert(self != .nil);
        return @backingInt(self);
    }

    pub fn fromIndex(i: usize) NodeId {
        assert(i < std.math.maxInt(u32)); // maxInt itself is reserved for nil
        return @fromBackingInt(@intCast(@as(u32, @intCast(i))));
    }
};

pub fn Arena(comptime T: type) type {
    return struct {
        const Self = @This();

        /// A slot either holds a live value or is a link of the free list.
        /// The tag is what lets `free` catch a double free and `validate`
        /// catch a handle that points at a freed node.
        const Slot = union(enum) {
            used: T,
            free: NodeId, // next free slot, or .nil
        };

        slots: std.ArrayList(Slot) = .empty,
        /// Most recently freed slot (head of the free list), or .nil.
        free_head: NodeId = .nil,
        /// Number of `used` slots.
        live: usize = 0,

        pub const empty: Self = .{};

        /// Frees every node at once. This is the "arena" half of the name:
        /// nobody has to walk the tree to release it.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.slots.deinit(gpa);
            self.* = .empty;
        }

        /// Makes sure the next `n` calls to `allocAssumeCapacity` succeed.
        /// The only function that allocates, and so the only one that can
        /// fail or move the slots.
        pub fn reserve(self: *Self, gpa: Allocator, n: usize) Allocator.Error!void {
            const free_slots = self.slots.items.len - self.live;
            if (n > free_slots) try self.slots.ensureUnusedCapacity(gpa, n - free_slots);
        }

        pub fn alloc(self: *Self, gpa: Allocator, value: T) Allocator.Error!NodeId {
            try self.reserve(gpa, 1);
            return self.allocAssumeCapacity(value);
        }

        /// Takes a slot from the free list if there is one, otherwise appends.
        /// Cannot fail and does not move existing slots (see `reserve`).
        pub fn allocAssumeCapacity(self: *Self, value: T) NodeId {
            self.live += 1;
            if (self.free_head != .nil) {
                const id = self.free_head;
                const slot = &self.slots.items[id.index()];
                self.free_head = slot.free; // pop; panics if the slot is not free
                slot.* = .{ .used = value };
                return id;
            }
            const id: NodeId = .fromIndex(self.slots.items.len);
            self.slots.appendAssumeCapacity(.{ .used = value });
            return id;
        }

        /// Returns the slot to the free list. The handle (and every copy of
        /// it) is dangling afterwards; the caller must have unlinked the node.
        pub fn free(self: *Self, id: NodeId) void {
            const slot = &self.slots.items[id.index()];
            assert(slot.* == .used); // double free
            slot.* = .{ .free = self.free_head };
            self.free_head = id;
            self.live -= 1;
        }

        /// Mutable access. Panics (in safe builds) on a freed or nil handle.
        pub fn ptr(self: *Self, id: NodeId) *T {
            return &self.slots.items[id.index()].used;
        }

        /// Read-only access.
        pub fn get(self: *const Self, id: NodeId) *const T {
            return &self.slots.items[id.index()].used;
        }

        /// True if `id` names a live node. Used by `validate`, which must not
        /// trust the handles it finds inside nodes.
        pub fn isLive(self: *const Self, id: NodeId) bool {
            if (id == .nil or id.index() >= self.slots.items.len) return false;
            return self.slots.items[id.index()] == .used;
        }

        pub fn liveCount(self: *const Self) usize {
            return self.live;
        }

        /// Slots ever created (live + free). The arena's high-water mark.
        pub fn slotCount(self: *const Self) usize {
            return self.slots.items.len;
        }

        /// Length of the free list, found by walking it. Returns null if the
        /// list is corrupt (reaches a used slot, or is longer than the array,
        /// which means a cycle).
        pub fn freeCount(self: *const Self) ?usize {
            var n: usize = 0;
            var id = self.free_head;
            while (id != .nil) : (n += 1) {
                if (n > self.slots.items.len or id.index() >= self.slots.items.len) return null;
                switch (self.slots.items[id.index()]) {
                    .free => |next| id = next,
                    .used => return null,
                }
            }
            return n;
        }
    };
}

test "alloc, free, reuse: slots are recycled last-in-first-out" {
    const gpa = std.testing.allocator;
    var arena: Arena(u64) = .empty;
    defer arena.deinit(gpa);

    const a = try arena.alloc(gpa, 10);
    const b = try arena.alloc(gpa, 20);
    const c = try arena.alloc(gpa, 30);
    try std.testing.expectEqual(0, a.index());
    try std.testing.expectEqual(2, c.index());
    try std.testing.expectEqual(3, arena.liveCount());

    arena.free(a);
    arena.free(c);
    try std.testing.expect(!arena.isLive(a));
    try std.testing.expect(arena.isLive(b));
    try std.testing.expectEqual(2, arena.freeCount());

    // c was freed last, so it is handed out first; the array does not grow.
    try std.testing.expectEqual(c, try arena.alloc(gpa, 31));
    try std.testing.expectEqual(a, try arena.alloc(gpa, 11));
    try std.testing.expectEqual(3, arena.slotCount());
    try std.testing.expectEqual(31, arena.get(c).*);
    try std.testing.expectEqual(20, arena.get(b).*);
    try std.testing.expect(!arena.isLive(.nil));
}

test "a handle survives growth of the array, a pointer does not have to" {
    const gpa = std.testing.allocator;
    var arena: Arena(u64) = .empty;
    defer arena.deinit(gpa);
    const first = try arena.alloc(gpa, 7);
    // Force many reallocations. Holding `arena.ptr(first)` across this loop
    // would be a use-after-free; holding the handle is fine.
    for (0..1000) |i| _ = try arena.alloc(gpa, i);
    try std.testing.expectEqual(7, arena.get(first).*);
}

test "reserve makes the following allocations infallible" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();
    var arena: Arena(u64) = .empty;
    defer arena.deinit(gpa);

    try arena.reserve(gpa, 3); // allocation #0 succeeds
    const a = arena.allocAssumeCapacity(1);
    _ = arena.allocAssumeCapacity(2);
    _ = arena.allocAssumeCapacity(3);
    arena.free(a);
    // One free slot is enough for one more node: no allocation, no failure.
    try arena.reserve(gpa, 1);
    // Far more than the capacity: allocation #1 fails and nothing has changed.
    try std.testing.expectError(error.OutOfMemory, arena.reserve(gpa, 10_000));
    try std.testing.expectEqual(2, arena.liveCount());
    try std.testing.expectEqual(1, arena.freeCount());
}
