// Copied from chapters/05-deletion-and-rebalancing/zig/src/validate.zig
// Changes for chapter 06: `Diagnostic` (WHERE the invariant broke), and a node's
// own checks (including its child slots) now all run before the walk descends.
//! The invariants as code (README section "Invariants as code").
//!
//! `validate` walks the whole tree and returns the first broken invariant as
//! an error value. Each invariant has its own error, so a failing fuzz run
//! says WHICH promise was broken; the optional `Diagnostic` says WHERE.
//!
//! A Zig error is a bare tag: it cannot carry data. The standard idiom for
//! "error plus details" is an out-parameter that the function fills in
//! before it returns the error (`std.json` and `std.zon` do the same). In
//! Rust the details simply travel inside the `Err` value.
//!
//! This file needs only base_node.zig: it knows nothing about pools, insert
//! or delete, and works on trees built by hand.
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

/// Where the walk stopped. Only meaningful after an error; whole-tree errors
/// (WrongKeyCount, NodeCountMismatch) leave it at the default.
pub const Diagnostic = struct {
    /// Depth of the offending node (root = 0).
    depth: usize = 0,
    /// Its first key, to find the node in a rendering of the tree.
    first_key: ?u64 = null,
};

pub fn validate(comptime M: usize, root: ?*const Node(M), expected_len: usize, diag: ?*Diagnostic) Error!void {
    if (diag) |d| d.* = .{};
    var count: usize = 0;
    if (root) |r| {
        if (r.len == 0) return error.EmptyRoot;
        var walk: Walk(M) = .{ .diag = diag };
        try walk.check(r, null, null, 0);
        count = walk.count;
    }
    if (count != expected_len) return error.WrongKeyCount;
}

fn Walk(comptime M: usize) type {
    return struct {
        const Self = @This();
        const N = Node(M);

        diag: ?*Diagnostic,
        leaf_depth: ?usize = null,
        count: usize = 0,

        /// `lo` / `hi` are exclusive bounds inherited from the separators in
        /// the ancestors (null = unbounded).
        fn check(self: *Self, node: *const N, lo: ?u64, hi: ?u64, depth: usize) Error!void {
            // Everything that can be said about this node alone comes first,
            // so the error names the node closest to the root that is wrong.
            self.checkNode(node, lo, hi, depth) catch |err| {
                if (self.diag) |d| d.* = .{ .depth = depth, .first_key = if (node.len > 0) node.keys[0] else null };
                return err;
            };
            if (node.leaf) return;
            for (node.children[0 .. node.len + 1], 0..) |child, i| {
                // Child i lives strictly between separator i - 1 and separator i.
                const child_lo = if (i == 0) lo else node.keys[i - 1];
                const child_hi = if (i == node.len) hi else node.keys[i];
                try self.check(child.?, child_lo, child_hi, depth + 1);
            }
        }

        fn checkNode(self: *Self, node: *const N, lo: ?u64, hi: ?u64, depth: usize) Error!void {
            if (node.len > N.max_keys) return error.NodeOverfull;
            if (depth > 0 and node.len < N.min_keys) return error.NodeUnderfull;
            self.count += node.len;

            for (node.keySlice(), 0..) |key, i| {
                if (i > 0 and node.keys[i - 1] >= key) return error.KeysOutOfOrder;
                if (lo) |l| if (key <= l) return error.KeyOutsideParentBounds;
                if (hi) |h| if (key >= h) return error.KeyOutsideParentBounds;
            }

            // Child slots: exactly len + 1 in an interior node, none in a leaf.
            const want: usize = if (node.leaf) 0 else node.len + 1;
            for (node.children, 0..) |child, i| {
                if (i < want and child == null) return error.MissingChild;
                if (i >= want and child != null) return error.UnexpectedChild;
            }

            if (node.leaf) {
                if (self.leaf_depth) |d| {
                    if (d != depth) return error.LeavesAtDifferentDepths;
                } else self.leaf_depth = depth;
            }
        }
    };
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
    try validate(4, &root, 5, null);
    try validate(4, null, 0, null);

    try std.testing.expectError(error.WrongKeyCount, validate(4, &root, 4, null));

    left.keys[1] = 5;
    try std.testing.expectError(error.KeysOutOfOrder, validate(4, &root, 5, null));
    left.keys[1] = 25; // sorted inside the leaf, but on the wrong side of 20
    try std.testing.expectError(error.KeyOutsideParentBounds, validate(4, &root, 5, null));
    left.keys[1] = 10;

    right.len = 0;
    try std.testing.expectError(error.NodeUnderfull, validate(4, &root, 3, null));
    right.len = 4;
    try std.testing.expectError(error.NodeOverfull, validate(4, &root, 7, null));
    right.len = 2;

    root.children[1] = null;
    try std.testing.expectError(error.MissingChild, validate(4, &root, 5, null));
    root.children[1] = &right;
    left.children[0] = &right;
    try std.testing.expectError(error.UnexpectedChild, validate(4, &root, 5, null));
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
    try std.testing.expectError(error.LeavesAtDifferentDepths, validate(4, &root, 6, null));

    var empty_root: N = .{ .leaf = true };
    try std.testing.expectError(error.EmptyRoot, validate(4, &empty_root, 0, null));

    // The diagnostic points at the node that broke the rule.
    var diag: Diagnostic = .{};
    root.children[1] = &right;
    right.keys[0] = 50; // [50 40]
    try std.testing.expectError(error.KeysOutOfOrder, validate(4, &root, 5, &diag));
    try std.testing.expectEqual(Diagnostic{ .depth = 1, .first_key = 50 }, diag);
}
