//! demo.rs: the fixed scenario printed by `cargo run`.
//!
//! Every number below is a count made by this program. Part 1 and Part 3 use
//! the small scenario of chapter 12 (two-digit keys with large values, so
//! that a handful of keys fills a page); Part 2 uses its seeded workload.

use std::error::Error as StdError;
use std::io::Write;

use crate::base_buffer_pool::BufferPool;
use crate::base_pager::Pager;
use crate::base_storage::MemStorage;
use crate::disk_btree::{DiskBTree, PageId, TreeError, Violation};
use crate::prng::SplitMix64;
use crate::resumable::{Advance, InsertOp, Options, Scratch, State, StateKind, Step};
use crate::scheduler::{EventKind, Op, Scheduler};
use crate::workload;

type DemoResult = Result<(), Box<dyn StdError>>;

/// Chapter 12's scenario keys, in insertion order.
pub const SCENARIO_KEYS: [u8; 24] = [
    10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15, 8, 22, 28, 14, 2, 27, 18, 9, 23, 11, 29, 4,
];

/// Key `n` as two decimal digits, so that byte order is numeric order.
pub fn scenario_key(n: u8) -> [u8; 2] {
    [b'0' + n / 10, b'0' + n % 10]
}

/// The value of key `n`: 300 + 24 * n copies of one letter.
pub fn scenario_value(n: u8) -> Vec<u8> {
    vec![b'a' + n % 26; 300 + 24 * n as usize]
}

/// A tree on a memory "disk", plus a second handle to the same bytes.
pub struct Rig {
    pub mem: MemStorage,
    pub tree: DiskBTree,
}

impl Rig {
    pub fn create(frames: usize) -> Result<Self, TreeError> {
        let mem = MemStorage::new();
        let pool = BufferPool::new(Pager::new(Box::new(mem.clone()))?, frames);
        Ok(Self {
            mem,
            tree: DiskBTree::create(pool)?,
        })
    }

    pub fn put_scenario(&mut self, n: u8) -> Result<(), TreeError> {
        self.tree.put(&scenario_key(n), &scenario_value(n))
    }

    /// Complete a read the way the simulated disk does.
    pub fn supply(&mut self, id: PageId) -> Result<(), TreeError> {
        let pool = self.tree.pool_mut();
        pool.fetch_page(id)?;
        pool.unpin(id, false);
        Ok(())
    }

    pub fn reads(&self) -> u64 {
        self.tree.pool().pager().stats.reads
    }

    pub fn page_count(&self) -> u32 {
        self.tree.pool().pager().page_count()
    }
}

fn text(bytes: &[u8]) -> std::borrow::Cow<'_, str> {
    String::from_utf8_lossy(bytes)
}

pub fn run(w: &mut dyn Write) -> DemoResult {
    writeln!(w, "Chapter 30: tracing a real insert")?;
    part1(w)?;
    part2(w)?;
    part3(w)?;
    part4(w)?;
    part5(w)
}

// ---- Part 1 -------------------------------------------------------------------

/// Run one resumable insert by hand and print every call: the states it
/// passed through and how the call ended.
fn trace_insert(w: &mut dyn Write, rig: &mut Rig, n: u8) -> DemoResult {
    let (key, value) = (scenario_key(n), scenario_value(n));
    rig.tree.pool_mut().evict_unpinned()?; // start cold: nothing is in memory
    let mut op = InsertOp::new(&rig.tree, &key, &value, Options::default())?;
    writeln!(w, "insert {} ({}-byte value), nothing cached:", text(&key), value.len())?;

    let reads_before = rig.reads();
    let mut disk_reads = 0;
    let mut call = 1;
    loop {
        write!(w, "  call {call}: ")?;
        let mut first = true;
        // One `step` call, spelled out so that the states can be printed.
        let end = loop {
            write!(w, "{}{}", if first { "" } else { ", " }, op.kind().name())?;
            first = false;
            match op.advance(&mut rig.tree)? {
                Advance::Again => {}
                Advance::Done => break Step::Done,
                Advance::Io(id) => break Step::Io(id),
            }
        };
        match end {
            Step::Done => {
                writeln!(w, " -> Done")?;
                break;
            }
            Step::Io(id) => {
                writeln!(w, " -> Io(page {id})")?;
                let in_step = rig.reads();
                rig.supply(id)?;
                disk_reads += rig.reads() - in_step;
                writeln!(w, "          the disk reads page {id} into the pool")?;
            }
        }
        call += 1;
    }
    writeln!(
        w,
        "  {call} calls; pages read by the disk: {disk_reads}, by the insert itself: {}",
        rig.reads() - reads_before - disk_reads
    )?;
    Ok(())
}

fn part1(w: &mut dyn Write) -> DemoResult {
    writeln!(w, "\n== Part 1: one insert, call by call (2-frame pool) ==")?;
    let mut rig = Rig::create(2)?;
    for &n in &SCENARIO_KEYS[0..6] {
        rig.put_scenario(n)?;
    }
    writeln!(
        w,
        "6 keys on {} pages; the root (page 1) is still a leaf",
        rig.page_count()
    )?;
    trace_insert(w, &mut rig, 7)?;
    write!(w, "{}", rig.tree.dump()?)?;
    for &n in &SCENARIO_KEYS[7..11] {
        rig.put_scenario(n)?;
    }
    trace_insert(w, &mut rig, 15)?;
    write!(w, "{}", rig.tree.dump()?)?;
    rig.tree.validate()?;
    Ok(())
}

// ---- Part 2 -------------------------------------------------------------------

const PART2_PUTS: usize = 2000;

fn print_suspensions(w: &mut dyn Write, s: &Scheduler) -> DemoResult {
    write!(
        w,
        "  {} calls of step, {} of them returned Io\n  suspended in:",
        s.steps, s.yields
    )?;
    for (i, (kind, n)) in StateKind::SUSPENDABLE.iter().zip(s.suspended).enumerate() {
        write!(w, "{} {} {n}", if i == 0 { "" } else { "," }, kind.name())?;
    }
    writeln!(w)?;
    Ok(())
}

fn part2(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 2: {PART2_PUTS} puts, blocking and resumable (4-frame pools) =="
    )?;
    let mut blocking = Rig::create(4)?;
    let mut rng = SplitMix64::new(30);
    for _ in 0..PART2_PUTS {
        let key = workload::key_for(rng.below(3000), 64);
        blocking.tree.put(&key, &workload::random_value(&mut rng, 300))?;
    }
    blocking.tree.flush()?;
    let height = blocking.tree.height()?;
    let stats = blocking.tree.stats;
    writeln!(
        w,
        "blocking put: {} keys, {} pages, height {height}; splits: {} leaf, {} interior, {} root",
        blocking.tree.key_count(),
        blocking.page_count(),
        stats.leaf_splits,
        stats.interior_splits,
        stats.root_splits
    )?;

    for pressure in [false, true] {
        let mut rig = Rig::create(4)?;
        let mut s = Scheduler::new(&mut rig.tree, 30);
        s.insert_options.pressure = pressure;
        let mut rng = SplitMix64::new(30);
        for _ in 0..PART2_PUTS {
            let key = workload::key_for(rng.below(3000), 64);
            s.submit_insert(&key, &workload::random_value(&mut rng, 300))?;
        }
        s.run();
        writeln!(
            w,
            "resumable insert{}:",
            if pressure {
                ", every unpinned page dropped between transitions"
            } else {
                ""
            }
        )?;
        print_suspensions(w, &s)?;
        drop(s);
        rig.tree.validate()?;
        rig.tree.flush()?;
        writeln!(
            w,
            "  pages read by the disk: {}; file identical to the blocking one: {}",
            rig.reads(),
            rig.mem.bytes() == blocking.mem.bytes()
        )?;
    }
    Ok(())
}

// ---- Part 3 -------------------------------------------------------------------

fn part3(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 3: five operations on one thread (8-frame pool, nothing cached) =="
    )?;
    let mut rig = Rig::create(8)?;
    for n in SCENARIO_KEYS {
        rig.put_scenario(n)?;
    }
    rig.tree.pool_mut().evict_unpinned()?;

    let mut s = Scheduler::new(&mut rig.tree, 3);
    s.events = Some(Vec::new());
    let names = ["get 17", "get 03", "get 28", "put 24", "get 24"];
    s.submit_get(b"17")?;
    s.submit_get(b"03")?;
    s.submit_get(b"28")?;
    s.submit_insert(b"24", &scenario_value(24))?;
    s.submit_get(b"24")?;
    s.run();

    for e in s.events.as_deref().unwrap_or_default() {
        let name = names[e.op];
        match e.kind {
            EventKind::Admit => writeln!(w, "  #{} {name}: admitted", e.op)?,
            EventKind::Yield => writeln!(w, "  #{} {name}: Io(page {})", e.op, e.page)?,
            EventKind::Complete => {
                writeln!(w, "  disk: page {} is in the pool, wake #{}", e.page, e.op)?;
            }
            EventKind::Failed => writeln!(w, "  #{} {name}: failed", e.op)?,
            EventKind::Done => {
                write!(w, "  #{} {name}: Done", e.op)?;
                match &s.slots[e.op].op {
                    Op::Insert(_) => writeln!(w)?,
                    Op::Get(op) => match &op.value {
                        Some(v) => writeln!(w, ", {} bytes", v.len())?,
                        None => writeln!(w, ", not found")?,
                    },
                }
            }
        }
    }
    drop(s);
    rig.tree.validate()?;
    Ok(())
}

// ---- Part 4 -------------------------------------------------------------------

fn part4(w: &mut dyn Write) -> DemoResult {
    writeln!(w, "\n== Part 4: why the writer runs alone (2-frame pool) ==")?;
    let mut rig = Rig::create(2)?;
    for n in SCENARIO_KEYS {
        rig.put_scenario(n)?;
    }
    // A value large enough that the leaf holding 12 .. 18 must split.
    let mut op = InsertOp::new(&rig.tree, b"16", &[b'q'; 1000], Options::default())?;
    // Step until the leaf has been split but the parent does not know yet.
    let mut last = op.step(&mut rig.tree)?;
    while op.kind() != StateKind::InsertSeparator {
        let Step::Io(id) = last else { unreachable!("the insert splits") };
        rig.supply(id)?;
        last = op.step(&mut rig.tree)?;
    }
    if let (State::InsertSeparator { carry }, Step::Io(id)) = (op.state(), last) {
        writeln!(
            w,
            "insert 16 has split a leaf into pages {} and {} and waits for page {id} in state {}",
            carry.left,
            carry.right,
            op.kind().name()
        )?;
    }
    // A reader that is let in now walks the tree as it is in memory.
    for key in [b"15", b"18"] {
        let found = rig.tree.get(key)?.is_some();
        writeln!(
            w,
            "  a get of {} let in now: {}",
            text(key),
            if found {
                "found"
            } else {
                "NOT FOUND, although the key is in the tree"
            }
        )?;
    }
    while let Step::Io(id) = last {
        rig.supply(id)?;
        last = op.step(&mut rig.tree)?;
    }
    let found = rig.tree.get(b"18")?.is_some();
    writeln!(
        w,
        "after the insert is done, get 18: {}",
        if found { "found" } else { "not found" }
    )?;
    rig.tree.validate()?;
    Ok(())
}

// ---- Part 5 -------------------------------------------------------------------

/// Insert 01, 02, ... in order through the scheduler, validating after each.
/// Returns the first key after which the tree is broken, with the violation.
pub fn ascending_until_broken(
    frames: usize,
    scratch: Scratch,
    last_key: u8,
) -> Result<Option<(u8, Violation)>, TreeError> {
    let mut rig = Rig::create(frames)?;
    for n in 1..=last_key {
        let mut s = Scheduler::new(&mut rig.tree, 5);
        s.insert_options.scratch = scratch;
        s.submit_insert(&scenario_key(n), &scenario_value(n))?;
        s.run();
        match rig.tree.validate() {
            Ok(()) => {}
            Err(TreeError::Invalid(v)) => return Ok(Some((n, v))),
            Err(e) => return Err(e),
        }
    }
    Ok(None)
}

fn part5(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 5: where the scratch memory of a split must live =="
    )?;
    let cases = [
        (2, Scratch::OpOwned, "owned by the operation, 2-frame pool"),
        (64, Scratch::StepBuffer, "buffer reused per call, 64-frame pool"),
        (2, Scratch::StepBuffer, "buffer reused per call, 2-frame pool"),
    ];
    for (frames, scratch, label) in cases {
        match ascending_until_broken(frames, scratch, 30)? {
            Some((n, v)) => writeln!(w, "{label}: tree broken after insert {n:02} ({v:?})")?,
            None => writeln!(w, "{label}: 30 inserts, validate ok after each")?,
        }
    }
    Ok(())
}
