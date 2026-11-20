//! SECTION 6a: the invariants as code.
//!
//! `validate` walks the whole tree and returns the first broken invariant.
//! Every test calls it after every operation; chapter 06 builds a fuzzer on it.
//!
//! This file needs only node.zig: it knows nothing about pools, insert or
//! delete, and works on trees built by hand.
const std = @import("std");
const Node = @import("base_node.zig").Node;

pub const Error = error{
    /// Keys inside a node are not strictly ascending.
    KeysOutOfOrder,
    /// A key is not between the two separators above it.
    KeyOutsideParentBounds,
    /// More than M - 1 keys.
    NodeOverfull,
    /// A non-root node with fewer than ceil(M/2) - 1 keys.
    NodeUnderfull,
    /// A root with zero keys (an empty tree has no root at all).
    EmptyRoot,
    /// Two leaves at different depths.
    LeavesAtDifferentDepths,
    /// An interior node without one of its len + 1 children.
    MissingChild,
    /// A child pointer where there must be none (leaf, or beyond len + 1).
    UnexpectedChild,
    /// The number of keys in the tree differs from the tree's `len`.
    WrongKeyCount,
    /// The pool's live-node counter differs from the number of nodes
    /// reachable from the root: a node was leaked. Not returned by the
    /// function below, which sees no pool; `BTree.validate` adds this check.
    NodeCountMismatch,
};

pub fn validate(comptime M: usize, root: ?*const Node(M), expected_len: usize) Error!void {
    var count: usize = 0;
    if (root) |r| {
        if (r.len == 0) return error.EmptyRoot;
        var leaf_depth: ?usize = null;
        try check(M, r, null, null, true, 0, &leaf_depth, &count);
    }
    if (count != expected_len) return error.WrongKeyCount;
}

/// `lo` / `hi` are exclusive bounds inherited from the separators in the
/// ancestors (null = unbounded).
fn check(
    comptime M: usize,
    node: *const Node(M),
    lo: ?u64,
    hi: ?u64,
    is_root: bool,
    depth: usize,
    leaf_depth: *?usize,
    count: *usize,
) Error!void {
    const N = Node(M);
    if (node.len > N.max_keys) return error.NodeOverfull;
    if (!is_root and node.len < N.min_keys) return error.NodeUnderfull;
    count.* += node.len;

    for (node.keySlice(), 0..) |key, i| {
        if (i > 0 and node.keys[i - 1] >= key) return error.KeysOutOfOrder;
        if (lo) |l| if (key <= l) return error.KeyOutsideParentBounds;
        if (hi) |h| if (key >= h) return error.KeyOutsideParentBounds;
    }

    if (node.leaf) {
        for (node.children) |child| if (child != null) return error.UnexpectedChild;
        if (leaf_depth.*) |d| {
            if (d != depth) return error.LeavesAtDifferentDepths;
        } else leaf_depth.* = depth;
        return;
    }

    for (node.children, 0..) |child, i| {
        if (i > node.len) {
            if (child != null) return error.UnexpectedChild;
            continue;
        }
        const c = child orelse return error.MissingChild;
        // Child i lives strictly between separator i - 1 and separator i.
        const child_lo = if (i == 0) lo else node.keys[i - 1];
        const child_hi = if (i == node.len) hi else node.keys[i];
        try check(M, c, child_lo, child_hi, false, depth + 1, leaf_depth, count);
    }
}

test "validate names the broken invariant" {
    //            [20]
    //     [5 10]      [30 40]
    const N = Node(4);
    var left: N = .{ .leaf = true };
    left.insertEntry(0, 5, 0);
    left.insertEntry(1, 10, 0);
    var right: N = .{ .leaf = true };
    right.insertEntry(0, 30, 0);
    right.insertEntry(1, 40, 0);
    var root: N = .{ .leaf = false };
    root.children[0] = &left;
    root.insertChild(1, &right);
    root.insertEntry(0, 20, 0);
    try validate(4, &root, 5);
    try validate(4, null, 0);

    try std.testing.expectError(error.WrongKeyCount, validate(4, &root, 4));

    left.keys[1] = 5;
    try std.testing.expectError(error.KeysOutOfOrder, validate(4, &root, 5));
    left.keys[1] = 25; // sorted inside the leaf, but on the wrong side of 20
    try std.testing.expectError(error.KeyOutsideParentBounds, validate(4, &root, 5));
    left.keys[1] = 10;

    right.len = 0;
    try std.testing.expectError(error.NodeUnderfull, validate(4, &root, 3));
    right.len = 4;
    try std.testing.expectError(error.NodeOverfull, validate(4, &root, 7));
    right.len = 2;

    root.children[1] = null;
    try std.testing.expectError(error.MissingChild, validate(4, &root, 5));
    root.children[1] = &right;
    left.children[0] = &right;
    try std.testing.expectError(error.UnexpectedChild, validate(4, &root, 5));
    left.children[0] = null;

    // Hang a subtree under the right slot: its leaves are one level deeper.
    var deep_a: N = .{ .leaf = true };
    deep_a.insertEntry(0, 25, 0);
    var deep_b: N = .{ .leaf = true };
    deep_b.insertEntry(0, 35, 0);
    var mid: N = .{ .leaf = false };
    mid.children[0] = &deep_a;
    mid.insertChild(1, &deep_b);
    mid.insertEntry(0, 30, 0);
    root.children[1] = &mid;
    try std.testing.expectError(error.LeavesAtDifferentDepths, validate(4, &root, 6));

    var empty_root: N = .{ .leaf = true };
    try std.testing.expectError(error.EmptyRoot, validate(4, &empty_root, 0));
}
