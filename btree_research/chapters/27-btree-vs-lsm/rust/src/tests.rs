//! Tests of chapter 27. The per-file unit tests live next to the code; here
//! are the tests of the two structures as wholes: exact block counts for
//! small hand-checked cases, model tests against the oracle with identical
//! operation streams, budget (allocation) failure, and `validate` catching
//! damage. Same tests, same order, as zig/src/tests.zig.

use crate::base_node::Entry;
use crate::base_tree::BPlusTree;
use crate::base_validate::Violation as TreeViolation;
use crate::bench;
use crate::device::{Counters, Kind};
use crate::lsm::{self, Lsm, Violation};
use crate::memtable::{Lookup, OutOfMemory};
use crate::ops::{self, Op, OpStream, Oracle, Weights};
use crate::{NodeId, OutOfNodes};

const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

/// 3 slots per block, memtable of 4, two runs in level 0, growth 2:
/// the configuration of the hand example.
const TINY: lsm::Config = lsm::Config {
    block_entries: 3,
    index_fanout: 4,
    memtable_entries: 4,
    l0_runs: 2,
    growth: 2,
    filter_bits_per_key: 0,
};

fn io(c: Counters) -> (u64, u64) {
    (c.total_reads(), c.total_writes())
}

// ------------------------------------------------- B+tree: block counts

#[test]
fn btree_a_put_reads_the_path_and_writes_what_it_dirtied() {
    let mut tree = BPlusTree::new(4);

    // Empty tree: nothing to read, one new leaf to write.
    let before = tree.dev.counters;
    tree.put(10, 1).unwrap();
    assert_eq!(io(tree.dev.counters.since(&before)), (0, 1));

    // Root is a leaf: read it, write it.
    let before = tree.dev.counters;
    tree.put(20, 2).unwrap();
    tree.put(5, 3).unwrap();
    assert_eq!(io(tree.dev.counters.since(&before)), (2, 2));

    // Fourth key overflows the root leaf: left half, new right half and a
    // new root are written; only the old leaf was read.
    let before = tree.dev.counters;
    tree.put(6, 4).unwrap();
    assert_eq!(io(tree.dev.counters.since(&before)), (1, 3));
    assert_eq!(tree.dev.live, 3);

    // An overwrite still rewrites the whole leaf block.
    let before = tree.dev.counters;
    assert_eq!(tree.put(6, 44), Ok(Some(4)));
    assert_eq!(io(tree.dev.counters.since(&before)), (2, 1));
    tree.validate().unwrap();
}

#[test]
fn btree_a_leaf_split_in_the_middle_of_the_chain_dirties_four_blocks() {
    let mut tree = BPlusTree::new(4);
    for k in [10, 20, 30, 40] {
        tree.put(k, k).unwrap(); // (10 20) (30 40)
    }
    tree.put(15, 15).unwrap(); // (10 15 20) (30 40)
    let before = tree.dev.counters;
    tree.put(12, 12).unwrap(); // left leaf splits; its old right neighbour needs a new prev link
    let d = tree.dev.counters.since(&before);
    // Read: root, the leaf, and the neighbour (only to fix its back link).
    assert_eq!(d.reads, [1, 2]);
    // Written: root (new separator), left half, new right half, neighbour.
    assert_eq!(d.writes, [1, 3]);
    tree.validate().unwrap();
}

#[test]
fn btree_get_costs_exactly_height_reads_and_scans_add_one_per_extra_leaf() {
    let mut tree = BPlusTree::new(4);
    for k in CANONICAL {
        tree.put(k, k * 100).unwrap();
    }
    assert_eq!(tree.height, 3);

    let before = tree.dev.counters;
    assert_eq!(tree.get(12), Some(1200));
    assert_eq!(tree.get(13), None);
    let d = tree.dev.counters.since(&before);
    assert_eq!(d.reads, [4, 2]); // 2 internal + 1 leaf, twice
    assert_eq!(d.total_writes(), 0);

    // Leaves: (1 3 5) (6 7) (10 12) (15 17) (20 25 30).
    let mut out = Vec::new();
    let before = tree.dev.counters;
    tree.range(6, 16, &mut out);
    let d = tree.dev.counters.since(&before);
    assert_eq!(out.len(), 5); // 6 7 10 12 15
    assert_eq!(out[0].key, 6);
    assert_eq!(d.total_reads(), 3 + 2); // descent to (6 7), then (10 12) and (15 17)
    tree.validate().unwrap();
}

#[test]
fn btree_delete_with_borrow_and_merge_counts_the_siblings_it_looked_at() {
    let mut tree = BPlusTree::new(4);
    for k in CANONICAL {
        tree.put(k, k).unwrap();
    }
    // A miss reads the path and writes nothing.
    let before = tree.dev.counters;
    assert_eq!(tree.delete(999), None);
    assert_eq!(io(tree.dev.counters.since(&before)), (3, 0));
    // Delete everything; every operation must leave the device consistent.
    for k in CANONICAL {
        let before = tree.dev.counters;
        assert_eq!(tree.delete(k), Some(k));
        let d = tree.dev.counters.since(&before);
        assert!(d.total_writes() <= d.total_reads()); // delete never creates a block
        tree.validate().unwrap();
    }
    assert!(tree.stats.borrows > 0 && tree.stats.merges > 0);
    assert_eq!(tree.dev.live, 0);
    assert_eq!(tree.height, 0);
}

// ---------------------------------------------------- LSM: block counts

#[test]
fn lsm_writes_are_free_until_the_memtable_is_full_then_one_flush() {
    let mut lsm = Lsm::new(TINY);
    for k in [10, 20, 5, 6] {
        lsm.put(k, k * 100).unwrap();
    }
    assert_eq!(io(lsm.dev.counters), (0, 0));
    assert_eq!(lsm.get(6), Some(600)); // from the memtable
    assert_eq!(io(lsm.dev.counters), (0, 0));

    // The fifth put finds the memtable full: 4 slots = 2 data blocks + 1 index.
    lsm.put(12, 1200).unwrap();
    assert_eq!(lsm.dev.counters.writes, [1, 2]);
    assert_eq!(lsm.l0.len(), 1);
    assert_eq!(lsm.mem.count(), 1);
    assert_eq!(lsm.dev.live, 3);

    // A lookup in the run: one index block + one data block.
    let before = lsm.dev.counters;
    assert_eq!(lsm.get(10), Some(1000));
    assert_eq!(lsm.dev.counters.since(&before).reads, [1, 1]);
    // Outside the run's key range: answered from the manifest, no I/O.
    assert_eq!(lsm.get(99), None);
    assert_eq!(lsm.get(1), None);
    assert_eq!(io(lsm.dev.counters.since(&before)), (2, 0));
    // Inside the range but absent: the probe is paid for and wasted.
    assert_eq!(lsm.get(7), None);
    assert_eq!(io(lsm.dev.counters.since(&before)), (4, 0));
    assert_eq!(lsm.stats.probes_wasted, 1);
    assert_eq!(lsm.stats.runs_skipped, 2);
    lsm.validate().unwrap();
}

#[test]
fn lsm_a_runs_index_is_a_tree_and_every_level_of_it_is_read_and_written() {
    // Regression test: the index used to be one level deep, with the choice
    // of the right index block made for free "in RAM". The B+tree paid for
    // every level, so the comparison was tilted.
    let cfg = lsm::Config {
        block_entries: 1,
        index_fanout: 2,
        memtable_entries: 8,
        l0_runs: 1,
        growth: 2,
        filter_bits_per_key: 0,
    };
    let mut lsm = Lsm::new(cfg);
    for k in 1..10 {
        lsm.put(k, k * 10).unwrap();
    }
    // The ninth put flushed keys 1..8 (8 data blocks; 4 + 2 + 1 index blocks)
    // and compacted that run into level 1: every block read once, and the
    // same 15 blocks written again.
    assert_eq!(lsm.levels[0].as_ref().unwrap().len(), 8);
    assert_eq!(cfg.geometry().index_height(8), 3);
    assert_eq!(lsm.dev.counters.writes, [14, 16]);
    assert_eq!(lsm.dev.counters.reads, [7, 8]);
    assert_eq!(lsm.dev.live, 15);
    assert_eq!(lsm.dev.peak, 30);

    // A point lookup walks root, level 2, level 1, data block: like a B+tree
    // of height 4.
    let mut before = lsm.dev.counters;
    assert_eq!(lsm.get(5), Some(50));
    assert_eq!(lsm.dev.counters.since(&before).reads, [3, 1]);

    // A scan pays the same path to find its first block, then only the
    // index blocks it newly moves under. Keys 3 and 4 are data blocks 2 and
    // 3; the cursor then steps on to block 4, which lies under another
    // level-1 block and another level-2 block, but under the same root.
    let mut out = Vec::new();
    before = lsm.dev.counters;
    lsm.range(3, 5, &mut out);
    assert_eq!(out.len(), 2);
    assert_eq!(lsm.dev.counters.since(&before).reads, [3 + 2, 3]);
    lsm.validate().unwrap();
}

#[test]
fn lsm_newest_version_wins_a_tombstone_hides_older_runs_compaction_drops_both() {
    let mut lsm = Lsm::new(TINY);
    for k in [1, 2, 3, 4] {
        lsm.put(k, k).unwrap();
    }
    lsm.put(2, 22).unwrap(); // flushes (1 2 3 4); newer version of 2 in the memtable
    lsm.delete(3).unwrap(); // tombstone in the memtable
    assert_eq!(lsm.get(2), Some(22));
    assert_eq!(lsm.get(3), None);
    assert_eq!(lsm.l0.len(), 1);

    lsm.put(5, 5).unwrap();
    lsm.put(6, 6).unwrap(); // memtable: 2' ~3 5 6
    lsm.put(7, 7).unwrap(); // flush -> two runs in level 0 -> compaction into level 1
    assert_eq!(lsm.l0.len(), 0);
    assert_eq!(lsm.deepest_level(), 1);
    // (1 2 3 4) + (2' ~3 5 6): the old 2 and the old 3 are shadowed, and the
    // tombstone itself is dropped because nothing lies below level 1.
    assert_eq!(lsm.stats.versions_dropped, 2);
    assert_eq!(lsm.stats.tombstones_dropped, 1);
    assert_eq!(lsm.levels[0].as_ref().unwrap().len(), 5); // 1 2' 4 5 6
    assert_eq!(lsm.get(2), Some(22));
    assert_eq!(lsm.get(3), None);
    lsm.validate().unwrap();
}

#[test]
fn lsm_a_tombstone_stays_on_the_device_until_compaction_reaches_the_bottom() {
    let mut lsm = Lsm::new(TINY);
    for k in 0..8 {
        lsm.put(k, k).unwrap();
    }
    lsm.delete(0).unwrap(); // flush + compaction: level 1 = (0 .. 7); memtable: ~0
    lsm.delete(1).unwrap();
    lsm.put(8, 8).unwrap();
    lsm.put(9, 9).unwrap();
    lsm.put(10, 10).unwrap(); // flush: level 0 = (~0 ~1 8 9) on top of level 1
    assert_eq!(lsm.l0.len(), 1);
    // Both the tombstones and the values they hide are on the device now.
    assert_eq!(lsm.l0[0].find(0), Lookup::Tombstone);
    assert_eq!(lsm.levels[0].as_ref().unwrap().find(0), Lookup::Value(0));
    assert_eq!(lsm.slots_on_device(), 12); // for 8 live keys on the device
    assert_eq!(lsm.get(0), None);
    assert_eq!(lsm.stats.tombstones_dropped, 0);

    for k in 11..15 {
        lsm.put(k, k).unwrap(); // second flush -> compaction into level 1
    }
    assert_eq!(lsm.stats.tombstones_dropped, 2);
    assert_eq!(lsm.stats.versions_dropped, 2);
    assert_eq!(lsm.levels[0].as_ref().unwrap().len(), 12); // 2 .. 13
    assert_eq!(lsm.get(0), None);
    lsm.validate().unwrap();
}

#[test]
fn lsm_a_scan_merges_every_overlapping_run_and_pays_for_each() {
    let mut lsm = Lsm::new(TINY);
    for k in CANONICAL {
        lsm.put(k, k * 100).unwrap();
    }
    lsm.delete(15).unwrap(); // flushes (1 3 15 25) to level 0; level 1 holds the first eight keys
    assert_eq!(lsm.l0.len(), 1);
    assert_eq!(lsm.levels[0].as_ref().unwrap().len(), 8);

    let mut out = Vec::new();
    let before = lsm.dev.counters;
    lsm.range(3, 16, &mut out);
    // 3 (level 0), 5 6 7 10 12 (level 1); 15 is hidden by the tombstone.
    let keys: Vec<u64> = out.iter().map(|e| e.key).collect();
    assert_eq!(keys, [3, 5, 6, 7, 10, 12]);
    // Level 0 run (1 3 15 | 25): index + both data blocks (the cursor moves
    // on to 25 after 15). Level 1 (5 6 7 | 10 12 17 | 20 30): index + two.
    assert_eq!(lsm.dev.counters.since(&before).reads, [2, 4]);
    lsm.validate().unwrap();
}

#[test]
fn lsm_deleting_costs_space_first_and_gives_it_back_only_through_compaction() {
    let mut lsm = Lsm::new(TINY);
    for k in 0..64 {
        lsm.put(k, k).unwrap();
    }
    let full = lsm.dev.live;
    for k in 0..64 {
        lsm.delete(k).unwrap();
    }
    for k in 0..64 {
        assert_eq!(lsm.get(k), None);
    }
    // No live key is left, yet the device is as full as before: tombstones
    // are data, and some of them still sit above the values they hide.
    assert!(lsm.dev.live >= full);
    assert!(lsm.dev.peak > 2 * full);
    // Later writes push the tombstones down until they meet the bottom.
    for k in 100..164 {
        lsm.put(k, k).unwrap();
    }
    assert_eq!(lsm.stats.tombstones_dropped, 64);
    assert_eq!(lsm.slots_on_device() + lsm.mem.count(), 64);
    lsm.validate().unwrap();
}

// ------------------------------------------------------- LSM: filters

/// `TINY` with a Bloom filter per run.
const TINY_FILTERED: lsm::Config = lsm::Config {
    filter_bits_per_key: 10,
    ..TINY
};

#[test]
fn lsm_filter_an_absent_key_inside_a_runs_range_costs_no_block_a_present_key_costs_the_same() {
    let mut plain = Lsm::new(TINY);
    let mut lsm = Lsm::new(TINY_FILTERED);
    for k in [10, 20, 5, 6, 12] {
        plain.put(k, k * 100).unwrap();
        lsm.put(k, k * 100).unwrap();
    }
    // One run (5 6 10 20) in level 0. Building its filter wrote no block.
    assert_eq!(lsm.dev.counters, plain.dev.counters);
    assert_eq!(lsm.dev.live, plain.dev.live);
    assert_eq!(lsm.filter_bits(), 40); // 4 slots x 10 bits, in RAM
    assert_eq!(plain.filter_bits(), 0);

    // 7 lies between 5 and 20, so min/max cannot help. Without a filter the
    // probe is paid for and wasted; the filter answers "no" in RAM.
    assert_eq!(plain.get(7), None);
    assert_eq!(io(plain.dev.counters.since(&lsm.dev.counters)), (2, 0));
    assert_eq!(lsm.get(7), None);
    assert_eq!(lsm.stats.filter_negatives, 1);
    assert_eq!(lsm.stats.runs_probed, 0);
    let before = lsm.dev.counters;
    // A key the run holds is never ruled out: index block + data block.
    assert_eq!(lsm.get(10), Some(1000));
    assert_eq!(io(lsm.dev.counters.since(&before)), (2, 0));
    // Outside the key range the min/max check answers first.
    assert_eq!(lsm.get(99), None);
    assert_eq!(lsm.stats.runs_skipped, 1);
    assert_eq!(lsm.stats.filter_negatives, 1);
    lsm.validate().unwrap();
}

#[test]
fn lsm_filter_changes_no_answer_no_write_and_no_scan_and_only_lowers_the_cost_of_gets() {
    let configs = [
        TINY,
        lsm::Config {
            block_entries: 1,
            index_fanout: 2,
            memtable_entries: 2,
            l0_runs: 1,
            growth: 2,
            filter_bits_per_key: 0,
        },
        lsm::Config {
            block_entries: 15,
            index_fanout: 16,
            memtable_entries: 60,
            l0_runs: 4,
            growth: 4,
            filter_bits_per_key: 0,
        },
    ];
    for (c, cfg) in configs.into_iter().enumerate() {
        // 1 bit per key is a bad filter (many false positives) and must
        // still be a correct one.
        for bits in [1, 10] {
            let mut plain = Lsm::new(cfg);
            let mut lsm = Lsm::new(lsm::Config {
                filter_bits_per_key: bits,
                ..cfg
            });
            let mut plain_out: Vec<Entry> = Vec::new();
            let mut out: Vec<Entry> = Vec::new();
            let stream = OpStream::new(ops::Config {
                seed: 700 + c as u64,
                count: 4000,
                key_space: 3000,
                weights: Weights {
                    put: 5,
                    delete: 2,
                    get: 4,
                    range: 1,
                },
            });
            for (step, op) in stream.enumerate() {
                let p0 = plain.dev.counters;
                let f0 = lsm.dev.counters;
                match op {
                    Op::Put { key, value } => {
                        plain.put(key, value).unwrap();
                        lsm.put(key, value).unwrap();
                    }
                    Op::Delete { key } => {
                        plain.delete(key).unwrap();
                        lsm.delete(key).unwrap();
                    }
                    Op::Get { key } => {
                        assert_eq!(lsm.get(key), plain.get(key));
                        // Never more blocks than without the filter.
                        let p = plain.dev.counters.since(&p0);
                        let f = lsm.dev.counters.since(&f0);
                        assert!(f.reads[0] <= p.reads[0] && f.reads[1] <= p.reads[1]);
                        continue;
                    }
                    Op::Range { lo, hi } => {
                        let hi = hi.min(lo + 50);
                        plain_out.clear();
                        out.clear();
                        plain.range(lo, hi, &mut plain_out);
                        lsm.range(lo, hi, &mut out);
                        assert_eq!(out, plain_out);
                    }
                }
                // Writes and scans: block for block the same.
                assert_eq!(lsm.dev.counters.since(&f0), plain.dev.counters.since(&p0));
                assert_eq!(lsm.dev.live, plain.dev.live);
                if step % 64 == 0 {
                    lsm.validate().unwrap();
                }
            }
            lsm.validate().unwrap();
            assert_eq!(lsm.dev.peak, plain.dev.peak);
            assert_eq!(lsm.dev.counters.writes, plain.dev.counters.writes);
            assert_eq!(lsm.stats.versions_dropped, plain.stats.versions_dropped);
            assert_eq!(lsm.filter_bits(), lsm.slots_on_device() * bits);
            assert!(lsm.stats.filter_negatives > 0);
            assert!(lsm.dev.counters.total_reads() < plain.dev.counters.total_reads());
            // Every probe the plain tree made was either made here too or
            // ruled out by a filter.
            assert_eq!(
                lsm.stats.runs_probed + lsm.stats.filter_negatives,
                plain.stats.runs_probed
            );
            assert_eq!(lsm.stats.runs_skipped, plain.stats.runs_skipped);
        }
    }
}

#[test]
fn the_harness_measures_the_filtered_tree_on_the_same_gets() {
    let r = bench::run_workload(&bench::WORKLOADS[1], bench::BENCH_ORDER, bench::BENCH_LSM);
    assert_eq!(r.mismatches, 0);
    assert_eq!(r.filter_gets.ops, r.lsm.gets.ops);
    assert!(r.get_misses > 0 && r.get_misses < r.lsm.gets.ops);
    assert!(r.filter_gets.io.total_reads() < r.lsm.gets.io.total_reads());
    assert_eq!(r.filter_gets.io.total_writes(), 0);
    assert_eq!(r.filter_bits, r.lsm_slots * bench::BENCH_FILTER_BITS);
    // Both trees did the same maintenance.
    assert_eq!(r.filter_stats.flushes, r.lsm_stats.flushes);
    assert_eq!(
        r.filter_stats.versions_dropped,
        r.lsm_stats.versions_dropped
    );
    assert_eq!(
        r.filter_stats.runs_probed + r.filter_stats.filter_negatives,
        r.lsm_stats.runs_probed
    );
    // False positives exist and are rare: under 2% at 10 bits per slot.
    assert!(r.filter_stats.probes_wasted > 0);
    assert!(r.filter_stats.probes_wasted * 50 < r.filter_stats.filter_negatives);
    // No filter was asked for, none was built: the plain tree is unchanged.
    assert_eq!(r.lsm_stats.filter_negatives, 0);
}

// ----------------------------------------------------------- model tests

/// Applies one operation stream to the B+tree, the LSM-tree and the oracle,
/// and checks every answer of both structures.
fn model_test(
    order: usize,
    cfg: lsm::Config,
    seed: u64,
    count: u64,
    key_space: u64,
    weights: Weights,
) {
    let mut tree = BPlusTree::new(order);
    let mut lsm = Lsm::new(cfg);
    let mut oracle = Oracle::new();
    let mut tree_out: Vec<Entry> = Vec::new();
    let mut lsm_out: Vec<Entry> = Vec::new();

    let stream = OpStream::new(ops::Config {
        seed,
        count,
        key_space,
        weights,
    });
    for (step, op) in stream.enumerate() {
        match op {
            Op::Put { key, value } => {
                let old = oracle.put(key, value);
                assert_eq!(tree.put(key, value), Ok(old));
                lsm.put(key, value).unwrap();
            }
            Op::Delete { key } => {
                assert_eq!(tree.delete(key), oracle.delete(key));
                lsm.delete(key).unwrap();
            }
            Op::Get { key } => {
                assert_eq!(tree.get(key), oracle.get(key));
                assert_eq!(lsm.get(key), oracle.get(key));
            }
            Op::Range { lo, hi } => {
                let want: Vec<Entry> = oracle
                    .range(lo, hi)
                    .iter()
                    .map(|e| Entry {
                        key: e.key,
                        value: e.value,
                    })
                    .collect();
                tree_out.clear();
                lsm_out.clear();
                tree.range(lo, hi, &mut tree_out);
                lsm.range(lo, hi, &mut lsm_out);
                assert_eq!(tree_out, want);
                assert_eq!(lsm_out, want);
            }
        }
        if step % 16 == 0 {
            tree.validate().unwrap();
            lsm.validate().unwrap();
        }
    }
    tree.validate().unwrap();
    lsm.validate().unwrap();
    // Final sweep: every key of the key space, on both.
    for key in 0..key_space {
        assert_eq!(tree.get(key), oracle.get(key));
        assert_eq!(lsm.get(key), oracle.get(key));
    }
}

#[test]
fn model_test_both_structures_against_the_oracle_same_operation_stream() {
    // Small memtables and growth factors make many levels out of few keys.
    let configs = [
        TINY,
        lsm::Config {
            block_entries: 1,
            index_fanout: 2,
            memtable_entries: 1,
            l0_runs: 1,
            growth: 2,
            filter_bits_per_key: 0,
        },
        lsm::Config {
            block_entries: 2,
            index_fanout: 3,
            memtable_entries: 3,
            l0_runs: 3,
            growth: 3,
            filter_bits_per_key: 0,
        },
        lsm::Config {
            block_entries: 5,
            index_fanout: 4,
            memtable_entries: 8,
            l0_runs: 4,
            growth: 4,
            filter_bits_per_key: 0,
        },
        lsm::Config {
            block_entries: 15,
            index_fanout: 16,
            memtable_entries: 60,
            l0_runs: 4,
            growth: 8,
            filter_bits_per_key: 0,
        },
    ];
    for (i, cfg) in configs.into_iter().enumerate() {
        let i = i as u64;
        let order = cfg.block_entries + 1 + usize::from(cfg.block_entries == 1);
        model_test(order, cfg, 100 + i, 3000, 40, Weights::default());
        model_test(order, cfg, 200 + i, 3000, 2000, Weights::default());
        model_test(
            order,
            cfg,
            300 + i,
            2000,
            300,
            Weights {
                put: 6,
                delete: 1,
                get: 2,
                range: 1,
            },
        );
    }
}

#[test]
fn model_test_delete_heavy_stream_tombstones_everywhere() {
    model_test(
        4,
        TINY,
        11,
        5000,
        6,
        Weights {
            put: 2,
            delete: 5,
            get: 1,
            range: 1,
        },
    );
    model_test(
        4,
        TINY,
        12,
        5000,
        200,
        Weights {
            put: 3,
            delete: 5,
            get: 1,
            range: 1,
        },
    );
    let one = lsm::Config {
        block_entries: 1,
        index_fanout: 2,
        memtable_entries: 2,
        l0_runs: 1,
        growth: 2,
        filter_bits_per_key: 0,
    };
    model_test(
        3,
        one,
        13,
        5000,
        64,
        Weights {
            put: 4,
            delete: 5,
            get: 1,
            range: 1,
        },
    );
}

#[test]
fn the_three_workloads_of_the_chapter_agree_with_the_oracle_shortened() {
    for full in bench::WORKLOADS {
        let wl = bench::Workload {
            preload: full.preload.min(1000),
            count: 2000,
            ..full
        };
        let r = bench::run_workload(&wl, bench::BENCH_ORDER, bench::BENCH_LSM);
        assert_eq!(r.mismatches, 0);
        assert_eq!(r.btree.writes.ops, r.lsm.writes.ops);
        // The LSM never reads in order to write except while compacting, and
        // batches its writes: fewer blocks written, more blocks per lookup.
        assert!(r.lsm.writes.io.total_writes() < r.btree.writes.io.total_writes());
        assert!(r.lsm.writes.max_writes > r.btree.writes.max_writes);
    }
}

#[test]
fn the_peak_is_compared_with_the_keys_that_were_live_at_the_peak() {
    // Regression test: "space amplification at the peak" used to divide the
    // peak by the packed size at the END of the run. The insert-heavy
    // workload only grows, so the LSM's peak (its last big compaction) comes
    // before the end, with fewer keys live.
    let r = bench::run_workload(&bench::WORKLOADS[0], bench::BENCH_ORDER, bench::BENCH_LSM);
    assert!(r.lsm.peak > r.lsm.blocks);
    assert!(r.lsm.peak_live_keys > 0 && r.lsm.peak_live_keys < r.live_keys as u64);
    assert!(r.btree.peak >= r.btree.blocks);
    assert!(r.btree.peak_live_keys <= r.live_keys as u64);

    // With no measured operation the peak is the preloaded state.
    let wl = bench::Workload {
        count: 0,
        ..bench::WORKLOADS[1]
    };
    let idle = bench::run_workload(&wl, bench::BENCH_ORDER, bench::BENCH_LSM);
    assert_eq!(idle.lsm.blocks, idle.lsm.peak);
    assert_eq!(idle.live_keys as u64, idle.lsm.peak_live_keys);
    assert_eq!(idle.live_keys as u64, idle.btree.peak_live_keys);
}

// ------------------------------------------- budget (allocation) failure
//
// Zig injects failures into the allocator (`checkAllAllocationFailures`,
// `FailingAllocator`). Safe Rust cannot make `Vec` fail, so the structures
// carry an explicit budget instead: nodes for the B+tree, run slots for the
// LSM-tree.

#[test]
fn lsm_every_budget_from_zero_up_is_reported_and_the_structure_stays_valid() {
    // The counterpart of Zig's "every allocation failure during a build".
    // With filters a refused builder must leave no filter behind either.
    for cfg in [TINY, TINY_FILTERED] {
        every_budget(cfg);
    }
}

fn every_budget(cfg: lsm::Config) {
    let mut completed = 0;
    for budget in 0..200 {
        let mut lsm = Lsm::with_slot_budget(cfg, budget);
        let mut failed = false;
        for i in 0..60u64 {
            let key = (i * 37) % 64;
            if lsm.put(key, i).is_err() || (i % 5 == 4 && lsm.delete(key / 2).is_err()) {
                failed = true;
                break;
            }
        }
        lsm.validate_structure().unwrap();
        if !failed {
            lsm.validate().unwrap();
            completed += 1;
        }
    }
    assert!(completed > 0 && completed < 200);
}

#[test]
fn btree_a_put_that_runs_out_of_nodes_changes_neither_the_tree_nor_the_device() {
    let mut failures = 0;
    for budget in 0..40 {
        let mut tree = BPlusTree::with_node_budget(3, budget);
        for i in 0..64u64 {
            let key = (i * 37) % 64;
            let counters = tree.dev.counters;
            let live = tree.dev.live;
            match tree.put(key, key) {
                Ok(old) => assert_eq!(old, None),
                Err(OutOfNodes) => {
                    failures += 1;
                    assert_eq!(tree.dev.counters, counters);
                    assert_eq!(tree.dev.live, live);
                    tree.validate().unwrap();
                    assert_eq!(tree.len(), i as usize);
                    assert_eq!(tree.get(key), None);
                    break;
                }
            }
            tree.validate().unwrap();
        }
    }
    assert!(failures >= 5);
}

#[test]
fn lsm_a_write_that_runs_out_of_memory_changes_no_answer_and_the_retry_finishes_the_job() {
    write_under_failure(TINY);
    write_under_failure(TINY_FILTERED);
}

fn write_under_failure(cfg: lsm::Config) {
    let mut lsm = Lsm::with_slot_budget(cfg, 0);
    let mut oracle = Oracle::new();
    let mut failures = 0;
    let mut pending_after_failure = 0;
    for i in 0..400u64 {
        let key = (i * 37) % 97;
        let is_delete = i % 7 == 6;
        // Allow exactly what is on the device plus a little: a flush may
        // fit, the compaction after it may not, or the other way round.
        lsm.slot_budget = lsm.slots_on_device() + (i % 3) as usize * 5;
        let mut attempts = 0;
        loop {
            let result = if is_delete {
                lsm.delete(key)
            } else {
                lsm.put(key, i)
            };
            match result {
                Ok(()) => break,
                Err(OutOfMemory) => {
                    failures += 1;
                    attempts += 1;
                    // Structure intact, and every key still has its old answer.
                    lsm.validate_structure().unwrap();
                    if lsm.needs_maintenance() {
                        pending_after_failure += 1;
                    }
                    for k in 0..97 {
                        assert_eq!(lsm.get(k), oracle.get(k));
                    }
                    // A failed write built no run: filters untouched.
                    assert_eq!(
                        lsm.filter_bits(),
                        lsm.slots_on_device() * cfg.filter_bits_per_key
                    );
                    lsm.slot_budget = usize::MAX;
                }
            }
        }
        assert!(attempts <= 1);
        if is_delete {
            oracle.delete(key);
        } else {
            oracle.put(key, i);
        }
        lsm.slot_budget = usize::MAX;
        lsm.validate().unwrap(); // a successful write leaves no maintenance behind
    }
    assert!(failures > 20);
    assert!(pending_after_failure > 0);
    for k in 0..97 {
        assert_eq!(lsm.get(k), oracle.get(k));
    }
}

// ------------------------------------------- validate catches corruption

#[test]
fn validate_names_the_broken_invariant() {
    let mut lsm = Lsm::new(TINY);
    for k in CANONICAL {
        lsm.put(k, k).unwrap();
    }
    lsm.put(99, 99).unwrap(); // flush: one run in level 0, one in level 1
    lsm.validate().unwrap();

    let run = lsm.levels[0].as_mut().unwrap();
    run.slots.swap(0, 1);
    assert_eq!(lsm.validate(), Err(Violation::RunNotSorted));
    lsm.levels[0].as_mut().unwrap().slots.swap(0, 1);

    lsm.levels[0].as_mut().unwrap().max_key += 1; // the manifest lies about the key range
    assert_eq!(lsm.validate(), Err(Violation::RunBoundsWrong));
    lsm.levels[0].as_mut().unwrap().max_key -= 1;

    lsm.dev.live += 1; // a leaked block
    assert_eq!(lsm.validate(), Err(Violation::DeviceAccounting));
    lsm.dev.live -= 1;

    {
        // A filter that says "no" for a key its run holds would hide the key.
        let mut filtered = Lsm::new(TINY_FILTERED);
        for k in CANONICAL {
            filtered.put(k, k).unwrap();
        }
        filtered.put(99, 99).unwrap();
        filtered.validate().unwrap();
        let words = &mut filtered.levels[0].as_mut().unwrap().filter.words;
        let saved_word = std::mem::replace(&mut words[0], 0);
        assert_eq!(filtered.validate(), Err(Violation::FilterLostKey));
        filtered.levels[0].as_mut().unwrap().filter.words[0] = saved_word;
        filtered.validate().unwrap();
    }

    let saved = lsm.cfg.l0_runs;
    lsm.cfg.l0_runs = 1; // level 0 now counts as full
    assert_eq!(lsm.validate(), Err(Violation::LevelOverLimit));
    lsm.validate_structure().unwrap();
    lsm.cfg.l0_runs = saved;
    lsm.validate().unwrap();

    let mut tree = BPlusTree::new(4);
    for k in CANONICAL {
        tree.put(k, k).unwrap();
    }
    tree.validate().unwrap();
    tree.dev.live -= 1; // a block the device forgot
    assert_eq!(tree.validate(), Err(TreeViolation::DeviceAccounting));
    tree.dev.live += 1;
    tree.dev.pin(NodeId::from_index(0).index(), Kind::Data); // an operation that never ended
    assert_eq!(tree.validate(), Err(TreeViolation::DeviceAccounting));
    tree.dev.end_op();
    tree.validate().unwrap();

    // Regression test (ported from chapter 07): a length beyond the node's
    // arrays is reported before it is used to slice them, not a panic.
    let last_leaf = tree.last_leaf;
    let saved_len = tree.nodes.get(last_leaf).len;
    tree.nodes.get_mut(last_leaf).len = crate::base_node::KEY_CAPACITY + 1;
    assert_eq!(tree.validate(), Err(TreeViolation::NodeOverfull));
    tree.nodes.get_mut(last_leaf).len = saved_len;
    tree.validate().unwrap();
}
