//! A simple hash index: open addressing with linear probing. No delete.
//!
//! All entries live in one flat array of slots. A key hashes to a home slot;
//! if that slot is taken by another key, the next slot is tried, and so on
//! (wrapping around). Lookup follows the same walk and stops at the first
//! empty slot: the key cannot be further along, because an insert would have
//! used that empty slot.
//!
//! What the hash function buys (expected O(1) probes) is exactly what it
//! destroys: neighbouring keys land in unrelated slots, so the table cannot
//! answer "what comes after this key" without looking at every slot.
use crate::keys::{Entry, Lookup, fnv1a};

#[derive(Debug, Clone)]
pub struct Slot {
    /// The bytes are owned by the index.
    pub key: Box<[u8]>,
    /// Kept so that growing does not have to hash every key again.
    hash: u64,
    pub value: u64,
}

#[derive(Debug, Default)]
pub struct HashIndex {
    /// Length is 0 or a power of two, so `hash & (len - 1)` is the home slot.
    /// `None` = empty slot (Zig: `key == null`).
    slots: Vec<Option<Slot>>,
    len: usize,
}

const MIN_CAPACITY: usize = 8;

impl HashIndex {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn capacity(&self) -> usize {
        self.slots.len()
    }

    /// All slots in table order, empty ones included.
    pub fn slots(&self) -> &[Option<Slot>] {
        &self.slots
    }

    pub fn get(&self, key: &[u8]) -> Option<u64> {
        self.lookup(key).value
    }

    /// Point lookup. `steps` counts slots inspected.
    pub fn lookup(&self, key: &[u8]) -> Lookup {
        if self.slots.is_empty() {
            return Lookup { value: None, steps: 0 };
        }
        let (index, steps) = self.probe(fnv1a(key), key);
        Lookup { value: self.slots[index].as_ref().map(|slot| slot.value), steps }
    }

    /// Walk from the home slot to the slot holding `key`, or to the first
    /// empty slot. Returns (slot index, slots inspected). Terminates because
    /// the load factor keeps empty slots around.
    fn probe(&self, hash: u64, key: &[u8]) -> (usize, u32) {
        let mask = self.slots.len() - 1;
        let mut i = (hash as usize) & mask;
        let mut steps = 1;
        while let Some(slot) = &self.slots[i] {
            // Comparing the stored hash first skips most byte comparisons.
            if slot.hash == hash && *slot.key == *key {
                break;
            }
            i = (i + 1) & mask;
            steps += 1;
        }
        (i, steps)
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    /// (No error path: unlike the Zig twin, a `Vec` that cannot grow aborts.)
    pub fn put(&mut self, key: &[u8], value: u64) -> Option<u64> {
        let hash = fnv1a(key);
        if !self.slots.is_empty() {
            let (index, _) = self.probe(hash, key);
            if let Some(slot) = &mut self.slots[index] {
                return Some(std::mem::replace(&mut slot.value, value));
            }
        }
        // Invariant: len <= 70% of capacity, so probe runs stay short and a
        // lookup always meets an empty slot.
        if (self.len + 1) * 10 > self.slots.len() * 7 {
            self.grow();
        }
        let (index, _) = self.probe(hash, key);
        self.slots[index] = Some(Slot { key: key.into(), hash, value });
        self.len += 1;
        None
    }

    /// Double the table and re-place every entry: a slot index depends on the
    /// capacity, so nothing can stay where it was. This is the hash index's
    /// "split", and it touches the whole structure at once.
    fn grow(&mut self) {
        let new_cap = MIN_CAPACITY.max(self.slots.len() * 2);
        let mask = new_cap - 1;
        let old = std::mem::replace(&mut self.slots, vec![None; new_cap]);
        for slot in old.into_iter().flatten() {
            let mut i = (slot.hash as usize) & mask;
            while self.slots[i].is_some() {
                i = (i + 1) & mask;
            }
            self.slots[i] = Some(slot);
        }
    }

    /// The only way a hash index can answer an ordered question: look at every
    /// slot, keep what matches, sort afterwards. Appends matching entries to
    /// `out` in SLOT order (keys borrowed) and returns the slots inspected.
    /// `hi == None` means no upper bound.
    pub fn scan_range<'a>(&'a self, lo: &[u8], hi: Option<&[u8]>, out: &mut Vec<Entry<'a>>) -> usize {
        for slot in self.slots.iter().flatten() {
            let k: &[u8] = &slot.key;
            if k < lo || hi.is_some_and(|h| k >= h) {
                continue;
            }
            out.push(Entry { key: k, value: slot.value });
        }
        self.slots.len()
    }

    pub fn validate(&self) -> Result<(), &'static str> {
        let cap = self.slots.len();
        if cap != 0 && !cap.is_power_of_two() {
            return Err("capacity is not a power of two");
        }
        if self.len * 10 > cap * 7 {
            return Err("load factor above 70%");
        }
        let mut used = 0;
        for (i, slot) in self.slots.iter().enumerate() {
            let Some(slot) = slot else { continue };
            used += 1;
            if slot.hash != fnv1a(&slot.key) {
                return Err("stored hash is wrong");
            }
            // Every entry must be found where a lookup would look for it.
            if self.probe(slot.hash, &slot.key).0 != i {
                return Err("entry is not reachable by probing");
            }
        }
        if used != self.len { Err("len differs from occupied slots") } else { Ok(()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::encode_u64;
    use crate::ops::{Config, Op, OpStream, Oracle, Weights};

    #[test]
    fn put_get_overwrite_growth() {
        let mut index = HashIndex::new();
        assert_eq!(index.get(b"a"), None);
        assert_eq!(index.lookup(b"a").steps, 0);
        for i in 0..100 {
            assert_eq!(index.put(&encode_u64(i * 7), i), None);
            index.validate().unwrap();
        }
        assert_eq!(index.len(), 100);
        assert_eq!(index.capacity(), 256); // 100 <= 0.7 * 256, but 100 > 0.7 * 128
        assert_eq!(index.put(&encode_u64(35), 500), Some(5));
        assert_eq!(index.get(&encode_u64(35)), Some(500));
        assert_eq!(index.get(&encode_u64(36)), None);
        assert_eq!(index.len(), 100);
    }

    #[test]
    fn scan_range_inspects_every_slot_and_returns_unordered_matches() {
        let mut index = HashIndex::new();
        for i in 0..50 {
            index.put(&encode_u64(i), i);
        }
        let mut out = Vec::new();
        let inspected = index.scan_range(&encode_u64(10), Some(&encode_u64(20)), &mut out);
        assert_eq!(inspected, index.capacity());
        assert_eq!(out.len(), 10);
        out.sort_by_key(|e| e.key);
        assert!(out.iter().map(|e| e.value).eq(10..20));
    }

    #[test]
    fn model_test_against_the_oracle_put_and_get() {
        let mut index = HashIndex::new();
        let mut oracle = Oracle::new();
        let stream = OpStream::new(Config {
            seed: 5,
            count: 5000,
            key_space: 600,
            weights: Weights { put: 5, delete: 0, get: 5, range: 0 },
        });
        for op in stream {
            match op {
                Op::Put { key, value } => {
                    assert_eq!(index.put(&encode_u64(key), value), oracle.put(key, value))
                }
                Op::Get { key } => assert_eq!(index.get(&encode_u64(key)), oracle.get(key)),
                _ => unreachable!(),
            }
        }
        index.validate().unwrap();
        assert_eq!(index.len(), oracle.len());
    }
}
