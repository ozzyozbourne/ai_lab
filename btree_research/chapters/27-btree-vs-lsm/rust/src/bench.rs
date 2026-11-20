//! The comparison harness: one operation stream, applied to the B+tree, to
//! the LSM-tree and to the oracle, with the device counters of each structure
//! read before and after every single operation.
//!
//! The LSM-tree runs twice, side by side: once as configured, and once with
//! a Bloom filter per run (`BENCH_FILTER_BITS`). The filter changes no write
//! and no scan, only what a point lookup reads, so the second tree
//! contributes the "with filters" read numbers and nothing else.
//!
//! Only counts come out of here. No timings: block counts are what the
//! structure decides; how long a block takes is the hardware's business.

use crate::base_node::Entry;
use crate::base_tree::BPlusTree;
use crate::device::Counters;
use crate::lsm::{self, Lsm};
use crate::ops::{self, Op, OpStream, Oracle, Weights};

/// Device activity of all operations of one kind.
#[derive(Debug, Clone, Copy, Default)]
pub struct Tally {
    pub ops: u64,
    pub io: Counters,
    /// Most blocks written by a single operation: the latency spike.
    pub max_writes: u64,
    /// Entries returned (scans only).
    pub entries: u64,
}

impl Tally {
    fn record(&mut self, io: Counters) {
        self.ops += 1;
        self.io.add(&io);
        self.max_writes = self.max_writes.max(io.total_writes());
    }
}

/// One structure's side of a comparison.
#[derive(Debug, Clone, Copy, Default)]
pub struct Side {
    /// put + delete
    pub writes: Tally,
    pub gets: Tally,
    pub scans: Tally,
    /// Blocks allocated at the end, and the most at any moment.
    pub blocks: u64,
    pub peak: u64,
    /// Live keys when the operation that set `peak` returned. Space
    /// amplification at the peak divides by THIS, not by the final count:
    /// the peak usually happens earlier, when fewer keys were live.
    pub peak_live_keys: u64,
}

impl Side {
    fn note_peak(&mut self, dev_peak: u64, live_keys: usize) {
        if dev_peak > self.peak {
            self.peak = dev_peak;
            self.peak_live_keys = live_keys as u64;
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Workload {
    pub name: &'static str,
    pub seed: u64,
    /// Puts applied before measuring starts (same key space).
    pub preload: u64,
    /// Measured operations.
    pub count: u64,
    pub key_space: u64,
    pub weights: Weights,
    /// A scan covers [lo, lo + scan_span) at most.
    pub scan_span: u64,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Report {
    pub btree: Side,
    pub lsm: Side,
    pub live_keys: usize,
    /// Answers that differed from the oracle's (must be 0).
    pub mismatches: usize,
    pub btree_height: usize,
    pub lsm_levels: usize,
    pub lsm_l0_runs: usize,
    pub lsm_slots: usize,
    pub lsm_stats: lsm::Stats,
    /// Gets whose answer was "no such key". Without filters these are the
    /// expensive ones for an LSM-tree, so the tables say how many there were.
    pub get_misses: u64,
    /// The same gets on the LSM-tree with a filter per run.
    pub filter_gets: Tally,
    pub filter_stats: lsm::Stats,
    /// RAM the filters hold at the end, in bits.
    pub filter_bits: usize,
}

fn same_entries(got: &[Entry], want: &[ops::Entry]) -> bool {
    got.len() == want.len()
        && got
            .iter()
            .zip(want)
            .all(|(g, w)| g.key == w.key && g.value == w.value)
}

/// No budgets are set by the harness, so writes cannot fail.
const NO_BUDGET: &str = "no budget set";

pub fn run_workload(wl: &Workload, order: usize, cfg: lsm::Config) -> Report {
    let mut tree = BPlusTree::new(order);
    let mut lsm = Lsm::new(cfg);
    let mut filtered = Lsm::new(lsm::Config {
        filter_bits_per_key: BENCH_FILTER_BITS,
        ..cfg
    });
    let mut oracle = Oracle::new();
    let mut tree_out = Vec::new();
    let mut lsm_out = Vec::new();

    // Preload: puts only, from a different seed, not measured.
    let load = OpStream::new(ops::Config {
        seed: wl.seed.wrapping_add(1),
        count: wl.preload,
        key_space: wl.key_space,
        weights: Weights {
            put: 1,
            delete: 0,
            get: 0,
            range: 0,
        },
    });
    for op in load {
        let Op::Put { key, value } = op else {
            unreachable!("put-only stream")
        };
        tree.put(key, value).expect(NO_BUDGET);
        lsm.put(key, value).expect(NO_BUDGET);
        filtered.put(key, value).expect(NO_BUDGET);
        oracle.put(key, value);
    }
    tree.dev.peak = tree.dev.live;
    lsm.dev.peak = lsm.dev.live;
    lsm.stats = lsm::Stats::default();
    filtered.stats = lsm::Stats::default();

    let mut report = Report::default();
    report.btree.note_peak(tree.dev.peak, oracle.len());
    report.lsm.note_peak(lsm.dev.peak, oracle.len());
    let stream = OpStream::new(ops::Config {
        seed: wl.seed,
        count: wl.count,
        key_space: wl.key_space,
        weights: wl.weights,
    });
    for op in stream {
        let t0 = tree.dev.counters;
        let l0 = lsm.dev.counters;
        let (tree_tally, lsm_tally) = match op {
            Op::Put { key, value } => {
                let old = oracle.put(key, value);
                if tree.put(key, value).expect(NO_BUDGET) != old {
                    report.mismatches += 1;
                }
                lsm.put(key, value).expect(NO_BUDGET);
                filtered.put(key, value).expect(NO_BUDGET);
                (&mut report.btree.writes, &mut report.lsm.writes)
            }
            Op::Delete { key } => {
                let old = oracle.delete(key);
                if tree.delete(key) != old {
                    report.mismatches += 1;
                }
                lsm.delete(key).expect(NO_BUDGET);
                filtered.delete(key).expect(NO_BUDGET);
                (&mut report.btree.writes, &mut report.lsm.writes)
            }
            Op::Get { key } => {
                let want = oracle.get(key);
                if tree.get(key) != want {
                    report.mismatches += 1;
                }
                if lsm.get(key) != want {
                    report.mismatches += 1;
                }
                if want.is_none() {
                    report.get_misses += 1;
                }
                let f0 = filtered.dev.counters;
                if filtered.get(key) != want {
                    report.mismatches += 1;
                }
                report.filter_gets.record(filtered.dev.counters.since(&f0));
                (&mut report.btree.gets, &mut report.lsm.gets)
            }
            Op::Range { lo, hi } => {
                // The generator's ranges are arbitrarily long; cut them down
                // to SHORT scans, which is where the two structures differ.
                let hi = hi.min(lo + wl.scan_span);
                let want = oracle.range(lo, hi);
                tree_out.clear();
                lsm_out.clear();
                tree.range(lo, hi, &mut tree_out);
                lsm.range(lo, hi, &mut lsm_out);
                if !same_entries(&tree_out, want) {
                    report.mismatches += 1;
                }
                if !same_entries(&lsm_out, want) {
                    report.mismatches += 1;
                }
                report.btree.scans.entries += want.len() as u64;
                report.lsm.scans.entries += want.len() as u64;
                (&mut report.btree.scans, &mut report.lsm.scans)
            }
        };
        tree_tally.record(tree.dev.counters.since(&t0));
        lsm_tally.record(lsm.dev.counters.since(&l0));
        report.btree.note_peak(tree.dev.peak, oracle.len());
        report.lsm.note_peak(lsm.dev.peak, oracle.len());
    }

    tree.validate().expect("valid tree");
    lsm.validate().expect("valid lsm");
    filtered.validate().expect("valid lsm with filters");
    report.filter_stats = filtered.stats;
    report.filter_bits = filtered.filter_bits();
    report.live_keys = oracle.len();
    report.btree.blocks = tree.dev.live;
    report.btree_height = tree.height;
    report.lsm.blocks = lsm.dev.live;
    report.lsm_levels = lsm.deepest_level();
    report.lsm_l0_runs = lsm.l0.len();
    report.lsm_slots = lsm.slots_on_device();
    report.lsm_stats = lsm.stats;
    report
}

/// The three seeded workloads of the chapter.
pub const WORKLOADS: [Workload; 3] = [
    Workload {
        name: "insert-heavy",
        seed: 271,
        preload: 0,
        count: 12_000,
        key_space: 1_000_000,
        weights: Weights {
            put: 90,
            delete: 0,
            get: 8,
            range: 2,
        },
        scan_span: 2_000,
    },
    Workload {
        name: "read-heavy",
        seed: 272,
        preload: 8_000,
        count: 12_000,
        key_space: 12_000,
        weights: Weights {
            put: 5,
            delete: 0,
            get: 80,
            range: 15,
        },
        scan_span: 40,
    },
    Workload {
        name: "update-heavy",
        seed: 273,
        preload: 4_000,
        count: 12_000,
        key_space: 4_000,
        weights: Weights {
            put: 70,
            delete: 15,
            get: 10,
            range: 5,
        },
        scan_span: 32,
    },
];

/// B+tree order used for the comparison, and the matching LSM geometry:
/// a data block holds what a leaf holds, an index block what an internal
/// node holds.
pub const BENCH_ORDER: usize = 16;
pub const BENCH_LSM: lsm::Config = lsm::Config {
    block_entries: BENCH_ORDER - 1,
    index_fanout: BENCH_ORDER,
    memtable_entries: 60,
    l0_runs: 4,
    growth: 4,
    filter_bits_per_key: 0,
};
/// Filter size of the "with filters" rows: 10 bits per slot and
/// `filter::HASH_COUNT` = 7 hash functions, a common textbook setting with a
/// false-positive rate near 1%.
pub const BENCH_FILTER_BITS: usize = 10;
