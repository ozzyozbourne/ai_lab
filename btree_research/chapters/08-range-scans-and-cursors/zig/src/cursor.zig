//! The cursor: a position in the tree that can step forward and backward,
//! and that survives changes to the tree.
//!
//! A cursor has two halves:
//!
//!   * a PHYSICAL position: where the entry is right now. This is the part
//!     that differs between the two designs of this chapter
//!     (`link_cursor.zig`: leaf handle + index, moves along sibling links;
//!      `stack_cursor.zig`: root-to-leaf path, moves by climbing and
//!      descending). It is only valid for the tree version it was computed in.
//!   * a LOGICAL position: the KEY of the entry the cursor is on. A key is
//!     the only thing that still means something after a split, a merge, or
//!     the reuse of a freed node handle.
//!
//! `Cursor(Position)` owns the logical half and the rule that connects the
//! two: before using the physical position, compare `version` with the
//! tree's. If they differ, throw the physical position away and seek again
//! from the root with the saved key ("save key and re-seek"). That rule is
//! the same for both designs, so it is written once, here.
const std = @import("std");
const Tree = @import("tree.zig").Tree;
const Entry = @import("base_node.zig").Entry;
const search = @import("base_search.zig");

/// Where to position a cursor.
pub const Seek = union(enum) {
    first, // smallest entry
    last, // largest entry
    ge: u64, // first entry with key >= k
    gt: u64, // first entry with key >  k
    le: u64, // last entry with key <= k
    lt: u64, // last entry with key <  k
};

/// Counts only (no timings). `node_visits` counts every move of the cursor
/// to another node: down to a child, sideways along a link, or back up.
pub const Stats = struct {
    seeks: usize = 0,
    /// How many of `seeks` were forced by a changed tree.
    reseeks: usize = 0,
    node_visits: usize = 0,
};

pub const State = union(enum) {
    /// In front of the smallest entry (also the state of a new cursor).
    before_first,
    /// Behind the largest entry.
    after_last,
    /// On the entry with this key. The key is kept even if that entry is
    /// deleted later: it still tells `next` and `prev` where to continue.
    on: u64,
};

/// Where a seek lands inside the leaf that the descent reached.
pub const Landing = union(enum) {
    /// Index of the answer. May equal the leaf's length: then the answer is
    /// the first entry of the NEXT leaf.
    forward: usize,
    /// Number of entries of this leaf that qualify; the answer is the last
    /// of them (index n-1). 0 means: the last entry of the PREVIOUS leaf.
    backward: usize,
};

/// The bounds table of the chapter in code. `lowerBound` counts keys < k,
/// `upperBound` counts keys <= k; the four seeks are those two numbers read
/// from the left or from the right.
pub fn landing(keys: []const u64, target: Seek) Landing {
    return switch (target) {
        .first => .{ .forward = 0 },
        .ge => |k| .{ .forward = search.lowerBound(keys, k) },
        .gt => |k| .{ .forward = search.upperBound(keys, k) },
        .last => .{ .backward = keys.len },
        .le => |k| .{ .backward = search.upperBound(keys, k) },
        .lt => |k| .{ .backward = search.lowerBound(keys, k) },
    };
}

/// `Position` must provide (all taking the base tree and a `*Stats`):
///   seek(tree, target, stats) ?Entry   position from scratch
///   next(tree, stats) ?Entry           step; only called on a valid position
///   prev(tree, stats) ?Entry
///   entry(tree) Entry                  the entry under a valid position
pub fn Cursor(comptime Position: type) type {
    return struct {
        const Self = @This();

        pos: Position,
        state: State = .before_first,
        /// Tree version for which `pos` was computed. INVARIANT: if
        /// `state == .on(k)` and `version == tree.version`, then `pos` is on
        /// the entry with key k. In every other case `pos` is garbage.
        version: u64 = 0,
        stats: Stats = .{},

        pub fn init(pos: Position) Self {
            return .{ .pos = pos };
        }

        /// Positions the cursor and returns the entry it is now on, or null
        /// if no entry qualifies (the cursor is then before the first or
        /// after the last entry, whichever side the seek was looking at).
        pub fn seek(self: *Self, tree: *const Tree, target: Seek) ?Entry {
            self.stats.seeks += 1;
            if (self.pos.seek(&tree.base, target, &self.stats)) |found| {
                self.state = .{ .on = found.key };
                self.version = tree.version;
                return found;
            }
            self.state = switch (target) {
                .first, .ge, .gt => .after_last,
                .last, .le, .lt => .before_first,
            };
            return null;
        }

        /// The entry under the cursor, or null if the cursor is off either
        /// end, or if the entry it was on has been deleted since.
        pub fn entry(self: *Self, tree: *const Tree) ?Entry {
            const key = switch (self.state) {
                .before_first, .after_last => return null,
                .on => |k| k,
            };
            if (self.version == tree.version) return self.pos.entry(&tree.base);
            // The tree changed: find the saved key again.
            self.stats.seeks += 1;
            self.stats.reseeks += 1;
            const found = self.pos.seek(&tree.base, .{ .ge = key }, &self.stats) orelse return null;
            // Not there any more. Stay "on" the key (and stale), so that the
            // next step continues from the gap it left.
            if (found.key != key) return null;
            self.version = tree.version;
            return found;
        }

        /// Moves to the following entry and returns it.
        pub fn next(self: *Self, tree: *const Tree) ?Entry {
            switch (self.state) {
                .after_last => return null,
                .before_first => return self.seek(tree, .first),
                .on => |key| {
                    if (self.version != tree.version) {
                        // Save key and re-seek: "the first entry after the
                        // one I returned last" is well defined whatever
                        // happened to the nodes in between.
                        self.stats.reseeks += 1;
                        return self.seek(tree, .{ .gt = key });
                    }
                    if (self.pos.next(&tree.base, &self.stats)) |found| {
                        self.state = .{ .on = found.key };
                        return found;
                    }
                    self.state = .after_last;
                    return null;
                },
            }
        }

        /// Moves to the preceding entry and returns it.
        pub fn prev(self: *Self, tree: *const Tree) ?Entry {
            switch (self.state) {
                .before_first => return null,
                .after_last => return self.seek(tree, .last),
                .on => |key| {
                    if (self.version != tree.version) {
                        self.stats.reseeks += 1;
                        return self.seek(tree, .{ .lt = key });
                    }
                    if (self.pos.prev(&tree.base, &self.stats)) |found| {
                        self.state = .{ .on = found.key };
                        return found;
                    }
                    self.state = .before_first;
                    return null;
                },
            }
        }
    };
}

test "landing: the four seeks are lowerBound and upperBound read from both sides" {
    const keys = [_]u64{ 10, 20, 30 };
    const L = Landing;
    // key present
    try std.testing.expectEqual(L{ .forward = 1 }, landing(&keys, .{ .ge = 20 }));
    try std.testing.expectEqual(L{ .forward = 2 }, landing(&keys, .{ .gt = 20 }));
    try std.testing.expectEqual(L{ .backward = 2 }, landing(&keys, .{ .le = 20 })); // index 1
    try std.testing.expectEqual(L{ .backward = 1 }, landing(&keys, .{ .lt = 20 })); // index 0
    // key in a gap: inclusive and exclusive agree
    try std.testing.expectEqual(L{ .forward = 2 }, landing(&keys, .{ .ge = 25 }));
    try std.testing.expectEqual(L{ .forward = 2 }, landing(&keys, .{ .gt = 25 }));
    try std.testing.expectEqual(L{ .backward = 2 }, landing(&keys, .{ .le = 25 }));
    try std.testing.expectEqual(L{ .backward = 2 }, landing(&keys, .{ .lt = 25 }));
    // off the ends of this leaf: the answer is in a neighbour
    try std.testing.expectEqual(L{ .forward = 3 }, landing(&keys, .{ .gt = 30 }));
    try std.testing.expectEqual(L{ .backward = 0 }, landing(&keys, .{ .lt = 10 }));
    try std.testing.expectEqual(L{ .forward = 0 }, landing(&keys, .first));
    try std.testing.expectEqual(L{ .backward = 3 }, landing(&keys, .last));
}
