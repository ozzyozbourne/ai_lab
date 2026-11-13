//! A generational pool (a "slot map"): values live in one ArrayList of slots, callers hold
//! 8-byte handles (index + generation), and a free list is threaded through the free slots.
//! Tests: `zig test pool.zig`
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Declared inside the generic, so Pool(Monster).Handle and Pool(Item).Handle are
        /// different types: a typed handle for free. The zero handle is never valid
        /// because generations start at 1.
        pub const Handle = packed struct(u64) {
            index: u32,
            generation: u32,
            pub const none: Handle = .{ .index = 0, .generation = 0 };
        };

        const end = std.math.maxInt(u32); // end of the free list

        /// The generation sits outside the union so it survives the slot being freed.
        const Slot = struct {
            generation: u32,
            state: union(enum) {
                occupied: T,
                free: u32, // index of the next free slot, or `end`
                retired, // generation counter exhausted: never handed out again
            },
        };

        slots: std.ArrayList(Slot) = .empty,
        free_head: u32 = end, // the free list lives *inside* `slots`
        len: u32 = 0,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.slots.deinit(gpa);
        }

        pub fn insert(self: *Self, gpa: Allocator, value: T) Allocator.Error!Handle {
            if (self.free_head != end) {
                const index = self.free_head;
                const slot = &self.slots.items[index];
                self.free_head = slot.state.free; // pop; safety-checked: must be a free slot
                slot.state = .{ .occupied = value };
                self.len += 1;
                return .{ .index = index, .generation = slot.generation };
            }
            const index: u32 = @intCast(self.slots.items.len);
            try self.slots.append(gpa, .{ .generation = 1, .state = .{ .occupied = value } });
            self.len += 1;
            return .{ .index = index, .generation = 1 };
        }

        pub fn remove(self: *Self, h: Handle) ?T {
            const slot = self.slotFor(h) orelse return null; // stale or double remove
            const value = slot.state.occupied;
            if (std.math.add(u32, slot.generation, 1)) |g| {
                slot.generation = g; // every outstanding copy of `h` stops matching
                slot.state = .{ .free = self.free_head };
                self.free_head = h.index; // push onto the free list
            } else |_| {
                slot.state = .retired; // wrapping would make old handles valid again
            }
            self.len -= 1;
            return value;
        }

        /// The pointer is valid only until the next insert: `slots` may reallocate.
        /// Keep the handle, not the pointer.
        pub fn get(self: *Self, h: Handle) ?*T {
            const slot = self.slotFor(h) orelse return null;
            return &slot.state.occupied;
        }

        fn slotFor(self: *Self, h: Handle) ?*Slot {
            if (h.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[h.index];
            if (slot.generation != h.generation or slot.state != .occupied) return null;
            return slot;
        }

        pub fn slotCount(self: *const Self) usize {
            return self.slots.items.len;
        }
    };
}

const testing = std.testing;
const Monster = struct { hp: i32 };

test "handle is 8 bytes" {
    try testing.expectEqual(8, @sizeOf(Pool(Monster).Handle));
}

test "stale handle is detected after reuse" {
    const gpa = testing.allocator;
    var p: Pool([]const u8) = .empty;
    defer p.deinit(gpa);
    const a = try p.insert(gpa, "orc");
    const b = try p.insert(gpa, "elf");
    try testing.expectEqualStrings("orc", p.remove(a).?);
    try testing.expect(p.get(a) == null); // removed handle must not resolve
    try testing.expect(p.remove(a) == null); // double remove must be rejected
    const c = try p.insert(gpa, "goblin"); // reuses a's slot
    try testing.expectEqual(a.index, c.index);
    try testing.expectEqual(a.generation + 1, c.generation);
    try testing.expect(p.get(a) == null); // stale handle must not see the new occupant
    try testing.expectEqualStrings("goblin", p.get(c).?.*);
    try testing.expectEqualStrings("elf", p.get(b).?.*);
    try testing.expect(p.get(.none) == null);
    try testing.expectEqual(2, p.len);
}

test "free list is LIFO and in-array" {
    const gpa = testing.allocator;
    var p: Pool(u32) = .empty;
    defer p.deinit(gpa);
    var hs: [5]Pool(u32).Handle = undefined;
    for (&hs, 0..) |*h, i| h.* = try p.insert(gpa, @intCast(i));
    _ = p.remove(hs[1]);
    _ = p.remove(hs[3]);
    try testing.expectEqual(3, (try p.insert(gpa, 30)).index); // last freed slot first
    try testing.expectEqual(1, (try p.insert(gpa, 10)).index);
    try testing.expectEqual(5, (try p.insert(gpa, 5)).index); // empty free list: append
    try testing.expectEqual(6, p.slotCount());
}

test "handles survive growth" {
    const gpa = testing.allocator;
    var p: Pool(u64) = .empty;
    defer p.deinit(gpa);
    const first = try p.insert(gpa, 7);
    for (0..10_000) |i| _ = try p.insert(gpa, i); // reallocates: a *u64 from before would dangle
    try testing.expectEqual(7, p.get(first).?.*);
}
