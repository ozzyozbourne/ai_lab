//! The sorted baseline: an array of (key, value) kept in key order, searched
//! by binary search.
//!
//! This stands in for the B-tree in this chapter's comparison. For the
//! questions asked here (which queries can be answered, and in what order the
//! answers come out) a B+tree behaves like a sorted array cut into pages; what
//! the tree adds is cheap insertion, which chapters 03 to 08 covered.
use crate::keys::Lookup;

/// An entry that owns its key bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnedEntry {
    pub key: Box<[u8]>,
    pub value: u64,
}

#[derive(Debug, Default)]
pub struct SortedIndex {
    /// Invariant: strictly ascending by key bytes.
    entries: Vec<OwnedEntry>,
}

impl SortedIndex {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// All entries in key order.
    pub fn entries(&self) -> &[OwnedEntry] {
        &self.entries
    }

    /// Index of the first entry with key >= `key` (chapter 02). `compares`
    /// is increased by the number of whole-key comparisons made.
    pub fn lower_bound(&self, key: &[u8], compares: &mut u32) -> usize {
        let mut lo = 0;
        let mut hi = self.entries.len();
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            *compares += 1;
            if *self.entries[mid].key < *key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }

    pub fn get(&self, key: &[u8]) -> Option<u64> {
        self.lookup(key).value
    }

    /// Point lookup. `steps` counts whole-key comparisons.
    pub fn lookup(&self, key: &[u8]) -> Lookup {
        let mut steps = 0;
        let i = self.lower_bound(key, &mut steps);
        if i == self.len() {
            return Lookup { value: None, steps };
        }
        steps += 1; // the equality check on the candidate
        let e = &self.entries[i];
        Lookup { value: (*e.key == *key).then_some(e.value), steps }
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    pub fn put(&mut self, key: &[u8], value: u64) -> Option<u64> {
        let mut steps = 0;
        let i = self.lower_bound(key, &mut steps);
        if i < self.len() && *self.entries[i].key == *key {
            return Some(std::mem::replace(&mut self.entries[i].value, value));
        }
        self.entries.insert(i, OwnedEntry { key: key.into(), value });
        None
    }

    /// Entries with lo <= key < hi, in order. A contiguous slice: this is the
    /// query an ordered structure answers for free.
    pub fn range(&self, lo: &[u8], hi: &[u8]) -> &[OwnedEntry] {
        let mut steps = 0;
        let a = self.lower_bound(lo, &mut steps);
        let b = self.lower_bound(hi, &mut steps);
        if a < b { &self.entries[a..b] } else { &[] }
    }

    /// Entries whose key starts with `prefix`. They are contiguous in sorted
    /// order, so a prefix query is a range query in disguise (chapter 08).
    pub fn prefix_range(&self, prefix: &[u8]) -> &[OwnedEntry] {
        let mut steps = 0;
        let a = self.lower_bound(prefix, &mut steps);
        let mut b = a;
        while b < self.len() && self.entries[b].key.starts_with(prefix) {
            b += 1;
        }
        &self.entries[a..b]
    }

    pub fn validate(&self) -> Result<(), &'static str> {
        if self.entries.windows(2).all(|w| w[0].key < w[1].key) { Ok(()) } else { Err("entries are not strictly ascending") }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::{decode_u64, encode_u64};
    use crate::ops::{Config, Op, OpStream, Oracle, Weights};

    #[test]
    fn put_keeps_order_range_and_prefix_are_slices() {
        let mut index = SortedIndex::new();
        let keys: [&[u8]; 5] = [b"cat/2", b"ant/1", b"cat/1", b"dog/9", b"cat/3"];
        for (k, i) in keys.into_iter().zip(0..) {
            assert_eq!(index.put(k, i), None);
            index.validate().unwrap();
        }
        assert_eq!(index.put(b"cat/1", 20), Some(2));
        assert_eq!(index.get(b"cat/1"), Some(20));
        assert_eq!(index.get(b"cat/"), None);
        assert_eq!(index.len(), 5);
        assert_eq!(index.prefix_range(b"cat/").len(), 3);
        assert_eq!(index.prefix_range(b"cow").len(), 0);
        let r = index.range(b"cat/2", b"dog/9");
        assert_eq!(r.len(), 2);
        assert_eq!(*r[0].key, *b"cat/2");
        assert_eq!(*r[1].key, *b"cat/3");
        assert_eq!(index.range(b"z", b"a").len(), 0);
    }

    #[test]
    fn model_test_against_the_oracle() {
        let mut index = SortedIndex::new();
        let mut oracle = Oracle::new();
        let stream = OpStream::new(Config {
            seed: 8,
            count: 3000,
            key_space: 400,
            weights: Weights { put: 5, delete: 0, get: 3, range: 2 },
        });
        for op in stream {
            match op {
                Op::Put { key, value } => {
                    assert_eq!(index.put(&encode_u64(key), value), oracle.put(key, value))
                }
                Op::Get { key } => assert_eq!(index.get(&encode_u64(key)), oracle.get(key)),
                Op::Range { lo, hi } => {
                    let got: Vec<(u64, u64)> =
                        index.range(&encode_u64(lo), &encode_u64(hi)).iter().map(|e| (decode_u64(&e.key), e.value)).collect();
                    let want: Vec<(u64, u64)> = oracle.range(lo, hi).iter().map(|e| (e.key, e.value)).collect();
                    assert_eq!(got, want);
                }
                Op::Delete { .. } => unreachable!(),
            }
        }
        index.validate().unwrap();
    }
}
