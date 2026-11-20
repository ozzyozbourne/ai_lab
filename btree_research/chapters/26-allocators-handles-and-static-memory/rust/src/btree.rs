//! A small in-memory B-tree whose nodes live in two bitmap slab pools (one size class
//! for leaves, one for interior nodes) and refer to each other by 32-bit handles
//! (twin of zig/src/btree.zig).
//!
//! Classic B-tree (keys and values in every node) with top-down splitting and CLRS
//! top-down deletion: every allocation happens BEFORE the step that needs it mutates
//! anything, so `Err(OutOfNodes)` in the middle of `put` leaves a valid tree.
//!
//! `M` is the order (maximum number of children), `K = M - 1` the maximum number of
//! keys and `S` the slots per slab. Stable Rust cannot write `[u64; M - 1]`, so `K` is
//! a second parameter and `new` checks the relation at compile time.

use crate::slab::{Handle, OutOfNodes, SlabPool};
use std::fmt::Write as _;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub key: u64,
    pub value: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub struct Invalid;

/// Size class 0. A leaf has no child array, so it is smaller than an interior node.
#[derive(Clone, Copy)]
pub struct Leaf<const K: usize> {
    len: u8,
    keys: [u64; K],
    vals: [u64; K],
}

/// Size class 1: the same header plus M child handles (4 bytes each).
#[derive(Clone, Copy)]
pub struct Interior<const M: usize, const K: usize> {
    head: Leaf<K>,
    children: [Handle; M],
}

impl<const K: usize> Leaf<K> {
    const BLANK: Self = Leaf {
        len: 0,
        keys: [0; K],
        vals: [0; K],
    };

    fn len(&self) -> usize {
        self.len as usize
    }
    fn keys(&self) -> &[u64] {
        &self.keys[..self.len()]
    }
    /// First index whose key is >= `key`.
    fn lower_bound(&self, key: u64) -> usize {
        self.keys().partition_point(|&k| k < key)
    }
    fn insert_at(&mut self, i: usize, key: u64, value: u64) {
        let n = self.len();
        self.keys.copy_within(i..n, i + 1);
        self.vals.copy_within(i..n, i + 1);
        self.keys[i] = key;
        self.vals[i] = value;
        self.len += 1;
    }
    fn remove_at(&mut self, i: usize) {
        let n = self.len();
        self.keys.copy_within(i + 1..n, i);
        self.vals.copy_within(i + 1..n, i);
        self.len -= 1;
    }
}

fn is_leaf(h: Handle) -> bool {
    h.class() == 0
}

pub struct BTree<const M: usize, const K: usize, const S: usize> {
    pub leaves: SlabPool<Leaf<K>, S>,
    pub interiors: SlabPool<Interior<M, K>, S>,
    root: Handle,
    /// Number of levels; 0 for the empty tree.
    pub height: u32,
    pub count: usize,
}

impl<const M: usize, const K: usize, const S: usize> BTree<M, K, S> {
    /// CLRS minimum degree: non-root nodes hold T-1 ..= 2T-1 keys.
    const T: usize = M / 2;

    pub fn new(release_empty: bool) -> Self {
        // Top-down splitting needs an even order.
        const { assert!(M >= 4 && M.is_multiple_of(2) && K + 1 == M) };
        BTree {
            leaves: SlabPool::new(0, release_empty, Leaf::BLANK),
            interiors: SlabPool::new(
                1,
                release_empty,
                Interior {
                    head: Leaf::BLANK,
                    children: [Handle::NONE; M],
                },
            ),
            root: Handle::NONE,
            height: 0,
            count: 0,
        }
    }

    // ---- handle plumbing ---------------------------------------------------------------

    /// Keys and values of any node. The class bit in the handle picks the pool.
    fn head(&self, h: Handle) -> &Leaf<K> {
        if is_leaf(h) {
            self.leaves.get(h)
        } else {
            &self.interiors.get(h).head
        }
    }

    fn head_mut(&mut self, h: Handle) -> &mut Leaf<K> {
        if is_leaf(h) {
            self.leaves.get_mut(h)
        } else {
            &mut self.interiors.get_mut(h).head
        }
    }

    fn kids(&self, h: Handle) -> &[Handle; M] {
        &self.interiors.get(h).children
    }

    fn kids_mut(&mut self, h: Handle) -> &mut [Handle; M] {
        &mut self.interiors.get_mut(h).children
    }

    fn new_node(&mut self, leaf: bool) -> Result<Handle, OutOfNodes> {
        let h = if leaf {
            self.leaves.create()?
        } else {
            self.interiors.create()?
        };
        self.head_mut(h).len = 0;
        Ok(h)
    }

    fn free_node(&mut self, h: Handle) {
        if is_leaf(h) {
            self.leaves.destroy(h)
        } else {
            self.interiors.destroy(h)
        }
    }

    // ---- get / range -------------------------------------------------------------------

    pub fn get(&self, key: u64) -> Option<u64> {
        let mut h = self.root;
        while !h.is_none() {
            let n = self.head(h);
            let i = n.lower_bound(key);
            if i < n.len() && n.keys[i] == key {
                return Some(n.vals[i]);
            }
            if is_leaf(h) {
                return None;
            }
            h = self.kids(h)[i];
        }
        None
    }

    /// Appends the entries with lo <= key < hi to `out`, ascending.
    pub fn range(&self, lo: u64, hi: u64, out: &mut Vec<Entry>) {
        if !self.root.is_none() && lo < hi {
            self.range_node(self.root, lo, hi, out);
        }
    }

    fn range_node(&self, h: Handle, lo: u64, hi: u64, out: &mut Vec<Entry>) {
        let n = self.head(h);
        let mut i = n.lower_bound(lo);
        loop {
            // Child i holds the keys between key i-1 and key i.
            if !is_leaf(h) {
                self.range_node(self.kids(h)[i], lo, hi, out);
            }
            if i == n.len() || n.keys[i] >= hi {
                return;
            }
            out.push(Entry {
                key: n.keys[i],
                value: n.vals[i],
            });
            i += 1;
        }
    }

    // ---- put ---------------------------------------------------------------------------

    /// Insert or overwrite. On `Err(OutOfNodes)` the key is not inserted and the tree
    /// is still valid (some full nodes on the path may already have been split).
    pub fn put(&mut self, key: u64, value: u64) -> Result<(), OutOfNodes> {
        if self.root.is_none() {
            self.root = self.new_node(true)?;
            self.height = 1;
        }
        if self.head(self.root).len() == K {
            // Grow upwards: a new empty root above the old one, then split the old.
            let new_root = self.new_node(false)?;
            self.kids_mut(new_root)[0] = self.root;
            if let Err(err) = self.split_child(new_root, 0) {
                self.free_node(new_root); // Zig: errdefer
                return Err(err);
            }
            self.root = new_root;
            self.height += 1;
        }
        let mut h = self.root;
        loop {
            // Invariant: node h is not full, so a key coming up from a split fits.
            let i = self.head(h).lower_bound(key);
            let n = self.head_mut(h);
            if i < n.len() && n.keys[i] == key {
                n.vals[i] = value;
                return Ok(());
            }
            if is_leaf(h) {
                n.insert_at(i, key, value);
                self.count += 1;
                return Ok(());
            }
            let mut child = self.kids(h)[i];
            if self.head(child).len() == K {
                self.split_child(h, i)?;
                // The child's median is now key i of h; pick the correct side of it.
                let n = self.head_mut(h);
                if key == n.keys[i] {
                    n.vals[i] = value;
                    return Ok(());
                }
                if key > n.keys[i] {
                    child = self.kids(h)[i + 1];
                }
            }
            h = child;
        }
    }

    /// Split the full child i of `parent` (which is not full). The only allocation
    /// comes first; after it nothing can fail.
    ///
    /// Zig holds pointers to parent, left and right at once. Here the nodes are small
    /// `Copy` values, so the code copies a node out, edits it and writes it back; the
    /// borrow checker never sees two `&mut` into the pools.
    fn split_child(&mut self, parent: Handle, i: usize) -> Result<(), OutOfNodes> {
        let t = Self::T;
        let left_h = self.kids(parent)[i];
        let right_h = self.new_node(is_leaf(left_h))?;
        let mut left = *self.head(left_h);
        let mut right = Leaf::BLANK;
        // left keeps keys 0..t-1, the median (index t-1) goes up, right gets the rest.
        right.len = (t - 1) as u8;
        right.keys[..t - 1].copy_from_slice(&left.keys[t..K]);
        right.vals[..t - 1].copy_from_slice(&left.vals[t..K]);
        if !is_leaf(left_h) {
            let left_kids = *self.kids(left_h);
            self.kids_mut(right_h)[..t].copy_from_slice(&left_kids[t..M]);
        }
        left.len = (t - 1) as u8;
        *self.head_mut(left_h) = left;
        *self.head_mut(right_h) = right;

        let parent_len = self.head(parent).len();
        let pk = self.kids_mut(parent);
        pk.copy_within(i + 1..parent_len + 1, i + 2);
        pk[i + 1] = right_h;
        self.head_mut(parent)
            .insert_at(i, left.keys[t - 1], left.vals[t - 1]);
        Ok(())
    }

    // ---- delete ------------------------------------------------------------------------

    /// Returns whether the key was present. Never allocates.
    pub fn delete(&mut self, key: u64) -> bool {
        if self.root.is_none() {
            return false;
        }
        let removed = self.delete_from(self.root, key);
        if removed {
            self.count -= 1;
        }
        // A root without keys is replaced by its only child (or by nothing).
        if self.head(self.root).len() == 0 {
            let old = self.root;
            self.root = if is_leaf(old) {
                Handle::NONE
            } else {
                self.kids(old)[0]
            };
            self.free_node(old);
            self.height -= 1;
        }
        removed
    }

    /// Precondition: `h` is the root or holds at least T keys, so one key can leave it
    /// without underflow. Each step re-establishes this for the child it enters.
    fn delete_from(&mut self, h: Handle, key: u64) -> bool {
        let t = Self::T;
        let n = *self.head(h);
        let i = n.lower_bound(key);
        let found = i < n.len() && n.keys[i] == key;
        if is_leaf(h) {
            if found {
                self.head_mut(h).remove_at(i);
            }
            return found;
        }
        let pk = *self.kids(h);
        if found {
            if self.head(pk[i]).len() >= t {
                // Replace by the predecessor, then delete the predecessor below.
                let pred = self.edge_entry(pk[i], false);
                self.set_entry(h, i, pred);
                return self.delete_from(pk[i], pred.key);
            }
            if self.head(pk[i + 1]).len() >= t {
                let succ = self.edge_entry(pk[i + 1], true);
                self.set_entry(h, i, succ);
                return self.delete_from(pk[i + 1], succ.key);
            }
            self.merge(h, i); // both minimal: key sinks into the merged child
            return self.delete_from(pk[i], key);
        }
        let mut c = i;
        if self.head(pk[c]).len() == t - 1 {
            if c > 0 && self.head(pk[c - 1]).len() >= t {
                self.borrow_from_left(h, c);
            } else if c < n.len() && self.head(pk[c + 1]).len() >= t {
                self.borrow_from_right(h, c);
            } else if c < n.len() {
                self.merge(h, c);
            } else {
                self.merge(h, c - 1);
                c -= 1;
            }
        }
        // `pk` is a copy taken before the merge; a merge only removes child c+1, so
        // entry c still names the node to descend into.
        self.delete_from(pk[c], key)
    }

    fn set_entry(&mut self, h: Handle, i: usize, e: Entry) {
        let n = self.head_mut(h);
        n.keys[i] = e.key;
        n.vals[i] = e.value;
    }

    /// Smallest (`min`) or largest entry of the subtree under `start`.
    fn edge_entry(&self, start: Handle, min: bool) -> Entry {
        let mut h = start;
        while !is_leaf(h) {
            h = self.kids(h)[if min { 0 } else { self.head(h).len() }];
        }
        let n = self.head(h);
        let i = if min { 0 } else { n.len() - 1 };
        Entry {
            key: n.keys[i],
            value: n.vals[i],
        }
    }

    /// Merge child i, separator i and child i+1 into child i; free child i+1.
    /// This is where slots become free and holes appear in the slab bitmaps.
    fn merge(&mut self, parent: Handle, i: usize) {
        let t = Self::T;
        let mut p = *self.head(parent);
        let left_h = self.kids(parent)[i];
        let right_h = self.kids(parent)[i + 1];
        let mut left = *self.head(left_h);
        let right = *self.head(right_h);
        assert!(left.len() == t - 1 && right.len() == t - 1);
        left.keys[t - 1] = p.keys[i];
        left.vals[t - 1] = p.vals[i];
        left.keys[t..K].copy_from_slice(&right.keys[..t - 1]);
        left.vals[t..K].copy_from_slice(&right.vals[..t - 1]);
        if !is_leaf(left_h) {
            let right_kids = *self.kids(right_h);
            self.kids_mut(left_h)[t..M].copy_from_slice(&right_kids[..t]);
        }
        left.len = K as u8;
        *self.head_mut(left_h) = left;
        self.kids_mut(parent).copy_within(i + 2..p.len() + 1, i + 1);
        p.remove_at(i);
        *self.head_mut(parent) = p;
        self.free_node(right_h);
    }

    /// Rotate right: separator c-1 moves down to the front of child c, the last entry
    /// of child c-1 moves up.
    fn borrow_from_left(&mut self, parent: Handle, c: usize) {
        let mut p = *self.head(parent);
        let left_h = self.kids(parent)[c - 1];
        let child_h = self.kids(parent)[c];
        let mut left = *self.head(left_h);
        let mut child = *self.head(child_h);
        if !is_leaf(child_h) {
            let moved = self.kids(left_h)[left.len()];
            let ck = self.kids_mut(child_h);
            ck.copy_within(0..child.len() + 1, 1);
            ck[0] = moved;
        }
        child.insert_at(0, p.keys[c - 1], p.vals[c - 1]);
        p.keys[c - 1] = left.keys[left.len() - 1];
        p.vals[c - 1] = left.vals[left.len() - 1];
        left.len -= 1;
        *self.head_mut(parent) = p;
        *self.head_mut(left_h) = left;
        *self.head_mut(child_h) = child;
    }

    /// Rotate left: separator c moves down to the end of child c, the first entry of
    /// child c+1 moves up.
    fn borrow_from_right(&mut self, parent: Handle, c: usize) {
        let mut p = *self.head(parent);
        let child_h = self.kids(parent)[c];
        let right_h = self.kids(parent)[c + 1];
        let mut child = *self.head(child_h);
        let mut right = *self.head(right_h);
        if !is_leaf(child_h) {
            let rk = self.kids_mut(right_h);
            let moved = rk[0];
            rk.copy_within(1..right.len() + 1, 0);
            self.kids_mut(child_h)[child.len() + 1] = moved;
        }
        child.insert_at(child.len(), p.keys[c], p.vals[c]);
        p.keys[c] = right.keys[0];
        p.vals[c] = right.vals[0];
        right.remove_at(0);
        *self.head_mut(parent) = p;
        *self.head_mut(child_h) = child;
        *self.head_mut(right_h) = right;
    }

    // ---- vacuum ------------------------------------------------------------------------

    /// Compaction after many deletes (after DuckDB's `ART::Vacuum`): each pool picks
    /// its emptiest slab as victim, the tree moves every node out of it and rewrites
    /// the ONE handle that refers to the node. Returns the number of nodes moved.
    pub fn vacuum(&mut self) -> u32 {
        let leaf_victim = self.leaves.vacuum_begin();
        let interior_victim = self.interiors.vacuum_begin();
        let mut moved = 0;
        if !self.root.is_none() {
            self.root = self.move_if_victim(self.root, &mut moved);
            self.vacuum_node(self.root, &mut moved);
        }
        if leaf_victim {
            self.leaves.vacuum_end();
        }
        if interior_victim {
            self.interiors.vacuum_end();
        }
        moved
    }

    fn move_if_victim(&mut self, h: Handle, moved: &mut u32) -> Handle {
        let victim = if is_leaf(h) {
            self.leaves.is_victim(h)
        } else {
            self.interiors.is_victim(h)
        };
        if !victim {
            return h;
        }
        *moved += 1;
        if is_leaf(h) {
            self.leaves.relocate(h)
        } else {
            self.interiors.relocate(h)
        }
    }

    fn vacuum_node(&mut self, h: Handle, moved: &mut u32) {
        if is_leaf(h) {
            return;
        }
        for i in 0..=self.head(h).len() {
            let child = self.move_if_victim(self.kids(h)[i], moved);
            self.kids_mut(h)[i] = child;
            self.vacuum_node(child, moved);
        }
    }

    // ---- validate / dump ---------------------------------------------------------------

    /// Checks the B-tree invariants and the allocator bookkeeping: every reachable
    /// handle is live in the pool of its class, and the pools hold no other node.
    pub fn validate(&self) -> Result<(), Invalid> {
        let mut seen = Counts::default();
        if self.root.is_none() {
            if self.height != 0 || self.count != 0 {
                return Err(Invalid);
            }
        } else {
            self.validate_node(self.root, 1, None, None, &mut seen)?;
        }
        let ok = seen.keys == self.count
            && seen.leaves == self.leaves.live
            && seen.interiors == self.interiors.live;
        if ok { Ok(()) } else { Err(Invalid) }
    }

    fn validate_node(
        &self,
        h: Handle,
        depth: u32,
        lo: Option<u64>,
        hi: Option<u64>,
        seen: &mut Counts,
    ) -> Result<(), Invalid> {
        let live = if is_leaf(h) {
            self.leaves.is_live(h)
        } else {
            self.interiors.is_live(h)
        };
        if !live {
            return Err(Invalid);
        }
        let n = self.head(h);
        if n.len() > K || n.len() == 0 || (h != self.root && n.len() < Self::T - 1) {
            return Err(Invalid);
        }
        for (i, &k) in n.keys().iter().enumerate() {
            let sorted = i == 0 || n.keys[i - 1] < k;
            if !sorted || lo.is_some_and(|lo| k <= lo) || hi.is_some_and(|hi| k >= hi) {
                return Err(Invalid);
            }
        }
        seen.keys += n.len();
        if is_leaf(h) {
            seen.leaves += 1;
            // All leaves on one level.
            return if depth == self.height {
                Ok(())
            } else {
                Err(Invalid)
            };
        }
        seen.interiors += 1;
        for i in 0..=n.len() {
            let child_lo = if i == 0 { lo } else { Some(n.keys[i - 1]) };
            let child_hi = if i == n.len() { hi } else { Some(n.keys[i]) };
            self.validate_node(self.kids(h)[i], depth + 1, child_lo, child_hi, seen)?;
        }
        Ok(())
    }

    /// One node per line, children indented, each with its handle:
    /// `I0.0 [10]` / `  L0.1 [12 20 30]`.
    pub fn dump(&self) -> String {
        let mut out = String::new();
        if self.root.is_none() {
            out.push_str("(empty)\n");
        } else {
            self.dump_node(&mut out, self.root, 0);
        }
        out
    }

    fn dump_node(&self, out: &mut String, h: Handle, depth: usize) {
        let n = self.head(h);
        let keys: Vec<String> = n.keys().iter().map(u64::to_string).collect();
        writeln!(out, "{}{} [{}]", "  ".repeat(depth), h, keys.join(" "))
            .expect("writing to a String");
        if !is_leaf(h) {
            for i in 0..=n.len() {
                self.dump_node(out, self.kids(h)[i], depth + 1);
            }
        }
    }
}

#[derive(Default)]
struct Counts {
    keys: usize,
    leaves: u32,
    interiors: u32,
}

pub const CANONICAL_KEYS: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::{Config, Op, OpStream, Oracle, Weights};

    #[test]
    fn node_sizes_handles_are_half_the_size_of_pointers() {
        assert_eq!(std::mem::size_of::<Leaf<3>>(), 56); // 3 keys + 3 values + len, padded
        assert_eq!(std::mem::size_of::<Interior<4, 3>>(), 56 + 4 * 4); // + four 4-byte handles
    }

    #[test]
    fn canonical_example_on_slabs() {
        let mut tree: BTree<4, 3, 4> = BTree::new(true);
        for k in CANONICAL_KEYS {
            tree.put(k, k * 10).unwrap();
            tree.validate().unwrap();
        }
        let expected = "\
I0.1 [10]
  I0.0 [6]
    L0.0 [1 3 5]
    L0.3 [7]
  I0.2 [20]
    L0.1 [12 15 17]
    L0.2 [25 30]
";
        assert_eq!(tree.dump(), expected);
        assert_eq!((tree.count, tree.height), (12, 3));
        for k in CANONICAL_KEYS {
            assert_eq!(tree.get(k), Some(k * 10));
        }
        assert_eq!(tree.get(11), None);
        tree.put(12, 99).unwrap(); // overwrite
        assert_eq!(tree.get(12), Some(99));
        assert_eq!(tree.count, 12);
    }

    #[test]
    fn delete_down_to_empty_returns_every_slot() {
        let mut tree: BTree<4, 3, 4> = BTree::new(true);
        for k in 0..200 {
            tree.put(k, k).unwrap();
        }
        assert!(!tree.delete(1000));
        for i in 0..200 {
            assert!(tree.delete((i * 37) % 200)); // a fixed permutation
            tree.validate().unwrap();
        }
        assert!(tree.root.is_none());
        assert_eq!(tree.leaves.live + tree.interiors.live, 0);
        assert_eq!(tree.leaves.slab_count, 1); // the kept "last slab with space"
    }

    fn model_test<const M: usize, const K: usize, const S: usize>(seed: u64) {
        let mut tree: BTree<M, K, S> = BTree::new(true);
        let mut oracle = Oracle::new();
        let mut got = Vec::new();
        let config = Config {
            seed,
            count: 4000,
            key_space: 120,
            weights: Weights::default(),
        };
        for (step, op) in OpStream::new(config).enumerate() {
            match op {
                Op::Put { key, value } => {
                    tree.put(key, value).unwrap();
                    oracle.put(key, value);
                }
                Op::Delete { key } => assert_eq!(tree.delete(key), oracle.delete(key).is_some()),
                Op::Get { key } => assert_eq!(tree.get(key), oracle.get(key)),
                Op::Range { lo, hi } => {
                    got.clear();
                    tree.range(lo, hi, &mut got);
                    let want = oracle.range(lo, hi);
                    assert_eq!(got.len(), want.len());
                    assert!(
                        got.iter()
                            .zip(want)
                            .all(|(a, b)| a.key == b.key && a.value == b.value)
                    );
                }
            }
            assert_eq!(tree.count, oracle.len());
            // Vacuum now and then: contents must not change when nodes move.
            if step % 500 == 499 {
                tree.vacuum();
            }
            if step % 16 == 0 {
                tree.validate().unwrap();
            }
        }
        tree.validate().unwrap();
    }

    #[test]
    fn model_test_against_the_oracle() {
        model_test::<4, 3, 2>(1);
        model_test::<4, 3, 4>(2);
        model_test::<6, 5, 3>(3);
        model_test::<8, 7, 64>(4);
    }

    #[test]
    fn put_under_every_possible_slab_budget() {
        // The analogue of Zig's checkAllAllocationFailures: let the 1st, 2nd, ... slab
        // creation fail and check that the failed put changed nothing visible.
        let n = 40u64;
        let mut budget = 0;
        loop {
            let mut tree: BTree<4, 3, 2> = BTree::new(true);
            tree.leaves.budget = budget;
            tree.interiors.budget = budget;
            let mut failed = false;
            for i in 0..n {
                let k = (i * 7) % n;
                if tree.put(k, k).is_err() {
                    tree.validate().unwrap();
                    assert_eq!(tree.get(k), None);
                    assert_eq!(tree.count as u64, i);
                    failed = true;
                    break;
                }
            }
            if !failed {
                break;
            }
            budget += 1;
        }
        assert!(budget > 5);
    }

    #[test]
    fn vacuum_releases_slabs_and_keeps_the_contents() {
        let mut tree: BTree<4, 3, 4> = BTree::new(true);
        for k in 1..=40 {
            tree.put(k, k).unwrap();
        }
        for k in (1..=40).filter(|k| k % 4 != 0) {
            assert!(tree.delete(k));
        }
        tree.validate().unwrap();
        let mut before = tree.leaves.slab_count + tree.interiors.slab_count;
        // One vacuum pass frees at most one slab per pool: repeat until nothing moves.
        let mut moved_total = 0;
        loop {
            let moved = tree.vacuum();
            tree.validate().unwrap();
            if moved == 0 {
                break;
            }
            moved_total += moved;
            let after = tree.leaves.slab_count + tree.interiors.slab_count;
            assert!(after < before);
            before = after;
        }
        assert!(moved_total > 0);
        for k in 1..=40 {
            assert_eq!(tree.get(k), (k % 4 == 0).then_some(k));
        }
        // Dense again: fewer free slots than one slab in each pool.
        assert!(tree.leaves.free_slots() < 4 && tree.interiors.free_slots() < 4);
    }

    #[test]
    fn frozen_after_reserve_the_tree_never_grows() {
        let mut tree: BTree<4, 3, 16> = BTree::new(false);
        tree.leaves.reserve(4).unwrap();
        tree.interiors.reserve(2).unwrap();
        tree.leaves.freeze();
        tree.interiors.freeze();

        let config = Config {
            seed: 9,
            count: 3000,
            key_space: 60,
            weights: Weights::default(),
        };
        for op in OpStream::new(config) {
            match op {
                Op::Put { key, value } => tree.put(key, value).unwrap(),
                Op::Delete { key } => {
                    tree.delete(key);
                }
                _ => {}
            }
        }
        tree.validate().unwrap();
        assert_eq!(tree.leaves.grow_failures + tree.interiors.grow_failures, 0);

        // Exhaust the pool: the put fails cleanly, the tree stays usable.
        let mut k = 1000;
        while tree.put(k, k).is_ok() {
            k += 1;
        }
        tree.validate().unwrap();
        assert_eq!(tree.leaves.grow_failures + tree.interiors.grow_failures, 1);
        assert_eq!(tree.get(k), None);
        assert_eq!(tree.leaves.slab_count, 4);
    }

    // The scenario of the "Static memory" mode in viz/index.html, pinned here and in the
    // Zig twin so that the page's JS model can be checked against real programs.
    #[test]
    fn static_picture_ascending_keys_until_the_pool_is_dry() {
        let mut tree: BTree<4, 3, 4> = BTree::new(false);
        tree.leaves.reserve(3).unwrap();
        tree.interiors.reserve(2).unwrap();
        tree.leaves.freeze();
        tree.interiors.freeze();

        let mut k = 1;
        while tree.put(k, k).is_ok() {
            k += 1;
        }
        // Key 25 would fit into leaf L2.3, but top-down insertion must first split the
        // full interior node I1.3 on the way, and the interior pool has no slot left.
        assert_eq!((k, tree.count, tree.height), (25, 24, 4));
        assert_eq!(tree.leaves.grow_failures, 0);
        assert_eq!(tree.interiors.grow_failures, 1);
        assert_eq!(tree.leaves.free_slots() + tree.interiors.free_slots(), 0);
        tree.validate().unwrap();
        let expected = "\
I1.1 [8]
  I0.1 [4]
    I0.0 [2]
      L0.0 [1]
      L0.1 [3]
    I0.2 [6]
      L0.2 [5]
      L0.3 [7]
  I1.2 [12 16]
    I0.3 [10]
      L1.0 [9]
      L1.1 [11]
    I1.0 [14]
      L1.2 [13]
      L1.3 [15]
    I1.3 [18 20 22]
      L2.0 [17]
      L2.1 [19]
      L2.2 [21]
      L2.3 [23 24]
";
        assert_eq!(tree.dump(), expected);
        // Deleting gives slots back to the pool (never to the allocator): 5 and 7 merge
        // into one leaf, their parent into its sibling, and the insert fits again.
        assert!(tree.delete(7));
        assert_eq!(tree.leaves.slab_count, 3);
        assert!(tree.leaves.free_slots() + tree.interiors.free_slots() > 0);
        tree.put(25, 25).unwrap();
        tree.validate().unwrap();
    }
}
