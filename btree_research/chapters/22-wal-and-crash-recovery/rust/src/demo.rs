//! demo.rs: the fixed, deterministic scenario printed by `cargo run`.
//!
//! Part 1  no log: the leaf split of chapter 12 on a disk that loses power.
//!         (Visualization page 1 replays it.)
//! Part 2  the same split through the write-ahead log: the records of the
//!         commit, every storage write, and recovery after a power cut at
//!         each of them. (Visualization page 2 replays it.)
//! Part 3  the crash loop: a seeded workload, a power cut after every write,
//!         four crash modes, with the log and without it.
//! Part 4  what the log costs.

use std::io::Write;

use crate::base_disk_btree::{DiskBTree, TreeError};
use crate::base_workload::Model;
use crate::crash::{self, CrashMode, Loop, Outcome};
use crate::db::{Db, DbError, Options};
use crate::machine::{self, EventKind, FileId, Machine};
use crate::wal::{self, LogScanner, PAGE_SIZE, Recovery};

type DemoResult<T = ()> = Result<T, Box<dyn std::error::Error>>;

/// Chapter 12's scenario: the first eleven keys are stored, the twelfth
/// (key 15) splits a leaf under a parent that already exists.
pub const SCENARIO_KEYS: [u8; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];
pub const OLD_KEYS: usize = SCENARIO_KEYS.len() - 1;

fn scenario_key(n: u8) -> [u8; 2] {
    [b'0' + n / 10, b'0' + n % 10]
}

/// 300 + 24 * n copies of one letter.
fn scenario_value(n: u8) -> Vec<u8> {
    vec![b'a' + n % 26; 300 + 24 * usize::from(n)]
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Before,
    After,
    OpenFailed,
    Invalid,
    WrongContents,
}

/// What one interrupted split left behind.
#[derive(Debug, Clone)]
pub struct SplitOutcome {
    pub state: State,
    /// The name of the error of a failed open or validate.
    pub err: Option<String>,
    pub recovery: Recovery,
    /// Page writes of the split (and checkpoint) when nothing interrupts it.
    pub writes: u64,
}

impl SplitOutcome {
    fn new() -> Self {
        Self {
            state: State::OpenFailed,
            err: None,
            recovery: Recovery::default(),
            writes: 0,
        }
    }
}

/// The bare error name, as Zig's `{t}` prints it.
fn error_name(err: &TreeError) -> String {
    match err {
        TreeError::Io(e) => format!("{e:?}"),
        TreeError::Invalid(v) => format!("{v:?}"),
        other => format!("{other:?}"),
    }
}

/// Is the tree valid, and does it hold exactly the first 11 keys (before) or
/// all 12 (after)?
fn classify(tree: &mut DiskBTree, outcome: &mut SplitOutcome) {
    if let Err(err) = tree.validate() {
        outcome.state = State::Invalid;
        outcome.err = Some(error_name(&err));
        return;
    }
    let mut model = Model::new();
    for &n in &SCENARIO_KEYS[..OLD_KEYS] {
        model.put(&scenario_key(n), &scenario_value(n));
    }
    outcome.state = State::WrongContents;
    if crash::same_contents(tree, &model) {
        outcome.state = State::Before;
    }
    let last = SCENARIO_KEYS[OLD_KEYS];
    model.put(&scenario_key(last), &scenario_value(last));
    if crash::same_contents(tree, &model) {
        outcome.state = State::After;
    }
}

fn print_trace(w: &mut dyn Write, machine: &Machine, new_page: u64) -> DemoResult {
    let mut write_no = 0;
    let mut seen_new_page = false;
    for e in &machine.trace {
        if e.kind == EventKind::Sync {
            writeln!(w, "  sync {}", e.file.name())?;
            continue;
        }
        write_no += 1;
        write!(
            w,
            "  write {write_no}: {} page {}",
            e.file.name(),
            e.page_no
        )?;
        if e.file == FileId::Main && e.page_no == new_page && !seen_new_page {
            seen_new_page = true;
            if machine.trace[0].file == FileId::Main {
                write!(w, "  (zeroes: the file grows by one page)")?;
            }
        }
        writeln!(w)?;
    }
    Ok(())
}

/// Part 1. Eleven keys flushed; then put 15 and flush, with the power
/// failing after `n` writes. `out` (clean run only) receives the narration.
pub fn split_without_log(
    n: Option<u64>,
    mode: CrashMode,
    mut out: Option<&mut dyn Write>,
) -> DemoResult<SplitOutcome> {
    let machine = Machine::new(22);
    let mut outcome = SplitOutcome::new();
    {
        let mut tree = crash::open_plain(&machine)?;
        for &k in &SCENARIO_KEYS[..OLD_KEYS] {
            tree.put(&scenario_key(k), &scenario_value(k))?;
        }
        tree.flush()?;
        if let Some(w) = out.as_mut() {
            writeln!(w, "{OLD_KEYS} keys are on disk, flushed and synced:")?;
            write!(w, "{}", tree.dump()?)?;
        }
        let base = machine.borrow().writes;
        let new_page = u64::from(tree.pool().pager().page_count());
        machine.borrow_mut().tracing = true;
        if let Some(limit) = n {
            machine.borrow_mut().power_off_after_writes(limit);
        }
        let last = SCENARIO_KEYS[OLD_KEYS];
        if let Err(err) = tree
            .put(&scenario_key(last), &scenario_value(last))
            .and_then(|()| tree.flush())
            && !machine.borrow().is_powered_off()
        {
            return Err(err.into());
        }
        outcome.writes = machine.borrow().writes - base;
        if let Some(w) = out.as_mut() {
            let key = scenario_key(last);
            writeln!(
                w,
                "put {} splits leaf page 2; the new right half is page {new_page}. put + flush issue:",
                String::from_utf8_lossy(&key)
            )?;
            print_trace(*w, &machine.borrow(), new_page)?;
            writeln!(w, "the tree after the split:")?;
            write!(w, "{}", tree.dump()?)?;
        }
    }
    machine.borrow_mut().crash(mode);

    match crash::open_plain(&machine) {
        Ok(mut tree) => classify(&mut tree, &mut outcome),
        Err(err) => outcome.err = Some(error_name(&err)),
    }
    Ok(outcome)
}

fn open_db(machine: &machine::SharedMachine, options: Options) -> Result<Db, DbError> {
    Db::open(
        machine::main_storage(machine),
        machine::log_storage(machine),
        options,
    )
}

/// Part 2. Eleven keys committed and checkpointed (the log is empty); then
/// put 15 (a commit) and a checkpoint, with the power failing after `n`
/// writes; then reopen, which runs recovery.
pub fn split_with_log(
    n: Option<u64>,
    mode: CrashMode,
    mut out: Option<&mut dyn Write>,
) -> DemoResult<SplitOutcome> {
    let machine = Machine::new(22);
    let mut outcome = SplitOutcome::new();
    let options = Options {
        checkpoint_every: 0,
        ..Options::default()
    }; // checkpoints by hand here
    let powered_off = || machine.borrow().is_powered_off();
    {
        let mut db = open_db(&machine, options).map_err(crash::CrashError::Db)?;
        for &k in &SCENARIO_KEYS[..OLD_KEYS] {
            db.put(&scenario_key(k), &scenario_value(k))
                .map_err(crash::CrashError::Db)?;
        }
        db.checkpoint().map_err(crash::CrashError::Db)?;
        if let Some(w) = out.as_mut() {
            writeln!(
                w,
                "{OLD_KEYS} keys are in the main file (checkpointed); the log is empty, generation {}",
                db.wal().generation
            )?;
        }
        let base = machine.borrow().writes;
        let new_page = u64::from(db.tree.pool().pager().page_count());
        machine.borrow_mut().tracing = true;
        if let Some(limit) = n {
            machine.borrow_mut().power_off_after_writes(limit);
        }
        let last = SCENARIO_KEYS[OLD_KEYS];
        match db.put(&scenario_key(last), &scenario_value(last)) {
            Ok(()) => {
                if let Some(w) = out.as_mut() {
                    let key = scenario_key(last);
                    writeln!(
                        w,
                        "put {} changes 4 pages in memory; its commit appends to the log:",
                        String::from_utf8_lossy(&key)
                    )?;
                    print_log(*w, &machine)?;
                }
                if let Err(err) = db.checkpoint()
                    && !powered_off()
                {
                    return Err(crash::CrashError::Db(err).into());
                }
            }
            Err(err) if !powered_off() => return Err(crash::CrashError::Db(err).into()),
            Err(_) => {}
        }
        outcome.writes = machine.borrow().writes - base;
        if let Some(w) = out.as_mut() {
            writeln!(
                w,
                "storage calls of the put and of the checkpoint after it:"
            )?;
            print_trace(*w, &machine.borrow(), new_page)?;
        }
    }
    machine.borrow_mut().crash(mode);

    match open_db(&machine, options) {
        Ok(mut db) => {
            outcome.recovery = db.recovery;
            classify(&mut db.tree, &mut outcome);
        }
        Err(err) => outcome.err = Some(format!("{err:?}")),
    }
    Ok(outcome)
}

/// Walk the valid records of the log and print one line each.
fn print_log(w: &mut dyn Write, machine: &machine::SharedMachine) -> DemoResult {
    let mut log = machine::log_storage(machine);
    let mut scanner = LogScanner::new(log.as_mut()).map_err(|e| crash::CrashError::Db(e.into()))?;
    let mut image = [0u8; PAGE_SIZE];
    while let Some(rec) = scanner
        .next(&mut image)
        .map_err(|e| crash::CrashError::Db(e.into()))?
    {
        write!(
            w,
            "  LSN {}  log bytes {}..{}  ",
            rec.lsn, rec.offset, scanner.pos
        )?;
        if rec.kind == wal::KIND_PAGE {
            write!(w, "image of page {}", rec.arg)?;
        } else {
            write!(w, "commit ({} pages)", rec.arg)?;
        }
        writeln!(w, "  crc {:08x}", rec.crc)?;
    }
    Ok(())
}

fn print_outcome(
    w: &mut dyn Write,
    mode: CrashMode,
    o: &SplitOutcome,
    with_log: bool,
) -> DemoResult {
    write!(w, "{}: ", mode.name())?;
    let err = o.err.as_deref().unwrap_or("?");
    match o.state {
        State::Before => write!(w, "before")?,
        State::After => write!(w, "after")?,
        State::OpenFailed => write!(w, "open fails ({err})")?,
        State::Invalid => write!(w, "invalid ({err})")?,
        State::WrongContents => write!(w, "valid tree, wrong contents")?,
    }
    if with_log {
        write!(
            w,
            " [{} records, {} commit]",
            o.recovery.valid_records, o.recovery.committed_ops
        )?;
    }
    Ok(())
}

const SPLIT_MODES: [CrashMode; 3] = [CrashMode::Drop, CrashMode::Keep, CrashMode::Tear];

fn part1(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 1: no log: one leaf split on a disk that loses power =="
    )?;
    let clean = split_without_log(None, CrashMode::Drop, Some(w))?;
    writeln!(
        w,
        "the power fails after N writes; the unsynced writes are then dropped, kept or torn:"
    )?;
    for n in 0..=clean.writes {
        write!(w, "N = {n}: ")?;
        for (i, &mode) in SPLIT_MODES.iter().enumerate() {
            if i > 0 {
                write!(w, " | ")?;
            }
            print_outcome(w, mode, &split_without_log(Some(n), mode, None)?, false)?;
        }
        writeln!(w)?;
    }
    writeln!(
        w,
        "(before = the 11 old keys, valid tree; after = all 12 keys, valid tree)"
    )?;
    Ok(())
}

fn part2(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 2: the same split through the write-ahead log =="
    )?;
    let clean = split_with_log(None, CrashMode::Drop, Some(w))?;
    writeln!(
        w,
        "the power fails after N writes; reopening runs recovery [what it found in the log]:"
    )?;
    for n in 0..=clean.writes {
        write!(w, "N = {n}: ")?;
        for (i, &mode) in SPLIT_MODES.iter().enumerate() {
            if i > 0 {
                write!(w, " | ")?;
            }
            print_outcome(w, mode, &split_with_log(Some(n), mode, None)?, true)?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn print_loop(w: &mut dyn Write, result: &Loop) -> DemoResult<u32> {
    writeln!(
        w,
        "  mode    runs  before  after  open fails  invalid  wrong contents"
    )?;
    let mut exact = 0;
    for (mode, t) in crash::MODES.iter().zip(&result.tallies) {
        writeln!(
            w,
            "  {:<6} {:>5} {:>7} {:>6} {:>11} {:>8} {:>15}",
            mode.name(),
            t.runs,
            t.before,
            t.after,
            t.open_failed,
            t.invalid,
            t.wrong_contents
        )?;
        exact += t.exact();
    }
    Ok(exact)
}

fn part3(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 3: a power cut after every write, four crash modes =="
    )?;
    let wl = crash::SMALL;
    let options = Options {
        frames: 3,
        ..Options::default()
    };
    let clean = crash::run_with_log(&wl, None, None, CrashMode::Drop, options)?;
    writeln!(
        w,
        "workload: {} puts (seed {}), keys of 240 to 256 bytes, values of 700 to 1023 bytes",
        wl.puts, wl.seed
    )?;
    writeln!(
        w,
        "no crash: splits: {} leaf, {} interior, {} root (the tree grows to 3 levels)",
        clean.stats.leaf_splits, clean.stats.interior_splits, clean.stats.root_splits
    )?;

    let with_log = crash::crash_loop(&wl, true, options)?;
    writeln!(
        w,
        "WITH the log (3-frame pool, checkpoint every 4 commits): {} page writes, power cut after N = 0..{}",
        with_log.total_writes, with_log.total_writes
    )?;
    let exact_with = print_loop(w, &with_log)?;
    let without = crash::crash_loop(&wl, false, options)?;
    writeln!(
        w,
        "WITHOUT the log (chapter 12: put, then flush): {} page writes, power cut after N = 0..{}",
        without.total_writes, without.total_writes
    )?;
    let exact_without = print_loop(w, &without)?;
    let runs_with = (with_log.total_writes + 1) * crash::MODES.len() as u64;
    let runs_without = (without.total_writes + 1) * crash::MODES.len() as u64;
    writeln!(
        w,
        "exactly the before or the after state: with the log {exact_with} of {runs_with} runs, without {exact_without} of {runs_without}"
    )?;

    // A second power cut, during recovery itself.
    let mut runs = 0;
    let mut exact = 0;
    for n in (0..=with_log.total_writes).step_by(5) {
        for mode in [CrashMode::Keep, CrashMode::Random] {
            for m in 0.. {
                let r = crash::run_with_log(&wl, Some(n), Some(m), mode, options)?;
                if !r.second_crash_hit {
                    break; // recovery finished before write m
                }
                runs += 1;
                if matches!(r.outcome, Outcome::Before | Outcome::After) {
                    exact += 1;
                }
            }
        }
    }
    writeln!(
        w,
        "a second power cut during recovery (every 5th N, after each recovery write, keep and random): {exact} of {runs} runs exact"
    )?;
    Ok(())
}

fn part4(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 4: what the log costs (the same 36 puts, no crash) =="
    )?;
    let wl = crash::SMALL;
    let payload: usize = (0..wl.puts)
        .map(|i| wl.op(i))
        .map(|(key, value)| key.len() + value.len())
        .sum();
    writeln!(w, "the puts carry {payload} bytes of keys and values")?;
    writeln!(
        w,
        "  checkpoint  log bytes  largest  page     log page  main page  syncs"
    )?;
    writeln!(
        w,
        "  every       appended   log      records  writes    writes"
    )?;
    for every in [1, 4, 16, 0] {
        let options = Options {
            checkpoint_every: every,
            ..Options::default()
        };
        let s = crash::run_with_log(&wl, None, None, CrashMode::Drop, options)?.wal_stats;
        let label = if every == 0 {
            "never".to_string()
        } else {
            every.to_string()
        };
        writeln!(
            w,
            "  {:<10} {:>10} {:>8} {:>8} {:>9} {:>10} {:>6}",
            label,
            s.log_bytes,
            s.max_log_bytes,
            s.page_records,
            s.log_page_writes,
            s.main_page_writes,
            s.log_syncs + s.main_syncs
        )?;
        if every == 4 {
            writeln!(
                w,
                "  (largest commit: {} page images; {} commits)",
                s.largest_commit, s.commits
            )?;
        }
    }
    let plain = crash::run_without_log(&wl, None, CrashMode::Drop)?;
    writeln!(
        w,
        "without the log: {} page writes in place, no second copy, and Part 3's failures",
        plain.writes
    )?;
    Ok(())
}

pub fn run(w: &mut dyn Write) -> DemoResult {
    writeln!(w, "Chapter 22: write-ahead log and crash recovery")?;
    part1(w)?;
    part2(w)?;
    part3(w)?;
    part4(w)?;
    Ok(())
}
