//! Chapter 02: searching a sorted node.
//!
//! A B-tree node is a small sorted array of keys. Every tree operation starts
//! by asking one question of that array: "where does this key belong?".
//! This file answers it with two functions, `lower_bound` and `upper_bound`,
//! and builds everything else (exact lookup, insertion index, ranges with
//! inclusive / exclusive bounds, neighbours, galloping) on top of them.
//!
//! Nothing here allocates. All functions borrow a slice the caller owns,
//! which is exactly the situation inside a tree: the node (or the disk page)
//! already holds the keys, and the search only looks at them.
//!
//! The standard library has these already (`partition_point`,
//! `binary_search`); they are written out here because the loop and its
//! invariant are the subject of the chapter. The tests compare against std.

use std::ops::{Bound, Range};

/// True if `keys` is in non-decreasing order (duplicates allowed).
/// This is the precondition of every search function below. Binary search on
/// an unsorted array does not crash, it silently returns nonsense, so tests
/// and `validate` functions check it explicitly.
pub fn is_sorted(keys: &[u64]) -> bool {
    keys.windows(2).all(|pair| pair[0] <= pair[1])
}

/// Index of the first element that is `>= key`, or `keys.len()` if there is none.
///
/// Equivalent statements of the same result `i`:
///   * every key in `keys[..i]` is `< key`, every key in `keys[i..]` is `>= key`;
///   * `i` is the number of keys smaller than `key`;
///   * `i` is the leftmost position where `key` can be inserted so that the
///     array stays sorted.
///
/// The candidate ANSWERS are the closed range of indices `[lo, hi]` (the answer
/// can be `keys.len()`, so there are `len + 1` candidates); the unknown ELEMENTS
/// are the half-open range `keys[lo..hi]`. The loop keeps this invariant:
///
/// ```text
///     keys[..lo]  are all <  key        (known to be left of the answer)
///     keys[hi..]  are all >= key        (known to be at or right of it)
/// ```
///
/// Both ranges start empty, so the invariant holds trivially before the loop.
/// Each iteration looks at one unknown element and moves it into one of the
/// two ranges. When `lo == hi` nothing is unknown, and `lo` is the answer.
pub fn lower_bound(keys: &[u64], key: u64) -> usize {
    let mut lo = 0;
    let mut hi = keys.len();
    while lo < hi {
        // Not `(lo + hi) / 2`: the sum can overflow. `lo + (hi - lo) / 2`
        // cannot, because `hi - lo` is at most `hi`. Since `lo < hi`, we get
        // `lo <= mid < hi`, so `keys[mid]` is always a real element.
        let mid = lo + (hi - lo) / 2;
        if keys[mid] < key {
            // keys[mid] and everything left of it is < key.
            lo = mid + 1;
        } else {
            // keys[mid] >= key, so mid is still a candidate answer: keep it
            // (`hi = mid`, not `mid - 1`).
            hi = mid;
        }
    }
    lo
}

/// Index of the first element that is `> key`, or `keys.len()` if there is none.
///
/// The only difference from `lower_bound` is `<=` instead of `<`: equal keys
/// are now pushed to the left side. Invariant:
///
/// ```text
///     keys[..lo]  are all <= key
///     keys[hi..]  are all >  key
/// ```
///
/// `i` is the rightmost position where `key` can be inserted so that the
/// array stays sorted, and the number of keys `<= key`.
pub fn upper_bound(keys: &[u64], key: u64) -> usize {
    let mut lo = 0;
    let mut hi = keys.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if keys[mid] <= key {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}

/// What a node search should return: not "the key or nothing", but always a
/// position. `index` is the lower bound; `found` says whether the key at that
/// position is the one searched for.
///
///   found = true   keys[index] == key (the first one, if there are duplicates)
///   found = false  key is absent and `index` is where to insert it
///
/// One search then serves `get` (use `found`), `put` (overwrite at `index` or
/// insert at `index`), `delete`, and the start of a range scan.
///
/// std's `slice::binary_search` returns the same information as
/// `Result<usize, usize>` (`Ok(index)` / `Err(insertion_index)`), except that
/// with duplicates `Ok` may point at ANY of the equal elements.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchResult {
    pub found: bool,
    pub index: usize,
}

pub fn search(keys: &[u64], key: u64) -> SearchResult {
    let index = lower_bound(keys, key);
    // `get` covers the case index == keys.len(): no element there.
    SearchResult { found: keys.get(index) == Some(&key), index }
}

/// All positions holding `key`: `lower_bound..upper_bound`. Empty (start ==
/// end == insertion index) when the key is absent.
///
/// Zig has its own `Span { start, end }` struct for half-open index ranges;
/// Rust already has one, `Range<usize>`, and it can index a slice directly.
/// Half-open ranges are used for the same reason the search itself is
/// half-open: the length is `end - start`, the empty range needs no special
/// value, and adjacent ranges share a bound.
pub fn equal_range(keys: &[u64], key: u64) -> Range<usize> {
    lower_bound(keys, key)..upper_bound(keys, key)
}

/// Translate a key range with inclusive / exclusive ends into a half-open
/// index range. This table is the whole trick:
///
/// ```text
///     start:  >= k  -> lower_bound(k)      > k  -> upper_bound(k)
///     end:    <= k  -> upper_bound(k)      < k  -> lower_bound(k)
/// ```
///
/// (An inclusive end must step PAST the equal keys, an exclusive start too.)
/// `Bound` is std's `std::ops::Bound`, the type behind `a..b`, `a..=b`, `..`.
pub fn range_span(keys: &[u64], lo: Bound<u64>, hi: Bound<u64>) -> Range<usize> {
    let start = match lo {
        Bound::Unbounded => 0,
        Bound::Included(k) => lower_bound(keys, k),
        Bound::Excluded(k) => upper_bound(keys, k),
    };
    let end = match hi {
        Bound::Unbounded => keys.len(),
        Bound::Included(k) => upper_bound(keys, k),
        Bound::Excluded(k) => lower_bound(keys, k),
    };
    // An empty or inverted key range such as (7, 7) or [9, 3] gives
    // end < start. Clamp: slicing with start > end would panic.
    start..end.max(start)
}

/// Index of the last element `<= key`, or `None` if every element is greater.
/// This is "upper bound minus one": the predecessor query. Interior nodes of
/// a B-tree use this shape to pick the child to descend into (chapter 03).
pub fn last_less_or_equal(keys: &[u64], key: u64) -> Option<usize> {
    // `checked_sub` turns the underflow at 0 into None instead of a panic.
    upper_bound(keys, key).checked_sub(1)
}

/// Index of the last element `< key`, or `None`: "lower bound minus one".
pub fn last_less(keys: &[u64], key: u64) -> Option<usize> {
    lower_bound(keys, key).checked_sub(1)
}

/// Lower bound of `key` in `keys[from..]`, returned as an index into `keys`.
/// The result is `max(from, lower_bound(keys, key))`.
///
/// Use it when the answer is expected to be CLOSE to `from`: for example when
/// looking up a sorted batch of keys, where each search can start where the
/// previous one ended. Instead of halving the whole array, it first doubles a
/// step (1, 2, 4, 8, ...) until it jumps past the answer, then runs a normal
/// binary search inside the last jump. If the answer is `d` positions after
/// `from`, this costs about `2 * log2(d)` comparisons instead of `log2(n)`.
pub fn gallop_lower_bound(keys: &[u64], from: usize, key: u64) -> usize {
    assert!(from <= keys.len());
    if from == keys.len() || keys[from] >= key {
        return from;
    }

    // Invariant of the galloping phase: keys[below] < key.
    let mut below = from;
    let mut step = 1;
    // Exclusive upper end of the bracket that must contain the answer.
    let mut hi = keys.len();
    // `step < keys.len() - below` is `below + step < keys.len()` written so
    // that it cannot overflow.
    while step < keys.len() - below {
        let probe = below + step;
        if keys[probe] >= key {
            hi = probe; // keys[probe] is a candidate answer
            break;
        }
        below = probe;
        step *= 2; // cannot overflow: step < keys.len()
    }
    // Now keys[below] < key, and the answer is in (below, hi].
    let first = below + 1;
    first + lower_bound(&keys[first..hi], key)
}

/// Reference implementations: one line of logic each, obviously correct, O(n).
/// The tests compare every clever function against these.
pub fn linear_lower_bound(keys: &[u64], key: u64) -> usize {
    keys.iter().position(|&k| k >= key).unwrap_or(keys.len())
}

pub fn linear_upper_bound(keys: &[u64], key: u64) -> usize {
    keys.iter().position(|&k| k > key).unwrap_or(keys.len())
}

/// Number of loop iterations binary search needs for n elements, worst case:
/// the number of bits of n (0 for n = 0, 1 for n = 1, 2 for n = 2..3, ...).
pub fn max_comparisons(n: usize) -> u64 {
    u64::from(usize::BITS - n.leading_zeros())
}

/// Fill `keys` with a sorted sequence: each key is the previous one plus a
/// random gap in [0, max_gap). A gap of 0 produces a duplicate.
pub fn fill_sorted(rng: &mut crate::prng::SplitMix64, keys: &mut [u64], max_gap: u64) {
    let mut previous = 0;
    for k in keys {
        previous += rng.below(max_gap);
        *k = previous;
    }
}

/// Carve `n` keys off the front of a scratch buffer and fill them with a
/// sorted sequence. Returns the keys and the unused rest of the buffer, or
/// `None` if the buffer is too small.
///
/// This is the Rust counterpart of Zig's `makeSorted(allocator, ...)` with a
/// `FixedBufferAllocator`: `split_at_mut` is a bump allocator that the borrow
/// checker can see through. The two halves are disjoint borrows of one
/// buffer, and "freeing" is simply the end of their lifetimes.
pub fn make_sorted<'a>(
    scratch: &'a mut [u64],
    rng: &mut crate::prng::SplitMix64,
    n: usize,
    max_gap: u64,
) -> Option<(&'a mut [u64], &'a mut [u64])> {
    let (keys, rest) = scratch.split_at_mut_checked(n)?;
    fill_sorted(rng, keys, max_gap);
    Some((keys, rest))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;

    #[test]
    fn hand_example_lower_and_upper_bound_on_a_node_with_duplicates() {
        let keys = [3, 7, 7, 7, 12, 15, 15, 20];
        assert!(is_sorted(&keys));
        assert_eq!(lower_bound(&keys, 0), 0);
        assert_eq!(upper_bound(&keys, 0), 0);
        assert_eq!(lower_bound(&keys, 7), 1);
        assert_eq!(upper_bound(&keys, 7), 4);
        assert_eq!(lower_bound(&keys, 8), 4);
        assert_eq!(upper_bound(&keys, 8), 4);
        assert_eq!(lower_bound(&keys, 20), 7);
        assert_eq!(upper_bound(&keys, 20), 8);
        assert_eq!(lower_bound(&keys, 21), 8);
        assert_eq!(equal_range(&keys, 15), 5..7);
        assert_eq!(equal_range(&keys, 13).len(), 0);
    }

    #[test]
    fn empty_and_single_element_nodes() {
        let empty: [u64; 0] = [];
        assert_eq!(lower_bound(&empty, 5), 0);
        assert_eq!(upper_bound(&empty, 5), 0);
        assert_eq!(search(&empty, 5), SearchResult { found: false, index: 0 });
        assert_eq!(last_less_or_equal(&empty, 5), None);
        assert_eq!(gallop_lower_bound(&empty, 0, 5), 0);

        let one = [5];
        assert_eq!(search(&one, 4), SearchResult { found: false, index: 0 });
        assert_eq!(search(&one, 5), SearchResult { found: true, index: 0 });
        assert_eq!(search(&one, 6), SearchResult { found: false, index: 1 });
    }

    #[test]
    fn extreme_keys_0_and_max_need_no_special_case() {
        let max = u64::MAX;
        let keys = [0, 0, 1, max - 1, max, max];
        assert_eq!(lower_bound(&keys, 0), 0);
        assert_eq!(upper_bound(&keys, 0), 2);
        assert_eq!(lower_bound(&keys, max), 4);
        assert_eq!(upper_bound(&keys, max), 6);
        assert_eq!(range_span(&keys, Bound::Included(0), Bound::Included(max)), 0..6);
    }

    #[test]
    fn search_result_is_the_insertion_index() {
        let keys = [1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30];
        assert_eq!(search(&keys, 12), SearchResult { found: true, index: 6 });
        assert_eq!(search(&keys, 13), SearchResult { found: false, index: 7 });
        assert_eq!(search(&keys, 0), SearchResult { found: false, index: 0 });
        assert_eq!(search(&keys, 31), SearchResult { found: false, index: 12 });
    }

    #[test]
    fn range_bounds_the_four_inclusive_exclusive_combinations() {
        use Bound::{Excluded, Included, Unbounded};
        let keys = [1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30];
        assert_eq!(range_span(&keys, Included(5), Included(17)), 2..9);
        assert_eq!(range_span(&keys, Excluded(5), Included(17)), 3..9);
        assert_eq!(range_span(&keys, Included(5), Excluded(17)), 2..8);
        assert_eq!(range_span(&keys, Excluded(5), Excluded(17)), 3..8);
        // Bounds that are not keys: all four combinations agree.
        assert_eq!(range_span(&keys, Excluded(4), Excluded(16)), 2..8);
        assert_eq!(range_span(&keys, Included(4), Included(16)), 2..8);
        // Unbounded ends.
        assert_eq!(range_span(&keys, Unbounded, Unbounded), 0..12);
        assert_eq!(range_span(&keys, Excluded(20), Unbounded), 10..12);
        // Empty and inverted key ranges are clamped to an empty span.
        assert_eq!(range_span(&keys, Excluded(7), Excluded(7)).len(), 0);
        assert_eq!(range_span(&keys, Included(20), Included(5)).len(), 0);
        assert_eq!(range_span(&keys, Included(8), Included(9)).len(), 0);
    }

    #[test]
    fn neighbours_last_key_below_or_at_a_key() {
        let keys = [1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30];
        assert_eq!(last_less_or_equal(&keys, 12), Some(6));
        assert_eq!(last_less_or_equal(&keys, 13), Some(6));
        assert_eq!(last_less(&keys, 12), Some(5));
        assert_eq!(last_less_or_equal(&keys, 0), None);
        assert_eq!(last_less(&keys, 1), None);
        assert_eq!(last_less(&keys, 1000), Some(11));
    }

    #[test]
    fn trap_the_midpoint_lo_plus_hi_over_2_overflows() {
        // Shown with 8-bit indices so that the numbers fit in a comment. With
        // usize the same thing happens once lo + hi exceeds the integer range.
        let lo: u8 = 200;
        let hi: u8 = 250;
        // 200 + 250 = 450 does not fit in a u8. Rust's `+` panics on overflow
        // in debug builds; `wrapping_add` wraps like C does, giving
        // (450 - 256) / 2 = 97, an index that is not even between lo and hi.
        assert_eq!(lo.wrapping_add(hi) / 2, 97);
        assert_eq!(lo.checked_add(hi), None);
        // The safe form stays inside [lo, hi).
        assert_eq!(lo + (hi - lo) / 2, 225);
    }

    #[test]
    fn max_comparisons_is_the_bit_length() {
        assert_eq!(max_comparisons(0), 0);
        assert_eq!(max_comparisons(1), 1);
        assert_eq!(max_comparisons(3), 2);
        assert_eq!(max_comparisons(4), 3);
        assert_eq!(max_comparisons(12), 4);
        assert_eq!(max_comparisons(4096), 13);
    }

    // --- Exhaustive testing ------------------------------------------------
    //
    // Binary search has few inputs that matter: the length of the array,
    // where the duplicates are, and where the key falls relative to the
    // elements. So instead of picking examples we enumerate ALL sorted arrays
    // of length 0..7 over the alphabet {1, 3, 5, 7} and search each one for
    // EVERY key 0..8 (below, between, equal to and above every element).

    const ALPHABET: [u64; 4] = [1, 3, 5, 7];
    const MAX_EXHAUSTIVE_LEN: usize = 7;

    #[derive(Debug, PartialEq, Eq)]
    struct Counterexample {
        keys: Vec<u64>,
        key: u64,
        got: usize,
        want: usize,
    }

    type BoundFn = fn(&[u64], u64) -> usize;

    /// Call `visit` with every sorted array of length 0..=MAX_EXHAUSTIVE_LEN
    /// over ALPHABET, shortest first. Stops early when `visit` returns false.
    fn for_each_sorted_array(mut visit: impl FnMut(&[u64]) -> bool) {
        let mut keys_buf = [0u64; MAX_EXHAUSTIVE_LEN];
        for n in 0..=MAX_EXHAUSTIVE_LEN {
            let keys = &mut keys_buf[..n];
            // `code` counts through all ALPHABET.len()^n digit strings; the
            // ones that are not sorted are skipped.
            for code in 0..ALPHABET.len().pow(n as u32) {
                let mut rest = code;
                for k in keys.iter_mut() {
                    *k = ALPHABET[rest % ALPHABET.len()];
                    rest /= ALPHABET.len();
                }
                if is_sorted(keys) && !visit(keys) {
                    return;
                }
            }
        }
    }

    /// Run `candidate` on every small input and return the first input where
    /// it disagrees with `reference` (shortest array first), or None.
    fn first_counterexample(candidate: BoundFn, reference: BoundFn) -> Option<Counterexample> {
        let mut found = None;
        for_each_sorted_array(|keys| {
            for key in 0..9 {
                let got = candidate(keys, key);
                let want = reference(keys, key);
                if got != want {
                    found = Some(Counterexample { keys: keys.to_vec(), key, got, want });
                    return false;
                }
            }
            true
        });
        found
    }

    #[test]
    fn exhaustive_lower_bound_and_upper_bound_agree_with_a_linear_scan() {
        assert_eq!(first_counterexample(lower_bound, linear_lower_bound), None);
        assert_eq!(first_counterexample(upper_bound, linear_upper_bound), None);
    }

    #[test]
    fn exhaustive_derived_results_and_galloping_from_every_start() {
        let mut arrays = 0;
        for_each_sorted_array(|keys| {
            arrays += 1;
            for key in 0..9 {
                let lower = linear_lower_bound(keys, key);
                let upper = linear_upper_bound(keys, key);

                // The two bounds bracket exactly the copies of `key`.
                assert!(lower <= upper);
                for (i, &k) in keys.iter().enumerate() {
                    assert_eq!(k == key, (lower..upper).contains(&i));
                }

                let r = search(keys, key);
                assert_eq!(r.index, lower);
                assert_eq!(r.found, lower != upper);

                assert_eq!(last_less_or_equal(keys, key), upper.checked_sub(1));
                assert_eq!(last_less(keys, key), lower.checked_sub(1));

                // Galloping from any start gives the lower bound, unless the
                // start is already past it.
                for from in 0..=keys.len() {
                    assert_eq!(gallop_lower_bound(keys, from, key), from.max(lower));
                }
            }
            true
        });
        // 1 + 4 + 10 + 20 + 35 + 56 + 84 + 120 sorted arrays of length 0..7.
        assert_eq!(arrays, 330);
    }

    // Two classic wrong versions. They exist so that the tests can show the
    // exhaustive checker catching them, with the smallest failing input.

    /// Bug 1: "closed interval" search that starts with hi = len - 1 but
    /// keeps the half-open loop. The answer `len` (key greater than
    /// everything) is no longer reachable.
    fn buggy_lower_bound_closed(keys: &[u64], key: u64) -> usize {
        if keys.is_empty() {
            return 0;
        }
        let mut lo = 0;
        let mut hi = keys.len() - 1;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if keys[mid] < key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    /// Bug 2: return as soon as an equal key is seen. Correct for unique
    /// keys, but with duplicates it returns SOME equal element, not the first.
    fn buggy_lower_bound_early_exit(keys: &[u64], key: u64) -> usize {
        let mut lo = 0;
        let mut hi = keys.len();
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if keys[mid] == key {
                return mid;
            }
            if keys[mid] < key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    #[test]
    fn trap_the_exhaustive_checker_finds_the_smallest_failing_input_of_two_classic_bugs() {
        // Bug 1 fails on the smallest possible input: one key, search above it.
        assert_eq!(
            first_counterexample(buggy_lower_bound_closed, linear_lower_bound),
            Some(Counterexample { keys: vec![1], key: 2, got: 0, want: 1 })
        );
        // Bug 2 needs a duplicate: [1, 1], key 1 probes index 1 first.
        assert_eq!(
            first_counterexample(buggy_lower_bound_early_exit, linear_lower_bound),
            Some(Counterexample { keys: vec![1, 1], key: 1, got: 1, want: 0 })
        );
    }

    /// Bug 3: the closed-style test `lo <= hi` on top of the half-open loop
    /// body (`hi = mid`). For sorted keys it NEVER returns: when `lo == hi`
    /// the probe `mid` equals both, and then either `mid == len` (a read one
    /// past the end) or `keys[mid] >= key` (so `hi = mid` changes nothing,
    /// forever). A test cannot wait forever or read out of bounds, so this
    /// version reports which of the two would happen.
    #[derive(Debug, PartialEq, Eq)]
    enum MixedOutcome {
        Index(usize),
        Spins,
        ReadsPastEnd(usize),
    }

    fn buggy_lower_bound_mixed(keys: &[u64], key: u64, max_steps: usize) -> MixedOutcome {
        let mut lo = 0;
        let mut hi = keys.len();
        let mut steps = 0;
        while lo <= hi {
            if steps == max_steps {
                return MixedOutcome::Spins;
            }
            let mid = lo + (hi - lo) / 2;
            if mid >= keys.len() {
                return MixedOutcome::ReadsPastEnd(mid);
            }
            if keys[mid] < key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
            steps += 1;
        }
        MixedOutcome::Index(lo)
    }

    #[test]
    fn trap_lo_le_hi_with_hi_eq_mid_spins_forever_or_reads_one_past_the_end() {
        // Key at or below an element: the loop stops shrinking and spins.
        assert_eq!(buggy_lower_bound_mixed(&[1], 0, 1000), MixedOutcome::Spins);
        assert_eq!(buggy_lower_bound_mixed(&[1, 3], 2, 1000), MixedOutcome::Spins);
        // Key above everything: lo == hi == len, and keys[len] is read.
        assert_eq!(buggy_lower_bound_mixed(&[1], 2, 1000), MixedOutcome::ReadsPastEnd(1));
        assert_eq!(buggy_lower_bound_mixed(&[], 5, 1000), MixedOutcome::ReadsPastEnd(0));
    }

    #[test]
    fn seeded_random_sorted_arrays_against_the_linear_scan_and_against_std() {
        // One scratch buffer for all rounds, reused by re-borrowing it.
        let mut scratch = [0u64; 200];
        let mut rng = SplitMix64::new(0x02);
        for round in 0..300 {
            let n = rng.below(200) as usize;
            // Small gaps on even rounds give many duplicates.
            let gap = if round % 2 == 0 { 3 } else { 1000 };
            let (keys, _rest) = make_sorted(&mut scratch, &mut rng, n, gap).unwrap();
            let keys = &*keys;
            assert!(is_sorted(keys));
            let top = keys.last().map_or(10, |&last| last + 2);
            for _ in 0..50 {
                let key = rng.below(top);
                let lower = lower_bound(keys, key);
                let upper = upper_bound(keys, key);
                assert_eq!(lower, linear_lower_bound(keys, key));
                assert_eq!(upper, linear_upper_bound(keys, key));
                assert_eq!(lower, keys.partition_point(|&k| k < key));
                assert_eq!(upper, keys.partition_point(|&k| k <= key));
                // std's binary_search agrees on found / not found and on the
                // insertion index, but not on WHICH duplicate it reports.
                match keys.binary_search(&key) {
                    Ok(i) => assert!((lower..upper).contains(&i)),
                    Err(i) => assert_eq!((lower, upper), (i, i)),
                }
                let from = rng.below(n as u64 + 1) as usize;
                assert_eq!(gallop_lower_bound(keys, from, key), from.max(lower));
            }
        }
    }

    #[test]
    fn allocation_failure_a_scratch_buffer_that_is_too_small_reports_none() {
        let mut scratch = [0u64; 8]; // room for 8 keys
        let mut rng = SplitMix64::new(1);
        let (keys, rest) = make_sorted(&mut scratch, &mut rng, 8, 10).unwrap();
        assert_eq!(keys.len(), 8);
        // The buffer is used up. Nothing is corrupted: the caller gets None
        // and can start over with the whole buffer.
        assert!(make_sorted(rest, &mut rng, 1, 10).is_none());
        assert!(make_sorted(&mut scratch, &mut rng, 8, 10).is_some());
    }
}
