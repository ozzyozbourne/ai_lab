//! Node layout of the B+tree, and the array surgery done inside one node.
//!
//! The two node kinds are the point of the chapter:
//!   * a LEAF holds the entries (key + value) and the two sibling links;
//!   * an INTERNAL node holds separator keys and child handles, and NO values.
//!
//! Nothing in this file knows about the tree or the arena except the type
//! `NodeId`; every function works on one node.
const std = @import("std");
const assert = std.debug.assert;
const NodeId = @import("arena.zig").NodeId;

/// Largest order a tree may be created with. The order itself (M = maximum
/// number of children) is a runtime field of the tree so that tests and the
/// visualization can use M = 3, 4, 5, ... with one node type. Arrays are sized
/// for the largest order, which wastes memory for small M and keeps the
/// teaching code free of generics.
pub const max_order = 16;

/// A node of order M holds at most M-1 keys, but `put` lets a node overflow
/// by exactly one key before it is split, so the arrays have room for M.
pub const key_capacity = max_order;
/// An internal node with k keys has k+1 children.
pub const child_capacity = max_order + 1;

pub const Entry = struct { key: u64, value: u64 };

pub const Leaf = struct {
    /// values[i] belongs to keys[i].
    values: [key_capacity]u64 = undefined,
    /// Doubly linked list of all leaves in key order.
    prev: NodeId = .nil,
    next: NodeId = .nil,
};

pub const Internal = struct {
    /// children[i] holds keys <  keys[i]   (and >= keys[i-1]);
    /// children[len] holds keys >= keys[len-1].
    children: [child_capacity]NodeId = undefined,
};

pub const Node = struct {
    /// Number of keys in use.
    len: usize = 0,
    /// Sorted ascending, no duplicates. In a leaf: the keys of the entries.
    /// In an internal node: separators (signposts, see `Internal.children`).
    keys: [key_capacity]u64 = undefined,
    kind: union(enum) { leaf: Leaf, internal: Internal },

    pub fn initLeaf() Node {
        return .{ .kind = .{ .leaf = .{} } };
    }

    pub fn initInternal() Node {
        return .{ .kind = .{ .internal = .{} } };
    }

    pub fn isLeaf(self: *const Node) bool {
        return self.kind == .leaf;
    }

    pub fn keySlice(self: *const Node) []const u64 {
        return self.keys[0..self.len];
    }

    /// The len+1 child handles of an internal node.
    pub fn childSlice(self: *const Node) []const NodeId {
        return self.kind.internal.children[0 .. self.len + 1];
    }

    // ------------------------------------------------------------ leaf

    /// Inserts an entry at position i, shifting the tail right.
    pub fn leafInsertAt(self: *Node, i: usize, key: u64, value: u64) void {
        assert(self.len < key_capacity and i <= self.len);
        const leaf = &self.kind.leaf;
        // Overlapping ranges: @memmove, not @memcpy.
        @memmove(self.keys[i + 1 .. self.len + 1], self.keys[i..self.len]);
        @memmove(leaf.values[i + 1 .. self.len + 1], leaf.values[i..self.len]);
        self.keys[i] = key;
        leaf.values[i] = value;
        self.len += 1;
    }

    /// Removes and returns the entry at position i, shifting the tail left.
    pub fn leafRemoveAt(self: *Node, i: usize) Entry {
        assert(i < self.len);
        const leaf = &self.kind.leaf;
        const removed: Entry = .{ .key = self.keys[i], .value = leaf.values[i] };
        @memmove(self.keys[i .. self.len - 1], self.keys[i + 1 .. self.len]);
        @memmove(leaf.values[i .. self.len - 1], leaf.values[i + 1 .. self.len]);
        self.len -= 1;
        return removed;
    }

    // -------------------------------------------------------- internal

    /// Inserts separator `key` at key position i and `right` as the child to
    /// its right (child position i+1). This is what a parent does when its
    /// child i has split.
    pub fn internalInsertAt(self: *Node, i: usize, key: u64, right: NodeId) void {
        assert(self.len < key_capacity and i <= self.len);
        const children = &self.kind.internal.children;
        @memmove(self.keys[i + 1 .. self.len + 1], self.keys[i..self.len]);
        @memmove(children[i + 2 .. self.len + 2], children[i + 1 .. self.len + 1]);
        self.keys[i] = key;
        children[i + 1] = right;
        self.len += 1;
    }

    /// Removes separator i and the child to its right (child i+1). This is
    /// what a parent does when children i and i+1 have been merged into i.
    pub fn internalRemoveAt(self: *Node, i: usize) void {
        assert(i < self.len);
        const children = &self.kind.internal.children;
        @memmove(self.keys[i .. self.len - 1], self.keys[i + 1 .. self.len]);
        @memmove(children[i + 1 .. self.len], children[i + 2 .. self.len + 1]);
        self.len -= 1;
    }
};

test "leaf insert and remove keep keys and values aligned" {
    var n = Node.initLeaf();
    n.leafInsertAt(0, 20, 200);
    n.leafInsertAt(0, 10, 100);
    n.leafInsertAt(2, 30, 300);
    n.leafInsertAt(1, 15, 150);
    try std.testing.expectEqualSlices(u64, &.{ 10, 15, 20, 30 }, n.keySlice());
    try std.testing.expectEqualSlices(u64, &.{ 100, 150, 200, 300 }, n.kind.leaf.values[0..n.len]);
    try std.testing.expectEqual(Entry{ .key = 15, .value = 150 }, n.leafRemoveAt(1));
    try std.testing.expectEqual(Entry{ .key = 30, .value = 300 }, n.leafRemoveAt(2));
    try std.testing.expectEqualSlices(u64, &.{ 10, 20 }, n.keySlice());
    try std.testing.expectEqualSlices(u64, &.{ 100, 200 }, n.kind.leaf.values[0..n.len]);
}

test "internal insert and remove move the child to the right of the key" {
    const id = NodeId.fromIndex;
    var n = Node.initInternal();
    n.kind.internal.children[0] = id(0);
    n.internalInsertAt(0, 50, id(5)); //  (0) 50 (5)
    n.internalInsertAt(0, 20, id(2)); //  (0) 20 (2) 50 (5)
    n.internalInsertAt(2, 80, id(8)); //  (0) 20 (2) 50 (5) 80 (8)
    try std.testing.expectEqualSlices(u64, &.{ 20, 50, 80 }, n.keySlice());
    try std.testing.expectEqualSlices(NodeId, &.{ id(0), id(2), id(5), id(8) }, n.childSlice());
    n.internalRemoveAt(1); //             (0) 20 (2) 80 (8)
    try std.testing.expectEqualSlices(u64, &.{ 20, 80 }, n.keySlice());
    try std.testing.expectEqualSlices(NodeId, &.{ id(0), id(2), id(8) }, n.childSlice());
}
