//! `Db`: the committed state of a copy-on-write B+tree and its readers.
//!
//!   store      page slab + free list + two metapage slots   (store.rs)
//!   current    the decoded winner of the two meta slots: the committed root
//!   snapshots  one entry per root that some reader still holds, refcounted
//!   pending    pages that a commit made unreachable from its root, while
//!   older roots can still reach them
//!
//! The life of a page:
//!
//! ```text
//! free --(written by a commit)--> live --(replaced or dropped by txn T)-->
//! pending(T) --(no snapshot older than T remains)--> free
//! ```
//!
//! THE reclamation rule: a page freed by transaction T is reachable from the
//! roots of transactions before T and from no root at or after T. A snapshot
//! with id S therefore needs it exactly when S < T, and the page may be
//! reused once every live snapshot has S >= T.

use crate::base_node::{MAX_ORDER, PageId};
use crate::meta::Meta;
use crate::read::{Range, View};
use crate::store::{PageStore, SlotState};
use crate::txn::{TxnError, WriteTxn};

/// A reader's handle on one committed root. It is a plain `Copy` value (four
/// numbers): what keeps the pages alive is the refcount in `Db::snapshots`,
/// which `Db::snapshot` / `Db::retain` raise and `Db::release` lowers.
///
/// It is deliberately NOT a guard with a `Drop` impl: a guard would have to
/// borrow the `Db`, and then no write transaction could start while a
/// snapshot exists, which is the opposite of what snapshots are for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Snapshot {
    pub id: u64,
    pub root: PageId,
    pub height: usize,
    pub count: u64,
}

impl Snapshot {
    pub fn view<'a>(&self, db: &'a Db) -> View<'a> {
        View {
            store: &db.store,
            dirty: None,
            root: self.root,
            height: self.height,
            count: self.count,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct SnapshotRef {
    pub snap: Snapshot,
    pub refs: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PendingFree {
    pub freed_by: u64,
    pub page: PageId,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub commits: u64,
    pub aborts: u64,
    /// Committed pages copied because a transaction wanted to change them.
    pub pages_copied: u64,
    /// Page ids taken from the free list / by growing the store.
    pub pages_reused: u64,
    pub pages_fresh: u64,
    /// Pages moved from pending to the free list.
    pub pages_released: u64,
}

/// No meta slot has a valid checksum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NoValidMeta;

#[derive(Debug)]
pub struct Db {
    /// M: maximum number of children of a node.
    order: usize,
    pub store: PageStore,
    pub current: Meta,
    /// Ascending by snapshot id (a new snapshot always has the newest id).
    pub snapshots: Vec<SnapshotRef>,
    /// Ascending by `freed_by` (commits append).
    pub pending: Vec<PendingFree>,
    /// True while a write transaction is open. The borrow checker already
    /// guarantees there is at most one (`begin` takes `&mut self`); the flag
    /// only tells `validate` that some page ids are reserved.
    pub writer_active: bool,
    pub stats: Stats,
    /// Rust's stand-in for Zig's allocation failure: the largest number of
    /// pages one transaction may hold in memory. `None` = unlimited.
    pub page_budget: Option<usize>,
}

impl Db {
    /// An empty database: transaction 0 committed an empty tree into meta
    /// slot 0; slot 1 has never been written and fails its checksum.
    pub fn new(order: usize) -> Db {
        assert!((3..=MAX_ORDER).contains(&order));
        let current = Meta {
            txn_id: 0,
            root: PageId::NIL,
            height: 0,
            count: 0,
            page_count: 0,
        };
        let mut store = PageStore::default();
        store.meta_slots[0] = current.encode();
        Db {
            order,
            store,
            current,
            snapshots: Vec::new(),
            pending: Vec::new(),
            writer_active: false,
            stats: Stats::default(),
            page_budget: None,
        }
    }

    pub fn max_keys(&self) -> usize {
        self.order - 1
    }

    /// ceil(M/2) - 1, for every node except the root.
    pub fn min_keys(&self) -> usize {
        self.order.div_ceil(2) - 1
    }

    pub fn len(&self) -> u64 {
        self.current.count
    }

    pub fn is_empty(&self) -> bool {
        self.current.count == 0
    }

    // ------------------------------------------------------------ reads

    /// The current committed tree. A reader that must survive commits takes
    /// a `snapshot` instead (the borrow checker insists: this view borrows
    /// the `Db`, so nothing can commit while it is alive).
    pub fn view(&self) -> View<'_> {
        let m = self.current;
        View {
            store: &self.store,
            dirty: None,
            root: m.root,
            height: m.height as usize,
            count: m.count,
        }
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        self.view().get(key)
    }

    pub fn range(&self, lo: u64, hi: u64) -> Range<'_> {
        self.view().range(lo, hi)
    }

    // -------------------------------------------------------- snapshots

    /// Pins the current root. Every page it reaches stays untouched until the
    /// matching `release`, no matter how many transactions commit meanwhile.
    pub fn snapshot(&mut self) -> Snapshot {
        let m = self.current;
        if let Some(last) = self.snapshots.last_mut()
            && last.snap.id == m.txn_id
        {
            last.refs += 1; // second reader of the same root
            return last.snap;
        }
        let snap = Snapshot {
            id: m.txn_id,
            root: m.root,
            height: m.height as usize,
            count: m.count,
        };
        self.snapshots.push(SnapshotRef { snap, refs: 1 });
        snap
    }

    /// One more reference to a root that is already pinned.
    pub fn retain(&mut self, snap: Snapshot) -> Snapshot {
        let i = self.find_snapshot(snap.id);
        self.snapshots[i].refs += 1;
        snap
    }

    /// Drops one reference. When the last reference to the OLDEST root goes,
    /// pages that were only waiting for it move to the free list. Returns the
    /// number of pages released.
    pub fn release(&mut self, snap: Snapshot) -> usize {
        let i = self.find_snapshot(snap.id);
        self.snapshots[i].refs -= 1;
        if self.snapshots[i].refs > 0 {
            return 0;
        }
        self.snapshots.remove(i);
        self.reclaim()
    }

    fn find_snapshot(&self, id: u64) -> usize {
        self.snapshots
            .iter()
            .position(|s| s.snap.id == id)
            .expect("releasing a snapshot that is not held")
    }

    /// Applies the reclamation rule.
    pub fn reclaim(&mut self) -> usize {
        let oldest = self.snapshots.first().map_or(u64::MAX, |s| s.snap.id);
        // `pending` is ascending by freed_by, so the releasable entries are a prefix.
        let n = self
            .pending
            .iter()
            .take_while(|p| p.freed_by <= oldest)
            .count();
        for p in self.pending.drain(..n) {
            self.store.release(p.page);
        }
        self.stats.pages_released += n as u64;
        n
    }

    // ----------------------------------------------------------- writes

    /// Opens the write transaction. Nothing it does is visible, or touches
    /// the store's pages, until `commit`. The transaction borrows the `Db`
    /// mutably, so a second writer is a compile error.
    pub fn begin(&mut self) -> WriteTxn<'_> {
        WriteTxn::new(self)
    }

    /// One-operation transactions. Returns the previous value, if any.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, TxnError> {
        let mut txn = self.begin();
        let old = txn.put(key, value)?; // on error `txn` is dropped = aborted
        txn.commit()?;
        Ok(old)
    }

    pub fn delete(&mut self, key: u64) -> Result<Option<u64>, TxnError> {
        let mut txn = self.begin();
        let old = txn.delete(key)?;
        txn.commit()?;
        Ok(old)
    }

    // ---------------------------------------------------------- restart

    /// What a restart does: forget all in-memory state (readers, pending
    /// list, free list), choose the meta slot by checksum and transaction id,
    /// and rebuild the free list as "every page the chosen root cannot
    /// reach". (A real engine stores the free list in the file instead of
    /// scanning; see the README.)
    pub fn reopen(&mut self) -> Result<(), NoValidMeta> {
        let m = Meta::pick(&self.store.meta_slots).ok_or(NoValidMeta)?;
        let mut reachable = vec![false; m.page_count as usize];

        self.current = m;
        self.snapshots.clear();
        self.pending.clear();
        // Pages past the chosen meta's page_count belong to a lost commit.
        self.store.slots.truncate(m.page_count as usize);
        self.store.free.clear();
        if !m.root.is_nil() {
            self.mark(m.root, &mut reachable);
        }
        for (i, r) in reachable.into_iter().enumerate() {
            self.store.slots[i].state = if r { SlotState::Live } else { SlotState::Free };
            if !r {
                self.store.free.push(PageId::from_index(i));
            }
        }
        Ok(())
    }

    fn mark(&self, id: PageId, reachable: &mut [bool]) {
        reachable[id.index()] = true;
        let n = &self.store.slots[id.index()].node;
        if n.is_leaf() {
            return;
        }
        for &child in n.child_slice() {
            self.mark(child, reachable);
        }
    }
}
