//! Bounded stress test: a few threads hammer one tree, then the result is
//! checked while nothing is running.
//!
//! Everything a worker does is decided by its seed alone, never by what the
//! other threads did. So although the interleaving (and with it the shape of
//! the tree) differs from run to run, the SET of keys that ends up in the
//! tree is the same every time, and so is everything `check` reports.
//!
//! Bounded by operation count, not by a clock: no sleeps, no timing asserts.

use std::thread;

use crate::dump::entries;
use crate::ops::Oracle;
use crate::prng::SplitMix64;
use crate::probe::value_of;
use crate::tree::Tree;

pub const MAX_THREADS: u32 = 4;

#[derive(Debug, Clone, Copy)]
pub struct Config {
    pub threads: u32,
    pub ops_per_thread: u32,
    pub seed: u64,
    /// Each worker draws from this many keys.
    pub key_space: u64,
    /// false: worker t only uses keys with key % threads == t, so no two
    /// workers ever touch the same key (they still share leaves and split
    /// each other's nodes). true: all workers draw from the same keys.
    pub overlapping: bool,
}

impl Config {
    /// A node table that cannot run out for this workload: at most one leaf
    /// per key (M = 4 allows leaves with a single key) and fewer internal
    /// nodes than leaves.
    pub fn node_capacity(&self) -> u32 {
        let keys = if self.overlapping {
            self.key_space
        } else {
            self.key_space * u64::from(self.threads)
        };
        (2 * keys + 16) as u32
    }
}

/// What one worker hands back when it is joined.
#[derive(Debug, Default)]
pub struct Worker {
    /// Every key this worker has put, in order. Zig grows these logs from a
    /// shared thread-safe arena; here each thread owns its `Vec` and moves
    /// it out through `join`.
    pub log: Vec<u64>,
    /// Puts that returned None: "the key was not there before".
    pub fresh: usize,
    /// Gets of a key this worker had already put that did NOT return its
    /// value. Must stay 0: an insert that has returned is visible.
    pub lost: usize,
    /// Operations that failed (table exhausted). 0 unless the test wants it.
    pub failed: usize,
}

fn work(tree: &Tree, config: Config, index: u32) -> Worker {
    let mut w = Worker::default();
    let mut rng = SplitMix64::new(config.seed.wrapping_add(u64::from(index)));
    for _ in 0..config.ops_per_thread {
        if !w.log.is_empty() && rng.below(4) == 0 {
            let key = w.log[rng.below(w.log.len() as u64) as usize];
            if tree.get(key) != Some(value_of(key)) {
                w.lost += 1;
            }
        } else {
            let k = rng.below(config.key_space);
            let key = if config.overlapping {
                k
            } else {
                k * u64::from(config.threads) + u64::from(index)
            };
            match tree.put(key, value_of(key)) {
                Ok(old) => {
                    if old.is_none() {
                        w.fresh += 1;
                    }
                    w.log.push(key);
                }
                Err(_) => w.failed += 1,
            }
        }
    }
    w
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Report {
    /// Entries in the tree at the end.
    pub keys: usize,
    /// Distinct keys in the workers' logs (the oracle's size).
    pub expected_keys: usize,
    /// Sum of the workers' `fresh` counters. Equal to `expected_keys` exactly
    /// when every key was inserted once: no insert lost, none done twice.
    pub fresh: usize,
    pub lost: usize,
    pub failed: usize,
    /// Positions where the leaf chain and the oracle disagree.
    pub mismatches: usize,
    pub valid: bool,
}

impl Report {
    pub fn ok(&self) -> bool {
        self.valid
            && self.mismatches == 0
            && self.lost == 0
            && self.failed == 0
            && self.keys == self.expected_keys
            && self.fresh == self.expected_keys
    }
}

/// Runs the workers to completion and checks the quiescent tree.
pub fn run(tree: &Tree, config: Config) -> Report {
    assert!((1..=MAX_THREADS).contains(&config.threads));
    // `thread::scope` joins every thread before it returns, also on panic,
    // which is what lets the workers borrow `tree`.
    let workers: Vec<Worker> = thread::scope(|scope| {
        let handles: Vec<_> = (0..config.threads)
            .map(|index| scope.spawn(move || work(tree, config, index)))
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().expect("worker panicked"))
            .collect()
    });
    check(tree, &workers)
}

/// Replays the workers' logs into the oracle, one after the other, and
/// compares. The order of the replay does not matter because a key always
/// gets the same value.
pub fn check(tree: &Tree, workers: &[Worker]) -> Report {
    let mut oracle = Oracle::new();
    let mut report = Report {
        keys: tree.len(),
        expected_keys: 0,
        fresh: 0,
        lost: 0,
        failed: 0,
        mismatches: 0,
        valid: tree.validate().is_ok(),
    };
    for w in workers {
        for &key in &w.log {
            oracle.put(key, value_of(key));
        }
        report.fresh += w.fresh;
        report.lost += w.lost;
        report.failed += w.failed;
    }
    report.expected_keys = oracle.len();
    let got = entries(tree);
    let expected = oracle.range(0, u64::MAX);
    report.mismatches = expected
        .iter()
        .zip(&got)
        .filter(|(e, g)| e.key != g.key || e.value != g.value)
        .count()
        + expected.len().saturating_sub(got.len())
        + usize::from(got.len() > expected.len());
    report
}
