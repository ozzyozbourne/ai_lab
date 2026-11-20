//! A small LSM-tree (log-structured merge tree) on the counted block device.
//!
//!   put / delete ──> MEMTABLE (RAM, sorted, mutable)
//!                       │ full: FLUSH, written once as a sorted run
//!                       ▼
//!   level 0     up to `l0_runs` runs; their key ranges may overlap
//!                       │ full: COMPACT, k-way merge of all of them + level 1
//!                       ▼
//!   level 1     one run, at most  memtable * l0_runs * growth    slots
//!   level 2     one run, at most  memtable * l0_runs * growth^2  slots
//!   ...                 │ over its limit: merge the whole level into the next
//!
//! Nothing on the device is ever changed in place. A write costs no device
//! I/O at all until the memtable fills; the price is paid later, in bulk, by
//! compaction, and by readers, who may have to look in several places.
//!
//! Invariants (checked by `validate`):
//!   1. The memtable holds at most `memtable_entries` keys.
//!   2. Every run is non-empty, strictly ascending, and its min/max keys in
//!      the manifest are those of its first and last slot.
//!   3. Level 0 holds at most `l0_runs` runs; l0[i + 1] is newer than l0[i].
//!   4. NEWER DATA IS ALWAYS SHALLOWER: memtable, then level 0 newest to
//!      oldest, then level 1, 2, ... A reader that searches in this order may
//!      stop at the first hit. Compaction only ever merges ADJACENT ages, so
//!      it cannot break this.
//!   5. The device's block count is exactly the blocks of all runs.
//!   6. (When no maintenance is pending) no level is over its limit.
//!
//! Not an invariant but a space rule: a compaction whose output becomes the
//! deepest level drops tombstones, because nothing older is left to hide.
//!
//! Simplification, stated loudly: a compaction here merges a WHOLE level in
//! one go. Real engines cut each level into many tables and merge one table
//! at a time so that the work can be spread evenly; see the README.

use crate::base_node::Entry;
use crate::device::{Device, Kind};
use crate::memtable::{Lookup, Memtable, OutOfMemory};
use crate::merge::{MAX_SOURCES, Merger};
use crate::run::{Builder, Geometry, Run, Slot};

/// Levels 1 ..= MAX_LEVELS. The last one has no size limit.
pub const MAX_LEVELS: usize = 12;
pub const MAX_L0_RUNS: usize = 16;

// A scan merges the memtable, every level-0 run and every level.
const _: () = assert!(1 + MAX_L0_RUNS + MAX_LEVELS <= MAX_SOURCES);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Config {
    /// Slots per data block; first-keys per index block (see run.rs).
    pub block_entries: usize,
    pub index_fanout: usize,
    /// Distinct keys the memtable holds before it is flushed.
    pub memtable_entries: usize,
    /// Runs that level 0 collects before they are merged into level 1.
    pub l0_runs: usize,
    /// Each level may hold `growth` times as many slots as the one above.
    pub growth: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            block_entries: 15,
            index_fanout: 16,
            memtable_entries: 60,
            l0_runs: 4,
            growth: 4,
        }
    }
}

impl Config {
    pub fn geometry(&self) -> Geometry {
        Geometry {
            block_entries: self.block_entries,
            index_fanout: self.index_fanout,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub flushes: u64,
    /// Merges of level 0 into level 1, and of level n into level n + 1.
    pub l0_compactions: u64,
    pub level_merges: u64,
    /// Slots that compaction did NOT carry over: older versions of a key,
    /// and tombstones that reached the deepest level.
    pub versions_dropped: u64,
    pub tombstones_dropped: u64,
    /// Point lookups, per run: skipped thanks to the min/max check, probed
    /// (2 block reads), and probed without finding the key.
    pub runs_skipped: u64,
    pub runs_probed: u64,
    pub probes_wasted: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Violation {
    MemtableOverfull,
    RunEmpty,
    RunNotSorted,
    RunBoundsWrong,
    TooManyL0Runs,
    LevelOverLimit,
    DeviceAccounting,
}

impl std::fmt::Display for Violation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for Violation {}

#[derive(Debug)]
pub struct Lsm {
    pub cfg: Config,
    pub dev: Device,
    pub mem: Memtable,
    /// Level 0, oldest first: the last element is the most recent flush.
    pub l0: Vec<Run>,
    /// levels[n - 1] is level n: one run, or nothing yet.
    pub levels: [Option<Run>; MAX_LEVELS],
    pub stats: Stats,
    /// Most run slots that may exist at once, the output a flush or a
    /// compaction reserves included; `usize::MAX` for "no limit". This is
    /// the Rust stand-in for an allocator that can fail.
    pub slot_budget: usize,
}

impl Lsm {
    pub fn new(cfg: Config) -> Lsm {
        Self::with_slot_budget(cfg, usize::MAX)
    }

    pub fn with_slot_budget(cfg: Config, slot_budget: usize) -> Lsm {
        assert!(cfg.memtable_entries >= 1 && cfg.growth >= 2);
        assert!((1..=MAX_L0_RUNS).contains(&cfg.l0_runs));
        Lsm {
            cfg,
            dev: Device::new(),
            mem: Memtable::new(),
            l0: Vec::with_capacity(cfg.l0_runs),
            levels: std::array::from_fn(|_| None),
            stats: Stats::default(),
            slot_budget,
        }
    }

    /// Most slots level `n` (1-based) may hold before it is merged down.
    pub fn level_limit(&self, n: usize) -> usize {
        self.cfg.memtable_entries * self.cfg.l0_runs * self.cfg.growth.pow(n as u32)
    }

    /// Number of the deepest level that holds a run (0 if there is none).
    pub fn deepest_level(&self) -> usize {
        self.levels
            .iter()
            .rposition(Option::is_some)
            .map_or(0, |i| i + 1)
    }

    // ------------------------------------------------------------ writes

    /// Inserts or overwrites. Unlike the B+tree's `put` it cannot say whether
    /// the key existed: finding out would cost a read, and not reading is the
    /// whole point. On `Err(OutOfMemory)` the visible contents are unchanged.
    pub fn put(&mut self, key: u64, value: u64) -> Result<(), OutOfMemory> {
        self.maintain()?;
        self.mem.put(key, Some(value))
    }

    /// Writes a tombstone, whether or not the key exists.
    pub fn delete(&mut self, key: u64) -> Result<(), OutOfMemory> {
        self.maintain()?;
        self.mem.put(key, None)
    }

    /// True if `maintain` has work to do before the next write.
    pub fn needs_maintenance(&self) -> bool {
        self.mem.count() >= self.cfg.memtable_entries || self.pending_compaction().is_some()
    }

    /// What `compact` would do next: 0 = merge level 0 into level 1,
    /// n = merge level n into level n + 1, None = nothing.
    fn pending_compaction(&self) -> Option<usize> {
        if self.l0.len() >= self.cfg.l0_runs {
            return Some(0);
        }
        (1..MAX_LEVELS).find(|&n| {
            self.levels[n - 1]
                .as_ref()
                .is_some_and(|run| run.len() > self.level_limit(n))
        })
    }

    /// Makes room for one more write: finishes compactions left over from a
    /// failed attempt, flushes a full memtable, and compacts until every
    /// level is within its limit again. This is where ALL the device writes
    /// of an LSM-tree happen. Any step may fail with OutOfMemory; each step
    /// either completes or changes nothing, so it is simply retried by the
    /// next write.
    fn maintain(&mut self) -> Result<(), OutOfMemory> {
        while let Some(n) = self.pending_compaction() {
            self.compact(n)?;
        }
        if self.mem.count() < self.cfg.memtable_entries {
            return Ok(());
        }
        self.flush()?;
        while let Some(n) = self.pending_compaction() {
            self.compact(n)?;
        }
        Ok(())
    }

    /// Slots that may still be reserved for a new run.
    fn budget_left(&self) -> usize {
        self.slot_budget.saturating_sub(self.slots_on_device())
    }

    /// Writes the memtable as a new level-0 run and empties it. No merging:
    /// the memtable is already sorted, so this is one sequential write.
    pub fn flush(&mut self) -> Result<(), OutOfMemory> {
        if self.mem.count() == 0 {
            return Ok(());
        }
        assert!(self.l0.len() < self.cfg.l0_runs);
        let mut builder = Builder::new(self.cfg.geometry(), self.mem.count(), self.budget_left())?;
        for slot in self.mem.iter_from(self.mem.first()) {
            // Tombstones are written too: they must hide older runs.
            builder.append(&mut self.dev, slot);
        }
        let run = builder
            .finish(&mut self.dev)
            .expect("a non-empty memtable makes a run");
        self.l0.push(run);
        self.mem.reset(); // every skip-list node is gone in one call
        self.stats.flushes += 1;
        Ok(())
    }

    /// Merges level `from` (0 = all level-0 runs) with the run of the next
    /// level and installs the result as the next level's run.
    fn compact(&mut self, from: usize) -> Result<(), OutOfMemory> {
        let geo = self.cfg.geometry();
        // Tombstones can be dropped only if no older data lies below the
        // output: otherwise a dropped tombstone would let a deleted key
        // "come back" from a deeper level.
        let drop_tombstones = self.deepest_level() <= from + 1;

        // The only allocation of a compaction. If it is refused, nothing has
        // been read, written or changed.
        let budget_left = self.budget_left();

        // `upper` is level `from` (None when from == 0: then the inputs are
        // the level-0 runs); `target` is level from + 1.
        let l0: &[Run] = if from == 0 { &self.l0 } else { &[] };
        let upper = if from == 0 {
            None
        } else {
            self.levels[from - 1].as_ref()
        };
        let target = self.levels[from].as_ref();
        let input_slots = l0.iter().map(Run::len).sum::<usize>()
            + upper.map_or(0, Run::len)
            + target.map_or(0, Run::len);
        let mut builder = Builder::new(geo, input_slots, budget_left)?;

        // Inputs, newest first (invariant 4).
        let mut merger = Merger::new(geo);
        for run in l0.iter().rev().chain(upper).chain(target) {
            merger.add_run(&mut self.dev, run, 0);
        }
        while let Some(slot) = merger.next(&mut self.dev) {
            if slot.value.is_none() && drop_tombstones {
                self.stats.tombstones_dropped += 1;
                continue;
            }
            builder.append(&mut self.dev, slot);
        }
        self.stats.versions_dropped += merger.shadowed;
        let output = builder.finish(&mut self.dev);

        // The new run is complete: only now do the inputs disappear. Until
        // this point input and output existed side by side on the device,
        // which is what `Device::peak` records.
        let mut freed = 0;
        if from == 0 {
            freed += self
                .l0
                .drain(..)
                .map(|run| geo.blocks(run.len()))
                .sum::<usize>();
            self.stats.l0_compactions += 1;
        } else {
            freed += self.levels[from - 1]
                .take()
                .map_or(0, |run| geo.blocks(run.len()));
            self.stats.level_merges += 1;
        }
        freed += self.levels[from]
            .take()
            .map_or(0, |run| geo.blocks(run.len()));
        self.dev.free_blocks(freed as u64);
        self.levels[from] = output;
        Ok(())
    }

    // ------------------------------------------------------------- reads

    /// Point lookup: newest place first, stop at the first place that knows
    /// the key (invariant 4). Each run that the min/max check cannot rule out
    /// costs one index block and one data block.
    pub fn get(&mut self, key: u64) -> Option<u64> {
        let mut result = self.mem.get(key);
        // `self.dev` and `self.stats` are borrowed next to the runs, so the
        // probe is a free function over the fields it needs.
        for run in self.l0.iter().rev().chain(self.levels.iter().flatten()) {
            if result != Lookup::Absent {
                break;
            }
            result = probe(&mut self.dev, &mut self.stats, run, key);
        }
        match result {
            Lookup::Value(v) => Some(v),
            Lookup::Tombstone | Lookup::Absent => None,
        }
    }

    /// Appends every live entry with lo <= key < hi to `out`, ascending.
    /// A scan cannot stop at the first place that has a key: the next key in
    /// order may come from any run, so all of them are merged.
    pub fn range(&mut self, lo: u64, hi: u64, out: &mut Vec<Entry>) {
        if lo >= hi {
            return;
        }
        let mut merger = Merger::new(self.cfg.geometry());
        merger.add_memtable(&mut self.dev, &self.mem, self.mem.seek(lo));
        for run in self.l0.iter().rev().chain(self.levels.iter().flatten()) {
            if run.overlaps(lo, hi) {
                merger.add_run(&mut self.dev, run, run.lower_bound(lo));
            }
        }
        while merger.peek_key().is_some_and(|key| key < hi) {
            // A tombstone has done its job by winning the merge: skip it.
            if let Some(Slot {
                key,
                value: Some(value),
            }) = merger.next(&mut self.dev)
            {
                out.push(Entry { key, value });
            }
        }
    }

    // -------------------------------------------------------- inspection

    /// Slots stored on the device, stale versions and tombstones included.
    pub fn slots_on_device(&self) -> usize {
        self.l0
            .iter()
            .chain(self.levels.iter().flatten())
            .map(Run::len)
            .sum()
    }

    pub fn validate(&self) -> Result<(), Violation> {
        self.validate_structure()?;
        // 6. Limits hold whenever maintenance is not pending.
        if self.pending_compaction().is_some() {
            return Err(Violation::LevelOverLimit);
        }
        Ok(())
    }

    /// Invariants 1 to 5: these hold even after a write failed half-way.
    pub fn validate_structure(&self) -> Result<(), Violation> {
        if self.mem.count() > self.cfg.memtable_entries {
            return Err(Violation::MemtableOverfull);
        }
        if self.l0.len() > self.cfg.l0_runs {
            return Err(Violation::TooManyL0Runs);
        }
        let geo = self.cfg.geometry();
        let mut blocks = 0;
        for run in self.l0.iter().chain(self.levels.iter().flatten()) {
            check_run(run)?;
            blocks += geo.blocks(run.len());
        }
        if blocks as u64 != self.dev.live {
            return Err(Violation::DeviceAccounting);
        }
        Ok(())
    }
}

fn probe(dev: &mut Device, stats: &mut Stats, run: &Run, key: u64) -> Lookup {
    if !run.may_contain(key) {
        stats.runs_skipped += 1; // decided in RAM, no I/O
        return Lookup::Absent;
    }
    dev.read(Kind::Index, 1);
    dev.read(Kind::Data, 1);
    stats.runs_probed += 1;
    let result = run.find(key);
    // A bloom filter per run exists to make this case rare.
    if result == Lookup::Absent {
        stats.probes_wasted += 1;
    }
    result
}

fn check_run(run: &Run) -> Result<(), Violation> {
    let (Some(first), Some(last)) = (run.slots.first(), run.slots.last()) else {
        return Err(Violation::RunEmpty);
    };
    if run.slots.windows(2).any(|w| w[0].key >= w[1].key) {
        return Err(Violation::RunNotSorted);
    }
    if run.min_key != first.key || run.max_key != last.key {
        return Err(Violation::RunBoundsWrong);
    }
    Ok(())
}
