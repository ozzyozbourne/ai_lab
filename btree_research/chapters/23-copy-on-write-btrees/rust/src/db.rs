//! `Db`: the committed state of a copy-on-write B+tree and its readers.
//!
//!   store      page slab + free list + two metapage slots   (store.rs)
//!   current    the decoded winner of the two meta slots: the committed root
//!   previous   the root in the OTHER meta slot: where a restart lands if the
//!   newest slot cannot be read
//!   snapshots  one entry per root that some reader still holds, refcounted
//!   pending    pages that a commit made unreachable from its root, while
//!   older roots can still reach them
//!
//! The life of a page:
//!
//! ```text
//! free --(written by a commit)--> live --(replaced or dropped by txn T)-->
//! pending(T) --(no protected root older than T remains)--> free
//! ```
//!
//! THE reclamation rule: a page freed by transaction T is reachable from the
//! roots of transactions before T and from no root at or after T. A root with
//! id R therefore needs it exactly when R < T, and the page may be reused
//! once every PROTECTED root has R >= T. Two kinds of root are protected:
//!
//!   * every snapshot, for as long as a reader holds it;
//!   * `previous`, the root of the commit before the current one, for as
//!     long as its meta slot can still be chosen by a restart. Its slot is
//!     overwritten by the NEXT commit, so pages freed by transaction T become
//!     reusable when T+1 has committed, and not before.
//!
//! The second line is what makes two meta slots worth having. At every
//! moment, also in the middle of a commit, the trees of BOTH slots are
//! complete: whichever slot a restart is able to read names a whole tree.

use crate::base_node::{MAX_ORDER, PageId};
use crate::meta::Meta;
use crate::read::{MAX_HEIGHT, Range, View};
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReopenError {
    /// No meta slot has a valid checksum.
    NoValidMeta,
    /// The chosen slot is intact but the tree it names is not all there.
    CorruptTree,
}

#[derive(Debug)]
pub struct Db {
    /// M: maximum number of children of a node.
    order: usize,
    pub store: PageStore,
    pub current: Meta,
    /// The committed root one commit back, as recorded in the other meta
    /// slot. `None` when that slot holds nothing usable (a new database, or
    /// after a restart that found it unreadable). `reclaim` treats it like a
    /// snapshot that nobody can release early.
    pub previous: Option<Meta>,
    /// Fault injection for the tests and the demo: when set, the next commit
    /// "loses power" after this many device writes (one per page, then one
    /// per byte of the meta slot) and returns `TxnError::Crashed`.
    pub crash_after: Option<usize>,
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
            previous: None,
            crash_after: None,
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
        // The oldest root that must stay complete: the oldest snapshot, or
        // the previous committed root, whichever is older.
        let mut oldest = self.snapshots.first().map_or(u64::MAX, |s| s.snap.id);
        if let Some(p) = self.previous {
            oldest = oldest.min(p.txn_id);
        }
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

    /// What a restart does. Only the "file" is trusted: the two meta slots
    /// and the pages (content and `written_by`). Everything else (readers,
    /// pending list, free list, slot states) is rebuilt:
    ///
    ///   1. choose the meta slot by checksum and transaction id;
    ///   2. walk its tree and CHECK it while walking (`tree_is_complete`);
    ///   3. if the other slot holds an older commit with a complete tree, it
    ///      stays the fallback: the pages only it reaches go back on the
    ///      pending list;
    ///   4. every page neither root reaches is free.
    ///
    /// (A real engine stores the free list in the file instead of scanning;
    /// see the README.) On error nothing has been changed.
    ///
    /// `NoValidMeta`: neither slot has a valid checksum.
    /// `CorruptTree`: the chosen slot has a valid checksum but its tree is
    /// not all there. The reclamation rule guarantees this cannot happen
    /// after a crash, a torn meta write or one unreadable slot, so it means
    /// damage this design does not defend against (a lost page write, a
    /// forged slot), and it is reported instead of guessed around.
    pub fn reopen(&mut self) -> Result<(), ReopenError> {
        let slots = &self.store.meta_slots;
        let m = Meta::pick(slots).ok_or(ReopenError::NoValidMeta)?;
        let n = m.page_count as usize;
        if n > self.store.page_count() {
            return Err(ReopenError::CorruptTree);
        }
        let in_current = self
            .tree_is_complete(m, n)
            .ok_or(ReopenError::CorruptTree)?;

        // The other slot is a fallback only if its tree is whole as well.
        let mut previous = None;
        let mut in_previous = vec![false; n];
        if let Some(p) = Meta::fallback(slots)
            && p.page_count as usize <= n
            && let Some(marks) = self.tree_is_complete(p, n)
        {
            previous = Some(p);
            in_previous = marks;
        }

        self.current = m;
        self.previous = previous;
        self.crash_after = None;
        self.writer_active = false;
        self.snapshots.clear();
        self.pending.clear();
        // Pages past the chosen meta's page_count belong to a lost commit.
        self.store.slots.truncate(n);
        self.store.free.clear();
        for i in 0..n {
            let (c, p) = (in_current[i], in_previous[i]);
            self.store.slots[i].state = if c || p {
                SlotState::Live
            } else {
                SlotState::Free
            };
            if c {
                continue;
            }
            let page = PageId::from_index(i);
            if p {
                // Replaced by the current commit; released when the next
                // commit overwrites the fallback slot.
                self.pending.push(PendingFree {
                    freed_by: m.txn_id,
                    page,
                });
            } else {
                self.store.free.push(page);
            }
        }
        Ok(())
    }

    /// Walks the tree a meta slot names and returns the marks of its pages
    /// (one per page of a store of `n` pages), or `None` if the tree is not
    /// all there. A valid checksum only says the 32 bytes of the slot are
    /// intact; it says nothing about the pages. So the walk trusts nothing:
    /// every page id is range-checked, a page may be reached only once (no
    /// cycles), it must have been written by a transaction no later than the
    /// slot's, and `height` and `count` must come out right. The recursion
    /// is at most `MAX_HEIGHT` deep whatever the input.
    fn tree_is_complete(&self, m: Meta, n: usize) -> Option<Vec<bool>> {
        let mut marks = vec![false; n];
        if m.root.is_nil() {
            return (m.height == 0 && m.count == 0).then_some(marks);
        }
        if m.height == 0 || m.height as usize > MAX_HEIGHT {
            return None;
        }
        let mut entries = 0;
        let ok = self.mark_checked(m, m.root, 1, &mut marks, &mut entries) && entries == m.count;
        ok.then_some(marks)
    }

    fn mark_checked(
        &self,
        m: Meta,
        id: PageId,
        depth: usize,
        marks: &mut [bool],
        entries: &mut u64,
    ) -> bool {
        if id.is_nil() || id.index() >= marks.len() || marks[id.index()] {
            return false;
        }
        marks[id.index()] = true;
        let slot = &self.store.slots[id.index()];
        // 0 = never written.
        if slot.written_by == 0 || slot.written_by > m.txn_id {
            return false;
        }
        let node = &slot.node;
        if node.len > self.max_keys() {
            return false;
        }
        if node.is_leaf() {
            *entries += node.len as u64;
            return depth == m.height as usize;
        }
        depth < m.height as usize
            && node
                .child_slice()
                .iter()
                .all(|&child| self.mark_checked(m, child, depth + 1, marks, entries))
    }
}
