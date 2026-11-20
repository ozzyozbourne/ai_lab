//! A sorted run: the immutable, on-device half of an LSM-tree.
//!
//! A run is a sorted sequence of slots cut into DATA BLOCKS of
//! `block_entries` slots, plus INDEX BLOCKS that hold the first key of each
//! data block (`index_fanout` of them per index block). That is a static,
//! bulk-loaded, 100% full B+tree that is never updated in place.
//!
//! What is on the device and what is in RAM:
//!   device  data blocks and index blocks (counted when read or written)
//!   RAM     the "manifest": per run its smallest and largest key, and which
//!           index block covers which key range. Tiny, so not counted.
//! A point lookup into a run therefore costs 1 index block + 1 data block.
//!
//! The model keeps a run's slots in one `Vec`; block j is simply
//! `slots[j * block_entries ..][..block_entries]`.

use crate::device::{Device, Kind};
use crate::memtable::{Lookup, OutOfMemory};

/// One entry of a run or of the memtable. `value == None` is a tombstone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Slot {
    pub key: u64,
    pub value: Option<u64>,
}

/// How slots map to blocks. Shared by every run of one LSM-tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Geometry {
    /// Slots per data block. The chapter sets this to M - 1, the capacity of
    /// a B+tree leaf of order M, so both structures have the same block size.
    pub block_entries: usize,
    /// First-keys per index block. Set to M, the fan-out of an internal node.
    pub index_fanout: usize,
}

impl Geometry {
    pub fn data_blocks(&self, slots: usize) -> usize {
        slots.div_ceil(self.block_entries)
    }

    pub fn index_blocks(&self, slots: usize) -> usize {
        self.data_blocks(slots).div_ceil(self.index_fanout)
    }

    pub fn blocks(&self, slots: usize) -> usize {
        self.data_blocks(slots) + self.index_blocks(slots)
    }
}

/// Largest `block_entries` a builder's block buffer can hold.
pub const MAX_BLOCK_ENTRIES: usize = 64;

#[derive(Debug)]
pub struct Run {
    /// Strictly ascending keys; never empty; never modified after `finish`.
    /// (Public so that the tests can corrupt a run and watch `validate`.)
    pub slots: Vec<Slot>,
    /// Manifest metadata, kept in RAM: lets a lookup skip the whole run
    /// without touching the device.
    pub min_key: u64,
    pub max_key: u64,
}

impl Run {
    #[allow(clippy::len_without_is_empty)] // a run is never empty
    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn may_contain(&self, key: u64) -> bool {
        self.min_key <= key && key <= self.max_key
    }

    /// Does the run have any key in [lo, hi)?  (As far as min/max can tell.)
    pub fn overlaps(&self, lo: u64, hi: u64) -> bool {
        lo < hi && self.min_key < hi && lo <= self.max_key
    }

    /// Index of the first slot with key >= `key`.
    pub fn lower_bound(&self, key: u64) -> usize {
        self.slots.partition_point(|s| s.key < key)
    }

    /// Looks the key up, assuming the caller already paid for the blocks.
    pub fn find(&self, key: u64) -> Lookup {
        match self.slots.get(self.lower_bound(key)) {
            Some(slot) if slot.key == key => match slot.value {
                Some(v) => Lookup::Value(v),
                None => Lookup::Tombstone,
            },
            _ => Lookup::Absent,
        }
    }
}

/// Writes a run from slots that arrive in ascending key order.
///
/// The builder owns ONE block-sized buffer. Slots collect there and leave for
/// the device a whole block at a time; that buffer is all the memory a flush
/// or a compaction needs on its output side, however large the run gets.
#[derive(Debug)]
pub struct Builder {
    geo: Geometry,
    slots: Vec<Slot>,
    block: [Slot; MAX_BLOCK_ENTRIES],
    block_len: usize,
}

impl Builder {
    /// `max_slots` is an upper bound on what will be appended (the sum of the
    /// inputs). Reserving it here is the builder's ONLY allocation, so a merge
    /// that got this far cannot fail half-way through. `budget` is how many
    /// slots may still be reserved; it stands in for the allocator that can
    /// say no in the Zig version.
    pub fn new(geo: Geometry, max_slots: usize, budget: usize) -> Result<Builder, OutOfMemory> {
        assert!((1..=MAX_BLOCK_ENTRIES).contains(&geo.block_entries));
        assert!(geo.index_fanout >= 2);
        if max_slots > budget {
            return Err(OutOfMemory);
        }
        Ok(Builder {
            geo,
            slots: Vec::with_capacity(max_slots),
            block: [Slot {
                key: 0,
                value: None,
            }; MAX_BLOCK_ENTRIES],
            block_len: 0,
        })
    }

    pub fn append(&mut self, dev: &mut Device, slot: Slot) {
        self.block[self.block_len] = slot;
        self.block_len += 1;
        if self.block_len == self.geo.block_entries {
            self.write_block(dev);
        }
    }

    fn write_block(&mut self, dev: &mut Device) {
        if let Some(last) = self.slots.last() {
            // Invariant: a run is strictly ascending across block borders too.
            assert!(last.key < self.block[0].key);
        }
        self.slots.extend_from_slice(&self.block[..self.block_len]);
        self.block_len = 0;
        dev.alloc_blocks(1);
        dev.write(Kind::Data, 1);
    }

    /// Writes the last partial block and the index blocks. Returns `None` if
    /// nothing was appended: there is no empty run.
    pub fn finish(mut self, dev: &mut Device) -> Option<Run> {
        if self.block_len > 0 {
            self.write_block(dev);
        }
        let (min_key, max_key) = (self.slots.first()?.key, self.slots.last()?.key);
        let index_blocks = self.geo.index_blocks(self.slots.len()) as u64;
        dev.alloc_blocks(index_blocks);
        dev.write(Kind::Index, index_blocks);
        Some(Run {
            slots: self.slots,
            min_key,
            max_key,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn geometry_slots_to_blocks() {
        let g = Geometry {
            block_entries: 3,
            index_fanout: 4,
        };
        assert_eq!(g.data_blocks(1), 1);
        assert_eq!(g.data_blocks(3), 1);
        assert_eq!(g.data_blocks(4), 2);
        assert_eq!(g.index_blocks(12), 1); // 4 data blocks: one index block
        assert_eq!(g.index_blocks(13), 2); // 5 data blocks: two
        assert_eq!(g.blocks(13), 7);
    }

    #[test]
    fn builder_writes_whole_blocks_then_the_index_and_the_run_answers_lookups() {
        let g = Geometry {
            block_entries: 3,
            index_fanout: 4,
        };
        let mut dev = Device::new();
        let mut b = Builder::new(g, 10, usize::MAX).unwrap();
        for k in [2, 4, 6, 8, 10, 12, 14] {
            b.append(
                &mut dev,
                Slot {
                    key: k,
                    value: (k != 8).then_some(k * 10),
                },
            );
        }
        // Two full blocks are on the device already, the seventh slot is buffered.
        assert_eq!(dev.counters.total_writes(), 2);
        let run = b.finish(&mut dev).unwrap();
        assert_eq!(dev.counters.writes, [1, 3]); // 1 index, 3 data
        assert_eq!(dev.live, 4);
        assert_eq!((run.min_key, run.max_key), (2, 14));

        assert_eq!(run.find(6), Lookup::Value(60));
        assert_eq!(run.find(8), Lookup::Tombstone);
        assert_eq!(run.find(7), Lookup::Absent);
        assert!(!run.may_contain(1) && !run.may_contain(15) && run.may_contain(7));
        assert!(run.overlaps(14, 20) && !run.overlaps(15, 20) && !run.overlaps(0, 2));
        assert_eq!(run.lower_bound(7), 3);
    }

    #[test]
    fn a_builder_with_nothing_appended_produces_no_run() {
        let mut dev = Device::new();
        let b = Builder::new(
            Geometry {
                block_entries: 3,
                index_fanout: 4,
            },
            5,
            usize::MAX,
        )
        .unwrap();
        assert!(b.finish(&mut dev).is_none());
        assert_eq!(dev.live, 0);
    }

    #[test]
    fn a_builder_over_budget_is_refused_before_anything_is_written() {
        let g = Geometry {
            block_entries: 3,
            index_fanout: 4,
        };
        assert_eq!(Builder::new(g, 5, 4).err(), Some(OutOfMemory));
        assert!(Builder::new(g, 5, 5).is_ok());
    }
}
