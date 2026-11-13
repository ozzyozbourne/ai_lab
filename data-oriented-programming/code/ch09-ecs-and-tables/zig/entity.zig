//! Generational entity ids, shared by both storages (the idea is Chapter 5's pool, minus the values).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// The index names a slot, the generation says which occupant of that slot this id means.
/// A packed struct compares with `==` as one 64-bit integer.
pub const Entity = packed struct(u64) {
    index: u32,
    generation: u32,
};

/// Hands out entity ids. Freed indices are reused LIFO, with their generation bumped,
/// so an old id never matches the new occupant. A slot whose generation runs out is retired.
pub const Entities = struct {
    generations: std.ArrayList(u32) = .empty, // current generation of every index ever used
    live: std.ArrayList(bool) = .empty,
    free: std.ArrayList(u32) = .empty,

    pub const empty: Entities = .{};

    pub fn deinit(self: *Entities, gpa: Allocator) void {
        self.generations.deinit(gpa);
        self.live.deinit(gpa);
        self.free.deinit(gpa);
    }

    pub fn spawn(self: *Entities, gpa: Allocator) Allocator.Error!Entity {
        if (self.free.pop()) |index| {
            self.live.items[index] = true;
            return .{ .index = index, .generation = self.generations.items[index] };
        }
        try self.generations.append(gpa, 1); // generations start at 1: a zeroed Entity is never alive
        try self.live.append(gpa, true);
        return .{ .index = @intCast(self.generations.items.len - 1), .generation = 1 };
    }

    pub fn alive(self: *const Entities, e: Entity) bool {
        return e.index < self.live.items.len and self.live.items[e.index] and
            self.generations.items[e.index] == e.generation;
    }

    /// Caller checks `alive` first. Bumps the generation: every copy of `e` goes stale.
    pub fn despawn(self: *Entities, gpa: Allocator, e: Entity) Allocator.Error!void {
        const g = &self.generations.items[e.index];
        self.live.items[e.index] = false;
        // Out of generations: retire the slot, as Chapter 5's pool does (wrapping would revive old ids).
        if (g.* == std.math.maxInt(u32)) return;
        g.* += 1;
        try self.free.append(gpa, e.index);
    }

    /// Number of indices ever handed out (live, free or retired).
    pub fn capacity(self: *const Entities) usize {
        return self.generations.items.len;
    }

    /// The current id for slot `index` (alive or not: callers check).
    pub fn at(self: *const Entities, index: usize) Entity {
        return .{ .index = @intCast(index), .generation = self.generations.items[index] };
    }
};
