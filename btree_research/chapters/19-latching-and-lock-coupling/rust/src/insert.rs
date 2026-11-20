//! The part of `put` that is the same under every protocol: what happens
//! AFTER the descent, once the caller owns the nodes it may have to change.
//!
//! The caller passes `path`: exclusive guards on the nodes from some ancestor
//! down to the leaf, in top-down order.
//!   * plain.rs passes the whole root-to-leaf path (the tree-wide lock covers
//!     everything; the guards are uncontended and only satisfy the types);
//!   * coupled.rs passes exactly the nodes it still holds exclusive latches
//!     on, which the "safe node" rule guarantees are all that can change.
//!
//! Splits are the two of chapter 07: a leaf split COPIES its separator up, an
//! internal split PUSHES it up. The left half keeps the old handle.

use std::sync::RwLockWriteGuard;
use std::sync::atomic::Ordering;

use crate::base_node::{Node, NodeId, OutOfNodes};
use crate::base_search::{child_index, lower_bound};
use crate::tree::{Hook, Point, Tree, emit, fresh_node};

pub type Held<'a> = (NodeId, RwLockWriteGuard<'a, Node>);

/// `top_is_root`: path[0] is the root, so a split of path[0] grows the tree.
pub fn insert_at_leaf(
    tree: &Tree,
    path: &mut [Held<'_>],
    top_is_root: bool,
    key: u64,
    value: u64,
    hook: Hook<'_>,
) -> Result<Option<u64>, OutOfNodes> {
    let (_, leaf) = path.last_mut().expect("the path ends at a leaf");
    let at = lower_bound(leaf.key_slice(), key);
    if at < leaf.len && leaf.keys[at] == key {
        return Ok(Some(std::mem::replace(
            &mut leaf.leaf_mut().values[at],
            value,
        )));
    }

    // How many nodes will split? Exactly the run of FULL nodes at the bottom
    // of the path: a full leaf splits and hands a separator to its parent,
    // which splits if it is full too, and so on up to the first node with
    // room. If the run reaches the root, one more node becomes the new root.
    let max_keys = tree.max_keys();
    let splits = path
        .iter()
        .rev()
        .take_while(|(_, node)| node.len == max_keys)
        .count();
    let grows = splits == path.len();
    // The caller must own the node that absorbs the last separator.
    assert!(!grows || top_is_root);

    // Take every new node NOW, before the first change. If the table is full
    // the tree has not been touched and the caller just drops its guards.
    let first = tree.table.reserve((splits + usize::from(grows)) as u32)?;
    let mut next_id = first.index();

    path.last_mut().unwrap().1.leaf_insert_at(at, key, value);
    tree.count.fetch_add(1, Ordering::Relaxed);

    let mut level = path.len();
    while level > 0 && path[level - 1].1.len > max_keys {
        level -= 1;
        let (above, rest) = path.split_at_mut(level);
        let (left_id, left) = &mut rest[0];
        let right_id = NodeId::from_index(next_id);
        next_id += 1;
        let separator = if left.is_leaf() {
            split_leaf(tree, left, right_id)
        } else {
            split_internal(tree, left, right_id)
        };

        if let Some((_, parent)) = above.last_mut() {
            let i = child_index(parent.key_slice(), separator);
            parent.internal_insert_at(i, separator, right_id);
        } else {
            // The root itself split: grow a new root above the two halves.
            let root_id = NodeId::from_index(next_id);
            let mut new_root = Node::new_internal();
            new_root.internal_mut().children[0] = *left_id;
            new_root.internal_insert_at(0, separator, right_id);
            drop(fresh_node(tree, root_id, new_root));
            // PUBLISH LAST. Nobody holds a latch on the new root, and nobody
            // needs one while it is unreachable. The store below makes it
            // reachable for every thread at once, so the node must have been
            // written before it. Stored earlier, a reader could latch the
            // new root (its latch is free) and read the empty placeholder
            // leaf that the table was filled with.
            emit(hook, Point::RootBuilt, root_id);
            // Under latch coupling a thread that read the OLD root id and is
            // waiting for its latch will notice this store when it gets the
            // latch, and start again (coupled::latch_root).
            tree.set_root(root_id);
        }
    }
    Ok(None)
}

/// Splits a leaf holding M entries (one too many). floor(M/2) stay, the rest
/// move. COPY-UP: the first key of the new leaf is returned AND stays in it.
fn split_leaf(tree: &Tree, left: &mut Node, right_id: NodeId) -> u64 {
    let mut right = Node::new_leaf();
    let mid = left.len / 2;
    let moved = left.len - mid;
    right.keys[..moved].copy_from_slice(&left.keys[mid..left.len]);
    right.leaf_mut().values[..moved].copy_from_slice(&left.leaf().values[mid..left.len]);
    right.len = moved;
    left.len = mid;
    // Chain: left -> old_next becomes left -> right -> old_next. Only `left`
    // and the new node are written; the old next leaf is not touched, which
    // is why the chain is singly linked in this chapter.
    right.leaf_mut().next = left.leaf().next;
    left.leaf_mut().next = right_id;
    tree.stats.leaf_splits.fetch_add(1, Ordering::Relaxed);
    let separator = right.keys[0];
    drop(fresh_node(tree, right_id, right));
    separator
}

/// Splits an internal node holding M separators and M+1 children.
/// PUSH-UP: the middle separator is returned and kept in neither half.
fn split_internal(tree: &Tree, left: &mut Node, right_id: NodeId) -> u64 {
    let mut right = Node::new_internal();
    let mid = left.len / 2;
    let separator = left.keys[mid];
    let moved = left.len - mid - 1;
    right.keys[..moved].copy_from_slice(&left.keys[mid + 1..left.len]);
    right.internal_mut().children[..moved + 1]
        .copy_from_slice(&left.internal().children[mid + 1..left.len + 1]);
    right.len = moved;
    left.len = mid;
    tree.stats.internal_splits.fetch_add(1, Ordering::Relaxed);
    drop(fresh_node(tree, right_id, right));
    separator
}
