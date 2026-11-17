//! Height calculator: how many levels does a tree of order M need for n keys?
//!
//! Height here means the number of nodes on a path from the root to a leaf,
//! which is the number of page reads for one lookup. An empty tree has
//! height 0, a single node has height 1.
//!
//! The two formulas are textbook results (Knuth, The Art of Computer
//! Programming vol. 3, section 6.2.4); chapter 03 proves the upper bound.

/// Fewest levels that can hold `n` keys when every node is completely full.
/// A full tree of order m and height h holds m^h - 1 keys, so this is the
/// smallest h with m^h - 1 >= n. For m = 2 it is the height of a perfectly
/// balanced binary search tree.
pub fn min_height(n: u64, m: u64) -> u32 {
    assert!(m >= 2);
    let mut h = 0;
    let mut capacity_plus_one: u128 = 1; // m^h; u128 so that 2^64 does not overflow
    while capacity_plus_one - 1 < u128::from(n) {
        capacity_plus_one *= u128::from(m);
        h += 1;
    }
    h
}

/// Most levels a B-tree of order m can need for `n` keys: every node as
/// empty as the rules allow. The root may hold a single key (2 children);
/// every other node has at least ceil(m/2) children. Such a tree of height
/// h holds 2 * ceil(m/2)^(h-1) - 1 keys, so this is the largest h for which
/// that number is <= n.
pub fn max_height(n: u64, m: u64) -> u32 {
    assert!(m >= 3); // for m = 2 the minimum fan-out is 1: no bound
    if n == 0 {
        return 0;
    }
    let min_children = u128::from(m.div_ceil(2));
    let mut h = 1;
    let mut power: u128 = 1; // min_children^(h-1)
    // Can a tree one level taller still be built from n keys?
    while 2 * power * min_children - 1 <= u128::from(n) {
        power *= min_children;
        h += 1;
    }
    h
}

/// Largest order M whose node fits in one page, for fixed-size keys, values
/// and child pointers: (M-1) entries and M pointers, nothing else. Real page
/// formats also spend bytes on a header and per-entry slots (chapter 10).
pub fn order_for_page(page_bytes: u64, entry_bytes: u64, pointer_bytes: u64) -> u64 {
    // (M-1) * entry + M * pointer <= page   =>   M <= (page + entry) / (entry + pointer)
    (page_bytes + entry_bytes) / (entry_bytes + pointer_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn min_height_values() {
        assert_eq!(min_height(0, 4), 0);
        assert_eq!(min_height(1, 4), 1);
        assert_eq!(min_height(3, 4), 1);
        assert_eq!(min_height(4, 4), 2);
        assert_eq!(min_height(15, 4), 2);
        assert_eq!(min_height(16, 4), 3);
        assert_eq!(min_height(1000, 2), 10); // 2^10 - 1 = 1023
        assert_eq!(min_height(1_000_000, 2), 20);
        assert_eq!(min_height(1_000_000, 171), 3);
        assert_eq!(min_height(u64::MAX, 2), 64);
    }

    #[test]
    fn max_height_values() {
        assert_eq!(max_height(0, 4), 0);
        assert_eq!(max_height(1, 4), 1);
        assert_eq!(max_height(2, 4), 1);
        assert_eq!(max_height(3, 4), 2); // root with 1 key, two leaves with 1 key
        assert_eq!(max_height(6, 4), 2);
        assert_eq!(max_height(7, 4), 3); // 2 * 2^2 - 1
        assert_eq!(max_height(1_000_000, 171), 3); // height 4 needs 2 * 86^3 - 1 = 1272111 keys
        assert_eq!(max_height(1_272_111, 171), 4);
        let _ = max_height(u64::MAX, 3); // must not overflow
    }

    #[test]
    fn min_height_never_exceeds_max_height() {
        for n in 0..2000 {
            for m in [3, 4, 5, 8, 171] {
                assert!(min_height(n, m) <= max_height(n, m));
            }
        }
    }

    #[test]
    fn order_for_page_values() {
        // 16-byte entries, 8-byte pointers, 4096-byte page:
        // 170 entries (2720 bytes) + 171 pointers (1368 bytes) = 4088 <= 4096.
        assert_eq!(order_for_page(4096, 16, 8), 171);
        assert_eq!(order_for_page(80, 16, 8), 4); // 3 entries + 4 pointers = 80 bytes
        assert_eq!(order_for_page(79, 16, 8), 3);
    }
}
