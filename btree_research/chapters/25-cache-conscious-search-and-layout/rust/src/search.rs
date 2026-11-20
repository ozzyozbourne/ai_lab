//! Four ways to find the lower bound in a sorted `&[u64]` (twin of
//! zig/src/search.zig).
//!
//! Every function returns the same thing chapter 02 called the insertion
//! index: the number of keys strictly less than `key` (so `keys.len()` when
//! all keys are smaller). They differ only in which keys they look at, in
//! what order, and in whether the CPU has to guess a branch.

use crate::layout::AlignedKeys;
use crate::trace::{LANES, Tracer};

/// What the scalar searches need from a sorted run of keys. Zig passes a
/// slice. Here there are two implementations: a plain `[u64]`, and
/// `layout::SortedView`, the line-aligned storage the scenario searches.
pub trait Keys {
    fn len(&self) -> usize;
    fn key(&self, i: usize) -> u64;
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl Keys for [u64] {
    #[inline]
    fn len(&self) -> usize {
        <[u64]>::len(self)
    }

    #[inline]
    fn key(&self, i: usize) -> u64 {
        self[i]
    }
}

/// The oracle: count the smaller keys one by one. Obviously correct.
pub fn lower_bound_linear(keys: &[u64], key: u64) -> usize {
    keys.iter().map(|&k| usize::from(k < key)).sum()
}

/// Chapter 02's loop. Invariant: every key left of `lo` is < key, every key
/// at or right of `hi` is >= key. The `if` is a data-dependent branch: for
/// random needles the predictor is wrong about half the time, and the number
/// of iterations depends on the path taken.
pub fn lower_bound_classic<K: Keys + ?Sized, T: Tracer>(
    keys: &K,
    key: u64,
    tracer: &mut T,
) -> usize {
    let mut lo = 0;
    let mut hi = keys.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        tracer.cmp(mid);
        if keys.key(mid) < key {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}

/// How the halving loop moves `offset`. All three compare exactly the same
/// keys in the same order; only the machine code may differ.
///
///   * `Branch`: a plain `if`. The compiler usually emits a conditional jump.
///   * `Arithmetic`: `offset += half * (0 or 1)`. Looks branch-free in the
///     source, but the optimiser recognises the pattern and is free to turn
///     it back into a jump (LLVM did, when we looked: see the README).
///   * `Hinted`: `std::hint::select_unpredictable` (stable since Rust 1.88).
///     This tells the compiler what the arithmetic trick only implies, and is
///     what produced a conditional move (`cmov`) on x86-64. Zig spells the
///     same request `@branchHint(.unpredictable)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Select {
    Branch,
    Arithmetic,
    Hinted,
}

/// The "offset + length" binary search (the shape of TigerBeetle's
/// `binary_search_values_upsert_index`). The window is `[offset, offset+length)`
/// and `length` shrinks by `half` on EVERY iteration whichever way the
/// comparison goes. Consequences:
///
///   * the trip count depends only on `keys.len()` (see `halving_comparisons`),
///     so the loop branch is perfectly predictable;
///   * the comparison only decides whether `offset` moves, which can be a
///     conditional move instead of a jump (see `Select`);
///   * both possible next probes are known one step ahead, so they can be
///     prefetched.
///
/// Invariant: keys[offset - 1] < key (or offset == 0), and
/// key <= keys[offset + length] (or offset + length == keys.len()).
///
/// Zig makes `select` and `prefetch` comptime parameters, so each combination
/// is a separate function with no test left in the loop. Here they are plain
/// arguments: the function is small, gets inlined at each call site with
/// constant arguments, and the optimiser removes the tests the same way.
pub fn lower_bound_halving<K: Keys + ?Sized, T: Tracer>(
    select: Select,
    prefetch: bool,
    keys: &K,
    key: u64,
    tracer: &mut T,
) -> usize {
    if keys.is_empty() {
        return 0;
    }
    let mut offset = 0;
    let mut length = keys.len();
    while length > 1 {
        let half = length / 2;
        let mid = offset + half;
        if prefetch {
            // The next iteration will compare keys[offset + next_half] or
            // keys[mid + next_half]. The Zig twin issues two real `@prefetch`
            // hints here. Stable Rust has no safe prefetch (the x86 intrinsic
            // `_mm_prefetch` takes a raw pointer and is `unsafe`), and this
            // crate forbids unsafe code, so the Rust version only RECORDS the
            // hints: the counts match Zig's, the machine code does not hint.
            let next_half = (length - half) / 2;
            tracer.prefetch(offset + next_half);
            tracer.prefetch(mid + next_half);
        }
        tracer.cmp(mid);
        let take_upper = keys.key(mid) < key;
        match select {
            Select::Branch => {
                if take_upper {
                    offset = mid;
                }
            }
            Select::Arithmetic => offset += half * usize::from(take_upper),
            Select::Hinted => offset = std::hint::select_unpredictable(take_upper, mid, offset),
        }
        length -= half;
    }
    // One key is left in the window. It is the answer unless it is too small.
    tracer.cmp(offset);
    offset + usize::from(keys.key(offset) < key)
}

/// Comparisons made by `lower_bound_halving` for an array of `n` keys:
/// ceil(log2(n)) halvings plus the final check. Independent of the needle.
pub fn halving_comparisons(n: usize) -> u32 {
    if n == 0 {
        return 0;
    }
    // ceil(log2(n)) = number of bits needed to write n - 1.
    (usize::BITS - (n - 1).leading_zeros()) + 1
}

/// Rank of `key` inside one 8-key block: how many of the 8 keys are smaller.
///
/// Zig writes this with `@Vector(8, u64)`, a compare and a popcount. Stable
/// Rust has no portable SIMD type (`std::simd` is nightly only), so this is
/// the "chunked auto-vectorisable loop": a fixed trip count of 8, no early
/// exit, and a body that only adds 0 or 1. The optimiser is free to turn it
/// into the same vector compare; it is not obliged to.
pub fn rank8(block: &[u64; LANES], key: u64) -> usize {
    let mut count = 0;
    for &k in block {
        count += usize::from(k < key);
    }
    count
}

/// Linear scan, eight keys at a time. `padded` is the sorted keys followed by
/// `u64::MAX` sentinels up to a multiple of 8 (see `AlignedKeys::padded`): a
/// sentinel is never smaller than any needle, so the tail needs no special
/// case. Reads every line of the array, which is why it only wins when the
/// array is a handful of lines.
pub fn lower_bound_vector<T: Tracer>(padded: &AlignedKeys, key: u64, tracer: &mut T) -> usize {
    let mut count = 0;
    for (b, line) in padded.lines().iter().enumerate() {
        tracer.cmp_block(b * LANES, LANES);
        count += rank8(&line.0, key);
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trace::{Layout, NoTrace, Trace};

    #[test]
    fn rank8_counts_the_smaller_keys() {
        let block = [10, 20, 30, 40, 50, 60, 70, 80];
        assert_eq!(rank8(&block, 5), 0);
        assert_eq!(rank8(&block, 35), 3);
        assert_eq!(rank8(&block, 40), 3); // equal is not smaller
        assert_eq!(rank8(&block, 99), 8);
    }

    #[test]
    fn exhaustive_every_algorithm_equals_the_linear_scan_for_every_length_up_to_70() {
        // Keys 10, 20, 30, ...; needles cover below, equal, between and above.
        for n in 0..71usize {
            let keys: Vec<u64> = (1..=n as u64).map(|i| i * 10).collect();
            let padded = AlignedKeys::padded(&keys);
            for needle in (0..=(n as u64 + 1) * 10).step_by(5) {
                let want = lower_bound_linear(&keys, needle);
                assert_eq!(lower_bound_classic(&keys[..], needle, &mut NoTrace), want);
                assert_eq!(
                    lower_bound_halving(Select::Branch, false, &keys[..], needle, &mut NoTrace),
                    want
                );
                assert_eq!(
                    lower_bound_halving(Select::Arithmetic, false, &keys[..], needle, &mut NoTrace),
                    want
                );
                assert_eq!(
                    lower_bound_halving(Select::Hinted, true, &keys[..], needle, &mut NoTrace),
                    want
                );
                assert_eq!(lower_bound_vector(&padded, needle, &mut NoTrace), want);
            }
        }
    }

    #[test]
    fn halving_comparison_count_depends_only_on_the_length() {
        let keys: Vec<u64> = (0..300).map(|i| i * 3).collect();
        for n in 0..=keys.len() {
            for needle in 0..3 * n as u64 + 3 {
                let mut t = Trace::new(Layout::KEYS);
                lower_bound_halving(Select::Hinted, false, &keys[..n], needle, &mut t);
                assert_eq!(t.comparisons, halving_comparisons(n));
            }
        }
        // 15 keys: 15 -> 8 -> 4 -> 2 -> 1 is four halvings, plus the final check.
        assert_eq!(halving_comparisons(15), 5);
        assert_eq!(halving_comparisons(1), 1);
    }

    #[test]
    fn halving_branch_arithmetic_hinted_and_prefetch_variants_probe_identical_keys() {
        let keys: Vec<u64> = (0..1000).map(|i| i * 2).collect();
        for needle in (0..2010).step_by(7) {
            let mut a = Trace::new(Layout::KEYS);
            let mut b = Trace::new(Layout::KEYS);
            let mut c = Trace::new(Layout::KEYS);
            let mut d = Trace::new(Layout::KEYS);
            let ra = lower_bound_halving(Select::Branch, false, &keys[..], needle, &mut a);
            let rb = lower_bound_halving(Select::Arithmetic, false, &keys[..], needle, &mut b);
            let rc = lower_bound_halving(Select::Hinted, true, &keys[..], needle, &mut c);
            let rd = lower_bound_halving(Select::Hinted, false, &keys[..], needle, &mut d);
            assert_eq!(ra, rb);
            assert_eq!(ra, rc);
            assert_eq!(ra, rd);
            assert_eq!(a.probes(), b.probes());
            assert_eq!(a.probes(), c.probes());
            assert_eq!(a.probes(), d.probes());
            assert_eq!(a.lines_read(), c.lines_read());
            // Every line except the very first probe was hinted at least one
            // comparison before it was read.
            assert_eq!(c.uncovered, 1);
            assert_eq!(a.uncovered, a.lines_read());
            assert_eq!(c.prefetches, 2 * (c.comparisons - 1));
        }
    }

    #[test]
    fn classic_between_floor_log2_n_and_floor_log2_n_plus_1_comparisons() {
        let keys: Vec<u64> = (0..200).collect();
        for n in 1..=keys.len() {
            let floor_log = n.ilog2();
            for needle in 0..=n as u64 {
                let mut t = Trace::new(Layout::KEYS);
                lower_bound_classic(&keys[..n], needle, &mut t);
                assert!(t.comparisons >= floor_log && t.comparisons <= floor_log + 1);
            }
        }
    }

    #[test]
    fn vector_scan_one_step_and_one_line_per_eight_keys() {
        let keys: Vec<u64> = (0..60).collect();
        let padded = AlignedKeys::padded(&keys);
        assert_eq!(padded.len(), 64);
        let mut t = Trace::new(Layout::KEYS);
        assert_eq!(lower_bound_vector(&padded, 33, &mut t), 33);
        assert_eq!(t.comparisons, 64);
        assert_eq!(t.steps, 8);
        assert_eq!(t.lines_read(), 8);
        // The largest possible needle still stops at the sentinels.
        assert_eq!(lower_bound_vector(&padded, u64::MAX, &mut NoTrace), 60);
    }
}
