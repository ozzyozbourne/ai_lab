//! The index: a B+tree of (user key, tid) entries whose leaves are chained
//! by right links. Three things make it different from chapter 07:
//!
//!   * `delete` does not exist. Entries leave the index only as GARBAGE,
//!     after the row version they point at is dead to every snapshot
//!     (`make_room` here, VACUUM in db.rs).
//!   * Non-empty pages are never merged and nothing is ever borrowed: an
//!     entry stays on the page it was put on until it is removed or the page
//!     splits (then it may move RIGHT, never left).
//!   * An EMPTY leaf is deleted in two phases plus a delayed third step:
//!     live -> (mark_half_dead) half-dead -> (unlink) deleted -> (recycle) free
//!
//! Invariants (checked by validate.rs):
//!   1. Keys inside a page are strictly ascending; a child holds only keys
//!      inside the range its parent's separators give it.
//!   2. An internal page with k separators has k+1 children; k may be 0.
//!   3. All leaves reachable from the root are `Live` and at the same depth.
//!   4. Following `next` from `first_leaf` visits exactly those leaves in key
//!      order, plus any half-dead pages still waiting for phase 2.
//!   5. A deleted page is on the deleted queue, in stamp order, and nothing
//!      in the tree or the chain points at it.

use crate::base_arena::{Arena, NodeId, OutOfNodes};
use crate::base_node::{self as node, Kind, Node, PageState};
use crate::base_search as search;
use crate::store::Store;

/// Counts only. The demo uses them to say what an operation did; tests use
/// them to prove that a path was exercised.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub leaf_splits: usize,
    pub internal_splits: usize,
    /// Splits that did not happen because garbage was removed instead.
    pub splits_avoided: usize,
    /// Entries removed by each of the three collectors.
    pub simple_deleted: usize,
    pub bottom_up_deleted: usize,
    pub vacuum_deleted: usize,
    pub pages_half_dead: usize,
    pub pages_unlinked: usize,
    pub pages_recycled: usize,
    /// Splits that got a recycled page instead of growing the page array.
    pub pages_reused: usize,
}

struct Split {
    separator: u64,
    right: NodeId,
}

/// Which entries `remove_where` treats as garbage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Garbage {
    Hinted,
    DeadToAll,
}

#[derive(Debug)]
pub struct Index {
    /// M: maximum number of children of an internal page.
    pub order: usize,
    /// When a leaf is full and has no hinted entries, ask the version store
    /// about every entry on it before splitting (the "bottom-up" pass).
    pub bottom_up: bool,
    pub nodes: Arena<Node>,
    pub root: NodeId,
    /// Head of the leaf chain (may be a half-dead page between the phases).
    pub first_leaf: NodeId,
    pub height: usize,
    /// Number of entries, garbage included.
    pub count: usize,
    /// Deleted pages waiting for the horizon to pass their stamp (FIFO).
    pub deleted_head: NodeId,
    pub deleted_tail: NodeId,
    pub stats: Stats,
}

impl Index {
    pub fn new(order: usize) -> Index {
        Index::with_budget(order, usize::MAX)
    }

    /// An index that refuses to hold more than `max_pages` pages: the Rust
    /// stand-in for Zig's allocation failure.
    pub fn with_budget(order: usize, max_pages: usize) -> Index {
        assert!((3..=node::MAX_ORDER).contains(&order));
        Index {
            order,
            bottom_up: true,
            nodes: Arena::with_budget(max_pages),
            root: NodeId::NIL,
            first_leaf: NodeId::NIL,
            height: 0,
            count: 0,
            deleted_head: NodeId::NIL,
            deleted_tail: NodeId::NIL,
            stats: Stats::default(),
        }
    }

    pub fn max_keys(&self) -> usize {
        self.order - 1
    }

    /// The live leaf whose key range contains `index_key`; `NIL` if empty.
    pub fn find_leaf(&self, index_key: u64) -> NodeId {
        let mut id = self.root;
        if id.is_nil() {
            return NodeId::NIL;
        }
        loop {
            let n = self.nodes.get(id);
            match &n.kind {
                Kind::Leaf(_) => return id,
                Kind::Internal(internal) => {
                    id = internal.children[search::child_index(n.key_slice(), index_key)];
                }
            }
        }
    }

    // ------------------------------------------------------------ insert

    /// Worst case for one insert: every page on the path splits, plus a new
    /// root. Reserving first makes `insert_reserved` infallible, so the
    /// caller can allocate the row version in between without a rollback path.
    pub fn reserve_for_insert(&mut self) -> Result<(), OutOfNodes> {
        self.nodes.reserve(self.height + 1)
    }

    pub fn insert_reserved(&mut self, store: &mut Store, index_key: u64) {
        if self.root.is_nil() {
            self.root = self.nodes.alloc_reserved(Node::new_leaf());
            self.first_leaf = self.root;
            self.height = 1;
        }
        if let Some(s) = self.insert_into(store, self.root, index_key) {
            let mut new_root = Node::new_internal();
            new_root.internal_mut().children[0] = self.root;
            new_root.internal_insert_at(0, s.separator, s.right);
            self.root = self.alloc_page(new_root);
            self.height += 1;
        }
    }

    fn insert_into(&mut self, store: &mut Store, id: NodeId, index_key: u64) -> Option<Split> {
        if self.nodes.get(id).is_leaf() {
            // A full page: collect garbage first, split only as a last resort.
            if self.nodes.get(id).len == self.max_keys() {
                self.make_room(store, id);
            }
            let n = self.nodes.get_mut(id);
            let i = search::lower_bound(n.key_slice(), index_key);
            assert!(i == n.len || n.keys[i] != index_key); // the tid makes it unique
            n.leaf_insert_at(i, index_key);
            let overfull = n.len > self.max_keys();
            self.count += 1;
            return overfull.then(|| self.split_leaf(id));
        }
        let n = self.nodes.get(id);
        let i = search::child_index(n.key_slice(), index_key);
        let child = n.internal().children[i];
        let s = self.insert_into(store, child, index_key)?;
        let n = self.nodes.get_mut(id);
        n.internal_insert_at(i, s.separator, s.right);
        let overfull = n.len > self.max_keys();
        overfull.then(|| self.split_internal(id))
    }

    /// Garbage collection on ONE leaf, run by the insert that found it full.
    ///
    ///   simple deletion : drop the entries a scan has already hinted. Costs
    ///                     nothing extra: the hint bit is on the page.
    ///   bottom-up       : nothing hinted, so ask the version store about
    ///                     every entry on the page (one "heap visit" each).
    ///
    /// Either one is safe at any time, because an entry whose version is dead
    /// to all is by definition invisible to every reader, now and later.
    fn make_room(&mut self, store: &mut Store, id: NodeId) {
        self.stats.simple_deleted += self.remove_where(store, id, Garbage::Hinted);
        if self.nodes.get(id).len == self.max_keys() && self.bottom_up {
            self.stats.bottom_up_deleted += self.remove_where(store, id, Garbage::DeadToAll);
        }
        if self.nodes.get(id).len < self.max_keys() {
            self.stats.splits_avoided += 1;
        }
    }

    /// Removes the matching entries of a leaf and frees their row versions.
    /// Entry first, version second: the tid may be handed out again as soon
    /// as the version is freed, and no entry may still point at it then.
    pub fn remove_where(&mut self, store: &mut Store, id: NodeId, what: Garbage) -> usize {
        let n = self.nodes.get_mut(id);
        let mut removed = 0;
        for i in (0..n.len).rev() {
            let tid = node::tid_of(n.keys[i]);
            let garbage = match what {
                Garbage::Hinted => n.leaf().dead[i],
                Garbage::DeadToAll => store.dead_to_all(tid),
            };
            if !garbage {
                continue;
            }
            n.leaf_remove_at(i);
            store.versions.free(tid);
            removed += 1;
        }
        self.count -= removed;
        removed
    }

    /// Takes a page from the arena's free list (a recycled page) if there is
    /// one. Capacity was reserved by `reserve_for_insert`.
    fn alloc_page(&mut self, page: Node) -> NodeId {
        let slots_before = self.nodes.slot_count();
        let id = self.nodes.alloc_reserved(page);
        if self.nodes.slot_count() == slots_before {
            self.stats.pages_reused += 1;
        }
        id
    }

    /// Splits a leaf holding M entries. The upper half moves RIGHT into a
    /// new page; nothing ever moves left, which is what lets a scan that
    /// remembers a right link find everything it has not seen yet.
    fn split_leaf(&mut self, left_id: NodeId) -> Split {
        let right_id = self.alloc_page(Node::new_leaf());
        let (left, right) = self.nodes.pair_mut(left_id, right_id);
        let mid = left.len / 2;
        let moved = left.len - mid;
        right.keys[..moved].copy_from_slice(&left.keys[mid..left.len]);
        right.len = moved;
        left.len = mid;
        let (left_leaf, right_leaf) = (left.leaf_mut(), right.leaf_mut());
        right_leaf.dead[..moved].copy_from_slice(&left_leaf.dead[mid..mid + moved]);
        right_leaf.next = left_leaf.next;
        left_leaf.next = right_id;
        self.stats.leaf_splits += 1;
        Split { separator: right.keys[0], right: right_id }
    }

    fn split_internal(&mut self, left_id: NodeId) -> Split {
        let right_id = self.alloc_page(Node::new_internal());
        let (left, right) = self.nodes.pair_mut(left_id, right_id);
        let mid = left.len / 2;
        let separator = left.keys[mid];
        let moved = left.len - mid - 1;
        right.keys[..moved].copy_from_slice(&left.keys[mid + 1..left.len]);
        right.internal_mut().children[..moved + 1]
            .copy_from_slice(&left.internal().children[mid + 1..left.len + 1]);
        right.len = moved;
        left.len = mid;
        self.stats.internal_splits += 1;
        Split { separator, right: right_id }
    }

    // ----------------------------------------------------- page deletion

    /// Finds the parent slot that points at `target` by walking the internal
    /// pages. (An empty leaf has no key to search for. Postgres keeps a high
    /// key on every page and re-finds the parent by searching for that.)
    fn find_downlink(&self, id: NodeId, depth: usize, target: NodeId) -> Option<(NodeId, usize)> {
        let n = self.nodes.get(id);
        if n.is_leaf() {
            return None;
        }
        for (slot, &child) in n.child_slice().iter().enumerate() {
            if depth + 1 == self.height {
                if child == target {
                    return Some((id, slot));
                }
            } else if let Some(found) = self.find_downlink(child, depth + 1, target) {
                return Some(found);
            }
        }
        None
    }

    /// PHASE 1. Removes the parent's downlink to an empty leaf and marks the
    /// leaf half-dead. Returns false (and changes nothing) if the page may
    /// not be deleted:
    ///   * it is not an empty live leaf, or it is the root;
    ///   * it is the rightmost child of its parent. Its key range would have
    ///     to be given to a page under a DIFFERENT parent, which means
    ///     changing separators higher up. (Postgres allows one more case, a
    ///     parent with a single child, and deletes the parent too.)
    ///
    /// The surgery: slot i now points at the old child i+1, and separator i
    /// goes away. The target's key range is thereby handed to its right
    /// sibling without touching a single key in either leaf:
    ///
    /// ```text
    /// .. k(i-1) [T] k(i) [R] k(i+1) ..   ->   .. k(i-1) [R] k(i+1) ..
    /// ```
    pub fn mark_half_dead(&mut self, id: NodeId) -> bool {
        if !self.nodes.is_live(id) || id == self.root {
            return false;
        }
        let leaf = self.nodes.get(id);
        if !leaf.is_leaf() || leaf.leaf().state != PageState::Live || leaf.len != 0 {
            return false;
        }
        let Some((parent_id, slot)) = self.find_downlink(self.root, 1, id) else {
            return false;
        };
        let parent = self.nodes.get_mut(parent_id);
        if slot == parent.len {
            return false; // rightmost child
        }
        let children = &mut parent.internal_mut().children;
        children[slot] = children[slot + 1];
        parent.internal_remove_at(slot);
        self.nodes.get_mut(id).leaf_mut().state = PageState::HalfDead;
        self.stats.pages_half_dead += 1;
        true
    }

    /// The page whose right link points at `id`, or `NIL` if `id` is the
    /// head of the chain. Walks the chain (there are no left links).
    pub fn left_sibling(&self, id: NodeId) -> NodeId {
        let mut left = NodeId::NIL;
        let mut cur = self.first_leaf;
        while cur != id {
            left = cur;
            cur = self.nodes.get(cur).leaf().next;
        }
        left
    }

    /// PHASE 2. Takes a half-dead page out of the sibling chain and stamps it
    /// with a fresh epoch. `left` is its chain predecessor (`NIL` = head).
    ///
    /// The page keeps its OWN right link: a scan that read "next = this page"
    /// before the unlink may still arrive here, and escapes to the right.
    ///
    /// The stamp is a NEW tick of the counter, taken after the unlink. So:
    ///   snapshot <  stamp : taken before the unlink, may hold a link here;
    ///   snapshot >= stamp : taken after it, cannot have found a link here.
    pub fn unlink_half_dead(&mut self, store: &mut Store, left: NodeId, id: NodeId) {
        let leaf = self.nodes.get(id).leaf();
        assert_eq!(leaf.state, PageState::HalfDead);
        let next = leaf.next;
        if left.is_nil() {
            assert_eq!(self.first_leaf, id);
            self.first_leaf = next;
        } else {
            let left_leaf = self.nodes.get_mut(left).leaf_mut();
            assert_eq!(left_leaf.next, id);
            left_leaf.next = next;
        }
        let leaf = self.nodes.get_mut(id).leaf_mut();
        leaf.state = PageState::Deleted(store.tick());
        leaf.next_deleted = NodeId::NIL;
        if self.deleted_tail.is_nil() {
            self.deleted_head = id;
        } else {
            self.nodes.get_mut(self.deleted_tail).leaf_mut().next_deleted = id;
        }
        self.deleted_tail = id;
        self.stats.pages_unlinked += 1;
    }

    /// STEP 3. Frees every deleted page whose stamp the horizon has reached:
    /// no open snapshot is older than the unlink, so no scan can still be on
    /// its way to the page. Freed pages go to the arena's free list and are
    /// handed to the next split. Stamps only grow, so the queue is in stamp
    /// order and we can stop at the first page that must wait.
    pub fn recycle(&mut self, horizon: u64) -> usize {
        let mut freed = 0;
        while !self.deleted_head.is_nil() {
            let id = self.deleted_head;
            let leaf = self.nodes.get(id).leaf();
            let PageState::Deleted(stamp) = leaf.state else {
                unreachable!("only deleted pages are queued");
            };
            if stamp > horizon {
                break;
            }
            self.deleted_head = leaf.next_deleted;
            if self.deleted_head.is_nil() {
                self.deleted_tail = NodeId::NIL;
            }
            self.nodes.free(id);
            freed += 1;
        }
        self.stats.pages_recycled += freed;
        freed
    }

    /// The bug this chapter is about, on purpose: recycle without asking who
    /// might still be looking. Only tests and the demo call it.
    pub fn recycle_ignoring_snapshots(&mut self) -> usize {
        self.recycle(u64::MAX)
    }
}
