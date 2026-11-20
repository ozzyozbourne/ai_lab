//! Coverage points: "did the test actually go there?"
//!
//! A fuzzer that never fails proves little if it never reached the hard
//! branches. So the tree counts how often each structurally interesting
//! branch ran, and the fuzz tests ASSERT at the end that every counter is
//! non-zero (TigerBeetle does the same with `assert(tested_padding)`, see the
//! README). The branches are marked in base_insert.zig and base_delete.zig
//! with `tree.coverage.hit(.point)`.
//!
//! This replaces chapter 05's `Counters`: the same idea, but split by level
//! (leaf / interior), because "a split happened" does not say whether a split
//! of an INTERIOR node, with its children to move, was ever exercised.
const std = @import("std");

pub const Point = enum {
    // base_insert.zig
    put_first_key, // empty tree: the root leaf is created
    put_overwrite, // key already present: value replaced, no structural change
    put_no_split, // new key fits into its leaf
    split_leaf,
    split_interior, // children move with their keys
    root_split_leaf, // height 1 -> 2
    root_split_interior, // height n -> n + 1, n >= 2
    put_oom, // allocation failed before anything was reserved
    put_oom_rollback, // allocation failed with nodes already reserved: they are handed back
    // base_delete.zig
    delete_missing,
    delete_leaf_key,
    delete_interior_key, // replaced by its in-order predecessor
    borrow_left_leaf,
    borrow_left_interior, // a child pointer changes parent as well
    borrow_right_leaf,
    borrow_right_interior,
    merge_leaf,
    merge_interior,
    merge_first_child, // the underfull node has no left sibling: merge with the right one
    root_shrink, // height n -> n - 1
    tree_emptied, // the last key was deleted
};

pub const point_count = @typeInfo(Point).@"enum".field_names.len;

pub const Coverage = struct {
    hits: [point_count]u64 = @splat(0),

    pub fn hit(self: *Coverage, point: Point) void {
        self.hits[@intFromEnum(point)] += 1;
    }

    pub fn count(self: *const Coverage, point: Point) u64 {
        return self.hits[@intFromEnum(point)];
    }

    /// Fold another tree's counters into this one (one fuzz run = many trees).
    pub fn add(self: *Coverage, other: *const Coverage) void {
        for (&self.hits, other.hits) |*mine, theirs| mine.* += theirs;
    }

    /// Number of points with at least one hit.
    pub fn reached(self: *const Coverage) usize {
        var n: usize = 0;
        for (self.hits) |h| n += @intFromBool(h > 0);
        return n;
    }

    /// The first point that was never hit, or null if every branch ran.
    pub fn firstMissing(self: *const Coverage) ?Point {
        for (self.hits, 0..) |h, i| if (h == 0) return @enumFromInt(i);
        return null;
    }
};

test "hit, count, add, reached, firstMissing" {
    var a: Coverage = .{};
    try std.testing.expectEqual(Point.put_first_key, a.firstMissing().?);
    a.hit(.split_leaf);
    a.hit(.split_leaf);
    var b: Coverage = .{};
    b.hit(.merge_leaf);
    b.add(&a);
    try std.testing.expectEqual(2, b.count(.split_leaf));
    try std.testing.expectEqual(1, b.count(.merge_leaf));
    try std.testing.expectEqual(2, b.reached());
    for (0..point_count) |i| b.hit(@enumFromInt(i));
    try std.testing.expectEqual(null, b.firstMissing());
    try std.testing.expectEqual(point_count, b.reached());
}
