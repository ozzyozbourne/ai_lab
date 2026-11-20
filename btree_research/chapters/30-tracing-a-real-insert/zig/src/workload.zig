// Copied from chapters/12-disk-backed-bplus-tree/zig/src/workload.zig; unchanged.
//! workload.zig: seeded byte-string keys and values, and the oracle the tree
//! is compared with. The Rust twin draws the same random numbers, so both
//! languages run the same operations and print the same counters.
const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitMix64 = @import("prng.zig").SplitMix64;
const btree = @import("disk_btree.zig");

pub const max_key_len = btree.max_key_len;
pub const max_value_len = btree.max_value_len;

/// The key that belongs to number `n`: 1 to `max_len` letters from a small
/// alphabet (so that many keys share a prefix), derived from `n` alone, so
/// the same `n` always gives the same key and a later put overwrites it.
/// One key in 16 has the full `max_len`.
pub fn keyFor(n: u64, max_len: usize, buf: *[max_key_len]u8) []const u8 {
    var rng = SplitMix64.init(n *% 0x9E3779B97F4A7C15 +% 1);
    const len: usize = if (rng.chance(1, 16)) max_len else @intCast(1 + rng.below(max_len));
    for (buf[0..len]) |*b| b.* = 'a' + @as(u8, @intCast(rng.below(6)));
    return buf[0..len];
}

/// A value of random length (one in 16 is empty, one in 16 has `max_len`
/// bytes) whose bytes count up from a random start.
pub fn randomValue(rng: *SplitMix64, max_len: usize, buf: *[max_value_len]u8) []const u8 {
    const pick = rng.below(16);
    const len: usize = if (pick == 0) 0 else if (pick == 1) max_len else @intCast(rng.below(max_len + 1));
    const start: u8 = @truncate(rng.nextU64());
    for (buf[0..len], 0..) |*b, i| b.* = start +% @as(u8, @truncate(i));
    return buf[0..len];
}

/// The oracle: a sorted array of (key, value) byte strings. Every byte it
/// stores comes from one arena and is freed in one go by `deinit`.
pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub fn init(gpa: Allocator) Model {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Index of the first entry whose key is >= `key`.
    pub fn lowerBound(self: *const Model, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.order(u8, self.entries.items[mid].key, key) == .lt) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn get(self: *const Model, key: []const u8) ?[]const u8 {
        const i = self.lowerBound(key);
        if (i < self.entries.items.len and std.mem.eql(u8, self.entries.items[i].key, key)) return self.entries.items[i].value;
        return null;
    }

    pub fn put(self: *Model, key: []const u8, value: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        const i = self.lowerBound(key);
        const owned_value = try a.dupe(u8, value);
        if (i < self.entries.items.len and std.mem.eql(u8, self.entries.items[i].key, key)) {
            self.entries.items[i].value = owned_value;
        } else {
            try self.entries.insert(a, i, .{ .key = try a.dupe(u8, key), .value = owned_value });
        }
    }

    /// The entries with lo <= key < hi (`hi` null = to the end).
    pub fn range(self: *const Model, lo: []const u8, hi: ?[]const u8) []const Entry {
        const from = self.lowerBound(lo);
        const to = if (hi) |h| @max(from, self.lowerBound(h)) else self.entries.items.len;
        return self.entries.items[from..to];
    }

    pub fn len(self: *const Model) usize {
        return self.entries.items.len;
    }
};

test "keyFor is a function of n; Model keeps keys sorted and overwrites" {
    var a: [max_key_len]u8 = undefined;
    var b: [max_key_len]u8 = undefined;
    try std.testing.expectEqualStrings(keyFor(7, 40, &a), keyFor(7, 40, &b));

    var model: Model = .init(std.testing.allocator);
    defer model.deinit();
    try model.put("b", "1");
    try model.put("a", "2");
    try model.put("c", "3");
    try model.put("b", "4");
    try std.testing.expectEqual(3, model.len());
    try std.testing.expectEqualStrings("4", model.get("b").?);
    try std.testing.expectEqual(null, model.get("bb"));
    try std.testing.expectEqual(2, model.range("a", "c").len);
    try std.testing.expectEqual(2, model.range("b", null).len);
    try std.testing.expectEqual(0, model.range("c", "a").len);
}
