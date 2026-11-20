//! Measurements: how full are the nodes after N inserts, and how many splits
//! did the inserts cost? Counts only, no timings.
//!
//! Two numbers are worth knowing before reading the output of `run`:
//!   * a tree in which every node is at the legal minimum is about 50% full,
//!     a tree of full nodes is 100% full;
//!   * textbook result (Yao, 1978): under random insertions the expected
//!     fill of a B-tree approaches ln 2 = 69.3% as the order grows.
//! The scenario prints what THIS code measures next to those references.
const std = @import("std");
const Allocator = std.mem.Allocator;
const BTree = @import("base_btree.zig").BTree;
const pool = @import("base_pool.zig");
const stats = @import("base_stats.zig");
const topdown = @import("topdown.zig");
const SplitMix64 = @import("prng.zig").SplitMix64;

pub const KeyOrder = enum { ascending, random };
pub const Variant = enum { bottom_up, top_down };

pub const Measured = struct {
    /// Number of puts (all keys are distinct, so also the number of keys).
    puts: usize,
    shape: stats.Shape,
    splits: u64,
    root_splits: u64,
    /// The worst single put: how many nodes it split.
    most_splits_in_one_put: u64,

    /// Average node fill in tenths of a percent: keys / (nodes * (M - 1)).
    /// Rounded DOWN (integer division): 66.664% is 666 and prints as 66.6%.
    pub fn fillPermille(self: Measured) usize {
        return if (self.shape.capacity == 0) 0 else self.shape.keys * 1000 / self.shape.capacity;
    }

    /// Splits per 1000 puts, in tenths (so 345 means 34.5 splits per 1000 puts).
    /// This is the amortised structural cost of one insert.
    pub fn splitsPer1000Tenths(self: Measured) usize {
        return if (self.puts == 0) 0 else @intCast(self.splits * 10_000 / self.puts);
    }
};

/// Fill `keys` with 0, 1, ..., n - 1, then shuffle them for `.random`.
pub fn fillKeys(keys: []u64, order: KeyOrder, seed: u64) void {
    for (keys, 0..) |*key, i| key.* = i;
    if (order == .random) {
        var prng: SplitMix64 = .init(seed);
        prng.shuffle(keys);
    }
}

/// Insert `keys` (distinct) into an empty tree of order M and report its
/// shape and split counts. Nodes come from `std.heap.MemoryPool` (StdPool).
pub fn build(comptime M: usize, comptime variant: Variant, gpa: Allocator, keys: []const u64) !Measured {
    const Tree = BTree(M, pool.StdPool);
    var tree: Tree = .empty;
    defer tree.deinit(gpa);
    var most: u64 = 0;
    for (keys) |key| {
        const before = tree.counters.splits;
        const old = switch (variant) {
            .bottom_up => try tree.put(gpa, key, key),
            .top_down => try topdown.put(Tree, &tree, gpa, key, key),
        };
        std.debug.assert(old == null); // keys are distinct
        most = @max(most, tree.counters.splits - before);
    }
    try tree.validate();
    return .{
        .puts = keys.len,
        .shape = tree.shape(),
        .splits = tree.counters.splits,
        .root_splits = tree.counters.root_splits,
        .most_splits_in_one_put = most,
    };
}

const testing = std.testing;

test "split accounting: every split adds one node, every root split one more and one level" {
    const gpa = testing.allocator;
    var keys: [3000]u64 = undefined;
    inline for (.{ KeyOrder.ascending, KeyOrder.random }) |order| {
        fillKeys(&keys, order, 4);
        inline for (.{ 3, 4, 5, 8, 16 }) |M| {
            const r = try build(M, .bottom_up, gpa, &keys);
            try testing.expectEqual(keys.len, r.shape.keys);
            try testing.expectEqual(1 + r.splits + r.root_splits, r.shape.nodes);
            try testing.expectEqual(1 + r.root_splits, r.shape.height);
            // No single put splits more nodes than the tree is high ...
            try testing.expect(r.most_splits_in_one_put <= r.shape.height);
            // ... and on average far fewer: every non-root node keeps at least
            // min_keys = ceil(M/2) - 1 keys, so there are fewer than
            // N / min_keys nodes, and each split made one of them.
            const min_keys = (M + 1) / 2 - 1;
            try testing.expect(r.splits < keys.len / min_keys);
        }
    }
}

test "ascending inserts leave every left half at its split size" {
    // With M = 4 an overfull node of 4 keys splits 2 + median + 1. Nothing is
    // ever inserted into a left half again, so all leaves except the last
    // keep 2 of 3 slots: two thirds full, not one half.
    const gpa = testing.allocator;
    var keys: [3000]u64 = undefined;
    fillKeys(&keys, .ascending, 0);
    const r4 = try build(4, .bottom_up, gpa, &keys);
    try testing.expect(r4.fillPermille() >= 640 and r4.fillPermille() <= 670);
    // With M = 64 the left half keeps 32 of 63 slots: about one half.
    const r64 = try build(64, .bottom_up, gpa, &keys);
    try testing.expect(r64.fillPermille() >= 490 and r64.fillPermille() <= 530);
}

test "random inserts fill nodes better than ascending inserts" {
    const gpa = testing.allocator;
    var asc: [20_000]u64 = undefined;
    var rnd: [20_000]u64 = undefined;
    fillKeys(&asc, .ascending, 0);
    fillKeys(&rnd, .random, 4);
    inline for (.{ 8, 16, 64 }) |M| {
        const a = try build(M, .bottom_up, gpa, &asc);
        const r = try build(M, .bottom_up, gpa, &rnd);
        try testing.expect(r.fillPermille() > a.fillPermille());
        // Loose band around the textbook ln 2 = 69.3%; the scenario prints
        // the exact measured values.
        try testing.expect(r.fillPermille() > 600 and r.fillPermille() < 780);
    }
}

test "top-down holds the same keys; ascending keys at M = 4 leave it one third full" {
    const gpa = testing.allocator;
    var keys: [20_000]u64 = undefined;
    inline for (.{ KeyOrder.ascending, KeyOrder.random }) |order| {
        fillKeys(&keys, order, 4);
        inline for (.{ 4, 8, 64 }) |M| {
            const bottom = try build(M, .bottom_up, gpa, &keys);
            const top = try build(M, .top_down, gpa, &keys);
            try testing.expectEqual(bottom.shape.keys, top.shape.keys);
            try testing.expectEqual(1 + top.splits + top.root_splits, top.shape.nodes);
            // Which variant splits more often is NOT fixed (the scenario has
            // a row where top-down needs one split fewer), so no assertion
            // on that. What does hold: a put splits at most one node per level.
            try testing.expect(top.most_splits_in_one_put <= top.shape.height);
        }
    }
    // With M = 4 a top-down split leaves 1 + 1 keys in nodes of 3 slots, and
    // ascending keys never refill a left half: one third full.
    fillKeys(&keys, .ascending, 0);
    const worst = try build(4, .top_down, gpa, &keys);
    try testing.expect(worst.fillPermille() >= 330 and worst.fillPermille() <= 340);
}
