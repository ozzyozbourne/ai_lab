//! A bounded multi-threaded workload, used by the tests and by the demo
//! program. Nothing here is timed and nothing printed depends on how the
//! threads interleave: the report contains only facts that must hold for
//! EVERY interleaving (no key lost, final content equals the oracle).
//!
//! Each worker thread
//!   * inserts `puts_per_thread` keys drawn from its own seeded SplitMix64;
//!   * after every put reads back that key, a key it inserted earlier, and a
//!     key that was in the tree before the threads started. All three must be
//!     found, whatever the other threads are splitting at that moment. This
//!     is the B-link promise: a key, once inserted, is never unreachable.
//!
//! Values are a function of the key, so when two threads put the same key
//! the outcome does not depend on who wins.

use crate::blink::BLinkTree;
use crate::ops::Oracle;
use crate::prng::SplitMix64;

pub const MAX_THREADS: usize = 4;

#[derive(Debug, Clone)]
pub struct Config {
    pub order: usize,
    pub threads: usize,
    pub puts_per_thread: usize,
    /// Keys are drawn from [0, key_space).
    pub key_space: u64,
    /// Keys inserted before the threads start.
    pub preload: usize,
    pub seed: u64,
    /// Size of the node table.
    pub capacity: usize,
    /// Run with the test hook on: every split stops after step 1 and is
    /// finished by whichever writer meets the flag next.
    pub abandon_splits: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Report {
    /// Entries in the tree at the end / in the oracle.
    pub keys: u64,
    pub expected_keys: u64,
    /// Reads during the run that missed a key known to be present.
    pub lost: u64,
    /// Puts that failed (node table full).
    pub failed_puts: u64,
    /// Differences between the final tree and the oracle.
    pub mismatches: u64,
    pub valid: bool,
    /// Flags still set at the end (always 0 unless `abandon_splits`).
    pub incomplete_splits: usize,
}

pub fn value_of(key: u64) -> u64 {
    key * 10 + 7
}

/// What one thread hands back when it is joined. The two vectors are owned
/// by the thread while it runs (Zig: a per-thread arena): no other thread
/// touches them, and they are freed together when the log is dropped.
struct WorkerLog {
    /// Every key this thread inserted, in order.
    keys: Vec<u64>,
    /// Keys a read failed to find. Must stay empty.
    missed: Vec<u64>,
    failed_puts: u64,
}

fn work(tree: &BLinkTree, seed: u64, config: &Config, preloaded: &[u64]) -> WorkerLog {
    let mut log = WorkerLog {
        keys: Vec::with_capacity(config.puts_per_thread),
        missed: Vec::new(),
        failed_puts: 0,
    };
    let mut rng = SplitMix64::new(seed);
    let expect_present = |key: u64, missed: &mut Vec<u64>| {
        if tree.get(key) != Some(value_of(key)) {
            missed.push(key);
        }
    };
    for _ in 0..config.puts_per_thread {
        let key = rng.below(config.key_space);
        if tree.put(key, value_of(key)).is_err() {
            log.failed_puts += 1;
            continue;
        }
        log.keys.push(key);
        expect_present(key, &mut log.missed);
        let earlier = log.keys[rng.below(log.keys.len() as u64) as usize];
        expect_present(earlier, &mut log.missed);
        if !preloaded.is_empty() {
            let old = preloaded[rng.below(preloaded.len() as u64) as usize];
            expect_present(old, &mut log.missed);
        }
    }
    log
}

/// Runs the workload and compares the result with a single-threaded oracle.
pub fn run(config: &Config) -> Report {
    assert!(config.threads >= 1 && config.threads <= MAX_THREADS);
    let tree = BLinkTree::new(config.order, config.capacity);
    let mut oracle = Oracle::new();
    let mut report = Report::default();

    // Preload, single-threaded.
    let mut preloaded = Vec::with_capacity(config.preload);
    let mut rng = SplitMix64::new(config.seed);
    for _ in 0..config.preload {
        let key = rng.below(config.key_space);
        preloaded.push(key);
        if tree.put(key, value_of(key)).is_err() {
            report.failed_puts += 1;
            continue;
        }
        oracle.put(key, value_of(key));
    }

    tree.set_abandon_splits(config.abandon_splits);

    // Scoped threads may borrow `tree` and `preloaded` from this stack
    // frame; the scope joins every thread before it returns.
    let logs: Vec<WorkerLog> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..config.threads)
            .map(|t| {
                let seed = config
                    .seed
                    .wrapping_add((t as u64 + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15));
                let (tree, preloaded) = (&tree, &preloaded);
                scope.spawn(move || work(tree, seed, config, preloaded))
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().expect("worker panicked"))
            .collect()
    });

    // From here on this thread is alone again. The logs are still alive:
    // the keys in them are the input of the oracle.
    tree.set_abandon_splits(false);
    for log in &logs {
        report.lost += log.missed.len() as u64;
        report.failed_puts += log.failed_puts;
        for &key in &log.keys {
            oracle.put(key, value_of(key));
        }
    }

    report.keys = tree.len();
    report.expected_keys = oracle.len() as u64;
    if report.keys != report.expected_keys {
        report.mismatches += 1;
    }
    let expected = oracle.range(0, u64::MAX);
    for e in expected {
        if tree.get(e.key) != Some(e.value) {
            report.mismatches += 1;
        }
    }
    // The other direction: walking the leaf level by right links must give
    // exactly the oracle's entries, in order.
    report.mismatches += leaf_chain_mismatches(&tree, &oracle);
    report.valid = tree.validate().is_ok();
    report.incomplete_splits = tree.incomplete_splits();
    report
}

fn leaf_chain_mismatches(tree: &BLinkTree, oracle: &Oracle) -> u64 {
    let expected = oracle.range(0, u64::MAX);
    let mut mismatches = 0;
    let mut n = 0usize;
    let mut id = tree.meta_snapshot().level_head[0];
    while !id.is_nil() {
        let p = tree.read(id);
        for (i, &key) in p.node.key_slice().iter().enumerate() {
            let value = p.node.leaf().values[i];
            if expected
                .get(n)
                .is_none_or(|e| e.key != key || e.value != value)
            {
                mismatches += 1;
            }
            n += 1;
        }
        id = p.right;
    }
    if n != expected.len() {
        mismatches += 1;
    }
    mismatches
}
