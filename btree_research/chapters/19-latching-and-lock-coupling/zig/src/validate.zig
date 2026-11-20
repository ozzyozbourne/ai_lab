//! `validate`: checks every invariant listed in tree.zig and names the first
//! one that is broken.
//!
//! QUIESCENT ONLY. It takes no lock and no latch, so it must run when no
//! operation is in flight: after the worker threads have been joined, or
//! between the operations of a single-threaded test. A concurrent test that
//! ends with a valid tree AND the right contents has not proved the protocol
//! correct, but a protocol bug very often leaves one of these broken.
const std = @import("std");
const tree_ = @import("tree.zig");
const Tree = tree_.Tree;
const NodeId = tree_.NodeId;

pub const Violation = error{
    /// The root handle does not name a node of the table.
    BadRoot,
    /// A child handle is nil or beyond the nodes handed out so far.
    DanglingChild,
    /// More than M-1 keys.
    NodeOverfull,
    /// Fewer than ceil(M/2)-1 keys in a non-root node, or an empty internal root.
    NodeUnderfull,
    /// Keys inside a node are not strictly ascending.
    KeysNotSorted,
    /// A key lies outside the range its ancestors' separators allow.
    KeyOutOfBounds,
    /// Leaves are not all at the same depth.
    UnevenLeafDepth,
    /// The `next` chain is not the leaves in tree order.
    BrokenLeafChain,
    /// `count` is not the number of entries in the leaves.
    WrongCount,
    /// A node was handed out by the table but is not reachable from the root:
    /// a split reserved it and never linked it in.
    UnreachableNode,
};

const Walk = struct {
    /// The leaf the chain says comes next; null before the first leaf.
    expected_leaf: ?NodeId = null,
    leaf_depth: ?usize = null,
    entries: usize = 0,
    nodes: usize = 0,
};

pub fn validate(tree: *const Tree) Violation!void {
    const root = tree.root.load(.acquire);
    if (root == .nil or root.index() >= tree.table.count()) return error.BadRoot;
    var walk: Walk = .{};
    try checkNode(tree, root, 1, null, null, &walk);
    // The chain must end at the last leaf of the tree.
    if (walk.expected_leaf != .nil) return error.BrokenLeafChain;
    if (walk.entries != tree.len()) return error.WrongCount;
    if (walk.nodes != tree.table.count()) return error.UnreachableNode;
}

/// Checks the subtree rooted at `id`. `lo` (inclusive) and `hi` (exclusive)
/// are the bounds inherited from the separators above; null means unbounded.
fn checkNode(tree: *const Tree, id: NodeId, depth: usize, lo: ?u64, hi: ?u64, walk: *Walk) Violation!void {
    const n = tree.table.node(id);
    const keys = n.keySlice();
    const is_root = depth == 1;
    walk.nodes += 1;

    if (n.len > tree.maxKeys()) return error.NodeOverfull;
    // The root may be an empty leaf (the tree starts that way).
    const min: usize = if (!is_root) tree.minKeys() else if (n.isLeaf()) 0 else 1;
    if (n.len < min) return error.NodeUnderfull;
    for (keys, 0..) |k, i| {
        if (i > 0 and keys[i - 1] >= k) return error.KeysNotSorted;
        if (lo != null and k < lo.?) return error.KeyOutOfBounds;
        if (hi != null and k >= hi.?) return error.KeyOutOfBounds;
    }

    switch (n.kind) {
        .leaf => |*leaf| {
            if (walk.leaf_depth == null) walk.leaf_depth = depth;
            if (walk.leaf_depth.? != depth) return error.UnevenLeafDepth;
            // Leaves are visited left to right, so each one must be what the
            // previous leaf's `next` link announced.
            if (walk.expected_leaf != null and walk.expected_leaf.? != id) return error.BrokenLeafChain;
            walk.expected_leaf = leaf.next;
            walk.entries += n.len;
        },
        .internal => {
            for (n.childSlice(), 0..) |child, i| {
                if (child == .nil or child.index() >= tree.table.count()) return error.DanglingChild;
                const child_lo = if (i == 0) lo else keys[i - 1];
                const child_hi = if (i == n.len) hi else keys[i];
                try checkNode(tree, child, depth + 1, child_lo, child_hi, walk);
            }
        },
    }
}
