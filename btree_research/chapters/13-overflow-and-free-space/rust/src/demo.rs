//! demo.rs: the fixed, deterministic scenario printed by `cargo run`.
//!
//! Part 1  24 keys with values of 324 to 1020 bytes in a real file, through
//!         a 3-frame buffer pool. The visualization replays exactly this
//!         part and checks its tree and its counters.
//! Part 2  a seeded workload of variable-length keys and values on an
//!         in-memory storage, with a reopen in the middle.
//! Part 3  integer keys: big-endian bytes make memcmp order numeric order.
//! Part 4  not crash-safe: the same split, stopped after every page write.

use std::error::Error as StdError;
use std::io::Write;
use std::path::Path;

use crate::base_buffer_pool::BufferPool;
use crate::base_pager::Pager;
use crate::base_storage::{FileStorage, MemStorage, Storage};
use crate::disk_btree::{self as btree, DiskBTree, TreeError};
use crate::prng::SplitMix64;
use crate::workload::{self, Model};

pub const DB_NAME: &str = "ch12_demo.db";

type DemoResult = Result<(), Box<dyn StdError>>;

/// The keys of parts 1 and 4, in insertion order. The first twelve are the
/// guide's canonical example.
pub const SCENARIO_KEYS: [u8; 24] = [
    10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15, 8, 22, 28, 14, 2, 27, 18, 9, 23, 11, 29, 4,
];

/// Key `n` as two decimal digits, so that byte order is numeric order.
pub fn scenario_key(n: u8) -> [u8; 2] {
    [b'0' + n / 10, b'0' + n % 10]
}

/// The value of key `n`: 300 + 24 * n copies of one letter. Small keys have
/// small values, so the leaves on the left hold more cells than the leaves
/// on the right.
pub fn scenario_value(n: u8) -> Vec<u8> {
    vec![b'a' + n % 26; 300 + 24 * n as usize]
}

fn scenario_put(tree: &mut DiskBTree, n: u8) -> Result<(), TreeError> {
    tree.put(&scenario_key(n), &scenario_value(n))
}

fn pool_over(storage: impl Storage + 'static, frames: usize) -> Result<BufferPool, TreeError> {
    Ok(BufferPool::new(Pager::new(Box::new(storage))?, frames))
}

fn text(bytes: &[u8]) -> std::borrow::Cow<'_, str> {
    String::from_utf8_lossy(bytes)
}

pub fn run(w: &mut dyn Write, dir: &Path) -> DemoResult {
    let path = dir.join(DB_NAME);
    let result = run_parts(w, &path);
    // Remove the demo file on every path out of here, errors included.
    let _ = std::fs::remove_file(&path);
    result
}

fn run_parts(w: &mut dyn Write, path: &Path) -> DemoResult {
    writeln!(w, "Chapter 12: a disk-backed B+tree")?;
    part1(w, path)?;
    part2(w)?;
    part3(w)?;
    part4(w)
}

fn print_counters(w: &mut dyn Write, tree: &mut DiskBTree) -> DemoResult {
    let height = tree.height()?;
    let (stats, pool) = (tree.stats, tree.pool());
    writeln!(
        w,
        "tree:  {} keys, {} pages, height {}; splits: {} leaf, {} interior, {} root",
        tree.key_count(),
        pool.pager().page_count(),
        height,
        stats.leaf_splits,
        stats.interior_splits,
        stats.root_splits
    )?;
    writeln!(
        w,
        "pool:  {} hits, {} misses, {} evictions, {} write-backs",
        pool.stats.hits, pool.stats.misses, pool.stats.evictions, pool.stats.writebacks
    )?;
    let pager = pool.pager().stats;
    writeln!(
        w,
        "pager: {} reads, {} writes, {} allocations, {} syncs",
        pager.reads, pager.writes, pager.allocations, pager.syncs
    )?;
    Ok(())
}

fn part1(w: &mut dyn Write, path: &Path) -> DemoResult {
    writeln!(
        w,
        "\n== Part 1: a tree of pages in a real file (3-frame pool) =="
    )?;
    writeln!(
        w,
        "a page offers {} bytes to cells; a key may have {} bytes, a value {}",
        btree::PAGE_CAPACITY,
        btree::MAX_KEY_LEN,
        btree::MAX_VALUE_LEN
    )?;
    {
        let mut tree = DiskBTree::create(pool_over(FileStorage::create(path)?, 3)?)?;
        writeln!(
            w,
            "created {}: {} pages (page 0 = metapage, page {} = root)",
            DB_NAME,
            tree.pool().pager().page_count(),
            tree.root()
        )?;

        for (i, &n) in SCENARIO_KEYS.iter().enumerate() {
            let before = tree.stats;
            scenario_put(&mut tree, n)?;
            if tree.stats.leaf_splits == before.leaf_splits {
                continue;
            }
            let grew = tree.stats.root_splits != before.root_splits;
            writeln!(
                w,
                "put #{} key {} ({} bytes) splits a leaf{}: {} pages",
                i + 1,
                text(&scenario_key(n)),
                btree::cell_cost(2, 300 + 24 * n as usize),
                if grew { " and moves the root down" } else { "" },
                tree.pool().pager().page_count()
            )?;
            if grew {
                write!(w, "{}", tree.dump()?)?;
            }
        }
        writeln!(w, "after 24 puts:")?;
        write!(w, "{}", tree.dump()?)?;
        tree.validate()?;
        print_counters(w, &mut tree)?;
        tree.close()?;
        writeln!(
            w,
            "flushed: file size = {} bytes",
            std::fs::metadata(path)?.len()
        )?;
    }
    let mut tree = DiskBTree::open(pool_over(FileStorage::open(path)?, 3)?)?;
    tree.validate()?;
    writeln!(
        w,
        "reopened: root = page {}, {} keys, height {}, validate ok",
        tree.root(),
        tree.key_count(),
        tree.height()?
    )?;

    let value = tree.get(b"17")?.expect("17 was inserted");
    writeln!(
        w,
        "get 17 -> {} bytes of '{}'",
        value.len(),
        value[0] as char
    )?;
    let missing = tree.get(b"13")?;
    writeln!(
        w,
        "get 13 -> {}",
        if missing.is_some() {
            "found?!"
        } else {
            "not found"
        }
    )?;
    write!(w, "range [10, 20) ->")?;
    let mut it = tree.range(b"10", Some(b"20"))?;
    while let Some((key, value)) = it.next()? {
        write!(w, " {}:{}", text(key), value.len())?;
    }
    writeln!(w)?;
    Ok(())
}

fn part2(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 2: 4000 random puts, keys of 1 to 64 bytes, values of 0 to 300 bytes (8-frame pool) =="
    )?;
    let mem = MemStorage::new();
    let mut model = Model::new();
    let mut rng = SplitMix64::new(12);

    for half in 0..2 {
        let pool = pool_over(mem.clone(), 8)?;
        let mut tree = if half == 0 {
            DiskBTree::create(pool)?
        } else {
            DiskBTree::open(pool)?
        };
        for _ in 0..2000 {
            let key = workload::key_for(rng.below(3000), 64);
            let value = workload::random_value(&mut rng, 300);
            tree.put(&key, &value)?;
            model.put(&key, &value);
        }
        tree.validate()?;
        writeln!(
            w,
            "{}",
            if half == 0 {
                "first 2000 puts:"
            } else {
                "reopened, 2000 more puts:"
            }
        )?;
        print_counters(w, &mut tree)?;
        tree.flush()?;
        if half == 0 {
            continue;
        }

        // Compare everything with the oracle: one full scan.
        let expected = model.range(b"", None);
        let mut it = tree.range(b"", None)?;
        let mut same = true;
        let mut count = 0;
        while let Some(entry) = it.next()? {
            same = same && expected.get(count) == Some(&entry);
            count += 1;
        }
        writeln!(
            w,
            "full scan: {} entries, oracle has {}, identical: {}",
            count,
            model.len(),
            same && count == model.len()
        )?;
    }
    Ok(())
}

fn part3(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 3: integer keys as big-endian bytes (chapter 11) =="
    )?;
    let mut tree = DiskBTree::create(pool_over(MemStorage::new(), 8)?)?;

    // 1 ..= 1000 in a shuffled order; the value is the number as text.
    let mut numbers: Vec<u64> = (1..=1000).collect();
    SplitMix64::new(3).shuffle(&mut numbers);
    for n in numbers {
        tree.put(&n.to_be_bytes(), n.to_string().as_bytes())?;
    }
    tree.validate()?;
    writeln!(
        w,
        "1000 keys, {} pages, height {}",
        tree.pool().pager().page_count(),
        tree.height()?
    )?;

    write!(w, "range [254, 259) ->")?;
    let mut it = tree.range(&254u64.to_be_bytes(), Some(&259u64.to_be_bytes()))?;
    while let Some((_, value)) = it.next()? {
        write!(w, " {}", text(value))?;
    }
    writeln!(
        w,
        "\n(255 = 00..00ff and 256 = 00..0100: adjacent as bytes only because the high byte comes first)"
    )?;
    Ok(())
}

// ---- Part 4 -------------------------------------------------------------------

/// What is left in the storage when a split is cut short.
#[derive(Debug, Default)]
pub struct CrashOutcome {
    /// The put and the flush both finished: there was no crash.
    pub completed: bool,
    pub open_error: Option<TreeError>,
    pub validate_error: Option<TreeError>,
    pub old_keys_readable: usize,
    pub new_key_readable: bool,
}

/// The index into `SCENARIO_KEYS` of the put that causes the second leaf
/// split (the first one that has to update an existing parent).
pub const CRASH_PUT: usize = 11;

/// Build the scenario tree up to (not including) `CRASH_PUT` and flush it.
/// Then let only `writes_allowed` more page writes reach the storage while
/// the next put splits a leaf and the tree is flushed. Finally forget
/// everything in memory, as a crash does, reopen and look.
pub fn crash_during_split(writes_allowed: u64) -> Result<CrashOutcome, TreeError> {
    let mem = MemStorage::new();
    let mut outcome = CrashOutcome::default();
    {
        let mut tree = DiskBTree::create(pool_over(mem.clone(), 8)?)?;
        for &n in &SCENARIO_KEYS[..CRASH_PUT] {
            scenario_put(&mut tree, n)?;
        }
        tree.flush()?;

        mem.set_writes_before_failure(Some(writes_allowed));
        let splits_before = tree.stats.leaf_splits;
        if scenario_put(&mut tree, SCENARIO_KEYS[CRASH_PUT]).is_ok() {
            assert_eq!(tree.stats.leaf_splits, splits_before + 1);
            outcome.completed = tree.flush().is_ok();
        }
        mem.set_writes_before_failure(None);
        // `tree` is dropped here without a flush: dirty pages are lost.
    }

    let mut tree = match DiskBTree::open(pool_over(mem.clone(), 8)?) {
        Ok(tree) => tree,
        Err(err) => {
            outcome.open_error = Some(err);
            return Ok(outcome);
        }
    };
    outcome.validate_error = tree.validate().err();
    for (i, &n) in SCENARIO_KEYS[..=CRASH_PUT].iter().enumerate() {
        // A lookup that runs into a broken page counts as "not readable".
        if let Ok(Some(_)) = tree.get(&scenario_key(n)) {
            if i == CRASH_PUT {
                outcome.new_key_readable = true;
            } else {
                outcome.old_keys_readable += 1;
            }
        }
    }
    Ok(outcome)
}

fn part4(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 4: not crash-safe: one split, stopped after every page write =="
    )?;
    writeln!(
        w,
        "{} keys are on disk; put {} splits a leaf, then flush; the storage fails after N writes",
        CRASH_PUT,
        text(&scenario_key(SCENARIO_KEYS[CRASH_PUT]))
    )?;
    for writes in 0.. {
        let o = crash_during_split(writes)?;
        write!(w, "N = {writes}: ")?;
        if o.completed {
            write!(w, "no crash, all writes done; ")?;
        }
        if let Some(err) = o.open_error {
            writeln!(w, "open fails with {err}")?;
            continue;
        }
        match o.validate_error {
            Some(err) => write!(w, "validate fails with {err}")?,
            None => write!(w, "validate ok")?,
        }
        writeln!(
            w,
            "; {} of {} old keys readable; new key {}",
            o.old_keys_readable,
            CRASH_PUT,
            if o.new_key_readable {
                "readable"
            } else {
                "missing"
            }
        )?;
        if o.completed {
            break;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_output_matches_expected_output_txt() {
        let tmp = crate::TempDir::new("expected_output");
        let mut out = Vec::new();
        super::run(&mut out, &tmp.0).expect("demo runs");
        assert_eq!(
            String::from_utf8(out).expect("utf-8"),
            include_str!("../../expected_output.txt")
        );
    }
}
