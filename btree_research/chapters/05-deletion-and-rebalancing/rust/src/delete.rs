//! SECTION 5 of 6: delete with borrow, merge and root shrink (THIS chapter).
//!
//! Removing a key can leave a node with fewer than `min_keys` keys
//! (an *underflow*). The repair is always done by the PARENT of the underfull
//! node, right after the recursive call returns, because only the parent can
//! reach the siblings and the separator keys between them:
//!
//! ```text
//! remove_from(node, key)
//!   leaf:      remove the entry                       (may underflow)
//!   interior, key is in this node:
//!              replace it with its in-order predecessor, which is taken
//!              out of the left subtree's right-most leaf (may underflow)
//!   interior, key is further down:
//!              recurse into the child                 (may underflow)
//!   then:      fix_underflow(node, child index)
//! ```
//!
//! `fix_underflow` restores the child to at least `min_keys` keys by
//!
//! 1. borrowing one entry from the left sibling through the parent, or
//! 2. borrowing one entry from the right sibling through the parent, or
//! 3. merging the child with a sibling and the separator between them.
//!
//! Only a merge takes a key away from the parent, so only a merge can make
//! the underflow travel one level up. At the root there is no parent and no
//! minimum: when the root has no keys left, its only child becomes the root
//! and the tree gets one level shorter.
//!
//! Delete never allocates: it only ever returns nodes to the pool.

use crate::btree::BTree;
use crate::node::{Entry, NodeId, max_keys, min_keys};
use crate::search::lower_bound;

/// Returns the removed value, or `None` if the key was not present (the tree
/// is then unchanged).
pub fn delete(tree: &mut BTree, key: u64) -> Option<u64> {
    let root = tree.root?;
    let removed = remove_from(tree, root, key)?;
    tree.len -= 1;
    if tree.pool[root].is_empty() {
        // Root shrink. Either the last key of the tree was deleted (leaf
        // root: the tree becomes empty) or a merge pulled the root's last
        // separator down (interior root: its single child holds everything).
        // Every leaf gets one level closer to the root at the same time, so
        // "all leaves at the same depth" still holds.
        let old_root = tree.pool.free(root);
        tree.root = old_root.children.first().copied();
        if tree.root.is_some() {
            tree.counters.root_shrinks += 1;
        }
    }
    Some(removed)
}

fn remove_from(tree: &mut BTree, id: NodeId, key: u64) -> Option<u64> {
    let node = &mut tree.pool[id];
    let i = lower_bound(&node.keys, key);
    let found = i < node.len() && node.keys[i] == key;

    if node.leaf {
        // Case 1: the key is in a leaf. Just take it out; if the leaf is now
        // too small, our caller (the parent) repairs it.
        return found.then(|| node.remove_entry(i).value);
    }
    let child = node.children[i];

    if found {
        // Case 2: the key is in an interior node. It separates children[i]
        // from children[i + 1], so it cannot simply vanish. Its in-order
        // predecessor (the largest key of children[i]) is the best
        // replacement: it is larger than everything else on the left and
        // smaller than everything on the right, and it sits in a leaf, where
        // removal is easy. This turns every interior delete into a leaf delete.
        let predecessor = remove_max(tree, child);
        let node = &mut tree.pool[id];
        node.keys[i] = predecessor.key;
        let removed = std::mem::replace(&mut node.values[i], predecessor.value);
        tree.counters.predecessor_swaps += 1;
        fix_underflow(tree, id, i);
        return Some(removed);
    }

    // Case 3: the key, if present, is in the subtree of children[i].
    let removed = remove_from(tree, child, key)?;
    fix_underflow(tree, id, i);
    Some(removed)
}

/// Remove and return the largest entry of the subtree: always the last entry
/// of the right-most leaf. Underflows are repaired on the way back up.
fn remove_max(tree: &mut BTree, id: NodeId) -> Entry {
    let node = &mut tree.pool[id];
    if node.leaf {
        return node.remove_entry(node.len() - 1);
    }
    let last = node.len(); // index of the right-most child
    let child = node.children[last];
    let entry = remove_max(tree, child);
    fix_underflow(tree, id, last);
    entry
}

/// If `parent.children[i]` has fewer than `min_keys` keys, repair it.
/// Afterwards every child of `parent` is legal again; `parent` itself may
/// have lost one key (merge), which its own parent checks next.
fn fix_underflow(tree: &mut BTree, parent: NodeId, i: usize) {
    let min = min_keys(tree.order);
    let siblings = &tree.pool[parent].children;
    if tree.pool[siblings[i]].len() >= min {
        return;
    }
    debug_assert_eq!(tree.pool[siblings[i]].len(), min - 1); // one delete removes one key

    // A sibling can lend a key only if it stays legal afterwards.
    if i > 0 && tree.pool[siblings[i - 1]].len() > min {
        borrow_from_left(tree, parent, i);
        tree.counters.borrows_left += 1;
    } else if i + 1 < siblings.len() && tree.pool[siblings[i + 1]].len() > min {
        borrow_from_right(tree, parent, i);
        tree.counters.borrows_right += 1;
    } else {
        // No sibling can spare a key. Merge with the left sibling if there is
        // one, otherwise with the right one. `at` is the separator between them.
        let at = if i > 0 { i - 1 } else { i };
        merge_children(tree, parent, at);
        tree.counters.merges += 1;
    }
}

/// Rotate one entry clockwise through the parent:
///
/// ```text
/// parent:        [.. S ..]                 [.. L ..]
/// left / child:  [a b L]  [x]      ->      [a b]  [S x]
/// ```
///
/// The separator S moves down to the front of the child, and the left
/// sibling's largest entry L moves up to take its place. A key cannot move
/// sideways directly: S lies between the two nodes in key order, so skipping
/// it would break the ordering invariant. In interior nodes the left
/// sibling's last child (keys between L and S) changes parent as well.
fn borrow_from_left(tree: &mut BTree, parent: NodeId, i: usize) {
    let child = tree.pool[parent].children[i];
    let left = tree.pool[parent].children[i - 1];
    let sep = i - 1;
    let up = {
        let node = &mut tree.pool[left];
        node.remove_entry(node.len() - 1)
    };
    let moved_child = tree.pool[left].children.pop(); // None in a leaf
    let node = &mut tree.pool[parent];
    let down = Entry {
        key: std::mem::replace(&mut node.keys[sep], up.key),
        value: std::mem::replace(&mut node.values[sep], up.value),
    };
    let node = &mut tree.pool[child];
    node.insert_entry(0, down.key, down.value);
    if let Some(grandchild) = moved_child {
        node.children.insert(0, grandchild);
    }
}

/// Mirror image: the separator moves down to the END of the child, the right
/// sibling's SMALLEST entry moves up, and the right sibling's first child
/// moves over.
fn borrow_from_right(tree: &mut BTree, parent: NodeId, i: usize) {
    let child = tree.pool[parent].children[i];
    let right = tree.pool[parent].children[i + 1];
    let sep = i;
    let node = &mut tree.pool[right];
    let up = node.remove_entry(0);
    let moved_child = if node.leaf {
        None
    } else {
        Some(node.children.remove(0))
    };
    let node = &mut tree.pool[parent];
    let down = Entry {
        key: std::mem::replace(&mut node.keys[sep], up.key),
        value: std::mem::replace(&mut node.values[sep], up.value),
    };
    let node = &mut tree.pool[child];
    node.insert_entry(node.len(), down.key, down.value);
    node.children.extend(moved_child);
}

/// Merge `children[at]`, the separator `keys[at]` and `children[at + 1]` into
/// `children[at]`, and free the right node.
///
/// ```text
/// parent:  [.. S ..]            [.. ..]
/// nodes:   [a]  [ ]      ->     [a S]
/// ```
///
/// It always fits: one node has min_keys - 1 keys, the other exactly
/// min_keys (otherwise we would have borrowed), plus the separator:
/// 2 * min_keys <= M - 1. The separator MUST come down: with one child fewer
/// the parent needs one key fewer.
fn merge_children(tree: &mut BTree, parent: NodeId, at: usize) {
    let node = &mut tree.pool[parent];
    let sep = node.remove_entry(at);
    let right = node.children.remove(at + 1);
    let left = node.children[at];
    // `free` hands the right node back by value: its vectors are appended to
    // the left node, and its slot is on the free list for the next split.
    let mut right = tree.pool.free(right);
    let node = &mut tree.pool[left];
    node.keys.push(sep.key);
    node.values.push(sep.value);
    node.keys.append(&mut right.keys);
    node.values.append(&mut right.values);
    node.children.append(&mut right.children);
    debug_assert!(node.len() <= max_keys(tree.order));
}
