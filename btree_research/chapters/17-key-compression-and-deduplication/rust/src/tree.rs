//! Chapter 17: key compression and deduplication on an in-memory page model.
//!
//! A B+tree of byte-string keys whose pages are measured in BYTES, like a real
//! on-disk page, but whose cells are ordinary vectors (no slotted-page
//! encoding: that was chapter 10). Three ideas are implemented:
//!
//!   1. Suffix truncation: the separator created by a leaf split is the
//!      shortest byte string that still separates the two halves.
//!   2. The heap TID (row address) is the last key column, so every index
//!      entry is unique and duplicates of a user key have one correct order.
//!   3. Deduplication: equal keys in a full leaf are merged into one cell with
//!      a sorted TID array (a posting list) before the page is allowed to split.
//!
//! The order used EVERYWHERE is `compare_tuple`: key bytes first, then TID,
//! where a missing TID (a truncated one) is minus infinity.
//!
//! The one routing rule, kept by every page and checked by `validate`:
//!
//!     low fence  <  every tuple on the page  <=  high fence
//!
//! so a separator S in a parent sends tuples <= S left and tuples > S right.
use std::cmp::Ordering;

/// Row address. 6 bytes on disk in Postgres (block number + slot); here a
/// plain integer below 2^48 so that ordering is integer ordering.
pub type Tid = u64;
pub type PageId = u32;

// ---- byte accounting (what a cell would cost in a slotted page) ----
pub const HEADER_BYTES: usize = 8; // page header
pub const SLOT_BYTES: usize = 2; // slot array entry pointing at the cell
pub const LEN_BYTES: usize = 2; // key length + flag bits
pub const TID_BYTES: usize = 6;
pub const CHILD_BYTES: usize = 4; // child page id in a pivot
pub const COUNT_BYTES: usize = 2; // number of TIDs in a posting list

/// A tree with at least two children per page cannot get anywhere near this.
pub const MAX_HEIGHT: usize = 32;

#[derive(Debug, Clone, Copy)]
pub struct Config {
    pub page_size: usize,
    /// Suffix truncation of new leaf separators. Off = the full last-left
    /// tuple (key and TID) becomes the separator, as in Lehman and Yao.
    pub truncate: bool,
    /// Run a deduplication pass on a full leaf before splitting it.
    pub dedup: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config { page_size: 4096, truncate: true, dedup: true }
    }
}

/// A separator / fence key. `tid == None` means the TID was truncated away
/// and compares as minus infinity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sep {
    pub key: Vec<u8>,
    pub tid: Option<Tid>,
}

/// A leaf cell: one key and its TIDs in ascending order. One TID is a plain
/// entry, more than one is a posting list.
#[derive(Debug, Clone)]
pub struct LeafCell {
    pub key: Vec<u8>,
    pub tids: Vec<Tid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    /// The page budget is exhausted (the Rust stand-in for Zig's OutOfMemory).
    OutOfPages,
    KeyTooLarge,
}

/// The total order of the tree. A shorter key sorts first when it is a prefix
/// of the other (slice comparison does that), which is exactly "truncated
/// bytes are minus infinity". `None < Some(_)` gives the same for TIDs.
pub fn compare_tuple(a_key: &[u8], a_tid: Option<Tid>, b_key: &[u8], b_tid: Option<Tid>) -> Ordering {
    a_key.cmp(b_key).then(a_tid.cmp(&b_tid))
}

pub fn common_prefix_len(a: &[u8], b: &[u8]) -> usize {
    a.iter().zip(b).take_while(|(x, y)| x == y).count()
}

/// The separator for a split between `last_left` and `first_right`
/// (precondition: last_left < first_right in tuple order), as borrowed parts.
/// Postcondition: last_left <= sep < first_right.
pub fn separator<'a>(truncate: bool, last_left: &'a LeafCell, first_right: &'a LeafCell) -> (&'a [u8], Option<Tid>) {
    if truncate {
        // Keep the common prefix plus ONE more byte of first_right. That byte
        // is where the two keys differ (or last_left has already ended), so
        // the result is > last_left.key and, having no TID, < first_right.
        let n = common_prefix_len(&last_left.key, &first_right.key);
        if n < first_right.key.len() {
            return (&first_right.key[..=n], None);
        }
        // n == first_right.key.len(): the keys are equal. No byte can tell
        // the halves apart; only the TID can. Fall through.
    }
    // Lehman and Yao's choice: the last tuple on the left, in full.
    (&last_left.key, last_left.tids.last().copied())
}

fn fence_size(key_len: usize, has_tid: bool) -> usize {
    SLOT_BYTES + LEN_BYTES + key_len + if has_tid { TID_BYTES } else { 0 }
}

pub fn sep_size(sep: Option<&Sep>) -> usize {
    // -inf / +inf fences cost nothing
    sep.map_or(0, |s| fence_size(s.key.len(), s.tid.is_some()))
}

pub fn pivot_size(sep: &Sep) -> usize {
    sep_size(Some(sep)) + CHILD_BYTES
}

pub fn leaf_cell_size(key_len: usize, n_tids: usize) -> usize {
    let payload = if n_tids == 1 { TID_BYTES } else { COUNT_BYTES + n_tids * TID_BYTES };
    SLOT_BYTES + LEN_BYTES + key_len + payload
}

fn cells_size(cells: &[LeafCell]) -> usize {
    cells.iter().map(|c| leaf_cell_size(c.key.len(), c.tids.len())).sum()
}

fn leaf_bytes(low: Option<&Sep>, high: Option<&Sep>, cells: &[LeafCell]) -> usize {
    HEADER_BYTES + sep_size(low) + sep_size(high) + cells_size(cells)
}

/// Header plus the first child, which has no separator: a pivot with an
/// empty key ("minus infinity" in Postgres terms).
const INTERNAL_FIXED: usize = HEADER_BYTES + SLOT_BYTES + LEN_BYTES + CHILD_BYTES;

fn internal_bytes(low: Option<&Sep>, high: Option<&Sep>, seps: &[Sep]) -> usize {
    INTERNAL_FIXED + sep_size(low) + sep_size(high) + seps.iter().map(pivot_size).sum::<usize>()
}

/// A page owns everything it refers to. It is rebuilt by constructing a NEW
/// `Page` value and dropping the old one (Zig: a new arena per rebuilt page).
#[derive(Debug, Clone)]
pub struct Page {
    pub is_leaf: bool,
    /// Fence keys: copies of the separators that bracket this page in its
    /// parent. None = minus infinity (low) / plus infinity (high).
    pub low: Option<Sep>,
    pub high: Option<Sep>,
    pub right: Option<PageId>,
    pub cells: Vec<LeafCell>, // leaf only
    pub seps: Vec<Sep>,       // internal only; seps.len() + 1 == children.len()
    pub children: Vec<PageId>,
}

impl Page {
    fn leaf(low: Option<Sep>, high: Option<Sep>, right: Option<PageId>, cells: Vec<LeafCell>) -> Page {
        Page { is_leaf: true, low, high, right, cells, seps: Vec::new(), children: Vec::new() }
    }

    fn internal(
        low: Option<Sep>,
        high: Option<Sep>,
        right: Option<PageId>,
        seps: Vec<Sep>,
        children: Vec<PageId>,
    ) -> Page {
        Page { is_leaf: false, low, high, right, cells: Vec::new(), seps, children }
    }

    pub fn used_bytes(&self) -> usize {
        if self.is_leaf {
            leaf_bytes(self.low.as_ref(), self.high.as_ref(), &self.cells)
        } else {
            internal_bytes(self.low.as_ref(), self.high.as_ref(), &self.seps)
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub height: usize,
    pub leaf_pages: usize,
    pub internal_pages: usize,
    pub entries: usize, // (key, TID) pairs
    pub leaf_cells: usize,
    pub posting_cells: usize,
    pub seps: usize,      // separators in internal pages
    pub sep_bytes: usize, // their key bytes plus 6 for each kept TID
    pub children: usize,
    pub used_bytes: usize, // sum of used_bytes over all pages
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Counters {
    pub leaf_splits: usize,
    pub internal_splits: usize,
    pub dedup_passes: usize, // passes that made the new tuple fit (a split avoided)
    pub posting_swaps: usize,
}

#[derive(Debug, Clone, Copy)]
struct Step {
    page: PageId,
    child_index: usize,
}

/// Where a (key, tid) tuple is, or belongs, in a leaf.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Slot {
    /// Already present: TID number `pos` of cell `cell`.
    Found { cell: usize, pos: usize },
    /// Absent; a new plain cell goes at this index.
    InsertAt(usize),
    /// Absent, but the TID falls inside the TID range of posting list `cell`,
    /// at position `pos`.
    Inside { cell: usize, pos: usize },
}

/// Pages built by a put that are not part of the tree yet. Either everything
/// in here is installed or nothing is: that is what makes a multi-level split
/// atomic when the page budget runs out.
#[derive(Default)]
struct Txn {
    replaced: Vec<(PageId, Page)>,
    added: Vec<Page>,
    new_root: Option<PageId>,
    /// A separator and child to insert into a parent that has room.
    parent_insert: Option<(PageId, usize, Sep, PageId)>,
}

pub struct Tree {
    pub cfg: Config,
    pub pages: Vec<Page>,
    pub root: PageId,
    pub count: usize,
    pub counters: Counters,
    /// Page budget: a put that would need more pages fails with
    /// `Error::OutOfPages` and changes nothing.
    pub max_pages: usize,
}

impl Tree {
    pub fn new(cfg: Config) -> Tree {
        assert!(cfg.page_size >= 128);
        // The tree starts as one empty leaf that is also the root.
        Tree {
            cfg,
            pages: vec![Page::leaf(None, None, None, Vec::new())],
            root: 0,
            count: 0,
            counters: Counters::default(),
            max_pages: usize::MAX,
        }
    }

    /// Largest cell of any kind: one sixth of the usable page. With cells and
    /// fences this small, a balanced split of an overflowing page always
    /// yields two pages that fit (see README, "Why one sixth").
    pub fn max_cell(&self) -> usize {
        (self.cfg.page_size - HEADER_BYTES) / 6
    }

    /// Longest key accepted: it must still fit as a pivot WITH an appended
    /// TID, because a split between equal keys cannot truncate anything.
    /// (Postgres reserves the same room: BTMaxItemSize, nbtree.h:165-173.)
    pub fn max_key_len(&self) -> usize {
        self.max_cell() - (SLOT_BYTES + LEN_BYTES + TID_BYTES + CHILD_BYTES)
    }

    fn max_posting_tids(&self, key_len: usize) -> usize {
        (self.max_cell() - (SLOT_BYTES + LEN_BYTES + COUNT_BYTES) - key_len) / TID_BYTES
    }

    // ---------------------------------------------------------------- search

    /// Child to follow for a tuple: the number of separators strictly below
    /// it. Works unchanged whether separators are full tuples or truncated
    /// prefixes, because `compare_tuple` is the only thing it asks.
    pub fn child_index(page: &Page, key: &[u8], tid: Tid) -> usize {
        page.seps.partition_point(|s| compare_tuple(&s.key, s.tid, key, Some(tid)) == Ordering::Less)
    }

    fn find_leaf(&self, key: &[u8], tid: Tid, path: &mut Vec<Step>) -> PageId {
        let mut id = self.root;
        path.clear();
        loop {
            let page = &self.pages[id as usize];
            if page.is_leaf {
                return id;
            }
            let i = Self::child_index(page, key, tid);
            path.push(Step { page: id, child_index: i });
            id = page.children[i];
        }
    }

    /// Index of the first cell whose (key, first TID) is >= (key, tid).
    fn leaf_lower_bound(cells: &[LeafCell], key: &[u8], tid: Tid) -> usize {
        cells.partition_point(|c| compare_tuple(&c.key, Some(c.tids[0]), key, Some(tid)) == Ordering::Less)
    }

    fn locate(cells: &[LeafCell], key: &[u8], tid: Tid) -> Slot {
        let i = Self::leaf_lower_bound(cells, key, tid);
        if i < cells.len() && cells[i].tids[0] == tid && cells[i].key == key {
            return Slot::Found { cell: i, pos: 0 };
        }
        // The cell before starts below (key, tid). If it has the same key and
        // its LAST TID is not below tid, the tuple belongs inside its range.
        if i > 0 && cells[i - 1].key == key {
            let tids = &cells[i - 1].tids;
            if tid <= tids[tids.len() - 1] {
                let pos = tids.partition_point(|&t| t < tid);
                if tids[pos] == tid {
                    return Slot::Found { cell: i - 1, pos };
                }
                return Slot::Inside { cell: i - 1, pos };
            }
        }
        Slot::InsertAt(i)
    }

    /// Entries with lo <= key < hi in (key, TID) order. Seeking with TID 0 is
    /// "the smallest tuple with this key": it goes RIGHT of a truncated
    /// separator equal to `lo` (None < Some(0)) and LEFT of a full separator
    /// (lo, t), which is where duplicates begin.
    pub fn range<'a>(&'a self, lo: &[u8], hi: Option<&'a [u8]>) -> RangeIter<'a> {
        let leaf = self.find_leaf(lo, 0, &mut Vec::new());
        let cell = Self::leaf_lower_bound(&self.pages[leaf as usize].cells, lo, 0);
        RangeIter { tree: self, page: Some(leaf), cell, pos: 0, hi }
    }

    /// All TIDs stored under `key`, ascending.
    pub fn get(&self, key: &[u8]) -> Vec<Tid> {
        self.range(key, None).take_while(|(k, _)| *k == key).map(|(_, tid)| tid).collect()
    }

    pub fn contains(&self, key: &[u8], tid: Tid) -> bool {
        let leaf = self.find_leaf(key, tid, &mut Vec::new());
        matches!(Self::locate(&self.pages[leaf as usize].cells, key, tid), Slot::Found { .. })
    }

    // ------------------------------------------------------------------- put

    /// Insert the tuple (key, tid). Returns Ok(false) if it is already
    /// present. On error the tree is unchanged.
    pub fn put(&mut self, key: &[u8], tid: Tid) -> Result<bool, Error> {
        if key.len() > self.max_key_len() {
            return Err(Error::KeyTooLarge);
        }
        let mut path = Vec::new();
        let leaf_id = self.find_leaf(key, tid, &mut path);
        let page_size = self.cfg.page_size;
        let leaf = &mut self.pages[leaf_id as usize];
        let slot = Self::locate(&leaf.cells, key, tid);

        // Whatever happens, the page grows by exactly one PLAIN cell: either
        // the new tuple, or the TID that the new tuple pushes out of a
        // posting list (see swap_into_posting).
        let fits = leaf.used_bytes() + leaf_cell_size(key.len(), 1) <= page_size;
        match slot {
            Slot::Found { .. } => return Ok(false),
            Slot::InsertAt(i) if fits => {
                leaf.cells.insert(i, LeafCell { key: key.to_vec(), tids: vec![tid] });
            }
            Slot::Inside { cell, pos } if fits => {
                let evicted = swap_into_posting(&mut leaf.cells[cell].tids, pos, tid);
                leaf.cells.insert(cell + 1, LeafCell { key: key.to_vec(), tids: vec![evicted] });
                self.counters.posting_swaps += 1;
            }
            _ => self.put_slow(leaf_id, slot, key, tid, &path)?,
        }
        self.count += 1;
        Ok(true)
    }

    fn put_slow(&mut self, leaf_id: PageId, slot: Slot, key: &[u8], tid: Tid, path: &[Step]) -> Result<(), Error> {
        let old = &self.pages[leaf_id as usize];
        let mut txn = Txn::default();
        let mut counters = self.counters;
        let next_id = |txn: &Txn| (self.pages.len() + txn.added.len()) as PageId;

        // 1. Flatten: the page's cells plus the new tuple. (Zig borrows the
        //    cells into a FixedBufferAllocator; cloning into a Vec is the
        //    Rust equivalent, and the real page stays untouched until commit.)
        let mut items = old.cells.clone();
        match slot {
            Slot::InsertAt(i) => items.insert(i, LeafCell { key: key.to_vec(), tids: vec![tid] }),
            Slot::Inside { cell, pos } => {
                let evicted = swap_into_posting(&mut items[cell].tids, pos, tid);
                items.insert(cell + 1, LeafCell { key: key.to_vec(), tids: vec![evicted] });
                counters.posting_swaps += 1;
            }
            Slot::Found { .. } => unreachable!(),
        }

        // 2. Deduplicate before splitting: a split is forever (pages are
        //    never merged back), a posting list is free.
        if self.cfg.dedup {
            items = self.dedup_pass(items);
        }
        if self.cfg.dedup && leaf_bytes(old.low.as_ref(), old.high.as_ref(), &items) <= self.cfg.page_size {
            txn.replaced.push((leaf_id, Page::leaf(old.low.clone(), old.high.clone(), old.right, items)));
            counters.dedup_passes += 1;
        } else {
            // 3. Split the leaf. The left half keeps the page id.
            let cut = self.choose_leaf_split(old.low.as_ref(), old.high.as_ref(), &items);
            let (sep_key, sep_tid) = separator(self.cfg.truncate, &items[cut - 1], &items[cut]);
            let mut sep = Sep { key: sep_key.to_vec(), tid: sep_tid };
            let right_cells = items.split_off(cut);
            let mut left_id = leaf_id;
            let mut right_id = next_id(&txn);
            txn.replaced.push((left_id, Page::leaf(old.low.clone(), Some(sep.clone()), Some(right_id), items)));
            txn.added.push(Page::leaf(Some(sep.clone()), old.high.clone(), old.right, right_cells));
            counters.leaf_splits += 1;

            // 4. Insert (sep, right_id) into the parent; repeat while parents overflow.
            let mut level = path.len();
            loop {
                if level == 0 {
                    // The page that split was the root: grow the tree by one level.
                    txn.new_root = Some(next_id(&txn));
                    txn.added.push(Page::internal(None, None, None, vec![sep], vec![left_id, right_id]));
                    break;
                }
                level -= 1;
                let step = path[level];
                let parent = &self.pages[step.page as usize];
                let at_sep = step.child_index; // the new separator's index; its child goes one further
                if parent.used_bytes() + pivot_size(&sep) <= self.cfg.page_size {
                    // Room in the parent: remember the insertion, apply it at commit.
                    txn.parent_insert = Some((step.page, at_sep, sep, right_id));
                    break;
                }
                // Internal split.
                let mut seps = parent.seps.clone();
                let mut kids = parent.children.clone();
                seps.insert(at_sep, sep);
                kids.insert(at_sep + 1, right_id);
                // seps[m] moves UP and is not truncated any further: it must
                // stay byte-identical to the leaf-level fence it came from.
                let m = self.choose_internal_split(parent.low.as_ref(), parent.high.as_ref(), &seps);
                let right_seps = seps.split_off(m + 1);
                let right_kids = kids.split_off(m + 1);
                let up = seps.pop().expect("seps[m] exists");
                let new_right = next_id(&txn);
                txn.replaced.push((
                    step.page,
                    Page::internal(parent.low.clone(), Some(up.clone()), Some(new_right), seps, kids),
                ));
                txn.added.push(Page::internal(
                    Some(up.clone()),
                    parent.high.clone(),
                    parent.right,
                    right_seps,
                    right_kids,
                ));
                counters.internal_splits += 1;
                sep = up;
                left_id = step.page;
                right_id = new_right;
            }
        }

        // Commit, or fail without having touched the tree.
        if self.pages.len() + txn.added.len() > self.max_pages {
            return Err(Error::OutOfPages);
        }
        for (id, page) in txn.replaced {
            self.pages[id as usize] = page; // the old version is dropped here, all at once
        }
        self.pages.extend(txn.added);
        if let Some((id, at_sep, sep, child)) = txn.parent_insert {
            let parent = &mut self.pages[id as usize];
            parent.seps.insert(at_sep, sep);
            parent.children.insert(at_sep + 1, child);
        }
        if let Some(root) = txn.new_root {
            self.root = root;
        }
        self.counters = counters;
        Ok(())
    }

    /// Merge runs of equal keys into posting lists (Postgres:
    /// `_bt_dedup_pass`). The cells are already in (key, TID) order and the
    /// TID ranges of equal keys do not overlap, so concatenating is enough.
    fn dedup_pass(&self, items: Vec<LeafCell>) -> Vec<LeafCell> {
        let mut out: Vec<LeafCell> = Vec::with_capacity(items.len());
        for cell in items {
            // `out.last()` is the run being built; extend it while it has room.
            if let Some(last) = out.last_mut()
                && last.key == cell.key
                && last.tids.len() + cell.tids.len() <= self.max_posting_tids(cell.key.len())
            {
                last.tids.extend(cell.tids);
                continue;
            }
            out.push(cell);
        }
        out
    }

    /// Where to cut `items` (left = items[..cut]). Among the cuts that leave
    /// both halves between 40% and 60% of the cell bytes, take the one with
    /// the SHORTEST separator; otherwise the most balanced one. (A small
    /// version of the Postgres idea in nbtsplitloc.c; chapter 14 has the
    /// full story of split policies.)
    fn choose_leaf_split(&self, low: Option<&Sep>, high: Option<&Sep>, items: &[LeafCell]) -> usize {
        let total = cells_size(items);
        let mut best: Option<(usize, (usize, usize, usize))> = None;
        let mut left = 0;
        for cut in 1..items.len() {
            left += leaf_cell_size(items[cut - 1].key.len(), items[cut - 1].tids.len());
            let (sep_key, sep_tid) = separator(self.cfg.truncate, &items[cut - 1], &items[cut]);
            let fence = fence_size(sep_key.len(), sep_tid.is_some());
            if HEADER_BYTES + sep_size(low) + fence + left > self.cfg.page_size
                || HEADER_BYTES + fence + sep_size(high) + (total - left) > self.cfg.page_size
            {
                continue;
            }
            let imbalance = (2 * left).abs_diff(total);
            let in_window = imbalance * 5 <= total;
            let score = if in_window { (0, fence, imbalance) } else { (1, 0, imbalance) };
            if best.is_none_or(|(_, best_score)| score < best_score) {
                best = Some((cut, score));
            }
        }
        best.expect("a legal cut exists because no cell exceeds max_cell").0
    }

    /// Index of the separator that moves up: the most balanced legal one.
    fn choose_internal_split(&self, low: Option<&Sep>, high: Option<&Sep>, seps: &[Sep]) -> usize {
        let total: usize = seps.iter().map(pivot_size).sum();
        let mut best: Option<(usize, usize)> = None;
        let mut left = 0;
        for (m, s) in seps.iter().enumerate() {
            let right = total - left - pivot_size(s);
            let fits = INTERNAL_FIXED + sep_size(low) + sep_size(Some(s)) + left <= self.cfg.page_size
                && INTERNAL_FIXED + sep_size(Some(s)) + sep_size(high) + right <= self.cfg.page_size;
            let imbalance = left.abs_diff(right);
            if fits && best.is_none_or(|(_, best_imbalance)| imbalance < best_imbalance) {
                best = Some((m, imbalance));
            }
            left += pivot_size(s);
        }
        best.expect("a legal split exists").0
    }

    // ---------------------------------------------------------------- delete

    /// Remove the tuple (key, tid). Returns false if it is absent. Pages are
    /// never merged (Postgres does not merge either; chapters 15 and 24), so
    /// a leaf may become empty; scans step over it.
    pub fn delete(&mut self, key: &[u8], tid: Tid) -> bool {
        let leaf_id = self.find_leaf(key, tid, &mut Vec::new());
        let leaf = &mut self.pages[leaf_id as usize];
        let Slot::Found { cell, pos } = Self::locate(&leaf.cells, key, tid) else {
            return false;
        };
        if leaf.cells[cell].tids.len() == 1 {
            leaf.cells.remove(cell);
        } else {
            // Shrink the posting list in place. With one TID left it simply
            // counts as a plain cell again (see leaf_cell_size).
            leaf.cells[cell].tids.remove(pos);
        }
        self.count -= 1;
        true
    }

    // -------------------------------------------------------------- validate

    /// Check every invariant of the structure; the error names the first violation.
    pub fn validate(&self) -> Result<(), &'static str> {
        let mut st = Check::default();
        self.check_page(self.root, None, None, 0, &mut st)?;
        // The DFS met the leaves left to right; the chain must end where it did.
        let last = st.prev_leaf.ok_or("no leaf")?;
        if self.pages[last as usize].right.is_some() {
            return Err("last leaf has a right link");
        }
        if st.entries != self.count {
            return Err("entry count mismatch");
        }
        Ok(())
    }

    fn check_page(
        &self,
        id: PageId,
        low: Option<&Sep>,
        high: Option<&Sep>,
        depth: usize,
        st: &mut Check,
    ) -> Result<(), &'static str> {
        if id as usize >= self.pages.len() || depth >= MAX_HEIGHT {
            return Err("bad page id or depth");
        }
        let p = &self.pages[id as usize];
        // Fence keys: the page's own copy must equal what the parent says.
        // This is what lets a page be verified without looking at its parent.
        if p.low.as_ref() != low || p.high.as_ref() != high {
            return Err("fence key differs from the parent's separator");
        }
        if p.used_bytes() > self.cfg.page_size {
            return Err("page overflows");
        }
        // low < (key, tid): a missing low fence is minus infinity.
        let above_low = |low: Option<&Sep>, key: &[u8], tid: Option<Tid>| {
            low.is_none_or(|l| compare_tuple(&l.key, l.tid, key, tid) == Ordering::Less)
        };
        // (key, tid) <= high (or < if not inclusive): a missing high fence is plus infinity.
        let below_high = |key: &[u8], tid: Option<Tid>, inclusive: bool| {
            high.is_none_or(|h| match compare_tuple(key, tid, &h.key, h.tid) {
                Ordering::Less => true,
                Ordering::Equal => inclusive,
                Ordering::Greater => false,
            })
        };

        if p.is_leaf {
            if *st.leaf_depth.get_or_insert(depth) != depth {
                return Err("leaves at different depths");
            }
            if let Some(prev) = st.prev_leaf
                && self.pages[prev as usize].right != Some(id)
            {
                return Err("leaf chain broken");
            }
            st.prev_leaf = Some(id);

            let mut prev_cell: Option<&LeafCell> = None;
            for c in &p.cells {
                if c.tids.is_empty() || c.key.len() > self.max_key_len() {
                    return Err("bad cell");
                }
                if leaf_cell_size(c.key.len(), c.tids.len()) > self.max_cell() {
                    return Err("cell too large");
                }
                if !c.tids.is_sorted_by(|a, b| a < b) {
                    return Err("posting list not ascending");
                }
                // Strictly ascending in (key, TID) order across cells.
                if let Some(pc) = prev_cell
                    && compare_tuple(&pc.key, pc.tids.last().copied(), &c.key, Some(c.tids[0])) != Ordering::Less
                {
                    return Err("cells out of order");
                }
                // low < every tuple <= high.
                if !above_low(low, &c.key, Some(c.tids[0])) || !below_high(&c.key, c.tids.last().copied(), true) {
                    return Err("tuple outside the fences");
                }
                prev_cell = Some(c);
                st.entries += c.tids.len();
            }
            return Ok(());
        }

        let seps = &p.seps;
        if p.children.len() != seps.len() + 1 || seps.is_empty() {
            return Err("separator / child count mismatch");
        }
        for (i, s) in seps.iter().enumerate() {
            // low < seps[0] < seps[1] < ... < high
            let below = if i == 0 { low } else { Some(&seps[i - 1]) };
            if s.key.len() > self.max_key_len() || !above_low(below, &s.key, s.tid) || !below_high(&s.key, s.tid, false)
            {
                return Err("separators out of order");
            }
        }
        for (i, &child) in p.children.iter().enumerate() {
            let child_low = if i == 0 { low } else { Some(&seps[i - 1]) };
            let child_high = if i == seps.len() { high } else { Some(&seps[i]) };
            self.check_page(child, child_low, child_high, depth + 1, st)?;
        }
        Ok(())
    }

    // ----------------------------------------------------------------- stats

    pub fn stats(&self) -> Stats {
        let mut s = Stats { entries: self.count, ..Stats::default() };
        let mut id = self.root;
        loop {
            s.height += 1;
            let p = &self.pages[id as usize];
            if p.is_leaf {
                break;
            }
            id = p.children[0];
        }
        // Pages are never freed, so every page in the vector is in the tree.
        for p in &self.pages {
            s.used_bytes += p.used_bytes();
            if p.is_leaf {
                s.leaf_pages += 1;
                s.leaf_cells += p.cells.len();
                s.posting_cells += p.cells.iter().filter(|c| c.tids.len() > 1).count();
            } else {
                s.internal_pages += 1;
                s.children += p.children.len();
                s.seps += p.seps.len();
                s.sep_bytes += p
                    .seps
                    .iter()
                    .map(|sep| sep.key.len() + if sep.tid.is_some() { TID_BYTES } else { 0 })
                    .sum::<usize>();
            }
        }
        s
    }
}

/// Posting list split, Postgres style (`_bt_swap_posting`): the new TID takes
/// its sorted place inside the list and the list's largest TID is pushed out,
/// to be inserted as a plain cell right after. The posting list keeps its
/// size, so the caller only ever has to find room for one plain cell.
fn swap_into_posting(tids: &mut Vec<Tid>, pos: usize, tid: Tid) -> Tid {
    let evicted = tids.pop().expect("a posting list is never empty");
    tids.insert(pos, tid);
    evicted
}

#[derive(Default)]
struct Check {
    leaf_depth: Option<usize>,
    prev_leaf: Option<PageId>,
    entries: usize,
}

pub struct RangeIter<'a> {
    tree: &'a Tree,
    page: Option<PageId>,
    cell: usize,
    pos: usize,
    hi: Option<&'a [u8]>, // exclusive upper bound on the key; None = no bound
}

impl<'a> Iterator for RangeIter<'a> {
    type Item = (&'a [u8], Tid);

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let p = &self.tree.pages[self.page? as usize];
            let Some(c) = p.cells.get(self.cell) else {
                // Leaf exhausted (or empty after deletes): follow the chain.
                self.page = p.right;
                self.cell = 0;
                continue;
            };
            if self.hi.is_some_and(|hi| c.key.as_slice() >= hi) {
                self.page = None;
                return None;
            }
            let entry = (c.key.as_slice(), c.tids[self.pos]);
            self.pos += 1;
            if self.pos == c.tids.len() {
                self.pos = 0;
                self.cell += 1;
            }
            return Some(entry);
        }
    }
}
