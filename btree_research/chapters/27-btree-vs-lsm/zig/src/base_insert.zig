// Copied from chapters/07-bplus-trees/zig/src/insert.zig; changes for chapter 27 are marked "ch27:"
//! Insert: descend to the leaf, insert there, and split overflowing nodes on
//! the way back up (bottom-up splitting, as in chapter 04).
//!
//! The two splits are NOT the same, and that difference is the chapter:
//!
//!   leaf split      COPY-UP : the first key of the new right leaf is copied
//!                             into the parent. The entry itself stays in the
//!                             leaf, because leaves are the only place where
//!                             values live.
//!   internal split  PUSH-UP : the middle separator MOVES into the parent and
//!                             is in neither half, exactly as in a classic
//!                             B-tree. A separator is needed once per boundary.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const tree_ = @import("base_tree.zig");
const BPlusTree = tree_.BPlusTree;
const Node = tree_.Node;
const NodeId = tree_.NodeId;
const search = @import("base_search.zig");

/// What a child reports to its parent after an insert below it.
const Split = struct {
    /// Smallest key that may appear in `right`'s subtree.
    separator: u64,
    right: NodeId,
};

const Result = union(enum) {
    /// The key existed; only a value changed. Carries the old value.
    replaced: u64,
    /// A new entry was added and this subtree absorbed it.
    inserted,
    /// A new entry was added and this node split in two.
    split: Split,
};

pub fn put(tree: *BPlusTree, gpa: Allocator, key: u64, value: u64) Allocator.Error!?u64 {
    // Reserve the worst case BEFORE touching anything: one new node per level
    // (every node on the path splits) plus one new root. For an empty tree
    // that is 0 + 1: the first leaf.
    //   * If the reservation fails the tree has not been modified at all.
    //   * After it succeeds no allocation below can fail or move the node
    //     array, so the `*Node` pointers used below stay valid.
    // The price: even an overwrite, which needs no node, can report
    // OutOfMemory. Simplicity wins here.
    try tree.nodes.reserve(gpa, tree.height + 1);

    if (tree.root == .nil) {
        const id = tree.nodes.allocAssumeCapacity(Node.initLeaf());
        tree.root = id;
        tree.first_leaf = id;
        tree.last_leaf = id;
        tree.height = 1;
    }

    switch (insertInto(tree, tree.root, key, value)) {
        .replaced => |old| return old,
        .inserted => {},
        .split => |s| {
            // The root itself split: grow a new root above the two halves.
            // This is the only way a B-tree gets taller, and it adds one level
            // to EVERY path at once, which keeps all leaves at the same depth.
            var new_root = Node.initInternal();
            new_root.kind.internal.children[0] = tree.root;
            new_root.internalInsertAt(0, s.separator, s.right);
            tree.root = tree.nodes.allocAssumeCapacity(new_root);
            tree.height += 1;
        },
    }
    tree.count += 1;
    return null;
}

fn insertInto(tree: *BPlusTree, id: NodeId, key: u64, value: u64) Result {
    const n = tree.nodes.ptr(id);
    switch (n.kind) {
        .leaf => |*leaf| {
            const i = search.lowerBound(n.keySlice(), key);
            if (i < n.len and n.keys[i] == key) {
                const old = leaf.values[i];
                leaf.values[i] = value;
                return .{ .replaced = old };
            }
            // Insert first, split afterwards: the arrays have one spare slot
            // (node.key_capacity), so the leaf may briefly hold M keys.
            n.leafInsertAt(i, key, value);
            if (n.len <= tree.maxKeys()) return .inserted;
            return .{ .split = splitLeaf(tree, id) };
        },
        .internal => |*in| {
            const i = search.childIndex(n.keySlice(), key);
            const result = insertInto(tree, in.children[i], key, value);
            switch (result) {
                .replaced, .inserted => return result,
                .split => |s| {
                    // Child i became two nodes: i (left half, same handle)
                    // and s.right. Slot the separator in between them.
                    n.internalInsertAt(i, s.separator, s.right);
                    if (n.len <= tree.maxKeys()) return .inserted;
                    return .{ .split = splitInternal(tree, id) };
                },
            }
        },
    }
}

/// Splits a leaf holding M entries (one too many).
/// The left half keeps the old handle, so the parent's child pointer and the
/// left neighbour's `next` link stay correct without being touched.
fn splitLeaf(tree: *BPlusTree, left_id: NodeId) Split {
    const right_id = tree.nodes.allocAssumeCapacity(Node.initLeaf());
    const left = tree.nodes.ptr(left_id);
    const right = tree.nodes.ptr(right_id);

    // floor(M/2) entries stay, ceil(M/2) move. Both halves end up with at
    // least ceil(M/2)-1 keys, the minimum (invariant 4).
    const mid = left.len / 2;
    const moved = left.len - mid;
    @memcpy(right.keys[0..moved], left.keys[mid..left.len]);
    @memcpy(right.kind.leaf.values[0..moved], left.kind.leaf.values[mid..left.len]);
    right.len = moved;
    left.len = mid;

    // Splice the new leaf into the chain right after the old one (invariant 6):
    //   left <-> old_next      becomes      left <-> right <-> old_next
    const old_next = left.kind.leaf.next;
    right.kind.leaf.prev = left_id;
    right.kind.leaf.next = old_next;
    left.kind.leaf.next = right_id;
    if (old_next != .nil) {
        tree.nodes.ptr(old_next).kind.leaf.prev = right_id;
    } else {
        tree.last_leaf = right_id; // we split the rightmost leaf
    }

    tree.stats.leaf_splits += 1;
    // COPY-UP: right.keys[0] goes to the parent AND stays in the leaf.
    return .{ .separator = right.keys[0], .right = right_id };
}

/// Splits an internal node holding M separators and M+1 children.
fn splitInternal(tree: *BPlusTree, left_id: NodeId) Split {
    const right_id = tree.nodes.allocAssumeCapacity(Node.initInternal());
    const left = tree.nodes.ptr(left_id);
    const right = tree.nodes.ptr(right_id);

    //   keys:      k0 .. k(mid-1) | k(mid) | k(mid+1) .. k(len-1)
    //   children: c0 ..    c(mid) |        | c(mid+1) ..   c(len)
    //              stay in left     goes up    move to right
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

    tree.stats.internal_splits += 1;
    // PUSH-UP: the separator is returned to the parent and kept in neither half.
    return .{ .separator = separator, .right = right_id };
}
