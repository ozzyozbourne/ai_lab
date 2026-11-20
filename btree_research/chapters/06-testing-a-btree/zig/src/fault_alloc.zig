//! A hand-written allocator wrapper that COUNTS and INJECTS FAULTS.
//!
//! `std.mem.Allocator` is two words: a context pointer and a pointer to a
//! table of four functions (alloc, resize, remap, free). A wrapper stores a
//! `child` allocator, does its own bookkeeping in each of the four functions
//! and forwards to the child. Code under test never knows: it just receives
//! an `Allocator`.
//!
//! What this one adds:
//!   * counters: attempts, successful allocations, frees, live allocations,
//!     live / peak / total bytes. `live_allocations == 0` at the end is a
//!     leak check that works with ANY child, including an arena that would
//!     hide the leak from `std.testing.allocator`;
//!   * one fault: `failNth(n)` makes the n-th allocation attempt from now
//!     return null (which callers see as error.OutOfMemory). ONE attempt
//!     fails; the attempts after it succeed again;
//!   * a quarantine (off by default): `quarantine = byte` makes `free`
//!     overwrite the block with that byte and KEEP it, so the block is never
//!     handed out again and a pointer that outlived it reads the byte, not
//!     the old contents and not somebody else's new node. That is what makes
//!     a use after free visible (fuzz.zig; README, "Which allocator where").
//!
//! The standard library has the same tool, `std.testing.FailingAllocator`.
//! Differences (tested at the bottom of this file):
//!   * FailingAllocator is armed once, at init, with an absolute index, and
//!     stays failed: every allocation from `fail_index` on fails. That is
//!     what `std.testing.checkAllAllocationFailures` wants (the function
//!     under test must give up cleanly), but it cannot show that the data
//!     structure is still USABLE after an out-of-memory error.
//!   * This wrapper can be re-armed between operations, relative to "now",
//!     so a fuzzer can fail the 2nd allocation of the 500th put.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const FaultAllocator = struct {
    child: Allocator,
    /// Index (in `attempts`) of the allocation that will fail; null = none armed.
    fail_at: ?u64 = null,
    /// Calls of `alloc`, including the failed ones.
    attempts: u64 = 0,
    /// Faults this wrapper injected (the child failing on its own is not counted).
    injected: u64 = 0,
    allocations: u64 = 0,
    frees: u64 = 0,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    total_bytes: usize = 0,
    /// null: `free` passes the block on to the child. A byte: `free` fills
    /// the block with it and does NOT pass it on, so the memory is only
    /// released when the child releases everything (use an arena as child).
    quarantine: ?u8 = null,

    pub fn init(child: Allocator) FaultAllocator {
        return .{ .child = child };
    }

    /// The interface value to hand to the code under test. It points at
    /// `self`, so `self` must not move while the allocator is in use.
    pub fn allocator(self: *FaultAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Fail the n-th allocation attempt from now (0 = the very next one).
    pub fn failNth(self: *FaultAllocator, n: u64) void {
        self.fail_at = self.attempts + n;
    }

    pub fn disarm(self: *FaultAllocator) void {
        self.fail_at = null;
    }

    pub fn liveAllocations(self: *const FaultAllocator) u64 {
        return self.allocations - self.frees;
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn resized(self: *FaultAllocator, old_len: usize, new_len: usize) void {
        self.live_bytes = self.live_bytes - old_len + new_len;
        if (new_len > old_len) self.total_bytes += new_len - old_len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        const index = self.attempts;
        self.attempts += 1;
        if (self.fail_at == index) {
            self.fail_at = null; // one shot
            self.injected += 1;
            return null;
        }
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.resized(0, len);
        return ptr;
    }

    // `resize` (grow or shrink in place) and `remap` (the same, but the block
    // may move) are not "allocation attempts" here and are never failed: the
    // B-tree never resizes a node. The byte counters still follow. For code
    // that grows a list this is a real limit: `failNth` cannot make its
    // growth fail (README, "Allocator notes").
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resized(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resized(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *FaultAllocator = @ptrCast(@alignCast(ctx));
        if (self.quarantine) |byte| {
            @memset(memory, byte);
        } else {
            self.child.rawFree(memory, alignment, ret_addr);
        }
        self.frees += 1;
        self.live_bytes -= memory.len;
    }
};

const testing = std.testing;

test "counts allocations, frees and bytes" {
    var fault: FaultAllocator = .init(testing.allocator);
    const a = fault.allocator();

    const xs = try a.alloc(u64, 10);
    const one = try a.create([32]u8);
    try testing.expectEqual(2, fault.allocations);
    try testing.expectEqual(2, fault.liveAllocations());
    try testing.expectEqual(80 + 32, fault.live_bytes);

    a.free(xs);
    try testing.expectEqual(1, fault.liveAllocations());
    try testing.expectEqual(32, fault.live_bytes);
    try testing.expectEqual(112, fault.peak_bytes);
    a.destroy(one);
    try testing.expectEqual(0, fault.liveAllocations());
    try testing.expectEqual(112, fault.total_bytes);
}

test "failNth fails exactly one attempt, relative to now" {
    var fault: FaultAllocator = .init(testing.allocator);
    const a = fault.allocator();
    const first = try a.create(u64); // attempt 0
    defer a.destroy(first);

    fault.failNth(1); // the second attempt from now, whatever happened before
    const second = try a.create(u64);
    defer a.destroy(second);
    try testing.expectError(error.OutOfMemory, a.create(u64));
    const fourth = try a.create(u64); // the fault was one shot
    defer a.destroy(fourth);

    try testing.expectEqual(4, fault.attempts);
    try testing.expectEqual(3, fault.allocations);
    try testing.expectEqual(1, fault.injected);
    try testing.expectEqual(null, fault.fail_at);
}

test "a leak hidden by an arena is still counted" {
    // The arena frees everything at once, so std.testing.allocator sees no
    // leak. The wrapper sits between the code and the arena and counts.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fault: FaultAllocator = .init(arena.allocator());
    _ = try fault.allocator().create(u64); // never destroyed
    try testing.expectEqual(1, fault.liveAllocations());
}

test "quarantine: a freed block reads as the chosen byte and is never handed out again" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Block = [4]u64;
    {
        // Without it, on an arena: the freed block still holds its old
        // contents, and the very next allocation gets the same address. A
        // stale pointer reads plausible data either way.
        var fault: FaultAllocator = .init(arena.allocator());
        const a = fault.allocator();
        const first = try a.create(Block);
        first.* = @splat(7);
        const stale: *const volatile Block = first;
        a.destroy(first);
        try testing.expectEqual(7, stale[0]);
        try testing.expectEqual(first, try a.create(Block));
    }
    var fault: FaultAllocator = .init(arena.allocator());
    fault.quarantine = 0x01;
    const a = fault.allocator();
    const first = try a.create(Block);
    first.* = @splat(7);
    const stale: *const volatile Block = first;
    a.destroy(first);
    try testing.expectEqual(0x0101010101010101, stale[0]);
    try testing.expect(first != try a.create(Block));
    try testing.expectEqual(0x0101010101010101, stale[3]);
    try testing.expectEqual(1, fault.liveAllocations()); // the counters do not know about the quarantine
}

test "std.testing.FailingAllocator stays failed; FaultAllocator recovers" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    const a = failing.allocator();
    const first = try a.create(u64);
    defer a.destroy(first);
    try testing.expectError(error.OutOfMemory, a.create(u64));
    try testing.expectError(error.OutOfMemory, a.create(u64)); // and every one after it
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(1, failing.allocations);
    try testing.expectEqual(0, failing.deallocations);
}
