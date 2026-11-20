//! Range bounds: the nine combinations of {unbounded, included, excluded} for
//! the two ends of a range, and "prefix scan" expressed as such a range.
//!
//! The one rule of this file: an excluded bound is NEVER rewritten as an
//! included bound on `key + 1` (or `key - 1`). That trick overflows at the
//! largest key, and it does not exist at all for byte-string keys (there is
//! no "next string" you can compute cheaply in general). Instead the kind of
//! the bound picks the comparison: `>=` or `>`, `<=` or `<`.
//!
//! Zig defines its own `Bound` union. Rust already has one in the standard
//! library, with range syntax on top (`6..17`, `..=17`, `..`), so we reuse it.

pub use std::ops::Bound;
use std::ops::Bound::{Excluded, Included, Unbounded};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Forward,
    Backward,
}

/// Is `key` on the inside of the lower bound?
pub fn above_lower(lo: Bound<u64>, key: u64) -> bool {
    match lo {
        Unbounded => true,
        Included(k) => key >= k,
        Excluded(k) => key > k,
    }
}

/// Is `key` on the inside of the upper bound?
pub fn below_upper(hi: Bound<u64>, key: u64) -> bool {
    match hi {
        Unbounded => true,
        Included(k) => key <= k,
        Excluded(k) => key < k,
    }
}

/// The definition of a range, used as the specification in tests: a scan
/// must return exactly the entries for which this is true, in key order.
pub fn contains(lo: Bound<u64>, hi: Bound<u64>, key: u64) -> bool {
    above_lower(lo, key) && below_upper(hi, key)
}

/// All keys whose top `prefix_bits` bits equal `prefix`, as a range.
///
/// With composite keys (chapter 07: `user_key << 32 | row_id`) "all rows of
/// user key 7" is `prefix_range(7, 32)`. The range is [first key with the
/// prefix, first key of the NEXT prefix). The next prefix is `prefix + 1`,
/// unless the prefix is all ones: then nothing sorts after it and the upper
/// bound is simply absent. For byte strings the same idea is "increment the
/// last byte that is not 0xFF and cut the string there".
pub fn prefix_range(prefix: u64, prefix_bits: u32) -> (Bound<u64>, Bound<u64>) {
    assert!((1..=64).contains(&prefix_bits));
    let shift = 64 - prefix_bits;
    let largest_prefix = u64::MAX >> shift;
    assert!(prefix <= largest_prefix, "the prefix must fit in prefix_bits");
    let hi = if prefix == largest_prefix {
        Unbounded
    } else {
        Excluded((prefix + 1) << shift)
    };
    (Included(prefix << shift), hi)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contains_the_nine_combinations_around_10_to_20() {
        let lows = [Unbounded, Included(10), Excluded(10)];
        let highs = [Unbounded, Included(20), Excluded(20)];
        // For each (lo, hi): which of the probe keys 9, 10, 15, 20, 21 are inside.
        let probes = [9, 10, 15, 20, 21];
        let expected = [
            [
                [true, true, true, true, true],
                [true, true, true, true, false],
                [true, true, true, false, false],
            ],
            [
                [false, true, true, true, true],
                [false, true, true, true, false],
                [false, true, true, false, false],
            ],
            [
                [false, false, true, true, true],
                [false, false, true, true, false],
                [false, false, true, false, false],
            ],
        ];
        for (i, lo) in lows.into_iter().enumerate() {
            for (j, hi) in highs.into_iter().enumerate() {
                for (k, p) in probes.into_iter().enumerate() {
                    assert_eq!(contains(lo, hi, p), expected[i][j][k]);
                }
            }
        }
    }

    #[test]
    fn contains_the_ends_of_the_key_space_need_no_special_case() {
        let max = u64::MAX;
        assert!(contains(Included(max), Unbounded, max));
        assert!(!contains(Excluded(max), Unbounded, max)); // "key > max": nothing
        assert!(contains(Unbounded, Included(0), 0));
        assert!(!contains(Unbounded, Excluded(0), 0)); // "key < 0": nothing
        // An inverted or degenerate range is just empty.
        assert!(!contains(Included(20), Included(10), 15));
        assert!(!contains(Excluded(10), Excluded(10), 10));
        assert!(contains(Included(10), Included(10), 10));
    }

    #[test]
    fn prefix_range_next_prefix_as_exclusive_upper_bound_none_after_all_ones() {
        let (lo, hi) = prefix_range(7, 32);
        assert_eq!(lo, Included(7 << 32));
        assert_eq!(hi, Excluded(8 << 32));
        assert!(contains(lo, hi, (7 << 32) | 0xFFFF_FFFF));
        assert!(!contains(lo, hi, 8 << 32));

        // The largest prefix has no successor: (0xFFFFFFFF + 1) << 32 would overflow.
        let (lo, hi) = prefix_range(0xFFFF_FFFF, 32);
        assert_eq!(hi, Unbounded);
        assert!(contains(lo, hi, u64::MAX));

        // A 64-bit prefix is a single key.
        let (lo, hi) = prefix_range(42, 64);
        assert!(contains(lo, hi, 42));
        assert!(!contains(lo, hi, 41) && !contains(lo, hi, 43));
    }
}
