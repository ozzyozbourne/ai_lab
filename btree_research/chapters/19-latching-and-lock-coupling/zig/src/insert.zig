//! The part of `put` that is the same under every protocol: what happens
//! AFTER the descent, once the caller owns the nodes it may have to change.
//!
//! The caller passes `path`: the nodes from some ancestor down to the leaf, in
//! top-down order, and promises that nobody else can read or write them now.
//!   * plain.zig passes the whole root-to-leaf path (the tree-wide lock
//!     covers everything);
//!   * coupled.zig passes exactly the nodes it still holds exclusive latches
//!     on, which the "safe node" rule guarantees are all that can change.
//!
//! Splits are the two of chapter 07: a leaf split COPIES its separator up, an
//! internal split PUSHES it up. The left half keeps the old handle.
const std = @import("std");
const assert = std.debug.assert;

const tree_ = @import("tree.zig");
const Tree = tree_.Tree;
const Node = tree_.Node;
const NodeId = tree_.NodeId;
const Hook = tree_.Hook;
const search = @import("base_search.zig");

/// `top_is_root`: path[0] is the root, so a split of path[0] grows the tree.
pub fn insertAtLeaf(tree: *Tree, path: []const NodeId, top_is_root: bool, key: u64, value: u64, hook: ?*const Hook) tree_.Error!?u64 {
    const leaf_id = path[path.len - 1];
    const leaf = tree.table.node(leaf_id);
    const at = search.lowerBound(leaf.keySlice(), key);
    if (at < leaf.len and leaf.keys[at] == key) {
        const old = leaf.kind.leaf.values[at];
        leaf.kind.leaf.values[at] = value;
        return old;
    }

    // How many nodes will split? Exactly the run of FULL nodes at the bottom
    // of the path: a full leaf splits and hands a separator to its parent,
    // which splits if it is full too, and so on up to the first node with
    // room. If the run reaches the root, one more node becomes the new root.
    const max_keys = tree.maxKeys();
    var splits: u32 = 0;
    while (splits < path.len and tree.table.node(path[path.len - 1 - splits]).len == max_keys) splits += 1;
    const grows = splits == path.len;
    // The caller must own the node that absorbs the last separator.
    assert(!grows or top_is_root);

    // Take every new node NOW, before the first change. If the table is full
    // the tree has not been touched and the caller just releases its locks.
    var next_id = (try tree.table.reserve(splits + @intFromBool(grows))).index();

    leaf.leafInsertAt(at, key, value);
    _ = tree.count.fetchAdd(1, .monotonic);

    var level = path.len;
    while (level > 0 and tree.table.node(path[level - 1]).len > max_keys) {
        level -= 1;
        const left_id = path[level];
        const left = tree.table.node(left_id);
        const right_id: NodeId = .fromIndex(next_id);
        next_id += 1;
        // The new node is not reachable from anywhere yet, so writing it
        // needs no latch. It becomes visible when the parent (which the
        // caller owns) or the root pointer is updated below.
        const right = tree.table.node(right_id);
        const separator = if (left.isLeaf()) splitLeaf(tree, left, right, right_id) else splitInternal(tree, left, right);

        if (level > 0) {
            const parent = tree.table.node(path[level - 1]);
            const i = search.childIndex(parent.keySlice(), separator);
            parent.internalInsertAt(i, separator, right_id);
        } else {
            // The root itself split: grow a new root above the two halves.
            const root_id: NodeId = .fromIndex(next_id);
            const new_root = tree.table.node(root_id);
            new_root.* = Node.initInternal();
            new_root.kind.internal.children[0] = left_id;
            new_root.internalInsertAt(0, separator, right_id);
            // PUBLISH LAST. Nobody holds a latch on the new root, and nobody
            // needs one while it is unreachable. The store below makes it
            // reachable for every thread at once, so every field must have
            // been written before it. Stored earlier, a reader could latch
            // the new root (its latch is free) and follow a child pointer
            // that is not there yet.
            tree_.emit(hook, .root_built, root_id);
            // Under latch coupling a thread that read the OLD root id and is
            // waiting for its latch will notice this store when it gets the
            // latch, and start again (coupled.latchRoot).
            tree.root.store(root_id, .release);
        }
    }
    return null;
}

/// Splits a leaf holding M entries (one too many). floor(M/2) stay, the rest
/// move. COPY-UP: the first key of `right` is returned AND stays in the leaf.
fn splitLeaf(tree: *Tree, left: *Node, right: *Node, right_id: NodeId) u64 {
    right.* = Node.initLeaf();
    const mid = left.len / 2;
    const moved = left.len - mid;
    @memcpy(right.keys[0..moved], left.keys[mid..left.len]);
    @memcpy(right.kind.leaf.values[0..moved], left.kind.leaf.values[mid..left.len]);
    right.len = moved;
    left.len = mid;
    // Chain: left -> old_next becomes left -> right -> old_next. Only `left`
    // and the new node are written; the old next leaf is not touched, which
    // is why the chain is singly linked in this chapter.
    right.kind.leaf.next = left.kind.leaf.next;
    left.kind.leaf.next = right_id;
    _ = tree.stats.leaf_splits.fetchAdd(1, .monotonic);
    return right.keys[0];
}

/// Splits an internal node holding M separators and M+1 children.
/// PUSH-UP: the middle separator is returned and kept in neither half.
fn splitInternal(tree: *Tree, left: *Node, right: *Node) u64 {
    right.* = Node.initInternal();
    const mid = left.len / 2;
    const separator = left.keys[mid];
    const moved = left.len - mid - 1;
    @memcpy(right.keys[0..moved], left.keys[mid + 1 .. left.len]);
    @memcpy(
        right.kind.internal.children[0 .. moved + 1],
        left.kind.internal.children[mid + 1 .. left.len + 1],
    );
    right.len = moved;
    left.len = mid;
    _ = tree.stats.internal_splits.fetchAdd(1, .monotonic);
    return separator;
}
