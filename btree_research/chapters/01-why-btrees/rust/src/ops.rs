// Copied from common/rust/ops.rs; do not edit here
//! Deterministic operation stream + a tiny reference oracle for model tests.
//!
//! Source of truth: common/rust/ops.rs (twin: common/zig/ops.zig).
//! A chapter copies this file and adds as its first line:
//!     // Copied from common/rust/ops.rs; do not edit here
//!
//! A model test feeds the same operations to the tree under test and to the
//! `Oracle` (a sorted array, obviously correct) and compares every answer.
//! Zig and Rust generate the identical stream for the same `Config`
//! (see common/golden.txt), so a failure in one language can be replayed in
//! the other.
//!
//! This file is self-contained: it carries its own private copy of the
//! SplitMix64 step (same numbers as common/rust/prng.rs).

/// One operation. Keys and values are u64 (Part I convention).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Put {
        key: u64,
        value: u64,
    },
    Delete {
        key: u64,
    },
    Get {
        key: u64,
    },
    /// Half-open key interval [lo, hi). Always lo < hi <= key_space.
    Range {
        lo: u64,
        hi: u64,
    },
}

/// Relative frequencies. {4,2,3,1} means 40% put, 20% delete, 30% get, 10% range.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Weights {
    pub put: u32,
    pub delete: u32,
    pub get: u32,
    pub range: u32,
}

impl Default for Weights {
    /// Same defaults as the Zig twin: put 4, delete 2, get 3, range 1.
    fn default() -> Self {
        Self {
            put: 4,
            delete: 2,
            get: 3,
            range: 1,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Config {
    pub seed: u64,
    /// Number of operations to produce.
    pub count: u64,
    /// Keys are drawn from [0, key_space). Small = many collisions (good for
    /// testing overwrite and delete). Must be > 0.
    pub key_space: u64,
    /// At least one weight must be non-zero.
    pub weights: Weights,
}

/// An `Iterator<Item = Op>`. Usage: `for op in OpStream::new(cfg) { match op { .. } }`
#[derive(Debug, Clone)]
pub struct OpStream {
    state: u64, // SplitMix64 state
    remaining: u64,
    key_space: u64,
    weights: Weights,
}

impl OpStream {
    /// Panics if key_space == 0 or all weights are 0.
    pub fn new(config: Config) -> Self {
        assert!(config.key_space > 0, "key_space must be > 0");
        let w = config.weights;
        let total = u64::from(w.put) + u64::from(w.delete) + u64::from(w.get) + u64::from(w.range);
        assert!(total > 0, "at least one weight must be non-zero");
        Self {
            state: config.seed,
            remaining: config.count,
            key_space: config.key_space,
            weights: w,
        }
    }

    // Private SplitMix64 (identical to prng.rs).
    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    // Multiply-high: top 64 bits of next_u64() * n.
    fn below(&mut self, n: u64) -> u64 {
        ((u128::from(self.next_u64()) * u128::from(n)) >> 64) as u64
    }
}

impl Iterator for OpStream {
    type Item = Op;

    /// Next operation, or None after `count` operations.
    fn next(&mut self) -> Option<Op> {
        // The exact recipe (the Zig twin follows it draw for draw):
        //   1. r = below(put + delete + get + range)
        //   2. r picks the kind, checking put, delete, get, range in that order
        //   3. put:    key = below(key_space), then value = next_u64()
        //      delete: key = below(key_space)
        //      get:    key = below(key_space)
        //      range:  a = below(key_space), b = below(key_space),
        //              lo = min(a, b), hi = max(a, b) + 1
        if self.remaining == 0 {
            return None;
        }
        self.remaining -= 1;
        let w = self.weights;
        let (put, delete, get) = (u64::from(w.put), u64::from(w.delete), u64::from(w.get));
        let mut r = self.below(put + delete + get + u64::from(w.range));
        if r < put {
            let key = self.below(self.key_space);
            return Some(Op::Put {
                key,
                value: self.next_u64(),
            });
        }
        r -= put;
        if r < delete {
            return Some(Op::Delete {
                key: self.below(self.key_space),
            });
        }
        r -= delete;
        if r < get {
            return Some(Op::Get {
                key: self.below(self.key_space),
            });
        }
        let a = self.below(self.key_space);
        let b = self.below(self.key_space);
        Some(Op::Range {
            lo: a.min(b),
            hi: a.max(b) + 1,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub key: u64,
    pub value: u64,
}

/// Reference map u64 -> u64: a `Vec` of entries kept sorted by key.
/// Slow (put/delete shift elements, O(n)) but easy to trust.
#[derive(Debug, Clone, Default)]
pub struct Oracle {
    entries: Vec<Entry>,
}

impl Oracle {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        let i = self.lower_bound(key);
        self.entries
            .get(i)
            .filter(|e| e.key == key)
            .map(|e| e.value)
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    pub fn put(&mut self, key: u64, value: u64) -> Option<u64> {
        let i = self.lower_bound(key);
        if i < self.entries.len() && self.entries[i].key == key {
            return Some(std::mem::replace(&mut self.entries[i].value, value));
        }
        self.entries.insert(i, Entry { key, value });
        None
    }

    /// Remove a key. Returns the removed value, or None if it was absent.
    pub fn delete(&mut self, key: u64) -> Option<u64> {
        let i = self.lower_bound(key);
        if i < self.entries.len() && self.entries[i].key == key {
            return Some(self.entries.remove(i).value);
        }
        None
    }

    /// All entries with lo <= key < hi, in ascending key order, borrowed
    /// from the oracle (so the borrow checker forbids put/delete meanwhile).
    pub fn range(&self, lo: u64, hi: u64) -> &[Entry] {
        let start = self.lower_bound(lo);
        let end = self.lower_bound(hi);
        if start < end {
            &self.entries[start..end]
        } else {
            &[]
        }
    }

    /// Binary search: index of the first entry with entry.key >= key.
    fn lower_bound(&self, key: u64) -> usize {
        let (mut lo, mut hi) = (0, self.entries.len());
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if self.entries[mid].key < key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_is_deterministic_bounded_and_yields_exactly_count_ops() {
        let cfg = Config {
            seed: 9,
            count: 500,
            key_space: 50,
            weights: Weights::default(),
        };
        let a: Vec<Op> = OpStream::new(cfg).collect();
        let b: Vec<Op> = OpStream::new(cfg).collect();
        assert_eq!(a, b);
        assert_eq!(a.len(), 500);
        for op in a {
            match op {
                Op::Put { key, .. } | Op::Delete { key } | Op::Get { key } => assert!(key < 50),
                Op::Range { lo, hi } => assert!(lo < hi && hi <= 50),
            }
        }
    }

    #[test]
    fn zero_weights_are_never_chosen() {
        let weights = Weights {
            put: 0,
            delete: 0,
            get: 1,
            range: 0,
        };
        let cfg = Config {
            seed: 1,
            count: 200,
            key_space: 10,
            weights,
        };
        assert!(OpStream::new(cfg).all(|op| matches!(op, Op::Get { .. })));
    }

    #[test]
    fn oracle_basics() {
        let mut o = Oracle::new();
        assert!(o.is_empty());
        assert_eq!(o.put(20, 200), None);
        assert_eq!(o.put(10, 100), None);
        assert_eq!(o.put(30, 300), None);
        assert_eq!(o.put(20, 222), Some(200));
        assert_eq!(o.len(), 3);
        assert_eq!(o.get(20), Some(222));
        assert_eq!(o.get(15), None);
        let expected = [
            Entry {
                key: 10,
                value: 100,
            },
            Entry {
                key: 20,
                value: 222,
            },
        ];
        assert_eq!(o.range(10, 30), &expected);
        assert!(o.range(11, 20).is_empty());
        assert!(o.range(30, 10).is_empty());
        assert_eq!(o.delete(10), Some(100));
        assert_eq!(o.delete(10), None);
        assert_eq!(o.len(), 2);
    }
}
