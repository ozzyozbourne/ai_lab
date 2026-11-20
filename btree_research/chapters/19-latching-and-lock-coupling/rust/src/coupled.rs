//! Latch coupling ("crabbing"): one reader-writer latch per node.
//!
//! The rule for moving from a node to its child, for readers and writers:
//!
//! > latch the CHILD first, release the PARENT afterwards.
//!
//! For a moment the thread holds both, like a crab that puts one claw down
//! before lifting the other. The moment matters: with the parent latched,
//! nobody can split the child and move our key range out of it between
//! "read the child pointer" and "arrive at the child".
//!
//! Readers hold shared latches and so hold at most two at a time. A writer
//! holds exclusive latches and may release the ancestors only when the child
//! is SAFE: it has room for one more key, so it cannot split, so nothing
//! above it can change. A full child keeps its ancestors latched.
//!
//! Latch order: every thread acquires latches top-down along one path and
//! never waits for a latch above or beside one it holds. No cycle of waiting
//! threads can form, so there is no deadlock.
//!
//! In Rust a latch is released by dropping its guard. "Release the parent
//! after latching the child" is therefore an assignment: `guard = child`
//! drops the old guard after the new one exists.

use std::sync::atomic::Ordering;
use std::sync::{RwLockReadGuard, RwLockWriteGuard};

use crate::base_node::{Kind, Node, NodeId, OutOfNodes};
use crate::base_search::{child_index, lower_bound};
use crate::insert::{Held, insert_at_leaf};
use crate::tree::{Hook, Point, Tree, acquire, emit};

fn latch_shared<'a>(tree: &'a Tree, id: NodeId, hook: Hook<'_>) -> RwLockReadGuard<'a, Node> {
    let guard = acquire(
        hook,
        id,
        || tree.table.latch(id).try_read(),
        || tree.table.read(id),
    );
    emit(hook, Point::Latched, id);
    guard
}

fn latch_exclusive<'a>(tree: &'a Tree, id: NodeId, hook: Hook<'_>) -> RwLockWriteGuard<'a, Node> {
    let guard = acquire(
        hook,
        id,
        || tree.table.latch(id).try_write(),
        || tree.table.write(id),
    );
    emit(hook, Point::Latched, id);
    guard
}

/// Latches the root with `latch` and returns its id and the guard.
///
/// The root has no parent whose latch could protect the step "read the root
/// id, then latch that node". Between the two another thread may split the
/// root and publish a new one; the node we latched is then only the left
/// half of the tree. So: latch, then look at the root id AGAIN. If it still
/// names our node we own the real root, because the root id is only ever
/// changed by a thread holding the exclusive latch of the current root, and
/// we now hold a latch on that node. If not, let go and start over.
///
/// Latching a node that is no longer the root is harmless only because nodes
/// are never freed or reused (see table.rs).
fn latch_root<G>(tree: &Tree, hook: Hook<'_>, latch: impl Fn(NodeId) -> G) -> (NodeId, G) {
    loop {
        let id = tree.root();
        emit(hook, Point::RootLoaded, id);
        let guard = latch(id);
        if tree.root() == id {
            return (id, guard);
        }
        drop(guard);
        tree.stats.root_restarts.fetch_add(1, Ordering::Relaxed);
    }
}

pub fn get(tree: &Tree, key: u64, hook: Hook<'_>) -> Option<u64> {
    let (mut id, mut node) = latch_root(tree, hook, |id| latch_shared(tree, id, hook));
    loop {
        match &node.kind {
            Kind::Internal(internal) => {
                let child = internal.children[child_index(node.key_slice(), key)];
                let child_guard = latch_shared(tree, child, hook); // claw down on the child ...
                node = child_guard; //                                ... then lift it off the parent
                id = child;
            }
            Kind::Leaf(leaf) => {
                emit(hook, Point::AtLeaf, id);
                let i = lower_bound(node.key_slice(), key);
                return (i < node.len && node.keys[i] == key).then(|| leaf.values[i]);
            }
        }
    }
}

pub fn put(tree: &Tree, key: u64, value: u64, hook: Hook<'_>) -> Result<Option<u64>, OutOfNodes> {
    // `held`: the nodes we hold exclusive latches on, top-down. It is always
    // a contiguous piece of the path that ends at the current node.
    let mut held: Vec<Held<'_>> = Vec::new();
    // Whether held[0] is the root (then a split may still grow the tree).
    let mut top_is_root = true;

    held.push(latch_root(tree, hook, |id| latch_exclusive(tree, id, hook)));
    loop {
        let (_, node) = held.last().expect("never empty");
        let Kind::Internal(internal) = &node.kind else {
            break;
        };
        let child = internal.children[child_index(node.key_slice(), key)];
        let child_guard = latch_exclusive(tree, child, hook);
        // SAFE NODE RULE. A child with room for one more key will absorb
        // whatever comes up from below without splitting, so no ancestor can
        // change: release them all, top-down. (A leaf that already contains
        // the key would not split either, but we cannot know that before we
        // hold its latch, and afterwards the rule has already decided.)
        if child_guard.len < tree.max_keys() {
            held.clear(); // drops the guards front to back = top-down
            top_is_root = false;
        }
        held.push((child, child_guard));
    }
    emit(hook, Point::AtLeaf, held.last().expect("never empty").0);

    // Every node that can change is latched: held[0] has room (or is the
    // root), everything below it is full. On OutOfNodes nothing was changed.
    // The guards are dropped, top-down, when `held` goes out of scope.
    insert_at_leaf(tree, &mut held, top_is_root, key, value, hook)
}
