//! SECTION 5: delete with borrow, merge and root shrink (THIS chapter).
//!
//! Removing a key can leave a node with fewer than `min_keys` keys
//! (an *underflow*). The repair is always done by the PARENT of the underfull
//! node, right after the recursive call returns, because only the parent can
//! reach the siblings and the separator keys between them:
//!
//!   removeFrom(node, key)
//!     leaf:      remove the entry                       (may underflow)
//!     interior, key is in this node:
//!                replace it with its in-order predecessor, which is taken
//!                out of the left subtree's right-most leaf (may underflow)
//!     interior, key is further down:
//!                recurse into the child                 (may underflow)
//!     then:      fixUnderflow(node, child index)
//!
//! `fixUnderflow` restores the child to at least `min_keys` keys by
//!   1. borrowing one entry from the left sibling through the parent, or
//!   2. borrowing one entry from the right sibling through the parent, or
//!   3. merging the child with a sibling and the separator between them.
//! Only a merge takes a key away from the parent, so only a merge can make
//! the underflow travel one level up. At the root there is no parent and no
//! minimum: when the root has no keys left, its only child becomes the root
//! and the tree gets one level shorter.
//!
//! Delete never allocates: it only ever returns nodes to the pool.
const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("node.zig");
const search = @import("search.zig");

/// `Tree` is a `BTree(M, PoolFn)` from btree.zig. Returns the removed value,
/// or null if the key was not present (the tree is then unchanged).
pub fn delete(comptime Tree: type, tree: *Tree, gpa: Allocator, key: u64) ?u64 {
    const root = tree.root orelse return null;
    const removed = removeFrom(Tree, tree, gpa, root, key) orelse return null;
    tree.len -= 1;
    if (root.len == 0) {
        // Root shrink. Either the last key of the tree was deleted (leaf
        // root: the tree becomes empty) or a merge pulled the root's last
        // separator down (interior root: its single child holds everything).
        // Every leaf gets one level closer to the root at the same time, so
        // "all leaves at the same depth" still holds.
        tree.root = if (root.leaf) null else root.children[0];
        tree.pool.destroy(gpa, root);
        if (tree.root != null) tree.counters.root_shrinks += 1;
    }
    return removed;
}

fn removeFrom(comptime Tree: type, tree: *Tree, gpa: Allocator, node: *Tree.NodeT, key: u64) ?u64 {
    const i = search.lowerBound(node.keySlice(), key);
    const found = i < node.len and node.keys[i] == key;

    if (node.leaf) {
        // Case 1: the key is in a leaf. Just take it out; if the leaf is now
        // too small, our caller (the parent) repairs it.
        return if (found) node.removeEntry(i).value else null;
    }

    if (found) {
        // Case 2: the key is in an interior node. It separates children[i]
        // from children[i + 1], so it cannot simply vanish. Its in-order
        // predecessor (the largest key of children[i]) is the best
        // replacement: it is larger than everything else on the left and
        // smaller than everything on the right, and it sits in a leaf, where
        // removal is easy. This turns every interior delete into a leaf delete.
        const removed = node.values[i];
        const predecessor = removeMax(Tree, tree, gpa, node.children[i].?);
        node.keys[i] = predecessor.key;
        node.values[i] = predecessor.value;
        tree.counters.predecessor_swaps += 1;
        fixUnderflow(Tree, tree, gpa, node, i);
        return removed;
    }

    // Case 3: the key, if present, is in the subtree of children[i].
    const removed = removeFrom(Tree, tree, gpa, node.children[i].?, key) orelse return null;
    fixUnderflow(Tree, tree, gpa, node, i);
    return removed;
}

/// Remove and return the largest entry of the subtree: always the last entry
/// of the right-most leaf. Underflows are repaired on the way back up.
fn removeMax(comptime Tree: type, tree: *Tree, gpa: Allocator, node: *Tree.NodeT) node_mod.Entry {
    if (node.leaf) return node.removeEntry(node.len - 1);
    const last = node.len; // index of the right-most child
    const entry = removeMax(Tree, tree, gpa, node.children[last].?);
    fixUnderflow(Tree, tree, gpa, node, last);
    return entry;
}

/// If parent.children[i] has fewer than `min_keys` keys, repair it.
/// Afterwards every child of `parent` is legal again; `parent` itself may
/// have lost one key (merge), which its own parent checks next.
fn fixUnderflow(comptime Tree: type, tree: *Tree, gpa: Allocator, parent: *Tree.NodeT, i: usize) void {
    const N = Tree.NodeT;
    const child = parent.children[i].?;
    if (child.len >= N.min_keys) return;
    std.debug.assert(child.len == N.min_keys - 1); // one delete removes one key

    // A sibling can lend a key only if it stays legal afterwards.
    if (i > 0 and parent.children[i - 1].?.len > N.min_keys) {
        borrowFromLeft(N, parent, i);
        tree.counters.borrows_left += 1;
    } else if (i < parent.len and parent.children[i + 1].?.len > N.min_keys) {
        borrowFromRight(N, parent, i);
        tree.counters.borrows_right += 1;
    } else {
        // No sibling can spare a key. Merge with the left sibling if there is
        // one, otherwise with the right one. `at` is the separator between them.
        const at = if (i > 0) i - 1 else i;
        const emptied = mergeChildren(N, parent, at);
        tree.pool.destroy(gpa, emptied);
        tree.counters.merges += 1;
    }
}

/// Rotate one entry clockwise through the parent:
///
///     parent:        [.. S ..]                 [.. L ..]
///     left / child:  [a b L]  [x]      ->      [a b]  [S x]
///
/// The separator S moves down to the front of the child, and the left
/// sibling's largest entry L moves up to take its place. A key cannot move
/// sideways directly: S lies between the two nodes in key order, so skipping
/// it would break the ordering invariant. In interior nodes the left
/// sibling's last child (keys between L and S) changes parent as well.
fn borrowFromLeft(comptime N: type, parent: *N, i: usize) void {
    const child = parent.children[i].?;
    const left = parent.children[i - 1].?;
    const sep = i - 1;
    if (!child.leaf) child.insertChild(0, left.children[left.len].?);
    child.insertEntry(0, parent.keys[sep], parent.values[sep]);
    const up = left.removeEntry(left.len - 1);
    if (!left.leaf) _ = left.removeChild(left.len + 1);
    parent.keys[sep] = up.key;
    parent.values[sep] = up.value;
}

/// Mirror image: the separator moves down to the END of the child, the right
/// sibling's SMALLEST entry moves up, and the right sibling's first child
/// moves over.
fn borrowFromRight(comptime N: type, parent: *N, i: usize) void {
    const child = parent.children[i].?;
    const right = parent.children[i + 1].?;
    const sep = i;
    if (!child.leaf) child.insertChild(child.len + 1, right.children[0].?);
    child.insertEntry(child.len, parent.keys[sep], parent.values[sep]);
    const up = right.removeEntry(0);
    if (!right.leaf) _ = right.removeChild(0);
    parent.keys[sep] = up.key;
    parent.values[sep] = up.value;
}

/// Merge children[at], the separator keys[at] and children[at + 1] into
/// children[at]. Returns the now unused right node so the caller can free it.
///
///     parent:  [.. S ..]            [.. ..]
///     nodes:   [a]  [ ]      ->     [a S]
///
/// It always fits: one node has min_keys - 1 keys, the other exactly
/// min_keys (otherwise we would have borrowed), plus the separator:
/// 2 * min_keys <= M - 1. The separator MUST come down: with one child fewer
/// the parent needs one key fewer.
fn mergeChildren(comptime N: type, parent: *N, at: usize) *N {
    const left = parent.children[at].?;
    const right = parent.children[at + 1].?;
    std.debug.assert(left.len + 1 + right.len <= N.max_keys);
    const sep = parent.removeEntry(at);
    _ = parent.removeChild(at + 1);
    if (!left.leaf) {
        // left has left.len + 1 children; right's children follow them.
        for (0..right.len + 1) |j| left.children[left.len + 1 + j] = right.children[j];
    }
    left.insertEntry(left.len, sep.key, sep.value);
    for (0..right.len) |j| left.insertEntry(left.len, right.keys[j], right.values[j]);
    return right;
}
