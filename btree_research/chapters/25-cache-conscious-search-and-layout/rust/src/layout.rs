//! Two static layouts of the same sorted keys, both stored on cache-line
//! boundaries, both searched without an unpredictable branch (twin of
//! zig/src/layout.zig).
//!
//!   * `Eytzinger`: a binary search tree stored in breadth-first order, the
//!     way a binary heap is stored. Children of slot k are slots 2k and 2k+1.
//!   * `BlockTree`: the same idea with 8 keys (one cache line) per node and 9
//!     children: one key line per level. It borrows the B-tree's node shape
//!     (8 keys, 9 children, one unit of transfer) but it is NOT a B-tree. It
//!     is a complete 9-ary search tree in breadth-first numbering: leaves may
//!     sit on two adjacent levels and a node may have fewer children than
//!     keys + 1.
//!
//! Both are built once from sorted input and never modified (compare the
//! bulk-loaded trees of chapter 16). Both keep a `rank` array that maps a slot
//! back to the index in sorted order, so that their answers can be compared
//! with the searches in search.rs. A real index would store the payload
//! (a child page id, a row id) in that parallel array instead.
//!
//! `rank` is a second array, so reading it costs a cache line of its own.
//! Both searches therefore read it exactly ONCE, after the descent, and
//! report that read to the tracer (`tracer.side`).

use crate::search::{Keys, rank8};
use crate::trace::{LANES, LINE_BYTES, Tracer};

/// Padding value: compares greater than or equal to every needle, so padded
/// slots never count as "smaller". Real keys must be below it.
pub const SENTINEL: u64 = u64::MAX;

/// Eight keys that are guaranteed to start on a 64-byte boundary.
///
/// Zig asks the allocator: `gpa.alignedAlloc(u64, .fromByteUnits(64), n)`. Safe Rust has
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

    /// The first `n` keys, without the padding, as something the scalar
    /// searches accept. Zig simply slices the aligned array (`padded[0..n]`).
    /// Safe Rust cannot turn a `&[Line]` into a `&[u64]`, so the searches are
    /// generic over `search::Keys` and this view implements it.
    pub fn sorted(&self, n: usize) -> SortedView<'_> {
        assert!(n <= self.len());
        SortedView { keys: self, n }
    }

    pub fn iter(&self) -> impl Iterator<Item = u64> + '_ {
        self.lines.iter().flat_map(|line| line.0.iter().copied())
    }
}

/// `n` sorted keys that start on a cache-line boundary: the classic and
/// halving searches run on this, so the model's "the array starts on a line
/// boundary" is true for them too. (A `Vec<u64>` only promises 8 bytes.)
#[derive(Debug, Clone, Copy)]
pub struct SortedView<'a> {
    keys: &'a AlignedKeys,
    n: usize,
}

impl Keys for SortedView<'_> {
    fn len(&self) -> usize {
        self.n
    }

    fn key(&self, i: usize) -> u64 {
        assert!(i < self.n);
        self.keys.get(i)
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
        // The only read of the second array: one more cache line.
        tracer.side(k);
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
    /// rank[slot] = index in sorted order, n for padding slots. One entry
    /// longer than `keys`: rank[keys.len()] = n is the "no key is >= the
    /// needle" answer, so the search can end with one unconditional read.
    pub rank: Vec<u32>,
    pub n: usize,
}

impl BlockTree {
    pub const FANOUT: usize = LANES + 1;

    pub fn new(sorted: &[u64]) -> Self {
        let n = sorted.len();
        let keys = AlignedKeys::filled(n, SENTINEL);
        let rank = vec![n as u32; keys.len() + 1];
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
    ///
    /// The descent only REMEMBERS the candidate's slot number. It does not
    /// look the rank up on every level: `rank` is another array, and each
    /// lookup there would be another cache line, about one per level, as many
    /// again as the key lines. One read after the loop is enough.
    pub fn lower_bound<T: Tracer>(&self, key: u64, tracer: &mut T) -> usize {
        let mut slot = self.keys.len(); // the "no key" entry of rank
        let mut block = 0;
        while let Some(line) = self.keys.lines().get(block) {
            tracer.cmp_block(block * LANES, LANES);
            let r = rank8(&line.0, key);
            // A select between two values that are already in registers: no
            // memory is touched. (Exercise 5 removes even this select.)
            slot = if r < LANES { block * LANES + r } else { slot };
            block = block * Self::FANOUT + r + 1;
        }
        tracer.side(slot);
        self.rank[slot] as usize
    }

    pub fn validate(&self) -> Result<(), Corrupt> {
        if self.keys.len() + 1 != self.rank.len()
            || self.keys.len() != self.n.next_multiple_of(LANES)
            || self.rank[self.keys.len()] as usize != self.n
        {
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
    use crate::search::{
        Select, lower_bound_classic, lower_bound_halving, lower_bound_linear, lower_bound_vector,
    };
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
        assert_eq!(t.key_lines(), 2); // slots 1..7 share line 0, slot 11 is in line 1
        assert_eq!(t.side_lines(), 1); // rank[11]
        assert_eq!(t.lines_read(), 3);
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
        assert_eq!(t.key_lines(), 2);
        assert_eq!(t.side_lines(), 1); // one rank read, after the descent
        assert_eq!(t.lines_read(), 3);
        assert_eq!(b.rank[b.keys.len()], 15); // the "no key" entry
        assert_eq!(b.lower_bound(151, &mut NoTrace), 15);
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
                    // Two lines are read without a hint that had lead time:
                    // key line 0 (slots 1..7; below 8 keys the clamped hint
                    // names line 0 itself, but in the same step as the read)
                    // and the rank line.
                    assert_eq!(tp.uncovered, 2);
                    // One key line per level of the 9-way tree.
                    assert_eq!(tb.steps, tb.key_lines());
                }
                // Regression (review round 1, G1): the rank array is read, and
                // counted, exactly once per lookup, whatever the depth. Even
                // an empty layout reads its "no key" entry.
                assert_eq!(te.side_lines(), 1);
                assert_eq!(tb.side_lines(), 1);
                assert_eq!(te.lines_read(), te.key_lines() + 1);
                assert_eq!(tb.lines_read(), tb.key_lines() + 1);
                assert_eq!(tb.uncovered, tb.lines_read()); // no hints at all
            }
            assert_eq!(e.lower_bound(SENTINEL, false, &mut NoTrace), n);
            assert_eq!(b.lower_bound(SENTINEL, &mut NoTrace), n);
        }
    }

    // Regression (review round 1, G6): the classic and halving searches of the
    // scenario ran on a `Vec<u64>`, which need not start on a line boundary.
    #[test]
    fn sorted_view_is_line_aligned_and_searches_like_the_slice() {
        let sorted: Vec<u64> = (0..37).map(|i| i * 3 + 1).collect();
        let padded = AlignedKeys::padded(&sorted);
        assert_eq!(padded.lines().as_ptr().addr() % LINE_BYTES, 0);
        let view = padded.sorted(sorted.len());
        assert_eq!(view.len(), 37);
        for needle in 0..120 {
            let want = lower_bound_linear(&sorted, needle);
            let mut a = Trace::new(Layout::KEYS);
            let mut b = Trace::new(Layout::KEYS);
            assert_eq!(lower_bound_classic(&view, needle, &mut NoTrace), want);
            assert_eq!(
                lower_bound_halving(Select::Hinted, true, &view, needle, &mut a),
                want
            );
            assert_eq!(
                lower_bound_halving(Select::Hinted, true, &sorted[..], needle, &mut b),
                want
            );
            assert_eq!(a.probes(), b.probes());
        }
        assert_eq!(lower_bound_classic(&padded.sorted(0), 5, &mut NoTrace), 0);
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
        t.keys.set(0, a);
        t.keys.set(1, b);
        assert_eq!(t.validate(), Ok(()));
        let no_key = t.keys.len();
        t.rank[no_key] = 0; // the "no key" entry must stay n
        assert_eq!(t.validate(), Err(Corrupt));
    }
}
