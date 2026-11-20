//! SECTION D: how many keys fit in a tree of height h, and the other way
//! round. The proof is in the README ("The height bound"); this file is the
//! arithmetic, so that the README's numbers are printed by a program.
//!
//! Key counts saturate at `u64::MAX` instead of overflowing, and no tree of
//! u64 keys is taller than 64 levels (2 * 2^63 - 1 keys).
//!
//! Every function asserts M >= 3, like `HandTree::new` does: with M = 2 a
//! non-root node could hold zero keys, and the formulas would describe no
//! B-tree (the loops below would stop at their 64-level cap with a wrong
//! answer).
//!
//! Argument order: every function here takes the order first, `(m, ...)`,
//! as `min_keys(m, height)` does. Chapter 01's height calculator has functions
//! of the same names with the arguments the other way round,
//! `minHeight(n, m)` (`min_height(n, m)` in Rust). Both arguments are `u64`, so the compiler cannot catch
//! a swap: `min_height(5, 100)` is 3 here (order 5, 100 keys), while
//! `min_height(100, 5)` means order 100 and 5 keys, and is 1.
//!
//! The letter d stands for ceil(M/2), as in the README. It is not the t of
//! CLRS, which exists only for even M.

/// The precondition of every function in this file.
fn assert_order(m: u64) {
    assert!(m >= 3, "a B-tree needs order M >= 3, got {m}");
}

/// d = ceil(M/2): the fewest children of an interior node that is not the root.
pub fn min_children(m: u64) -> u64 {
    assert_order(m);
    m.div_ceil(2)
}

fn power(base: u64, exponent: usize) -> u64 {
    let mut result: u64 = 1;
    for _ in 0..exponent {
        result = result.saturating_mul(base);
    }
    result
}

/// Fewest keys in a tree of `height` levels: 2 * d^(height-1) - 1.
/// (The root has 1 key and 2 children; every other node has d - 1 keys.)
pub fn min_keys(m: u64, height: usize) -> u64 {
    if height == 0 {
        return 0;
    }
    let half = power(min_children(m), height - 1);
    match half.checked_mul(2) {
        Some(twice) => twice - 1,
        None => u64::MAX,
    }
}

/// Most keys in a tree of `height` levels: M^height - 1 (every node full).
pub fn max_keys(m: u64, height: usize) -> u64 {
    assert_order(m);
    let full = power(m, height);
    if full == u64::MAX { u64::MAX } else { full - 1 }
}

/// Shortest tree that can hold n keys: the smallest h with M^h - 1 >= n.
pub fn min_height(m: u64, n: u64) -> usize {
    assert_order(m);
    let mut h = 0;
    while h < 64 && max_keys(m, h) < n {
        h += 1;
    }
    h
}

/// Tallest tree that n keys can form: the largest h with 2 * d^(h-1) - 1 <= n.
pub fn max_height(m: u64, n: u64) -> usize {
    assert_order(m);
    if n == 0 {
        return 0;
    }
    let mut h = 1;
    while h < 64 && min_keys(m, h + 1) <= n {
        h += 1;
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_counts_per_height_for_m_4() {
        assert_eq!(min_children(4), 2);
        assert_eq!(min_children(3), 2);
        assert_eq!(min_children(5), 3);
        let want = [(0, 0), (1, 3), (3, 15), (7, 63), (15, 255)];
        for (h, (min, max)) in want.into_iter().enumerate() {
            assert_eq!(min_keys(4, h), min);
            assert_eq!(max_keys(4, h), max);
        }
    }

    #[test]
    fn height_bounds_the_readmes_worked_example() {
        // One million keys, M = 4 (d = 2): at most 1 + floor(log2(500000.5)) = 19 levels.
        assert_eq!(max_height(4, 1_000_000), 19);
        assert_eq!(min_height(4, 1_000_000), 10);
        // M = 256 (d = 128): 128^2 = 16384 <= 500000.5 < 128^3, so exactly 3 levels.
        assert_eq!(max_height(256, 1_000_000), 3);
        assert_eq!(min_height(256, 1_000_000), 3);
        assert_eq!(max_height(4, 0), 0);
        assert_eq!(min_height(4, 0), 0);
        assert_eq!(max_height(4, 2), 1);
        assert_eq!(max_height(4, 3), 2); // 3 keys may already be root + 2 leaves
        assert_eq!(min_height(4, 4), 2); // 4 keys no longer fit in one node
        // Exercise 2: 100 keys at M = 5.
        assert_eq!(min_height(5, 100), 3);
        assert_eq!(max_height(5, 100), 4);
        assert_eq!(min_keys(5, 5), 161);
    }

    #[test]
    fn the_smallest_legal_order_m_3_gets_sensible_answers() {
        // Regression: orders below 3 were accepted (see the three tests
        // below). M = 3 is the boundary that must keep working: d = 2, so
        // 1 or 2 keys per node.
        assert_eq!(min_children(3), 2);
        assert_eq!(min_keys(3, 2), 3);
        assert_eq!(max_keys(3, 2), 8);
        assert_eq!(min_height(3, 10), 3); // 3^2 - 1 = 8 < 10 <= 26
        assert_eq!(max_height(3, 10), 3); // 2 * 2^2 - 1 = 7 <= 10 < 15
    }

    #[test]
    #[should_panic(expected = "order M >= 3")]
    fn min_height_rejects_order_0() {
        min_height(0, 10); // used to overflow in max_keys
    }

    #[test]
    #[should_panic(expected = "order M >= 3")]
    fn max_height_rejects_order_2() {
        max_height(2, 10); // used to return the 64-level cap
    }

    #[test]
    #[should_panic(expected = "order M >= 3")]
    fn min_keys_rejects_order_1() {
        min_keys(1, 3);
    }

    #[test]
    fn the_two_bounds_are_consistent_and_huge_inputs_saturate() {
        for m in [3, 4, 5, 16, 255, 256] {
            for n in 0..2000 {
                let lo = min_height(m, n);
                let hi = max_height(m, n);
                assert!(lo <= hi);
                // n lies in the key range of both extreme heights.
                assert!(min_keys(m, hi) <= n && n <= max_keys(m, lo));
            }
        }
        assert_eq!(max_keys(1024, 100), u64::MAX);
        assert_eq!(min_keys(1024, 100), u64::MAX);
        assert_eq!(max_height(4, u64::MAX), 64); // 2 * 2^63 - 1 keys
        assert_eq!(min_height(4, u64::MAX), 32); // 4^32 - 1 keys
    }
}
