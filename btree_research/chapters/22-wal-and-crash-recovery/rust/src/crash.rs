//! crash.rs: the crash loop. "Stop the machine after write number N, for
//! every N", in the style of a deterministic simulation: one seed fixes the
//! workload and every fault, so a failing (N, mode) pair is a reproducible
//! test case, not a lucky find.
//!
//! One run:
//!   1. a fresh `Machine` (seeded); power fails after N page writes
//!   2. open the database, apply the workload's puts until one fails;
//!      `acked` = puts that returned success
//!   3. crash(mode): each unsynced write is dropped, kept or torn
//!   4. reopen (with the log: recovery runs here), validate, and compare the
//!      contents with the oracle
//!
//! The oracle allows exactly two states: the workload's first `acked` puts
//! ("before"), or those plus the one put that was in flight ("after"). The
//! in-flight put may count either way because its commit record can become
//! durable just before the power fails, when nobody is left to hear the
//! answer. Anything else (a tree that does not validate, a missing
//! acknowledged key, half an operation) is a failure.
//!
//! The same loop runs twice: with the log (`Db`), and without it (chapter
//! 12's tree directly on the disk through `PageFile`, flushed after every
//! put). The second one is the control experiment.

use crate::adapter::PageFile;
use crate::base_buffer_pool::BufferPool;
use crate::base_disk_btree::{DiskBTree, Stats as TreeStats, TreeError};
use crate::base_pager::Pager;
use crate::base_workload::Model;
use crate::db::{Db, DbError, Options};
pub use crate::machine::CrashMode;
use crate::machine::{self, Machine, SharedMachine};
use crate::prng::SplitMix64;
use crate::wal::{Recovery, Stats as WalStats};

pub const MODES: [CrashMode; 4] = [CrashMode::Drop, CrashMode::Keep, CrashMode::Tear, CrashMode::Random];

/// A fixed, seeded list of puts. Keys of 240 to 256 bytes and values of 700
/// to 1023 bytes, so that a few dozen puts already split leaves, split an
/// interior page and grow the tree to three levels (a leaf holds 3 such
/// cells, an interior page 15 separators).
#[derive(Debug, Clone, Copy)]
pub struct Workload {
    pub seed: u64,
    pub puts: u32,
    /// Keys are drawn from this many distinct keys; repeats overwrite.
    pub key_space: u32,
}

impl Workload {
    /// Put number `i` (0-based): (key, value). A function of (seed, i) alone.
    pub fn op(&self, i: u32) -> (Vec<u8>, Vec<u8>) {
        let mut rng = SplitMix64::new(self.seed.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(u64::from(i)));
        let n = rng.below(u64::from(self.key_space)) as usize;
        // "k" + three digits, padded with one letter to 240..256 bytes.
        let mut key = vec![b'a' + (n % 26) as u8; 240 + (n * 7) % 17];
        key[..4].copy_from_slice(&[b'k', b'0' + (n / 100 % 10) as u8, b'0' + (n / 10 % 10) as u8, b'0' + (n % 10) as u8]);
        let value = vec![b'A' + (i % 26) as u8; 700 + rng.below(324) as usize];
        (key, value)
    }
}

/// The default workload of the tests and of the demo.
pub const SMALL: Workload = Workload { seed: 4, puts: 36, key_space: 60 };
/// A longer one, used when the feature `long` is enabled.
pub const LONG: Workload = Workload { seed: 2222, puts: 120, key_space: 150 };

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Before,
    After,
    OpenFailed,
    Invalid,
    WrongContents,
}

#[derive(Debug, Clone, Copy)]
pub struct RunResult {
    pub outcome: Outcome,
    /// Puts that returned success before the power failed.
    pub acked: u32,
    /// Page writes the machine accepted before the (first) crash.
    pub writes: u64,
    /// With the log: what the final recovery found.
    pub recovery: Recovery,
    /// Tree statistics at the end of the run phase (meaningful if no crash).
    pub stats: TreeStats,
    /// With the log: its counters at the end of the run phase.
    pub wal_stats: WalStats,
    /// With a second crash: did the power fail during the first recovery?
    pub second_crash_hit: bool,
}

impl RunResult {
    fn new() -> Self {
        Self {
            outcome: Outcome::OpenFailed,
            acked: 0,
            writes: 0,
            recovery: Recovery::default(),
            stats: TreeStats::default(),
            wal_stats: WalStats::default(),
            second_crash_hit: false,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Tally {
    pub runs: u32,
    pub before: u32,
    pub after: u32,
    pub open_failed: u32,
    pub invalid: u32,
    pub wrong_contents: u32,
}

impl Tally {
    pub fn add(&mut self, outcome: Outcome) {
        self.runs += 1;
        match outcome {
            Outcome::Before => self.before += 1,
            Outcome::After => self.after += 1,
            Outcome::OpenFailed => self.open_failed += 1,
            Outcome::Invalid => self.invalid += 1,
            Outcome::WrongContents => self.wrong_contents += 1,
        }
    }

    /// Runs that ended in exactly the before or the after state.
    pub fn exact(&self) -> u32 {
        self.before + self.after
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CrashError {
    /// A call failed although the power was still on: a bug, not a crash.
    Db(DbError),
    /// The recovered database could not take another put.
    RecoveredDbUnusable,
}

impl std::fmt::Display for CrashError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for CrashError {}

impl From<DbError> for CrashError {
    fn from(e: DbError) -> Self {
        CrashError::Db(e)
    }
}

impl From<TreeError> for CrashError {
    fn from(e: TreeError) -> Self {
        CrashError::Db(DbError::Tree(e))
    }
}

fn apply_ops(model: &mut Model, w: &Workload, from: u32, to: u32) {
    for i in from..to {
        let (key, value) = w.op(i);
        model.put(&key, &value);
    }
}

/// One full scan of the tree against the oracle. A read error counts as a
/// difference.
pub fn same_contents(tree: &mut DiskBTree, model: &Model) -> bool {
    let expected = model.range(b"", None);
    let Ok(mut it) = tree.range(b"", None) else { return false };
    let mut count = 0;
    loop {
        match it.next() {
            Ok(Some((key, value))) => {
                if count >= expected.len() || expected[count] != (key, value) {
                    return false;
                }
                count += 1;
            }
            Ok(None) => return count == expected.len(),
            Err(_) => return false,
        }
    }
}

/// Step 4 of a run: validate, then decide which oracle state the tree is in.
fn classify(tree: &mut DiskBTree, w: &Workload, acked: u32) -> Outcome {
    if tree.validate().is_err() {
        return Outcome::Invalid;
    }
    let mut model = Model::new();
    apply_ops(&mut model, w, 0, acked);
    if same_contents(tree, &model) {
        return Outcome::Before;
    }
    if acked < w.puts {
        apply_ops(&mut model, w, acked, acked + 1);
        if same_contents(tree, &model) {
            return Outcome::After;
        }
    }
    Outcome::WrongContents
}

fn open_db(machine: &SharedMachine, options: Options) -> Result<Db, DbError> {
    Db::open(machine::main_storage(machine), machine::log_storage(machine), options)
}

/// One run WITH the log. `n` = page writes before the power fails (None =
/// never: the whole workload runs). `second` = if set, the power fails again
/// after that many writes of the recovery, and recovery runs a second time.
pub fn run_with_log(w: &Workload, n: Option<u64>, second: Option<u64>, mode: CrashMode, options: Options) -> Result<RunResult, CrashError> {
    let machine = Machine::new(w.seed);
    if let Some(limit) = n {
        machine.borrow_mut().power_off_after_writes(limit);
    }
    let powered_off = || machine.borrow().is_powered_off();

    let mut result = RunResult::new();
    match open_db(&machine, options) {
        Ok(mut db) => {
            while result.acked < w.puts {
                let (key, value) = w.op(result.acked);
                if let Err(err) = db.put(&key, &value) {
                    if !powered_off() {
                        return Err(err.into());
                    }
                    break;
                }
                result.acked += 1;
            }
            result.stats = db.tree.stats;
            result.wal_stats = db.wal().stats;
        }
        Err(err) if !powered_off() => return Err(err.into()),
        Err(_) => {}
    }
    result.writes = machine.borrow().writes;
    machine.borrow_mut().crash(mode);

    if let Some(limit) = second {
        // Crash during recovery: recovery must be restartable.
        machine.borrow_mut().power_off_after_writes(limit);
        if let Err(err) = open_db(&machine, options) {
            if !powered_off() {
                return Err(err.into());
            }
        }
        result.second_crash_hit = powered_off();
        machine.borrow_mut().crash(mode);
    }

    let Ok(mut db) = open_db(&machine, options) else { return Ok(result) }; // OpenFailed
    result.recovery = db.recovery;
    result.outcome = classify(&mut db.tree, w, result.acked);
    if matches!(result.outcome, Outcome::Before | Outcome::After) {
        // The recovered database must be a working database.
        let alive = db.put(b"zz after recovery", b"still alive").is_ok() && db.validate().is_ok() && db.get(b"zz after recovery") == Ok(Some(b"still alive".to_vec()));
        if !alive {
            return Err(CrashError::RecoveredDbUnusable);
        }
    }
    Ok(result)
}

/// A chapter 12 tree directly on the machine's main file: no log, no
/// checksums. (Zig needs a struct for this; here the tree owns its parts.)
pub fn open_plain(machine: &SharedMachine) -> Result<DiskBTree, TreeError> {
    let pager = Pager::new(Box::new(PageFile { inner: machine::main_storage(machine) }))?;
    let pool = BufferPool::new(pager, 8);
    if pool.pager().page_count() == 0 { DiskBTree::create(pool) } else { DiskBTree::open(pool) }
}

/// The same run WITHOUT the log: put, then flush (write the dirty pages in
/// place, sync). This is all chapter 12 can do for durability.
pub fn run_without_log(w: &Workload, n: Option<u64>, mode: CrashMode) -> Result<RunResult, CrashError> {
    let machine = Machine::new(w.seed);
    if let Some(limit) = n {
        machine.borrow_mut().power_off_after_writes(limit);
    }
    let powered_off = || machine.borrow().is_powered_off();

    let mut result = RunResult::new();
    match open_plain(&machine) {
        Ok(mut tree) => {
            while result.acked < w.puts {
                let (key, value) = w.op(result.acked);
                if let Err(err) = tree.put(&key, &value).and_then(|()| tree.flush()) {
                    if !powered_off() {
                        return Err(err.into());
                    }
                    break;
                }
                result.acked += 1;
            }
            result.stats = tree.stats;
        }
        Err(err) if !powered_off() => return Err(err.into()),
        Err(_) => {}
    }
    result.writes = machine.borrow().writes;
    machine.borrow_mut().crash(mode);

    let Ok(mut tree) = open_plain(&machine) else { return Ok(result) }; // OpenFailed
    result.outcome = classify(&mut tree, w, result.acked);
    Ok(result)
}

#[derive(Debug, Clone, Copy)]
pub struct Loop {
    /// Page writes of the whole workload when nothing goes wrong.
    pub total_writes: u64,
    /// One tally per crash mode, in the order of `MODES`.
    pub tallies: [Tally; 4],
}

/// THE loop: for every N from 0 to the total number of writes, and for every
/// crash mode, one run. With `with_log` false it is the control experiment.
pub fn crash_loop(w: &Workload, with_log: bool, options: Options) -> Result<Loop, CrashError> {
    let run = |n: Option<u64>, mode: CrashMode| if with_log { run_with_log(w, n, None, mode, options) } else { run_without_log(w, n, mode) };
    let clean = run(None, CrashMode::Drop)?;
    assert!(clean.acked == w.puts && clean.outcome == Outcome::Before);
    let mut result = Loop { total_writes: clean.writes, tallies: [Tally::default(); 4] };
    for n in 0..=clean.writes {
        for (mode, tally) in MODES.iter().zip(&mut result.tallies) {
            tally.add(run(Some(n), *mode)?.outcome);
        }
    }
    Ok(result)
}
