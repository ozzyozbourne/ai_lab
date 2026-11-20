//! A map from u64 to u64 kept as ONE sorted array.
//!
//! This is the simplest ordered index there is, and it is the right mental
//! starting point: a B-tree node is a small sorted array, and a B-tree is
//! what you get when one sorted array is no longer good enough.
//!
//! Reads are excellent: binary search, and the result of a range query is one
//! contiguous slice. Writes are the problem: to keep the array sorted, `put`
//! and `delete` must shift every entry behind the affected position.
//!
//! Invariant (checked by `validate`): keys are strictly ascending. "Strictly"
//! also means there are no duplicates.

use crate::cost::{ENTRIES_PER_PAGE, Entry, Trace};

/// `put` needed room for one more entry and the map is at its limit.
/// (The Zig version gets `error.OutOfMemory` from its allocator instead.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfSpace;

#[derive(Debug, Default)]
pub struct SortedArrayMap {
    /// The live entries. `Vec` owns the allocation and its capacity; Zig
    /// keeps the slice and the length by hand.
    entries: Vec<Entry>,
    /// Maximum number of entries, or None for "as many as memory allows".
    /// This stands in for Zig's fixed buffer.
    limit: Option<usize>,
    /// Total entries shifted by `put` and `delete` so far (the write cost).
    pub moves: u64,
    /// Total model pages rewritten by `put` and `delete` so far.
    pub page_writes: u64,
}

impl SortedArrayMap {
    pub fn new() -> Self {
        Self::default()
    }

    /// A map that refuses to hold more than `limit` entries.
    pub fn with_limit(limit: usize) -> Self {
        Self {
            limit: Some(limit),
            ..Self::default()
        }
    }

    /// Build from entries in any order: copy, then sort once. This is how a
    /// read-only index is made (Milvus builds its sorted index the same way)
    /// and it costs O(n log n) in total instead of O(n^2) for n single puts.
    /// The keys must be distinct.
    pub fn from_entries(unsorted: &[Entry]) -> Self {
        let mut entries = unsorted.to_vec();
        entries.sort_unstable_by_key(|e| e.key);
        let map = Self {
            entries,
            ..Self::default()
        };
        debug_assert!(map.validate().is_ok());
        map
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The live entries, in ascending key order.
    pub fn items(&self) -> &[Entry] {
        &self.entries
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        self.get_traced(key, &mut Trace::new())
    }

    /// `get` that also reports what the lookup cost.
    pub fn get_traced(&self, key: u64, trace: &mut Trace) -> Option<u64> {
        let i = self.lower_bound(key, Some(trace));
        // The entry at `i` was probed by the search or sits next to a probed
        // entry on the same page... unless the search never ran (i == len).
        let entry = self.entries.get(i)?;
        trace.touch((i / ENTRIES_PER_PAGE) as u64);
        trace.comparisons += 1;
        (entry.key == key).then_some(entry.value)
    }

    /// Insert or overwrite. Returns the previous value if the key existed.
    /// On `Err(OutOfSpace)` the map is unchanged.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, OutOfSpace> {
        let i = self.lower_bound(key, None);
        if let Some(entry) = self.entries.get_mut(i)
            && entry.key == key
        {
            self.page_writes += 1;
            return Ok(Some(std::mem::replace(&mut entry.value, value)));
        }
        // Check the limit BEFORE touching anything, so a failure changes nothing.
        if self.limit == Some(self.entries.len()) {
            return Err(OutOfSpace);
        }

        // Open a gap at i: everything in [i, len) moves one slot to the right.
        // `Vec::insert` does the shift (and grows the allocation if needed).
        // This shift is the reason a sorted array is a poor index for data
        // that changes: its length is "how many keys are larger than mine".
        let tail = self.entries.len() - i;
        self.entries.insert(i, Entry { key, value });
        self.moves += tail as u64;
        self.page_writes += pages_spanned(i, self.entries.len());
        Ok(None)
    }

    /// Remove a key. Returns the removed value, or None if it was absent.
    pub fn delete(&mut self, key: u64) -> Option<u64> {
        let i = self.lower_bound(key, None);
        if self.entries.get(i)?.key != key {
            return None;
        }
        // Close the gap: everything in (i, len) moves one slot to the left.
        let tail = self.entries.len() - i - 1;
        self.moves += tail as u64;
        self.page_writes += pages_spanned(i, self.entries.len());
        Some(self.entries.remove(i).value)
    }

    /// All entries with lo <= key < hi, ascending. The slice borrows the
    /// map, so the compiler rejects a `put` or `delete` while it is alive.
    pub fn range(&self, lo: u64, hi: u64) -> &[Entry] {
        let start = self.lower_bound(lo, None);
        let end = self.lower_bound(hi, None);
        if start < end {
            &self.entries[start..end]
        } else {
            &[]
        }
    }

    /// Check the invariant: keys are strictly ascending.
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.limit.is_some_and(|limit| self.entries.len() > limit) {
            return Err("len exceeds the limit");
        }
        if self
            .entries
            .windows(2)
            .any(|pair| pair[0].key >= pair[1].key)
        {
            return Err("keys not strictly ascending");
        }
        Ok(())
    }

    /// Binary search: index of the first entry whose key is >= `key`
    /// (`len` if there is none). Chapter 02 is entirely about this function.
    fn lower_bound(&self, key: u64, mut trace: Option<&mut Trace>) -> usize {
        let mut lo = 0;
        let mut hi = self.entries.len();
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if let Some(t) = trace.as_deref_mut() {
                t.comparisons += 1;
                // Looking at entry `mid` means having its page in memory.
                t.touch((mid / ENTRIES_PER_PAGE) as u64);
            }
            if self.entries[mid].key < key {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        lo
    }
}

/// Pages that contain any of the slots [first, end): the pages a shift
/// starting at `first` has to rewrite.
fn pages_spanned(first: usize, end: usize) -> u64 {
    debug_assert!(first < end);
    ((end - 1) / ENTRIES_PER_PAGE - first / ENTRIES_PER_PAGE + 1) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ops::{Config, Op, OpStream, Oracle, Weights};

    #[test]
    fn put_keeps_keys_sorted_and_counts_the_shifted_entries() {
        let mut map = SortedArrayMap::new();
        assert_eq!(map.put(20, 200), Ok(None));
        assert_eq!(map.moves, 0); // appended at the end: nothing moves
        assert_eq!(map.put(30, 300), Ok(None));
        assert_eq!(map.moves, 0);
        assert_eq!(map.put(10, 100), Ok(None));
        assert_eq!(map.moves, 2); // new smallest key: both others move
        assert_eq!(map.put(20, 222), Ok(Some(200))); // overwrite
        assert_eq!(map.moves, 2);

        map.validate().unwrap();
        assert_eq!(map.len(), 3);
        assert_eq!(map.get(20), Some(222));
        assert_eq!(map.get(25), None);
        assert_eq!(map.get(99), None);
    }

    #[test]
    fn delete_closes_the_gap() {
        let mut map = SortedArrayMap::new();
        for k in [1, 2, 3, 4, 5] {
            map.put(k, k * 10).unwrap();
        }
        map.moves = 0;

        assert_eq!(map.delete(2), Some(20));
        assert_eq!(map.moves, 3); // 3, 4, 5 moved left
        assert_eq!(map.delete(2), None);
        assert_eq!(map.delete(5), Some(50));
        assert_eq!(map.moves, 3); // last entry: nothing to move
        map.validate().unwrap();
        assert_eq!(map.len(), 3);
    }

    #[test]
    fn range_is_a_contiguous_slice_with_lo_inclusive_and_hi_exclusive() {
        let mut map = SortedArrayMap::new();
        for k in [10, 20, 30, 40] {
            map.put(k, k + 1).unwrap();
        }
        let r = map.range(20, 40);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].key, 20);
        assert_eq!(r[1].key, 30);
        assert!(map.range(21, 30).is_empty());
        assert!(map.range(40, 20).is_empty());
        assert_eq!(map.range(0, u64::MAX).len(), 4);
    }

    #[test]
    fn from_entries_sorts_once() {
        let map = SortedArrayMap::from_entries(&[
            Entry { key: 3, value: 30 },
            Entry { key: 1, value: 10 },
            Entry { key: 2, value: 20 },
        ]);
        map.validate().unwrap();
        assert_eq!(map.moves, 0);
        assert_eq!(map.get(2), Some(20));
    }

    #[test]
    fn validate_rejects_an_unsorted_array() {
        let mut map = SortedArrayMap::new();
        map.entries = vec![Entry { key: 2, value: 0 }, Entry { key: 1, value: 0 }];
        assert!(map.validate().is_err());
        map.entries[1].key = 2; // a duplicate is not strictly ascending either
        assert!(map.validate().is_err());
    }

    #[test]
    fn a_lookup_in_100000_entries_at_most_18_comparisons_and_9_page_reads() {
        let n = 100_000u64;
        let unsorted: Vec<Entry> = (0..n)
            .map(|i| Entry {
                key: (n - i) * 10,
                value: i,
            })
            .collect();
        let map = SortedArrayMap::from_entries(&unsorted);

        let mut max_comparisons = 0;
        let mut max_pages = 0;
        for i in 0..n {
            let mut trace = Trace::new();
            assert!(map.get_traced((i + 1) * 10, &mut trace).is_some());
            max_comparisons = max_comparisons.max(trace.comparisons);
            max_pages = max_pages.max(trace.page_reads);
        }
        // ceil(log2(100000)) = 17 halvings, plus the final equality check.
        assert_eq!(max_comparisons, 18);
        // The array spans 391 pages. Each early probe lands on a different page;
        // the reads stop only when the search interval fits inside one page,
        // after about log2(391) = 8.6 halvings.
        assert_eq!(max_pages, 9);
    }

    #[test]
    fn put_at_the_limit_out_of_space_leaves_the_map_unchanged() {
        // Room for exactly 16 entries, like the 256-byte buffer in Zig.
        let mut map = SortedArrayMap::with_limit(16);
        for i in 0..16 {
            map.put(100 - i, i).unwrap();
        }
        assert_eq!(map.put(1, 1), Err(OutOfSpace));
        map.validate().unwrap();
        assert_eq!(map.len(), 16);
        assert_eq!(map.get(1), None);
        assert_eq!(map.get(85), Some(15));
        // Overwriting needs no room, so it still works on a full map.
        assert_eq!(map.put(85, 7), Ok(Some(15)));
    }

    /// Mirror of Zig's checkAllAllocationFailures: fail at every possible
    /// point (here: every possible limit) and check the map stays valid.
    #[test]
    fn put_under_every_possible_limit() {
        let count = 40u64;
        for limit in 0..count as usize {
            let mut map = SortedArrayMap::with_limit(limit);
            for i in 0..count {
                let result = map.put((i * 7) % count, i);
                assert_eq!(result.is_err(), i as usize >= limit);
                map.validate().unwrap();
            }
            assert_eq!(map.len(), limit);
        }
    }

    #[test]
    fn model_test_against_the_oracle() {
        let mut map = SortedArrayMap::new();
        let mut oracle = Oracle::new();
        let config = Config {
            seed: 1,
            count: 5000,
            key_space: 200,
            weights: Weights::default(),
        };
        for op in OpStream::new(config) {
            match op {
                Op::Put { key, value } => {
                    assert_eq!(map.put(key, value), Ok(oracle.put(key, value)))
                }
                Op::Delete { key } => assert_eq!(map.delete(key), oracle.delete(key)),
                Op::Get { key } => assert_eq!(map.get(key), oracle.get(key)),
                Op::Range { lo, hi } => {
                    let want = oracle.range(lo, hi);
                    let got = map.range(lo, hi);
                    assert_eq!(got.len(), want.len());
                    for (w, g) in want.iter().zip(got) {
                        assert_eq!((w.key, w.value), (g.key, g.value));
                    }
                }
            }
            map.validate().unwrap();
            assert_eq!(map.len(), oracle.len());
        }
    }
}
