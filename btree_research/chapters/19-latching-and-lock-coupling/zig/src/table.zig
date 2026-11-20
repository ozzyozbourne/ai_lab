//! The node table: every node the tree will ever have, allocated ONCE.
//!
//! Chapter 07 kept its nodes in a growable array with a free list. Neither
//! survives the move to several threads:
//!
//!   * a growing array MOVES, and another thread may be reading a node at
//!     that moment. Here the array has a fixed capacity and never moves, so a
//!     `*Node` stays valid for the lifetime of the tree;
//!   * a freed slot can be REUSED while a slow thread still holds its handle.
//!     Here nodes are never freed (the chapter has no delete), so a handle
//!     always names the node it named when it was read. A thread may latch a
//!     node it found through a stale pointer; it then sees an old but real
//!     node, never garbage. `latchRoot` in coupled.zig depends on this.
//!
//! Each slot pairs a node with its latch. Handing out slots is a bump of one
//! atomic counter, so two threads splitting different leaves never wait for
//! each other to get a node.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const base_node = @import("base_node.zig");
const Node = base_node.Node;
const NodeId = base_node.NodeId;

pub const Slot = struct {
    /// Reader-writer latch protecting `node`. Used only by the latch-coupling
    /// protocol; the two global protocols never touch it.
    latch: Io.RwLock = .init,
    /// Undefined until the slot has been handed out by `reserve`.
    node: Node = undefined,
};

pub const NodeTable = struct {
    slots: []Slot,
    /// Slots handed out so far; ids 0 .. used-1 are live. Only ever grows.
    used: std.atomic.Value(u32) = .init(0),

    /// The only allocation the tree ever makes.
    pub fn init(gpa: Allocator, node_count: u32) Allocator.Error!NodeTable {
        const slots = try gpa.alloc(Slot, node_count);
        for (slots) |*slot| slot.* = .{};
        return .{ .slots = slots };
    }

    pub fn deinit(self: *NodeTable, gpa: Allocator) void {
        gpa.free(self.slots);
        self.* = undefined;
    }

    /// Hands out `n` consecutive slots and returns the id of the first, or
    /// fails WITHOUT taking any. All or nothing matters: an insert asks for
    /// every node its splits will need before it changes the tree, so running
    /// out of nodes never leaves a half-finished split behind.
    ///
    /// A compare-and-swap loop instead of `fetchAdd`, because a failed
    /// `fetchAdd` would have to be undone, and between the add and the undo
    /// another thread could see a counter beyond the capacity.
    pub fn reserve(self: *NodeTable, n: u32) error{OutOfNodes}!NodeId {
        var seen = self.used.load(.monotonic);
        while (true) {
            if (n > self.slots.len - seen) return error.OutOfNodes;
            seen = self.used.cmpxchgWeak(seen, seen + n, .monotonic, .monotonic) orelse
                return .fromIndex(seen);
        }
    }

    /// Pointer to a node. Stable forever (the table never moves). Whether the
    /// caller may read or write through it is decided by the lock protocol.
    pub fn node(self: *const NodeTable, id: NodeId) *Node {
        return &self.slots[id.index()].node;
    }

    pub fn latch(self: *const NodeTable, id: NodeId) *Io.RwLock {
        return &self.slots[id.index()].latch;
    }

    pub fn count(self: *const NodeTable) u32 {
        return self.used.load(.monotonic);
    }

    pub fn capacity(self: *const NodeTable) u32 {
        return @intCast(self.slots.len);
    }
};

test "reserve is all or nothing" {
    var table: NodeTable = try .init(std.testing.allocator, 5);
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, (try table.reserve(2)).index());
    try std.testing.expectEqual(2, (try table.reserve(2)).index());
    // Two are needed, one is left: nothing is taken.
    try std.testing.expectError(error.OutOfNodes, table.reserve(2));
    try std.testing.expectEqual(4, table.count());
    try std.testing.expectEqual(4, (try table.reserve(1)).index());
    try std.testing.expectError(error.OutOfNodes, table.reserve(1));
}

test "the table is allocated once and an allocation failure is reported" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, NodeTable.init(failing.allocator(), 8));
}
