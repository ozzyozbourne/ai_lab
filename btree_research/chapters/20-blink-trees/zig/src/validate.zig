//! `validate`: checks every invariant listed in blink.zig and names the first
//! one that is broken.
//!
//! A B+tree checker walks from the root through child handles. That is not
//! enough here: a node whose downlink is still missing cannot be reached that
//! way. In a B-link tree the authoritative structure of a level is its LINKED
//! LIST (`level_head[l]`, then right links), so the checker walks every level
//! as a list and, next to it, the sequence of downlinks of the level above,
//! and demands that the two agree except where a flag says "split in
//! progress".
//!
//! Reads pages without latching them: call only when no other thread is
//! using the tree.
const std = @import("std");
const blink = @import("blink.zig");
const BLinkTree = blink.BLinkTree;
const NodeId = blink.NodeId;

pub const Violation = error{
    /// root / height / level_head disagree.
    BadRoot,
    /// A right link or child handle names a slot that was never allocated,
    /// or a level's list does not end.
    DanglingLink,
    /// A node is on the list of a level it does not belong to.
    WrongLevel,
    /// More than M-1 keys.
    NodeOverfull,
    /// Fewer than ceil(M/2)-1 keys in a non-root node, or an empty internal root.
    NodeUnderfull,
    /// Keys inside a node are not strictly ascending.
    KeysNotSorted,
    /// A key lies outside [left sibling's high key, own high key).
    KeyOutOfBounds,
    /// High key without right link or the reverse, or high keys not ascending.
    BrokenRightLink,
    /// INCOMPLETE_SPLIT set on a node that has no right sibling.
    BadSplitFlag,
    /// A node has no downlink although its left sibling is not flagged, or
    /// the downlinks of the parent level name other nodes than the list.
    MissingDownlink,
    /// The separator in front of a downlink is not the child's lower bound.
    SeparatorMismatch,
    /// `count` is not the number of entries in the leaves.
    WrongCount,
    /// Allocated nodes that are on no level's list.
    OrphanNode,
};

/// One downlink as the parent level sees it.
const Downlink = struct {
    child: NodeId,
    /// Lower bound the parent promises for the child (null = -infinity).
    low: ?u64,
};

/// Walks all downlinks of one level, left to right, across its nodes.
const DownlinkCursor = struct {
    tree: *const BLinkTree,
    /// Used for the top level, which has no parent: one imaginary downlink
    /// to the root.
    virtual_root: ?NodeId = null,
    node: NodeId = .nil,
    index: usize = 0,
    node_low: ?u64 = null,

    fn next(self: *DownlinkCursor) ?Downlink {
        if (self.virtual_root) |root| {
            self.virtual_root = null;
            return .{ .child = root, .low = null };
        }
        if (self.node == .nil) return null;
        const p = self.tree.page(self.node);
        const link: Downlink = .{
            .child = p.node.kind.internal.children[self.index],
            .low = if (self.index == 0) self.node_low else p.node.keys[self.index - 1],
        };
        self.index += 1;
        if (self.index > p.node.len) {
            self.node_low = p.high_key;
            self.node = p.right;
            self.index = 0;
        }
        return link;
    }
};

pub fn validate(tree: *const BLinkTree) Violation!void {
    const allocated = tree.nodeCount();
    const root = tree.rootId();
    const height = tree.height;
    if (height == 0 or height > blink.max_levels) return error.BadRoot;
    if (tree.level_head[height - 1] != root) return error.BadRoot;

    var nodes: usize = 0;
    var entries: u64 = 0;
    var level = height;
    while (level > 0) {
        level -= 1;
        var downlinks: DownlinkCursor = if (level + 1 == height)
            .{ .tree = tree, .virtual_root = root }
        else
            .{ .tree = tree, .node = tree.level_head[level + 1] };

        var id = tree.level_head[level];
        var low: ?u64 = null; // high key of the node to the left
        var left_is_incomplete = false;
        while (id != .nil) {
            if (id.index() >= allocated) return error.DanglingLink;
            nodes += 1;
            if (nodes > allocated) return error.DanglingLink; // a cycle
            const p = tree.page(id);
            if (p.level != level or p.node.isLeaf() != (level == 0)) return error.WrongLevel;

            // Occupancy.
            const keys = p.node.keySlice();
            if (keys.len > tree.maxKeys()) return error.NodeOverfull;
            const min: usize = if (id != root) tree.minKeys() else if (level == 0) 0 else 1;
            if (keys.len < min) return error.NodeUnderfull;

            // Keys: ascending, and inside [low, high_key). A separator of
            // an internal node is strictly above the node's lower bound.
            for (keys, 0..) |k, i| {
                if (i > 0 and keys[i - 1] >= k) return error.KeysNotSorted;
                if (low) |lo| {
                    if (k < lo or (level > 0 and k == lo)) return error.KeyOutOfBounds;
                }
                if (p.high_key) |hk| {
                    if (k >= hk) return error.KeyOutOfBounds;
                }
            }

            // High key and right link come as a pair, and high keys ascend.
            if ((p.high_key == null) != (p.right == .nil)) return error.BrokenRightLink;
            if (low != null and p.high_key != null and p.high_key.? <= low.?) return error.BrokenRightLink;
            if (p.incomplete_split and p.right == .nil) return error.BadSplitFlag;

            // Downlink: every node has one, with the right separator,
            // unless its left sibling says the split is still in progress.
            if (!left_is_incomplete) {
                const link = downlinks.next() orelse return error.MissingDownlink;
                if (link.child != id) return error.MissingDownlink;
                if (link.low != low) return error.SeparatorMismatch;
            }

            if (level == 0) entries += keys.len;
            low = p.high_key;
            left_is_incomplete = p.incomplete_split;
            id = p.right;
        }
        // A downlink left over would point at a node that is not on the list.
        if (downlinks.next() != null) return error.MissingDownlink;
    }
    if (entries != tree.len()) return error.WrongCount;
    if (nodes != allocated) return error.OrphanNode;
}

/// Number of flagged nodes, counted by walking every level's list.
pub fn incompleteSplits(tree: *const BLinkTree) usize {
    var flagged: usize = 0;
    for (0..tree.height) |level| {
        var id = tree.level_head[level];
        while (id != .nil) : (id = tree.page(id).right) {
            if (tree.page(id).incomplete_split) flagged += 1;
        }
    }
    return flagged;
}
