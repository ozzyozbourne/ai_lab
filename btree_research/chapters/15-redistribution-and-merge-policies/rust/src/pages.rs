//! Chapter 15: redistribution and merge policies on an in-memory page model.
//!
//! The model is deliberately small: one parent page and a row of leaf pages.
//!
//! ```text
//!   parent:  (p0, 40) (p2, 75) right=p1      divider cells + right-most pointer
//!   leaves:  p0: keys <= 40    p2: 40 < keys <= 75    p1: keys > 75
//! ```
//!
//! A leaf holds cells `{key, size}`. Only the byte size matters here, so there
//! is no payload. A page is full when the sizes add up to `capacity` (4096 by
//! default). The parent is not size-limited: how a parent overflows is the
//! same story one level up, and is not what this chapter is about.
//!
//! The parent has the shape of a SQLite/Turso table interior page: each
//! divider cell is `(left child, largest key that may live in that child)`,
//! and the last child hangs off a separate right-most pointer. Dividers are
//! routing information only; they are never part of the cells that get
//! redistributed (turso/core/storage/btree.rs:4622-4630 builds them the same
//! way: left page id + rowid of the last cell on the left page).
//!
//! The central routine is `balance`: flatten up to three adjacent siblings
//! into one array, cut the array into pages again (`pack_left` + `even_out`),
//! write the pages back and replace the dividers. Split, redistribution and
//! merge are that one routine with a different number of output pages.
//!
//! Twin of ../zig/src/pages.zig: same names, same structure, same tests.
use std::fmt::Write as _;

/// One record on a leaf. `size` is its whole footprint on the page in bytes
/// (payload plus slot pointer), which is all a balancing decision looks at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    pub key: u64,
    pub size: u32,
}

/// One cell of the parent: "keys <= `key` live under page `child`".
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Divider {
    pub child: u32,
    pub key: u64,
}

/// Balancing 3 siblings never needs more than 5 output pages (the same bound
/// as MAX_NEW_SIBLING_PAGES_AFTER_BALANCE, turso/core/storage/btree.rs:163).
/// Here it follows from `put` refusing cells larger than a third of a page:
/// every page that `pack_left` closes is then more than 2/3 full, and three
/// pages plus one cell cannot fill five of those.
pub const MAX_OUT_PAGES: usize = 5;

/// What `delete` does when a page gets emptier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MergePolicy {
    /// Do nothing, ever. Empty pages stay in the tree.
    Never,
    /// Unlink a page only when its last cell is gone (the Postgres rule,
    /// minus VACUUM and the two-phase protocol of chapter 24).
    AtEmpty,
    /// Rebalance with the siblings when more than 2/3 of the page is free
    /// (the SQLite/Turso trigger, turso/core/storage/btree.rs:3427-3430).
    BelowThird,
    /// Rebalance as soon as less than half the page is used (textbook).
    BelowHalf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Config {
    pub capacity: u32,
    /// How many adjacent siblings an overflowing page is balanced with.
    /// 1 = plain split of the page alone, 2 = the classic B* pairing, 3 = Turso.
    pub insert_siblings: u8,
    /// Append fast path (`balance_quick`): a cell that overflows the end of
    /// the right-most leaf starts a new leaf of its own.
    pub quick_append: bool,
    pub merge: MergePolicy,
    /// Page budget. Rust's `Vec` aborts when memory runs out, so the
    /// allocation-failure tests of the Zig twin are mirrored by refusing to
    /// hand out more than this many pages (`PutError::OutOfPages`).
    pub max_pages: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            capacity: 4096,
            insert_siblings: 3,
            quick_append: true,
            merge: MergePolicy::BelowThird,
            max_pages: usize::MAX,
        }
    }
}

/// Counters for the "churn" comparison. Only structural work is counted; the
/// one leaf write that every put or delete needs anyway is not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    pub balances: u64,
    pub quick_appends: u64,
    pub pages_allocated: u64,
    pub pages_freed: u64,
    /// Leaf pages whose set of cells was changed by a structural operation.
    pub leaf_writes: u64,
    /// Structural operations that had to rewrite divider cells.
    pub parent_writes: u64,
    /// Cells that ended up on a different page than they were on.
    pub cells_moved: u64,
    /// ... of which onto a page that already existed before the operation.
    /// This is the number Postgres insists on keeping at zero (see README).
    pub cells_moved_to_old: u64,
}

#[derive(Debug, Default)]
pub struct Page {
    pub cells: Vec<Cell>,
    /// Sum of the cell sizes. May exceed `capacity` only between the insert
    /// and the balance inside one `put` ("overfull is represented, not
    /// prevented", like Turso's overflow cells).
    pub used: u32,
    pub live: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PutError {
    CellTooLarge,
    OutOfPages,
}

/// Step 1 of redistribution: cut the flattened cells into as few pages as
/// possible by filling each page from the left.
///
/// Fills `ends`: `ends[p]` is the index one past the last cell of output
/// page p (prefix sums, like `cell_count_per_page_cumulative` in Turso,
/// btree.rs:4200-4284). Always at least one page; only that single page can
/// be empty. `ends` is the caller's scratch buffer and is overwritten.
pub fn pack_left(sizes: &[u32], capacity: u32, ends: &mut Vec<u32>) {
    ends.clear();
    let mut used = 0;
    for (i, &size) in sizes.iter().enumerate() {
        debug_assert!(size <= capacity);
        if used + size > capacity {
            ends.push(i as u32); // close the page before cell i
            used = 0;
        }
        used += size;
    }
    ends.push(sizes.len() as u32);
}

/// Step 2: packing left leaves the last page with whatever was left over,
/// possibly a single cell. Walk the page boundaries from right to left and
/// move cells from the left page to the right page for as long as that does
/// not make the right page the bigger one (btree.rs:4384-4390).
///
/// Only the boundaries move; no page ever gains more than its left neighbour
/// had, so nothing can overflow.
pub fn even_out(sizes: &[u32], ends: &mut [u32]) {
    let sum = |from: u32, to: u32| sizes[from as usize..to as usize].iter().sum::<u32>();
    for k in (1..ends.len()).rev() {
        // boundary between page k-1 (left) and page k (right)
        let left_start = if k >= 2 { ends[k - 2] } else { 0 };
        let mut left_used = sum(left_start, ends[k - 1]);
        let mut right_used = sum(ends[k - 1], ends[k]);
        // The left page always keeps at least one cell.
        while ends[k - 1] > left_start + 1 {
            let c = sizes[ends[k - 1] as usize - 1]; // last cell of the left page
            if right_used != 0 && right_used + c > left_used - c {
                break;
            }
            ends[k - 1] -= 1;
            left_used -= c;
            right_used += c;
        }
    }
}

/// Scratch memory for one `balance` call: the flattened cell array and the
/// boundaries. The Zig twin uses an arena that is reset after every call;
/// the Rust idiom for "reset but keep the buffer" is `Vec::clear`.
#[derive(Debug, Default)]
struct Scratch {
    flat: Vec<Cell>,
    from: Vec<u32>,
    sizes: Vec<u32>,
    ends: Vec<u32>,
}

#[derive(Debug)]
pub struct Tree {
    scratch: Scratch,
    pub cfg: Config,
    /// Page table indexed by page id; freed pages stay as dead slots.
    pages: Vec<Page>,
    /// Free list of page ids.
    free_ids: Vec<u32>,
    /// The parent page: divider cells in key order, plus the right-most child.
    dividers: Vec<Divider>,
    rightmost: u32,
    pub count: usize,
    pub stats: Stats,
}

impl Tree {
    pub fn new(cfg: Config) -> Tree {
        assert!(cfg.capacity >= 4 && (1..=3).contains(&cfg.insert_siblings) && cfg.max_pages >= 1);
        // An empty tree is one empty leaf.
        Tree {
            scratch: Scratch::default(),
            cfg,
            pages: vec![Page { live: true, ..Page::default() }],
            free_ids: Vec::new(),
            dividers: Vec::new(),
            rightmost: 0,
            count: 0,
            stats: Stats::default(),
        }
    }

    // ---- page table -----------------------------------------------------

    fn alloc_page(&mut self) -> Result<u32, PutError> {
        if self.child_count() >= self.cfg.max_pages {
            return Err(PutError::OutOfPages);
        }
        self.stats.pages_allocated += 1;
        if let Some(id) = self.free_ids.pop() {
            self.pages[id as usize].live = true;
            return Ok(id);
        }
        self.pages.push(Page { live: true, ..Page::default() });
        Ok(self.pages.len() as u32 - 1)
    }

    fn free_page(&mut self, id: u32) {
        let page = &mut self.pages[id as usize];
        page.cells.clear(); // keep the buffer, like a real page frame
        page.used = 0;
        page.live = false;
        self.free_ids.push(id);
        self.stats.pages_freed += 1;
    }

    // ---- parent ---------------------------------------------------------

    pub fn child_count(&self) -> usize {
        self.dividers.len() + 1
    }

    /// Page id of the i-th child, left to right.
    pub fn child_at(&self, i: usize) -> u32 {
        self.dividers.get(i).map_or(self.rightmost, |d| d.child)
    }

    /// Index of the child whose key range contains `key`: the first divider
    /// with divider.key >= key, else the right-most child.
    fn find_child(&self, key: u64) -> usize {
        self.dividers.partition_point(|d| d.key < key)
    }

    fn leaf(&self, ci: usize) -> &Page {
        &self.pages[self.child_at(ci) as usize]
    }

    pub fn used_bytes(&self) -> u64 {
        (0..self.child_count()).map(|ci| u64::from(self.leaf(ci).used)).sum()
    }

    /// Average fill of the leaves in tenths of a percent (integers only, so
    /// Zig and Rust print the same digits).
    pub fn fill_permille(&self) -> u64 {
        self.used_bytes() * 1000 / (self.child_count() as u64 * u64::from(self.cfg.capacity))
    }

    // ---- operations -----------------------------------------------------

    /// Size of the cell stored under `key`.
    pub fn get(&self, key: u64) -> Option<u32> {
        let cells = &self.leaf(self.find_child(key)).cells;
        let pos = cells.partition_point(|c| c.key < key);
        cells.get(pos).filter(|c| c.key == key).map(|c| c.size)
    }

    /// Insert a cell, or replace the size of an existing one. On any error
    /// the tree is exactly as it was before the call.
    pub fn put(&mut self, key: u64, size: u32) -> Result<(), PutError> {
        // A third of a page at most, so that every page can hold several
        // cells and three siblings plus one cell fit in five pages.
        if size == 0 || size > self.cfg.capacity / 3 {
            return Err(PutError::CellTooLarge);
        }
        let ci = self.find_child(key);
        let id = self.child_at(ci) as usize;
        let page = &mut self.pages[id];
        let pos = page.cells.partition_point(|c| c.key < key);
        let existing = page.cells.get(pos).is_some_and(|c| c.key == key);
        let old_size = if existing { page.cells[pos].size } else { 0 };
        if existing {
            page.cells[pos].size = size;
        } else {
            page.cells.insert(pos, Cell { key, size });
            self.count += 1;
        }
        page.used = page.used - old_size + size;
        if page.used <= self.cfg.capacity {
            return Ok(());
        }

        // The page is overfull. Unlike underflow, this MUST be repaired
        // before returning, so a failed repair undoes the insert.
        let saved_stats = self.stats;
        let appended = !existing && pos == page.cells.len() - 1;
        if let Err(err) = self.fix_overflow(ci, appended) {
            // Nothing structural was committed (balance reserves first,
            // then mutates), so `id` and `pos` are still right.
            let undo = &mut self.pages[id];
            if existing {
                undo.cells[pos].size = old_size;
            } else {
                undo.cells.remove(pos);
                self.count -= 1;
            }
            undo.used = undo.used - size + old_size;
            self.stats = saved_stats;
            return Err(err);
        }
        Ok(())
    }

    fn fix_overflow(&mut self, ci: usize, appended: bool) -> Result<(), PutError> {
        // Turso's conditions for the fast path (btree.rs:3460-3492): the
        // overflowing cell is the last cell of the right-most leaf.
        if self.cfg.quick_append && appended && ci == self.child_count() - 1 {
            return self.quick_append();
        }
        self.balance(ci, usize::from(self.cfg.insert_siblings))
    }

    /// Append fast path (Turso `balance_quick`, btree.rs:3526-3600): do not
    /// look at any sibling, do not move any existing cell. The new cell gets
    /// a fresh right-most leaf to itself and the old leaf stays 100% full.
    fn quick_append(&mut self) -> Result<(), PutError> {
        let old_id = self.rightmost;
        let new_id = self.alloc_page()?;
        // Everything below cannot fail.
        let old = &mut self.pages[old_id as usize];
        let cell = old.cells.pop().expect("an overfull page has cells");
        old.used -= cell.size;
        let divider_key = old.cells.last().expect("cells are at most a third of a page").key;
        let new = &mut self.pages[new_id as usize];
        new.cells.push(cell);
        new.used = cell.size;
        // New divider: (old leaf, largest key left on it); the right-most
        // pointer now names the new leaf.
        self.dividers.push(Divider { child: old_id, key: divider_key });
        self.rightmost = new_id;
        self.stats.quick_appends += 1;
        self.stats.leaf_writes += 1;
        self.stats.parent_writes += 1;
        Ok(())
    }

    /// Remove `key`. Returns whether it was present. Never fails: repairing
    /// an underfull page is optional, so if the repair cannot be done the
    /// tree is simply left as it is (still valid, a little emptier).
    pub fn delete(&mut self, key: u64) -> bool {
        let ci = self.find_child(key);
        let id = self.child_at(ci) as usize;
        let page = &mut self.pages[id];
        let pos = page.cells.partition_point(|c| c.key < key);
        if page.cells.get(pos).is_none_or(|c| c.key != key) {
            return false;
        }
        page.used -= page.cells.remove(pos).size;
        self.count -= 1;
        // Note: the divider above this page may now be larger than every key
        // on it (a stale separator). That is fine: it is still an upper bound.
        if self.child_count() == 1 {
            return true; // a lone leaf has nobody to merge with
        }

        let cap = u64::from(self.cfg.capacity);
        let used = u64::from(self.pages[id].used);
        let wants_balance = match self.cfg.merge {
            MergePolicy::Never => return true,
            MergePolicy::AtEmpty => false,
            MergePolicy::BelowThird => (cap - used) * 3 > cap * 2,
            MergePolicy::BelowHalf => used * 2 < cap,
        };
        if wants_balance {
            let saved_stats = self.stats;
            if self.balance(ci, 3).is_ok() {
                return true;
            }
            self.stats = saved_stats;
        }
        // An empty page must not stay (only `Never` tolerates it).
        if used == 0 {
            self.remove_empty(ci);
        }
        true
    }

    /// Unlink the empty child `ci`. Needs no memory and moves no cell.
    /// Dropping divider `ci` hands the page's key range to its RIGHT
    /// neighbour (the same trick as Postgres `_bt_mark_page_halfdead`); only
    /// the right-most child gives its range to the left instead.
    fn remove_empty(&mut self, ci: usize) {
        let id = self.child_at(ci);
        if ci < self.dividers.len() {
            self.dividers.remove(ci);
        } else {
            self.rightmost = self.dividers.pop().expect("more than one child").child;
        }
        self.free_page(id);
        self.stats.parent_writes += 1;
    }

    /// The one routine: balance child `ci` together with its neighbours, up
    /// to `window` siblings in total. Depending on how many pages the cells
    /// need afterwards this is a split (more pages), a redistribution (same
    /// number) or a merge (fewer).
    ///
    /// Everything that can fail happens before the first mutation, so on
    /// error the tree is untouched.
    fn balance(&mut self, ci: usize, window: usize) -> Result<(), PutError> {
        // Borrow the scratch buffers out of `self` for the duration of the
        // call and hand them back (with their capacity) on every exit path.
        let mut scratch = std::mem::take(&mut self.scratch);
        let result = self.balance_with(&mut scratch, ci, window);
        self.scratch = scratch;
        result
    }

    fn balance_with(&mut self, scratch: &mut Scratch, ci: usize, window: usize) -> Result<(), PutError> {
        let Scratch { flat, from, sizes, ends } = scratch;
        flat.clear();
        from.clear();
        sizes.clear();

        // 1. Pick the siblings: the page itself, then its left and right
        //    neighbours; at the edges take the first or last `window`
        //    children (btree.rs:3693-3713).
        let n = self.child_count();
        let cnt = window.min(n);
        let start = ci.saturating_sub(window / 2).min(n - cnt);
        let mut old_ids = [0u32; 3];
        let mut old_ends = [0u32; 3];

        // 2. Flatten: copy every cell of the siblings into one array, in key
        //    order. `from` remembers where each cell came from, `sizes` is
        //    all the redistribution maths needs.
        for s in 0..cnt {
            let id = self.child_at(start + s);
            old_ids[s] = id;
            for &cell in &self.pages[id as usize].cells {
                flat.push(cell);
                from.push(id);
                sizes.push(cell.size);
            }
            old_ends[s] = flat.len() as u32;
        }

        // 3. Decide the new page boundaries. Pure arithmetic on `sizes`.
        pack_left(sizes, self.cfg.capacity, ends);
        even_out(sizes, ends);
        let new_cnt = ends.len();
        debug_assert!(new_cnt <= MAX_OUT_PAGES);
        if ends[..] == old_ends[..cnt] {
            return Ok(()); // already as good as it gets
        }

        // 4. Reserve everything the commit needs: the extra pages.
        let reused = cnt.min(new_cnt);
        let mut ids = [0u32; MAX_OUT_PAGES];
        ids[..reused].copy_from_slice(&old_ids[..reused]); // old pages are reused in order
        if n - cnt + new_cnt > self.cfg.max_pages {
            return Err(PutError::OutOfPages);
        }
        for id in &mut ids[reused..new_cnt] {
            *id = self.alloc_page().expect("the budget was checked above");
        }

        // 5. Commit. Nothing below can fail.
        for p in 0..new_cnt {
            let id = ids[p];
            let first = if p == 0 { 0 } else { ends[p - 1] };
            let old_first = if p == 0 || p >= cnt { 0 } else { old_ends[p - 1] };
            let changed = p >= cnt || first != old_first || ends[p] != old_ends[p];
            if changed {
                self.stats.leaf_writes += 1;
            }
            let span = first as usize..ends[p] as usize;
            for &origin in &from[span.clone()] {
                if origin != id {
                    self.stats.cells_moved += 1;
                    if p < cnt {
                        self.stats.cells_moved_to_old += 1;
                    }
                }
            }
            let page = &mut self.pages[id as usize];
            page.cells.clear();
            page.cells.extend_from_slice(&flat[span.clone()]);
            page.used = sizes[span].iter().sum();
        }
        for &id in &old_ids[reused..cnt] {
            self.free_page(id);
        }

        // New dividers: every output page except the last is bounded by the
        // largest key it now holds. The last one keeps the upper bound the
        // old last sibling had (its old divider, or none if it is right-most).
        // The last sibling may hang off the right-most pointer instead of
        // owning a divider cell.
        let last_is_right = start + cnt == n;
        let old_div = if last_is_right { cnt - 1 } else { cnt };
        let new_div = if last_is_right { new_cnt - 1 } else { new_cnt };
        let mut new_dividers = [Divider { child: 0, key: 0 }; MAX_OUT_PAGES];
        for p in 0..new_div {
            let key = if p + 1 < new_cnt { flat[ends[p] as usize - 1].key } else { self.dividers[start + cnt - 1].key };
            new_dividers[p] = Divider { child: ids[p], key };
        }
        self.dividers.splice(start..start + old_div, new_dividers[..new_div].iter().copied());
        if last_is_right {
            self.rightmost = ids[new_cnt - 1];
        }
        self.stats.balances += 1;
        self.stats.parent_writes += 1;
        Ok(())
    }

    /// Append every cell with lo <= key < hi to `out`, in key order.
    pub fn range(&self, lo: u64, hi: u64, out: &mut Vec<Cell>) {
        if lo >= hi {
            return;
        }
        // Without sibling links the scan walks the parent, child by child.
        for ci in self.find_child(lo)..self.child_count() {
            for &cell in &self.leaf(ci).cells {
                if cell.key >= hi {
                    return;
                }
                if cell.key >= lo {
                    out.push(cell);
                }
            }
        }
    }

    /// Check every invariant of the model. Being underfull is NOT a
    /// violation: minimum fill is a policy, not an invariant.
    pub fn validate(&self) -> Result<(), &'static str> {
        let live = self.pages.iter().filter(|p| p.live).count();
        // Every live page is reachable exactly once, the rest is on the free list.
        if live != self.child_count() {
            return Err("live pages != children");
        }
        if self.free_ids.len() != self.pages.len() - live
            || self.free_ids.iter().any(|&id| self.pages[id as usize].live)
        {
            return Err("free list does not match the dead pages");
        }
        let mut cells_seen = 0;
        let mut lower: Option<u64> = None; // exclusive lower bound of the current child
        for ci in 0..self.child_count() {
            let page = self.leaf(ci);
            if !page.live {
                return Err("child is a freed page");
            }
            let upper = self.dividers.get(ci).map(|d| d.key);
            // Dividers strictly increase, so key ranges do not overlap.
            if let (Some(lo), Some(hi)) = (lower, upper)
                && hi <= lo
            {
                return Err("dividers not increasing");
            }
            let mut used = 0;
            let mut prev = lower;
            for cell in &page.cells {
                if prev.is_some_and(|p| cell.key <= p) {
                    return Err("cells not sorted or below the lower bound");
                }
                if upper.is_some_and(|u| cell.key > u) {
                    return Err("cell above its divider");
                }
                prev = Some(cell.key);
                used += cell.size;
            }
            if used != page.used || used > self.cfg.capacity {
                return Err("page size wrong or over capacity");
            }
            if used == 0 && self.cfg.merge != MergePolicy::Never && self.child_count() > 1 {
                return Err("empty page left in the tree");
            }
            cells_seen += page.cells.len();
            lower = upper;
        }
        if cells_seen != self.count {
            return Err("cell count wrong");
        }
        Ok(())
    }

    /// Text picture of the tree, used by the fixed scenario and by the
    /// visualization's self-test.
    pub fn dump(&self, w: &mut String) {
        w.push_str("parent:");
        for d in &self.dividers {
            write!(w, " (p{}, {})", d.child, d.key).unwrap();
        }
        writeln!(w, " right=p{}", self.rightmost).unwrap();
        for ci in 0..self.child_count() {
            let page = self.leaf(ci);
            write!(w, "  p{} {:>3}/{}:", self.child_at(ci), page.used, self.cfg.capacity).unwrap();
            for cell in &page.cells {
                write!(w, " {}:{}", cell.key, cell.size).unwrap();
            }
            w.push('\n');
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::{self, Op, OpStream, Oracle};
    use crate::prng::SplitMix64;

    fn cfg100() -> Config {
        Config { capacity: 100, ..Config::default() }
    }

    fn redistribute(sizes: &[u32], capacity: u32) -> Vec<u32> {
        let mut ends = Vec::new();
        pack_left(sizes, capacity, &mut ends);
        even_out(sizes, &mut ends);
        ends
    }

    #[test]
    fn pack_left_fills_pages_from_the_left_even_out_balances_right_to_left() {
        let sizes = [30, 30, 30, 30, 30, 30, 20]; // 200 bytes, capacity 100
        let mut ends = Vec::new();
        pack_left(&sizes, 100, &mut ends);
        assert_eq!(ends, [3, 6, 7]); // 90 | 90 | 20
        even_out(&sizes, &mut ends);
        // One cell moves right (60 | 50); a second would make the right page the
        // bigger one. The first boundary stays: 90 vs 60 cannot be improved.
        assert_eq!(ends, [3, 5, 7]);
    }

    #[test]
    fn redistribute_edge_cases() {
        // No cells at all: one empty page.
        assert_eq!(redistribute(&[], 100), [0]);
        // Everything fits one page: a merge.
        assert_eq!(redistribute(&[30, 30, 40], 100), [3]);
        // A lone leftover cell pulls cells over from its left neighbour.
        assert_eq!(redistribute(&[25, 25, 25, 25, 10], 100), [3, 5]);
        // One big cell per page: nothing to even out, left pages keep >= 1 cell.
        assert_eq!(redistribute(&[90, 90, 90], 100), [1, 2, 3]);
    }

    #[test]
    fn redistribute_every_page_fits_and_no_page_is_empty_random_sizes() {
        let mut rng = SplitMix64::new(15);
        for _ in 0..500 {
            let n = rng.range(1, 65) as usize;
            let sizes: Vec<u32> = (0..n).map(|_| rng.range(1, 26) as u32).collect();
            let ends = redistribute(&sizes, 100);
            let mut first = 0;
            for &end in &ends {
                assert!(end > first);
                assert!(sizes[first as usize..end as usize].iter().sum::<u32>() <= 100);
                first = end;
            }
            assert_eq!(n, first as usize);
            // Minimal page count: greedy packing is optimal for contiguous cuts.
            assert!(sizes.iter().sum::<u32>().div_ceil(100) as usize <= ends.len());
        }
    }

    fn dump(tree: &Tree) -> String {
        let mut s = String::new();
        tree.dump(&mut s);
        s
    }

    #[test]
    fn split_redistribution_and_merge_are_one_routine() {
        let mut tree = Tree::new(Config { quick_append: false, ..cfg100() });
        for k in [10, 20, 30, 40] {
            tree.put(k, 25).unwrap();
        }
        tree.put(50, 25).unwrap(); // overflow with no sibling: 1 page in, 2 out
        assert_eq!(
            dump(&tree),
            "parent: (p0, 30) right=p1\n  p0  75/100: 10:25 20:25 30:25\n  p1  50/100: 40:25 50:25\n"
        );
        tree.put(5, 25).unwrap();
        tree.put(15, 25).unwrap(); // p0 overflows, p1 has room: 2 in, 2 out, no new page
        assert_eq!(
            dump(&tree),
            "parent: (p0, 20) right=p1\n  p0 100/100: 5:25 10:25 15:25 20:25\n  p1  75/100: 30:25 40:25 50:25\n"
        );
        assert_eq!(tree.stats.balances, 2);
        assert_eq!(tree.stats.pages_allocated, 1);
        assert_eq!(tree.stats.cells_moved_to_old, 1); // key 30 crossed an existing boundary
        // Deleting until p1 is more than 2/3 free pulls the siblings together.
        assert!(tree.delete(40));
        assert!(tree.delete(50)); // p1 = 25 bytes; 125 bytes in total still need 2 pages
        assert_eq!(
            dump(&tree),
            "parent: (p0, 15) right=p1\n  p0  75/100: 5:25 10:25 15:25\n  p1  50/100: 20:25 30:25\n"
        );
        assert!(tree.delete(5));
        assert!(tree.delete(20)); // p1 = 25 bytes again; now 75 bytes fit one page
        assert_eq!(dump(&tree), "parent: right=p0\n  p0  75/100: 10:25 15:25 30:25\n");
        assert_eq!(tree.stats.pages_freed, 1);
        tree.validate().unwrap();
    }

    #[test]
    fn quick_append_leaves_the_old_rightmost_leaf_full_and_moves_nothing() {
        let mut tree = Tree::new(cfg100());
        for k in 1..10 {
            tree.put(k, 25).unwrap();
        }
        assert_eq!(
            dump(&tree),
            "parent: (p0, 4) (p1, 8) right=p2\n  p0 100/100: 1:25 2:25 3:25 4:25\n  p1 100/100: 5:25 6:25 7:25 8:25\n  p2  25/100: 9:25\n"
        );
        assert_eq!(tree.stats.quick_appends, 2);
        assert_eq!(tree.stats.balances, 0);
        assert_eq!(tree.stats.cells_moved, 0);
        // A key that overflows the right-most leaf but is not its last cell
        // does not qualify.
        for k in [20, 30, 40] {
            tree.put(k, 25).unwrap();
        }
        tree.put(15, 25).unwrap();
        assert_eq!(tree.stats.quick_appends, 2);
        assert_eq!(tree.stats.balances, 1);
        tree.validate().unwrap();
    }

    const POLICIES: [MergePolicy; 4] =
        [MergePolicy::Never, MergePolicy::AtEmpty, MergePolicy::BelowThird, MergePolicy::BelowHalf];

    #[test]
    fn merge_policies_on_the_same_deletes() {
        for (policy, expected) in POLICIES.into_iter().zip([4, 2, 1, 1]) {
            let mut tree = Tree::new(Config { merge: policy, ..cfg100() });
            for k in 1..17 {
                tree.put(k, 25).unwrap(); // four full leaves
            }
            // Empty the two middle leaves, leave one cell in each outer leaf.
            for k in 2..16 {
                assert!(tree.delete(k));
            }
            assert_eq!(tree.child_count(), expected);
            assert_eq!(tree.count, 2);
            assert_eq!(tree.get(1), Some(25));
            assert_eq!(tree.get(16), Some(25));
            tree.validate().unwrap();
            // Only the rebalancing policies ever move a cell onto another page.
            let moved = tree.stats.cells_moved_to_old != 0;
            assert_eq!(moved, matches!(policy, MergePolicy::BelowThird | MergePolicy::BelowHalf));
        }
    }

    #[test]
    fn put_rejects_oversized_cells_and_overwrites_in_place() {
        let mut tree = Tree::new(cfg100());
        assert_eq!(tree.put(1, 34), Err(PutError::CellTooLarge));
        assert_eq!(tree.put(1, 0), Err(PutError::CellTooLarge));
        tree.put(1, 10).unwrap();
        tree.put(1, 20).unwrap(); // overwrite: still one cell
        assert_eq!(tree.count, 1);
        assert_eq!(tree.get(1), Some(20));
        assert_eq!(tree.get(2), None);
        assert!(!tree.delete(2));
        // An overwrite that grows a cell can overflow the page too.
        for k in 2..6 {
            tree.put(k, 20).unwrap();
        }
        tree.put(3, 25).unwrap();
        assert_eq!(tree.child_count(), 2);
        tree.validate().unwrap();
    }

    fn cell_size_for(value: u64) -> u32 {
        (1 + value % 25) as u32 // 1..25 bytes on a 100-byte page
    }

    fn model_test(cfg: Config, seed: u64) {
        let mut tree = Tree::new(cfg);
        let mut oracle = Oracle::new();
        let mut got = Vec::new();
        let stream = OpStream::new(ops::Config { seed, count: 6000, key_space: 300, weights: ops::Weights::default() });
        for op in stream {
            match op {
                Op::Put { key, value } => {
                    tree.put(key, cell_size_for(value)).unwrap();
                    oracle.put(key, u64::from(cell_size_for(value)));
                }
                Op::Delete { key } => assert_eq!(oracle.delete(key).is_some(), tree.delete(key)),
                Op::Get { key } => assert_eq!(oracle.get(key), tree.get(key).map(u64::from)),
                Op::Range { lo, hi } => {
                    got.clear();
                    tree.range(lo, hi, &mut got);
                    let want = oracle.range(lo, hi);
                    assert_eq!(want.len(), got.len());
                    for (w, g) in want.iter().zip(&got) {
                        assert_eq!((w.key, w.value), (g.key, u64::from(g.size)));
                    }
                }
            }
            tree.validate().unwrap();
            assert_eq!(oracle.len(), tree.count);
        }
    }

    #[test]
    fn model_test_against_the_oracle_every_policy_combination() {
        let mut seed = 1;
        for merge in POLICIES {
            for insert_siblings in [1, 2, 3] {
                for quick_append in [false, true] {
                    model_test(Config { insert_siblings, quick_append, merge, ..cfg100() }, seed);
                    seed += 1;
                }
            }
        }
    }

    /// Mirror of the Zig allocation-failure tests: with every possible page
    /// budget, a run of puts either succeeds or stops with OutOfPages, and
    /// the tree is valid and unchanged by the failed put.
    #[test]
    fn running_out_of_pages_at_every_point_of_a_run_of_puts() {
        for insert_siblings in [1, 2, 3] {
            let mut failures = 0;
            for max_pages in 1..40 {
                let mut tree = Tree::new(Config { insert_siblings, merge: MergePolicy::Never, max_pages, ..cfg100() });
                let mut rng = SplitMix64::new(99);
                let puts = (0..60).map(|_| (rng.below(80), rng.range(5, 26) as u32)).collect::<Vec<_>>();
                for (key, size) in puts.into_iter().chain((100..110).map(|k| (k, 25))) {
                    let before = (dump(&tree), tree.stats, tree.count);
                    if let Err(err) = tree.put(key, size) {
                        assert_eq!(err, PutError::OutOfPages);
                        assert_eq!(before, (dump(&tree), tree.stats, tree.count));
                        failures += 1;
                        break;
                    }
                    tree.validate().unwrap();
                    assert!(tree.child_count() <= max_pages);
                }
                tree.validate().unwrap();
            }
            assert!(failures > 5);
        }
    }

    #[test]
    fn a_failed_put_leaves_the_tree_exactly_as_it_was_a_merge_needs_no_new_page() {
        let mut tree = Tree::new(Config { quick_append: false, max_pages: 1, ..cfg100() });
        for k in 1..5 {
            tree.put(k * 10, 25).unwrap(); // one full leaf
        }
        let before = dump(&tree);
        assert_eq!(tree.put(25, 25), Err(PutError::OutOfPages));
        assert_eq!(dump(&tree), before);
        assert_eq!(tree.stats, Stats::default());
        assert_eq!(tree.count, 4);
        tree.validate().unwrap();

        tree.cfg.max_pages = 2;
        tree.put(25, 25).unwrap();
        assert_eq!(tree.child_count(), 2); // p0: 10 20 25, p1: 30 40
        // Underflow repair never needs a new page (the cells already fit in
        // the pages they are on), so the budget cannot get in its way.
        for k in 41..91 {
            tree.put(k, 1).unwrap();
        }
        assert!(tree.delete(30));
        assert!(tree.delete(40)); // p0: 75 bytes, p1: fifty 1-byte cells
        let balances = tree.stats.balances;
        for k in 41..67 {
            assert!(tree.delete(k)); // at 25 bytes on p1 everything fits one page
        }
        assert_eq!(tree.stats.balances, balances + 1);
        assert_eq!(tree.child_count(), 1);
        tree.validate().unwrap();
    }
}
