//! `validate`: every invariant of the copy-on-write tree as code.
//!
//! Per root (the committed root and every snapshot root), the B+tree
//! invariants of chapter 07 minus the leaf chain:
//!   1. keys in a node strictly ascending, within the bounds of the separators
//!      above; 2. at most M-1 keys, at least ceil(M/2)-1 except in the root;
//!   3. all leaves at depth `height`; 4. `count` entries in total.
//!
//! Across roots, the copy-on-write invariants:
//!   5. Within one root a page is reached exactly once: each tree is a tree.
//!      (Two DIFFERENT roots sharing a page is the whole point and is fine.)
//!   6. A page reachable from the root of transaction R was written by a
//!      transaction <= R. So no page was modified after a root that still
//!      reaches it was published; in particular no page shared by two live
//!      roots was ever modified.
//!   7. The free list, the pending list and the set reachable from the
//!      current root are pairwise disjoint and together cover every page:
//!      nothing reachable is writable, nothing is leaked.
//!   8. A page that only a snapshot reaches is pending, freed by a LATER
//!      transaction than the snapshot (so the reclamation rule protects it).
//!   9. `current` is what the two meta slots decode to.

use crate::base_node::{Kind, PageId};
use crate::db::Db;
use crate::meta::Meta;
use crate::store::SlotState;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Violation {
    /// No meta slot has a valid checksum, or `current` is not the winner.
    BadMeta,
    /// root / height / count disagree about emptiness.
    BadRoot,
    /// A child page id is nil or out of range.
    DanglingChild,
    NodeOverfull,
    NodeUnderfull,
    KeysNotSorted,
    KeyOutOfBounds,
    UnevenLeafDepth,
    WrongCount,
    /// Invariant 5.
    PageReachedTwice,
    /// Invariant 6.
    LivePageModified,
    /// Invariant 7: a root reaches a page that is on the free list.
    ReachablePageIsFree,
    /// Invariant 7: duplicates, bad ids or wrong slot state in the free list.
    FreeListCorrupt,
    /// Invariant 7: bad pending entry, or a pending page the current root reaches.
    PendingCorrupt,
    /// Invariant 7: a page that is neither reachable, pending nor free.
    PageLeak,
    /// Invariant 8.
    SnapshotPageUnprotected,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Class {
    Unknown,
    Reachable,
    Pending,
    Free,
}

struct Checker<'a> {
    db: &'a Db,
    /// What each page is from the point of view of the CURRENT root.
    class: Vec<Class>,
    /// For pending pages: the transaction that freed them.
    freed_by: Vec<u64>,
    /// Pages reached during the walk of one root.
    seen: Vec<bool>,
    // The root being walked:
    root_txn: u64,
    is_current: bool,
    height: usize,
    entries: u64,
}

impl Db {
    pub fn validate(&self) -> Result<(), Violation> {
        let n = self.store.page_count();
        let m = Meta::pick(&self.store.meta_slots).ok_or(Violation::BadMeta)?;
        if m != self.current || m.page_count as usize != n {
            return Err(Violation::BadMeta);
        }
        let mut c = Checker {
            db: self,
            class: vec![Class::Unknown; n],
            freed_by: vec![0; n],
            seen: vec![false; n],
            root_txn: m.txn_id,
            is_current: true,
            height: m.height as usize,
            entries: 0,
        };

        // Free list: valid ids, no duplicates, slots really free.
        for &id in &self.store.free {
            if id.is_nil() || id.index() >= n || c.class[id.index()] != Class::Unknown {
                return Err(Violation::FreeListCorrupt);
            }
            if self.store.slots[id.index()].state != SlotState::Free {
                return Err(Violation::FreeListCorrupt);
            }
            c.class[id.index()] = Class::Free;
        }
        // Pending list: live pages, ascending by the freeing transaction,
        // none freed by a transaction that has not committed.
        let mut last = 0;
        for p in &self.pending {
            if p.page.is_nil() || p.page.index() >= n || c.class[p.page.index()] != Class::Unknown {
                return Err(Violation::PendingCorrupt);
            }
            if !self.store.is_live(p.page) || p.freed_by < last || p.freed_by > m.txn_id {
                return Err(Violation::PendingCorrupt);
            }
            last = p.freed_by;
            c.class[p.page.index()] = Class::Pending;
            c.freed_by[p.page.index()] = p.freed_by;
        }

        c.check_root(m.root, m.count)?;
        // Everything else must be accounted for. (While a write transaction
        // is open, the page ids it has reserved are in none of the three sets.)
        if !self.writer_active && c.class.contains(&Class::Unknown) {
            return Err(Violation::PageLeak);
        }

        let mut prev_id = None;
        for s in &self.snapshots {
            if s.refs == 0 || s.snap.id > m.txn_id || prev_id.is_some_and(|p| s.snap.id <= p) {
                return Err(Violation::BadRoot);
            }
            prev_id = Some(s.snap.id);
            c.root_txn = s.snap.id;
            c.is_current = false;
            c.height = s.snap.height;
            c.check_root(s.snap.root, s.snap.count)?;
        }
        Ok(())
    }
}

impl Checker<'_> {
    fn check_root(&mut self, root: PageId, count: u64) -> Result<(), Violation> {
        self.seen.fill(false);
        self.entries = 0;
        if root.is_nil() {
            if self.height != 0 || count != 0 {
                return Err(Violation::BadRoot);
            }
            return Ok(());
        }
        if self.height == 0 {
            return Err(Violation::BadRoot);
        }
        self.check_node(root, 1, None, None)?;
        if self.entries != count {
            return Err(Violation::WrongCount);
        }
        Ok(())
    }

    /// Checks the subtree rooted at `id`. `lo` (inclusive) and `hi`
    /// (exclusive) are the bounds inherited from the separators above;
    /// `None` means unbounded.
    fn check_node(
        &mut self,
        id: PageId,
        depth: usize,
        lo: Option<u64>,
        hi: Option<u64>,
    ) -> Result<(), Violation> {
        let db = self.db;
        if id.is_nil() || id.index() >= self.class.len() {
            return Err(Violation::DanglingChild);
        }
        let i = id.index();
        let slot = &db.store.slots[i];

        if self.seen[i] {
            return Err(Violation::PageReachedTwice); // invariant 5
        }
        self.seen[i] = true;
        if slot.state != SlotState::Live || self.class[i] == Class::Free {
            return Err(Violation::ReachablePageIsFree); // invariant 7
        }
        if slot.written_by > self.root_txn {
            return Err(Violation::LivePageModified); // invariant 6
        }
        if self.is_current {
            if self.class[i] == Class::Pending {
                return Err(Violation::PendingCorrupt); // invariant 7
            }
            self.class[i] = Class::Reachable;
        } else {
            match self.class[i] {
                Class::Reachable => {} // shared with the current tree
                Class::Pending if self.freed_by[i] > self.root_txn => {}
                _ => return Err(Violation::SnapshotPageUnprotected), // invariant 8
            }
        }

        let n = &slot.node;
        let keys = n.key_slice();
        if n.len > db.max_keys() {
            return Err(Violation::NodeOverfull);
        }
        if n.len < (if depth == 1 { 1 } else { db.min_keys() }) {
            return Err(Violation::NodeUnderfull);
        }
        for (j, &k) in keys.iter().enumerate() {
            if j > 0 && keys[j - 1] >= k {
                return Err(Violation::KeysNotSorted);
            }
            if lo.is_some_and(|lo| k < lo) || hi.is_some_and(|hi| k >= hi) {
                return Err(Violation::KeyOutOfBounds);
            }
        }
        match &n.kind {
            Kind::Leaf(_) => {
                if depth != self.height {
                    return Err(Violation::UnevenLeafDepth);
                }
                self.entries += n.len as u64;
            }
            Kind::Internal(_) => {
                if depth >= self.height {
                    return Err(Violation::UnevenLeafDepth);
                }
                for (j, &child) in n.child_slice().iter().enumerate() {
                    let child_lo = if j == 0 { lo } else { Some(keys[j - 1]) };
                    let child_hi = if j == n.len { hi } else { Some(keys[j]) };
                    self.check_node(child, depth + 1, child_lo, child_hi)?;
                }
            }
        }
        Ok(())
    }
}
