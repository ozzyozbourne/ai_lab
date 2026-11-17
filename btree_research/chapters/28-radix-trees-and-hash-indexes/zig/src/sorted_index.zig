//! The sorted baseline: an array of (key, value) kept in key order, searched
//! by binary search.
//!
//! This stands in for the B-tree in this chapter's comparison. For the
//! questions asked here (which queries can be answered, and in what order the
//! answers come out) a B+tree behaves like a sorted array cut into pages; what
//! the tree adds is cheap insertion, which chapters 03 to 08 covered.
const std = @import("std");
const Allocator = std.mem.Allocator;
const keys = @import("keys.zig");

pub const Entry = keys.Entry;
pub const Lookup = keys.Lookup;

pub const SortedIndex = struct {
    gpa: Allocator,
    /// Invariant: strictly ascending by key bytes. Keys are owned.
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: Allocator) SortedIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *SortedIndex) void {
        for (self.entries.items) |e| self.gpa.free(e.key);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn len(self: *const SortedIndex) usize {
        return self.entries.items.len;
    }

    /// Index of the first entry with key >= `key` (chapter 02). `compares`
    /// is increased by the number of whole-key comparisons made.
    pub fn lowerBound(self: *const SortedIndex, key: []const u8, compares: *u32) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            compares.* += 1;
            if (std.mem.lessThan(u8, self.entries.items[mid].key, key)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn get(self: *const SortedIndex, key: []const u8) ?u64 {
        return self.lookup(key).value;
    }

    /// Point lookup. `steps` counts whole-key comparisons.
    pub fn lookup(self: *const SortedIndex, key: []const u8) Lookup {
        var steps: u32 = 0;
        const i = self.lowerBound(key, &steps);
        if (i == self.len()) return .{ .value = null, .steps = steps };
        steps += 1; // the equality check on the candidate
        const e = self.entries.items[i];
        return .{ .value = if (std.mem.eql(u8, e.key, key)) e.value else null, .steps = steps };
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    pub fn put(self: *SortedIndex, key: []const u8, value: u64) Allocator.Error!?u64 {
        var steps: u32 = 0;
        const i = self.lowerBound(key, &steps);
        if (i < self.len() and std.mem.eql(u8, self.entries.items[i].key, key)) {
            const old = self.entries.items[i].value;
            self.entries.items[i].value = value;
            return old;
        }
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        try self.entries.insert(self.gpa, i, .{ .key = owned, .value = value });
        return null;
    }

    /// Entries with lo <= key < hi, in order. A contiguous slice: this is the
    /// query an ordered structure answers for free.
    pub fn range(self: *const SortedIndex, lo: []const u8, hi: []const u8) []const Entry {
        var steps: u32 = 0;
        const a = self.lowerBound(lo, &steps);
        const b = self.lowerBound(hi, &steps);
        return if (a < b) self.entries.items[a..b] else &.{};
    }

    /// Entries whose key starts with `prefix`. They are contiguous in sorted
    /// order, so a prefix query is a range query in disguise (chapter 08).
    pub fn prefixRange(self: *const SortedIndex, prefix: []const u8) []const Entry {
        var steps: u32 = 0;
        const a = self.lowerBound(prefix, &steps);
        var b = a;
        while (b < self.len() and std.mem.startsWith(u8, self.entries.items[b].key, prefix)) b += 1;
        return self.entries.items[a..b];
    }

    pub fn validate(self: *const SortedIndex) error{Unsorted}!void {
        const items = self.entries.items;
        for (1..items.len) |i| {
            if (!std.mem.lessThan(u8, items[i - 1].key, items[i].key)) return error.Unsorted;
        }
    }
};

const testing = std.testing;
const ops = @import("ops.zig");

test "put keeps order; range and prefix are slices" {
    var index: SortedIndex = .init(testing.allocator);
    defer index.deinit();
    for ([_][]const u8{ "cat/2", "ant/1", "cat/1", "dog/9", "cat/3" }, 0..) |k, i| {
        try testing.expectEqual(null, try index.put(k, i));
        try index.validate();
    }
    try testing.expectEqual(2, try index.put("cat/1", 20));
    try testing.expectEqual(20, index.get("cat/1"));
    try testing.expectEqual(null, index.get("cat/"));
    try testing.expectEqual(5, index.len());
    try testing.expectEqual(3, index.prefixRange("cat/").len);
    try testing.expectEqual(0, index.prefixRange("cow").len);
    const r = index.range("cat/2", "dog/9");
    try testing.expectEqual(2, r.len);
    try testing.expectEqualStrings("cat/2", r[0].key);
    try testing.expectEqualStrings("cat/3", r[1].key);
    try testing.expectEqual(0, index.range("z", "a").len);
}

test "model test against the oracle" {
    const gpa = testing.allocator;
    var index: SortedIndex = .init(gpa);
    defer index.deinit();
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(gpa);
    var stream = ops.OpStream.init(.{
        .seed = 8,
        .count = 3000,
        .key_space = 400,
        .weights = .{ .put = 5, .delete = 0, .get = 3, .range = 2 },
    });
    while (stream.next()) |op| switch (op) {
        .put => |p| try testing.expectEqual(try oracle.put(gpa, p.key, p.value), try index.put(&keys.encodeU64(p.key), p.value)),
        .get => |g| try testing.expectEqual(oracle.get(g.key), index.get(&keys.encodeU64(g.key))),
        .range => |r| {
            const want = oracle.range(r.lo, r.hi);
            const got = index.range(&keys.encodeU64(r.lo), &keys.encodeU64(r.hi));
            try testing.expectEqual(want.len, got.len);
            for (want, got) |w, g| {
                try testing.expectEqual(w.key, keys.decodeU64(g.key));
                try testing.expectEqual(w.value, g.value);
            }
        },
        .delete => unreachable,
    };
    try index.validate();
}

fn fillUnderFailure(gpa: Allocator) !void {
    var index: SortedIndex = .init(gpa);
    defer index.deinit();
    for (0..20) |i| _ = try index.put(&keys.encodeU64(i * 3 % 20), i);
    try index.validate();
}

test "allocation failure in put leaks nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, fillUnderFailure, .{});
}
