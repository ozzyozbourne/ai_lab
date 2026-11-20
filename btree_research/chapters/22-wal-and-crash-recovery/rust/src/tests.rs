//! tests.rs: the log, recovery, and the crash loop.

use std::cell::Cell;
use std::rc::Rc;

use crate::base_disk_btree::{MAX_KEY_LEN, MAX_VALUE_LEN, TreeError};
use crate::base_page_storage::{PAGE_SIZE, Page, SECTOR_SIZE, Storage, StorageError};
use crate::base_storage::Error as IoError;
use crate::crash::{self, CrashMode, Cut, Fates, Loop, Outcome, Tally};
use crate::crc32::{crc32, crc32_update};
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
fn the_two_files_fare_differently_in_the_power_cut_still_the_before_or_the_after_state() {
    // Nothing ties the fate of the log's unsynced writes to that of the main
    // file's. The first pair is the write-ahead rule seen from outside: the
    // main file keeps every write and the log loses every unsynced one, so
    // a page that reached the main file before its log record was durable
    // would stay there with nothing to explain it.
    let wl = crash::SMALL;
    let fates = |main, log| Fates { main, log };
    let always = [
        fates(CrashMode::Keep, CrashMode::Drop),
        fates(CrashMode::Drop, CrashMode::Keep),
    ];
    // Two more pairs with torn pages, taking turns to keep the test short.
    let in_turn = [
        fates(CrashMode::Tear, CrashMode::Random),
        fates(CrashMode::Random, CrashMode::Tear),
    ];
    let options = Options::default();
    let clean = crash::run_with_log(&wl, None, None, CrashMode::Drop, options).unwrap();
    let mut tally = Tally::default();
    for n in 0..=clean.writes {
        for f in [always[0], always[1], in_turn[(n % 2) as usize]] {
            let r = crash::run_cut(&wl, Cut::AfterWrite(n), None, f, options).unwrap();
            tally.add(r.outcome);
        }
    }
    assert_eq!(u64::from(tally.runs), 3 * (clean.writes + 1));
    assert_eq!(tally.exact(), tally.runs);
    assert!(tally.before > 0 && tally.after > 0);
}

#[test]
fn a_sync_that_completes_but_reports_the_power_cut_the_put_failed_and_is_stored() {
    // "After write N" never stops the machine between a sync and its
    // return. Here it stops exactly there, at every sync of the workload.
    let wl = crash::SMALL;
    let options = Options {
        frames: 2,
        checkpoint_every: 3,
        ..Options::default()
    };
    let clean = crash::run_with_log(&wl, None, None, CrashMode::Drop, options).unwrap();
    assert!(clean.syncs > u64::from(wl.puts)); // commits, and the two syncs of each checkpoint
    for mode in crash::MODES {
        let mut tally = Tally::default();
        for k in 1..=clean.syncs {
            let fates = Fates {
                main: mode,
                log: mode,
            };
            let r = crash::run_cut(&wl, Cut::AtSync(k), None, fates, options).unwrap();
            assert_eq!(r.syncs, k);
            tally.add(r.outcome);
        }
        assert_eq!(tally.exact(), tally.runs);
        // Syncs 1 and 2 belong to `open` (the first log header, the commit
        // that creates the tree). Every later one is part of a put: the log
        // sync of its commit, or a sync of the checkpoint behind it. The
        // commit record is durable in all of them, so the put that returned
        // an error is in the database: "outcome unknown" is not "not stored".
        assert_eq!(tally.before, 2);
        assert_eq!(u64::from(tally.after), clean.syncs - 2);
    }
}

#[test]
fn a_second_power_cut_during_recovery_in_the_modes_the_demo_leaves_out() {
    // The demo prints this loop for `keep` and `random`. `tear` is the mode
    // in which recovery finds a main-file page that its own first attempt
    // tore, and must simply write it again.
    let wl = crash::SMALL;
    let options = Options {
        frames: 3,
        ..Options::default()
    };
    let clean = crash::run_with_log(&wl, None, None, CrashMode::Drop, options).unwrap();
    let mut runs = 0;
    for n in (2..=clean.writes).step_by(11) {
        for mode in [CrashMode::Drop, CrashMode::Tear] {
            for m in 0.. {
                let r = crash::run_with_log(&wl, Some(n), Some(m), mode, options).unwrap();
                if !r.second_crash_hit {
                    break; // recovery finished before write m
                }
                assert!(matches!(r.outcome, Outcome::Before | Outcome::After));
                runs += 1;
            }
        }
    }
    assert!(runs > 50);
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

#[test]
fn a_batch_with_a_pair_the_tree_would_refuse_is_refused_whole_and_the_handle_stays_usable() {
    let machine = Machine::new(1);
    {
        let mut db = open_db(&machine, Options::default());
        db.put(b"a", b"1").unwrap();
        // The bad pair is the second of three. Nothing of the batch may be
        // applied, not even to the pages in memory.
        let long_key = [b'k'; MAX_KEY_LEN + 1];
        let long_value = [b'v'; MAX_VALUE_LEN + 1];
        assert_eq!(
            db.put_batch(&[(b"b1", b"x"), (&long_key, b"y"), (b"b3", b"z")]),
            Err(DbError::Tree(TreeError::KeyTooLarge))
        );
        assert_eq!(
            db.put_batch(&[(b"b1", b"x"), (b"b2", &long_value)]),
            Err(DbError::Tree(TreeError::ValueTooLarge))
        );
        assert_eq!(
            db.put(&long_key, b"y"),
            Err(DbError::Tree(TreeError::KeyTooLarge))
        );
        expect_value(&mut db, b"b1", None);
        // Nothing was touched, so this is not a failed handle...
        assert!(!db.is_failed());
        db.put(b"c", b"3").unwrap();
    }
    machine.borrow_mut().crash(CrashMode::Drop);
    let mut db = open_db(&machine, Options::default());
    // ... and the put that followed did not commit half of the batch.
    expect_value(&mut db, b"b1", None);
    expect_value(&mut db, b"b3", None);
    expect_value(&mut db, b"c", Some(b"3"));
}

#[test]
fn a_batch_that_fails_after_its_first_put_the_handle_refuses_everything_until_it_is_reopened() {
    const STORAGE_FAILURE: DbError = DbError::Tree(TreeError::Io(IoError::StorageFailure));
    let machine = Machine::new(1);
    {
        // Five keys of 1000 bytes: an interior root (page 1) and two leaves
        // (pages 2 and 3), all of them checkpointed into the main file.
        let mut db = open_db(&machine, Options::default());
        for key in b"abcde" {
            db.put(&[*key], &[b'1'; 1000]).unwrap();
        }
        db.checkpoint().unwrap();
        assert_eq!(machine.borrow().main.size(), 4);
    }
    {
        // Damage the right leaf in the main file. Its checksum will not verify.
        let mut main = machine::main_storage(&machine);
        let mut page = [0u8; PAGE_SIZE];
        main.read_page(3, &mut page).unwrap();
        page[2000] ^= 1;
        main.write_page(3, &page).unwrap();
        main.sync().unwrap();
    }
    {
        let mut db = open_db(&machine, Options::default());
        expect_value(&mut db, b"a", Some(&[b'1'; 1000])); // the left leaf is fine
        assert_eq!(db.get(b"e"), Err(STORAGE_FAILURE));
        assert!(!db.is_failed()); // a failed read changes nothing

        // "a2" goes into the left leaf; "e2" needs the damaged one.
        assert_eq!(
            db.put_batch(&[(b"a2", b"x"), (b"e2", b"y")]),
            Err(STORAGE_FAILURE)
        );
        // "a2" now sits in a dirty page of the buffer pool. Without the
        // `failed` flag the next put would log that page and commit half of
        // the batch, and a `get` would already show it.
        assert!(db.is_failed());
        assert_eq!(db.put(b"b2", b"z"), Err(DbError::ReopenRequired));
        assert_eq!(db.put_batch(&[(b"b2", b"z")]), Err(DbError::ReopenRequired));
        assert_eq!(db.get(b"a2"), Err(DbError::ReopenRequired));
        assert_eq!(db.range(b"", None).err(), Some(DbError::ReopenRequired));
        assert_eq!(db.validate(), Err(DbError::ReopenRequired));
        assert_eq!(db.checkpoint(), Err(DbError::ReopenRequired));
    }
    machine.borrow_mut().crash(CrashMode::Keep);
    let mut db = open_db(&machine, Options::default());
    assert_eq!(db.recovery.valid_records, 0); // the failed batch never reached the log
    expect_value(&mut db, b"a2", None);
    expect_value(&mut db, b"b2", None);
    expect_value(&mut db, b"a", Some(&[b'1'; 1000]));
}

#[test]
fn a_checkpoint_that_fails_the_handle_refuses_everything_until_it_is_reopened() {
    let machine = Machine::new(1);
    {
        let options = Options {
            checkpoint_every: 0,
            ..Options::default()
        };
        let mut db = open_db(&machine, options);
        db.put(b"a", b"1").unwrap();
        // The explicit checkpoint has two main-file pages to write (the
        // metapage and the root leaf). The power fails after the first.
        machine.borrow_mut().power_off_after_writes(1);
        assert_eq!(
            db.checkpoint(),
            Err(DbError::Wal(WalError::Storage(StorageError::PowerLoss)))
        );
        assert!(db.is_failed());
        // "a" is still in the buffer pool and would be served from memory.
        assert_eq!(db.get(b"a"), Err(DbError::ReopenRequired));
        assert_eq!(db.put(b"b", b"2"), Err(DbError::ReopenRequired));
        assert_eq!(db.checkpoint(), Err(DbError::ReopenRequired));
    }
    machine.borrow_mut().crash(CrashMode::Tear);
    let mut db = open_db(&machine, Options::default());
    db.validate().unwrap();
    expect_value(&mut db, b"a", Some(b"1")); // committed before the checkpoint began
    expect_value(&mut db, b"b", None);
}

/// A storage in front of another one whose next `sync` fails with an I/O
/// error while the power stays on: the writes before it are readable but not
/// durable. `SimDisk` has no such fault (its only failure is the power cut).
struct SyncFails {
    inner: Box<dyn Storage>,
    armed: Rc<Cell<bool>>,
}

impl Storage for SyncFails {
    fn read_page(&mut self, page_no: u64, out: &mut Page) -> Result<(), StorageError> {
        self.inner.read_page(page_no, out)
    }

    fn write_page(&mut self, page_no: u64, page: &Page) -> Result<(), StorageError> {
        self.inner.write_page(page_no, page)
    }

    fn sync(&mut self) -> Result<(), StorageError> {
        if self.armed.replace(false) {
            return Err(StorageError::InputOutput);
        }
        self.inner.sync()
    }

    fn size(&self) -> u64 {
        self.inner.size()
    }
}

#[test]
fn a_log_sync_that_fails_with_the_power_on_a_reopen_then_a_power_cut_inside_that_recovery() {
    // The commit's records are all in the log file, readable, but its sync
    // returned an error: they are not durable. The reopen that the handle
    // demands finds a complete commit. If recovery copied it to the main
    // file at once, a power cut that keeps those main-file writes and drops
    // the log's would leave pages of an operation the log knows nothing of.
    // So `recover` syncs the log before its first main-file write.
    let options = Options {
        checkpoint_every: 0,
        ..Options::default()
    };
    let mut cut = 0;
    loop {
        let machine = Machine::new(1);
        {
            let mut db = open_db(&machine, options);
            for key in b"abcd" {
                db.put(&[*key], &[b'1'; 1000]).unwrap();
            }
            db.checkpoint().unwrap();
        }
        {
            let armed = Rc::new(Cell::new(false));
            let flaky = Box::new(SyncFails {
                inner: machine::log_storage(&machine),
                armed: Rc::clone(&armed),
            });
            let mut db = Db::open(machine::main_storage(&machine), flaky, options).unwrap();
            armed.set(true);
            // "e" splits the root leaf: 4 page images and a commit record.
            assert_eq!(
                db.put(b"e", &[b'5'; 1000]),
                Err(DbError::Tree(TreeError::Io(IoError::StorageFailure)))
            );
            assert_eq!(
                db.wal().last_error,
                Some(WalError::Storage(StorageError::InputOutput))
            );
            assert!(!armed.get()); // it was the commit's sync that failed
            assert_eq!(db.put(b"f", b"x"), Err(DbError::ReopenRequired));
        }
        // "After an error, reopen." The power fails after `cut` writes of
        // that recovery; the main file keeps them, the log loses its own.
        machine.borrow_mut().power_off_after_writes(cut);
        match Db::open(
            machine::main_storage(&machine),
            machine::log_storage(&machine),
            options,
        ) {
            Ok(_) => break, // recovery needed fewer than `cut` writes
            Err(e) => assert_eq!(e, DbError::Wal(WalError::Storage(StorageError::PowerLoss))),
        }
        machine
            .borrow_mut()
            .crash_each(CrashMode::Keep, CrashMode::Drop);

        let mut db = open_db(&machine, options);
        db.validate().unwrap();
        for key in b"abcd" {
            expect_value(&mut db, &[*key], Some(&[b'1'; 1000]));
        }
        // Before the first write nothing was synced and the put is gone.
        // From the first main-file write on, the log had been synced first.
        let e: Option<&[u8]> = if cut == 0 { None } else { Some(&[b'5'; 1000]) };
        expect_value(&mut db, b"e", e);
        cut += 1;
    }
    assert_eq!(cut, 6); // 4 main-file pages, the new log header, and a run without a cut
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

// ---- forged logs -------------------------------------------------------------------

/// Copy `len` bytes of the log file, starting at byte `offset`.
fn read_log(machine: &SharedMachine, offset: u64, len: usize) -> Vec<u8> {
    let mut log = machine::log_storage(machine);
    let mut page = [0u8; PAGE_SIZE];
    let mut out = Vec::with_capacity(len);
    while out.len() < len {
        let at = offset + out.len() as u64;
        let in_page = (at % PAGE_SIZE as u64) as usize;
        log.read_page(at / PAGE_SIZE as u64, &mut page).unwrap();
        let n = (len - out.len()).min(PAGE_SIZE - in_page);
        out.extend_from_slice(&page[in_page..in_page + n]);
    }
    out
}

/// Overwrite bytes of the log file, starting at byte `offset`, and sync.
/// Everything else in the file stays as it is.
fn write_log(machine: &SharedMachine, offset: u64, bytes: &[u8]) {
    let mut log = machine::log_storage(machine);
    let mut done = 0;
    while done < bytes.len() {
        let at = offset + done as u64;
        let in_page = (at % PAGE_SIZE as u64) as usize;
        let mut page = [0u8; PAGE_SIZE];
        if at / (PAGE_SIZE as u64) < log.size() {
            log.read_page(at / PAGE_SIZE as u64, &mut page).unwrap();
        }
        let n = (bytes.len() - done).min(PAGE_SIZE - in_page);
        page[in_page..in_page + n].copy_from_slice(&bytes[done..done + n]);
        log.write_page(at / PAGE_SIZE as u64, &page).unwrap();
        done += n;
    }
    log.sync().unwrap();
}

/// Writes a log by hand, from the format table at the top of wal.rs and
/// from nothing else: it calls no function of wal.rs. So these tests also
/// pin the format, and they can write logs the real writer never would.
#[derive(Default)]
struct Forge {
    bytes: Vec<u8>,
    chain: u32,
}

impl Forge {
    /// Start over with a header page.
    fn header(&mut self, generation: u64, first_lsn: u64) {
        let mut page = [0u8; PAGE_SIZE];
        page[0..8].copy_from_slice(b"WAL22\0\0\0");
        page[8..12].copy_from_slice(&1u32.to_le_bytes());
        page[12..16].copy_from_slice(&4096u32.to_le_bytes());
        page[16..24].copy_from_slice(&generation.to_le_bytes());
        page[24..32].copy_from_slice(&first_lsn.to_le_bytes());
        self.chain = crc32(&page[0..32]);
        page[32..36].copy_from_slice(&self.chain.to_le_bytes());
        self.bytes.clear();
        self.bytes.extend_from_slice(&page);
    }

    /// Append one record, chained from the one before it.
    fn record(&mut self, lsn: u64, kind: u32, arg: u32, payload: &[u8]) {
        let mut head = [0u8; 24];
        head[0..8].copy_from_slice(&lsn.to_le_bytes());
        head[8..12].copy_from_slice(&kind.to_le_bytes());
        head[12..16].copy_from_slice(&arg.to_le_bytes());
        head[16..20].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        let prev = crc32(&self.chain.to_le_bytes());
        self.chain = crc32_update(crc32_update(prev, &head[0..20]), payload);
        head[20..24].copy_from_slice(&self.chain.to_le_bytes());
        self.bytes.extend_from_slice(&head);
        self.bytes.extend_from_slice(payload);
    }

    /// One operation: page 0 and page 1, then the commit record.
    fn operation(&mut self, first_lsn: u64, images: &[Vec<u8>; 2]) {
        self.record(first_lsn, 1, 0, &images[0]);
        self.record(first_lsn + 1, 1, 1, &images[1]);
        self.record(first_lsn + 2, 2, 2, &[]);
    }

    /// Put the forged bytes at the front of the machine's log file.
    fn install(&self, machine: &SharedMachine) {
        write_log(machine, 0, &self.bytes);
    }
}

const IMAGE_RECORD_LEN: usize = wal::RECORD_HEADER_LEN + PAGE_SIZE;
/// Bytes of one operation of 2 page images.
const OPERATION_LEN: usize = COMMIT_LEN as usize;

/// A machine whose main file holds "a" and whose log holds two committed
/// operations, put "b" and put "c": the raw material of the forgeries.
struct Forgery {
    machine: SharedMachine,
    generation: u64,
    /// LSN of the first record in the log.
    lsn: u64,
    /// Pages 0 and 1 (metapage and root leaf) as put "b" and put "c" logged them.
    b: [Vec<u8>; 2],
    c: [Vec<u8>; 2],
    /// The log file as the real writer left it: the header and 6 records.
    original: Vec<u8>,
}

impl Forgery {
    fn new() -> Self {
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
            db.checkpoint().unwrap();
            db.put(b"b", b"2").unwrap();
            db.put(b"c", b"3").unwrap();
        }
        let original = read_log(&machine, 0, PAGE_SIZE + 2 * OPERATION_LEN);
        let generation = u64::from_le_bytes(original[16..24].try_into().unwrap());
        let lsn = u64::from_le_bytes(original[24..32].try_into().unwrap());
        // Generation 1 held the creation and "a": records 1 to 6.
        assert_eq!((generation, lsn), (2, 7));
        let records = &original[PAGE_SIZE..];
        let image = |record_at: usize| {
            records[record_at + wal::RECORD_HEADER_LEN..record_at + IMAGE_RECORD_LEN].to_vec()
        };
        Self {
            generation,
            lsn,
            b: [image(0), image(IMAGE_RECORD_LEN)],
            c: [
                image(OPERATION_LEN),
                image(OPERATION_LEN + IMAGE_RECORD_LEN),
            ],
            original,
            machine,
        }
    }

    /// Open the database and compare what recovery found and which of the
    /// keys "b" and "c" exist afterwards. "a" must always be there.
    fn expect_recovery(&self, valid_records: u32, committed_ops: u32, has_b: bool, has_c: bool) {
        let mut db = open_db(&self.machine, Options::default());
        assert_eq!(db.recovery.valid_records, valid_records);
        assert_eq!(db.recovery.committed_ops, committed_ops);
        db.validate().unwrap();
        expect_value(&mut db, b"a", Some(b"1"));
        expect_value(&mut db, b"b", has_b.then_some(b"2"));
        expect_value(&mut db, b"c", has_c.then_some(b"3"));
    }

    fn open_error(&self) -> Option<DbError> {
        Db::open(
            machine::main_storage(&self.machine),
            machine::log_storage(&self.machine),
            Options::default(),
        )
        .err()
    }
}

#[test]
fn forged_log_written_by_hand_from_the_format_table_it_equals_the_real_log_byte_for_byte() {
    let fx = Forgery::new();
    let mut forge = Forge::default();
    forge.header(fx.generation, fx.lsn);
    forge.operation(fx.lsn, &fx.b);
    forge.operation(fx.lsn + 3, &fx.c);
    assert!(forge.bytes == fx.original);
    forge.install(&fx.machine);
    fx.expect_recovery(6, 2, true, true);
}

#[test]
fn forged_log_a_record_with_the_wrong_lsn_ends_the_scan_although_its_checksum_chains() {
    {
        // A gap: the second operation carries LSNs 11 to 13 instead of 10 to 12.
        let fx = Forgery::new();
        let mut forge = Forge::default();
        forge.header(fx.generation, fx.lsn);
        forge.operation(fx.lsn, &fx.b);
        forge.operation(fx.lsn + 4, &fx.c);
        forge.install(&fx.machine);
        fx.expect_recovery(3, 1, true, false);
    }
    {
        // The very first record is one too low for what the header announces.
        let fx = Forgery::new();
        let mut forge = Forge::default();
        forge.header(fx.generation, fx.lsn);
        forge.operation(fx.lsn - 1, &fx.b);
        forge.install(&fx.machine);
        fx.expect_recovery(0, 0, false, false);
    }
}

#[test]
fn forged_log_stale_records_with_exactly_the_expected_lsns_are_rejected_they_chain_from_another_header()
 {
    let fx = Forgery::new();
    let mut forge = Forge::default();
    // An older generation that happens to use the LSNs the new one will use.
    // (The real writer never reuses an LSN; the chain must not depend on it.)
    forge.header(fx.generation - 1, fx.lsn);
    forge.operation(fx.lsn, &fx.b);
    forge.operation(fx.lsn + 3, &fx.c);
    forge.install(&fx.machine);
    // The new generation overwrites the header and the first operation with
    // the same LSNs and the same page images. Behind them lies the old "c":
    // right position, right LSNs, a checksum that is good for the old chain.
    forge.header(fx.generation, fx.lsn);
    forge.operation(fx.lsn, &fx.b);
    forge.install(&fx.machine);
    fx.expect_recovery(3, 1, true, false);
}

#[test]
fn a_commit_record_with_a_damaged_checksum_commits_nothing() {
    let fx = Forgery::new();
    // One bit in the CRC field (bytes 20..24) of the commit record of "c".
    let at = PAGE_SIZE + 2 * OPERATION_LEN - 4;
    write_log(&fx.machine, at as u64, &[fx.original[at] ^ 0x01]);
    {
        let db = open_db(&fx.machine, Options::default());
        assert_eq!(db.recovery.uncommitted_records, 2); // the two images of "c"
    }
    // (That open has already recovered: the log is empty now.)
    fx.expect_recovery(0, 0, true, false);
}

#[test]
fn a_commit_record_that_counts_the_wrong_number_of_page_records_log_corrupt() {
    // No power cut produces this: the checksum is right, so the writer wrote
    // it. Recovery refuses to guess which pages belong to the operation.
    for count in [1, 3] {
        let fx = Forgery::new();
        let mut forge = Forge::default();
        forge.header(fx.generation, fx.lsn);
        forge.record(fx.lsn, 1, 0, &fx.b[0]);
        forge.record(fx.lsn + 1, 1, 1, &fx.b[1]);
        forge.record(fx.lsn + 2, 2, count, &[]);
        forge.install(&fx.machine);
        let writes = fx.machine.borrow().writes;
        assert_eq!(fx.open_error(), Some(DbError::Wal(WalError::LogCorrupt)));
        assert_eq!(fx.machine.borrow().writes, writes); // nothing was replayed, nothing reset
    }
}

#[test]
fn a_damaged_log_header_is_log_corrupt_not_an_empty_log_bytes_behind_sector_0_do_not_matter() {
    {
        let fx = Forgery::new();
        // One bit of the generation. Treating this as "no log" would open the
        // database without "b" and "c", both acknowledged.
        write_log(&fx.machine, 16, &[fx.original[16] ^ 0x01]);
        assert_eq!(fx.open_error(), Some(DbError::Wal(WalError::LogCorrupt)));
    }
    {
        let fx = Forgery::new();
        // The header page is rewritten in place at every reset. Only its
        // first sector carries anything; a tear further back is harmless.
        write_log(
            &fx.machine,
            SECTOR_SIZE as u64,
            &[0xAB; PAGE_SIZE - SECTOR_SIZE],
        );
        fx.expect_recovery(6, 2, true, true);
    }
}

#[test]
fn recovery_leaves_an_empty_log_of_the_next_generation_and_lsns_go_on_behind_every_valid_record() {
    let machine = Machine::new(1);
    three_commits(&machine); // generation 1, LSNs 1 to 12
    // Zero the commit record of "c" (LSN 12): records 10 and 11 stay valid.
    let zeros = [0u8; wal::RECORD_HEADER_LEN];
    write_log(
        &machine,
        wal::LOG_START + 4 * COMMIT_LEN - zeros.len() as u64,
        &zeros,
    );
    let scan_lsns = || {
        let mut log = machine::log_storage(&machine);
        let mut scanner = LogScanner::new(log.as_mut()).unwrap();
        let mut image = [0u8; PAGE_SIZE];
        let mut lsns = Vec::new();
        while let Some(rec) = scanner.next(&mut image).unwrap() {
            lsns.push(rec.lsn);
        }
        lsns
    };
    {
        let mut db = open_db(
            &machine,
            Options {
                checkpoint_every: 0,
                ..Options::default()
            },
        );
        assert_eq!(db.recovery.generation, 1);
        assert_eq!(db.recovery.valid_records, 11);
        // What is on disk now, not what the handle believes:
        let header = read_log(&machine, 0, 36);
        assert_eq!(header[16..24], 2u64.to_le_bytes()); // generation
        assert_eq!(header[24..32], 12u64.to_le_bytes()); // first LSN
        assert_eq!(scan_lsns(), []); // the old records no longer chain
        db.put(b"d", b"4").unwrap();
    }
    // LSNs 10 and 11 were handed out to records that never committed. They
    // are not handed out again: the new records start at 12.
    assert_eq!(scan_lsns(), [12, 13, 14]);

    let mut db = open_db(&machine, Options::default());
    assert_eq!(db.recovery.generation, 2);
    assert_eq!(db.recovery.committed_ops, 1);
    expect_value(&mut db, b"b", Some(b"2"));
    expect_value(&mut db, b"c", None);
    expect_value(&mut db, b"d", Some(b"4"));
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
        // The pages of the split stay in memory, and nothing can take them
        // back: this handle is finished, also for a put that would fit.
        assert_eq!(db.put(b"a", b"small"), Err(DbError::ReopenRequired));
        assert_eq!(db.checkpoint(), Err(DbError::ReopenRequired));
    }
    machine.borrow_mut().crash(CrashMode::Keep);
    let mut db = open_db(&machine, Options::default());
    db.validate().unwrap();
    expect_value(&mut db, b"d", Some(&[b'4'; 1000]));
    expect_value(&mut db, b"e", None); // nothing of the failed operation reached a file
}

/// A storage that refuses ONE write, the `fail_index`-th of both files
/// together, with `OutOfMemory`: what `std.testing.FailingAllocator` does to
/// the allocation behind a write in Zig.
struct OneRefusal {
    inner: Box<dyn Storage>,
    /// (writes seen so far, the one to refuse)
    budget: Rc<Cell<(u64, u64)>>,
}

impl Storage for OneRefusal {
    fn read_page(&mut self, page_no: u64, out: &mut Page) -> Result<(), StorageError> {
        self.inner.read_page(page_no, out)
    }

    fn write_page(&mut self, page_no: u64, page: &Page) -> Result<(), StorageError> {
        let (seen, fail_index) = self.budget.get();
        self.budget.set((seen + 1, fail_index));
        if seen == fail_index {
            return Err(StorageError::OutOfMemory);
        }
        self.inner.write_page(page_no, page)
    }

    fn sync(&mut self) -> Result<(), StorageError> {
        self.inner.sync()
    }

    fn size(&self) -> u64 {
        self.inner.size()
    }
}

#[test]
fn a_write_refused_for_lack_of_memory_at_any_point_leaves_a_recoverable_database() {
    // Zig's twin fails the allocator: "allocation failure at any point leaves
    // a recoverable database and leaks nothing". std has no failing
    // allocator, and a failed allocation aborts the process. The mirror is a
    // budget that returns `Err`: write number `fail_index` is refused, for
    // every `fail_index`. So a commit fails in the middle of its log append,
    // a checkpoint in the middle of its main-file writes, a reset at its
    // header write.
    let key_of = |k: u8| [b'0' + k / 10, b'0' + k % 10];
    let options = Options {
        frames: 3,
        checkpoint_every: 2,
        ..Options::default()
    };
    let mut fail_index = 0;
    loop {
        let machine = Machine::new(1);
        let budget = Rc::new(Cell::new((0, fail_index)));
        let refusing = |inner| -> Box<dyn Storage> {
            Box::new(OneRefusal {
                inner,
                budget: Rc::clone(&budget),
            })
        };
        let mut acked = 0;
        let mut failed = false;
        match Db::open(
            refusing(machine::main_storage(&machine)),
            refusing(machine::log_storage(&machine)),
            options,
        ) {
            // The first header write, or the commit that creates the tree.
            Err(_) => failed = true,
            Ok(mut db) => {
                for k in demo::SCENARIO_KEYS {
                    if db.put(&key_of(k), &[b'v'; 700]).is_err() {
                        // Memory is back at once (one refusal only), but the
                        // handle does not carry on with what the failure left.
                        assert_eq!(
                            db.put(&key_of(k), &[b'v'; 700]),
                            Err(DbError::ReopenRequired)
                        );
                        failed = true;
                        break;
                    }
                    acked += 1;
                }
            }
        }
        assert_eq!(failed, budget.get().0 > fail_index);
        // Whatever happened, a healthy process can open the files.
        machine.borrow_mut().crash(CrashMode::Keep);
        let mut db = open_db(&machine, Options::default());
        db.validate().unwrap();
        let count = db.tree.key_count();
        assert!(count == acked || count == acked + 1);
        for k in &demo::SCENARIO_KEYS[..acked as usize] {
            expect_value(&mut db, &key_of(*k), Some(&[b'v'; 700]));
        }
        if !failed {
            break;
        }
        fail_index += 1;
    }
    assert!(fail_index > 20); // many distinct failure points were exercised
}

// Zig's "allocation failure at every scratch request of a put that splits"
// has no Rust twin: it refuses single requests of the tree's scratch arena,
// and safe Rust cannot fail a `Vec` allocation (chapter 12 says the same).
// Zig's PageTable test has none either: here the table is std's BTreeMap.
