//! Interleaving fuzzer: the property the chapter is about, under random test.
//!
//! The fixed scenarios in tests.rs pause ONE scan at ONE chosen moment. Here
//! many scans are paused at once, under up to eight open snapshots, and are
//! advanced a few rows at a time while writers, VACUUM and the three steps of
//! page deletion (`mark_half_dead`, `unlink_half_dead`, `recycle`), called one
//! by one in any order, change the tree under them.
//!
//! After every step:
//!   - `validate()` holds;
//!   - the page handle every paused scan saved is still a live slot (this is
//!     the recycling rule, stated as a check);
//!
//! and regularly a fresh scan and a `get` under every open snapshot equal an
//! independent oracle: a flat list of versions that is never garbage
//! collected. A paused scan must return exactly its snapshot's rows, in order,
//! none lost and none twice, however often it was interrupted.
//!
//! The last test swaps `recycle(horizon)` for `recycle_ignoring_snapshots()`
//! and demands that the same fuzzer then FAILS: a test that cannot fail proves
//! nothing. zig/src/fuzz.zig is the same file line for line (same generator,
//! same seeds, same counts).

use crate::base_arena::NodeId;
use crate::base_node::PageState;
use crate::db::{Cursor, Db, VacuumOptions};

const EVERYTHING: u64 = u64::MAX;

/// xorshift64: tiny, seedable, and the same numbers in both languages.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        (self.next() >> 11) % n
    }
    fn pick(&mut self, len: usize) -> usize {
        self.below(len as u64) as usize
    }
}

/// The oracle: every version ever written, with its two transaction ids.
struct OracleVersion {
    key: u64,
    value: u64,
    xmin: u64,
    xmax: u64,
}

/// What `snapshot` sees in [lo, hi), by the definition of visibility alone.
fn visible(oracle: &[OracleVersion], snapshot: u64, lo: u64, hi: u64) -> Vec<(u64, u64)> {
    let mut out: Vec<(u64, u64)> = oracle
        .iter()
        .filter(|v| v.key >= lo && v.key < hi && v.xmin <= snapshot && (v.xmax == 0 || v.xmax > snapshot))
        .map(|v| (v.key, v.value))
        .collect();
    out.sort(); // one visible version per key: keys are unique
    out
}

/// A scan stopped between two rows, and the rows it still owes.
struct Paused {
    cursor: Cursor,
    expected: Vec<(u64, u64)>,
    pos: usize,
    done: bool,
}

struct Snap {
    snapshot: u64,
    cursors: Vec<Paused>,
}

struct Options {
    seed: u64,
    order: usize,
    steps: usize,
    key_space: u64,
    /// Compare every snapshot with the oracle after every step (else every 17th).
    check_every_step: bool,
    bottom_up: bool,
    /// Recycle without asking the horizon: the bug of section 6.
    cheat: bool,
}

const MAX_SNAPSHOTS: usize = 8;

/// Proof that the runs went where the danger is, summed over all of them.
#[derive(Default)]
struct Coverage {
    pages_recycled: usize,
    pages_reused: usize,
    moved_right: usize,
}

#[derive(Debug, PartialEq)]
enum Failure {
    PausedScanPageRecycled,
    Other(String),
}

fn run(o: &Options, coverage: &mut Coverage) -> Result<(), Failure> {
    let mut rng = Rng::new(o.seed);
    let mut db = Db::new(o.order);
    db.index.bottom_up = o.bottom_up;
    let mut oracle: Vec<OracleVersion> = Vec::new();
    let mut snaps: Vec<Snap> = Vec::new();

    for step in 0..o.steps {
        let fail = |what: String| Failure::Other(format!("fuzz: seed {} order {} step {step}: {what}", o.seed, o.order));
        let r = rng.below(100);
        if r < 30 {
            // put
            let key = rng.below(o.key_space);
            let value = rng.next() % 1000;
            let old = db.put(key, value).unwrap();
            if old != end_current(&mut oracle, key, db.store.now) {
                return Err(fail(format!("put {key} replaced {old:?}")));
            }
            oracle.push(OracleVersion { key, value, xmin: db.store.now, xmax: 0 });
        } else if r < 50 {
            // delete one row, or a whole range (that is what empties pages)
            let first = rng.below(o.key_space);
            let n = if rng.below(4) == 0 { rng.below(o.key_space / 2 + 1) } else { 1 };
            for key in first..(first + n).min(o.key_space) {
                let old = db.delete(key);
                if old != end_current(&mut oracle, key, db.store.now) {
                    return Err(fail(format!("delete {key} removed {old:?}")));
                }
            }
        } else if r < 58 {
            // open a snapshot
            if snaps.len() < MAX_SNAPSHOTS {
                snaps.push(Snap { snapshot: db.store.open_snapshot().unwrap(), cursors: Vec::new() });
            }
        } else if r < 64 {
            // close one, with the scans that ran under it
            if !snaps.is_empty() {
                let s = snaps.swap_remove(rng.pick(snaps.len()));
                db.store.close_snapshot(s.snapshot);
            }
        } else if r < 72 {
            // start a scan and leave it paused before its first row
            if !snaps.is_empty() {
                let s = &mut snaps[rng.pick(snaps.len())];
                let (mut lo, mut hi) = (0, EVERYTHING);
                if rng.below(2) != 0 {
                    lo = rng.below(o.key_space);
                    hi = lo + rng.below(o.key_space);
                }
                let expected = visible(&oracle, s.snapshot, lo, hi);
                s.cursors.push(Paused { cursor: Cursor::seek(&db, s.snapshot, lo, hi), expected, pos: 0, done: false });
            }
        } else if r < 85 {
            // advance a paused scan by 1 to 5 rows
            if !snaps.is_empty() {
                let s = &mut snaps[rng.pick(snaps.len())];
                if !s.cursors.is_empty() {
                    let which = rng.pick(s.cursors.len());
                    let p = &mut s.cursors[which];
                    let n = 1 + rng.below(5);
                    for _ in 0..n {
                        if p.done {
                            break;
                        }
                        let got = p.cursor.next(&mut db).map_err(|e| fail(format!("paused scan: {e:?}")))?;
                        let want = p.expected.get(p.pos).copied();
                        if got.map(|row| (row.key, row.value)) != want {
                            return Err(fail(format!("paused scan returned {got:?}, its snapshot has {want:?} next")));
                        }
                        match got {
                            Some(_) => p.pos += 1,
                            None => p.done = true,
                        }
                    }
                }
            }
        } else if r < 90 {
            // VACUUM, one time in three without page deletion
            db.vacuum(VacuumOptions { delete_pages: rng.below(3) != 0 });
        } else if r < 94 {
            // phase 1 alone, on any leaf (most are refused: not empty, rightmost ...)
            let leaves = chain_leaves(&db, false);
            if !leaves.is_empty() {
                db.index.mark_half_dead(leaves[rng.pick(leaves.len())]);
            }
        } else if r < 97 {
            // phase 2 alone, on a page some earlier step left half-dead
            let leaves = chain_leaves(&db, true);
            if !leaves.is_empty() {
                let target = leaves[rng.pick(leaves.len())];
                let left = db.index.left_sibling(target);
                db.index.unlink_half_dead(&mut db.store, left, target);
            }
        } else if o.cheat {
            db.index.recycle_ignoring_snapshots();
        } else {
            let horizon = db.store.horizon();
            db.index.recycle(horizon);
        }

        db.validate().map_err(|e| fail(format!("{e:?}")))?;
        // The recycling rule as a check: no paused scan holds a freed handle.
        for p in snaps.iter().flat_map(|s| &s.cursors) {
            if !p.done && !p.cursor.next_leaf.is_nil() && !db.index.nodes.is_live(p.cursor.next_leaf) {
                return Err(Failure::PausedScanPageRecycled);
            }
        }
        if o.check_every_step || step % 17 == 0 {
            for s in &snaps {
                let want = visible(&oracle, s.snapshot, 0, EVERYTHING);
                let mut cursor = Cursor::seek(&db, s.snapshot, 0, EVERYTHING);
                let mut got = Vec::new();
                while let Some(row) = cursor.next(&mut db).map_err(|e| fail(format!("fresh scan: {e:?}")))? {
                    got.push((row.key, row.value));
                }
                if got != want {
                    return Err(fail(format!("snapshot {} sees {got:?}, expected {want:?}", s.snapshot)));
                }
                if rng.below(4) == 0 {
                    let key = rng.below(o.key_space);
                    let value = visible(&oracle, s.snapshot, key, key + 1).first().map(|pair| pair.1);
                    if db.get(s.snapshot, key).map_err(|e| fail(format!("get: {e:?}")))? != value {
                        return Err(fail(format!("get {key} under snapshot {}", s.snapshot)));
                    }
                }
            }
            // scans set hint bits: those must not lie either
            db.validate().map_err(|e| fail(format!("after scans: {e:?}")))?;
        }
    }

    // Close everything, delete every row, vacuum: nothing may be left behind.
    for s in snaps.drain(..) {
        db.store.close_snapshot(s.snapshot);
    }
    for key in 0..o.key_space {
        db.delete(key);
    }
    let report = db.vacuum(VacuumOptions::default());
    assert_eq!(db.index.count, 0);
    assert_eq!(db.store.versions.live_count(), 0);
    assert_eq!(report.pages_waiting, 0);
    db.validate().unwrap();
    coverage.pages_recycled += db.index.stats.pages_recycled;
    coverage.pages_reused += db.index.stats.pages_reused;
    coverage.moved_right += db.reads.moved_right;
    Ok(())
}

/// Ends the current version of `key` in the oracle; returns its value.
fn end_current(oracle: &mut [OracleVersion], key: u64, xid: u64) -> Option<u64> {
    let v = oracle.iter_mut().find(|v| v.key == key && v.xmax == 0)?;
    v.xmax = xid;
    Some(v.value)
}

/// The leaf chain as the right links give it (all of it, or only half-dead pages).
fn chain_leaves(db: &Db, only_half_dead: bool) -> Vec<NodeId> {
    let mut out = Vec::new();
    let mut leaf_id = db.index.first_leaf;
    while !leaf_id.is_nil() {
        let leaf = db.index.nodes.get(leaf_id).leaf();
        if !only_half_dead || leaf.state == PageState::HalfDead {
            out.push(leaf_id);
        }
        leaf_id = leaf.next;
    }
    out
}

const ORDERS: [usize; 5] = [3, 4, 5, 8, 16];
const KEY_SPACES: [u64; 4] = [6, 20, 60, 200];

#[test]
fn fuzz_paused_scans_survive_writers_vacuum_and_page_deletion_in_any_interleaving() {
    let mut coverage = Coverage::default();
    for seed in 1..9u64 {
        for order in ORDERS {
            let options = Options {
                seed,
                order,
                steps: 800,
                key_space: KEY_SPACES[(seed % 4) as usize],
                check_every_step: seed % 2 == 0,
                bottom_up: seed % 3 != 0,
                cheat: false,
            };
            assert_eq!(run(&options, &mut coverage), Ok(()));
        }
    }
    // Pages were freed and handed to later splits, and scans did land on dead pages.
    assert!(coverage.pages_recycled > 100);
    assert!(coverage.pages_reused > 100);
    assert!(coverage.moved_right > 100);
}

#[test]
fn fuzz_the_same_fuzzer_catches_recycling_that_ignores_the_horizon() {
    let mut caught = 0;
    let mut coverage = Coverage::default();
    for seed in 1..13u64 {
        let options = Options { seed, order: 4, steps: 800, key_space: 60, check_every_step: false, bottom_up: true, cheat: true };
        if let Err(failure) = run(&options, &mut coverage) {
            // Always the first symptom: the handle is freed before any scan can trip over it.
            assert_eq!(failure, Failure::PausedScanPageRecycled);
            caught += 1;
        }
    }
    assert_eq!(caught, 5); // of 12 seeds; the Zig test finds the same five
}
