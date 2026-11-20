//! tests.rs: what a resumable operation has to prove.
//!
//!   1. It computes the same thing as the blocking code: byte-identical files.
//!   2. Every place where it can stop has been made to stop there.
//!   3. Calling it again before its page arrived changes nothing at all.
//!   4. It never reads, and it holds no pin while it waits.
//!   5. When it dies in the middle (read error, write error) it leaves no
//!      pin and no memory behind.
//!   6. Its memory has the right lifetime: owned data survives every yield,
//!      and a buffer that does not is shown to break the tree.
//!
//! Difference from Zig: there `std.testing.allocator` fails a test that
//! leaks, and a `FailingAllocator` makes the operation's arena run out of
//! memory at every possible allocation. Safe Rust can do neither with a
//! `Vec`; ownership makes the leak impossible to write, and the "cannot get
//! what it needs in the middle of a split" case is covered by the failed
//! page allocation (a write fault), as in chapter 12.

use crate::base_buffer_pool::{Frame, PoolStats};
use crate::base_pager::PagerStats;
use crate::base_storage::Error as IoError;
use crate::demo::{self, Rig, SCENARIO_KEYS};
use crate::disk_btree::{self as btree, PageId, Stats, TreeError, Violation};
use crate::prng::SplitMix64;
use crate::resumable::{GetOp, InsertOp, Options, SUSPEND_POINTS, Scratch, State, StateKind, Step};
use crate::scheduler::{Scheduler, Status};
use crate::workload::{self, Model};

type TestResult = Result<(), TreeError>;

/// A workload whose keys are long enough that 700 puts build three levels,
/// so that every state of the insert is reached.
#[derive(Clone, Copy)]
struct Shape {
    key_space: u64,
    max_key: usize,
    max_value: usize,
    puts: usize,
}

const SHAPE: Shape = Shape {
    key_space: 2000,
    max_key: 200,
    max_value: 500,
    puts: 700,
};

fn next_put(rng: &mut SplitMix64, shape: Shape) -> (Vec<u8>, Vec<u8>) {
    let key = workload::key_for(rng.below(shape.key_space), shape.max_key);
    let value = workload::random_value(rng, shape.max_value);
    (key, value)
}

/// The reference: the same puts through chapter 12's blocking `put`.
fn blocking_file(shape: Shape, seed: u64) -> Result<Vec<u8>, TreeError> {
    let mut rig = Rig::create(8)?;
    let mut rng = SplitMix64::new(seed);
    for _ in 0..shape.puts {
        let (key, value) = next_put(&mut rng, shape);
        rig.tree.put(&key, &value)?;
    }
    // The shape must really exercise interior and root splits.
    assert!(rig.tree.stats.interior_splits >= 1 && rig.tree.stats.root_splits >= 2);
    rig.tree.flush()?;
    Ok(rig.mem.bytes())
}

#[test]
fn the_resumable_insert_writes_the_same_file_byte_for_byte_as_the_blocking_put() -> TestResult {
    let shape = SHAPE;
    let expected = blocking_file(shape, 1)?;

    // (frames, disk seed, batch size, pressure)
    let cases = [
        (2, 1u64, 1, false),
        (3, 2, 5, false),
        (16, 3, 40, false),
        (2, 4, 7, true),
        (5, 5, 3, true),
    ];
    for (frames, disk_seed, batch, pressure) in cases {
        let mut rig = Rig::create(frames)?;
        let mut model = Model::new();
        let mut rng = SplitMix64::new(1);
        let mut probe = SplitMix64::new(disk_seed);

        let mut done = 0;
        while done < shape.puts {
            // One batch: puts interleaved with gets, all submitted before any
            // of them runs. `expect` is what a blocking program running them
            // one by one would have answered.
            let mut s = Scheduler::new(&mut rig.tree, disk_seed.wrapping_add(done as u64));
            s.insert_options.pressure = pressure;
            let mut tickets: Vec<(usize, Option<Vec<u8>>)> = Vec::new();
            let n = batch.min(shape.puts - done);
            for _ in 0..n {
                let (key, value) = next_put(&mut rng, shape);
                s.submit_insert(&key, &value)?;
                model.put(&key, &value);
                for _ in 0..2 {
                    let wanted = workload::key_for(probe.below(shape.key_space), shape.max_key);
                    tickets.push((
                        s.submit_get(&wanted)?,
                        model.get(&wanted).map(<[u8]>::to_vec),
                    ));
                }
            }
            s.run();
            assert!(s.slots.iter().all(|slot| slot.status == Status::Done));
            for (ticket, expect) in &tickets {
                assert_eq!(s.result(*ticket), expect.as_deref());
            }
            done += n;
        }
        rig.tree.validate()?;
        assert_eq!(rig.tree.key_count(), model.len() as u64);
        rig.tree.flush()?;
        assert!(
            rig.mem.bytes() == expected,
            "frames {frames}, pressure {pressure}"
        );
    }
    Ok(())
}

#[test]
fn every_suspension_point_is_exercised() -> TestResult {
    let shape = SHAPE;
    for pressure in [false, true] {
        let mut rig = Rig::create(4)?;
        let mut s = Scheduler::new(&mut rig.tree, 9);
        s.insert_options.pressure = pressure;
        let mut rng = SplitMix64::new(1);
        for _ in 0..shape.puts {
            let (key, value) = next_put(&mut rng, shape);
            s.submit_insert(&key, &value)?;
        }
        s.run();
        let suspended = s.suspended;
        rig.tree.validate()?;
        if pressure {
            // With the pool emptied between transitions, every state had to
            // wait for its page at least once.
            assert!(suspended.iter().all(|&n| n > 0), "{suspended:?}");
        } else {
            // Left alone, a single writer only ever waits in two states: on
            // the way down, and when it comes back to a parent that the split
            // pushed out of the pool. The other five find the page that the
            // state before them just used. They are still suspension points
            // (another operation, or a smaller pool, can take the page away),
            // which is why the run above forces them.
            for (kind, n) in StateKind::SUSPENDABLE.iter().zip(suspended) {
                let expected_to_wait =
                    matches!(kind, StateKind::Descend | StateKind::InsertSeparator);
                assert_eq!(expected_to_wait, n > 0, "{kind:?}");
            }
        }
    }
    Ok(())
}

/// Everything that a call of `step` could possibly change, as far as the
/// public API shows it. (Zig also hashes the raw frames; here the frames'
/// bookkeeping is compared. No write reached the file if the pager's
/// counters stand still, and the file bytes themselves are compared too.)
#[derive(Debug, PartialEq)]
struct Snapshot {
    state: StateKind,
    path_len: usize,
    changed: bool,
    suspended: [u32; SUSPEND_POINTS],
    key_count: u64,
    tree_stats: Stats,
    pool_stats: PoolStats,
    pager_stats: PagerStats,
    hand: usize,
    frames: Vec<Frame>,
    file: Vec<u8>,
}

impl Snapshot {
    fn take(rig: &Rig, op: &InsertOp) -> Self {
        let pool = rig.tree.pool();
        Snapshot {
            state: op.kind(),
            path_len: op.path_len(),
            changed: op.has_changed_a_page(),
            suspended: op.suspended,
            key_count: rig.tree.key_count(),
            tree_stats: rig.tree.stats,
            pool_stats: pool.stats,
            pager_stats: pool.pager().stats,
            hand: pool.hand(),
            frames: pool.frames().to_vec(),
            file: rig.mem.bytes(),
        }
    }
}

#[test]
fn an_operation_re_entered_before_its_page_arrived_makes_no_progress_and_changes_nothing()
-> TestResult {
    let shape = SHAPE;
    let mut rig = Rig::create(3)?;
    let mut rng = SplitMix64::new(1);
    let mut reentered = [0u32; SUSPEND_POINTS];
    let options = Options {
        pressure: true,
        ..Options::default()
    };

    for _ in 0..shape.puts {
        let (key, value) = next_put(&mut rng, shape);
        let mut op = InsertOp::new(&rig.tree, &key, &value, options)?;
        loop {
            let first = op.step(&mut rig.tree)?;
            let Step::Io(page) = first else { break };
            let before = Snapshot::take(&rig, &op);
            // The caller is impatient: it calls again, and again, although
            // the disk has delivered nothing.
            for _ in 0..3 {
                assert_eq!(op.step(&mut rig.tree)?, first);
                assert!(Snapshot::take(&rig, &op) == before);
            }
            reentered[op.kind() as usize] += 1;
            rig.supply(page)?;
        }
    }
    assert!(reentered.iter().all(|&n| n > 0)); // in every one of the seven states
    rig.tree.validate()
}

#[test]
fn step_reads_nothing_and_keeps_no_pin_all_reading_is_done_by_the_disk() -> TestResult {
    let mut rig = Rig::create(2)?;
    for n in SCENARIO_KEYS {
        rig.put_scenario(n)?;
    }
    rig.tree.pool_mut().evict_unpinned()?;

    let mut op = InsertOp::new(&rig.tree, b"16", &[b'x'; 900], Options::default())?;
    let (mut in_step, mut by_disk, mut yields) = (0, 0, 0);
    loop {
        let before = rig.reads();
        let s = op.step(&mut rig.tree)?;
        in_step += rig.reads() - before;
        assert_eq!(rig.tree.pool().pinned_frames(), 0);
        let Step::Io(page) = s else { break };
        yields += 1;
        let mid = rig.reads();
        rig.supply(page)?;
        by_disk += rig.reads() - mid;
    }
    assert_eq!(in_step, 0);
    assert_eq!(yields, 3); // root, leaf, and the root again after the split
    assert_eq!(by_disk, 3);
    rig.tree.validate()
}

/// Step `op` until it has split the leaf and waits for the parent.
fn run_to_half_split(rig: &mut Rig, op: &mut InsertOp) -> Result<Step, TreeError> {
    let mut last = op.step(&mut rig.tree)?;
    while op.kind() != StateKind::InsertSeparator {
        let Step::Io(page) = last else {
            panic!("the insert was expected to split")
        };
        rig.supply(page)?;
        last = op.step(&mut rig.tree)?;
    }
    Ok(last)
}

fn run_to_end(rig: &mut Rig, op: &mut InsertOp, mut last: Step) -> Result<u32, TreeError> {
    let mut yields = 0;
    while let Step::Io(page) = last {
        yields += 1;
        rig.supply(page)?;
        last = op.step(&mut rig.tree)?;
    }
    Ok(yields)
}

#[test]
fn a_reader_let_in_while_a_split_is_half_done_misses_a_key_why_the_writer_runs_alone() -> TestResult
{
    let mut rig = Rig::create(2)?;
    for n in SCENARIO_KEYS {
        rig.put_scenario(n)?;
    }
    let mut op = InsertOp::new(&rig.tree, b"16", &[b'q'; 1000], Options::default())?;
    let last = run_to_half_split(&mut rig, &mut op)?;
    assert!(matches!(last, Step::Io(_)) && op.has_changed_a_page());

    // The tree in memory is half-split: validate sees it (the leaf chain
    // already contains a page that no parent leads to), and a lookup of a
    // key that moved to that page comes back empty.
    assert_eq!(
        rig.tree.validate(),
        Err(TreeError::Invalid(Violation::LeafChainBroken))
    );
    assert_eq!(rig.tree.get(b"18")?, None);

    run_to_end(&mut rig, &mut op, last)?;
    rig.tree.validate()?;
    assert_eq!(rig.tree.get(b"18")?.map(|v| v.len()), Some(732));
    Ok(())
}

#[test]
fn the_scheduler_runs_operations_in_submission_order_a_get_sees_exactly_the_puts_before_it()
-> TestResult {
    let mut rig = Rig::create(3)?;
    let mut s = Scheduler::new(&mut rig.tree, 77);
    let before = s.submit_get(b"k")?;
    s.submit_insert(b"k", b"one")?;
    let between = s.submit_get(b"k")?;
    s.submit_insert(b"k", b"two")?;
    let after = s.submit_get(b"k")?;
    s.run();
    assert_eq!(s.result(before), None);
    assert_eq!(s.result(between), Some(&b"one"[..]));
    assert_eq!(s.result(after), Some(&b"two"[..]));
    drop(s);
    assert_eq!(rig.tree.key_count(), 1);
    Ok(())
}

// ---- failures in the middle of an operation ------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
enum Fault {
    Read,
    Write,
}

/// Build the 24-key scenario tree, then run twelve inserts that split leaves
/// while fault number `n` of the given kind strikes. Returns whether a fault
/// was actually hit.
fn run_with_fault(fault: Fault, n: u64, poisoned_runs: &mut u32) -> Result<bool, TreeError> {
    let mut rig = Rig::create(2)?;
    for k in SCENARIO_KEYS {
        rig.put_scenario(k)?;
    }
    rig.tree.flush()?;
    match fault {
        Fault::Read => rig.mem.set_reads_before_failure(Some(n)),
        Fault::Write => rig.mem.set_writes_before_failure(Some(n)),
    }

    let new_keys: [&[u8]; 12] = [
        b"13", b"16", b"19", b"21", b"24", b"26", b"0a", b"0b", b"1a", b"1b", b"2a", b"2b",
    ];
    let mut s = Scheduler::new(&mut rig.tree, n);
    for key in new_keys {
        s.submit_insert(key, &[b'v'; 700])?;
    }
    s.run();
    let statuses: Vec<Status> = s.slots.iter().map(|slot| slot.status).collect();
    for slot in &s.slots {
        if let Some(err) = slot.err {
            assert!(matches!(
                err,
                TreeError::Io(IoError::StorageFailure) | TreeError::TreePoisoned
            ));
        }
    }
    drop(s);

    // The fault is over; look at what it left behind.
    rig.mem.set_reads_before_failure(None);
    rig.mem.set_writes_before_failure(None);
    assert_eq!(rig.tree.pool().pinned_frames(), 0);
    rig.tree.pool().validate().expect("pool invariants");

    let failures = statuses.iter().filter(|&&s| s == Status::Failed).count();
    if rig.tree.is_poisoned() {
        // The failed insert had already changed a page: the handle refuses
        // further work, exactly like chapter 12's blocking put.
        *poisoned_runs += 1;
        assert_eq!(rig.tree.flush(), Err(TreeError::TreePoisoned));
        return Ok(true);
    }
    rig.tree.validate()?;
    for (key, status) in new_keys.iter().zip(&statuses) {
        let applied = *status == Status::Done;
        assert_eq!(applied, rig.tree.get(key)?.is_some()); // all of it, or none of it
    }
    Ok(failures > 0)
}

#[test]
fn a_read_failure_or_a_write_failure_mid_operation_leaves_no_pinned_page() -> TestResult {
    for fault in [Fault::Read, Fault::Write] {
        let (mut hit, mut poisoned_runs, mut n) = (0u32, 0u32, 0u64);
        while run_with_fault(fault, n, &mut poisoned_runs)? {
            hit += 1;
            n += 1;
        }
        assert!(hit >= 10, "{fault:?}"); // the sweep really went through the operations
        // Both outcomes must have occurred: an insert that never started
        // changing pages, and one caught half-way.
        assert!(poisoned_runs > 0 && poisoned_runs < hit, "{fault:?}");
    }
    Ok(())
}

#[test]
fn a_failed_page_allocation_in_the_middle_of_a_cascading_split_no_pin_and_the_handle_is_poisoned()
-> TestResult {
    let shape = SHAPE;
    // Pilot run: which put is the first to split an interior page?
    let mut target = 0;
    {
        let mut rig = Rig::create(8)?;
        let mut rng = SplitMix64::new(1);
        while rig.tree.stats.interior_splits == 0 {
            let (key, value) = next_put(&mut rng, shape);
            rig.tree.put(&key, &value)?;
            target += 1;
        }
        target -= 1;
    }

    let options = Options {
        pressure: true,
        ..Options::default()
    };
    let (mut before_change, mut after_change) = (0, 0);
    for writes_allowed in 0.. {
        let mut rig = Rig::create(8)?;
        let mut rng = SplitMix64::new(1);
        for _ in 0..target {
            let (key, value) = next_put(&mut rng, shape);
            rig.tree.put(&key, &value)?;
        }
        let (key, value) = next_put(&mut rng, shape);
        let mut op = InsertOp::new(&rig.tree, &key, &value, options)?;
        rig.mem.set_writes_before_failure(Some(writes_allowed));
        let outcome = loop {
            match op.step(&mut rig.tree) {
                Err(e) => break Err(e),
                Ok(Step::Done) => break Ok(()),
                Ok(Step::Io(page)) => rig.supply(page)?,
            }
        };
        rig.mem.set_writes_before_failure(None);
        match outcome {
            Ok(()) => {
                assert_eq!(rig.tree.stats.interior_splits, 1);
                rig.tree.validate()?;
                break; // the sweep has passed the operation's last write
            }
            Err(err) => {
                assert_eq!(err, TreeError::Io(IoError::StorageFailure));
                assert_eq!(op.kind(), StateKind::Failed);
                assert_eq!(rig.tree.pool().pinned_frames(), 0);
                assert_eq!(op.held_bytes(), 0);
                if rig.tree.is_poisoned() {
                    after_change += 1;
                } else {
                    before_change += 1;
                    rig.tree.validate()?; // untouched
                }
            }
        }
    }
    assert!(before_change > 0 && after_change > 0);
    Ok(())
}

#[test]
fn cancelling_a_waiting_insert_nothing_pinned_nothing_changed_memory_returned() -> TestResult {
    let mut rig = Rig::create(2)?;
    for n in SCENARIO_KEYS {
        rig.put_scenario(n)?;
    }
    rig.tree.flush()?;
    rig.tree.pool_mut().evict_unpinned()?;
    let file_before = rig.mem.bytes();

    let mut op = InsertOp::new(&rig.tree, b"16", b"abandoned", Options::default())?;
    assert_eq!(op.step(&mut rig.tree)?, Step::Io(1));
    assert!(op.held_bytes() > 0);
    op.cancel(&mut rig.tree);
    assert_eq!(op.kind(), StateKind::Failed);
    assert_eq!(op.held_bytes(), 0);
    assert_eq!(rig.tree.pool().pinned_frames(), 0);
    assert!(!rig.tree.is_poisoned());
    rig.tree.flush()?;
    assert!(rig.mem.bytes() == file_before);
    Ok(())
}

// ---- the lifetime of the operation's memory -------------------------------------

#[test]
fn the_operations_data_survives_every_resumption_and_is_freed_when_it_completes() -> TestResult {
    let mut rig = Rig::create(2)?;
    for n in SCENARIO_KEYS {
        rig.put_scenario(n)?;
    }
    rig.tree.pool_mut().evict_unpinned()?;

    // The caller's buffers die right after `new`: the operation has copies.
    let mut op = {
        let key_buf = *b"16";
        let value_buf = [b'q'; 1000];
        InsertOp::new(&rig.tree, &key_buf, &value_buf, Options::default())?
    };
    let key_address = op.key().as_ptr();

    let mut yields = 0;
    let mut s = op.step(&mut rig.tree)?;
    while let Step::Io(page) = s {
        yields += 1;
        // Across the suspension: same memory, same content.
        assert_eq!(op.key().as_ptr(), key_address);
        assert_eq!(op.key(), b"16");
        assert!(op.held_bytes() >= 1000);
        if let State::InsertSeparator { carry } = op.state() {
            // The separator computed by the split, two calls ago in program
            // terms, is still readable: the state owns it.
            assert_eq!(carry.sep, b"17");
        }
        rig.supply(page)?;
        s = op.step(&mut rig.tree)?;
    }
    assert_eq!(yields, 3);
    assert_eq!(op.held_bytes(), 0);
    rig.tree.validate()
}

#[test]
fn scratch_memory_that_is_reused_at_every_yield_breaks_the_tree_but_only_when_the_insert_yields()
-> TestResult {
    // The right lifetime: fine however often the operation yields.
    assert_eq!(demo::ascending_until_broken(2, Scratch::OpOwned, 30)?, None);
    // The wrong lifetime with a pool so large that no split ever waits: the
    // bug is there and does nothing. This is what makes it dangerous.
    assert_eq!(
        demo::ascending_until_broken(64, Scratch::StepBuffer, 30)?,
        None
    );
    // The wrong lifetime and a yield between the split and the parent: the
    // separator has been overwritten, the parent gets garbage for a key.
    assert_eq!(
        demo::ascending_until_broken(2, Scratch::StepBuffer, 30)?,
        Some((10, Violation::KeyOutOfBounds))
    );
    Ok(())
}

#[test]
fn new_rejects_what_put_rejects() -> TestResult {
    let mut rig = Rig::create(2)?;
    let long_key = [b'k'; btree::MAX_KEY_LEN + 1];
    let long_value = [b'v'; btree::MAX_VALUE_LEN + 1];
    let o = Options::default();
    assert_eq!(
        InsertOp::new(&rig.tree, &long_key, b"", o).err(),
        Some(TreeError::KeyTooLarge)
    );
    assert_eq!(
        InsertOp::new(&rig.tree, b"k", &long_value, o).err(),
        Some(TreeError::ValueTooLarge)
    );
    rig.tree.poisoned = true;
    assert_eq!(
        InsertOp::new(&rig.tree, b"k", b"v", o).err(),
        Some(TreeError::TreePoisoned)
    );
    assert_eq!(
        GetOp::new(&rig.tree, b"k").err(),
        Some(TreeError::TreePoisoned)
    );
    let _: PageId = rig.tree.root();
    Ok(())
}

#[test]
fn run_output_matches_expected_output_txt() {
    let mut out = Vec::new();
    demo::run(&mut out).expect("demo runs");
    assert_eq!(
        String::from_utf8(out).expect("utf-8"),
        include_str!("../../expected_output.txt")
    );
}
