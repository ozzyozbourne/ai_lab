// Copied from chapters/07-bplus-trees/rust/src/search.rs, trimmed for chapter
// 19 to the in-node searches (the descent is rewritten per latch protocol).
//! Binary search inside one node.

/// Index of the first key >= `key` (= keys.len() if there is none).
/// In a leaf this is where `key` is, or where it would be inserted.
pub fn lower_bound(keys: &[u64], key: u64) -> usize {
    let (mut lo, mut hi) = (0, keys.len());
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

/// Index of the first key > `key` (= keys.len() if there is none).
pub fn upper_bound(keys: &[u64], key: u64) -> usize {
    let (mut lo, mut hi) = (0, keys.len());
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

/// Which child of an internal node to descend into: the number of separators
/// that are <= key. A key EQUAL to a separator goes RIGHT.
pub fn child_index(separators: &[u64], key: u64) -> usize {
    upper_bound(separators, key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_equal_to_a_separator_is_routed_to_the_right_child() {
        assert_eq!(child_index(&[10, 20], 9), 0);
        assert_eq!(child_index(&[10, 20], 10), 1);
        assert_eq!(child_index(&[10, 20], 19), 1);
        assert_eq!(child_index(&[10, 20], 20), 2);
        assert_eq!(lower_bound(&[], 1), 0);
    }
}
