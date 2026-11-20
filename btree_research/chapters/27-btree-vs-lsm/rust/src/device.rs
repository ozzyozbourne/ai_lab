//! A counted block device: no bytes, only arithmetic.
//!
//! Both structures of this chapter "store" their data on one of these. The
//! device never holds a byte; it only counts how many blocks would have been
//! read, written and allocated if the structure lived on a disk. That is all
//! the three amplification factors need.
//!
//! The rules are the same for both structures, and deliberately harsh:
//!   * NOTHING is cached between operations. Every operation reads each block
//!     it looks at from the device and writes each block it changed back
//!     before it returns. (Real engines put a buffer pool in between; chapter
//!     09. The counters split index blocks from data blocks so that you can
//!     see what a cache holding all the index blocks would save.)
//!   * Within ONE operation a block is read at most once and written at most
//!     once, however often the code touches it: that is the `pin` table.
//!   * Sequential work that streams over many blocks (a scan walking the leaf
//!     chain, a compaction) uses `read` / `write` directly.
//!   * There is no write-ahead log in the model, for either structure.

/// What a block holds. The B+tree's internal nodes and the LSM's index blocks
/// are `Index`; B+tree leaves and LSM data blocks are `Data`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Index = 0,
    Data = 1,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Counters {
    /// Indexed by `Kind as usize`.
    pub reads: [u64; 2],
    pub writes: [u64; 2],
}

impl Counters {
    pub fn total_reads(&self) -> u64 {
        self.reads[0] + self.reads[1]
    }

    pub fn total_writes(&self) -> u64 {
        self.writes[0] + self.writes[1]
    }

    /// `self - earlier`: what happened between two snapshots.
    pub fn since(&self, earlier: &Counters) -> Counters {
        Counters {
            reads: [
                self.reads[0] - earlier.reads[0],
                self.reads[1] - earlier.reads[1],
            ],
            writes: [
                self.writes[0] - earlier.writes[0],
                self.writes[1] - earlier.writes[1],
            ],
        }
    }

    pub fn add(&mut self, other: &Counters) {
        for i in 0..2 {
            self.reads[i] += other.reads[i];
            self.writes[i] += other.writes[i];
        }
    }
}

/// Most blocks one B+tree operation can hold at once: per level the node, a
/// new or examined sibling or two, plus a leaf-chain neighbour and a new root.
/// A tree of order >= 3 with 2^32 nodes has fewer than 32 levels.
pub const MAX_PINS: usize = 128;

#[derive(Debug, Clone, Copy)]
struct Pin {
    id: u32,
    kind: Kind,
    dirty: bool,
}

#[derive(Debug)]
pub struct Device {
    pub counters: Counters,
    /// Blocks allocated right now, and the most there have ever been.
    pub live: u64,
    pub peak: u64,
    /// Blocks held by the operation in progress (fixed buffer, no heap).
    pins: [Pin; MAX_PINS],
    pin_count: usize,
}

impl Default for Device {
    fn default() -> Self {
        Self::new()
    }
}

impl Device {
    pub fn new() -> Device {
        Device {
            counters: Counters::default(),
            live: 0,
            peak: 0,
            pins: [Pin {
                id: 0,
                kind: Kind::Data,
                dirty: false,
            }; MAX_PINS],
            pin_count: 0,
        }
    }

    // ------------------------------------------------------ space

    pub fn alloc_blocks(&mut self, n: u64) {
        self.live += n;
        self.peak = self.peak.max(self.live);
    }

    pub fn free_blocks(&mut self, n: u64) {
        assert!(n <= self.live);
        self.live -= n;
    }

    // ------------------------------------------------- streaming I/O

    pub fn read(&mut self, kind: Kind, n: u64) {
        self.counters.reads[kind as usize] += n;
    }

    pub fn write(&mut self, kind: Kind, n: u64) {
        self.counters.writes[kind as usize] += n;
    }

    // ------------------------------------- per-operation pinned blocks

    fn find_pin(&self, id: usize) -> Option<usize> {
        self.pins[..self.pin_count]
            .iter()
            .position(|p| p.id as usize == id)
    }

    fn push_pin(&mut self, id: usize, kind: Kind, dirty: bool) {
        let id = u32::try_from(id).expect("block id fits in 32 bits");
        self.pins[self.pin_count] = Pin { id, kind, dirty };
        self.pin_count += 1;
    }

    /// The operation looks at block `id`. Costs one read the first time.
    pub fn pin(&mut self, id: usize, kind: Kind) {
        if self.find_pin(id).is_some() {
            return;
        }
        self.read(kind, 1);
        self.push_pin(id, kind, false);
    }

    /// The operation created block `id`: nothing to read, but it must be
    /// written. Also accounts for the space.
    pub fn pin_new(&mut self, id: usize, kind: Kind) {
        assert!(self.find_pin(id).is_none());
        self.alloc_blocks(1);
        self.push_pin(id, kind, true);
    }

    /// The operation changed block `id` (which it must have pinned).
    pub fn mark_dirty(&mut self, id: usize) {
        let i = self.find_pin(id).expect("a dirty block is pinned");
        self.pins[i].dirty = true;
    }

    /// The operation freed block `id`. A freed block is never written, even
    /// if it was changed first.
    pub fn release(&mut self, id: usize) {
        self.free_blocks(1);
        if let Some(i) = self.find_pin(id) {
            self.pin_count -= 1;
            self.pins[i] = self.pins[self.pin_count];
        }
    }

    /// End of the operation: every dirty block is written exactly once.
    pub fn end_op(&mut self) {
        for i in 0..self.pin_count {
            if self.pins[i].dirty {
                self.write(self.pins[i].kind, 1);
            }
        }
        self.pin_count = 0;
    }

    /// Blocks held by an operation in progress (0 between operations).
    pub fn pinned(&self) -> usize {
        self.pin_count
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_block_is_read_once_and_written_once_per_operation() {
        let mut dev = Device::new();
        dev.pin(7, Kind::Index);
        dev.pin(9, Kind::Data);
        dev.pin(7, Kind::Index); // already held: free
        dev.mark_dirty(9);
        dev.mark_dirty(9);
        dev.pin_new(12, Kind::Data); // fresh block: no read, one write
        assert_eq!(dev.counters.total_reads(), 2);
        assert_eq!(dev.counters.total_writes(), 0); // not yet
        dev.end_op();
        assert_eq!(dev.counters.reads, [1, 1]);
        assert_eq!(dev.counters.writes, [0, 2]);
        assert_eq!(dev.live, 1);

        // The next operation pays again: nothing is cached.
        dev.pin(7, Kind::Index);
        dev.end_op();
        assert_eq!(dev.counters.total_reads(), 3);
    }

    #[test]
    fn a_freed_block_is_not_written_and_peak_remembers_the_high_water_mark() {
        let mut dev = Device::new();
        dev.pin_new(1, Kind::Data);
        dev.pin_new(2, Kind::Data);
        dev.end_op();
        dev.pin(2, Kind::Data);
        dev.mark_dirty(2);
        dev.release(2);
        dev.end_op();
        assert_eq!(dev.counters.total_writes(), 2);
        assert_eq!(dev.live, 1);
        assert_eq!(dev.peak, 2);

        let before = dev.counters;
        dev.read(Kind::Data, 5);
        dev.write(Kind::Index, 2);
        let delta = dev.counters.since(&before);
        assert_eq!(delta.total_reads(), 5);
        assert_eq!(delta.writes[Kind::Index as usize], 2);
    }
}
