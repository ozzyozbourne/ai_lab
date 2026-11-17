//! A simple hash index: open addressing with linear probing. No delete.
//!
//! All entries live in one flat array of slots. A key hashes to a home slot;
//! if that slot is taken by another key, the next slot is tried, and so on
//! (wrapping around). Lookup follows the same walk and stops at the first
//! empty slot: the key cannot be further along, because an insert would have
//! used that empty slot.
//!
//! What the hash function buys (expected O(1) probes) is exactly what it
//! destroys: neighbouring keys land in unrelated slots, so the table cannot
//! answer "what comes after this key" without looking at every slot.
const std = @import("std");
const Allocator = std.mem.Allocator;
const keys = @import("keys.zig");

pub const Entry = keys.Entry;
pub const Lookup = keys.Lookup;

pub const HashIndex = struct {
    gpa: Allocator,
    /// Length is 0 or a power of two, so `hash & (len - 1)` is the home slot.
    slots: []Slot = &.{},
    len: usize = 0,

    pub const Slot = struct {
        /// null = empty slot. The bytes are owned by the index.
        key: ?[]u8 = null,
        /// Kept so that growing does not have to hash every key again.
        hash: u64 = 0,
        value: u64 = 0,
    };

    const min_capacity = 8;

    pub fn init(gpa: Allocator) HashIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *HashIndex) void {
        for (self.slots) |slot| {
            if (slot.key) |k| self.gpa.free(k);
        }
        self.gpa.free(self.slots);
        self.* = undefined;
    }

    pub fn capacity(self: *const HashIndex) usize {
        return self.slots.len;
    }

    pub fn get(self: *const HashIndex, key: []const u8) ?u64 {
        return self.lookup(key).value;
    }

    /// Point lookup. `steps` counts slots inspected.
    pub fn lookup(self: *const HashIndex, key: []const u8) Lookup {
        if (self.slots.len == 0) return .{ .value = null, .steps = 0 };
        const found = self.probe(keys.fnv1a(key), key);
        const slot = self.slots[found.index];
        return .{ .value = if (slot.key != null) slot.value else null, .steps = found.steps };
    }

    const Probe = struct { index: usize, steps: u32 };

    /// Walk from the home slot to the slot holding `key`, or to the first
    /// empty slot. Terminates because the load factor keeps empty slots around.
    fn probe(self: *const HashIndex, hash: u64, key: []const u8) Probe {
        const mask = self.slots.len - 1;
        var i: usize = @intCast(hash & mask);
        var steps: u32 = 1;
        while (self.slots[i].key) |stored| {
            // Comparing the stored hash first skips most byte comparisons.
            if (self.slots[i].hash == hash and std.mem.eql(u8, stored, key)) break;
            i = (i + 1) & mask;
            steps += 1;
        }
        return .{ .index = i, .steps = steps };
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    /// On error the index holds the same entries as before.
    pub fn put(self: *HashIndex, key: []const u8, value: u64) Allocator.Error!?u64 {
        const hash = keys.fnv1a(key);
        if (self.slots.len > 0) {
            const slot = &self.slots[self.probe(hash, key).index];
            if (slot.key != null) {
                const old = slot.value;
                slot.value = value;
                return old;
            }
        }
        // Invariant: len <= 70% of capacity, so probe runs stay short and a
        // lookup always meets an empty slot.
        if ((self.len + 1) * 10 > self.slots.len * 7) try self.grow();
        const owned = try self.gpa.dupe(u8, key);
        const slot = &self.slots[self.probe(hash, key).index];
        slot.* = .{ .key = owned, .hash = hash, .value = value };
        self.len += 1;
        return null;
    }

    /// Double the table and re-place every entry: a slot index depends on the
    /// capacity, so nothing can stay where it was. This is the hash index's
    /// "split", and it touches the whole structure at once.
    fn grow(self: *HashIndex) Allocator.Error!void {
        const new_cap = @max(min_capacity, self.slots.len * 2);
        const new_slots = try self.gpa.alloc(Slot, new_cap);
        @memset(new_slots, .{});
        const mask = new_cap - 1;
        for (self.slots) |slot| {
            if (slot.key == null) continue;
            var i: usize = @intCast(slot.hash & mask);
            while (new_slots[i].key != null) i = (i + 1) & mask;
            new_slots[i] = slot;
        }
        self.gpa.free(self.slots);
        self.slots = new_slots;
    }

    /// The only way a hash index can answer an ordered question: look at every
    /// slot, keep what matches, sort afterwards. Appends matching entries to
    /// `out` in SLOT order (keys borrowed) and returns the slots inspected.
    /// `hi == null` means no upper bound.
    pub fn scanRange(self: *const HashIndex, gpa: Allocator, lo: []const u8, hi: ?[]const u8, out: *std.ArrayList(Entry)) Allocator.Error!usize {
        for (self.slots) |slot| {
            const k = slot.key orelse continue;
            if (std.mem.lessThan(u8, k, lo)) continue;
            if (hi) |h| {
                if (!std.mem.lessThan(u8, k, h)) continue;
            }
            try out.append(gpa, .{ .key = k, .value = slot.value });
        }
        return self.slots.len;
    }

    pub fn validate(self: *const HashIndex) error{ BadCapacity, BadCount, BadHash, Unreachable, Overloaded }!void {
        const cap = self.slots.len;
        if (cap != 0 and !std.math.isPowerOfTwo(cap)) return error.BadCapacity;
        if (self.len * 10 > cap * 7) return error.Overloaded;
        var used: usize = 0;
        for (self.slots, 0..) |slot, i| {
            const k = slot.key orelse continue;
            used += 1;
            if (slot.hash != keys.fnv1a(k)) return error.BadHash;
            // Every entry must be found where a lookup would look for it.
            if (self.probe(slot.hash, k).index != i) return error.Unreachable;
        }
        if (used != self.len) return error.BadCount;
    }
};

pub fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

const testing = std.testing;
const ops = @import("ops.zig");

test "put, get, overwrite, growth" {
    var index: HashIndex = .init(testing.allocator);
    defer index.deinit();
    try testing.expectEqual(null, index.get("a"));
    try testing.expectEqual(0, index.lookup("a").steps);
    for (0..100) |i| {
        try testing.expectEqual(null, try index.put(&keys.encodeU64(i * 7), i));
        try index.validate();
    }
    try testing.expectEqual(100, index.len);
    try testing.expectEqual(256, index.capacity()); // 100 <= 0.7 * 256, but 100 > 0.7 * 128
    try testing.expectEqual(5, try index.put(&keys.encodeU64(35), 500));
    try testing.expectEqual(500, index.get(&keys.encodeU64(35)));
    try testing.expectEqual(null, index.get(&keys.encodeU64(36)));
    try testing.expectEqual(100, index.len);
}

test "scanRange inspects every slot and returns unordered matches" {
    const gpa = testing.allocator;
    var index: HashIndex = .init(gpa);
    defer index.deinit();
    for (0..50) |i| _ = try index.put(&keys.encodeU64(i), i);
    var out: std.ArrayList(Entry) = .empty;
    defer out.deinit(gpa);
    const inspected = try index.scanRange(gpa, &keys.encodeU64(10), &keys.encodeU64(20), &out);
    try testing.expectEqual(index.capacity(), inspected);
    try testing.expectEqual(10, out.items.len);
    std.mem.sort(Entry, out.items, {}, entryLessThan);
    for (out.items, 10..) |e, want| try testing.expectEqual(want, e.value);
}

test "model test against the oracle: put and get" {
    const gpa = testing.allocator;
    var index: HashIndex = .init(gpa);
    defer index.deinit();
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var stream = ops.OpStream.init(.{
        .seed = 5,
        .count = 5000,
        .key_space = 600,
        .weights = .{ .put = 5, .delete = 0, .get = 5, .range = 0 },
    });
    while (stream.next()) |op| switch (op) {
        .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try index.put(&keys.encodeU64(p.key), p.value)),
        .get => |g| try testing.expectEqual(oracle.get(g.key), index.get(&keys.encodeU64(g.key))),
        else => unreachable,
    };
    try index.validate();
    try testing.expectEqual(oracle.len(), index.len);
}

fn fillUnderFailure(gpa: Allocator) !void {
    var index: HashIndex = .init(gpa);
    defer index.deinit();
    for (0..40) |i| _ = try index.put(&keys.encodeU64(i), i);
    try index.validate();
}

test "allocation failure in put leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, fillUnderFailure, .{});
}

test "a failed put keeps the old entries" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var index: HashIndex = .init(failing.allocator());
    defer index.deinit();
    for (0..5) |i| _ = try index.put(&keys.encodeU64(i), i);
    failing.fail_index = failing.alloc_index; // the next allocation (table growth) fails
    try testing.expectError(error.OutOfMemory, index.put(&keys.encodeU64(5), 5));
    try index.validate();
    try testing.expectEqual(5, index.len);
    for (0..5) |i| try testing.expectEqual(i, index.get(&keys.encodeU64(i)));
}
