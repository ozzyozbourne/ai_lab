//! Deterministic operation stream + a tiny reference oracle for model tests.
//!
//! Source of truth: common/zig/ops.zig (twin: common/rust/ops.rs).
//! A chapter copies this file and adds as its first line:
//!     // Copied from common/zig/ops.zig; do not edit here
//!
//! A model test feeds the same operations to the tree under test and to the
//! `Oracle` (a sorted array, obviously correct) and compares every answer.
//! Zig and Rust generate the identical stream for the same `Config`
//! (see common/golden.txt), so a failure in one language can be replayed in
//! the other.
//!
//! This file is self-contained: it carries its own private copy of the
//! SplitMix64 step (same numbers as common/zig/prng.zig).
const std = @import("std");

/// One operation. Keys and values are u64 (Part I convention).
pub const Op = union(enum) {
    put: struct { key: u64, value: u64 },
    delete: struct { key: u64 },
    get: struct { key: u64 },
    /// Half-open key interval [lo, hi). Always lo < hi <= key_space.
    range: struct { lo: u64, hi: u64 },
};

/// Relative frequencies. {4,2,3,1} means 40% put, 20% delete, 30% get, 10% range.
pub const Weights = struct {
    put: u32 = 4,
    delete: u32 = 2,
    get: u32 = 3,
    range: u32 = 1,
};

pub const Config = struct {
    seed: u64,
    /// Number of operations to produce.
    count: u64,
    /// Keys are drawn from [0, key_space). Small = many collisions (good for
    /// testing overwrite and delete). Must be > 0.
    key_space: u64,
    /// At least one weight must be non-zero.
    weights: Weights = .{},
};

/// Usage:  var s = OpStream.init(cfg);  while (s.next()) |op| switch (op) { ... }
pub const OpStream = struct {
    state: u64, // SplitMix64 state
    remaining: u64,
    key_space: u64,
    weights: Weights,

    pub fn init(config: Config) OpStream {
        std.debug.assert(config.key_space > 0);
        const w = config.weights;
        std.debug.assert(@as(u64, w.put) + w.delete + w.get + w.range > 0);
        return .{
            .state = config.seed,
            .remaining = config.count,
            .key_space = config.key_space,
            .weights = w,
        };
    }

    /// Next operation, or null after `count` operations.
    ///
    /// The exact recipe (the Rust twin follows it draw for draw):
    ///   1. r = below(put + delete + get + range)
    ///   2. r picks the kind, checking put, delete, get, range in that order
    ///   3. put:    key = below(key_space), then value = nextU64()
    ///      delete: key = below(key_space)
    ///      get:    key = below(key_space)
    ///      range:  a = below(key_space), b = below(key_space),
    ///              lo = min(a, b), hi = max(a, b) + 1
    pub fn next(self: *OpStream) ?Op {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const w = self.weights;
        const total = @as(u64, w.put) + w.delete + w.get + w.range;
        var r = self.below(total);
        if (r < w.put) {
            const key = self.below(self.key_space);
            return .{ .put = .{ .key = key, .value = self.nextU64() } };
        }
        r -= w.put;
        if (r < w.delete) return .{ .delete = .{ .key = self.below(self.key_space) } };
        r -= w.delete;
        if (r < w.get) return .{ .get = .{ .key = self.below(self.key_space) } };
        const a = self.below(self.key_space);
        const b = self.below(self.key_space);
        return .{ .range = .{ .lo = @min(a, b), .hi = @max(a, b) + 1 } };
    }

    // Private SplitMix64 (identical to prng.zig).
    fn nextU64(self: *OpStream) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    // Multiply-high: top 64 bits of nextU64() * n.
    fn below(self: *OpStream, n: u64) u64 {
        return @intCast((@as(u128, self.nextU64()) * @as(u128, n)) >> 64);
    }
};

pub const Entry = struct { key: u64, value: u64 };

/// Reference map u64 -> u64: an array of entries kept sorted by key.
/// Slow (put/delete shift elements, O(n)) but easy to trust.
pub const Oracle = struct {
    entries: std.ArrayList(Entry) = .empty,

    /// `var oracle: Oracle = .{};` then `defer oracle.deinit(allocator);`
    pub fn deinit(self: *Oracle, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn len(self: *const Oracle) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const Oracle, key: u64) ?u64 {
        const i = self.lowerBound(key);
        const items = self.entries.items;
        return if (i < items.len and items[i].key == key) items[i].value else null;
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    /// The only Oracle method that can allocate.
    pub fn put(self: *Oracle, allocator: std.mem.Allocator, key: u64, value: u64) !?u64 {
        const i = self.lowerBound(key);
        const items = self.entries.items;
        if (i < items.len and items[i].key == key) {
            const old = items[i].value;
            items[i].value = value;
            return old;
        }
        try self.entries.insert(allocator, i, .{ .key = key, .value = value });
        return null;
    }

    /// Remove a key. Returns the removed value, or null if it was absent.
    pub fn delete(self: *Oracle, key: u64) ?u64 {
        const i = self.lowerBound(key);
        const items = self.entries.items;
        if (i < items.len and items[i].key == key) return self.entries.orderedRemove(i).value;
        return null;
    }

    /// All entries with lo <= key < hi, in ascending key order. The slice
    /// points into the oracle: it is invalidated by the next put/delete.
    pub fn range(self: *const Oracle, lo: u64, hi: u64) []const Entry {
        const start = self.lowerBound(lo);
        const end = self.lowerBound(hi);
        return if (start < end) self.entries.items[start..end] else &.{};
    }

    /// Binary search: index of the first entry with entry.key >= key.
    fn lowerBound(self: *const Oracle, key: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries.items[mid].key < key) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

test "stream is deterministic, bounded and yields exactly count ops" {
    const cfg: Config = .{ .seed = 9, .count = 500, .key_space = 50 };
    var a = OpStream.init(cfg);
    var b = OpStream.init(cfg);
    var n: u64 = 0;
    while (a.next()) |op| : (n += 1) {
        try std.testing.expectEqual(op, b.next().?);
        switch (op) {
            .put => |p| try std.testing.expect(p.key < 50),
            .delete => |d| try std.testing.expect(d.key < 50),
            .get => |g| try std.testing.expect(g.key < 50),
            .range => |r| try std.testing.expect(r.lo < r.hi and r.hi <= 50),
        }
    }
    try std.testing.expectEqual(500, n);
    try std.testing.expectEqual(null, b.next());
}

test "zero weights are never chosen" {
    var s = OpStream.init(.{ .seed = 1, .count = 200, .key_space = 10, .weights = .{ .put = 0, .delete = 0, .get = 1, .range = 0 } });
    while (s.next()) |op| try std.testing.expect(op == .get);
}

test "oracle basics" {
    const allocator = std.testing.allocator; // reports leaks
    var o: Oracle = .{};
    defer o.deinit(allocator);
    try std.testing.expectEqual(null, try o.put(allocator, 20, 200));
    try std.testing.expectEqual(null, try o.put(allocator, 10, 100));
    try std.testing.expectEqual(null, try o.put(allocator, 30, 300));
    try std.testing.expectEqual(200, try o.put(allocator, 20, 222));
    try std.testing.expectEqual(3, o.len());
    try std.testing.expectEqual(222, o.get(20));
    try std.testing.expectEqual(null, o.get(15));
    try std.testing.expectEqualSlices(Entry, &.{ .{ .key = 10, .value = 100 }, .{ .key = 20, .value = 222 } }, o.range(10, 30));
    try std.testing.expectEqual(0, o.range(11, 20).len);
    try std.testing.expectEqual(0, o.range(30, 10).len);
    try std.testing.expectEqual(100, o.delete(10));
    try std.testing.expectEqual(null, o.delete(10));
    try std.testing.expectEqual(2, o.len());
}

test "oracle put survives allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var o: Oracle = .{};
    defer o.deinit(failing.allocator());
    try std.testing.expectError(error.OutOfMemory, o.put(failing.allocator(), 1, 1));
    try std.testing.expectEqual(0, o.len());
}
