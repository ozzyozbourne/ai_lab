//! Cursor design 1: leaf handle + index, moving along the sibling links.
//!
//! This is the textbook B+tree scan and the shape of a Postgres index scan:
//! descend once, then walk the leaf level and never look at an internal node
//! again. The position is two words and never allocates.
//!
//! The price is paid elsewhere: every leaf split and merge has to maintain
//! the `prev` / `next` links (chapter 07), and on disk a split must write the
//! neighbour's page too.
const std = @import("std");
const BPlusTree = @import("base_tree.zig").BPlusTree;
const NodeId = @import("base_arena.zig").NodeId;
const node = @import("base_node.zig");
const Entry = node.Entry;
const search = @import("base_search.zig");
const cursor = @import("cursor.zig");
const Seek = cursor.Seek;
const Stats = cursor.Stats;

pub const LinkCursor = cursor.Cursor(LinkPosition);

pub const LinkPosition = struct {
    leaf: NodeId = .nil,
    index: usize = 0,

    pub fn seek(self: *LinkPosition, tree: *const BPlusTree, target: Seek, stats: *Stats) ?Entry {
        self.leaf = switch (target) {
            // The tree keeps handles of both ends of the chain: no descent.
            .first => tree.first_leaf,
            .last => tree.last_leaf,
            .ge, .gt, .le, .lt => |key| descend(tree, key, stats),
        };
        if (self.leaf == .nil) return null; // empty tree
        if (target == .first or target == .last) stats.node_visits += 1;
        return switch (cursor.landing(tree.nodes.get(self.leaf).keySlice(), target)) {
            .forward => |i| self.settleForward(tree, i, stats),
            .backward => |n| self.settleBackward(tree, n, stats),
        };
    }

    pub fn next(self: *LinkPosition, tree: *const BPlusTree, stats: *Stats) ?Entry {
        return self.settleForward(tree, self.index + 1, stats);
    }

    pub fn prev(self: *LinkPosition, tree: *const BPlusTree, stats: *Stats) ?Entry {
        return self.settleBackward(tree, self.index, stats);
    }

    pub fn entry(self: *const LinkPosition, tree: *const BPlusTree) Entry {
        return entryAt(tree.nodes.get(self.leaf), self.index);
    }

    /// Moves to entry `start` of the current leaf, or, if the leaf has no
    /// such entry, to the first entry of the next leaf: ONE link, no parent.
    fn settleForward(self: *LinkPosition, tree: *const BPlusTree, start: usize, stats: *Stats) ?Entry {
        var i = start;
        while (self.leaf != .nil) {
            const n = tree.nodes.get(self.leaf);
            if (i < n.len) {
                self.index = i;
                return entryAt(n, i);
            }
            self.leaf = n.kind.leaf.next;
            if (self.leaf != .nil) stats.node_visits += 1;
            i = 0;
        }
        return null; // ran off the right end of the chain
    }

    /// Moves to the last of the first `count` entries of the current leaf,
    /// or, if `count` is 0, to the last entry of the previous leaf.
    fn settleBackward(self: *LinkPosition, tree: *const BPlusTree, count: usize, stats: *Stats) ?Entry {
        var n_qualifying = count;
        while (true) {
            const n = tree.nodes.get(self.leaf);
            if (n_qualifying > 0) {
                self.index = n_qualifying - 1;
                return entryAt(n, self.index);
            }
            self.leaf = n.kind.leaf.prev;
            if (self.leaf == .nil) return null; // ran off the left end
            stats.node_visits += 1;
            n_qualifying = tree.nodes.get(self.leaf).len;
        }
    }
};

/// Root-to-leaf descent for `key`, counting the nodes on the way.
/// (`search.findLeaf` without the counter.)
fn descend(tree: *const BPlusTree, key: u64, stats: *Stats) NodeId {
    var id = tree.root;
    if (id == .nil) return .nil;
    while (true) {
        const n = tree.nodes.get(id);
        stats.node_visits += 1;
        switch (n.kind) {
            .leaf => return id,
            .internal => |*in| id = in.children[search.childIndex(n.keySlice(), key)],
        }
    }
}

pub fn entryAt(n: *const node.Node, i: usize) Entry {
    return .{ .key = n.keys[i], .value = n.kind.leaf.values[i] };
}
