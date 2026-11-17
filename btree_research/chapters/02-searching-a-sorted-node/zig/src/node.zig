//! A single sorted node: the smallest structure that USES a search result.
//!
//! `Node(capacity)` is a fixed-size array of keys with a parallel array of
//! values and a length, all stored inline (no heap, no pointers). It is what a
//! B-tree leaf will look like from chapter 03 on. Every operation is the same
//! two steps:
//!
//!   1. `search` the keys: get `{found, index}`;
//!   2. act at `index`: read it, overwrite it, open a gap there, close it.
//!
//! When the node is full, `put` reports `error.NodeFull`. A B-tree answers
//! that error by splitting the node (chapter 04); here it is just an error.
const std = @import("std");
const search = @import("search.zig");

pub fn Node(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        keys: [capacity]u64 = undefined,
        values: [capacity]u64 = undefined,
        /// Only `keys[0..len]` and `values[0..len]` are meaningful.
        len: usize = 0,

        pub const empty: Self = .{};

        pub const PutError = error{NodeFull};

        /// The live keys, sorted and unique.
        pub fn keySlice(self: *const Self) []const u64 {
            return self.keys[0..self.len];
        }

        pub fn valueSlice(self: *const Self) []const u64 {
            return self.values[0..self.len];
        }

        pub fn get(self: *const Self, key: u64) ?u64 {
            const r = search.search(self.keySlice(), key);
            return if (r.found) self.values[r.index] else null;
        }

        /// Insert or overwrite. Returns the previous value if the key existed.
        pub fn put(self: *Self, key: u64, value: u64) PutError!?u64 {
            const r = search.search(self.keySlice(), key);
            if (r.found) {
                const old = self.values[r.index];
                self.values[r.index] = value;
                return old;
            }
            if (self.len == capacity) return error.NodeFull;
            // Open a gap at the insertion index: move keys[index..len] one
            // slot to the right. The ranges overlap and the destination is
            // higher, so the copy must run backwards. Because `index` is the
            // lower bound, everything left of the gap is < key and everything
            // right of it is > key: the node stays sorted without re-sorting.
            const i = r.index;
            std.mem.copyBackwards(u64, self.keys[i + 1 .. self.len + 1], self.keys[i..self.len]);
            std.mem.copyBackwards(u64, self.values[i + 1 .. self.len + 1], self.values[i..self.len]);
            self.keys[i] = key;
            self.values[i] = value;
            self.len += 1;
            return null;
        }

        /// Remove a key. Returns its value, or null if it was not there.
        pub fn delete(self: *Self, key: u64) ?u64 {
            const r = search.search(self.keySlice(), key);
            if (!r.found) return null;
            const i = r.index;
            const old = self.values[i];
            // Close the gap: move keys[i+1..len] one slot to the left.
            std.mem.copyForwards(u64, self.keys[i .. self.len - 1], self.keys[i + 1 .. self.len]);
            std.mem.copyForwards(u64, self.values[i .. self.len - 1], self.values[i + 1 .. self.len]);
            self.len -= 1;
            return old;
        }

        /// Positions of all keys in the half-open key interval `[lo, hi)`.
        /// Use the span to slice `keySlice()` and `valueSlice()`.
        pub fn range(self: *const Self, lo: u64, hi: u64) search.Span {
            return search.rangeSpan(self.keySlice(), .{ .included = lo }, .{ .excluded = hi });
        }

        /// Check the invariants: the length fits, and the keys are strictly
        /// increasing (sorted, and no duplicates: Part I rejects duplicates).
        pub fn validate(self: *const Self) error{InvalidNode}!void {
            if (self.len > capacity) return error.InvalidNode;
            const ks = self.keySlice();
            for (1..@max(ks.len, 1)) |i| {
                if (ks[i - 1] >= ks[i]) return error.InvalidNode;
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const ops = @import("ops.zig");

test "put keeps the node sorted by inserting at the search index" {
    var node: Node(8) = .empty;
    for ([_]u64{ 10, 20, 5, 6, 12 }) |k| {
        try testing.expectEqual(null, try node.put(k, k * 100));
        try node.validate();
    }
    try testing.expectEqualSlices(u64, &.{ 5, 6, 10, 12, 20 }, node.keySlice());
    try testing.expectEqualSlices(u64, &.{ 500, 600, 1000, 1200, 2000 }, node.valueSlice());

    // Overwrite: same position, old value comes back, length unchanged.
    try testing.expectEqual(1000, try node.put(10, 1));
    try testing.expectEqual(1, node.get(10));
    try testing.expectEqual(5, node.len);

    try testing.expectEqual(null, node.get(11));
    try testing.expectEqual(600, node.delete(6));
    try testing.expectEqual(null, node.delete(6));
    try testing.expectEqualSlices(u64, &.{ 5, 10, 12, 20 }, node.keySlice());
    try node.validate();
}

test "a full node rejects new keys but still accepts overwrites" {
    var node: Node(4) = .empty;
    for ([_]u64{ 10, 20, 5, 6 }) |k| _ = try node.put(k, k);
    try testing.expectError(error.NodeFull, node.put(12, 12));
    // The failed put changed nothing.
    try testing.expectEqualSlices(u64, &.{ 5, 6, 10, 20 }, node.keySlice());
    try node.validate();
    try testing.expectEqual(20, try node.put(20, 21));
    // Deleting makes room again.
    try testing.expectEqual(5, node.delete(5));
    try testing.expectEqual(null, try node.put(12, 12));
    try testing.expectEqualSlices(u64, &.{ 6, 10, 12, 20 }, node.keySlice());
}

test "validate rejects unsorted and duplicate keys" {
    var node: Node(4) = .empty;
    for ([_]u64{ 1, 2, 3 }) |k| _ = try node.put(k, k);
    try node.validate();
    node.keys[1] = 3; // 1 3 3: duplicate
    try testing.expectError(error.InvalidNode, node.validate());
    node.keys[1] = 9; // 1 9 3: unsorted
    try testing.expectError(error.InvalidNode, node.validate());
    // An unsorted node is why validate exists: search gives a wrong answer
    // without any error.
    try testing.expectEqual(null, node.get(3));
}

test "seeded model test: node against the oracle" {
    const allocator = testing.allocator; // the oracle allocates; leaks fail the test
    var oracle: ops.Oracle = .{};
    defer oracle.deinit(allocator);

    // key_space <= capacity, so the node can never be full.
    var node: Node(64) = .empty;
    var stream = ops.OpStream.init(.{ .seed = 2, .count = 20_000, .key_space = 64 });
    while (stream.next()) |op| {
        switch (op) {
            .put => |p| try testing.expectEqual(try oracle.put(allocator, p.key, p.value), try node.put(p.key, p.value)),
            .delete => |d| try testing.expectEqual(oracle.delete(d.key), node.delete(d.key)),
            .get => |g| try testing.expectEqual(oracle.get(g.key), node.get(g.key)),
            .range => |r| {
                const want = oracle.range(r.lo, r.hi);
                const span = node.range(r.lo, r.hi);
                try testing.expectEqual(want.len, span.len());
                for (want, node.keySlice()[span.start..span.end], node.valueSlice()[span.start..span.end]) |e, k, v| {
                    try testing.expectEqual(e.key, k);
                    try testing.expectEqual(e.value, v);
                }
            },
        }
        try node.validate();
        try testing.expectEqual(oracle.len(), node.len);
    }
}
