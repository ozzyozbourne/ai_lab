//! `WriteTxn`: the write transaction. Path copying happens here.
//!
//! A transaction never changes a committed page. Before it modifies a page it
//! calls `touch`, which copies the page into the transaction's own `Vec` under
//! a brand-new page id and remembers the old id as "freed by this
//! transaction". The parent must then point at the new id, so the parent is
//! copied too, and so on up to the root: every modification copies one
//! root-to-leaf path and shares everything else with the previous tree.
//!
//! Memory: everything the transaction builds (page copies, the dirty map,
//! its lists) is owned by the `WriteTxn` value. Zig uses an arena for this;
//! the Rust idiom is "drop the Vec":
//!   abort   = drop the transaction. `Drop` hands back the page ids; the
//!             store was never written, so there is nothing to undo.
//!   commit  = copy the dirty pages into their (free) slots, write the meta
//!             slot, drop the transaction.
//!
//! Errors: if `put` or `delete` fails (`OutOfPages`) the transaction's private
//! tree may be half modified. That is harmless, because nobody else can see
//! it: the transaction is marked `failed` and `commit` refuses it.

use crate::base_node::{Kind, Node, PageId};
use crate::base_search::{child_index, lower_bound};
use crate::db::{Db, PendingFree};
use crate::meta::Meta;
use crate::read::{DirtyMap, View};

/// What one commit did; the demo program prints it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CommitInfo {
    /// 0 for a transaction that changed nothing (no commit happened).
    pub txn_id: u64,
    /// Committed pages replaced by a copy.
    pub copied: usize,
    /// Page ids taken from the free list / by growing the store.
    pub reused: usize,
    pub fresh: usize,
    /// Committed pages this transaction made unreachable (now pending).
    pub freed: usize,
    /// Pending pages that became free right after the commit.
    pub released: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TxnError {
    /// The transaction would hold more pages than `Db::page_budget` allows
    /// (the stand-in for Zig's `error.OutOfMemory`).
    OutOfPages,
    /// `commit` on a transaction in which `put` or `delete` failed.
    TxnFailed,
    /// Only with `Db::crash_after`: a power failure in the middle of the
    /// commit's writes. The store is as the "disk" was at that instant and
    /// the rest of the `Db` is as meaningless as the memory of a dead
    /// process: call `Db::reopen`.
    Crashed,
}

pub struct WriteTxn<'db> {
    db: &'db mut Db,
    /// The id this transaction gets if it commits.
    id: u64,
    // The transaction's private idea of the tree.
    root: PageId,
    height: usize,
    count: u64,
    /// Every page this transaction created or copied. This `Vec` is the
    /// arena: pages are never removed one by one, the whole thing is dropped.
    pages: Vec<Node>,
    /// Page id -> index in `pages`. A page in here belongs to this
    /// transaction alone and may be modified in place as often as needed.
    dirty: DirtyMap,
    /// Committed pages replaced or dropped by this transaction.
    freed: Vec<PageId>,
    /// Dirty pages dropped again (merged away); they were never committed,
    /// so no root can reach them and they go straight to the free list.
    scrapped: Vec<PageId>,
    /// Page ids popped from the store's free list (returned on abort).
    taken: Vec<PageId>,
    /// Next page id past the end of the store (the "file" grows at commit).
    next_new: usize,
    info: CommitInfo,
    /// Set when `put` / `delete` returned an error.
    failed: bool,
    /// Set by a successful commit, so that `Drop` does not abort.
    committed: bool,
}

struct Split {
    separator: u64,
    right: PageId,
}

enum Outcome {
    Replaced(u64),
    Inserted,
    Split(Split),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Survivor {
    Left,
    Right,
}

impl<'db> WriteTxn<'db> {
    pub(crate) fn new(db: &'db mut Db) -> WriteTxn<'db> {
        let m = db.current;
        let next_new = db.store.page_count();
        db.writer_active = true;
        WriteTxn {
            db,
            id: m.txn_id + 1,
            root: m.root,
            height: m.height as usize,
            count: m.count,
            pages: Vec::new(),
            dirty: DirtyMap::new(),
            freed: Vec::new(),
            scrapped: Vec::new(),
            taken: Vec::new(),
            next_new,
            info: CommitInfo::default(),
            failed: false,
            committed: false,
        }
    }

    pub fn view(&self) -> View<'_> {
        View {
            store: &self.db.store,
            dirty: Some((&self.dirty, &self.pages)),
            root: self.root,
            height: self.height,
            count: self.count,
        }
    }

    /// Reads see the transaction's own uncommitted changes.
    pub fn get(&self, key: u64) -> Option<u64> {
        self.view().get(key)
    }

    /// The committed state, which this transaction has not changed.
    pub fn committed(&self) -> &Db {
        self.db
    }

    pub fn dirty_count(&self) -> usize {
        self.dirty.len()
    }

    pub fn info(&self) -> CommitInfo {
        self.info
    }

    pub fn failed(&self) -> bool {
        self.failed
    }

    // ------------------------------------------------------ page plumbing

    /// A new private page holding `content`, under a page id nobody uses.
    fn alloc_page(&mut self, content: Node) -> Result<PageId, TxnError> {
        // The check that can fail comes first, so that a failure leaves the
        // free list and the dirty map consistent.
        if self
            .db
            .page_budget
            .is_some_and(|budget| self.pages.len() >= budget)
        {
            return Err(TxnError::OutOfPages);
        }
        let id = if let Some(reusable) = self.db.store.free.pop() {
            self.taken.push(reusable);
            self.info.reused += 1;
            reusable
        } else {
            self.next_new += 1;
            self.info.fresh += 1;
            PageId::from_index(self.next_new - 1)
        };
        self.dirty.insert(id, self.pages.len());
        self.pages.push(content);
        Ok(id)
    }

    /// Returns the id of a page this transaction may modify, with the same
    /// content as page `id`. THE copy-on-write step:
    ///   * already dirty: it is ours, use it (a page is copied at most once
    ///     per transaction);
    ///   * committed: copy it to a new page id; the old page stays as it is
    ///     for older roots and is recorded in `freed`.
    ///
    /// The caller must store the returned id where the old id was.
    fn touch(&mut self, id: PageId) -> Result<PageId, TxnError> {
        if self.dirty.contains_key(&id) {
            return Ok(id);
        }
        let copy = self.alloc_page(self.db.store.read(id).clone())?;
        self.freed.push(id);
        self.info.copied += 1;
        Ok(copy)
    }

    /// Page `id` is no longer part of this transaction's tree.
    fn discard(&mut self, id: PageId) {
        if self.dirty.remove(&id).is_some() {
            self.scrapped.push(id);
        } else {
            self.freed.push(id);
        }
    }

    /// Read-only access to a page of this transaction's tree.
    fn peek(&self, id: PageId) -> &Node {
        match self.dirty.get(&id) {
            Some(&i) => &self.pages[i],
            None => self.db.store.read(id),
        }
    }

    /// Mutable access to a page this transaction owns.
    fn node_mut(&mut self, id: PageId) -> &mut Node {
        &mut self.pages[self.dirty[&id]]
    }

    // -------------------------------------------------------------- put

    /// Insert or overwrite. Returns the previous value, if any.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, TxnError> {
        assert!(!self.failed);
        let result = self.put_inner(key, value);
        self.failed = result.is_err();
        result
    }

    fn put_inner(&mut self, key: u64, value: u64) -> Result<Option<u64>, TxnError> {
        if self.root.is_nil() {
            let mut leaf = Node::new_leaf();
            leaf.leaf_insert_at(0, key, value);
            self.root = self.alloc_page(leaf)?;
            self.height = 1;
            self.count = 1;
            return Ok(None);
        }
        let (id, outcome) = self.insert_into(self.root, key, value)?;
        self.root = id; // the root moved: this is what the meta flip publishes
        match outcome {
            Outcome::Replaced(old) => return Ok(Some(old)),
            Outcome::Inserted => {}
            Outcome::Split(s) => {
                // The root split: a new root above the two halves.
                let mut new_root = Node::new_internal();
                new_root.internal_mut().children[0] = id;
                new_root.internal_insert_at(0, s.separator, s.right);
                self.root = self.alloc_page(new_root)?;
                self.height += 1;
            }
        }
        self.count += 1;
        Ok(None)
    }

    /// Returns where the visited page lives NOW (its copy) and what happened.
    fn insert_into(
        &mut self,
        id: PageId,
        key: u64,
        value: u64,
    ) -> Result<(PageId, Outcome), TxnError> {
        // Copy on the way DOWN: by the time we change anything, this page is
        // private.
        let id = self.touch(id)?;
        let max = self.db.max_keys();
        let n = self.node_mut(id);
        let (i, child) = match &mut n.kind {
            Kind::Leaf(leaf) => {
                let i = lower_bound(&n.keys[..n.len], key);
                if i < n.len && n.keys[i] == key {
                    let old = std::mem::replace(&mut leaf.values[i], value);
                    return Ok((id, Outcome::Replaced(old)));
                }
                n.leaf_insert_at(i, key, value);
                if n.len <= max {
                    return Ok((id, Outcome::Inserted));
                }
                return Ok((id, Outcome::Split(self.split_leaf(id)?)));
            }
            Kind::Internal(internal) => {
                let i = child_index(&n.keys[..n.len], key);
                (i, internal.children[i])
            }
        };
        // The recursion needs `&mut self`, so the borrow of `n` ends here and
        // the node is looked up again afterwards (Zig keeps the pointer).
        let (child, outcome) = self.insert_into(child, key, value)?;
        let n = self.node_mut(id);
        // The child was copied to a new page id: repoint. This write is the
        // reason the parent had to be copied as well.
        n.internal_mut().children[i] = child;
        match outcome {
            Outcome::Replaced(_) | Outcome::Inserted => Ok((id, outcome)),
            Outcome::Split(s) => {
                n.internal_insert_at(i, s.separator, s.right);
                if n.len <= max {
                    return Ok((id, Outcome::Inserted));
                }
                Ok((id, Outcome::Split(self.split_internal(id)?)))
            }
        }
    }

    /// Splits a (private) leaf holding M entries. COPY-UP as in chapter 07,
    /// minus the sibling-link splicing: there is no chain to maintain.
    fn split_leaf(&mut self, left_id: PageId) -> Result<Split, TxnError> {
        let left = self.peek(left_id);
        let mid = left.len / 2;
        let moved = left.len - mid;
        let mut right = Node::new_leaf();
        right.keys[..moved].copy_from_slice(&left.keys[mid..left.len]);
        right.leaf_mut().values[..moved].copy_from_slice(&left.leaf().values[mid..left.len]);
        right.len = moved;
        let separator = right.keys[0];
        let right = self.alloc_page(right)?;
        self.node_mut(left_id).len = mid;
        Ok(Split { separator, right })
    }

    /// Splits a (private) internal node holding M separators. PUSH-UP.
    fn split_internal(&mut self, left_id: PageId) -> Result<Split, TxnError> {
        let left = self.peek(left_id);
        let mid = left.len / 2;
        let separator = left.keys[mid];
        let moved = left.len - mid - 1;
        let mut right = Node::new_internal();
        right.keys[..moved].copy_from_slice(&left.keys[mid + 1..left.len]);
        right.internal_mut().children[..moved + 1]
            .copy_from_slice(&left.internal().children[mid + 1..left.len + 1]);
        right.len = moved;
        let right = self.alloc_page(right)?;
        self.node_mut(left_id).len = mid;
        Ok(Split { separator, right })
    }

    // ----------------------------------------------------------- delete

    /// Removes `key`. Returns its value, or `None` if it was not there.
    pub fn delete(&mut self, key: u64) -> Result<Option<u64>, TxnError> {
        assert!(!self.failed);
        let result = self.delete_inner(key);
        self.failed = result.is_err();
        result
    }

    fn delete_inner(&mut self, key: u64) -> Result<Option<u64>, TxnError> {
        // Look before you copy: a miss must not copy a path for nothing.
        if self.get(key).is_none() {
            return Ok(None);
        }
        let (id, removed) = self.delete_from(self.root, key)?;
        self.root = id;
        self.count -= 1;

        let root = self.peek(self.root);
        if root.len == 0 {
            let old_root = self.root;
            self.root = match &root.kind {
                Kind::Leaf(_) => PageId::NIL,                     // last entry gone
                Kind::Internal(internal) => internal.children[0], // one child left
            };
            self.height -= 1;
            self.discard(old_root);
        }
        Ok(Some(removed))
    }

    fn delete_from(&mut self, id: PageId, key: u64) -> Result<(PageId, u64), TxnError> {
        let id = self.touch(id)?;
        let n = self.node_mut(id);
        let (i, child) = match &n.kind {
            Kind::Leaf(_) => {
                let i = lower_bound(n.key_slice(), key);
                assert!(i < n.len && n.keys[i] == key);
                return Ok((id, n.leaf_remove_at(i).value));
            }
            Kind::Internal(internal) => {
                let i = child_index(n.key_slice(), key);
                (i, internal.children[i])
            }
        };
        let (child, removed) = self.delete_from(child, key)?;
        self.node_mut(id).internal_mut().children[i] = child;
        if self.peek(child).len < self.db.min_keys() {
            self.rebalance(id, i)?;
        }
        Ok((id, removed))
    }

    fn child_of(&self, parent: PageId, i: usize) -> PageId {
        self.peek(parent).internal().children[i]
    }

    /// Child `i` of the private node `parent` is one key short. Same order of
    /// preference as chapter 07 (borrow left, borrow right, merge left, merge
    /// right), but the COSTS are different here:
    ///   borrow  the sibling changes, so the sibling is COPIED (one extra page);
    ///   merge   the sibling is only read and then freed (no extra copy).
    fn rebalance(&mut self, parent: PageId, i: usize) -> Result<(), TxnError> {
        let min = self.db.min_keys();
        let parent_len = self.peek(parent).len;
        if i > 0 && self.peek(self.child_of(parent, i - 1)).len > min {
            self.borrow_from_left(parent, i)
        } else if i < parent_len && self.peek(self.child_of(parent, i + 1)).len > min {
            self.borrow_from_right(parent, i)
        } else if i > 0 {
            self.merge(parent, i - 1, Survivor::Right);
            Ok(())
        } else {
            self.merge(parent, i, Survivor::Left);
            Ok(())
        }
    }

    /// Moves the last item of the left sibling to the front of child `i`.
    ///
    /// Three nodes change (left, child, parent). They live in one `Vec`, so
    /// instead of three simultaneous `&mut` the item is carried by value from
    /// one node to the next.
    fn borrow_from_left(&mut self, parent: PageId, i: usize) -> Result<(), TxnError> {
        let left_id = self.touch(self.child_of(parent, i - 1))?;
        self.node_mut(parent).internal_mut().children[i - 1] = left_id;
        let child_id = self.child_of(parent, i); // copied on the way down
        let left = self.node_mut(left_id);
        if left.is_leaf() {
            let e = left.leaf_remove_at(left.len - 1);
            self.node_mut(child_id).leaf_insert_at(0, e.key, e.value);
            self.node_mut(parent).keys[i - 1] = e.key;
        } else {
            // Rotation through the parent, as in chapter 05.
            let moved_child = left.internal().children[left.len];
            let up = left.keys[left.len - 1];
            left.len -= 1;
            let down = std::mem::replace(&mut self.node_mut(parent).keys[i - 1], up);
            let child = self.node_mut(child_id);
            let len = child.len;
            child.keys.copy_within(0..len, 1);
            child.keys[0] = down;
            let children = &mut child.internal_mut().children;
            children.copy_within(0..len + 1, 1);
            children[0] = moved_child;
            child.len += 1;
        }
        Ok(())
    }

    /// Moves the first item of the right sibling to the end of child `i`.
    fn borrow_from_right(&mut self, parent: PageId, i: usize) -> Result<(), TxnError> {
        let right_id = self.touch(self.child_of(parent, i + 1))?;
        self.node_mut(parent).internal_mut().children[i + 1] = right_id;
        let child_id = self.child_of(parent, i);
        let right = self.node_mut(right_id);
        if right.is_leaf() {
            let e = right.leaf_remove_at(0);
            let new_separator = right.keys[0];
            let child = self.node_mut(child_id);
            child.leaf_insert_at(child.len, e.key, e.value);
            self.node_mut(parent).keys[i] = new_separator;
        } else {
            let moved_child = right.internal().children[0];
            let up = right.keys[0];
            // Drop right's first key and first child.
            let len = right.len;
            right.keys.copy_within(1..len, 0);
            right.internal_mut().children.copy_within(1..len + 1, 0);
            right.len -= 1;
            let down = std::mem::replace(&mut self.node_mut(parent).keys[i], up);
            let child = self.node_mut(child_id);
            let len = child.len;
            child.keys[len] = down;
            child.internal_mut().children[len + 1] = moved_child;
            child.len += 1;
        }
        Ok(())
    }

    /// Merges children `li` and `li + 1` of `parent` into ONE page.
    ///
    /// Chapter 07 always merged right into left. Here one of the two is
    /// certainly a private copy already (the child we came up from, named by
    /// `survivor`), so we merge INTO THAT ONE: the other sibling is only read
    /// and then freed, and never has to be copied.
    fn merge(&mut self, parent: PageId, li: usize, survivor: Survivor) {
        let left_id = self.child_of(parent, li);
        let right_id = self.child_of(parent, li + 1);
        let (keep_id, drop_id) = match survivor {
            Survivor::Left => (left_id, right_id),
            Survivor::Right => (right_id, left_id),
        };
        // In a one-operation transaction the other sibling is a committed
        // page; in a longer one it may be dirty from an earlier operation.
        // `peek` handles both.
        let right = self.peek(right_id);
        // Build the merged node in a scratch copy, then store it in the survivor.
        let mut merged = self.peek(left_id).clone();
        let (ll, rl) = (merged.len, right.len);
        match &mut merged.kind {
            Kind::Leaf(leaf) => {
                // The separator between two leaves was only a copy: drop it.
                merged.keys[ll..ll + rl].copy_from_slice(right.key_slice());
                leaf.values[ll..ll + rl].copy_from_slice(&right.leaf().values[..rl]);
                merged.len = ll + rl;
            }
            Kind::Internal(internal) => {
                // The separator between two internal nodes comes DOWN.
                merged.keys[ll] = self.peek(parent).keys[li];
                merged.keys[ll + 1..ll + 1 + rl].copy_from_slice(right.key_slice());
                internal.children[ll + 1..ll + 2 + rl].copy_from_slice(right.child_slice());
                merged.len = ll + 1 + rl;
            }
        }
        assert!(merged.len <= self.db.max_keys());
        *self.node_mut(keep_id) = merged;
        self.discard(drop_id);
        let p = self.node_mut(parent);
        p.internal_mut().children[li] = keep_id; // internal_remove_at drops child li + 1
        p.internal_remove_at(li);
    }

    // --------------------------------------------------- commit / abort

    /// Publishes the transaction: write the new pages, then flip the root.
    /// Consumes the transaction; on `Err(TxnFailed)` it is dropped, which
    /// aborts it. `Err(Crashed)` is the injected power failure: restart with
    /// `Db::reopen`.
    pub fn commit(mut self) -> Result<CommitInfo, TxnError> {
        if self.failed {
            return Err(TxnError::TxnFailed);
        }
        if self.dirty.is_empty() && self.freed.is_empty() {
            // Nothing changed (e.g. delete of a missing key): no new root,
            // no new transaction id. Dropping `self` returns the page ids.
            self.info = CommitInfo::default();
            self.committed = true;
            self.return_page_ids();
            return Ok(self.info);
        }
        let id = self.id;

        // Phase 1 (Zig: everything that can fail) has no counterpart here:
        // growing a `Vec` aborts the process instead of returning an error.
        self.db.store.grow(self.next_new);

        // Phase 2: write the new pages. Each goes to a FREE slot, so a crash
        // (or a reader) in the middle of this loop still sees the old tree
        // complete: the old meta slot does not point at any of these pages.
        // The same holds for the tree of the OTHER meta slot
        // (`db.previous`): the pages only it reaches are still pending.
        for (&page, &i) in &self.dirty {
            if power_fails(self.db) {
                return Err(self.crashed());
            }
            self.db.store.write(page, &self.pages[i], id);
        }
        self.db.store.free.extend_from_slice(&self.scrapped);

        // Phase 3: THE atomic step. One small write into the slot that does
        // NOT hold the current root. Before it, readers find the old tree;
        // after it, the new one. A real engine syncs the pages before this
        // write and the meta slot after it (chapter 21).
        let new = Meta {
            txn_id: id,
            root: self.root,
            height: u32::try_from(self.height).expect("height fits"),
            count: self.count,
            page_count: u32::try_from(self.db.store.page_count()).expect("page count fits"),
        };
        // Byte by byte only so that a crash can tear it; a slot with some
        // new and some old bytes fails its checksum.
        for (i, byte) in new.encode().into_iter().enumerate() {
            if power_fails(self.db) {
                return Err(self.crashed());
            }
            self.db.store.meta_slots[(id % 2) as usize][i] = byte;
        }
        self.db.crash_after = None; // the commit is durable: nothing left to interrupt
        // The slot just overwritten held the root from two commits back.
        // From here on the fallback is the root we are replacing.
        self.db.previous = Some(self.db.current);
        self.db.current = new;

        // Phase 4: the replaced pages are unreachable from the new root, but
        // older roots still reach them: pending, not free. `reclaim` then
        // releases what no protected root needs. That never includes the
        // pages replaced just now, because `previous` reaches them.
        let freed = self
            .freed
            .iter()
            .map(|&page| PendingFree { freed_by: id, page });
        self.db.pending.extend(freed);
        let mut info = self.info;
        info.txn_id = id;
        info.freed = self.freed.len();
        info.released = self.db.reclaim();

        self.db.stats.commits += 1;
        self.db.stats.pages_copied += info.copied as u64;
        self.db.stats.pages_reused += info.reused as u64;
        self.db.stats.pages_fresh += info.fresh as u64;
        self.committed = true;
        Ok(info)
    }

    fn crashed(&mut self) -> TxnError {
        // The free list is rebuilt by `reopen`; `Drop` must not touch it.
        self.taken.clear();
        TxnError::Crashed
    }

    /// Throws the transaction away. No page of the store was written, so the
    /// committed tree and every snapshot are exactly as before. (Letting the
    /// transaction go out of scope does the same.)
    pub fn abort(self) {}

    /// Hands the reserved page ids back, last taken first, which restores
    /// the free list's order.
    fn return_page_ids(&mut self) {
        while let Some(id) = self.taken.pop() {
            self.db.store.free.push(id);
        }
    }
}

/// Fault injection: counts down `db.crash_after`; true when it runs out.
fn power_fails(db: &mut Db) -> bool {
    match db.crash_after {
        None => false,
        Some(0) => {
            db.crash_after = None;
            true
        }
        Some(left) => {
            db.crash_after = Some(left - 1);
            false
        }
    }
}

impl Drop for WriteTxn<'_> {
    fn drop(&mut self) {
        self.db.writer_active = false;
        if !self.committed {
            self.return_page_ids();
            self.db.stats.aborts += 1;
        }
        // `pages`, `dirty` and the lists are dropped right after this: every
        // page copy is gone in one go.
    }
}
