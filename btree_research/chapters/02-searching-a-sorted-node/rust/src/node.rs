//! A single sorted node: the smallest structure that USES a search result.
//!
//! `Node<CAP>` is a fixed-size array of keys with a parallel array of values
//! and a length, all stored inline (no heap, no pointers). It is what a
//! B-tree leaf will look like from chapter 03 on. Every operation is the same
//! two steps:
//!
//!   1. `search` the keys: get `{found, index}`;
//!   2. act at `index`: read it, overwrite it, open a gap there, close it.
//!
//! When the node is full, `put` reports `NodeFull`. A B-tree answers that
//! error by splitting the node (chapter 04); here it is just an error.

use std::ops::{Bound, Range};

use crate::search;

/// `put` on a full node. Mirrors Zig's `error.NodeFull`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NodeFull;

/// `validate` found a broken invariant. Mirrors Zig's `error.InvalidNode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidNode;

/// Zig writes `Node(4)`, a function that returns a type; Rust writes
/// `Node<4>`, a const generic parameter. Same result: the capacity is part of
/// the type and the arrays live inside the struct.
#[derive(Debug, Clone)]
pub struct Node<const CAP: usize> {
    keys: [u64; CAP],
    values: [u64; CAP],
    /// Only `keys[..len]` and `values[..len]` are meaningful.
    len: usize,
}

impl<const CAP: usize> Node<CAP> {
    /// Zig leaves the unused slots `undefined`; safe Rust must give them a
    /// value, so they start as zero. They are never read either way.
    pub fn new() -> Self {
        Self { keys: [0; CAP], values: [0; CAP], len: 0 }
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// The live keys, sorted and unique.
    pub fn key_slice(&self) -> &[u64] {
        &self.keys[..self.len]
    }

    pub fn value_slice(&self) -> &[u64] {
        &self.values[..self.len]
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        let r = search::search(self.key_slice(), key);
        r.found.then(|| self.values[r.index])
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, NodeFull> {
        let r = search::search(self.key_slice(), key);
        if r.found {
            return Ok(Some(std::mem::replace(&mut self.values[r.index], value)));
        }
        if self.len == CAP {
            return Err(NodeFull);
        }
        // Open a gap at the insertion index: move keys[index..len] one slot
        // to the right (`copy_within` handles the overlap, like memmove).
        // Because `index` is the lower bound, everything left of the gap is
        // < key and everything right of it is > key: the node stays sorted
        // without re-sorting.
        let i = r.index;
        self.keys.copy_within(i..self.len, i + 1);
        self.values.copy_within(i..self.len, i + 1);
        self.keys[i] = key;
        self.values[i] = value;
        self.len += 1;
        Ok(None)
    }

    /// Remove a key. Returns its value, or None if it was not there.
    pub fn delete(&mut self, key: u64) -> Option<u64> {
        let r = search::search(self.key_slice(), key);
        if !r.found {
            return None;
        }
        let i = r.index;
        let old = self.values[i];
        // Close the gap: move keys[i+1..len] one slot to the left.
        self.keys.copy_within(i + 1..self.len, i);
        self.values.copy_within(i + 1..self.len, i);
        self.len -= 1;
        Some(old)
    }

    /// Positions of all keys in the half-open key interval `[lo, hi)`.
    /// Use the range to slice `key_slice()` and `value_slice()`.
    pub fn range(&self, lo: u64, hi: u64) -> Range<usize> {
        search::range_span(self.key_slice(), Bound::Included(lo), Bound::Excluded(hi))
    }

    /// Check the invariants: the length fits, and the keys are strictly
    /// increasing (sorted, and no duplicates: Part I rejects duplicates).
    pub fn validate(&self) -> Result<(), InvalidNode> {
        if self.len > CAP {
            return Err(InvalidNode);
        }
        if self.key_slice().windows(2).any(|pair| pair[0] >= pair[1]) {
            return Err(InvalidNode);
        }
        Ok(())
    }
}

impl<const CAP: usize> Default for Node<CAP> {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::{Config, Op, OpStream, Oracle, Weights};

    #[test]
    fn put_keeps_the_node_sorted_by_inserting_at_the_search_index() {
        let mut node: Node<8> = Node::new();
        for k in [10, 20, 5, 6, 12] {
            assert_eq!(node.put(k, k * 100), Ok(None));
            assert_eq!(node.validate(), Ok(()));
        }
        assert_eq!(node.key_slice(), [5, 6, 10, 12, 20]);
        assert_eq!(node.value_slice(), [500, 600, 1000, 1200, 2000]);

        // Overwrite: same position, old value comes back, length unchanged.
        assert_eq!(node.put(10, 1), Ok(Some(1000)));
        assert_eq!(node.get(10), Some(1));
        assert_eq!(node.len(), 5);

        assert_eq!(node.get(11), None);
        assert_eq!(node.delete(6), Some(600));
        assert_eq!(node.delete(6), None);
        assert_eq!(node.key_slice(), [5, 10, 12, 20]);
        assert_eq!(node.validate(), Ok(()));
    }

    #[test]
    fn a_full_node_rejects_new_keys_but_still_accepts_overwrites() {
        let mut node: Node<4> = Node::new();
        assert!(node.is_empty());
        for k in [10, 20, 5, 6] {
            node.put(k, k).unwrap();
        }
        assert_eq!(node.put(12, 12), Err(NodeFull));
        // The failed put changed nothing.
        assert_eq!(node.key_slice(), [5, 6, 10, 20]);
        assert_eq!(node.validate(), Ok(()));
        assert_eq!(node.put(20, 21), Ok(Some(20)));
        // Deleting makes room again.
        assert_eq!(node.delete(5), Some(5));
        assert_eq!(node.put(12, 12), Ok(None));
        assert_eq!(node.key_slice(), [6, 10, 12, 20]);
    }

    #[test]
    fn validate_rejects_unsorted_and_duplicate_keys() {
        let mut node: Node<4> = Node::new();
        for k in [1, 2, 3] {
            node.put(k, k).unwrap();
        }
        assert_eq!(node.validate(), Ok(()));
        node.keys[1] = 3; // 1 3 3: duplicate
        assert_eq!(node.validate(), Err(InvalidNode));
        node.keys[1] = 9; // 1 9 3: unsorted
        assert_eq!(node.validate(), Err(InvalidNode));
        // An unsorted node is why validate exists: search gives a wrong
        // answer without any error.
        assert_eq!(node.get(3), None);
    }

    #[test]
    fn seeded_model_test_node_against_the_oracle() {
        let mut oracle = Oracle::new();
        // key_space <= capacity, so the node can never be full.
        let mut node: Node<64> = Node::new();
        let config = Config { seed: 2, count: 20_000, key_space: 64, weights: Weights::default() };
        for op in OpStream::new(config) {
            match op {
                Op::Put { key, value } => assert_eq!(node.put(key, value), Ok(oracle.put(key, value))),
                Op::Delete { key } => assert_eq!(node.delete(key), oracle.delete(key)),
                Op::Get { key } => assert_eq!(node.get(key), oracle.get(key)),
                Op::Range { lo, hi } => {
                    let want = oracle.range(lo, hi);
                    let span = node.range(lo, hi);
                    assert_eq!(span.len(), want.len());
                    let keys = &node.key_slice()[span.clone()];
                    let values = &node.value_slice()[span];
                    for ((entry, &k), &v) in want.iter().zip(keys).zip(values) {
                        assert_eq!((entry.key, entry.value), (k, v));
                    }
                }
            }
            assert_eq!(node.validate(), Ok(()));
            assert_eq!(node.len(), oracle.len());
        }
    }
}
