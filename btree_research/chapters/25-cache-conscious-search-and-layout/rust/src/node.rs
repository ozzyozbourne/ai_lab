//! One B-tree node, two memory layouts (twin of zig/src/node.zig).
//!
//! A node is a sorted list of entries `{key, child, flags}`. The obvious
//! representation is an array of structs (AoS). The cache-conscious one is a
//! struct of arrays (SoA): all keys together, all children together. A search
//! only reads keys, so in SoA every line it loads is 100% keys, while in AoS
//! half of every line is child ids the search never looks at.
//!
//! The other side of the trade: once the search has found its entry, AoS has
//! the child on the line it just read, while SoA must read the child column,
//! which is one more line. `get` reports both reads to the tracer, so the
//! counts show the saving and its price.
//!
//! Zig has `std.MultiArrayList(Entry)`, which derives the columns from the
//! struct declaration. Rust's std has nothing like it, so `SoaNode` spells the
//! columns out by hand: one `Vec` per field, kept the same length.
//!
//! Alignment caveat: a `Vec<u64>` or `Vec<Entry>` is aligned to 8 bytes, not
//! to a cache line. The tracer's counts describe a node whose key array and
//! child column each start on a line boundary. A node that starts in the
//! middle of a line can touch one line more.

use crate::search::{Select, lower_bound_halving};
use crate::trace::{Layout, NoTrace, Tracer};

/// 16 bytes: four entries per cache line in AoS form.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub key: u64,
    pub child: u32,
    pub flags: u32,
}

pub const AOS_LAYOUT: Layout = Layout {
    stride: size_of::<Entry>(),
    offset: 0,
};
pub const SOA_LAYOUT: Layout = Layout::KEYS;

/// The node has a fixed capacity, like a page. This is also how the Rust
/// twins in this guide mirror Zig's allocation-failure tests: a budget that
/// runs out returns an error instead of growing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NodeFull;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Corrupt;

/// Struct-of-arrays node. All memory is reserved in `new`.
#[derive(Debug, Clone)]
pub struct SoaNode {
    keys: Vec<u64>,
    children: Vec<u32>,
    flags: Vec<u32>,
    capacity: usize,
}

impl SoaNode {
    pub fn new(capacity: usize) -> Self {
        Self {
            keys: Vec::with_capacity(capacity),
            children: Vec::with_capacity(capacity),
            flags: Vec::with_capacity(capacity),
            capacity,
        }
    }

    /// The key column: a dense `&[u64]`, exactly what search.rs wants.
    pub fn keys(&self) -> &[u64] {
        &self.keys
    }

    pub fn len(&self) -> usize {
        self.keys.len()
    }

    /// Insert in sorted position, or overwrite the child of an existing key.
    pub fn put(&mut self, key: u64, child: u32) -> Result<(), NodeFull> {
        let i = self.lower_bound(key, &mut NoTrace);
        if i < self.keys.len() && self.keys[i] == key {
            self.children[i] = child;
            return Ok(());
        }
        if self.keys.len() == self.capacity {
            return Err(NodeFull);
        }
        // Shifts each column separately: three small memmoves instead of one.
        self.keys.insert(i, key);
        self.children.insert(i, child);
        self.flags.insert(i, 0);
        Ok(())
    }

    /// The search part of `get`: reads the key column and nothing else.
    pub fn lower_bound<T: Tracer>(&self, key: u64, tracer: &mut T) -> usize {
        lower_bound_halving(Select::Hinted, false, &self.keys[..], key, tracer)
    }

    /// The search touches only the key column. Then come two more reads, and
    /// the tracer hears about both: the equality check on key `i` (usually on
    /// a line the search already read) and, for a hit, the child column,
    /// which is a different array and so always a line of its own.
    pub fn get<T: Tracer>(&self, key: u64, tracer: &mut T) -> Option<u32> {
        let i = self.lower_bound(key, tracer);
        if i == self.keys.len() {
            return None;
        }
        tracer.cmp(i);
        if self.keys[i] != key {
            return None;
        }
        tracer.side(i);
        Some(self.children[i])
    }

    pub fn validate(&self) -> Result<(), Corrupt> {
        let same_len =
            self.children.len() == self.keys.len() && self.flags.len() == self.keys.len();
        let sorted = self.keys.windows(2).all(|w| w[0] < w[1]);
        if same_len && sorted && self.keys.len() <= self.capacity {
            Ok(())
        } else {
            Err(Corrupt)
        }
    }
}

/// Array-of-structs node with the same interface, for comparison.
#[derive(Debug, Clone)]
pub struct AosNode {
    entries: Vec<Entry>,
    capacity: usize,
}

impl AosNode {
    pub fn new(capacity: usize) -> Self {
        Self {
            entries: Vec::with_capacity(capacity),
            capacity,
        }
    }

    /// The same halving loop as `search::lower_bound_halving`, but each probe
    /// strides over 16-byte entries: half as many keys per cache line.
    pub fn lower_bound<T: Tracer>(&self, key: u64, tracer: &mut T) -> usize {
        let entries = &self.entries;
        if entries.is_empty() {
            return 0;
        }
        let mut offset = 0;
        let mut length = entries.len();
        while length > 1 {
            let half = length / 2;
            let mid = offset + half;
            tracer.cmp(mid);
            offset = std::hint::select_unpredictable(entries[mid].key < key, mid, offset);
            length -= half;
        }
        tracer.cmp(offset);
        offset + usize::from(entries[offset].key < key)
    }

    pub fn put(&mut self, key: u64, child: u32) -> Result<(), NodeFull> {
        let i = self.lower_bound(key, &mut NoTrace);
        if i < self.entries.len() && self.entries[i].key == key {
            self.entries[i].child = child;
            return Ok(());
        }
        if self.entries.len() == self.capacity {
            return Err(NodeFull);
        }
        self.entries.insert(
            i,
            Entry {
                key,
                child,
                flags: 0,
            },
        );
        Ok(())
    }

    /// Same two extra reads as `SoaNode::get`, but here the second one is
    /// free: the child is in the 16-byte entry whose key the equality check
    /// just read, and (in a line-aligned array) a 16-byte entry never
    /// straddles two lines. So there is no `tracer.side` call.
    pub fn get<T: Tracer>(&self, key: u64, tracer: &mut T) -> Option<u32> {
        let i = self.lower_bound(key, tracer);
        if i == self.entries.len() {
            return None;
        }
        tracer.cmp(i);
        (self.entries[i].key == key).then(|| self.entries[i].child)
    }

    pub fn validate(&self) -> Result<(), Corrupt> {
        let sorted = self.entries.windows(2).all(|w| w[0].key < w[1].key);
        if sorted && self.entries.len() <= self.capacity {
            Ok(())
        } else {
            Err(Corrupt)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;
    use crate::search::halving_comparisons;
    use crate::trace::Trace;

    #[test]
    fn entry_is_16_bytes_and_the_key_column_is_dense() {
        assert_eq!(size_of::<Entry>(), 16);
        let mut node = SoaNode::new(4);
        node.put(30, 3).unwrap();
        node.put(10, 1).unwrap();
        node.put(20, 2).unwrap();
        assert_eq!(node.keys(), [10, 20, 30]);
        assert_eq!(node.children, [1, 2, 3]);
        // Consecutive keys are 8 bytes apart, not 16.
        let k = node.keys();
        assert_eq!((&raw const k[1]).addr() - (&raw const k[0]).addr(), 8);
    }

    #[test]
    fn model_test_soa_and_aos_nodes_behave_like_a_sorted_oracle_and_compare_the_same_keys() {
        let capacity = 255;
        let mut soa = SoaNode::new(capacity);
        let mut aos = AosNode::new(capacity);
        // Oracle: child value per key, 0 = absent (children are stored as >= 1).
        let mut oracle = [0u32; 600];
        let mut count = 0;
        let mut rng = SplitMix64::new(2525);
        for step in 0..4000u32 {
            let key = rng.below(oracle.len() as u64);
            let slot = key as usize;
            if rng.chance(1, 3) {
                let child = step + 1;
                let is_new = oracle[slot] == 0;
                if is_new && count == capacity {
                    assert_eq!(soa.put(key, child), Err(NodeFull));
                    assert_eq!(aos.put(key, child), Err(NodeFull));
                } else {
                    soa.put(key, child).unwrap();
                    aos.put(key, child).unwrap();
                    oracle[slot] = child;
                    count += usize::from(is_new);
                }
            } else {
                let mut ts = Trace::new(SOA_LAYOUT);
                let mut ta = Trace::new(AOS_LAYOUT);
                let want = (oracle[slot] != 0).then_some(oracle[slot]);
                assert_eq!(soa.get(key, &mut ts), want);
                assert_eq!(aos.get(key, &mut ta), want);
                // Same probes, same comparison count; only the lines differ.
                assert_eq!(ts.probes(), ta.probes());
                assert_eq!(ts.comparisons, ta.comparisons);
                // The search, plus the equality check unless the needle is
                // above every key.
                let searched = halving_comparisons(count);
                assert!(ts.comparisons == searched || ts.comparisons == searched + 1);
                assert!(ts.key_lines() <= ta.key_lines());
                // Regression (review round 1, G1): the child column is a read
                // too. SoA pays one side line for every hit, AoS never does.
                assert_eq!(ts.side_lines(), u32::from(want.is_some()));
                assert_eq!(ta.side_lines(), 0);
                assert_eq!(ts.lines_read(), ts.key_lines() + ts.side_lines());
                // The search alone reads only keys, in both layouts.
                let mut ss = Trace::new(SOA_LAYOUT);
                let mut sa = Trace::new(AOS_LAYOUT);
                assert_eq!(soa.lower_bound(key, &mut ss), aos.lower_bound(key, &mut sa));
                assert_eq!(ss.comparisons, searched);
                assert_eq!(ss.side_lines() + sa.side_lines(), 0);
                assert!(ss.lines_read() <= sa.lines_read());
            }
        }
        assert_eq!(soa.len(), capacity); // the node did fill up
        soa.validate().unwrap();
        aos.validate().unwrap();
    }

    #[test]
    fn a_full_node_reports_node_full_and_stays_valid() {
        let mut soa = SoaNode::new(64);
        let mut aos = AosNode::new(64);
        for i in 0..64 {
            soa.put(i, 1).unwrap();
            aos.put(i, 1).unwrap();
        }
        assert_eq!(soa.put(1000, 1), Err(NodeFull));
        assert_eq!(aos.put(1000, 1), Err(NodeFull));
        soa.put(5, 9).unwrap(); // overwriting needs no room
        assert_eq!(soa.get(5, &mut NoTrace), Some(9));
        soa.validate().unwrap();
        aos.validate().unwrap();
    }
}
