//! The B-link tree object (Lehman and Yao): the node table, the latches, and
//! the public method names. The algorithms live in one file each:
//!
//!   search.rs    descent that holds ONE latch at a time and moves right
//!   insert.rs    put; a split as two separate atomic steps
//!   validate.rs  every invariant as code, including half-finished splits
//!   dump.rs      text rendering
//!
//! What a B-link tree adds to the B+tree of chapter 07:
//!
//!   high key    an upper bound on the keys a node may hold. Here it is
//!               EXCLUSIVE: a node holds keys < high_key. `None` = +infinity.
//!   right link  the handle of the next node on the SAME level (leaf or
//!               internal). `NIL` on the rightmost node of a level.
//!
//! Invariants (checked by `validate`):
//!   1. Every level is a singly linked list in key order: the high key of a
//!      node is the lower bound of its right sibling.
//!   2. A node has a high key if and only if it has a right link.
//!   3. A node is reachable from its parent level by a DOWNLINK, except the
//!      right half of a split whose second step has not happened yet. That
//!      case is marked by `incomplete_split` on its LEFT sibling.
//!   4. Keys only ever move to the right, into a NEW node. A node's id, its
//!      level and its lower bound never change; its high key only decreases.
//!
//! Invariant 4 is the whole trick. A reader that holds a stale handle (it
//! read the parent before a split) lands on a node that is still the leftmost
//! place the key could be, compares the key with the high key, and follows
//! right links until the range fits. No lock coupling is needed.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};

use crate::base_handle::{NodeId, OutOfNodes};
use crate::base_node::{MAX_ORDER, Node};
use crate::insert::Pause;
use crate::search::{self, Lookup, Mode};
use crate::validate::{self, Violation};

/// More levels than any tree that fits in a u32-indexed table can have.
pub const MAX_LEVELS: usize = 32;

/// Everything in a node that the latch protects.
#[derive(Debug, Clone)]
pub struct Page {
    /// Keys plus values (leaf) or children (internal): chapter 07's node.
    pub node: Node,
    /// 0 for a leaf, 1 for the parents of leaves, ... Never changes.
    pub level: u32,
    /// Exclusive upper bound of this node's key range; None = +infinity.
    pub high_key: Option<u64>,
    /// Next node on the same level, or `NIL`.
    pub right: NodeId,
    /// Step 1 of a split happened here and step 2 has not: the node behind
    /// `right` has no downlink in the parent level yet (Postgres:
    /// BTP_INCOMPLETE_SPLIT, set on the left half).
    pub incomplete_split: bool,
}

impl Page {
    pub fn new(level: u32) -> Page {
        Page {
            node: if level == 0 {
                Node::new_leaf()
            } else {
                Node::new_internal()
            },
            level,
            high_key: None,
            right: NodeId::NIL,
            incomplete_split: false,
        }
    }

    /// True when `key` belongs to a node further right. This single
    /// comparison is how a concurrent split is detected.
    pub fn is_beyond(&self, key: u64) -> bool {
        self.high_key.is_some_and(|hk| key >= hk)
    }
}

/// Plain copy of the counters (see `BLinkTree::stats`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    /// Step 1 performed: sibling created and linked, flag set.
    pub half_splits: u64,
    /// Step 2 performed: downlink inserted (or new root built), flag cleared.
    pub completed_splits: u64,
    /// ... of which by a LATER writer that met the flag, not by the splitter.
    pub finished_later: u64,
    /// Right links followed by searches and by descending writers.
    pub moves_right: u64,
}

/// What the `meta` mutex guards (Zig: the fields `height` and `level_head`).
#[derive(Debug, Clone)]
pub struct Meta {
    /// Number of levels; 1 when the root is a leaf.
    pub height: usize,
    /// level_head[l] = leftmost node of level l. Set once, when the level is
    /// created by a root split, and never changed afterwards: the left half
    /// of a split keeps its id, so the leftmost node of a level is forever
    /// the node that was the root when the level was born.
    pub level_head: [NodeId; MAX_LEVELS],
}

pub struct BLinkTree {
    /// M: maximum number of children of an internal node (Knuth's order).
    pub(crate) order: usize,
    /// The node table: one latch per node, with the page inside it.
    /// Allocated once, never grown, never moved. A boxed slice (not a `Vec`)
    /// says so in the type: there is no `push`.
    pub(crate) slots: Box<[RwLock<Page>]>,
    /// Number of slots handed out so far. Nodes are never freed (no delete).
    pub(crate) allocated: AtomicU32,
    /// The "metapage": where a descent starts. Readers load it without any
    /// lock. It may be stale by the time they use it, which is fine, because
    /// an old root is still a node of the tree and has a right link.
    pub(crate) root: AtomicU32,
    /// Protects root changes, `height` and `level_head`. Taken after every
    /// latch on a node that other threads can reach, so it cannot be part of
    /// a deadlock cycle. The one latch taken while it is held is that of a
    /// brand-new root (`alloc_page`, then filling it in `insert_parent`):
    /// no other thread knows that node yet, so that latch never waits.
    pub(crate) meta: Mutex<Meta>,
    /// Number of entries.
    pub(crate) count: AtomicU64,
    /// TEST HOOK. While true, every split stops after step 1, as if the
    /// writer had died between the two atomic steps.
    pub(crate) abandon_splits: AtomicBool,

    pub(crate) half_splits: AtomicU64,
    pub(crate) completed_splits: AtomicU64,
    pub(crate) finished_later: AtomicU64,
    pub(crate) moves_right: AtomicU64,
}

impl BLinkTree {
    /// Allocates the whole node table (`capacity` nodes) and creates the
    /// root as an empty leaf. This is the only allocation the tree ever
    /// makes; `put` fails only with `OutOfNodes`, when the table is used up.
    /// The capacity plays the role of chapter 07's node budget.
    pub fn new(order: usize, capacity: usize) -> BLinkTree {
        assert!((3..=MAX_ORDER).contains(&order));
        assert!(capacity >= 1 && capacity < u32::MAX as usize);
        let mut level_head = [NodeId::NIL; MAX_LEVELS];
        level_head[0] = NodeId::from_index(0);
        BLinkTree {
            order,
            slots: (0..capacity).map(|_| RwLock::new(Page::new(0))).collect(),
            allocated: AtomicU32::new(1), // slot 0: the root leaf
            root: AtomicU32::new(0),
            meta: Mutex::new(Meta {
                height: 1,
                level_head,
            }),
            count: AtomicU64::new(0),
            abandon_splits: AtomicBool::new(false),
            half_splits: AtomicU64::new(0),
            completed_splits: AtomicU64::new(0),
            finished_later: AtomicU64::new(0),
            moves_right: AtomicU64::new(0),
        }
    }

    pub fn order(&self) -> usize {
        self.order
    }

    /// A node holds at most M-1 keys.
    pub fn max_keys(&self) -> usize {
        self.order - 1
    }

    /// Smallest node a split can produce: ceil(M/2)-1 keys.
    pub fn min_keys(&self) -> usize {
        self.order.div_ceil(2) - 1
    }

    pub fn len(&self) -> u64 {
        self.count.load(Ordering::Relaxed)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn root_id(&self) -> NodeId {
        NodeId::from_index(self.root.load(Ordering::Acquire) as usize)
    }

    pub fn node_count(&self) -> usize {
        self.allocated.load(Ordering::Relaxed) as usize
    }

    pub fn capacity(&self) -> usize {
        self.slots.len()
    }

    pub fn height(&self) -> usize {
        self.meta().height
    }

    /// A copy of the fields behind the `meta` mutex.
    pub fn meta_snapshot(&self) -> Meta {
        self.meta().clone()
    }

    pub fn stats(&self) -> Stats {
        Stats {
            half_splits: self.half_splits.load(Ordering::Relaxed),
            completed_splits: self.completed_splits.load(Ordering::Relaxed),
            finished_later: self.finished_later.load(Ordering::Relaxed),
            moves_right: self.moves_right.load(Ordering::Relaxed),
        }
    }

    /// Test hook: see `abandon_splits`.
    pub fn set_abandon_splits(&self, on: bool) {
        self.abandon_splits.store(on, Ordering::Release);
    }

    // ------------------------------------------------------------ nodes

    /// Hands out the next unused slot as an empty node of `level`.
    ///
    /// No other thread can know the new id until the caller stores it in a
    /// right link or a child slot, and it does that while holding the
    /// exclusive latch of the node it stores it in. Zig therefore writes the
    /// new page without latching it; safe Rust has no way to say "I am the
    /// only one who knows this index", so it takes the (uncontended) latch.
    pub(crate) fn alloc_page(&self, level: u32) -> Result<NodeId, OutOfNodes> {
        // Compare-and-swap instead of fetch_add, so that a failed allocation
        // never pushes the counter past the table size.
        let capacity = self.slots.len() as u32;
        let used = self
            .allocated
            .fetch_update(Ordering::AcqRel, Ordering::Relaxed, |used| {
                (used < capacity).then_some(used + 1)
            })
            .map_err(|_| OutOfNodes)?;
        let id = NodeId::from_index(used as usize);
        *self.write(id) = Page::new(level);
        Ok(id)
    }

    /// Shared latch on a node. A poisoned latch means another thread
    /// panicked inside the tree; there is nothing sensible left to do.
    pub fn read(&self, id: NodeId) -> RwLockReadGuard<'_, Page> {
        self.slots[id.index()].read().expect("latch poisoned")
    }

    /// Exclusive latch on a node.
    pub fn write(&self, id: NodeId) -> RwLockWriteGuard<'_, Page> {
        self.slots[id.index()].write().expect("latch poisoned")
    }

    pub(crate) fn meta(&self) -> MutexGuard<'_, Meta> {
        self.meta.lock().expect("meta mutex poisoned")
    }

    // ------------------------------------------------------- operations

    /// Value stored under `key`, or None. Holds one shared latch at a time.
    pub fn get(&self, key: u64) -> Option<u64> {
        search::lookup(self, key, Mode::FollowRightLinks).value
    }

    /// Like `get`, with a report of the path, and optionally with move-right
    /// switched off to show what goes wrong without it.
    pub fn lookup(&self, key: u64, mode: Mode) -> Lookup {
        search::lookup(self, key, mode)
    }

    /// Inserts or overwrites. Returns the previous value if the key existed.
    /// Safe to call from several threads at once: note `&self`, not
    /// `&mut self`. On `Err(OutOfNodes)` the key was not inserted and no
    /// value was changed. A put that needs no node can fail this way too: a
    /// writer must finish every half-finished split on its path first, and
    /// that needs a node if the parent is full or the split is the root's.
    pub fn put(&self, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
        crate::insert::put(self, key, value)
    }

    /// TEST HOOK: `put` that starts its descent at `start` (the leftmost node
    /// of a level, i.e. a former root) and can be paused on its leaf or
    /// before it publishes a new root. See `insert::put_from`.
    pub fn put_from(
        &self,
        start: NodeId,
        key: u64,
        value: u64,
        pause: Pause<'_>,
    ) -> Result<Option<u64>, OutOfNodes> {
        crate::insert::put_from(self, start, key, value, pause)
    }

    /// Checks every invariant. Meaningful only while no other thread
    /// modifies the tree.
    pub fn validate(&self) -> Result<(), Violation> {
        validate::validate(self)
    }

    /// Number of nodes whose `incomplete_split` flag is set.
    pub fn incomplete_splits(&self) -> usize {
        validate::incomplete_splits(self)
    }
}
