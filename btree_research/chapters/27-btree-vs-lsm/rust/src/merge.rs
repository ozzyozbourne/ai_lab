//! K-way merge: several sorted inputs in, one sorted stream out, and for each
//! key only its NEWEST version survives.
//!
//! This one routine is both halves of an LSM-tree's cost:
//!   * compaction is "merge these runs and write the result as a new run";
//!   * a range scan is "merge the memtable and every run, and stop early".
//!
//! Inputs are added newest first, so an input's position is its age rank.
//! A binary min-heap of input numbers, ordered by (current key, rank), always
//! has the smallest key on top, and among equal keys the newest version.
//!
//! All state is in fixed arrays inside the `Merger` (a cursor per input and
//! the heap): a merge never allocates. Reading is charged to the device one
//! block at a time, as a cursor enters each block.

use crate::device::{Device, Kind};
use crate::memtable::{Memtable, NIL};
use crate::run::{Geometry, Run, Slot};

/// Most inputs one merge can have: the memtable, every level-0 run and one
/// run per deeper level. `Lsm::new` asserts that its configuration fits.
pub const MAX_SOURCES: usize = 32;

#[derive(Debug, Clone, Copy)]
enum Source<'a> {
    /// A run on the device.
    Run {
        slots: &'a [Slot],
        pos: usize,
        /// Index levels of the run (`Geometry::index_height`).
        index_height: usize,
        /// Data block the cursor has paid for, if any.
        loaded: Option<usize>,
    },
    /// The memtable: in RAM, so it costs nothing to read.
    Mem { table: &'a Memtable, node: u32 },
}

impl Source<'_> {
    fn peek(&self) -> Option<Slot> {
        match *self {
            Source::Run { slots, pos, .. } => slots.get(pos).copied(),
            Source::Mem { table, node } => (node != NIL).then(|| table.slot(node)),
        }
    }
}

#[derive(Debug)]
pub struct Merger<'a> {
    geo: Geometry,
    sources: [Source<'a>; MAX_SOURCES],
    count: usize,
    /// heap[..heap_len]: numbers of the inputs that still have a slot.
    heap: [u8; MAX_SOURCES],
    heap_len: usize,
    /// Older versions of a key that were skipped because a newer input had
    /// the same key.
    pub shadowed: u64,
}

impl<'a> Merger<'a> {
    pub fn new(geo: Geometry) -> Merger<'a> {
        Merger {
            geo,
            sources: [Source::Run {
                slots: &[],
                pos: 0,
                index_height: 1,
                loaded: None,
            }; MAX_SOURCES],
            count: 0,
            heap: [0; MAX_SOURCES],
            heap_len: 0,
            shadowed: 0,
        }
    }

    /// Adds a run, positioned at slot `from`. Add inputs NEWEST FIRST.
    pub fn add_run(&mut self, dev: &mut Device, run: &'a Run, from: usize) {
        self.push_source(
            dev,
            Source::Run {
                slots: &run.slots,
                pos: from,
                index_height: self.geo.index_height(run.len()),
                loaded: None,
            },
        );
    }

    /// Adds the memtable, positioned at `node` (from `Memtable::seek`).
    pub fn add_memtable(&mut self, dev: &mut Device, table: &'a Memtable, node: u32) {
        self.push_source(dev, Source::Mem { table, node });
    }

    fn push_source(&mut self, dev: &mut Device, source: Source<'a>) {
        assert!(self.count < MAX_SOURCES);
        let s = self.count as u8;
        self.sources[self.count] = source;
        self.count += 1;
        self.load(dev, s);
        if self.sources[s as usize].peek().is_none() {
            return; // empty input
        }
        self.heap[self.heap_len] = s;
        self.heap_len += 1;
        self.sift_up(self.heap_len - 1);
    }

    /// Charges the device for the block under the cursor of input `s`, if the
    /// cursor has just entered it: one data block, plus, on every index
    /// level, the index block above it unless the cursor was already under
    /// that one. The first block of a stream therefore costs the whole path
    /// from the run's root, exactly like a point lookup, and a stream that
    /// reads a whole run reads each of its index blocks once.
    fn load(&mut self, dev: &mut Device, s: u8) {
        let (block_entries, fan) = (self.geo.block_entries, self.geo.index_fanout);
        if let Source::Run {
            slots,
            pos,
            index_height,
            loaded,
        } = &mut self.sources[s as usize]
        {
            if *pos >= slots.len() {
                return;
            }
            let block = *pos / block_entries;
            if *loaded == Some(block) {
                return;
            }
            let mut span = fan; // data blocks under one index block
            for _ in 0..*index_height {
                if loaded.is_none_or(|old| old / span != block / span) {
                    dev.read(Kind::Index, 1);
                }
                span *= fan;
            }
            dev.read(Kind::Data, 1);
            *loaded = Some(block);
        }
    }

    fn advance(&mut self, dev: &mut Device, s: u8) {
        match &mut self.sources[s as usize] {
            Source::Mem { table, node } => *node = table.next(*node),
            Source::Run { pos, .. } => *pos += 1,
        }
        self.load(dev, s);
    }

    fn key_of(&self, s: u8) -> u64 {
        self.sources[s as usize]
            .peek()
            .expect("inputs in the heap have a slot")
            .key
    }

    /// (key, rank) order: smaller key first; for equal keys the newer input.
    fn less(&self, a: u8, b: u8) -> bool {
        (self.key_of(a), a) < (self.key_of(b), b)
    }

    fn sift_up(&mut self, start: usize) {
        let mut i = start;
        while i > 0 {
            let parent = (i - 1) / 2;
            if !self.less(self.heap[i], self.heap[parent]) {
                break;
            }
            self.heap.swap(i, parent);
            i = parent;
        }
    }

    fn sift_down(&mut self) {
        let mut i = 0;
        loop {
            let mut smallest = i;
            for child in [2 * i + 1, 2 * i + 2] {
                if child < self.heap_len && self.less(self.heap[child], self.heap[smallest]) {
                    smallest = child;
                }
            }
            if smallest == i {
                return;
            }
            self.heap.swap(i, smallest);
            i = smallest;
        }
    }

    /// Advances the input on top of the heap and restores the heap order.
    fn advance_top(&mut self, dev: &mut Device) {
        let s = self.heap[0];
        self.advance(dev, s);
        if self.sources[s as usize].peek().is_none() {
            // Input exhausted: the last heap entry takes its place.
            self.heap_len -= 1;
            self.heap[0] = self.heap[self.heap_len];
        }
        self.sift_down();
    }

    /// Key of the slot `next` would return, without consuming anything.
    pub fn peek_key(&self) -> Option<u64> {
        (self.heap_len > 0).then(|| self.key_of(self.heap[0]))
    }

    /// The newest version of the next key in ascending order (tombstones
    /// included: the caller decides whether they may be dropped).
    pub fn next(&mut self, dev: &mut Device) -> Option<Slot> {
        if self.heap_len == 0 {
            return None;
        }
        let winner = self.sources[self.heap[0] as usize].peek()?;
        self.advance_top(dev);
        // Every other input positioned at the same key holds an older
        // version. Skip them all: that is how an overwrite finally
        // reclaims space.
        while self.peek_key() == Some(winner.key) {
            self.shadowed += 1;
            self.advance_top(dev);
        }
        Some(winner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::run::Builder;

    fn build_run(dev: &mut Device, geo: Geometry, slots: &[(u64, Option<u64>)]) -> Run {
        let mut b = Builder::new(geo, slots.len(), usize::MAX).unwrap();
        for &(key, value) in slots {
            b.append(dev, Slot { key, value });
        }
        b.finish(dev).unwrap()
    }

    #[test]
    fn three_runs_ascending_output_newest_version_wins_tombstones_pass_through() {
        let geo = Geometry {
            block_entries: 2,
            index_fanout: 2,
        };
        let mut dev = Device::new();
        let newest = build_run(&mut dev, geo, &[(3, Some(31)), (7, None)]);
        let middle = build_run(
            &mut dev,
            geo,
            &[(1, Some(12)), (3, Some(32)), (9, Some(92))],
        );
        let oldest = build_run(
            &mut dev,
            geo,
            &[(3, Some(33)), (5, Some(53)), (7, Some(73))],
        );

        let before = dev.counters;
        let mut m = Merger::new(geo);
        m.add_run(&mut dev, &newest, 0);
        m.add_run(&mut dev, &middle, 0);
        m.add_run(&mut dev, &oldest, 0);
        let expected = [
            (1, Some(12)),
            (3, Some(31)),
            (5, Some(53)),
            (7, None),
            (9, Some(92)),
        ];
        for (key, value) in expected {
            assert_eq!(m.next(&mut dev), Some(Slot { key, value }));
        }
        assert_eq!(m.next(&mut dev), None);
        assert_eq!(m.shadowed, 3); // 3 twice, 7 once
        // Every block of every input was read exactly once: 1 + 2 + 2 data
        // blocks and one index block per run.
        assert_eq!(dev.counters.since(&before).reads, [3, 5]);
    }

    #[test]
    fn a_merge_that_stops_early_reads_only_the_blocks_it_entered() {
        let geo = Geometry {
            block_entries: 2,
            index_fanout: 2,
        };
        let mut dev = Device::new();
        let slots: Vec<(u64, Option<u64>)> = (0..20).map(|i| (i * 10, Some(i))).collect();
        let run = build_run(&mut dev, geo, &slots);

        let before = dev.counters;
        let mut m = Merger::new(geo);
        m.add_run(&mut dev, &run, run.lower_bound(65)); // slot 7 = key 70, in data block 3
        assert_eq!(m.next(&mut dev).map(|s| s.key), Some(70)); // cursor moves into block 4
        assert_eq!(m.peek_key(), Some(80));
        // 10 data blocks at fan-out 2: index levels of 5, 3, 2 and 1 blocks.
        // Positioning at block 3 reads one block of each level; block 4 lies
        // under a different block of levels 1 and 2 (3/2 != 4/2, 3/4 != 4/4)
        // but under the same block of levels 3 and 4.
        assert_eq!(dev.counters.since(&before).reads, [4 + 2, 2]);
    }
}
