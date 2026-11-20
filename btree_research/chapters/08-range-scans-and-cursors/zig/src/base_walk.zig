// Copied from chapters/07-bplus-trees/zig/src/walk.zig; behaviour unchanged (only the
// @import paths were renamed to base_*.zig). Do not edit here.
//! The minimal in-order walk over the leaf chain.
//!
//! This is deliberately small: forward only, positioned at the first entry or
//! at the first entry >= a key. It exists to show that an ordered scan of a
//! B+tree never goes back up into the internal nodes, and to give `validate`
//! and the model test something to compare with. Bounds, backward scans and
//! cursors that survive changes to the tree are the subject of chapter 08.
//!
//! The walker holds a handle and an index, not a pointer, and it does not
//! allocate. It must not be used across a `put` or `delete`.
const std = @import("std");
const BPlusTree = @import("base_tree.zig").BPlusTree;
const NodeId = @import("base_arena.zig").NodeId;
const Entry = @import("base_node.zig").Entry;
const search = @import("base_search.zig");

pub const LeafWalker = struct {
    tree: *const BPlusTree,
    /// Current leaf, `.nil` when the walk is finished.
    leaf: NodeId,
    /// Next entry to return inside `leaf`.
    index: usize,

    /// Starts at the smallest key.
    pub fn first(tree: *const BPlusTree) LeafWalker {
        return .{ .tree = tree, .leaf = tree.first_leaf, .index = 0 };
    }

    /// Starts at the first entry with key >= `key`: one root-to-leaf descent,
    /// then a binary search in the leaf.
    pub fn seek(tree: *const BPlusTree, key: u64) LeafWalker {
        const leaf = search.findLeaf(tree, key);
        if (leaf == .nil) return .{ .tree = tree, .leaf = .nil, .index = 0 };
        // The index may equal the leaf's length (every key in this leaf is
        // smaller). `next` then steps to the following leaf by itself.
        const index = search.lowerBound(tree.nodes.get(leaf).keySlice(), key);
        return .{ .tree = tree, .leaf = leaf, .index = index };
    }

    pub fn next(self: *LeafWalker) ?Entry {
        while (self.leaf != .nil) {
            const n = self.tree.nodes.get(self.leaf);
            if (self.index < n.len) {
                defer self.index += 1;
                return .{ .key = n.keys[self.index], .value = n.kind.leaf.values[self.index] };
            }
            // End of this leaf: follow the sibling link. No parent needed.
            self.leaf = n.kind.leaf.next;
            self.index = 0;
        }
        return null;
    }
};
