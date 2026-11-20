//! demo.rs: the fixed, deterministic scenario printed by `cargo run`.
//!
//! Part 1  sixteen operations on a real file: a value spills into an
//!         overflow chain, pages are freed and reused, a leaf empties and
//!         the root collapses. The visualization replays exactly this part.
//! Part 2  a seeded workload of puts and deletes with values of every size
//!         class, with a reopen in the middle, compared with the oracle.
//! Part 3  the file stops growing under a steady insert/delete load.
//! Part 4  where a value is assembled: stack buffer first, heap if larger.
//! Part 5  not crash-safe: a freed page is reused at once.

use std::error::Error as StdError;
use std::io::Write;
use std::path::Path;

use crate::base_buffer_pool::BufferPool;
use crate::base_pager::Pager;
use crate::base_storage::{FileStorage, MemStorage, Storage};
use crate::disk_btree::{self as btree, DiskBTree, Stats, TreeError, ValueBuf};
use crate::prng::SplitMix64;
use crate::workload::{self, Model};

pub const DB_NAME: &str = "ch13_demo.db";

type DemoResult = Result<(), Box<dyn StdError>>;

/// One step of part 1: `len` None deletes the key, otherwise the key gets a
/// value of `len` bytes.
#[derive(Debug, Clone, Copy)]
pub struct Step {
    pub key: u8,
    pub len: Option<usize>,
    pub show: bool,
}

const fn put(key: u8, len: usize, show: bool) -> Step {
    Step {
        key,
        len: Some(len),
        show,
    }
}

const fn delete(key: u8, show: bool) -> Step {
    Step {
        key,
        len: None,
        show,
    }
}

pub const SCENARIO: [Step; 16] = [
    put(10, 700, false),
    put(20, 700, false),
    put(30, 700, false),
    put(40, 700, false),
    put(50, 700, false),
    put(25, 9000, true), // spills, and splits the root leaf
    put(60, 3000, false),
    put(25, 100, true),  // large -> small: the chain is freed
    put(35, 5000, true), // reuses a freed page
    delete(60, false),   // frees its chain
    delete(35, false),
    delete(40, false),
    delete(50, false),
    delete(30, true),     // the right leaf empties; the root collapses
    put(70, 14000, true), // four overflow pages, all from the free list
    put(80, 3000, true),  // takes the trunk page itself
];

/// Key `n` as two decimal digits, so that byte order is numeric order.
pub fn scenario_key(n: u8) -> [u8; 2] {
    [b'0' + n / 10, b'0' + n % 10]
}

/// Apply one step. The value is `len` copies of one letter.
pub fn apply_step(tree: &mut DiskBTree, step: Step) -> Result<(), TreeError> {
    let key = scenario_key(step.key);
    match step.len {
        None => tree.delete(&key).map(|_| ()),
        Some(len) => tree.put(&key, &vec![b'a' + step.key % 26; len]),
    }
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
    writeln!(w, "Chapter 13: overflow chains and free space")?;
    part1(w, path)?;
    part2(w)?;
    part3(w)?;
    part4(w)?;
    part5(w)
}

/// One letter per page: M metapage, I interior, L leaf, O overflow, T free-
/// list trunk, F free.
fn print_page_map(w: &mut dyn Write, tree: &mut DiskBTree) -> DemoResult {
    write!(w, "page map:")?;
    for role in tree.page_map()? {
        write!(w, " {}", role.letter())?;
    }
    writeln!(w)?;
    Ok(())
}

fn print_counters(w: &mut dyn Write, tree: &mut DiskBTree) -> DemoResult {
    let height = tree.height()?;
    let (s, pool) = (tree.stats, tree.pool());
    writeln!(
        w,
        "tree:  {} keys, {} pages, height {}; splits: {} leaf, {} interior, {} root; root collapses: {}",
        tree.key_count(),
        pool.pager().page_count(),
        height,
        s.leaf_splits,
        s.interior_splits,
        s.root_splits,
        s.root_collapses
    )?;
    writeln!(
        w,
        "space: {} overflow pages written, {} tree pages freed, {} pages freed in all, {} allocations reused a page, {} pages free now",
        s.overflow_pages_written,
        s.tree_pages_freed,
        s.pages_freed,
        s.pages_reused,
        tree.free_count()
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
        "\n== Part 1: large values, freed pages and their reuse, in a real file (3-frame pool) =="
    )?;
    writeln!(
        w,
        "a page offers {} bytes to cells; a leaf cell keeps at most X = {} value bytes, a spilled value at least M = {}",
        btree::PAGE_CAPACITY,
        btree::MAX_LOCAL,
        btree::MIN_LOCAL
    )?;
    writeln!(
        w,
        "an overflow page holds {} value bytes; a trunk page lists up to {} free pages; a value may have {} bytes",
        btree::OVERFLOW_PAYLOAD,
        btree::TRUNK_CAPACITY,
        btree::MAX_VALUE_LEN
    )?;
    write!(w, "value bytes -> in the leaf + overflow pages:")?;
    for total in [100, 1088, 1089, 3000, 5000, 9000, 14000] {
        write!(
            w,
            "  {} -> {}+{}p",
            total,
            btree::local_len(total),
            btree::overflow_pages(total)
        )?;
    }
    writeln!(w)?;
    {
        let mut tree = DiskBTree::create(pool_over(FileStorage::create(path)?, 3)?)?;
        writeln!(
            w,
            "created {}: {} pages (page 0 = metapage, page {} = root)",
            DB_NAME,
            tree.pool().pager().page_count(),
            tree.root()
        )?;

        for (i, &step) in SCENARIO.iter().enumerate() {
            let pages_before = tree.pool().pager().page_count();
            let before = tree.stats;
            apply_step(&mut tree, step)?;
            let key = scenario_key(step.key);
            match step.len {
                Some(len) => write!(
                    w,
                    "#{} put {} = {} bytes ({} in the leaf + {} overflow pages)",
                    i + 1,
                    text(&key),
                    len,
                    btree::local_len(len),
                    btree::overflow_pages(len)
                )?,
                None => write!(w, "#{} delete {}", i + 1, text(&key))?,
            }
            writeln!(
                w,
                ": {} pages freed, {} reused, file grew by {}",
                tree.stats.pages_freed - before.pages_freed,
                tree.stats.pages_reused - before.pages_reused,
                tree.pool().pager().page_count() - pages_before
            )?;
            if !step.show {
                continue;
            }
            write!(w, "{}", tree.dump()?)?;
            print_page_map(w, &mut tree)?;
        }
        tree.validate()?;
        print_counters(w, &mut tree)?;
        tree.flush()?;
        writeln!(
            w,
            "flushed: file size = {} bytes",
            std::fs::metadata(path)?.len()
        )?;
    }
    let mut tree = DiskBTree::open(pool_over(FileStorage::open(path)?, 3)?)?;
    tree.validate()?;
    let height = tree.height()?;
    writeln!(
        w,
        "reopened: root = page {}, {} keys, height {}, {} free pages, validate ok",
        tree.root(),
        tree.key_count(),
        height,
        tree.free_count()
    )?;

    let value = tree.get(b"70")?.expect("key 70 is there");
    writeln!(
        w,
        "get 70 -> {} bytes, all '{}': {}",
        value.len(),
        value[0] as char,
        value.iter().all(|&b| b == b'a' + 70 % 26)
    )?;
    let found = tree.get(b"35")?.is_some();
    writeln!(
        w,
        "get 35 -> {}",
        if found { "found?!" } else { "not found" }
    )?;
    write!(w, "range [20, 99) ->")?;
    let mut it = tree.range(b"20", Some(b"99"))?;
    while let Some((key, value)) = it.next()? {
        let (key, len) = (text(key).into_owned(), value.len());
        write!(
            w,
            " {}:{}{}",
            key,
            len,
            if it.value_on_heap() { "(heap)" } else { "" }
        )?;
    }
    writeln!(w)?;
    Ok(())
}

/// One random operation of parts 2 to 4, applied to tree and oracle: a put
/// of a mixed-size value, or (`deletes` times in 10) a delete.
fn mixed_op(
    tree: &mut DiskBTree,
    model: &mut Model,
    rng: &mut SplitMix64,
    key_space: u64,
    deletes: u64,
) -> Result<(), TreeError> {
    let key = workload::key_for(rng.below(key_space), 32);
    if rng.below(10) < deletes {
        let deleted = tree.delete(&key)?;
        assert_eq!(deleted, model.delete(&key));
    } else {
        let value = workload::mixed_value(rng, 20000);
        tree.put(&key, &value)?;
        model.put(&key, &value);
    }
    Ok(())
}

fn same_as_oracle(tree: &mut DiskBTree, model: &Model) -> Result<bool, TreeError> {
    let mut it = tree.range(b"", None)?;
    let mut expected = model.iter();
    while let Some(item) = it.next()? {
        if expected.next() != Some(item) {
            return Ok(false);
        }
    }
    Ok(expected.next().is_none())
}

fn part2(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 2: 4000 random operations, 3 puts to 1 delete, values of 0 to 20000 bytes (8-frame pool) =="
    )?;
    let mem = MemStorage::new();
    let mut model = Model::new();
    let mut rng = SplitMix64::new(13);

    for half in 0..2 {
        let pool = pool_over(mem.clone(), 8)?;
        let mut tree = if half == 0 {
            DiskBTree::create(pool)?
        } else {
            DiskBTree::open(pool)?
        };
        for _ in 0..2000 {
            mixed_op(&mut tree, &mut model, &mut rng, 600, 3)?;
        }
        tree.validate()?;
        writeln!(
            w,
            "{}",
            if half == 0 {
                "first 2000 operations:"
            } else {
                "reopened, 2000 more operations:"
            }
        )?;
        print_counters(w, &mut tree)?;
        tree.flush()?;
        if half == 0 {
            continue;
        }

        let mut counts = [0usize; 7];
        for role in tree.page_map()? {
            counts[role as usize] += 1;
        }
        writeln!(
            w,
            "page roles: {} metapage, {} interior, {} leaf, {} overflow, {} trunk, {} free",
            counts[1], counts[2], counts[3], counts[4], counts[5], counts[6]
        )?;
        let same = same_as_oracle(&mut tree, &model)?;
        writeln!(
            w,
            "full scan: oracle has {} entries, identical: {}",
            model.len(),
            same
        )?;
    }
    Ok(())
}

/// Part 3 and its test: `rounds` rounds of 500 operations, half puts and
/// half deletes over 200 keys. Returns the page count after each round and
/// the tree's counters.
pub fn steady_state(rounds: usize) -> Result<(Vec<u32>, Stats), TreeError> {
    let mut model = Model::new();
    let mut tree = DiskBTree::create(pool_over(MemStorage::new(), 8)?)?;
    let mut rng = SplitMix64::new(3);
    let mut pages = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        for _ in 0..500 {
            mixed_op(&mut tree, &mut model, &mut rng, 200, 5)?;
        }
        tree.validate()?;
        pages.push(tree.pool().pager().page_count());
    }
    assert!(same_as_oracle(&mut tree, &model)?);
    Ok((pages, tree.stats))
}

fn part3(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 3: the file stops growing: 12 rounds of 500 operations, half puts and half deletes, over 200 keys =="
    )?;
    let (pages, stats) = steady_state(12)?;
    write!(w, "pages in the file after each round:")?;
    for n in &pages {
        write!(w, " {n}")?;
    }
    writeln!(
        w,
        "\n{} pages were freed and {} allocations reused one; without a free list the file would have {} pages",
        stats.pages_freed,
        stats.pages_reused,
        u64::from(pages[pages.len() - 1]) + stats.pages_reused
    )?;
    Ok(())
}

fn part4(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 4: assembling values: a 1088-byte stack buffer first, the heap only if the value is larger =="
    )?;
    let mut model = Model::new();
    let mut tree = DiskBTree::create(pool_over(MemStorage::new(), 8)?)?;
    let mut rng = SplitMix64::new(4);
    for _ in 0..1500 {
        mixed_op(&mut tree, &mut model, &mut rng, 500, 2)?;
    }

    // `get_into` assembles the value in the buffer it is given. A `ValueBuf`
    // is 1088 bytes in this stack frame plus a `Vec` for larger values.
    let (mut on_stack, mut on_heap, mut wrong) = (0, 0, 0);
    for (key, expected) in model.iter() {
        let mut buf = ValueBuf::new();
        assert!(tree.get_into(key, &mut buf)?);
        if buf.as_slice() != expected {
            wrong += 1;
        }
        if buf.on_heap() {
            on_heap += 1;
        } else {
            on_stack += 1;
        }
    }
    writeln!(
        w,
        "{} gets: {} values assembled in the stack buffer, {} on the heap, {} wrong",
        model.len(),
        on_stack,
        on_heap,
        wrong
    )?;

    // The range iterator carries the same kind of buffer inside itself.
    let mut it = tree.range(b"", None)?;
    let (mut inline_values, mut heap_values) = (0, 0);
    while it.next()?.is_some() {
        if it.value_on_heap() {
            heap_values += 1;
        } else {
            inline_values += 1;
        }
    }
    writeln!(
        w,
        "full scan: {inline_values} values in the iterator's inline buffer, {heap_values} on the heap"
    )?;
    Ok(())
}

// ---- Part 5 -------------------------------------------------------------------

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum State {
    #[default]
    Missing,
    Intact,
    WrongBytes,
    Unreadable,
}

/// What `get` returned, with the value's first and last byte.
#[derive(Debug, Clone, Copy, Default)]
pub struct Found {
    pub state: State,
    pub first: u8,
    pub last: u8,
}

/// What is in the storage after a crash in the middle of "delete one large
/// value, put another".
#[derive(Debug, Default)]
pub struct CrashOutcome {
    /// Both operations and the flush finished: there was no crash.
    pub completed: bool,
    pub validate_error: Option<TreeError>,
    pub old: Found,
    pub new: Found,
}

pub const CRASH_VALUE_LEN: usize = 5000;

fn look(tree: &mut DiskBTree, key: &[u8], letter: u8) -> Found {
    let value = match tree.get(key) {
        Err(_) => {
            return Found {
                state: State::Unreadable,
                ..Found::default()
            };
        }
        Ok(None) => return Found::default(),
        Ok(Some(value)) => value,
    };
    let intact = value.len() == CRASH_VALUE_LEN && value.iter().all(|&b| b == letter);
    Found {
        state: if intact {
            State::Intact
        } else {
            State::WrongBytes
        },
        first: value[0],
        last: value[value.len() - 1],
    }
}

fn print_found(w: &mut dyn Write, name: &str, found: Found) -> DemoResult {
    write!(w, "; {name}: ")?;
    match found.state {
        State::WrongBytes => write!(
            w,
            "WRONG VALUE (starts with '{}', ends with '{}')",
            found.first as char, found.last as char
        )?,
        State::Missing => write!(w, "missing")?,
        State::Intact => write!(w, "intact")?,
        State::Unreadable => write!(w, "unreadable")?,
    }
    Ok(())
}

/// Store "old" = 5000 x 'o' (916 bytes in the leaf, one overflow page) and
/// flush. Then let only `writes_allowed` more page writes reach the storage
/// while "old" is deleted, "new" = 5000 x 'n' is put (its overflow page is
/// the one "old" just gave back) and the tree is flushed. Finally forget
/// everything in memory, as a crash does, reopen and look.
pub fn crash_during_reuse(writes_allowed: u64) -> Result<CrashOutcome, TreeError> {
    let mem = MemStorage::new();
    let mut outcome = CrashOutcome::default();
    {
        let mut tree = DiskBTree::create(pool_over(mem.clone(), 8)?)?;
        tree.put(b"old", &[b'o'; CRASH_VALUE_LEN])?;
        tree.flush()?;

        mem.set_writes_before_failure(Some(writes_allowed));
        outcome.completed =
            tree.delete(b"old").is_ok() && tree.put(b"new", &[b'n'; CRASH_VALUE_LEN]).is_ok() && {
                assert!(tree.stats.pages_reused == 1 && tree.pool().pager().page_count() == 3);
                tree.flush().is_ok()
            };
        mem.set_writes_before_failure(None);
        // `tree` is dropped here without a flush: dirty pages are lost.
    }

    let mut tree = DiskBTree::open(pool_over(mem.clone(), 8)?)?;
    outcome.validate_error = tree.validate().err();
    outcome.old = look(&mut tree, b"old", b'o');
    outcome.new = look(&mut tree, b"new", b'n');
    Ok(outcome)
}

fn part5(w: &mut dyn Write) -> DemoResult {
    writeln!(
        w,
        "\n== Part 5: not crash-safe: a freed page is reused at once =="
    )?;
    writeln!(
        w,
        "\"old\" (5000 x 'o', one overflow page) is on disk; delete it, put \"new\" (5000 x 'n') into the same page, flush; the storage fails after N writes"
    )?;
    for writes in 0.. {
        let o = crash_during_reuse(writes)?;
        write!(w, "N = {writes}: ")?;
        if o.completed {
            write!(w, "no crash, all writes done; ")?;
        }
        match o.validate_error {
            Some(err) => write!(w, "validate fails with {err}")?,
            None => write!(w, "validate ok")?,
        }
        print_found(w, "old", o.old)?;
        print_found(w, "new", o.new)?;
        writeln!(w)?;
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
