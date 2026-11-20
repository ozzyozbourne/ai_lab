// Copied from chapters/07-bplus-trees/zig/src/node.zig and arena.zig (NodeId
// only), trimmed for chapter 19: no delete helpers, and a leaf keeps only the
// `next` link. With a `prev` link a leaf split would have to write into the
// right neighbour, a node the splitting thread has not latched.
//! Node layout of the B+tree, and the array surgery done inside one node.
//!
//!   * a LEAF holds the entries (key + value) and the link to the next leaf;
//!   * an INTERNAL node holds separator keys and child handles, and NO values.
//!
//! Nothing in this file knows about latches: every function works on one node
//! that the caller is allowed to touch.
const std = @import("std");
const assert = std.debug.assert;

/// Handle of a node: an index into the node table. `.nil` plays the role of a
/// null pointer.
pub const NodeId = enum(u32) {
    nil = std.math.maxInt(u32),
    _,

    /// Position in the table. Never call on `.nil`.
    pub fn index(self: NodeId) usize {
        assert(self != .nil);
        return @backingInt(self);
    }

    pub fn fromIndex(i: usize) NodeId {
        assert(i < std.math.maxInt(u32)); // maxInt itself is reserved for nil
        return @fromBackingInt(@intCast(@as(u32, @intCast(i))));
    }
};

/// Largest order a tree may be created with. The order itself (M = maximum
/// number of children) is a runtime field of the tree.
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
    /// Singly linked list of all leaves in key order.
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
    /// Sorted ascending, no duplicates.
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
};

test "leaf insert keeps keys and values aligned" {
    var n = Node.initLeaf();
    n.leafInsertAt(0, 20, 200);
    n.leafInsertAt(0, 10, 100);
    n.leafInsertAt(2, 30, 300);
    n.leafInsertAt(1, 15, 150);
    try std.testing.expectEqualSlices(u64, &.{ 10, 15, 20, 30 }, n.keySlice());
    try std.testing.expectEqualSlices(u64, &.{ 100, 150, 200, 300 }, n.kind.leaf.values[0..n.len]);
}

test "internal insert moves the child to the right of the key" {
    const id = NodeId.fromIndex;
    var n = Node.initInternal();
    n.kind.internal.children[0] = id(0);
    n.internalInsertAt(0, 50, id(5)); //  (0) 50 (5)
    n.internalInsertAt(0, 20, id(2)); //  (0) 20 (2) 50 (5)
    n.internalInsertAt(2, 80, id(8)); //  (0) 20 (2) 50 (5) 80 (8)
    try std.testing.expectEqualSlices(u64, &.{ 20, 50, 80 }, n.keySlice());
    try std.testing.expectEqualSlices(NodeId, &.{ id(0), id(2), id(5), id(8) }, n.childSlice());
}
