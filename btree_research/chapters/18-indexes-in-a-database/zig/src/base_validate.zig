// Copied from chapters/07-bplus-trees/zig/src/validate.zig; only the @import paths were renamed to base_*.
//! `validate`: checks every invariant listed in tree.zig and names the first
//! one that is broken. Tests call it after every few operations; a bug in
//! insert or delete then fails close to the operation that caused it.
//!
//! The checker trusts nothing it reads from a node: a child handle is tested
//! with `isLive` before it is followed.
const std = @import("std");
const BPlusTree = @import("base_tree.zig").BPlusTree;
const NodeId = @import("base_arena.zig").NodeId;

pub const Violation = error{
    /// root / first_leaf / last_leaf / height / count disagree about emptiness.
    BadRoot,
    /// A child handle is nil, out of range, or names a freed slot.
    DanglingChild,
    /// More than M-1 keys.
    NodeOverfull,
    /// Fewer than ceil(M/2)-1 keys in a non-root node, or an empty root.
    NodeUnderfull,
    /// Keys inside a node are not strictly ascending.
    KeysNotSorted,
    /// A key lies outside the range its ancestors' separators allow.
    KeyOutOfBounds,
    /// A leaf is not at depth `height`.
    UnevenLeafDepth,
    /// The next/prev chain is not the leaves in tree order.
    BrokenLeafChain,
    /// `count` is not the number of entries in the leaves.
    WrongCount,
    /// Live arena slots that the tree does not reach, or a corrupt free list.
    ArenaLeak,
};

const Walk = struct {
    /// The leaf the chain says comes next (starts at tree.first_leaf).
    expected_leaf: NodeId,
    /// The leaf visited before it.
    prev_leaf: NodeId = .nil,
    entries: usize = 0,
    nodes: usize = 0,
};

pub fn validate(tree: *const BPlusTree) Violation!void {
    if (tree.root == .nil) {
        if (tree.first_leaf != .nil or tree.last_leaf != .nil) return error.BadRoot;
        if (tree.height != 0 or tree.count != 0) return error.BadRoot;
        if (tree.nodes.liveCount() != 0) return error.ArenaLeak;
    } else {
        if (!tree.nodes.isLive(tree.root)) return error.BadRoot;
        var walk: Walk = .{ .expected_leaf = tree.first_leaf };
        try checkNode(tree, tree.root, 1, null, null, &walk);
        // The chain must end exactly where the tree's last leaf is.
        if (walk.expected_leaf != .nil or walk.prev_leaf != tree.last_leaf) return error.BrokenLeafChain;
        if (walk.entries != tree.count) return error.WrongCount;
        // Every live slot must be reachable from the root: nothing leaked.
        if (walk.nodes != tree.nodes.liveCount()) return error.ArenaLeak;
    }
    // live + free must account for every slot ever created.
    const free = tree.nodes.freeCount() orelse return error.ArenaLeak;
    if (free + tree.nodes.liveCount() != tree.nodes.slotCount()) return error.ArenaLeak;
}

/// Checks the subtree rooted at `id`. `lo` (inclusive) and `hi` (exclusive)
/// are the bounds inherited from the separators above; null means unbounded.
/// Leaves are visited left to right, so the visit order can be compared with
/// the sibling links as we go.
fn checkNode(tree: *const BPlusTree, id: NodeId, depth: usize, lo: ?u64, hi: ?u64, walk: *Walk) Violation!void {
    const n = tree.nodes.get(id);
    const keys = n.keySlice();
    const is_root = id == tree.root;
    walk.nodes += 1;

    if (n.len > tree.maxKeys()) return error.NodeOverfull;
    if (n.len < (if (is_root) 1 else tree.minKeys())) return error.NodeUnderfull;
    for (keys, 0..) |k, i| {
        if (i > 0 and keys[i - 1] >= k) return error.KeysNotSorted;
        if (lo != null and k < lo.?) return error.KeyOutOfBounds;
        if (hi != null and k >= hi.?) return error.KeyOutOfBounds;
    }

    switch (n.kind) {
        .leaf => |*leaf| {
            if (depth != tree.height) return error.UnevenLeafDepth;
            if (walk.expected_leaf != id or leaf.prev != walk.prev_leaf) return error.BrokenLeafChain;
            walk.prev_leaf = id;
            walk.expected_leaf = leaf.next;
            walk.entries += n.len;
        },
        .internal => {
            for (n.childSlice(), 0..) |child, i| {
                if (!tree.nodes.isLive(child)) return error.DanglingChild;
                // Child i may hold keys in [keys[i-1], keys[i]).
                const child_lo = if (i == 0) lo else keys[i - 1];
                const child_hi = if (i == n.len) hi else keys[i];
                try checkNode(tree, child, depth + 1, child_lo, child_hi, walk);
            }
        },
    }
}
