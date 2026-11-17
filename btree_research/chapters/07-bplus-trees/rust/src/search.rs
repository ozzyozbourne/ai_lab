//! Search: inside one node (binary search) and from the root to a leaf.
//!
//! In a B+tree EVERY lookup ends in a leaf, even if the key equals a separator
//! on the way down: the separator is only a copy, the value is in the leaf.

use crate::arena::NodeId;
use crate::node::Kind;
use crate::tree::BPlusTree;

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

impl BPlusTree {
    /// The leaf whose key range contains `key` (whether or not the key is in
    /// it). `NIL` only for an empty tree.
    pub fn find_leaf(&self, key: u64) -> NodeId {
        let mut id = self.root;
        if id.is_nil() {
            return NodeId::NIL;
        }
        loop {
            let n = self.nodes.get(id);
            match &n.kind {
                Kind::Leaf(_) => return id,
                Kind::Internal(internal) => id = internal.children[child_index(n.key_slice(), key)],
            }
        }
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        let id = self.find_leaf(key);
        if id.is_nil() {
            return None;
        }
        let leaf = self.nodes.get(id);
        let i = lower_bound(leaf.key_slice(), key);
        (i < leaf.len && leaf.keys[i] == key).then(|| leaf.leaf().values[i])
    }
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
        assert_eq!(upper_bound(&[], 1), 0);
    }

    #[test]
    fn a_key_equal_to_a_separator_is_routed_to_the_right_child() {
        assert_eq!(child_index(&[10, 20], 9), 0);
        assert_eq!(child_index(&[10, 20], 10), 1);
        assert_eq!(child_index(&[10, 20], 19), 1);
        assert_eq!(child_index(&[10, 20], 20), 2);
    }
}
