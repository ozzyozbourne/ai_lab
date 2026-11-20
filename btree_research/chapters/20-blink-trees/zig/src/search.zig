//! Search in a B-link tree: one shared latch at a time, and "move right".
//!
//! The descent is written as a little state machine (`Descent`) that visits
//! exactly one node per `step`. Between two steps it holds NO latch, only the
//! handle of the node it wants to visit next. That is precisely the moment at
//! which another thread may split that node, and writing the descent this way
//! lets a single-threaded test put a split exactly there.
const std = @import("std");
const Io = std.Io;

const blink = @import("blink.zig");
const BLinkTree = blink.BLinkTree;
const NodeId = blink.NodeId;
const base_search = @import("base_search.zig");

pub const Mode = enum {
    /// The real algorithm.
    follow_right_links,
    /// The broken variant, for demonstration: behave like a plain B+tree and
    /// trust that the node we were sent to still covers the key.
    ignore_right_links,
};

/// What one visit did.
pub const Step = union(enum) {
    /// Internal node: followed the downlink to `to`.
    descended: struct { from: NodeId, to: NodeId },
    /// The key is at or above the node's high key: followed the right link.
    moved_right: struct { from: NodeId, to: NodeId, high_key: u64 },
    /// Leaf reached and searched: the answer.
    done: struct { leaf: NodeId, value: ?u64 },
};

pub const Lookup = struct {
    value: ?u64,
    /// Right links followed on the way.
    moves_right: usize,
    /// Nodes visited (each under its own shared latch).
    visited: usize,
};

pub const Descent = struct {
    key: u64,
    mode: Mode,
    /// The node to visit next. No latch is held on it.
    next: NodeId,
    moves_right: usize = 0,
    visited: usize = 0,

    /// Reads the root pointer and nothing else.
    pub fn begin(tree: *const BLinkTree, key: u64, mode: Mode) Descent {
        return .{ .key = key, .mode = mode, .next = tree.rootId() };
    }

    /// Latches `next` (shared), looks at it, decides where to go, unlatches.
    /// Do not call again after it returned `.done`.
    pub fn step(self: *Descent, tree: *BLinkTree, io: Io) Step {
        const id = self.next;
        const page = tree.lockShared(io, id);
        // The latch is released BEFORE the next node is latched: there is
        // never a moment with two latches, so there is nothing to deadlock on.
        defer tree.unlockShared(io, id);
        self.visited += 1;

        // Move right. The node may have split since we were given its
        // handle; if so, the keys we want moved into a new right sibling.
        // Postgres: _bt_moveright, nbtsearch.c:320-325.
        if (self.mode == .follow_right_links and page.isBeyond(self.key)) {
            self.next = page.right;
            self.moves_right += 1;
            _ = tree.moves_right.fetchAdd(1, .monotonic);
            return .{ .moved_right = .{ .from = id, .to = page.right, .high_key = page.high_key.? } };
        }

        const keys = page.node.keySlice();
        switch (page.node.kind) {
            .internal => |*in| {
                self.next = in.children[base_search.childIndex(keys, self.key)];
                return .{ .descended = .{ .from = id, .to = self.next } };
            },
            .leaf => |*leaf| {
                const i = base_search.lowerBound(keys, self.key);
                const value: ?u64 = if (i < keys.len and keys[i] == self.key) leaf.values[i] else null;
                return .{ .done = .{ .leaf = id, .value = value } };
            },
        }
    }
};

pub fn lookup(tree: *BLinkTree, io: Io, key: u64, mode: Mode) Lookup {
    var d = Descent.begin(tree, key, mode);
    while (true) switch (d.step(tree, io)) {
        .done => |r| return .{ .value = r.value, .moves_right = d.moves_right, .visited = d.visited },
        .descended, .moved_right => {},
    };
}
