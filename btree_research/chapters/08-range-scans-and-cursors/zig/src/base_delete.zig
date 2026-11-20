// Copied from chapters/07-bplus-trees/zig/src/delete.zig; behaviour unchanged (only the
// @import paths were renamed to base_*.zig). Do not edit here.
//! Delete: remove the entry from its leaf, then repair underfull nodes on the
//! way back up by borrowing from a sibling or merging with one.
//!
//! Compared with the classic B-tree of chapter 05 there is no "delete from an
//! internal node" case at all: entries are only in leaves. If the deleted key
//! also appears as a separator higher up, the separator simply STAYS. It is
//! still a correct signpost ("everything to my right is >= me"), it just no
//! longer names a key that exists. `validate` accepts that on purpose.
const std = @import("std");
const assert = std.debug.assert;

const tree_ = @import("base_tree.zig");
const BPlusTree = tree_.BPlusTree;
const Node = tree_.Node;
const NodeId = tree_.NodeId;
const search = @import("base_search.zig");

pub fn delete(tree: *BPlusTree, key: u64) ?u64 {
    if (tree.root == .nil) return null;
    const removed = deleteFrom(tree, tree.root, key) orelse return null;
    tree.count -= 1;

    // The root is allowed to be underfull, but not to be empty.
    const root = tree.nodes.ptr(tree.root);
    if (root.len == 0) {
        const old_root = tree.root;
        switch (root.kind) {
            // Last entry gone: back to the empty tree, zero nodes.
            .leaf => {
                tree.root = .nil;
                tree.first_leaf = .nil;
                tree.last_leaf = .nil;
            },
            // An internal root with no separator has exactly one child (its
            // two children were just merged). That child becomes the root:
            // the only way a B-tree gets shorter, again for all paths at once.
            .internal => |*in| tree.root = in.children[0],
        }
        tree.nodes.free(old_root);
        tree.height -= 1;
    }
    return removed;
}

fn deleteFrom(tree: *BPlusTree, id: NodeId, key: u64) ?u64 {
    const n = tree.nodes.ptr(id);
    switch (n.kind) {
        .leaf => {
            const i = search.lowerBound(n.keySlice(), key);
            if (i == n.len or n.keys[i] != key) return null;
            return n.leafRemoveAt(i).value;
        },
        .internal => |*in| {
            const i = search.childIndex(n.keySlice(), key);
            const child_id = in.children[i];
            const removed = deleteFrom(tree, child_id, key) orelse return null;
            if (tree.nodes.get(child_id).len < tree.minKeys()) rebalance(tree, n, i);
            return removed;
        },
    }
}

/// Child `i` of `parent` has one key too few. Preference order:
///   1. borrow from the left sibling   (cheap: 3 nodes touched, none freed)
///   2. borrow from the right sibling
///   3. merge with the left sibling    (frees a node, parent loses a key and
///   4. merge with the right sibling    may now be underfull itself)
/// A merge is only chosen when both siblings are at the minimum, which is
/// exactly when the two nodes are guaranteed to fit into one.
fn rebalance(tree: *BPlusTree, parent: *Node, i: usize) void {
    const children = &parent.kind.internal.children;
    const min = tree.minKeys();
    if (i > 0 and tree.nodes.get(children[i - 1]).len > min) {
        borrowFromLeft(tree, parent, i);
    } else if (i < parent.len and tree.nodes.get(children[i + 1]).len > min) {
        borrowFromRight(tree, parent, i);
    } else if (i > 0) {
        merge(tree, parent, i - 1);
    } else {
        merge(tree, parent, i);
    }
}

/// Moves the last item of the left sibling to the front of child `i`.
/// The separator between the two is parent.keys[i-1].
fn borrowFromLeft(tree: *BPlusTree, parent: *Node, i: usize) void {
    const children = &parent.kind.internal.children;
    const left = tree.nodes.ptr(children[i - 1]);
    const child = tree.nodes.ptr(children[i]);
    switch (child.kind) {
        .leaf => {
            // The entry moves sideways; the parent gets a fresh COPY of the
            // child's new first key.
            const e = left.leafRemoveAt(left.len - 1);
            child.leafInsertAt(0, e.key, e.value);
            parent.keys[i - 1] = child.keys[0];
        },
        .internal => |*in| {
            // Rotation through the parent, as in a classic B-tree: the old
            // separator comes down, the left sibling's last key goes up, and
            // the left sibling's last child changes parent.
            const moved_child = left.kind.internal.children[left.len];
            @memmove(child.keys[1 .. child.len + 1], child.keys[0..child.len]);
            @memmove(in.children[1 .. child.len + 2], in.children[0 .. child.len + 1]);
            child.keys[0] = parent.keys[i - 1];
            in.children[0] = moved_child;
            child.len += 1;
            parent.keys[i - 1] = left.keys[left.len - 1];
            left.len -= 1;
        },
    }
    tree.stats.borrows += 1;
}

/// Moves the first item of the right sibling to the end of child `i`.
/// The separator between the two is parent.keys[i].
fn borrowFromRight(tree: *BPlusTree, parent: *Node, i: usize) void {
    const children = &parent.kind.internal.children;
    const child = tree.nodes.ptr(children[i]);
    const right = tree.nodes.ptr(children[i + 1]);
    switch (child.kind) {
        .leaf => {
            const e = right.leafRemoveAt(0);
            child.leafInsertAt(child.len, e.key, e.value);
            parent.keys[i] = right.keys[0];
        },
        .internal => |*in| {
            child.keys[child.len] = parent.keys[i];
            in.children[child.len + 1] = right.kind.internal.children[0];
            child.len += 1;
            parent.keys[i] = right.keys[0];
            // Drop right's first key and first child.
            const rc = &right.kind.internal.children;
            @memmove(right.keys[0 .. right.len - 1], right.keys[1..right.len]);
            @memmove(rc[0..right.len], rc[1 .. right.len + 1]);
            right.len -= 1;
        },
    }
    tree.stats.borrows += 1;
}

/// Merges child `li + 1` into child `li` and frees it. Always right INTO
/// left, so the surviving node keeps its handle and `first_leaf` never needs
/// to change.
fn merge(tree: *BPlusTree, parent: *Node, li: usize) void {
    const children = &parent.kind.internal.children;
    const left_id = children[li];
    const right_id = children[li + 1];
    const left = tree.nodes.ptr(left_id);
    const right = tree.nodes.ptr(right_id);
    switch (left.kind) {
        .leaf => |*leaf| {
            // The separator between two leaves was only a copy: drop it.
            const rl = &right.kind.leaf;
            @memcpy(left.keys[left.len .. left.len + right.len], right.keys[0..right.len]);
            @memcpy(leaf.values[left.len .. left.len + right.len], rl.values[0..right.len]);
            left.len += right.len;
            // Unlink `right` from the chain (invariant 6).
            leaf.next = rl.next;
            if (rl.next != .nil) {
                tree.nodes.ptr(rl.next).kind.leaf.prev = left_id;
            } else {
                tree.last_leaf = left_id;
            }
        },
        .internal => |*in| {
            // The separator between two internal nodes is real routing
            // information for the children being joined: pull it DOWN.
            const rc = &right.kind.internal.children;
            left.keys[left.len] = parent.keys[li];
            @memcpy(left.keys[left.len + 1 .. left.len + 1 + right.len], right.keys[0..right.len]);
            @memcpy(in.children[left.len + 1 .. left.len + 2 + right.len], rc[0 .. right.len + 1]);
            left.len += 1 + right.len;
        },
    }
    assert(left.len <= tree.maxKeys());
    parent.internalRemoveAt(li);
    tree.nodes.free(right_id);
    tree.stats.merges += 1;
}
