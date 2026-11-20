//! `Db` = version store + index, and the operations that need both:
//! `put` / `delete` (writers), `Cursor` and `get` (snapshot readers that
//! leave hints behind), and `vacuum`.

use crate::base_arena::{Arena, NodeId, OutOfNodes};
use crate::base_node::{self as node, PageState};
use crate::index::{Garbage, Index};
use crate::store::{Store, Tid, Version};
use crate::validate::{self, Violation};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Row {
    pub key: u64,
    pub value: u64,
}

/// What readers did. Kept apart from `index::Stats` because these are costs
/// of reading, not changes to the tree.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ReadStats {
    /// Version-store lookups made to decide visibility ("heap visits").
    pub heap_fetches: usize,
    /// Entries skipped because of their hint bit: a heap visit saved.
    pub hint_skips: usize,
    pub hints_set: usize,
    /// Times a scan landed on a half-dead or deleted page and moved right.
    pub moved_right: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VacuumOptions {
    /// false = only remove entries; leave empty pages in place.
    pub delete_pages: bool,
}

impl Default for VacuumOptions {
    fn default() -> Self {
        VacuumOptions { delete_pages: true }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct VacuumReport {
    pub horizon: u64,
    pub entries_removed: usize,
    pub pages_unlinked: usize,
    pub pages_recycled: usize,
    /// Deleted pages that some snapshot still forces us to keep.
    pub pages_waiting: usize,
}

#[derive(Debug)]
pub struct Db {
    pub store: Store,
    pub index: Index,
    pub reads: ReadStats,
}

impl Db {
    pub fn new(order: usize) -> Db {
        Db::with_budgets(order, usize::MAX, usize::MAX)
    }

    /// A Db that refuses to hold more than `max_pages` index pages or
    /// `max_versions` row versions (Zig tests this with a failing allocator).
    pub fn with_budgets(order: usize, max_pages: usize, max_versions: usize) -> Db {
        Db {
            store: Store { versions: Arena::with_budget(max_versions), ..Store::default() },
            index: Index::with_budget(order, max_pages),
            reads: ReadStats::default(),
        }
    }

    // ------------------------------------------------------------ writers

    /// The tid of the version of `key` that no transaction has deleted yet.
    /// A writer's lookup: it wants the latest state, not a snapshot.
    fn current(&self, key: u64) -> Option<Tid> {
        let mut id = self.index.find_leaf(node::pack_low(key));
        while !id.is_nil() {
            let n = self.index.nodes.get(id);
            if n.leaf().state == PageState::Live {
                for &index_key in n.key_slice() {
                    if node::user_key(index_key) < key {
                        continue;
                    }
                    if node::user_key(index_key) > key {
                        return None;
                    }
                    let tid = node::tid_of(index_key);
                    if self.store.versions.get(tid).xmax == 0 {
                        return Some(tid);
                    }
                }
            }
            id = n.leaf().next;
        }
        None
    }

    /// Insert or update. An update does NOT overwrite: it ends the current
    /// version (sets its xmax) and adds a new version with a new index entry.
    /// Returns the previous value. On `Err(OutOfNodes)` nothing has changed.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
        // Reserve everything that can fail before changing anything.
        self.store.versions.reserve(1)?;
        self.index.reserve_for_insert()?;
        let xid = self.store.tick();
        let mut old = None;
        if let Some(tid) = self.current(key) {
            let v = self.store.versions.get_mut(tid);
            v.xmax = xid;
            old = Some(v.value);
        }
        let tid = self.store.versions.alloc_reserved(Version { key, value, xmin: xid, xmax: 0 });
        self.index.insert_reserved(&mut self.store, node::pack(key, tid));
        Ok(old)
    }

    /// Delete = write one number. The index is not touched at all: its entry
    /// stays, because snapshots older than this transaction still need it.
    pub fn delete(&mut self, key: u64) -> Option<u64> {
        let tid = self.current(key)?;
        let xid = self.store.tick();
        let v = self.store.versions.get_mut(tid);
        v.xmax = xid;
        Some(v.value)
    }

    // ------------------------------------------------------------ readers

    /// Takes `&mut self`, not `&self`: a read may set hint bits.
    pub fn get(&mut self, snapshot: u64, key: u64) -> Result<Option<u64>, DanglingLink> {
        let mut cursor = Cursor::seek(self, snapshot, key, key + 1);
        Ok(cursor.next(self)?.map(|row| row.value))
    }

    // ------------------------------------------------------------- vacuum

    /// Walks the leaf chain once and
    ///   1. removes every entry whose version is dead to the horizon,
    ///   2. finishes page deletions that stopped after phase 1,
    ///   3. deletes (both phases) the leaves it emptied, where allowed,
    ///   4. recycles the deleted pages that no snapshot can reach any more.
    ///
    /// Never allocates, so it cannot fail.
    pub fn vacuum(&mut self, options: VacuumOptions) -> VacuumReport {
        let mut report = VacuumReport { horizon: self.store.horizon(), ..VacuumReport::default() };
        let index = &mut self.index;
        let mut left = NodeId::NIL; // chain predecessor of `id`
        let mut id = index.first_leaf;
        while !id.is_nil() {
            let next = index.nodes.get(id).leaf().next;
            if index.nodes.get(id).leaf().state == PageState::Live {
                let removed = index.remove_where(&mut self.store, id, Garbage::DeadToAll);
                index.stats.vacuum_deleted += removed;
                report.entries_removed += removed;
                if index.nodes.get(id).len == 0 && options.delete_pages {
                    index.mark_half_dead(id);
                }
            }
            if index.nodes.get(id).leaf().state == PageState::HalfDead && options.delete_pages {
                index.unlink_half_dead(&mut self.store, left, id);
                report.pages_unlinked += 1;
            } else {
                left = id; // still in the chain: it is the next page's predecessor
            }
            id = next;
        }
        // The unlinks above advanced the epoch; ask for the horizon again.
        report.pages_recycled = index.recycle(self.store.horizon());
        let mut waiting = index.deleted_head;
        while !waiting.is_nil() {
            report.pages_waiting += 1;
            waiting = index.nodes.get(waiting).leaf().next_deleted;
        }
        report
    }

    pub fn validate(&self) -> Result<(), Violation> {
        validate::validate(self)
    }
}

/// The saved link names a page that has been recycled. Cannot happen unless
/// a page was recycled while the cursor's snapshot was open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DanglingLink;

/// A forward scan under one snapshot.
///
/// It works the way a Postgres index scan does: read ONE leaf completely,
/// copy out what the snapshot can see, remember the page's right link, and
/// only then hand rows to the caller. Between two calls the cursor therefore
/// holds no pointer INTO a page, only the handle of the page it will read
/// next. That handle is the whole problem of page deletion: the page may be
/// emptied, half-dead or deleted by the time the cursor follows it.
///
/// The cursor is plain data and does not borrow the Db; every call is given
/// the Db again, so writers and VACUUM can run between calls. (With a borrow
/// the compiler would simply forbid the interleavings this chapter is about.)
/// The caller must keep `snapshot` open for as long as the cursor is used.
#[derive(Debug, Clone)]
pub struct Cursor {
    pub snapshot: u64,
    /// First page: skip index keys below this. Later pages hold only larger ones.
    lo: u64,
    /// Stop before the first user key >= hi.
    hi: u64,
    /// The page to read when the buffer runs out (`NIL` = end of chain).
    pub next_leaf: NodeId,
    rows: Vec<Row>,
    pos: usize,
}

impl Cursor {
    /// Positions before the first row with lo <= key < hi. Reads nothing yet.
    pub fn seek(db: &Db, snapshot: u64, lo: u64, hi: u64) -> Cursor {
        assert!(db.store.is_open(snapshot));
        Cursor {
            snapshot,
            lo: node::pack_low(lo),
            hi,
            next_leaf: db.index.find_leaf(node::pack_low(lo)),
            rows: Vec::with_capacity(node::KEY_CAPACITY),
            pos: 0,
        }
    }

    // Not `Iterator::next`: it needs the Db and can fail.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self, db: &mut Db) -> Result<Option<Row>, DanglingLink> {
        while self.pos == self.rows.len() {
            if !self.read_page(db)? {
                return Ok(None);
            }
        }
        self.pos += 1;
        Ok(Some(self.rows[self.pos - 1]))
    }

    /// Fills the buffer from the next live page. Returns false at the end.
    fn read_page(&mut self, db: &mut Db) -> Result<bool, DanglingLink> {
        let mut id = self.next_leaf;
        self.rows.clear();
        self.pos = 0;
        loop {
            if id.is_nil() {
                self.next_leaf = NodeId::NIL;
                return Ok(false);
            }
            if !db.index.nodes.is_live(id) || !db.index.nodes.get(id).is_leaf() {
                return Err(DanglingLink);
            }
            // Half-dead or deleted: nothing to read, and the page's own right
            // link still leads to everything that used to be to its right.
            let leaf = db.index.nodes.get(id).leaf();
            if leaf.state == PageState::Live {
                break;
            }
            db.reads.moved_right += 1;
            id = leaf.next;
        }
        let n = db.index.nodes.get_mut(id);
        for i in 0..n.len {
            let index_key = n.keys[i];
            if index_key < self.lo {
                continue;
            }
            if node::user_key(index_key) >= self.hi {
                self.next_leaf = NodeId::NIL; // nothing further right can qualify
                return Ok(!self.rows.is_empty());
            }
            if n.leaf().dead[i] {
                db.reads.hint_skips += 1;
                continue;
            }
            let tid = node::tid_of(index_key);
            let v = db.store.versions.get(tid);
            db.reads.heap_fetches += 1;
            if v.visible(self.snapshot) {
                self.rows.push(Row { key: v.key, value: v.value });
            } else if db.store.dead_to_all(tid) {
                // Not just invisible to me: invisible to everyone, for ever.
                // Leave a note so that the next reader skips the heap visit
                // and the next insert on a full page can drop the entry.
                n.leaf_mut().dead[i] = true;
                db.reads.hints_set += 1;
            }
        }
        self.next_leaf = n.leaf().next;
        Ok(true)
    }
}
