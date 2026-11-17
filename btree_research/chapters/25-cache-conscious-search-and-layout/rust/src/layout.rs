//! Two static layouts of the same sorted keys, both stored on cache-line
//! boundaries, both searched without an unpredictable branch (twin of
//! zig/src/layout.zig).
//!
//!   * `Eytzinger`: a binary search tree stored in breadth-first order, the
//!     way a binary heap is stored. Children of slot k are slots 2k and 2k+1.
//!   * `BlockTree`: the same idea with 8 keys (one cache line) per node and 9
//!     children. It is a pointer-free B-tree: one line per level.
//!
//! Both are built once from sorted input and never modified (compare the
//! bulk-loaded trees of chapter 16). Both keep a `rank` array that maps a slot
//! back to the index in sorted order, so that their answers can be compared
//! with the searches in search.rs. A real index would store the payload
//! (a child page id, a row id) in that parallel array instead.

use crate::search::rank8;
use crate::trace::{LANES, LINE_BYTES, Tracer};

/// Padding value: compares greater than or equal to every needle, so padded
/// slots never count as "smaller". Real keys must be below it.
pub const SENTINEL: u64 = u64::MAX;

/// Eight keys that are guaranteed to start on a 64-byte boundary.
///
/// Zig asks the allocator: `gpa.alignedAlloc(u64, .@"64", n)`. Safe Rust has
/// no aligned `Vec<u64>`, but alignment is a property of a TYPE, so we make
/// the cache line a type and let `Vec<Line>` do the rest. No unsafe needed.
#[repr(align(64))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Line(pub [u64; LANES]);

const _: () = assert!(size_of::<Line>() == LINE_BYTES && align_of::<Line>() == LINE_BYTES);

/// A line-aligned array of u64 keys whose length is a multiple of 8.
/// The price of the safe representation: element i is `lines[i / 8].0[i % 8]`
/// instead of `keys[i]` (a shift and a mask, both free next to a cache miss).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlignedKeys {
    lines: Vec<Line>,
}

impl AlignedKeys {
    /// `slots` rounded up to whole lines, every slot holding `fill`.
    pub fn filled(slots: usize, fill: u64) -> Self {
        Self {
            lines: vec![Line([fill; LANES]); slots.div_ceil(LANES)],
        }
    }

    /// Copies `sorted` and pads with sentinels to a multiple of 8 keys, ready
    /// for `search::lower_bound_vector`.
    pub fn padded(sorted: &[u64]) -> Self {
        let mut keys = Self::filled(sorted.len(), SENTINEL);
        for (i, &k) in sorted.iter().enumerate() {
            keys.set(i, k);
        }
        keys
    }

    pub fn len(&self) -> usize {
        self.lines.len() * LANES
    }

    pub fn get(&self, i: usize) -> u64 {
        self.lines[i / LANES].0[i % LANES]
    }

    pub fn set(&mut self, i: usize, key: u64) {
        self.lines[i / LANES].0[i % LANES] = key;
    }

    pub fn lines(&self) -> &[Line] {
        &self.lines
    }

    pub fn iter(&self) -> impl Iterator<Item = u64> + '_ {
        self.lines.iter().flat_map(|line| line.0.iter().copied())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Corrupt;

#[derive(Debug, Clone)]
pub struct Eytzinger {
    /// Slot 0 is unused, slots 1..=n hold keys, the rest is sentinel padding.
    /// Slot 0 is not wasted: it shifts the tree so that slots 8k..8k+7, the
    /// eight great-grandchildren of slot k, are exactly one cache line.
    pub keys: AlignedKeys,
    /// rank[slot] = index of that key in sorted order; rank[0] = n ("no key").
    pub rank: Vec<u32>,
    pub n: usize,
}

impl Eytzinger {
    pub fn new(sorted: &[u64]) -> Self {
        let n = sorted.len();
        let mut keys = AlignedKeys::filled(n + 1, SENTINEL);
        keys.set(0, 0);
        let mut rank = vec![0u32; n + 1];
        rank[0] = n as u32;
        let mut this = Self { keys, rank, n };
        let mut next = 0;
        this.fill(sorted, 1, &mut next);
        assert_eq!(next, n);
        this
    }

    /// In-order walk of the implicit tree, handing out sorted keys as we go:
    /// everything in the left subtree gets a smaller key than slot k.
    fn fill(&mut self, sorted: &[u64], k: usize, next: &mut usize) {
        if k > self.n {
            return;
        }
        self.fill(sorted, 2 * k, next);
        assert!(sorted[*next] < SENTINEL);
        self.keys.set(k, sorted[*next]);
        self.rank[k] = *next as u32;
        *next += 1;
        self.fill(sorted, 2 * k + 1, next);
    }

    /// Lower bound as an index into the SORTED order.
    ///
    /// Descend: go right (2k+1) when the slot's key is smaller, else left
    /// (2k). The slot number therefore records the path in binary: each right
    /// turn appends a 1, each left turn a 0. The answer is the last slot where
    /// we turned left (its key is >= the needle and nothing smaller below it
    /// is). To get back there, drop the trailing 1 bits and one more bit. If
    /// we never turned left the result is slot 0, whose rank is n.
    pub fn lower_bound<T: Tracer>(&self, key: u64, prefetch: bool, tracer: &mut T) -> usize {
        let mut k = 1;
        while k <= self.n {
            if prefetch {
                // Slots 8k..8k+7 are the eight possible positions three
                // levels down and they share one line: a single hint covers
                // all of them, with three comparisons of lead time. (Recorded
                // only; see search.rs for why Rust issues no real hint.)
                tracer.prefetch((8 * k).min(self.keys.len() - 1));
            }
            tracer.cmp(k);
            k = 2 * k + usize::from(self.keys.get(k) < key);
        }
        k >>= k.trailing_ones() + 1;
        self.rank[k] as usize
    }

    /// Checks: an in-order walk visits strictly increasing keys with ranks
    /// 0, 1, 2, ...; padding is untouched; rank[0] is n.
    pub fn validate(&self) -> Result<(), Corrupt> {
        if self.rank.len() != self.n + 1 || self.rank[0] as usize != self.n {
            return Err(Corrupt);
        }
        if self.keys.len() != (self.n + 1).next_multiple_of(LANES) {
            return Err(Corrupt);
        }
        if self.keys.iter().skip(self.n + 1).any(|pad| pad != SENTINEL) {
            return Err(Corrupt);
        }
        let mut next = 0;
        let mut prev = None;
        self.walk(1, &mut next, &mut prev)?;
        if next == self.n { Ok(()) } else { Err(Corrupt) }
    }

    fn walk(&self, k: usize, next: &mut usize, prev: &mut Option<u64>) -> Result<(), Corrupt> {
        if k > self.n {
            return Ok(());
        }
        self.walk(2 * k, next, prev)?;
        let key = self.keys.get(k);
        if self.rank[k] as usize != *next || prev.is_some_and(|p| p >= key) {
            return Err(Corrupt);
        }
        *prev = Some(key);
        *next += 1;
        self.walk(2 * k + 1, next, prev)
    }
}

#[derive(Debug, Clone)]
pub struct BlockTree {
    /// Node b owns keys[8b ..= 8b+7], i.e. `keys.lines()[b]`. Child j of node
    /// b is node 9b + j + 1. No pointers are stored: the position is arithmetic.
    pub keys: AlignedKeys,
    /// rank[slot] = index in sorted order, n for padding slots.
    pub rank: Vec<u32>,
    pub n: usize,
}

impl BlockTree {
    pub const FANOUT: usize = LANES + 1;

    pub fn new(sorted: &[u64]) -> Self {
        let n = sorted.len();
        let keys = AlignedKeys::filled(n, SENTINEL);
        let rank = vec![n as u32; keys.len()];
        let mut this = Self { keys, rank, n };
        let mut next = 0;
        this.fill(sorted, 0, &mut next);
        assert_eq!(next, n);
        this
    }

    pub fn block_count(&self) -> usize {
        self.keys.lines().len()
    }

    /// In-order: child 0, key 0, child 1, key 1, ..., key 7, child 8.
    /// When the sorted keys run out the remaining slots keep their sentinel.
    fn fill(&mut self, sorted: &[u64], block: usize, next: &mut usize) {
        if block >= self.block_count() {
            return;
        }
        for j in 0..LANES {
            self.fill(sorted, block * Self::FANOUT + j + 1, next);
            if *next < sorted.len() {
                assert!(sorted[*next] < SENTINEL);
                self.keys.set(block * LANES + j, sorted[*next]);
                self.rank[block * LANES + j] = *next as u32;
                *next += 1;
            }
        }
        self.fill(sorted, block * Self::FANOUT + LANES + 1, next);
    }

    /// Lower bound as an index into the sorted order. Per level: one chunk
    /// compare of one line gives the child number r. If r < 8, key r of this
    /// node is the best candidate so far (deeper candidates are smaller and
    /// still >= the needle, so later ones overwrite earlier ones).
    pub fn lower_bound<T: Tracer>(&self, key: u64, tracer: &mut T) -> usize {
        let mut result = self.n;
        let mut block = 0;
        while let Some(line) = self.keys.lines().get(block) {
            tracer.cmp_block(block * LANES, LANES);
            let r = rank8(&line.0, key);
            // rank[] is read at most once per level; a tree that stored child
            // ids would not need it at all.
            if r < LANES {
                result = self.rank[block * LANES + r] as usize;
            }
            block = block * Self::FANOUT + r + 1;
        }
        result
    }

    pub fn validate(&self) -> Result<(), Corrupt> {
        if self.keys.len() != self.rank.len() || self.keys.len() != self.n.next_multiple_of(LANES) {
            return Err(Corrupt);
        }
        let mut next = 0;
        let mut prev = None;
        self.walk(0, &mut next, &mut prev)?;
        if next == self.n { Ok(()) } else { Err(Corrupt) }
    }

    fn walk(&self, block: usize, next: &mut usize, prev: &mut Option<u64>) -> Result<(), Corrupt> {
        if block >= self.block_count() {
            return Ok(());
        }
        for j in 0..LANES {
            self.walk(block * Self::FANOUT + j + 1, next, prev)?;
            let slot = block * LANES + j;
            let key = self.keys.get(slot);
            if *next < self.n {
                if self.rank[slot] as usize != *next || prev.is_some_and(|p| p >= key) {
                    return Err(Corrupt);
                }
                *prev = Some(key);
                *next += 1;
            } else if key != SENTINEL || self.rank[slot] as usize != self.n {
                return Err(Corrupt);
            }
        }
        self.walk(block * Self::FANOUT + LANES + 1, next, prev)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;
    use crate::search::{lower_bound_linear, lower_bound_vector};
    use crate::trace::{Layout, NoTrace, Trace};

    fn tens() -> Vec<u64> {
        (1..=15).map(|i| i * 10).collect()
    }

    #[test]
    fn eytzinger_layout_of_15_keys_is_the_breadth_first_order_of_the_balanced_tree() {
        let e = Eytzinger::new(&tens());
        e.validate().unwrap();
        let slots: Vec<u64> = e.keys.iter().skip(1).collect();
        assert_eq!(
            slots,
            [
                80, 40, 120, 20, 60, 100, 140, 10, 30, 50, 70, 90, 110, 130, 150
            ]
        );
        assert_eq!(e.keys.len(), 16);
        // The type guarantees it, but look anyway: the first key starts a line.
        assert_eq!(e.keys.lines().as_ptr().addr() % 64, 0);

        let mut t = Trace::new(Layout::KEYS);
        assert_eq!(e.lower_bound(70, false, &mut t), 6);
        assert_eq!(t.probes(), &[1, 2, 5, 11]); // 80, 40, 60, 70
        assert_eq!(t.lines_read(), 2); // slots 1..7 share line 0, slot 11 is in line 1
        assert_eq!(e.lower_bound(151, false, &mut NoTrace), 15); // never turned left
    }

    #[test]
    fn block_tree_of_15_keys_one_full_leaf_and_a_root_with_seven_keys() {
        let b = BlockTree::new(&tens());
        b.validate().unwrap();
        assert_eq!(
            b.keys.lines()[0].0,
            [90, 100, 110, 120, 130, 140, 150, SENTINEL]
        );
        assert_eq!(b.keys.lines()[1].0, [10, 20, 30, 40, 50, 60, 70, 80]);
        let mut t = Trace::new(Layout::KEYS);
        assert_eq!(b.lower_bound(70, &mut t), 6);
        assert_eq!(t.steps, 2);
        assert_eq!(t.lines_read(), 2);
    }

    #[test]
    fn model_test_both_layouts_agree_with_the_linear_oracle_on_seeded_random_arrays() {
        let mut rng = SplitMix64::new(25);
        for round in 0..300usize {
            let n = if round < 100 {
                round
            } else {
                rng.below(700) as usize
            };
            let mut key = 0;
            let sorted: Vec<u64> = (0..n)
                .map(|_| {
                    key += 1 + rng.below(50);
                    key
                })
                .collect();
            let e = Eytzinger::new(&sorted);
            let b = BlockTree::new(&sorted);
            let padded = AlignedKeys::padded(&sorted);
            e.validate().unwrap();
            b.validate().unwrap();
            for _ in 0..64 {
                let needle = rng.below(key + 60);
                let want = lower_bound_linear(&sorted, needle);
                let mut te = Trace::new(Layout::KEYS);
                let mut tp = Trace::new(Layout::KEYS);
                let mut tb = Trace::new(Layout::KEYS);
                assert_eq!(e.lower_bound(needle, false, &mut te), want);
                assert_eq!(e.lower_bound(needle, true, &mut tp), want);
                assert_eq!(b.lower_bound(needle, &mut tb), want);
                assert_eq!(lower_bound_vector(&padded, needle, &mut NoTrace), want);
                // Prefetching changes neither the probes nor the lines read.
                assert_eq!(te.probes(), tp.probes());
                assert_eq!(te.lines_read(), tp.lines_read());
                if n > 0 {
                    // Eytzinger depth: floor(log2 n) or one more.
                    let depth = n.ilog2();
                    assert!(te.comparisons >= depth && te.comparisons <= depth + 1);
                    // Only line 0 (slots 1..7) is read without having been hinted.
                    // (Below 8 keys the clamped hint lands on line 0 itself.)
                    assert_eq!(tp.uncovered, u32::from(n >= LANES));
                    // One line per level of the 9-way tree.
                    assert_eq!(tb.steps, tb.lines_read());
                }
            }
            assert_eq!(e.lower_bound(SENTINEL, false, &mut NoTrace), n);
            assert_eq!(b.lower_bound(SENTINEL, &mut NoTrace), n);
        }
    }

    #[test]
    fn validate_catches_a_swapped_pair() {
        let sorted: Vec<u64> = (0..40).collect();
        let mut e = Eytzinger::new(&sorted);
        let (a, b) = (e.keys.get(3), e.keys.get(4));
        e.keys.set(3, b);
        e.keys.set(4, a);
        assert_eq!(e.validate(), Err(Corrupt));
        let mut t = BlockTree::new(&sorted);
        let (a, b) = (t.keys.get(0), t.keys.get(1));
        t.keys.set(0, b);
        t.keys.set(1, a);
        assert_eq!(t.validate(), Err(Corrupt));
    }
}
