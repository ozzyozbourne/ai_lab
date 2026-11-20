// Copied from chapters/05-deletion-and-rebalancing/zig/src/node.zig; fixes go there first
//! The node type.
//!
//! A B-tree of order M (Knuth: M = maximum number of children) is made of
//! nodes that hold
//!   * at most      M - 1          keys (`max_keys`),
//!   * at least     ceil(M/2) - 1  keys (`min_keys`), except the root,
//!   * and, if the node is interior, exactly `len + 1` children.
//!
//! This is a plain B-tree (not a B+tree): every key lives exactly once, with
//! its value, either in a leaf or in an interior node.
//!
//! Layout decision: the arrays are ONE slot larger than the legal maximum.
//! An insert may therefore put the new key into a full node first and split
//! it afterwards ("overflow, then split"), which keeps the split code free of
//! special cases. A node with `len == M` only exists for an instant inside
//! `base_insert.zig`; `validate` rejects it.
const std = @import("std");

pub const Entry = struct { key: u64, value: u64 };

pub fn Node(comptime M: usize) type {
    comptime std.debug.assert(M >= 3); // M = 2 would allow nodes with zero keys
    return struct {
        const Self = @This();

        /// Most keys a node may hold between operations.
        pub const max_keys = M - 1;
        /// Fewest keys a non-root node may hold: ceil(M/2) - 1.
        pub const min_keys = (M + 1) / 2 - 1;

        /// Number of keys currently stored.
        len: usize = 0,
        /// Leaves have no children. All leaves are at the same depth.
        leaf: bool,
        /// keys[0..len] strictly ascending. Slot M - 1 is the overflow slot.
        keys: [M]u64 = undefined,
        /// values[i] belongs to keys[i].
        values: [M]u64 = undefined,
        /// Interior nodes: children[0..len + 1] are non-null. Every key in
        /// children[i] is < keys[i]; every key in children[i + 1] is > keys[i].
        children: [M + 1]?*Self = @splat(null),

        pub fn keySlice(self: *const Self) []const u64 {
            return self.keys[0..self.len];
        }

        /// Open a gap at index `i` and store the entry there (shifts the tail right).
        pub fn insertEntry(self: *Self, i: usize, key: u64, value: u64) void {
            std.debug.assert(i <= self.len and self.len < M);
            var j = self.len;
            while (j > i) : (j -= 1) {
                self.keys[j] = self.keys[j - 1];
                self.values[j] = self.values[j - 1];
            }
            self.keys[i] = key;
            self.values[i] = value;
            self.len += 1;
        }

        /// Remove and return the entry at index `i` (shifts the tail left).
        pub fn removeEntry(self: *Self, i: usize) Entry {
            std.debug.assert(i < self.len);
            const removed: Entry = .{ .key = self.keys[i], .value = self.values[i] };
            for (i..self.len - 1) |j| {
                self.keys[j] = self.keys[j + 1];
                self.values[j] = self.values[j + 1];
            }
            self.len -= 1;
            return removed;
        }

        /// Insert a child pointer at index `i`.
        /// Call BEFORE the matching `insertEntry`: it assumes `len + 1` children.
        pub fn insertChild(self: *Self, i: usize, child: *Self) void {
            std.debug.assert(!self.leaf and i <= self.len + 1 and self.len < M);
            var j = self.len + 1;
            while (j > i) : (j -= 1) self.children[j] = self.children[j - 1];
            self.children[i] = child;
        }

        /// Remove and return the child pointer at index `i`.
        /// Call AFTER the matching `removeEntry`: it assumes `len + 2` children.
        pub fn removeChild(self: *Self, i: usize) *Self {
            std.debug.assert(!self.leaf and i <= self.len + 1);
            const removed = self.children[i].?;
            for (i..self.len + 1) |j| self.children[j] = self.children[j + 1];
            self.children[self.len + 1] = null;
            return removed;
        }
    };
}

test "capacity limits follow the order M" {
    try std.testing.expectEqual(3, Node(4).max_keys); // a 2-3-4 tree
    try std.testing.expectEqual(1, Node(4).min_keys);
    try std.testing.expectEqual(1, Node(3).min_keys);
    try std.testing.expectEqual(2, Node(5).min_keys);
    try std.testing.expectEqual(2, Node(6).min_keys);
    try std.testing.expectEqual(3, Node(7).min_keys);
}

test "insertEntry and removeEntry keep the arrays dense" {
    var n: Node(4) = .{ .leaf = true };
    n.insertEntry(0, 20, 200);
    n.insertEntry(0, 10, 100);
    n.insertEntry(2, 30, 300);
    n.insertEntry(1, 15, 150); // uses the overflow slot
    try std.testing.expectEqualSlices(u64, &.{ 10, 15, 20, 30 }, n.keySlice());
    try std.testing.expectEqual(Entry{ .key = 15, .value = 150 }, n.removeEntry(1));
    try std.testing.expectEqual(Entry{ .key = 30, .value = 300 }, n.removeEntry(2));
    try std.testing.expectEqualSlices(u64, &.{ 10, 20 }, n.keySlice());
    try std.testing.expectEqualSlices(u64, &.{ 100, 200 }, n.values[0..n.len]);
}

test "insertChild and removeChild pair with the entry helpers" {
    var a: Node(4) = .{ .leaf = true };
    var b: Node(4) = .{ .leaf = true };
    var c: Node(4) = .{ .leaf = true };
    var p: Node(4) = .{ .leaf = false };
    p.children[0] = &a;
    p.insertChild(1, &c); // child first ...
    p.insertEntry(0, 50, 0); // ... then the separator
    p.insertChild(1, &b);
    p.insertEntry(0, 25, 0);
    try std.testing.expectEqual(&b, p.children[1].?);
    try std.testing.expectEqual(&c, p.children[2].?);
    _ = p.removeEntry(0); // separator first ...
    try std.testing.expectEqual(&b, p.removeChild(1)); // ... then the child
    try std.testing.expectEqual(&c, p.children[1].?);
    try std.testing.expectEqual(null, p.children[2]);
}
