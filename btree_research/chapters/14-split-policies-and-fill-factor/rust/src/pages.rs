//! Chapter 14: a deliberately small page model to try split policies on.
//!
//! There is no pager and there are no bytes: a leaf page is a sorted list of
//! cells that only remember how many bytes they WOULD occupy, and the whole
//! upper part of the tree is flattened into one sorted "directory" of
//! separators. That is enough to measure what a split policy does to space:
//! how many pages, how full, and how large the separators.
//!
//!   directory:  [ -inf -> leaf 0 | (20) -> leaf 2 | (20,7) -> leaf 1 | ... ]
//!   leaves:       cells sorted by (key, tid), used <= capacity
//!
//! Invariants (checked by `validate`):
//!   I1  directory separators are strictly ascending
//!   I2  every cell of the page behind entry i is >= entry i's separator and
//!       < entry i+1's separator
//!   I3  cells inside a page are strictly ascending by (key, tid)
//!   I4  used == sum of cell sizes, and used <= capacity
//!   I5  len == number of cells in all pages

use crate::split::{self, Candidate, Cell, PageInfo, Policy};

/// Lower bound of a page, stored in the directory.
///
/// `tid == None` is a TRUNCATED separator: it compares below every cell with
/// the same key, which is only correct if the page to its left holds no cell
/// with that key. A cut between two different keys can therefore store the
/// bare key (8 bytes); a cut inside a run of equal keys has to keep the tid
/// as well (16 bytes). This is the model's version of suffix truncation.
///
/// The derived ordering is exactly the one we need: by key, then None before
/// Some, then by tid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Sep {
    pub key: u64,
    pub tid: Option<u64>,
}

impl Sep {
    pub fn bytes(self) -> u32 {
        if self.tid.is_none() { 8 } else { 16 }
    }

    /// separator <= (key, tid)?
    fn at_or_below(self, key: u64, tid: u64) -> bool {
        self <= Sep {
            key,
            tid: Some(tid),
        }
    }
}

#[derive(Debug, Default)]
pub struct Leaf {
    pub cells: Vec<Cell>,
    pub used: u32,
}

#[derive(Debug, Clone, Copy)]
pub struct DirEntry {
    /// None only for the first entry: its lower bound is minus infinity.
    pub low: Option<Sep>,
    /// Index into `Tree::leaves`. Page numbers are handed out in creation
    /// order, so they say nothing about key order; only the directory does.
    pub leaf: u32,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Stats {
    pub splits: u64,
    /// Indexed by `Strategy as usize`.
    pub by_strategy: [u64; 3],
    /// Cells copied into a new right page by splits ("churn").
    pub cells_moved: u64,
}

/// A snapshot of how full the pages are.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Fill {
    pub pages: u32,
    pub used_bytes: u64,
    pub min_used: u32,
    /// histogram[b] = pages whose fill is in [b*10 %, b*10+10 %); 100% is in
    /// the last bucket.
    pub histogram: [u32; 10],
    pub sep_bytes: u64,
    /// Separators that could not be truncated to the bare key.
    pub tid_seps: u32,
}

impl Fill {
    /// Average fill in tenths of a percent (integer, so no float printing).
    pub fn avg_permille(&self, capacity: u32) -> u64 {
        self.used_bytes * 1000 / (u64::from(self.pages) * u64::from(capacity))
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct RangeSum {
    pub cells: u64,
    pub bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PutError {
    BadCellSize,
    /// The page budget is used up. This mirrors Zig's `error.OutOfMemory`:
    /// Rust's `Vec` aborts instead of returning an allocation error, so the
    /// failure path is modelled with an explicit limit.
    OutOfPages,
}

/// Smallest page `Tree::new` accepts: the smallest capacity whose
/// `max_cell_size` (a quarter of the page) is not zero.
pub const MIN_CAPACITY: u32 = 4;

pub struct Tree {
    pub capacity: u32,
    pub policy: Policy,
    /// Long-lived memory: the pages and the directory.
    pub leaves: Vec<Leaf>,
    pub dir: Vec<DirEntry>,
    pub len: usize,
    pub stats: Stats,
    /// Refuse to create more than this many pages (None = unlimited).
    pub page_budget: Option<usize>,
    /// Short-lived memory, reused by every split: the imaginary page and the
    /// candidate list. `clear()` keeps the buffers, like an arena reset that
    /// retains capacity; see `split_and_insert`.
    scratch_items: Vec<Cell>,
    scratch_cands: Vec<Candidate>,
}

impl Tree {
    /// `capacity` must be at least 4 bytes: below that `max_cell_size` is 0,
    /// so no cell could ever be stored, and a capacity of 0 would make every
    /// fill percentage a division by zero. Passing less is a programming
    /// error (asserted), not a runtime condition.
    pub fn new(capacity: u32, policy: Policy) -> Tree {
        assert!(capacity >= MIN_CAPACITY, "capacity must be at least 4");
        Tree {
            capacity,
            policy,
            // A tree always has at least one (possibly empty) page.
            leaves: vec![Leaf::default()],
            dir: vec![DirEntry { low: None, leaf: 0 }],
            len: 0,
            stats: Stats::default(),
            page_budget: None,
            scratch_items: Vec::new(),
            scratch_cands: Vec::new(),
        }
    }

    /// Largest cell `put` accepts. With cells this small an overfull page can
    /// always be cut into two pages that both fit (total <= 1.25 * capacity).
    pub fn max_cell_size(&self) -> u32 {
        self.capacity / 4
    }

    /// Directory position of the page that must contain (key, tid): the last
    /// entry whose separator is <= (key, tid). Binary search over I1.
    fn find_dir(&self, key: u64, tid: u64) -> usize {
        // Entry 0 has no separator and always qualifies.
        self.dir[1..].partition_point(|e| {
            e.low
                .expect("only entry 0 has no separator")
                .at_or_below(key, tid)
        })
    }

    /// First index in `cells` that is not less than (key, tid).
    fn lower_bound(cells: &[Cell], key: u64, tid: u64) -> usize {
        cells.partition_point(|c| (c.key, c.tid) < (key, tid))
    }

    /// Size of the cell (key, tid), or None.
    pub fn get(&self, key: u64, tid: u64) -> Option<u16> {
        let leaf = &self.leaves[self.dir[self.find_dir(key, tid)].leaf as usize];
        let c = leaf.cells.get(Self::lower_bound(&leaf.cells, key, tid))?;
        (c.key == key && c.tid == tid).then_some(c.size)
    }

    /// Insert a cell of `size` bytes. Returns Ok(false) (and changes nothing)
    /// if (key, tid) is already present. On error the tree is unchanged.
    pub fn put(&mut self, key: u64, tid: u64, size: u16) -> Result<bool, PutError> {
        if size == 0 || u32::from(size) > self.max_cell_size() {
            return Err(PutError::BadCellSize);
        }
        let d = self.find_dir(key, tid);
        let leaf = &mut self.leaves[self.dir[d].leaf as usize];
        let i = Self::lower_bound(&leaf.cells, key, tid);
        if leaf
            .cells
            .get(i)
            .is_some_and(|c| c.key == key && c.tid == tid)
        {
            return Ok(false);
        }
        let cell = Cell { key, tid, size };
        if leaf.used + u32::from(size) <= self.capacity {
            leaf.cells.insert(i, cell);
            leaf.used += u32::from(size);
        } else {
            self.split_and_insert(d, i, cell)?;
        }
        self.len += 1;
        Ok(true)
    }

    /// The page behind directory entry `d` cannot take `cell` at index `i`.
    /// Ask the policy where to cut, then move the right part to a new page.
    fn split_and_insert(&mut self, d: usize, i: usize, cell: Cell) -> Result<(), PutError> {
        // Check the budget BEFORE touching the tree, so that a failure leaves
        // it exactly as it was (Zig reserves its memory at the same point).
        if self
            .page_budget
            .is_some_and(|budget| self.leaves.len() >= budget)
        {
            return Err(PutError::OutOfPages);
        }
        let left_id = self.dir[d].leaf as usize;

        // The "imaginary page" of nbtsplitloc.c: the old cells with the new
        // one already in place. It is larger than a page, which is exactly
        // why it lives in scratch memory and not in a page. Taking the Vec
        // out of `self` lets us borrow it and the tree at the same time; it
        // goes back, emptied but with its buffer, at the end.
        let mut items = std::mem::take(&mut self.scratch_items);
        items.clear();
        items.extend_from_slice(&self.leaves[left_id].cells);
        items.insert(i, cell);

        let upper_key = self
            .dir
            .get(d + 1)
            .map(|e| e.low.expect("only entry 0 has no separator").key);
        let page = PageInfo {
            capacity: self.capacity,
            upper_key,
        };
        let choice = split::choose_split(&mut self.scratch_cands, &items, i, page, self.policy);
        let fr = choice.first_right as usize;

        let right = Leaf {
            cells: items[fr..].to_vec(),
            used: choice.right_bytes,
        };

        // The left page keeps its buffer. It never needs to grow: the right
        // page takes at least one cell, so at most the old count remains.
        let left = &mut self.leaves[left_id];
        left.cells.clear();
        left.cells.extend_from_slice(&items[..fr]);
        left.used = choice.left_bytes;

        // The separator is the lower bound of the right page. Truncate it to
        // the bare key when the last cell on the left has a different key.
        let first_right = items[fr];
        let sep = Sep {
            key: first_right.key,
            tid: (choice.penalty != 1).then_some(first_right.tid),
        };
        let right_id = self.leaves.len() as u32;
        self.leaves.push(right);
        self.dir.insert(
            d + 1,
            DirEntry {
                low: Some(sep),
                leaf: right_id,
            },
        );

        self.stats.splits += 1;
        self.stats.by_strategy[choice.strategy as usize] += 1;
        self.stats.cells_moved += (items.len() - fr) as u64;

        self.scratch_items = items;
        Ok(())
    }

    /// Remove (key, tid). Pages are never merged or freed here, not even
    /// empty ones: what to do with underfull pages is chapter 15.
    pub fn delete(&mut self, key: u64, tid: u64) -> bool {
        let d = self.find_dir(key, tid);
        let leaf = &mut self.leaves[self.dir[d].leaf as usize];
        let i = Self::lower_bound(&leaf.cells, key, tid);
        if !leaf
            .cells
            .get(i)
            .is_some_and(|c| c.key == key && c.tid == tid)
        {
            return false;
        }
        let c = leaf.cells.remove(i);
        leaf.used -= u32::from(c.size);
        self.len -= 1;
        true
    }

    /// Count and total size of all cells with lo <= key < hi.
    pub fn range(&self, lo: u64, hi: u64) -> RangeSum {
        let mut sum = RangeSum::default();
        if lo >= hi {
            return sum;
        }
        for entry in &self.dir[self.find_dir(lo, 0)..] {
            let cells = &self.leaves[entry.leaf as usize].cells;
            for c in &cells[Self::lower_bound(cells, lo, 0)..] {
                if c.key >= hi {
                    return sum;
                }
                sum.cells += 1;
                sum.bytes += u64::from(c.size);
            }
        }
        sum
    }

    pub fn fill(&self) -> Fill {
        let mut f = Fill {
            min_used: self.capacity,
            ..Fill::default()
        };
        for entry in &self.dir {
            let used = self.leaves[entry.leaf as usize].used;
            f.pages += 1;
            f.used_bytes += u64::from(used);
            f.min_used = f.min_used.min(used);
            f.histogram[(used * 10 / self.capacity).min(9) as usize] += 1;
            if let Some(sep) = entry.low {
                f.sep_bytes += u64::from(sep.bytes());
                f.tid_seps += u32::from(sep.tid.is_some());
            }
        }
        f
    }

    /// Check invariants I1 to I5 (see the top of this file).
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.dir.is_empty() || self.dir.len() != self.leaves.len() {
            return Err("directory and page list disagree");
        }
        if self.dir[0].low.is_some() {
            return Err("first entry has a separator");
        }
        let mut count = 0usize;
        for (d, entry) in self.dir.iter().enumerate() {
            let leaf = self
                .leaves
                .get(entry.leaf as usize)
                .ok_or("dangling page number")?;
            let upper = self.dir.get(d + 1).and_then(|e| e.low);
            if d > 0 {
                let low = entry.low.ok_or("missing separator")?;
                if upper.is_some_and(|up| low >= up) {
                    return Err("I1: separators not ascending");
                }
            }
            let mut used = 0u32;
            for (i, c) in leaf.cells.iter().enumerate() {
                if i > 0 && !split::cell_less(leaf.cells[i - 1], *c) {
                    return Err("I3: cells not ascending");
                }
                if entry.low.is_some_and(|low| !low.at_or_below(c.key, c.tid)) {
                    return Err("I2: cell below its page's separator");
                }
                if upper.is_some_and(|up| up.at_or_below(c.key, c.tid)) {
                    return Err("I2: cell at or above the next separator");
                }
                used += u32::from(c.size);
            }
            if used != leaf.used || used > self.capacity {
                return Err("I4: byte accounting");
            }
            count += leaf.cells.len();
        }
        if count != self.len {
            return Err("I5: cell count");
        }
        Ok(())
    }
}

pub const ALL_POLICIES: [Policy; 4] = [
    Policy::Half,
    Policy::Fill(90),
    Policy::Rightmost(90),
    Policy::Adaptive(90),
];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;
    use crate::split::{HAND_CAPACITY, HAND_ITEMS, HAND_NEW_INDEX};
    use std::collections::HashMap;

    #[test]
    fn put_get_delete_and_range_on_one_page() {
        let mut tree = Tree::new(100, Policy::Half);
        assert_eq!(tree.put(5, 1, 10), Ok(true));
        assert_eq!(tree.put(5, 2, 20), Ok(true));
        assert_eq!(tree.put(3, 9, 25), Ok(true));
        assert_eq!(tree.put(5, 2, 25), Ok(false)); // already there, unchanged
        assert_eq!(tree.get(5, 2), Some(20));
        assert_eq!(tree.get(5, 3), None);
        assert_eq!(
            tree.range(5, 6),
            RangeSum {
                cells: 2,
                bytes: 30
            }
        );
        assert_eq!(
            tree.range(0, 100),
            RangeSum {
                cells: 3,
                bytes: 55
            }
        );
        assert!(tree.delete(5, 1));
        assert!(!tree.delete(5, 1));
        assert_eq!(tree.len, 2);
        assert_eq!(tree.put(1, 1, 26), Err(PutError::BadCellSize));
        assert_eq!(tree.put(1, 1, 0), Err(PutError::BadCellSize));
        tree.validate().unwrap();
    }

    /// A tree holding the hand example's page, without the incoming cell.
    fn hand_tree(policy: Policy) -> Tree {
        let mut tree = Tree::new(HAND_CAPACITY, policy);
        for (i, c) in HAND_ITEMS.iter().enumerate() {
            if i != HAND_NEW_INDEX {
                tree.put(c.key, c.tid, c.size).unwrap();
            }
        }
        tree
    }

    #[test]
    fn the_hand_example_splits_where_each_policy_says() {
        // (policy, bytes left, bytes right, separator carries a tid?)
        let cases = [
            (Policy::Half, 46, 60, true),
            (Policy::Fill(90), 86, 20, false),
            (Policy::Rightmost(90), 86, 20, false),
            (Policy::Adaptive(90), 86, 20, false),
        ];
        for (policy, left, right, tid_sep) in cases {
            let mut tree = hand_tree(policy);
            let new = HAND_ITEMS[HAND_NEW_INDEX];
            tree.put(new.key, new.tid, new.size).unwrap();
            tree.validate().unwrap();
            assert_eq!(tree.dir.len(), 2);
            assert_eq!(tree.leaves[0].used, left);
            assert_eq!(tree.leaves[1].used, right);
            assert_eq!(tree.dir[1].low.unwrap().tid.is_some(), tid_sep);
        }
    }

    #[test]
    fn ascending_inserts_half_leaves_pages_half_empty_rightmost_does_not() {
        let mut half = Tree::new(4096, Policy::Half);
        let mut right = Tree::new(4096, Policy::Rightmost(90));
        for i in 0..2000 {
            half.put(i, i, 64).unwrap();
            right.put(i, i, 64).unwrap();
        }
        half.validate().unwrap();
        right.validate().unwrap();
        // 4096 / 64 = 64 cells per page. Of the 65 cells of an overfull page,
        // 50:50 keeps 32 on the left and the 90% target keeps 58, so a new page
        // is needed every 32 or every 58 inserts.
        assert_eq!(half.fill().pages, 62);
        assert_eq!(right.fill().pages, 35);
        assert!(half.fill().avg_permille(4096) < 550);
        assert!(right.fill().avg_permille(4096) > 850);
    }

    #[test]
    fn the_smallest_legal_page_capacity_4_holds_1_byte_cells_splits_and_reports_its_fill() {
        for policy in ALL_POLICIES {
            let mut tree = Tree::new(MIN_CAPACITY, policy);
            assert_eq!(tree.max_cell_size(), 1);
            assert_eq!(tree.put(1, 1, 2), Err(PutError::BadCellSize));
            // An empty tree must already be measurable (no division by zero).
            assert_eq!(tree.fill().pages, 1);
            assert_eq!(tree.fill().avg_permille(MIN_CAPACITY), 0);
            for i in 0..9 {
                assert_eq!(tree.put(i, 0, 1), Ok(true));
            }
            tree.validate().unwrap();
            let f = tree.fill();
            assert!(f.pages >= 3);
            assert_eq!(f.used_bytes, 9);
            assert_eq!(f.histogram.iter().sum::<u32>(), f.pages);
        }
    }

    // Seeded model test: random puts, deletes, gets and ranges against a hash
    // map oracle, under every policy, on small pages so that splits are common.
    #[test]
    fn model_test_against_an_oracle_all_policies() {
        for (p, policy) in ALL_POLICIES.into_iter().enumerate() {
            let mut tree = Tree::new(256, policy);
            let mut oracle: HashMap<(u64, u64), u16> = HashMap::new();
            let mut rng = SplitMix64::new(1400 + p as u64);

            for step in 0..6000 {
                let key = rng.below(40);
                let tid = rng.below(60);
                let id = (key, tid);
                match rng.below(10) {
                    0..=5 => {
                        let size = rng.range(1, 65) as u16;
                        let added = tree.put(key, tid, size).unwrap();
                        assert_eq!(added, !oracle.contains_key(&id));
                        if added {
                            oracle.insert(id, size);
                        }
                    }
                    6 | 7 => assert_eq!(tree.delete(key, tid), oracle.remove(&id).is_some()),
                    8 => assert_eq!(tree.get(key, tid), oracle.get(&id).copied()),
                    _ => {
                        let hi = key + 1 + rng.below(5);
                        let mut want = RangeSum::default();
                        for (&(k, _), &size) in &oracle {
                            if k >= key && k < hi {
                                want.cells += 1;
                                want.bytes += u64::from(size);
                            }
                        }
                        assert_eq!(tree.range(key, hi), want);
                    }
                }
                if step % 500 == 0 {
                    tree.validate().unwrap();
                }
            }
            tree.validate().unwrap();
            assert_eq!(tree.len, oracle.len());
            assert!(tree.stats.splits > 10);
        }
    }

    #[test]
    fn every_page_budget_while_building_is_reported() {
        // Counterpart of Zig's checkAllAllocationFailures: build the same
        // small tree with every possible page budget. A build either
        // succeeds or stops with OutOfPages, and the tree is valid either way.
        for policy in ALL_POLICIES {
            let mut budget = 1;
            loop {
                let mut tree = Tree::new(128, policy);
                tree.page_budget = Some(budget);
                let mut rng = SplitMix64::new(7);
                let result = (0..40).try_for_each(|i| {
                    tree.put(rng.below(6), i, rng.range(8, 33) as u16)
                        .map(|_| ())
                });
                tree.validate().unwrap();
                match result {
                    Ok(()) => break,
                    Err(e) => assert_eq!(e, PutError::OutOfPages),
                }
                assert_eq!(tree.leaves.len(), budget);
                budget += 1;
            }
            assert!(budget > 2);
        }
    }

    #[test]
    fn a_put_that_fails_leaves_the_tree_unchanged() {
        let mut tree = hand_tree(Policy::Adaptive(90));
        let new = HAND_ITEMS[HAND_NEW_INDEX];
        tree.page_budget = Some(1);
        assert_eq!(
            tree.put(new.key, new.tid, new.size),
            Err(PutError::OutOfPages)
        );
        tree.validate().unwrap();
        assert_eq!((tree.len, tree.dir.len()), (6, 1));
        assert_eq!(tree.get(new.key, new.tid), None);
        assert_eq!(tree.stats, Stats::default());

        // With room for one more page the same put goes through.
        tree.page_budget = Some(2);
        assert_eq!(tree.put(new.key, new.tid, new.size), Ok(true));
        tree.validate().unwrap();
        assert_eq!(tree.dir.len(), 2);
    }
}
