// Copied from chapters/07-bplus-trees/rust/src/search.rs, trimmed to the
// binary searches inside one node (the descent lives in index.rs here).
//! Search inside one node. Keys are the packed (user key, tid) index keys of
//! base_node.rs; they are unique, so the rules of chapter 07 apply unchanged.

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

/// Which child of an internal node to descend into.
///
/// Child i holds keys in [keys[i-1], keys[i]), so we want the number of
/// separators that are <= key: that is the upper bound. A key EQUAL to a
/// separator goes RIGHT, because a separator is a copy of the smallest key
/// that was in the right half when the leaf split.
pub fn child_index(separators: &[u64], key: u64) -> usize {
    upper_bound(separators, key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lower_bound_and_upper_bound_differ_only_on_equal_keys() {
        let keys = [10, 20, 30];
        let probes = [5, 10, 15, 20, 30, 35];
        let lower = [0, 0, 1, 1, 2, 3];
        let upper = [0, 1, 1, 2, 3, 3];
        for i in 0..probes.len() {
            assert_eq!(lower_bound(&keys, probes[i]), lower[i]);
            assert_eq!(upper_bound(&keys, probes[i]), upper[i]);
        }
        assert_eq!(lower_bound(&[], 1), 0);
        assert_eq!(child_index(&[10, 20], 10), 1);
    }
}
