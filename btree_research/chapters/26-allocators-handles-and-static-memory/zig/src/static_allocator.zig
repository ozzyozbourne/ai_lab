//! "Freeze after init": an allocator wrapper that can be switched off at run time.
//!
//! After TigerBeetle's `StaticAllocator` (db_study/tigerbeetle/src/static_allocator.zig):
//! allocate everything while starting up, then flip the wrapper so that any later
//! allocation is a detected bug. TigerBeetle asserts (the process dies); this version
//! refuses the request and counts it, so that a test can observe the refusal.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const StaticAllocator = struct {
    parent: Allocator,
    state: State = .init,
    /// Requests refused because of the state. In a correct program this stays 0, except
    /// for deliberate "pool exhausted" probes.
    refused: u32 = 0,

    pub const State = enum {
        /// Start-up: `alloc`, `resize`, `remap` and `free` all pass through.
        init,
        /// Running: nothing may be allocated or freed.
        static,
        /// Shutting down: only `free` passes through.
        deinit,
    };

    pub fn init(parent: Allocator) StaticAllocator {
        return .{ .parent = parent };
    }

    /// init -> static. From here on the memory footprint cannot change.
    pub fn freeze(self: *StaticAllocator) void {
        std.debug.assert(self.state == .init);
        self.state = .static;
    }

    /// static -> deinit, so that owners can give their memory back.
    pub fn thaw(self: *StaticAllocator) void {
        std.debug.assert(self.state == .static);
        self.state = .deinit;
    }

    pub fn allocator(self: *StaticAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // The whole std.mem.Allocator interface is these four functions. A wrapper forwards
    // each one to the parent's `raw*` twin and adds its policy in front.
    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        if (self.state != .init) {
            self.refused += 1;
            return null; // the caller sees error.OutOfMemory
        }
        return self.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        if (self.state != .init) {
            self.refused += 1;
            return false; // "cannot resize in place" is always a legal answer
        }
        return self.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        if (self.state != .init) {
            self.refused += 1;
            return null;
        }
        return self.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *StaticAllocator = @ptrCast(@alignCast(ctx));
        // `free` cannot report failure, so a free while frozen is counted and then
        // performed (dropping it would turn a logic error into a leak as well).
        if (self.state == .static) self.refused += 1;
        // As in TigerBeetle: "once you start freeing, you don't stop". A free during
        // init (an errdefer path) ends the init phase.
        if (self.state == .init) self.state = .deinit;
        self.parent.rawFree(memory, alignment, ret_addr);
    }
};

const testing = std.testing;

test "init allocates, static refuses, deinit only frees" {
    var static: StaticAllocator = .init(testing.allocator);
    const a = static.allocator();

    var list: std.ArrayList(u64) = try .initCapacity(a, 4);
    const node = try a.create([64]u8);

    static.freeze();
    list.appendAssumeCapacity(1); // using memory is fine
    try testing.expectError(error.OutOfMemory, a.create(u64));
    try testing.expectError(error.OutOfMemory, list.ensureTotalCapacity(a, 100));
    try testing.expect(static.refused >= 2);
    try testing.expectEqual(1, list.items[0]); // a refused grow leaves the list intact

    static.thaw();
    const refused = static.refused;
    a.destroy(node);
    list.deinit(a);
    try testing.expectError(error.OutOfMemory, a.create(u64)); // no way back to init
    try testing.expectEqual(refused + 1, static.refused);
}

test "a free during init ends init" {
    var static: StaticAllocator = .init(testing.allocator);
    const a = static.allocator();
    const x = try a.create(u64);
    a.destroy(x);
    try testing.expectEqual(StaticAllocator.State.deinit, static.state);
    try testing.expectError(error.OutOfMemory, a.create(u64));
}
