// Copied from chapters/12-disk-backed-bplus-tree/rust/src/workload.rs; unchanged.
//! workload.rs: seeded byte-string keys and values, and the oracle the tree
//! is compared with. The Zig twin draws the same random numbers, so both
//! languages run the same operations and print the same counters.

use std::collections::BTreeMap;
use std::ops::Bound;

use crate::prng::SplitMix64;

/// The key that belongs to number `n`: 1 to `max_len` letters from a small
/// alphabet (so that many keys share a prefix), derived from `n` alone, so
/// the same `n` always gives the same key and a later put overwrites it.
/// One key in 16 has the full `max_len`.
pub fn key_for(n: u64, max_len: usize) -> Vec<u8> {
    let mut rng = SplitMix64::new(n.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(1));
    let len = if rng.chance(1, 16) {
        max_len
    } else {
        1 + rng.below(max_len as u64) as usize
    };
    (0..len).map(|_| b'a' + rng.below(6) as u8).collect()
}

/// A value of random length (one in 16 is empty, one in 16 has `max_len`
/// bytes) whose bytes count up from a random start.
pub fn random_value(rng: &mut SplitMix64, max_len: usize) -> Vec<u8> {
    let len = match rng.below(16) {
        0 => 0,
        1 => max_len,
        _ => rng.below(max_len as u64 + 1) as usize,
    };
    let start = rng.next_u64() as u8;
    (0..len).map(|i| start.wrapping_add(i as u8)).collect()
}

/// The oracle. Zig keeps a sorted array in an arena; std's `BTreeMap` is the
/// natural choice here (and an in-memory B-tree checking an on-disk one).
#[derive(Debug, Default)]
pub struct Model {
    entries: BTreeMap<Vec<u8>, Vec<u8>>,
}

impl Model {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, key: &[u8]) -> Option<&[u8]> {
        self.entries.get(key).map(Vec::as_slice)
    }

    pub fn put(&mut self, key: &[u8], value: &[u8]) {
        self.entries.insert(key.to_vec(), value.to_vec());
    }

    /// The entries with lo <= key < hi (`hi` None = to the end).
    pub fn range(&self, lo: &[u8], hi: Option<&[u8]>) -> Vec<(&[u8], &[u8])> {
        if hi.is_some_and(|hi| hi <= lo) {
            return Vec::new(); // BTreeMap::range panics on an inverted range
        }
        let upper = hi.map_or(Bound::Unbounded, Bound::Excluded);
        self.entries
            .range::<[u8], _>((Bound::Included(lo), upper))
            .map(|(k, v)| (k.as_slice(), v.as_slice()))
            .collect()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_for_is_a_function_of_n_model_keeps_keys_sorted_and_overwrites() {
        assert_eq!(key_for(7, 40), key_for(7, 40));

        let mut model = Model::new();
        model.put(b"b", b"1");
        model.put(b"a", b"2");
        model.put(b"c", b"3");
        model.put(b"b", b"4");
        assert_eq!(model.len(), 3);
        assert_eq!(model.get(b"b"), Some(&b"4"[..]));
        assert_eq!(model.get(b"bb"), None);
        assert_eq!(model.range(b"a", Some(b"c")).len(), 2);
        assert_eq!(model.range(b"b", None).len(), 2);
        assert_eq!(model.range(b"c", Some(b"a")).len(), 0);
    }
}
