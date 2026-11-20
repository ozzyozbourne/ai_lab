//! Cursor design 2: a root-to-leaf path, and NO sibling links.
//!
//! The position is a stack of frames, one per internal node on the path:
//! "in node N, I went down child number C". To reach the next leaf the
//! cursor climbs until some ancestor has a child to the right of the one it
//! took, steps to that child, and descends along the left edge. This is how
//! a SQLite-format tree (Turso) is scanned: its pages have no sibling links
//! at all, so the path is the only way to find a neighbour.
//!
//! What it buys: splits and merges have no leaf chain to maintain.
//! What it costs: the cursor is bigger (a frame per level), and crossing a
//! leaf boundary touches at least the parent as well.
//!
//! The functions below never read `leaf.prev`, `leaf.next`,
//! `tree.first_leaf` or `tree.last_leaf`; a test scrambles those fields to
//! prove it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const BPlusTree = @import("base_tree.zig").BPlusTree;
const NodeId = @import("base_arena.zig").NodeId;
const Entry = @import("base_node.zig").Entry;
const search = @import("base_search.zig");
const cursor = @import("cursor.zig");
const Seek = cursor.Seek;
const Stats = cursor.Stats;
const entryAt = @import("link_cursor.zig").entryAt;

pub const StackCursor = cursor.Cursor(StackPosition);

/// Most frames a path can need. Handles are 32 bits, so a tree has fewer
/// than 2^32 nodes; every internal node has at least 2 children, so a tree
/// of height h has at least 2^(h-1) leaves; hence h <= 32 and a path has at
/// most 31 internal nodes. (Turso uses the same idea with a fixed limit of
/// 20 levels and treats a deeper tree as corrupt.)
pub const max_depth = 32;

pub const Frame = struct {
    /// An internal node on the path.
    node: NodeId,
    /// Which of its children the path continues into (0 ..= node.len).
    child: usize,
};

pub const StackPosition = struct {
    /// Room for `max_depth` frames, allocated ONCE from the scan's scratch
    /// allocator. Seeking and stepping never allocate, so they cannot fail.
    frames: []Frame,
    /// Frames in use: frames[0] is the root, frames[depth-1] the leaf's parent.
    depth: usize = 0,
    leaf: NodeId = .nil,
    index: usize = 0,

    /// `scratch` is typically an arena that lives as long as the scan. The
    /// position must not be used after that arena is reset or freed.
    pub fn init(scratch: Allocator) Allocator.Error!StackPosition {
        return .{ .frames = try scratch.alloc(Frame, max_depth) };
    }

    /// The internal part of the path, root first.
    pub fn path(self: *const StackPosition) []const Frame {
        return self.frames[0..self.depth];
    }

    pub fn seek(self: *StackPosition, tree: *const BPlusTree, target: Seek, stats: *Stats) ?Entry {
        self.depth = 0;
        self.leaf = .nil;
        if (tree.root == .nil) return null; // empty tree
        // `.first` and `.last` are descents too (along the left or right
        // edge): without links there is no other way to find the end leaves.
        self.leaf = self.descend(tree, tree.root, target, stats);
        return switch (cursor.landing(tree.nodes.get(self.leaf).keySlice(), target)) {
            .forward => |i| self.settleForward(tree, i, stats),
            .backward => |n| self.settleBackward(tree, n, stats),
        };
    }

    pub fn next(self: *StackPosition, tree: *const BPlusTree, stats: *Stats) ?Entry {
        return self.settleForward(tree, self.index + 1, stats);
    }

    pub fn prev(self: *StackPosition, tree: *const BPlusTree, stats: *Stats) ?Entry {
        return self.settleBackward(tree, self.index, stats);
    }

    pub fn entry(self: *const StackPosition, tree: *const BPlusTree) Entry {
        return entryAt(tree.nodes.get(self.leaf), self.index);
    }

    /// Walks down from `start` to a leaf, pushing a frame per internal node.
    fn descend(self: *StackPosition, tree: *const BPlusTree, start: NodeId, target: Seek, stats: *Stats) NodeId {
        var id = start;
        while (true) {
            const n = tree.nodes.get(id);
            stats.node_visits += 1;
            switch (n.kind) {
                .leaf => return id,
                .internal => |*in| {
                    const child = switch (target) {
                        .first => 0,
                        .last => n.len,
                        .ge, .gt, .le, .lt => |key| search.childIndex(n.keySlice(), key),
                    };
                    assert(self.depth < max_depth);
                    self.frames[self.depth] = .{ .node = id, .child = child };
                    self.depth += 1;
                    id = in.children[child];
                },
            }
        }
    }

    fn settleForward(self: *StackPosition, tree: *const BPlusTree, start: usize, stats: *Stats) ?Entry {
        var i = start;
        while (true) {
            const n = tree.nodes.get(self.leaf);
            if (i < n.len) {
                self.index = i;
                return entryAt(n, i);
            }
            if (!self.stepLeaf(tree, .forward, stats)) return null;
            i = 0;
        }
    }

    fn settleBackward(self: *StackPosition, tree: *const BPlusTree, count: usize, stats: *Stats) ?Entry {
        var n_qualifying = count;
        while (true) {
            const n = tree.nodes.get(self.leaf);
            if (n_qualifying > 0) {
                self.index = n_qualifying - 1;
                return entryAt(n, self.index);
            }
            if (!self.stepLeaf(tree, .backward, stats)) return null;
            n_qualifying = tree.nodes.get(self.leaf).len;
        }
    }

    /// Moves to the neighbouring leaf using only the path: pop, step, push.
    /// Returns false (with an empty stack) if there is no such leaf.
    fn stepLeaf(self: *StackPosition, tree: *const BPlusTree, direction: enum { forward, backward }, stats: *Stats) bool {
        while (self.depth > 0) {
            const frame = &self.frames[self.depth - 1];
            const parent = tree.nodes.get(frame.node);
            stats.node_visits += 1; // back up in the parent
            const has_sibling = if (direction == .forward) frame.child < parent.len else frame.child > 0;
            if (has_sibling) {
                if (direction == .forward) frame.child += 1 else frame.child -= 1;
                const subtree = parent.kind.internal.children[frame.child];
                // Entering a subtree from the left we want its first leaf;
                // from the right, its last.
                self.leaf = self.descend(tree, subtree, if (direction == .forward) .first else .last, stats);
                return true;
            }
            self.depth -= 1; // this ancestor has nothing further: pop it
        }
        self.leaf = .nil;
        return false;
    }
};
