//! tests.rs: the log, recovery, and the crash loop.

use crate::base_disk_btree::TreeError;
use crate::base_page_storage::{PAGE_SIZE, Storage as _};
use crate::base_storage::Error as IoError;
use crate::crash::{self, CrashMode, Loop};
use crate::db::{Db, DbError, Options};
use crate::demo;
use crate::machine::{self, EventKind, FileId, Machine, SharedMachine};
use crate::wal::{self, LogScanner, WalError};

fn open_db(machine: &SharedMachine, options: Options) -> Db {
    Db::open(
        machine::main_storage(machine),
        machine::log_storage(machine),
        options,
    )
    .expect("open")
}

fn expect_value(db: &mut Db, key: &[u8], expected: Option<&[u8]>) {
    assert_eq!(db.get(key).expect("get").as_deref(), expected);
}

#[test]
fn run_output_matches_expected_output_txt() {
    // This is also the test of the "second power cut during recovery" loop
    // and of the cost table: their numbers are part of the expected output.
    let mut out = Vec::new();
    demo::run(&mut out).unwrap();
    assert_eq!(
        String::from_utf8(out).unwrap(),
        include_str!("../../expected_output.txt")
    );
}

// ---- THE central test ---------------------------------------------------------

fn expect_all_exact(result: &Loop) {
    for t in &result.tallies {
        assert_eq!(u64::from(t.runs), result.total_writes + 1);
        assert_eq!(t.exact(), t.runs); // never invalid, never a mix, never a lost key
        assert!(t.before > 0 && t.after > 0);
    }
}

#[test]
fn crash_after_every_write_in_every_crash_mode_recovery_gives_the_before_or_the_after_state() {
    let wl = crash::SMALL;
    // The workload must be worth the trouble: leaf, interior and root splits.
    let clean = crash::run_with_log(&wl, None, None, CrashMode::Drop, Options::default()).unwrap();
    assert_eq!(clean.acked, wl.puts);
    assert!(
        clean.stats.leaf_splits >= 10
            && clean.stats.interior_splits >= 1
            && clean.stats.root_splits >= 2
    );

    // A 2-frame pool: dirty pages are evicted in the middle of every split.
    // (The demo runs the same loop with 3 frames and a checkpoint every 4.)
    let options = Options {
        frames: 2,
        checkpoint_every: 3,
        ..Options::default()
    };
    expect_all_exact(&crash::crash_loop(&wl, true, options).unwrap());
}

#[test]
fn the_same_loop_without_the_log_fails_the_control_experiment() {
    let result = crash::crash_loop(&crash::SMALL, false, Options::default()).unwrap();
    let [drop, keep, tear, random] = result.tallies;
    // If every unsynced write vanishes the file is always the last flushed
    // one. That is luck with this crash mode, not a property of the tree.
    assert_eq!(drop.before, drop.runs);
    // Any other fate of the unsynced writes breaks the tree most of the time.
    for t in [keep, tear, random] {
        assert!(t.invalid > t.runs / 2);
    }
    // Worst of all: a tree that validates but lost acknowledged keys.
    assert!(random.wrong_contents > 0);
}

#[test]
#[cfg_attr(not(feature = "long"), ignore = "only with --features long")]
fn long_crash_loop() {
    let options = Options {
        frames: 4,
        checkpoint_every: 7,
        ..Options::default()
    };
    expect_all_exact(&crash::crash_loop(&crash::LONG, true, options).unwrap());
}

#[test]
fn a_batch_commits_all_of_its_puts_or_none_at_every_crash_point() {
    let values: Vec<Vec<u8>> = b"xyzuvw".iter().map(|&c| vec![c; 900]).collect();
    let keys: [&[u8]; 6] = [b"b1", b"b2", b"b3", b"b4", b"b5", b"b6"];
    let pairs: Vec<(&[u8], &[u8])> = keys
        .iter()
        .zip(&values)
        .map(|(k, v)| (*k, v.as_slice()))
        .collect();
    let (mut none, mut all) = (0, 0);
    let mut n = 0;
    loop {
        let machine = Machine::new(n);
        {
            let mut db = open_db(&machine, Options::default());
            db.put(b"a0", b"already here").unwrap();
            machine.borrow_mut().power_off_after_writes(n);
            let _ = db.put_batch(&pairs);
        }
        let finished = !machine.borrow().is_powered_off();
        machine.borrow_mut().crash(CrashMode::Random);
        let mut db = open_db(&machine, Options::default());
        db.validate().unwrap();
        expect_value(&mut db, b"a0", Some(b"already here"));
        let mut present = 0;
        for (key, value) in &pairs {
            if let Some(got) = db.get(key).unwrap() {
                assert_eq!(&got, value);
                present += 1;
            }
        }
        assert!(present == 0 || present == pairs.len());
        if present == 0 {
            none += 1;
        } else {
            all += 1;
        }
        if finished {
            break;
        }
        n += 1;
    }
    assert!(none > 0 && all > 0);
    assert!(n >= 6); // the batch split leaves: several log pages
}

// ---- the write-ahead rule ------------------------------------------------------

#[test]
fn write_ahead_rule_no_main_file_write_while_the_log_has_unsynced_records() {
    let machine = Machine::new(1);
    machine.borrow_mut().tracing = true;
    let mut db = open_db(
        &machine,
        Options {
            frames: 2,
            checkpoint_every: 3,
            ..Options::default()
        },
    );
    for i in 0..crash::SMALL.puts {
        let (key, value) = crash::SMALL.op(i);
        db.put(&key, &value).unwrap();
    }
    let mut log_unsynced = false;
    let mut main_writes = 0;
    for e in &machine.borrow().trace {
        match e.file {
            FileId::Log => log_unsynced = e.kind == EventKind::Write,
            FileId::Main if e.kind == EventKind::Write => {
                assert!(!log_unsynced);
                main_writes += 1;
            }
            FileId::Main => {}
        }
    }
    assert!(main_writes > 0);
    assert_eq!(db.wal().stats.main_page_writes, main_writes);
}

#[test]
fn eviction_goes_through_the_log_a_2_frame_pool_never_touches_the_main_file_before_a_checkpoint() {
    let machine = Machine::new(1);
    {
        let mut db = open_db(
            &machine,
            Options {
                frames: 2,
                checkpoint_every: 0,
                ..Options::default()
            },
        );
        for i in 0..crash::SMALL.puts {
            let (key, value) = crash::SMALL.op(i);
            db.put(&key, &value).unwrap();
        }
        assert!(db.tree.pool().stats.writebacks > 0); // dirty pages were evicted mid-operation
        assert_eq!(db.wal().stats.main_page_writes, 0);
        assert_eq!(machine.borrow().main.size(), 0); // the main file does not even exist yet
        db.validate().unwrap(); // every read is served from the log's images
    }
    machine.borrow_mut().crash(CrashMode::Drop);
    let mut db = open_db(&machine, Options::default());
    assert_eq!(db.recovery.committed_ops, crash::SMALL.puts + 1); // + the creation
    assert!(machine.borrow().main.size() > 0);
    db.validate().unwrap();
}

// ---- the checksum chain ----------------------------------------------------------

/// Bytes of one commit of 2 page images.
const COMMIT_LEN: u64 = (2 * (wal::RECORD_HEADER_LEN + PAGE_SIZE) + wal::RECORD_HEADER_LEN) as u64;

/// Three one-key commits after the creation: 4 commits of 2 page images each.
fn three_commits(machine: &SharedMachine) {
    let mut db = open_db(
        machine,
        Options {
            checkpoint_every: 0,
            ..Options::default()
        },
    );
    db.put(b"a", b"1").unwrap();
    db.put(b"b", b"2").unwrap();
    db.put(b"c", b"3").unwrap();
    assert_eq!(db.wal().stats.commits, 4);
    assert_eq!(db.wal().stats.page_records, 8);
}

/// Read the log page holding byte `offset`, let `change` edit it, write it
/// back and sync.
fn damage_log(
    machine: &SharedMachine,
    offset: u64,
    change: impl FnOnce(&mut [u8; PAGE_SIZE], usize),
) {
    let mut log = machine::log_storage(machine);
    let mut page = [0u8; PAGE_SIZE];
    log.read_page(offset / PAGE_SIZE as u64, &mut page).unwrap();
    change(&mut page, (offset % PAGE_SIZE as u64) as usize);
    log.write_page(offset / PAGE_SIZE as u64, &page).unwrap();
    log.sync().unwrap();
}

#[test]
fn recovery_stops_at_the_first_record_whose_checksum_chain_breaks() {
    let machine = Machine::new(1);
    three_commits(&machine);
    // Flip one bit inside the first record of the commit of "b": record 7,
    // which starts 2 commits into the records.
    damage_log(
        &machine,
        wal::LOG_START + 2 * COMMIT_LEN + 100,
        |page, at| page[at] ^= 0x10,
    );

    let mut db = open_db(&machine, Options::default());
    assert_eq!(db.recovery.valid_records, 6);
    assert_eq!(db.recovery.committed_ops, 2); // creation and "a"
    db.validate().unwrap();
    expect_value(&mut db, b"a", Some(b"1"));
    expect_value(&mut db, b"b", None);
    // "c" is lost too, although its own bytes are intact: a record is only
    // as good as the chain in front of it.
    expect_value(&mut db, b"c", None);
}

#[test]
fn a_trailing_operation_without_a_commit_record_is_ignored() {
    let machine = Machine::new(1);
    three_commits(&machine);
    // Zero the last 24 bytes of the log: the commit record of "c".
    damage_log(
        &machine,
        wal::LOG_START + 4 * COMMIT_LEN - 24,
        |page, at| page[at..at + 24].fill(0),
    );

    let mut db = open_db(&machine, Options::default());
    assert_eq!(db.recovery.valid_records, 11);
    assert_eq!(db.recovery.committed_ops, 3);
    assert_eq!(db.recovery.uncommitted_records, 2);
    expect_value(&mut db, b"b", Some(b"2"));
    expect_value(&mut db, b"c", None);
}

#[test]
fn records_of_an_earlier_generation_are_stale_they_do_not_chain_from_the_new_header() {
    let machine = Machine::new(1);
    {
        let mut db = open_db(
            &machine,
            Options {
                checkpoint_every: 0,
                ..Options::default()
            },
        );
        db.put(b"a", b"1").unwrap();
        db.put(b"b", b"2").unwrap();
        db.checkpoint().unwrap(); // new generation; the 9 old records stay in the file
        db.put(b"c", b"3").unwrap(); // overwrites the first three of them
        assert_eq!(db.wal().generation, 2);
    }
    assert!(machine.borrow().log.size() > 4); // the old records are physically still there
    {
        let mut log = machine::log_storage(&machine);
        let mut scanner = LogScanner::new(log.as_mut()).unwrap();
        let mut image = [0u8; PAGE_SIZE];
        let mut lsns = Vec::new();
        while let Some(rec) = scanner.next(&mut image).unwrap() {
            lsns.push(rec.lsn);
        }
        // Two page images and a commit: only "c". LSNs continue across
        // generations: 1..9 were used before the checkpoint.
        assert_eq!(lsns, [10, 11, 12]);
    }
    let mut db = open_db(&machine, Options::default());
    assert_eq!(db.recovery.committed_ops, 1);
    expect_value(&mut db, b"a", Some(b"1"));
    expect_value(&mut db, b"c", Some(b"3"));
}

#[test]
fn a_damaged_page_in_the_main_file_is_detected_by_its_checksum() {
    let machine = Machine::new(1);
    {
        let mut db = open_db(&machine, Options::default());
        db.put(b"a", b"1").unwrap();
        db.checkpoint().unwrap();
    }
    {
        let mut main = machine::main_storage(&machine);
        let mut page = [0u8; PAGE_SIZE];
        main.read_page(1, &mut page).unwrap();
        page[2000] ^= 1;
        main.write_page(1, &page).unwrap();
        main.sync().unwrap();
    }
    let mut db = open_db(&machine, Options::default()); // the metapage is fine
    assert_eq!(
        db.get(b"a"),
        Err(DbError::Tree(TreeError::Io(IoError::StorageFailure)))
    );
    assert_eq!(db.wal().stats.checksum_failures, 1);
}

// ---- memory ------------------------------------------------------------------------

#[test]
fn the_record_buffer_is_a_hard_limit_commit_too_large() {
    let machine = Machine::new(1);
    {
        // Room for 2 page images per commit: enough for a put into the root
        // leaf (leaf + metapage), not for a split (4 pages).
        let mut db = open_db(
            &machine,
            Options {
                max_commit_pages: 2,
                ..Options::default()
            },
        );
        for (key, fill) in [(b"a", b'1'), (b"b", b'2'), (b"c", b'3'), (b"d", b'4')] {
            db.put(key, &[fill; 1000]).unwrap();
        }
        // The root splits.
        assert_eq!(
            db.put(b"e", &[b'5'; 1000]),
            Err(DbError::Tree(TreeError::Io(IoError::StorageFailure)))
        );
        assert_eq!(db.wal().last_error, Some(WalError::CommitTooLarge));
    }
    machine.borrow_mut().crash(CrashMode::Keep);
    let mut db = open_db(&machine, Options::default());
    db.validate().unwrap();
    expect_value(&mut db, b"d", Some(&[b'4'; 1000]));
    expect_value(&mut db, b"e", None); // nothing of the failed operation reached a file
}

// Zig's "allocation failure at any point leaves a recoverable database and
// leaks nothing" has no Rust twin: std offers no failing allocator, and a
// failed allocation aborts the process instead of returning an error.
// Zig's PageTable test has none either: here the table is std's BTreeMap.
