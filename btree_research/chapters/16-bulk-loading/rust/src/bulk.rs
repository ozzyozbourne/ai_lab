//! Bottom-up bulk loader: build a B+tree from sorted input without a single
//! split, writing every page exactly once.
//!
//! The picture to keep in mind is one "open page" per tree level:
//!
//! ```text
//!     level 2:                 [ . . . . ]            <- gets a pair when a
//!     level 1:        [ p p p . ]                        level-1 page is sealed
//!     level 0:  ##### ##### [ k k . ]  <- sorted input arrives here
//! ```
//!
//! A pair is (key, pointer). On level 0 it is (key, value). On every higher
//! level it is (low key of a finished page, id of that page). So "a page was
//! finished" on level L is simply "a pair was added" on level L + 1, and the
//! same code runs on every level.
//!
//! Compared with PostgreSQL's nbtsort.c, which this follows, there is one
//! addition. Postgres writes a page the moment it is full and accepts that
//! the last page of each level may be nearly empty. Our tree promises the
//! textbook minimum occupancy, so each level keeps its most recently filled
//! page *pending*: it has a page id and is complete, but it is not written
//! until we know that the page after it is big enough. At the end of the
//! input the last two pages of a level can still be evened out (or merged)
//! for free, because neither has been written yet.
//!
//! Memory. The loader owns one buffer per level. The Zig version takes it
//! from a per-level `ArenaAllocator` and calls `reset(.retain_capacity)`
//! after every page; the Rust idiom for the same thing is a `Vec` that is
//! `clear()`ed, which drops the contents and keeps the allocation. Working
//! memory is therefore O(height) pages no matter how many keys are loaded.

use crate::bptree::{Entry, Error, NIL, Tree};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Options {
    /// Target fullness of leaves, in percent of their capacity.
    pub leaf_fill: u8,
    /// Target fullness of interior nodes, in percent of their capacity.
    pub inner_fill: u8,
}

impl Default for Options {
    fn default() -> Self {
        Self { leaf_fill: 100, inner_fill: 100 }
    }
}

#[derive(Debug, Clone, Copy)]
struct Pair {
    key: u64,
    slot: u64,
}

/// How many pairs a page gets before the next page is started:
/// floor(cap * percent / 100), but never below the minimum occupancy (so a
/// fill factor under 50% behaves like 50%) and never above the capacity.
pub fn fill_target(cap: usize, min: usize, percent: u8) -> usize {
    (cap * usize::from(percent) / 100).clamp(min, cap)
}

#[derive(Debug)]
struct Level {
    /// The open page: pairs collected so far. Cleared after every page, so
    /// its capacity stays at one buffer of this level's target size.
    buf: Vec<Pair>,
    /// Id of the page filled just before the open one. It sits in the tree's
    /// node array but has not been counted as written yet. `NIL` if none.
    pending: u32,
    /// Pages of this level already written and announced to the parent level.
    sealed: usize,
}

#[derive(Debug)]
pub struct BulkLoader<'a> {
    tree: &'a mut Tree,
    leaf_target: usize,
    inner_target: usize,
    levels: Vec<Level>,
    last_key: Option<u64>,
    /// Set by any call that runs out of nodes. Unlike `put`, an `add` that
    /// fails halfway cannot be undone or retried (a page may already have
    /// been closed and announced to its parent), so the failed load is
    /// abandoned instead: the tree is emptied and every later call returns
    /// `Error::LoaderClosed`. (The Zig version also sets its flag in
    /// `finish`; here `finish` takes `self`, so a finished loader is gone.)
    closed: bool,
}

impl<'a> BulkLoader<'a> {
    /// `tree` must be empty. The loader borrows it until it is dropped.
    pub fn new(tree: &'a mut Tree, options: Options) -> Self {
        assert!(tree.root == NIL && tree.count == 0);
        let leaf_target = fill_target(tree.leaf_cap(), tree.leaf_min(), options.leaf_fill);
        let inner_target = fill_target(tree.inner_cap(), tree.inner_min(), options.inner_fill);
        Self { tree, leaf_target, inner_target, levels: Vec::new(), last_key: None, closed: false }
    }

    /// Feed the next entry. Keys must arrive in strictly ascending order.
    /// `Error::NotSorted` rejects the key and changes nothing.
    /// `Error::OutOfNodes` abandons the whole load (see `closed`).
    pub fn add(&mut self, key: u64, value: u64) -> Result<(), Error> {
        if self.closed {
            return Err(Error::LoaderClosed);
        }
        if self.last_key.is_some_and(|last| key <= last) {
            return Err(Error::NotSorted);
        }
        if let Err(err) = self.add_pair(0, Pair { key, slot: value }) {
            return Err(self.abandon(err));
        }
        // Only now is the key part of the tree.
        self.last_key = Some(key);
        self.tree.count += 1;
        Ok(())
    }

    /// Out of nodes in the middle of a load. The half-built pages are of no
    /// use to anyone (there is no root to reach them from), so give them back
    /// and leave the tree as empty as `new` found it. The page-write counter
    /// is left alone: those writes did happen.
    fn abandon(&mut self, err: Error) -> Error {
        self.closed = true;
        self.tree.nodes.clear();
        self.tree.count = 0;
        err
    }

    fn target(&self, level: usize) -> usize {
        if level == 0 { self.leaf_target } else { self.inner_target }
    }

    /// Add one pair to the open page of `level`, starting the level or a new
    /// page as needed. This is the whole algorithm; everything else is
    /// bookkeeping for the two ends of the input.
    fn add_pair(&mut self, level: usize, pair: Pair) -> Result<(), Error> {
        if level == self.levels.len() {
            // First pair on this level: the tree just grew by one level.
            let buf = Vec::with_capacity(self.target(level));
            self.levels.push(Level { buf, pending: NIL, sealed: 0 });
        }
        if self.levels[level].buf.len() == self.target(level) {
            // The open page reached its fill target and another pair is
            // coming, so this page will certainly exist. Give it an id.
            self.close_open_page(level)?;
        }
        self.levels[level].buf.push(pair);
        Ok(())
    }

    /// Move the open page into the tree's node array (it becomes the pending
    /// page) and write out the page that was pending before it.
    fn close_open_page(&mut self, level: usize) -> Result<(), Error> {
        let id = self.copy_out(level)?;
        let old = self.levels[level].pending;
        self.levels[level].pending = id;
        if old != NIL {
            // Now the older page's right neighbour has an id, so its sibling
            // link can be filled in and the page is final.
            if level == 0 {
                self.tree.nodes[old as usize].next = id;
            }
            self.seal(level, old)?;
        }
        // The buffer's contents now live in the node. Recycle the buffer:
        // clear keeps the allocation, like reset(.retain_capacity) in Zig.
        self.levels[level].buf.clear();
        Ok(())
    }

    /// Allocate a node and copy the open page's pairs into it.
    fn copy_out(&mut self, level: usize) -> Result<u32, Error> {
        let id = self.tree.alloc_node(level == 0)?;
        let node = &mut self.tree.nodes[id as usize];
        let buf = &self.levels[level].buf;
        for (i, pair) in buf.iter().enumerate() {
            node.keys[i] = pair.key;
            node.slots[i] = pair.slot;
        }
        node.len = buf.len();
        Ok(id)
    }

    /// The page is final: count the write and tell the parent level about it.
    /// The pair sent up is (the page's low key, the page's id). For a leaf
    /// the low key is its first key; for an interior page it is the low key
    /// of its first child, which is sitting in the ignored slot 0.
    fn seal(&mut self, level: usize, id: u32) -> Result<(), Error> {
        self.tree.stats.page_writes += 1;
        self.levels[level].sealed += 1;
        let low_key = self.tree.nodes[id as usize].keys[0];
        self.add_pair(level + 1, Pair { key: low_key, slot: u64::from(id) })
    }

    /// End of input: close the right edge of the tree, bottom to top.
    ///
    /// `finish` consumes the loader, so "call it exactly once, and no `add`
    /// after it" is checked by the compiler (in Zig it is a run-time error):
    ///
    /// ```compile_fail
    /// use ch16_bulk_loading::{bptree::Tree, bulk::{BulkLoader, Options}};
    /// let mut tree = Tree::new(4);
    /// let mut loader = BulkLoader::new(&mut tree, Options::default());
    /// loader.add(1, 10).unwrap();
    /// loader.finish().unwrap();
    /// loader.finish().unwrap(); // error[E0382]: use of moved value: `loader`
    /// ```
    ///
    /// On `Error::OutOfNodes` the load is abandoned (see `closed`).
    pub fn finish(mut self) -> Result<(), Error> {
        if self.closed {
            return Err(Error::LoaderClosed);
        }
        self.close_right_edge().map_err(|err| self.abandon(err))
    }

    fn close_right_edge(&mut self) -> Result<(), Error> {
        let mut level = 0;
        while level < self.levels.len() {
            let is_leaf = level == 0;
            let min = self.tree.min(is_leaf);
            let cap = self.tree.cap(is_leaf);
            let lv = &mut self.levels[level];

            // Fix the tail. Only the open page can be under the minimum (the
            // pending page reached the target, and target >= min).
            if lv.pending != NIL && lv.buf.len() < min {
                let left = &mut self.tree.nodes[lv.pending as usize];
                let total = left.len + lv.buf.len();
                if total <= cap {
                    // Too few pairs for two legal pages: put them all in the
                    // pending page. The open page never becomes a node.
                    for (i, pair) in lv.buf.iter().enumerate() {
                        left.keys[left.len + i] = pair.key;
                        left.slots[left.len + i] = pair.slot;
                    }
                    left.len = total;
                    lv.buf.clear();
                } else {
                    // Share evenly: move the pending page's last pairs to the
                    // front of the open page.
                    let keep = total - total / 2;
                    let moved = (keep..left.len).map(|i| Pair { key: left.keys[i], slot: left.slots[i] });
                    lv.buf.splice(0..0, moved);
                    left.len = keep;
                }
            }

            let pending = lv.pending;
            let open = !lv.buf.is_empty();
            let pages_left = usize::from(pending != NIL) + usize::from(open);
            if lv.sealed == 0 && pages_left == 1 {
                // The only page on its level is the root. It is written but
                // has no parent to announce itself to.
                let id = if pending != NIL { pending } else { self.copy_out(level)? };
                self.tree.stats.page_writes += 1;
                self.tree.root = id;
                self.tree.height = level + 1;
                return Ok(());
            }

            // Otherwise write what is left. Each seal adds a pair one level
            // up, which may create that level; the loop then finishes it too.
            if open {
                let id = self.copy_out(level)?;
                self.levels[level].buf.clear();
                if pending != NIL {
                    if is_leaf {
                        self.tree.nodes[pending as usize].next = id;
                    }
                    self.seal(level, pending)?;
                }
                self.seal(level, id)?;
            } else {
                self.seal(level, pending)?;
            }
            self.levels[level].pending = NIL;
            level += 1;
        }
        Ok(())
    }
}

/// Convenience wrapper: build a tree of the given order from a sorted slice.
pub fn bulk_load(order: usize, entries: &[Entry], options: Options) -> Result<Tree, Error> {
    bulk_load_with_budget(order, entries, options, usize::MAX)
}

/// Same, but the tree may hold at most `max_nodes` nodes.
pub fn bulk_load_with_budget(order: usize, entries: &[Entry], options: Options, max_nodes: usize) -> Result<Tree, Error> {
    let mut tree = Tree::with_budget(order, max_nodes);
    load_into(&mut tree, entries, options)?;
    Ok(tree)
}

fn load_into(tree: &mut Tree, entries: &[Entry], options: Options) -> Result<(), Error> {
    let mut loader = BulkLoader::new(tree, options);
    for e in entries {
        loader.add(e.key, e.value)?;
    }
    loader.finish()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::bptree::assert_same_entries;
    use crate::ops::{Config, Op, OpStream, Oracle, Weights};
    use crate::prng::SplitMix64;

    fn ascending(n: usize, step: u64) -> Vec<Entry> {
        (1..=n as u64).map(|i| Entry { key: i * step, value: i * step * 10 }).collect()
    }

    fn both(fill: u8) -> Options {
        Options { leaf_fill: fill, inner_fill: fill }
    }

    #[test]
    fn fill_target_rounds_down_and_clamps() {
        assert_eq!(fill_target(3, 1, 100), 3);
        assert_eq!(fill_target(3, 1, 70), 2);
        assert_eq!(fill_target(3, 1, 10), 1); // clamped to the minimum
        assert_eq!(fill_target(15, 7, 90), 13);
        assert_eq!(fill_target(15, 7, 70), 10);
        assert_eq!(fill_target(15, 7, 20), 7);
        assert_eq!(fill_target(16, 8, 70), 11);
    }

    #[test]
    fn hand_example_13_keys_order_4_full_pages() {
        let tree = bulk_load(4, &ascending(13, 1), Options::default()).unwrap();
        assert_eq!(tree.validate(), Ok(()));
        let s = tree.shape();
        assert_eq!(s.height, 3);
        assert_eq!(s.leaves, 5);
        assert_eq!(s.inner, 3);
        // Every page written exactly once, no reads, no splits.
        assert_eq!(tree.stats.page_writes, 8);
        assert_eq!(tree.stats.page_reads, 0);
        assert_eq!(tree.stats.splits, 0);
        // The fifth leaf alone would make an interior node with one child, so
        // the loader shared the five leaves 3 + 2.
        let root = &tree.nodes[tree.root as usize];
        assert_eq!(root.len, 2);
        assert_eq!(root.keys[1], 10);
        assert_eq!(tree.nodes[root.slots[0] as usize].len, 3);
        assert_eq!(tree.nodes[root.slots[1] as usize].len, 2);
    }

    #[test]
    fn every_size_from_0_to_400_several_orders_and_fill_factors() {
        let all = ascending(400, 2);
        for order in [3usize, 4, 5, 6, 7, 16] {
            for fill in [100u8, 90, 70, 50, 1] {
                for n in 0..=all.len() {
                    let tree = bulk_load(order, &all[..n], both(fill)).unwrap();
                    assert_eq!(tree.validate(), Ok(()));
                    assert_eq!(tree.count, n);
                    // Written once each: writes == pages, and no slot is wasted.
                    let s = tree.shape();
                    assert_eq!(tree.stats.page_writes, s.pages() as u64);
                    assert_eq!(tree.nodes.len(), s.pages());
                    assert!(tree.range(0, u64::MAX).eq(all[..n].iter().copied()));
                    if n > 0 {
                        assert_eq!(tree.get(all[n - 1].key + 1), None);
                    }
                }
            }
        }
    }

    #[test]
    fn full_pages_give_the_minimum_number_of_leaves() {
        let tree = bulk_load(16, &ascending(1000, 1), Options::default()).unwrap();
        assert_eq!(tree.shape().leaves, 67); // ceil(1000 / 15)
    }

    #[test]
    fn unsorted_or_duplicate_input_is_rejected() {
        let mut tree = Tree::new(4);
        let mut loader = BulkLoader::new(&mut tree, Options::default());
        loader.add(5, 0).unwrap();
        assert_eq!(loader.add(5, 0), Err(Error::NotSorted));
        assert_eq!(loader.add(4, 0), Err(Error::NotSorted));
        loader.add(6, 0).unwrap();
        loader.finish().unwrap();
        assert_eq!(tree.validate(), Ok(()));
        assert_eq!(tree.count, 2);
    }

    #[test]
    fn a_closed_loader_refuses_everything() {
        // `finish` consumes the loader, so "finish twice" and "add after
        // finish" do not compile (see the compile_fail doc test on `finish`).
        // What is left to check at run time is a loader closed by a failure.
        let mut tree = Tree::with_budget(4, 0);
        let mut loader = BulkLoader::new(&mut tree, Options::default());
        for k in 1..=3 {
            loader.add(k, k).unwrap(); // the open leaf needs no node yet
        }
        assert_eq!(loader.add(4, 4), Err(Error::OutOfNodes));
        assert_eq!(loader.finish(), Err(Error::LoaderClosed));
        assert_eq!(tree.count, 0);
    }

    #[test]
    fn out_of_nodes_abandons_the_load_and_leaves_an_empty_tree() {
        let (mut failed_in_add, mut failed_in_finish) = (0, 0);
        for n in 1..=60u64 {
            let needed = bulk_load(4, &ascending(n as usize, 1), Options::default()).unwrap().nodes.len();
            for budget in 0..needed {
                let mut tree = Tree::with_budget(4, budget);
                let mut loader = BulkLoader::new(&mut tree, Options::default());
                let failed_key = (0..n).find(|&k| {
                    let result = loader.add(k, k);
                    assert!(matches!(result, Ok(()) | Err(Error::OutOfNodes)));
                    result.is_err()
                });
                if let Some(key) = failed_key {
                    failed_in_add += 1;
                    // Retrying the key used to report NotSorted, because the
                    // key was remembered before it was stored.
                    assert_eq!(loader.add(key, key), Err(Error::LoaderClosed));
                    assert_eq!(loader.add(key + 1, key), Err(Error::LoaderClosed));
                    assert_eq!(loader.finish(), Err(Error::LoaderClosed));
                } else {
                    failed_in_finish += 1;
                    assert_eq!(loader.finish(), Err(Error::OutOfNodes));
                }
                // Not a half-built tree: a valid empty one, which `put` can use.
                assert_eq!(tree.validate(), Ok(()));
                assert_eq!(tree.count, 0);
                assert_eq!(tree.root, NIL);
                assert_eq!(tree.get(0), None);
                if budget > 0 {
                    tree.put(7, 70).unwrap();
                    assert_eq!(tree.get(7), Some(70));
                    assert_eq!(tree.validate(), Ok(()));
                }
            }
        }
        // Both entry points were hit.
        assert!(failed_in_add > 0);
        assert!(failed_in_finish > 0);
    }

    #[test]
    fn loader_memory_does_not_grow_with_the_input() {
        for order in [4usize, 32] {
            for n in [2_000u64, 200_000] {
                let mut tree = Tree::new(order);
                let mut loader = BulkLoader::new(&mut tree, Options::default());
                for k in 0..n {
                    loader.add(k, k).unwrap();
                }
                // One buffer per level, and every buffer still has its
                // original capacity whether 1 page or 60000 went through it.
                // (Checked before `finish`, which consumes the loader; the
                // levels that `finish` adds on top never hold a full page.)
                let capacities: Vec<usize> = loader.levels.iter().map(|lv| lv.buf.capacity()).collect();
                loader.finish().unwrap();
                assert!(!capacities.is_empty() && capacities.len() <= tree.height);
                assert!(capacities.iter().all(|&c| c <= order));
            }
        }
    }

    #[test]
    fn bulk_load_under_a_node_budget_fails_cleanly() {
        let entries = ascending(60, 1);
        let needed = bulk_load(4, &entries, both(70)).unwrap().nodes.len();
        for budget in 0..needed {
            let result = bulk_load_with_budget(4, &entries, both(70), budget);
            assert_eq!(result.err(), Some(Error::OutOfNodes));
        }
        let tree = bulk_load_with_budget(4, &entries, both(70), needed).unwrap();
        assert_eq!(tree.validate(), Ok(()));
    }

    #[test]
    fn model_test_bulk_load_then_keep_inserting_against_the_oracle() {
        let mut rng = SplitMix64::new(1616);
        for round in 0..40 {
            let order = rng.range(3, 10) as usize;
            let fill = rng.range(1, 101) as u8;
            let n = rng.below(300);
            let mut oracle = Oracle::new();
            // Random distinct keys: put them through the oracle, which sorts.
            for _ in 0..n {
                let key = rng.below(1000);
                oracle.put(key, rng.next_u64());
            }

            let mut tree = Tree::new(order);
            let mut loader = BulkLoader::new(&mut tree, both(fill));
            for e in oracle.range(0, 1000) {
                loader.add(e.key, e.value).unwrap();
            }
            loader.finish().unwrap();
            assert_eq!(tree.validate(), Ok(()));
            assert_same_entries(oracle.range(0, 1000), &tree, 0, 1000);

            // A bulk-loaded tree is an ordinary tree: the insert path works on it.
            let stream = OpStream::new(Config {
                seed: round,
                count: 500,
                key_space: 1000,
                weights: Weights { put: 5, delete: 0, get: 3, range: 2 },
            });
            for op in stream {
                match op {
                    Op::Put { key, value } => {
                        tree.put(key, value).unwrap();
                        oracle.put(key, value);
                    }
                    Op::Delete { .. } => unreachable!(),
                    Op::Get { key } => assert_eq!(tree.get(key), oracle.get(key)),
                    Op::Range { lo, hi } => assert_same_entries(oracle.range(lo, hi), &tree, lo, hi),
                }
            }
            assert_eq!(tree.validate(), Ok(()));
            assert_eq!(tree.count, oracle.len());
        }
    }
}
