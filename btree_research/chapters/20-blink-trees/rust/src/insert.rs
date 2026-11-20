//! Insert, with a split done as TWO separate atomic steps (as in Postgres):
//!
//!   step 1  `half_split`     under the exclusive latch of the full node
//!                            only: create the right sibling, move the upper
//!                            half into it, set high keys and right links,
//!                            and set INCOMPLETE_SPLIT on the left node.
//!                            (Postgres: _bt_split, nbtinsert.c:1486-2109.)
//!   step 2  `insert_parent`  insert the downlink to the new sibling into the
//!                            parent and clear the flag, both under the
//!                            parent's exclusive latch.
//!                            (Postgres: _bt_insert_parent, nbtinsert.c:2127-2254.)
//!
//! After step 1 the tree is already correct for every reader: the moved keys
//! are one right link away. Step 2 only makes the path shorter. If step 2
//! never happens (the test hook `abandon_splits`, or the node table ran out
//! while the parent needed to split), the flag stays, and the next writer
//! that latches the node finishes the job before doing its own
//! (`finish_split`; Postgres: _bt_finish_split, nbtinsert.c:2269-2315).
//!
//! Latches held by a writer:
//!   going down   one at a time, like a reader (shared, exclusive on the leaf);
//!   going up     the child stays latched until its downlink is in the parent,
//!                so child + parent. If that parent is flagged, the writer
//!                first finishes the parent's split, which needs the
//!                grandparent, and if that one is flagged too, the node above
//!                it: one latch per level, bottom-up, for as long as each
//!                level's parent turns out to be flagged. The bound is the
//!                height of the tree, not a constant. LATCH_COUNTS
//! The order is always child before parent and never left-and-right at once;
//! the `meta` mutex comes last. With one global order there is no deadlock.
//!
//! In Rust a held latch is a guard value. "Release the latch" is `drop`, and
//! a function that takes a guard BY VALUE (as `insert_parent` does) has
//! taken over the duty to release it: every `return` does so automatically.

use std::ops::Deref;
use std::sync::atomic::Ordering;
use std::sync::{RwLockReadGuard, RwLockWriteGuard};

use crate::base_handle::{NodeId, OutOfNodes};
use crate::base_node::Kind;
use crate::base_search::{child_index, lower_bound};
use crate::blink::{BLinkTree, MAX_LEVELS, Page};

/// The nodes a writer came through on its way down: at[l] is the node of
/// level l (l >= 1) from which it followed a downlink. Like Postgres'
/// BTStack it is only a HINT for finding the parent later: by then that node
/// may have split, and the real parent may be further right.
struct Stack {
    at: [NodeId; MAX_LEVELS],
}

/// Result of step 2 for one split.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Finish {
    /// Downlink inserted (or new root built) and flag cleared.
    Done,
    /// A node was needed and the table is full. The split stays incomplete,
    /// which is a legal state of the tree.
    OutOfNodes,
}

/// A latch held in either mode (Zig: a node id plus a `bool`).
enum Latch<'a> {
    Shared(RwLockReadGuard<'a, Page>),
    Exclusive(RwLockWriteGuard<'a, Page>),
}

impl Deref for Latch<'_> {
    type Target = Page;
    fn deref(&self) -> &Page {
        match self {
            Latch::Shared(guard) => guard,
            Latch::Exclusive(guard) => guard,
        }
    }
}

impl Latch<'_> {
    fn is_exclusive(&self) -> bool {
        matches!(self, Latch::Exclusive(_))
    }
}

fn latch(tree: &BLinkTree, id: NodeId, exclusive: bool) -> Latch<'_> {
    if exclusive {
        Latch::Exclusive(tree.write(id))
    } else {
        Latch::Shared(tree.read(id))
    }
}

/// TEST HOOK for `put_from`: a callback that runs while ONE writer stands
/// still on its leaf. `abandon_splits` stops a split between its two steps;
/// this stops a writer between its way down and its way up, which is the
/// only moment at which its remembered parents can go stale.
///
/// It is called once, when the writer has found its leaf: the node with the
/// given id is latched exclusively (by the paused writer), its flag is
/// clear, and nothing has been inserted yet. No other latch is held. The
/// callback may run whole operations on the tree, as other threads would in
/// this gap. It must not touch the latched leaf: a `put` or `get` of a key
/// in that leaf's range would wait for the paused writer forever. That is
/// also why the leaf's page is passed in: the callback cannot latch it.
pub type Pause<'p> = &'p mut dyn FnMut(&BLinkTree, NodeId, &Page);

pub(crate) fn put(tree: &BLinkTree, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
    put_from(tree, tree.root_id(), key, value, None)
}

/// `put` with the two things a test must control to reach a stale writer
/// without threads:
///
///   `start`  the node the descent begins at, as if the writer had loaded
///            the root pointer at some earlier time. It must be the leftmost
///            node of a level (`level_head`): each of them was the root once.
///   `pause`  see `Pause`.
pub(crate) fn put_from(
    tree: &BLinkTree,
    start: NodeId,
    key: u64,
    value: u64,
    pause: Option<Pause<'_>>,
) -> Result<Option<u64>, OutOfNodes> {
    let mut stack = Stack {
        at: [NodeId::NIL; MAX_LEVELS],
    };

    // ---- Descend to the leaf whose key range contains `key`. -------------
    let mut id = start;
    let mut held = latch(tree, id, false);
    let mut leaf = loop {
        if held.level == 0 && !held.is_exclusive() {
            // We reached a leaf with a shared latch (only happens when the
            // root is a leaf). There is no upgrade: release, then take the
            // exclusive latch. Whatever happened in between is handled by
            // move_right below. Postgres: nbtsearch.c:190-199.
            drop(held);
            held = latch(tree, id, true);
        }
        (id, held) = move_right(tree, id, held, key, &stack)?;
        if held.level == 0 {
            match held {
                Latch::Exclusive(guard) => break guard,
                Latch::Shared(_) => unreachable!("leaves are latched exclusively"),
            }
        }

        stack.at[held.level as usize] = id;
        let child = held.node.internal().children[child_index(held.node.key_slice(), key)];
        // The children of a level-1 node are leaves: latch them exclusively
        // straight away. The level is known from the parent, so no peeking
        // at an unlatched node is needed.
        let child_is_leaf = held.level == 1;
        // Release the parent BEFORE latching the child: no lock coupling.
        // If the child splits in this gap, move_right repairs the path.
        drop(held);
        id = child;
        held = latch(tree, id, child_is_leaf);
    };

    // TEST HOOK: the writer knows its leaf and its (hinted) parents, and
    // the rest of the world moves on. Everything in `stack` may be out of
    // date when the callback returns; `insert_parent` must cope.
    if let Some(at_leaf) = pause {
        at_leaf(tree, id, &leaf);
    }

    // ---- Insert into the leaf (exclusively latched, flag clear). ----------
    let i = lower_bound(leaf.node.key_slice(), key);
    if i < leaf.node.len && leaf.node.keys[i] == key {
        let slot = &mut leaf.node.leaf_mut().values[i];
        return Ok(Some(std::mem::replace(slot, value)));
    }
    if leaf.node.len < tree.max_keys() {
        leaf.node.leaf_insert_at(i, key, value);
        tree.count.fetch_add(1, Ordering::Relaxed);
        return Ok(None);
    }

    // The leaf is full. Get the new node BEFORE changing anything, so that
    // a full table leaves the tree exactly as it was. (`?` drops `leaf`.)
    let right_id = tree.alloc_page(0)?;
    // The arrays have one spare slot (base_node::KEY_CAPACITY), so the leaf
    // may hold M keys for a moment; half_split cuts it in two right away.
    leaf.node.leaf_insert_at(i, key, value);
    tree.count.fetch_add(1, Ordering::Relaxed);
    half_split(tree, &mut leaf, right_id);

    if tree.abandon_splits.load(Ordering::Acquire) {
        // TEST HOOK: stop between the two steps. The key is in the tree and
        // every reader can find it; only the downlink is missing.
        return Ok(None);
    }
    // Step 2. Whether it succeeds or not, the put itself has succeeded.
    let _ = insert_parent(tree, id, leaf, &stack);
    Ok(None)
}

/// The writer's version of "move right" (Postgres: _bt_moveright with
/// forupdate, nbtsearch.c:243-324).
///
/// `held` is the latch on `start`. Returns the node on the same level whose
/// key range contains `key`, latched in the same mode, with its
/// INCOMPLETE_SPLIT flag clear. On error no latch is held.
fn move_right<'a>(
    tree: &'a BLinkTree,
    start: NodeId,
    mut held: Latch<'a>,
    key: u64,
    stack: &Stack,
) -> Result<(NodeId, Latch<'a>), OutOfNodes> {
    let mut id = start;
    loop {
        let exclusive = held.is_exclusive();
        if held.incomplete_split {
            // A writer never walks past a half-finished split: it finishes
            // it first. That needs the exclusive latch.
            let guard = match held {
                Latch::Exclusive(guard) => guard,
                Latch::Shared(guard) => {
                    drop(guard);
                    tree.write(id)
                }
            };
            // Re-check: between the two latches another writer may have
            // finished the split already.
            if guard.incomplete_split {
                if finish_split(tree, id, guard, stack) == Finish::OutOfNodes {
                    return Err(OutOfNodes);
                }
            } else {
                drop(guard);
            }
            // The latch is released. Take it again in our mode and look at
            // the node afresh.
            held = latch(tree, id, exclusive);
            continue;
        }
        if !held.is_beyond(key) {
            return Ok((id, held));
        }
        let next = held.right;
        drop(held);
        held = latch(tree, next, exclusive);
        tree.moves_right.fetch_add(1, Ordering::Relaxed);
        id = next;
    }
}

/// STEP 1 of a split. `left` is exclusively latched and holds M keys (one
/// too many); `right_id` is a fresh node nobody else can see yet.
///
/// When this returns, `left` and the new node together hold exactly what
/// `left` held before, the level's linked list has one more element, and
/// `left` is flagged. Readers are served correctly from this moment on.
fn half_split(tree: &BLinkTree, left: &mut Page, right_id: NodeId) {
    let mut right = tree.write(right_id);
    assert!(left.node.len == tree.order() && !left.incomplete_split);
    assert!(right.level == left.level);

    let len = left.node.len;
    let mid = len / 2;
    let separator;
    match &left.node.kind {
        Kind::Leaf(from) => {
            // floor(M/2) entries stay, ceil(M/2) move. The separator is a
            // COPY of the first moved key (copy-up, chapter 07).
            let moved = len - mid;
            right.node.keys[..moved].copy_from_slice(&left.node.keys[mid..len]);
            right.node.leaf_mut().values[..moved].copy_from_slice(&from.values[mid..len]);
            right.node.len = moved;
            separator = right.node.keys[0];
        }
        Kind::Internal(from) => {
            // The middle separator leaves the node (push-up, chapter 07).
            // It does not go into the parent yet: it becomes `left`'s high
            // key, and step 2 copies it from there.
            let moved = len - mid - 1;
            right.node.keys[..moved].copy_from_slice(&left.node.keys[mid + 1..len]);
            right.node.internal_mut().children[..moved + 1]
                .copy_from_slice(&from.children[mid + 1..len + 1]);
            right.node.len = moved;
            separator = left.node.keys[mid];
        }
    }
    left.node.len = mid;

    // The new node takes over the old upper bound and the old right link ...
    right.high_key = left.high_key;
    right.right = left.right;
    // ... and only then does `left` point at it. (Under the exclusive latch
    // nobody can observe the order of these writes; it is written this way
    // because it is the order a lock-free publication would need.)
    left.high_key = Some(separator);
    left.right = right_id;
    left.incomplete_split = true;
    tree.half_splits.fetch_add(1, Ordering::Relaxed);
}

/// Finishes a split that some earlier operation left half-done.
/// `left` is the exclusive latch on the flagged node; it is released.
fn finish_split(
    tree: &BLinkTree,
    left_id: NodeId,
    left: RwLockWriteGuard<'_, Page>,
    stack: &Stack,
) -> Finish {
    assert!(left.incomplete_split);
    let result = insert_parent(tree, left_id, left, stack);
    if result == Finish::Done {
        tree.finished_later.fetch_add(1, Ordering::Relaxed);
    }
    result
}

/// STEP 2 of a split: give the right half of `left_id` its downlink.
///
/// `left` is the exclusive latch on the flagged node. It is released before
/// returning, but not before the downlink is in place and the flag is
/// clear: both change under the parent's latch, so no thread can ever see a
/// downlink together with the flag, or neither.
fn insert_parent(
    tree: &BLinkTree,
    left_id: NodeId,
    mut left: RwLockWriteGuard<'_, Page>,
    stack: &Stack,
) -> Finish {
    assert!(left.incomplete_split);
    let level = left.level as usize;
    // The downlink is (left's high key, left's right link). Postgres builds
    // it the same way: nbtinsert.c:2206-2212.
    let separator = left.high_key.expect("a split node has a high key");
    let right_id = left.right;

    // ---- Where is the parent level? -----------------------------------
    let mut parent_id = stack.at[level + 1];
    if parent_id.is_nil() {
        // We did not come through a node of level+1: `left` was the root
        // when we started (or we started below the root, see `put_from`).
        // Is it still the root?
        let mut meta = tree.meta();
        if tree.root_id() == left_id {
            // Root split: build a new root above the two halves. This is
            // the only way the tree grows, and it is step 2 of the root's
            // split (Postgres: _bt_newlevel, nbtinsert.c:2489-2655).
            let Ok(new_root) = tree.alloc_page(level as u32 + 1) else {
                return Finish::OutOfNodes; // drops `meta`, then `left`
            };
            {
                let mut root = tree.write(new_root);
                root.node.internal_mut().children[0] = left_id;
                root.node.internal_insert_at(0, separator, right_id);
            }
            meta.level_head[level + 1] = new_root;
            meta.height = level + 2;
            left.incomplete_split = false;
            // Publishing the root last: a reader that still starts at the
            // old root finds everything by moving right.
            tree.root.store(new_root.index() as u32, Ordering::Release);
            tree.completed_splits.fetch_add(1, Ordering::Relaxed);
            return Finish::Done;
        }
        // Somebody else grew the tree meanwhile. Start at the leftmost node
        // of the parent level and walk right.
        parent_id = meta.level_head[level + 1];
        assert!(!parent_id.is_nil());
    }

    // ---- Find the node that holds the downlink to `left`. ---------------
    // Search by CHILD ID, not by key, moving right as needed (Postgres:
    // _bt_getstackbuf, nbtinsert.c:2348-2453). We hold `left`, then latch a
    // parent-level node: child before parent, the one allowed order.
    let (mut parent, slot) = loop {
        let parent = tree.write(parent_id);
        if parent.incomplete_split {
            // The flag can describe only ONE missing downlink. Inserting
            // into this node might split it again, so finish the pending
            // split first (Postgres: nbtinsert.c:2368-2372).
            if finish_split(tree, parent_id, parent, stack) == Finish::OutOfNodes {
                return Finish::OutOfNodes;
            }
            continue; // latch the same node again and look afresh
        }
        let found = parent.node.child_slice().iter().position(|&c| c == left_id);
        if let Some(slot) = found {
            break (parent, slot);
        }
        let next = parent.right;
        drop(parent);
        // The downlink exists (writers finish incomplete splits before they
        // go on), and downlinks only move right. Not finding it is a bug.
        assert!(
            !next.is_nil(),
            "B-link tree: downlink of a split node not found"
        );
        parent_id = next;
    };

    // ---- Insert the downlink; split the parent if it is full. ------------
    let mut parent_right = NodeId::NIL;
    if parent.node.len == tree.max_keys() {
        // Allocate before modifying, as in `put`.
        match tree.alloc_page(level as u32 + 1) {
            Ok(id) => parent_right = id,
            Err(OutOfNodes) => return Finish::OutOfNodes,
        }
    }
    // Child `slot` is `left`; the new sibling goes right after it.
    parent.node.internal_insert_at(slot, separator, right_id);
    left.incomplete_split = false;
    tree.completed_splits.fetch_add(1, Ordering::Relaxed);
    // The split of `left` is complete: let go of it before going further up.
    drop(left);

    if parent_right.is_nil() {
        return Finish::Done;
    }
    // The parent overflowed: the same two steps, one level up.
    half_split(tree, &mut parent, parent_right);
    if tree.abandon_splits.load(Ordering::Acquire) {
        return Finish::Done;
    }
    // The result of the parent's step 2 is not ours to report: the split of
    // `left`, which is what the caller asked about, is done.
    let _ = insert_parent(tree, parent_id, parent, stack);
    Finish::Done
}
