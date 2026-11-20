// Started as a copy of chapters/12-disk-backed-bplus-tree/rust/src/tests.rs.
//! tests.rs: everything that tests DiskBTree through its public API.
//!
//! The model tests compare the tree with the oracle of workload.rs after
//! every operation, on memory and on a real file, with pools as small as two
//! frames, with reopens in the middle, and with injected I/O failures.
//!
//! Difference from Zig: there `BufferPool.deinit` asserts that no pin is
//! left and `std.testing.allocator` reports leaks, so every test is a leak
//! test by construction. Here the tests assert `pinned_frames() == 0`
//! themselves. Zig also injects allocation failures (into the tree's scratch
//! arena, into the allocator `get` is given, into the range iterator); safe
//! Rust cannot make a `Vec` allocation fail, so the equivalent "the tree
//! cannot get what it needs in the middle of an operation" case is the
//! failed page allocation of the I/O tests.

use crate::TempDir;
use crate::base_buffer_pool::BufferPool;
use crate::base_pager::Pager;
use crate::base_slotted_page::SlottedPage;
use crate::base_storage::{Error as IoError, FileStorage, MemStorage, Storage};
use crate::demo;
use crate::disk_btree::{self as btree, DiskBTree, Role, Stats, TreeError, ValueBuf, Violation};
use crate::prng::SplitMix64;
use crate::workload::{self, Model};

type TestResult = Result<(), TreeError>;

fn pool_over(storage: impl Storage + 'static, frames: usize) -> BufferPool {
    BufferPool::new(Pager::new(Box::new(storage)).expect("whole pages"), frames)
}

fn create_mem(mem: &MemStorage, frames: usize) -> DiskBTree {
    DiskBTree::create(pool_over(mem.clone(), frames)).expect("create")
}

/// Flush, forget everything in memory, open again.
fn reopen(tree: DiskBTree, mem: &MemStorage, frames: usize) -> Result<DiskBTree, TreeError> {
    tree.close()?;
    DiskBTree::open(pool_over(mem.clone(), frames))
}

fn expect_range(tree: &mut DiskBTree, model: &Model, lo: &[u8], hi: Option<&[u8]>) -> TestResult {
    let mut it = tree.range(lo, hi)?;
    for expected in model.range(lo, hi) {
        assert_eq!(it.next()?, Some(expected));
        // Heap exactly when the value had an overflow chain.
        assert_eq!(it.value_on_heap(), expected.1.len() > btree::MAX_LOCAL);
    }
    assert_eq!(it.next()?, None);
    assert_eq!(it.next()?, None); // stays at the end
    Ok(())
}

/// The tree holds exactly what the model holds.
fn expect_same_content(tree: &mut DiskBTree, model: &Model) -> TestResult {
    tree.validate()?;
    assert_eq!(tree.key_count(), model.len() as u64);
    expect_range(tree, model, b"", None)
}

fn count_roles(tree: &mut DiskBTree, role: Role) -> Result<usize, TreeError> {
    Ok(tree.page_map()?.iter().filter(|&&r| r == role).count())
}

#[derive(Clone, Copy)]
struct Shape {
    frames: usize,
    key_space: u64,
    max_key: usize,
    max_value: usize,
    /// Values from `mixed_value` (every size class) or from `random_value`.
    mixed: bool,
    ops: usize,
    reopen_every: usize,
    /// Out of ten operations: this many puts, then this many deletes; the
    /// rest are two gets, a range scan and a flush, in that order.
    puts: u64,
    deletes: u64,
    /// Every `sweep_every` operations, delete `sweep_len` neighbouring keys:
    /// random deletes alone almost never empty a whole leaf.
    sweep_every: usize,
    sweep_len: usize,
}

impl Shape {
    const fn new(frames: usize, key_space: u64, max_key: usize, max_value: usize) -> Self {
        Shape {
            frames,
            key_space,
            max_key,
            max_value,
            mixed: true,
            ops: 0,
            reopen_every: 1,
            puts: 4,
            deletes: 2,
            sweep_every: 0,
            sweep_len: 0,
        }
    }

    const fn run(self, ops: usize, reopen_every: usize) -> Self {
        Shape {
            ops,
            reopen_every,
            ..self
        }
    }

    const fn mix(self, puts: u64, deletes: u64) -> Self {
        Shape {
            puts,
            deletes,
            ..self
        }
    }

    const fn plain(self) -> Self {
        Shape {
            mixed: false,
            ..self
        }
    }
}

/// One random operation against tree and model. Returns the tree's error;
/// the model is only changed when the tree succeeded.
fn random_op(
    tree: &mut DiskBTree,
    model: &mut Model,
    rng: &mut SplitMix64,
    shape: Shape,
) -> TestResult {
    let key = workload::key_for(rng.below(shape.key_space), shape.max_key);
    let pick = rng.below(10);
    if pick < shape.puts {
        let value = if shape.mixed {
            workload::mixed_value(rng, shape.max_value)
        } else {
            workload::random_value(rng, shape.max_value)
        };
        tree.put(&key, &value)?;
        model.put(&key, &value);
        return Ok(());
    }
    if pick < shape.puts + shape.deletes {
        assert_eq!(tree.delete(&key)?, model.get(&key).is_some());
        model.delete(&key);
        return Ok(());
    }
    match pick {
        6 | 7 => assert_eq!(tree.get(&key)?.as_deref(), model.get(&key)),
        8 => {
            let hi = workload::key_for(rng.below(shape.key_space), shape.max_key);
            let unbounded = rng.chance(1, 4);
            expect_range(tree, model, &key, if unbounded { None } else { Some(&hi) })?;
        }
        _ => tree.flush()?,
    }
    Ok(())
}

/// Delete up to `count` keys that follow each other in key order, starting
/// at a random one.
fn sweep(
    tree: &mut DiskBTree,
    model: &mut Model,
    rng: &mut SplitMix64,
    count: usize,
) -> TestResult {
    if model.is_empty() {
        return Ok(());
    }
    let from = rng.below(model.len() as u64) as usize;
    for _ in 0..count.min(model.len() - from) {
        let key = model.key_at(from).expect("in range").to_vec();
        assert!(tree.delete(&key)?);
        assert!(model.delete(&key));
    }
    Ok(())
}

/// A reopen starts a new handle with new counters; keep a running sum.
fn add_stats(total: &mut Stats, s: Stats) {
    total.interior_splits += s.interior_splits;
    total.tree_pages_freed += s.tree_pages_freed;
    total.interior_pages_freed += s.interior_pages_freed;
    total.pages_freed += s.pages_freed;
    total.pages_reused += s.pages_reused;
    total.overflow_pages_written += s.overflow_pages_written;
}

/// `open_storage` hands out another handle to the same storage: a clone of
/// the MemStorage, or the same file opened again.
fn run_model(
    open_storage: &dyn Fn() -> Box<dyn Storage>,
    seed: u64,
    shape: Shape,
) -> Result<Stats, TreeError> {
    let pool = || {
        BufferPool::new(
            Pager::new(open_storage()).expect("whole pages"),
            shape.frames,
        )
    };
    let mut model = Model::new();
    let mut tree = DiskBTree::create(pool())?;
    let mut rng = SplitMix64::new(seed);
    let mut total = Stats::default();

    for i in 1..=shape.ops {
        random_op(&mut tree, &mut model, &mut rng, shape)?;
        assert_eq!(tree.pool().pinned_frames(), 0);
        if shape.sweep_every != 0 && i % shape.sweep_every == 0 {
            sweep(&mut tree, &mut model, &mut rng, shape.sweep_len)?;
        }
        if i % 250 == 0 {
            expect_same_content(&mut tree, &model)?;
        }
        if i % shape.reopen_every == 0 {
            add_stats(&mut total, tree.stats);
            tree.close()?;
            tree = DiskBTree::open(pool())?;
        }
    }
    expect_same_content(&mut tree, &model)?;
    tree.pool().validate().expect("pool invariants");
    assert_eq!(tree.root(), 1); // the root never moved
    add_stats(&mut total, tree.stats);
    tree.close()?; // the caller may look at the storage afterwards
    Ok(total)
}

#[test]
fn model_memory_storage_tiny_pools_values_of_every_size_deletes_reopen_mid_run() -> TestResult {
    let shapes = [
        // 3 frames: nearly every page access evicts, also in the middle of a chain.
        Shape::new(3, 300, 24, 20000).run(3000, 1100),
        // 2 frames is the minimum: a split, and a chain being written, pin two pages.
        Shape::new(2, 200, 40, 9000).run(2500, 900),
        // The largest values allowed (16 overflow pages) and the longest keys.
        Shape::new(4, 60, btree::MAX_KEY_LEN, btree::MAX_VALUE_LEN).run(700, 300),
        // Long keys, tiny values, three levels: interior pages split, and
        // the sweeps empty whole leaves and the interior pages above them.
        Shape {
            sweep_every: 2900,
            sweep_len: 1500,
            ..Shape::new(16, 6000, btree::MAX_KEY_LEN, 8)
                .plain()
                .run(9000, 4000)
                .mix(5, 1)
        },
    ];
    for (i, shape) in shapes.into_iter().enumerate() {
        let mem = MemStorage::new();
        let stats = run_model(&|| Box::new(mem.clone()), i as u64 + 1, shape)?;
        assert!(stats.pages_freed > 0 && stats.pages_reused > 0);
        if shape.mixed {
            assert!(stats.overflow_pages_written > 100);
        } else {
            assert!(
                stats.tree_pages_freed > 20
                    && stats.interior_pages_freed > 0
                    && stats.interior_splits > 0
            );
        }
    }
    Ok(())
}

#[test]
fn model_a_real_file_closed_and_opened_again() -> TestResult {
    let tmp = TempDir::new("model_file");
    let path = tmp.0.join("tree.db");
    let shape = Shape::new(5, 300, 48, 12000).run(2500, 700);
    drop(FileStorage::create(&path).expect("create file"));
    run_model(
        &|| Box::new(FileStorage::open(&path).expect("open file")),
        42,
        shape,
    )?;

    // Replay the same operations into a model and compare with the file as
    // it was left by the run above: nothing but the file carries the data.
    let mut model = Model::new();
    {
        let mut tree = create_mem(&MemStorage::new(), 64);
        let mut rng = SplitMix64::new(42);
        for _ in 0..shape.ops {
            random_op(&mut tree, &mut model, &mut rng, shape)?;
        }
    }
    let file = FileStorage::open(&path).expect("open file");
    let mut tree = DiskBTree::open(pool_over(file, shape.frames))?;
    expect_same_content(&mut tree, &model)
}

#[test]
fn the_file_stops_growing_under_a_steady_insert_delete_load() -> TestResult {
    // Part 3 of the demo: its page counts are pinned in expected_output.txt.
    let (pages, stats) = demo::steady_state(12)?;
    assert_eq!(pages[6], pages[11]); // no growth in the second half
    assert!(stats.pages_reused > 10 * u64::from(pages[11]));

    // The general statement: the file only grows when the free list is
    // empty, so it is never larger than the most pages ever in use at once
    // (measured between operations) plus what one operation holds briefly:
    // the new chain of an overwrite, allocated before the old one is freed.
    let mut model = Model::new();
    let mut tree = create_mem(&MemStorage::new(), 6);
    let mut rng = SplitMix64::new(99);
    let shape = Shape::new(6, 150, 16, 16000).mix(5, 5);
    let mut most_in_use = 0;
    for _ in 0..6000 {
        random_op(&mut tree, &mut model, &mut rng, shape)?;
        most_in_use = most_in_use.max(tree.pool().pager().page_count() - tree.free_count());
    }
    expect_same_content(&mut tree, &model)?;
    let pages = tree.pool().pager().page_count();
    let slack = btree::overflow_pages(shape.max_value) as u32 + 2;
    assert!(pages <= most_in_use + slack);
    assert!(tree.stats.pages_reused > 5 * u64::from(pages));
    Ok(())
}

#[test]
fn delete_everything_an_empty_root_leaf_every_other_page_free_and_nothing_grows_when_it_all_comes_back()
-> TestResult {
    let mem = MemStorage::new();
    let mut tree = create_mem(&mem, 8);

    // Keys of 200 bytes: three levels, as in chapter 12.
    let mut key = [b'k'; 200];
    let n = 2000;
    let digits =
        |key: &mut [u8; 200], i: usize| key[..6].copy_from_slice(format!("{i:06}").as_bytes());
    for round in 0..2 {
        for i in 0..n {
            digits(&mut key, i * 7919 % n);
            tree.put(&key, b"v")?;
        }
        tree.validate()?;
        assert_eq!(tree.height()?, 3);
        let pages = tree.pool().pager().page_count();
        // Second round: every page came from the free list.
        assert_eq!(
            tree.pool().pager().stats.allocations,
            if round == 0 { u64::from(pages) } else { 0 }
        );

        // Delete in another order than the keys were inserted.
        for i in 0..n {
            digits(&mut key, i * 6007 % n);
            assert!(tree.delete(&key)?);
            if i % 97 == 0 {
                tree.validate()?;
            }
        }
        assert!(!tree.delete(&key)?);
        tree.validate()?;
        assert_eq!(tree.key_count(), 0);
        assert_eq!(tree.height()?, 1);
        assert_eq!(tree.root(), 1);
        assert_eq!(tree.pool().pager().page_count(), pages);
        assert_eq!(tree.free_count(), pages - 2); // all but the metapage and the root
        assert_eq!(count_roles(&mut tree, Role::Leaf)?, 1);
        assert_eq!(count_roles(&mut tree, Role::Interior)?, 0);
        assert_eq!(tree.stats.root_collapses, 2);
        assert!(tree.stats.interior_pages_freed > 10);
        tree = reopen(tree, &mem, 8)?;
    }
    Ok(())
}

#[test]
fn more_free_pages_than_one_trunk_lists_a_second_trunk_and_both_are_used_up_again() -> TestResult {
    let mem = MemStorage::new();
    let mut tree = create_mem(&mem, 4);
    let value: Vec<u8> = (0..btree::MAX_VALUE_LEN)
        .map(|i| (i as u8).wrapping_mul(31))
        .collect();

    // 80 values of 16 overflow pages each: 1280 pages to free.
    assert_eq!(btree::overflow_pages(btree::MAX_VALUE_LEN), 16);
    let key = |i: usize| format!("{i:03}").into_bytes();
    for i in 0..80 {
        tree.put(&key(i), &value)?;
    }
    let pages = tree.pool().pager().page_count();
    for i in 0..80 {
        assert!(tree.delete(&key(i))?);
    }
    tree.validate()?;
    assert!(tree.free_count() as usize > btree::TRUNK_CAPACITY + 1);
    assert_eq!(count_roles(&mut tree, Role::Trunk)?, 2);
    assert_eq!(
        count_roles(&mut tree, Role::Free)?,
        tree.free_count() as usize - 2
    );

    tree = reopen(tree, &mem, 4)?;
    for i in 0..80 {
        tree.put(&key(i), &value)?;
    }
    tree.validate()?;
    assert_eq!(tree.pool().pager().page_count(), pages);
    assert_eq!(tree.free_count(), 0);
    assert_eq!(count_roles(&mut tree, Role::Trunk)?, 0);
    assert_eq!(tree.get(b"079")?.as_deref(), Some(&value[..]));
    Ok(())
}

#[test]
fn local_len_sqlites_rule_with_this_chapters_numbers() {
    assert_eq!(btree::MAX_LOCAL, 1088);
    assert_eq!(btree::MIN_LOCAL, 544);
    // value bytes, bytes in the leaf, overflow pages
    let cases = [
        (0, 0, 0),
        (1088, 1088, 0),
        (1089, 544, 1),
        (3000, 544, 1),
        (4628, 544, 1),
        (4629, 545, 1),
        (5000, 916, 1),
        (5172, 1088, 1),
        (5173, 544, 2),
        (9000, 832, 2),
        (14000, 544, 4),
        (65536, 544, 16),
    ];
    for (total, local, pages) in cases {
        assert_eq!(btree::local_len(total), local);
        assert_eq!(btree::overflow_pages(total), pages);
    }
    let mut full_chains = 0;
    for total in btree::MAX_LOCAL + 1..=btree::MAX_VALUE_LEN {
        let local = btree::local_len(total);
        let pages = btree::overflow_pages(total);
        assert!((btree::MIN_LOCAL..=btree::MAX_LOCAL).contains(&local));
        // The chain is exactly as long as the tail needs.
        let tail = total - local;
        assert!(
            tail > (pages - 1) * btree::OVERFLOW_PAYLOAD && tail <= pages * btree::OVERFLOW_PAYLOAD
        );
        // More than the minimum stays local only to make every page full.
        if local > btree::MIN_LOCAL {
            assert_eq!(tail, pages * btree::OVERFLOW_PAYLOAD);
        }
        if tail == pages * btree::OVERFLOW_PAYLOAD {
            full_chains += 1;
        }
    }
    // 545 remainders out of every 4084 end in a full last page.
    assert!(full_chains * 8 > btree::MAX_VALUE_LEN - btree::MAX_LOCAL);
}

#[test]
fn overwrites_that_change_the_size_class_free_the_old_chain_and_keep_the_tree_valid() -> TestResult
{
    let mut tree = create_mem(&MemStorage::new(), 3);
    let value: Vec<u8> = (0..30000).map(|i| (i as u8).wrapping_mul(7)).collect();

    tree.put(b"a", b"x")?;
    tree.put(b"z", b"y")?;
    let sizes = [
        10, 5000, 1088, 1089, 30000, 0, 9000, 9000, 9001, 544, 20000, 3,
    ];
    let mut chain_pages = 0;
    for size in sizes {
        tree.put(b"k", &value[..size])?;
        tree.validate()?;
        assert_eq!(tree.get(b"k")?.as_deref(), Some(&value[..size]));
        chain_pages += btree::overflow_pages(size);
        // Exactly the pages of the current value are in use.
        assert_eq!(
            count_roles(&mut tree, Role::Overflow)?,
            btree::overflow_pages(size)
        );
        let pages = tree.pool().pager().page_count() as usize;
        assert_eq!(
            tree.free_count() as usize,
            pages - 2 - btree::overflow_pages(size)
        );
    }
    assert_eq!(tree.stats.overflow_pages_written, chain_pages as u64);
    assert_eq!(tree.stats.pages_freed, chain_pages as u64);
    assert_eq!(tree.key_count(), 3);
    // The file is as large as the largest moment needed: the 30000-byte
    // chain (8 pages) was written while the 1089-byte one (1 page) was live.
    assert_eq!(tree.pool().pager().page_count(), 2 + 8 + 1);
    assert_eq!(tree.get(b"a")?.as_deref(), Some(&b"x"[..]));
    assert_eq!(tree.get(b"z")?.as_deref(), Some(&b"y"[..]));
    Ok(())
}

#[test]
fn values_are_assembled_where_the_caller_says_inline_buffer_first_heap_if_larger() -> TestResult {
    let mut tree = create_mem(&MemStorage::new(), 4);
    let big = [b'b'; 7000];
    tree.put(b"big", &big)?;
    tree.put(b"small", &big[..btree::MAX_LOCAL])?;

    // One buffer for both: the inline array, then the Vec, then the array
    // again (the Vec keeps its capacity, the value does not use it).
    let mut buf = ValueBuf::new();
    assert!(tree.get_into(b"small", &mut buf)?);
    assert!(!buf.on_heap());
    assert_eq!(buf.as_slice(), &big[..btree::MAX_LOCAL]);
    assert!(tree.get_into(b"big", &mut buf)?);
    assert!(buf.on_heap());
    assert_eq!(buf.as_slice(), &big[..]);
    assert!(tree.get_into(b"small", &mut buf)?);
    assert!(!buf.on_heap());
    assert_eq!(buf.as_slice().len(), btree::MAX_LOCAL);
    assert!(!tree.get_into(b"missing", &mut buf)?);
    assert_eq!(buf.into_vec(), &big[..btree::MAX_LOCAL]);
    assert_eq!(tree.pool().pinned_frames(), 0);

    // The iterator: dropping it mid-scan frees its heap value.
    let mut it = tree.range(b"", None)?;
    assert_eq!(it.next()?.map(|(key, _)| key), Some(&b"big"[..]));
    assert!(it.value_on_heap());
    assert!(size_of::<ValueBuf>() < 1200);
    Ok(())
}

#[test]
fn injected_io_failures_an_error_no_leaked_pin_and_a_tree_that_is_intact_or_poisoned() -> TestResult
{
    let shapes = [
        Shape::new(3, 200, 32, 9000),
        // Small cells with long keys, many deletes: splits and freed leaves.
        Shape::new(3, 400, 200, 600).plain().mix(5, 4),
    ];
    let mut clean_failures = 0;
    let mut poisoned_failures = 0;
    for fail_reads in [false, true] {
        for countdown in 0..150u64 {
            let shape = shapes[countdown as usize % 2];
            let mem = MemStorage::new();
            let mut model = Model::new();
            let mut tree = create_mem(&mem, shape.frames);
            let mut rng = SplitMix64::new(1000 + countdown);
            for _ in 0..250 {
                random_op(&mut tree, &mut model, &mut rng, shape)?;
            }

            if fail_reads {
                mem.set_reads_before_failure(Some(countdown));
            } else {
                mem.set_writes_before_failure(Some(countdown));
            }
            for _ in 0..300 {
                let Err(err) = random_op(&mut tree, &mut model, &mut rng, shape) else {
                    continue;
                };
                assert_eq!(err, TreeError::Io(IoError::StorageFailure));
                assert_eq!(tree.pool().pinned_frames(), 0);
                tree.pool().validate().expect("pool invariants");
                mem.set_reads_before_failure(None);
                mem.set_writes_before_failure(None);
                if tree.is_poisoned() {
                    // The failure hit after the operation's first page change.
                    poisoned_failures += 1;
                    assert_eq!(tree.put(b"k", b"v"), Err(TreeError::TreePoisoned));
                    assert_eq!(tree.delete(b"k"), Err(TreeError::TreePoisoned));
                    assert_eq!(tree.get(b"k"), Err(TreeError::TreePoisoned));
                    assert_eq!(tree.range(b"", None).err(), Some(TreeError::TreePoisoned));
                    assert_eq!(tree.flush(), Err(TreeError::TreePoisoned));
                } else {
                    // The failed operation did not happen at all.
                    clean_failures += 1;
                    expect_same_content(&mut tree, &model)?;
                    for _ in 0..50 {
                        random_op(&mut tree, &mut model, &mut rng, shape)?;
                    }
                    expect_same_content(&mut tree, &model)?;
                }
                break;
            }
            assert_eq!(tree.pool().pinned_frames(), 0);
        }
    }
    // Both outcomes must have been exercised.
    assert!(clean_failures > 50);
    assert!(poisoned_failures > 20);
    Ok(())
}

#[test]
fn a_failure_after_the_first_page_change_poisons_the_handle_before_it_nothing_happened()
-> TestResult {
    let big = [b'v'; 9000]; // two overflow pages
    // writes allowed -> poisoned? Growing the file writes a (zero) page, so
    // the first chain page is write 0 and the second is write 1.
    for (writes, poisoned) in [(0, false), (1, true)] {
        let mem = MemStorage::new();
        let mut tree = create_mem(&mem, 8);
        tree.put(b"a", b"1")?;
        mem.set_writes_before_failure(Some(writes));
        assert_eq!(
            tree.put(b"b", &big),
            Err(TreeError::Io(IoError::StorageFailure))
        );
        mem.set_writes_before_failure(None);
        assert_eq!(tree.is_poisoned(), poisoned);
        assert_eq!(tree.pool().pinned_frames(), 0);
        if poisoned {
            assert_eq!(tree.put(b"b", &big), Err(TreeError::TreePoisoned));
            assert_eq!(tree.delete(b"a"), Err(TreeError::TreePoisoned));
            // The half-written chain is one page that nothing points to.
            assert_eq!(
                tree.validate(),
                Err(TreeError::Invalid(Violation::UnreachablePage))
            );
        } else {
            tree.validate()?;
            tree.put(b"b", &big)?;
            tree.validate()?;
            assert_eq!(tree.key_count(), 2);
        }
    }
    Ok(())
}

#[test]
fn full_is_a_number_of_bytes_not_a_number_of_keys() -> TestResult {
    // Cells of 1014 bytes (4 of them are the value's length): four fit in
    // 4076 bytes, the fifth splits. Cells of 22 bytes: 185 fit.
    for (value_len, fit) in [(1000, 4), (8, 185)] {
        let cost = btree::cell_cost(4, 4 + value_len);
        assert!(fit * cost <= btree::PAGE_CAPACITY);
        assert!((fit + 1) * cost > btree::PAGE_CAPACITY);
        let mut tree = create_mem(&MemStorage::new(), 8);
        let value = [b'v'; 1000];
        for i in 0..fit {
            tree.put(format!("{i:04}").as_bytes(), &value[..value_len])?;
        }
        assert_eq!(tree.stats.leaf_splits, 0);
        tree.put(b"9999", &value[..value_len])?;
        assert_eq!(tree.stats.leaf_splits, 1);
        tree.validate()?;
    }
    Ok(())
}

#[test]
fn split_point_the_shortest_prefix_with_at_least_half_of_the_bytes() {
    assert_eq!(btree::split_point(&[10, 10, 10, 10], 1), 2);
    assert_eq!(btree::split_point(&[100, 1, 1, 1], 1), 1);
    assert_eq!(btree::split_point(&[1, 1, 1, 100], 1), 3); // the right half is never empty
    assert_eq!(btree::split_point(&[5, 5, 5, 5, 5], 2), 3);
    assert_eq!(btree::split_point(&[1, 1, 1, 100], 2), 2); // interior: one entry right of the middle
}

#[test]
fn limits_the_largest_key_with_the_largest_local_part_still_packs_three_to_a_page() -> TestResult {
    let mut tree = create_mem(&MemStorage::new(), 4);
    let big = vec![b'x'; btree::MAX_VALUE_LEN + 1];
    assert_eq!(
        tree.put(&big[..btree::MAX_KEY_LEN + 1], b"v"),
        Err(TreeError::KeyTooLarge)
    );
    assert_eq!(tree.put(b"k", &big), Err(TreeError::ValueTooLarge));
    assert!(!tree.delete(&big[..btree::MAX_KEY_LEN + 1])?);
    assert_eq!(tree.key_count(), 0);

    // 5172 bytes keep X = 1088 in the leaf: the costliest cell there is.
    assert_eq!(btree::local_len(5172), btree::MAX_LOCAL);
    let mut key = [b'k'; btree::MAX_KEY_LEN];
    for i in 0..120 {
        key[..3].copy_from_slice(format!("{:03}", i * 37 % 120).as_bytes());
        tree.put(&key, &big[..5172])?;
    }
    tree.validate()?;
    assert_eq!(tree.key_count(), 120);
    // The empty key and the empty value are legal, and so is the largest value.
    tree.put(b"", b"")?;
    assert_eq!(tree.get(b"")?.as_deref(), Some(&b""[..]));
    tree.put(&key, &big[..btree::MAX_VALUE_LEN])?;
    assert_eq!(
        tree.get(&key)?.as_deref(),
        Some(&big[..btree::MAX_VALUE_LEN])
    );
    tree.put(&key, b"small")?;
    assert_eq!(tree.get(&key)?.as_deref(), Some(&b"small"[..]));
    tree.validate()?;
    assert_eq!(tree.key_count(), 121);
    Ok(())
}

/// The tree of the demo's part 1 after its first `steps` steps.
/// After 8 steps (see expected_output.txt): page 1 is the root, pages 4 and
/// 5 are the leaves, page 6 is the chain of key 60, page 2 is a trunk that
/// lists page 3. Page map: M I T F L L O.
fn build_scenario(mem: &MemStorage, steps: usize) -> DiskBTree {
    let mut tree = create_mem(mem, 8);
    for &step in &demo::SCENARIO[..steps] {
        demo::apply_step(&mut tree, step).expect("step");
    }
    tree.validate().expect("valid");
    tree
}

#[test]
fn range_bounds_are_half_open_leaves_are_followed_through_their_links() -> TestResult {
    let mut tree = build_scenario(&MemStorage::new(), 9);
    // lo, hi, first key expected, number of entries expected
    type Case<'a> = (&'a [u8], Option<&'a [u8]>, Option<&'a [u8]>, usize);
    let cases: [Case; 7] = [
        (b"", None, Some(b"10"), 8),
        (b"20", Some(b"40"), Some(b"20"), 4), // 40 itself is excluded
        (b"33", Some(b"33"), None, 0),
        (b"26", Some(b"36"), Some(b"30"), 2), // neither bound is a key
        (b"40", Some(b"20"), None, 0),
        (b"50", None, Some(b"50"), 2),
        (b"61", None, None, 0),
    ];
    for (lo, hi, first, count) in cases {
        let mut it = tree.range(lo, hi)?;
        let mut seen = 0;
        let mut previous = vec![0u8, 0];
        while let Some((key, _)) = it.next()? {
            if seen == 0 {
                assert_eq!(Some(key), first);
            }
            assert!(previous.as_slice() < key);
            previous = key.to_vec();
            seen += 1;
        }
        assert_eq!(seen, count);
        assert_eq!(tree.pool().pinned_frames(), 0);
    }
    Ok(())
}

#[test]
fn the_scenarios_page_map_step_by_step() -> TestResult {
    let mut tree = build_scenario(&MemStorage::new(), 0);
    let maps = [
        "ML", "ML", "ML", "ML", "ML", "MIOOLL", "MIOOLLO", "MITFLLO", "MITOLLO", "MITOLLF",
        "MITFLLF", "MITFLLF", "MITFLLF", "MLTFFFF", "MLTOOOO", "MLOOOOO",
    ];
    for (&step, want) in demo::SCENARIO.iter().zip(maps) {
        demo::apply_step(&mut tree, step)?;
        let letters: String = tree.page_map()?.iter().map(|role| role.letter()).collect();
        assert_eq!(letters, want);
    }
    Ok(())
}

fn put_u32(bytes: &mut [u8], at: usize, value: u32) {
    bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
}

#[test]
fn validate_detects_each_kind_of_damage() -> TestResult {
    let cases = [
        // chapter 12's
        ("link", Violation::LeafChainBroken),
        ("bounds", Violation::KeyOutOfBounds),
        ("count", Violation::KeyCountMismatch),
        ("orphan", Violation::UnreachablePage),
        ("twice", Violation::PageReachedTwice),
        ("zeroed", Violation::BadPage),
        ("emptied", Violation::EmptyPage),
        ("depth", Violation::UnevenDepth),
        // new
        ("cell", Violation::BadCell),
        ("chain_long", Violation::OverflowChainBroken),
        ("chain_short", Violation::OverflowChainBroken),
        ("chain_kind", Violation::OverflowChainBroken),
        ("chain_shared", Violation::PageReachedTwice),
        ("free_and_used", Violation::PageInTwoRoles),
        ("free_count", Violation::FreeListBroken),
        ("trunk_kind", Violation::FreeListBroken),
        ("trunk_loop", Violation::PageReachedTwice),
        ("leaked", Violation::UnreachablePage),
    ];
    // A value field for a 3000-byte value whose chain starts at page 6.
    let mut field_3000 = [b'x'; 4 + 544 + 4];
    put_u32(&mut field_3000, 0, 3000);
    put_u32(&mut field_3000, 548, 6);

    for (damage, want) in cases {
        let mem = MemStorage::new();
        let mut tree = build_scenario(&mem, 8);
        match damage {
            "link" => {
                let pool = tree.pool_mut();
                put_u32(
                    SlottedPage::open(pool.fetch_page(4)?).user_area_mut(),
                    0,
                    btree::INVALID_PAGE_ID,
                ); // skips page 5
                pool.unpin(4, true);
            }
            "bounds" => {
                let pool = tree.pool_mut();
                let mut leaf = SlottedPage::open(pool.fetch_page(4)?);
                leaf.put(b"99", b"\x01\x00\x00\x00v").expect("fits"); // far too large for this leaf
                pool.unpin(4, true);
            }
            "count" => *tree.counts_mut().0 += 1,
            "orphan" => {
                let pool = tree.pool_mut();
                let (id, _) = pool.new_page()?;
                pool.unpin(id, false);
            }
            "twice" => {
                let pool = tree.pool_mut();
                put_u32(SlottedPage::open(pool.fetch_page(1)?).user_area_mut(), 0, 4); // rightmost child = first child
                pool.unpin(1, true);
            }
            "zeroed" => {
                let pool = tree.pool_mut();
                pool.fetch_page(5)?.fill(0);
                pool.unpin(5, true);
            }
            "emptied" => {
                let pool = tree.pool_mut();
                let mut leaf = SlottedPage::open(pool.fetch_page(4)?);
                while leaf.count() > 0 {
                    leaf.delete_at(0);
                }
                pool.unpin(4, true);
                *tree.counts_mut().0 -= 3;
            }
            "depth" => {
                // Turn leaf 4 into an interior page over two new leaves that
                // hold its keys: every invariant holds except T4.
                let pool = tree.pool_mut();
                let old = *pool.fetch_page(4)?;
                let (a, _) = pool.new_page()?;
                let (b, _) = pool.new_page()?;
                *pool.page_mut(a) = old;
                *pool.page_mut(b) = old;
                let mut left = SlottedPage::open(pool.page_mut(a));
                left.delete_at(2);
                put_u32(left.user_area_mut(), 0, b);
                let mut right = SlottedPage::open(pool.page_mut(b));
                right.delete_at(0);
                right.delete_at(0);
                let sep = right.key(0).to_vec();
                let mut parent = SlottedPage::init_reserved(pool.page_mut(4), btree::RESERVED_TAIL);
                parent.set_kind(btree::KIND_INTERIOR);
                put_u32(parent.user_area_mut(), 0, b);
                parent.insert_at(0, &sep, &a.to_le_bytes()).expect("fits");
                pool.unpin(4, true);
                pool.unpin(a, true);
                pool.unpin(b, true);
            }
            "cell" => {
                // A length of 5 in front of 3 bytes.
                let pool = tree.pool_mut();
                SlottedPage::open(pool.fetch_page(4)?)
                    .put(b"25", b"\x05\x00\x00\x00abc")
                    .expect("fits");
                pool.unpin(4, true);
            }
            "chain_long" => {
                // The 3000-byte value's single page points on, at page 3.
                let pool = tree.pool_mut();
                put_u32(pool.fetch_page(6)?, 0, 3);
                pool.unpin(6, true);
            }
            "chain_short" => {
                // A cell that claims 9000 bytes over a chain of one page.
                let mut field = [b'x'; 4 + 832 + 4];
                put_u32(&mut field, 0, 9000);
                put_u32(&mut field, 836, 6);
                let pool = tree.pool_mut();
                SlottedPage::open(pool.fetch_page(5)?)
                    .put(b"60", &field)
                    .expect("fits");
                pool.unpin(5, true);
            }
            "chain_kind" => {
                let pool = tree.pool_mut();
                pool.fetch_page(6)?[7] = btree::KIND_TRUNK;
                pool.unpin(6, true);
            }
            "chain_shared" => {
                // A second cell points at the chain of key 60.
                let pool = tree.pool_mut();
                SlottedPage::open(pool.fetch_page(4)?)
                    .put(b"25", &field_3000)
                    .expect("fits");
                pool.unpin(4, true);
            }
            "free_and_used" => {
                // The trunk lists leaf 4 as free.
                let pool = tree.pool_mut();
                let trunk = pool.fetch_page(2)?;
                put_u32(trunk, 12, 4);
                trunk[4] = 2;
                pool.unpin(2, true);
                *tree.counts_mut().1 += 1;
            }
            "free_count" => *tree.counts_mut().1 += 1,
            "trunk_kind" => {
                let pool = tree.pool_mut();
                pool.fetch_page(2)?[7] = btree::KIND_OVERFLOW;
                pool.unpin(2, true);
            }
            "trunk_loop" => {
                let pool = tree.pool_mut();
                put_u32(pool.fetch_page(2)?, 0, 2);
                pool.unpin(2, true);
            }
            "leaked" => {
                // Page 3 drops off the list: free, but nobody knows.
                let pool = tree.pool_mut();
                pool.fetch_page(2)?[4] = 0;
                pool.unpin(2, true);
                *tree.counts_mut().1 -= 1;
            }
            _ => unreachable!(),
        }
        assert_eq!(tree.validate(), Err(TreeError::Invalid(want)), "{damage}");
        assert_eq!(tree.pool().pinned_frames(), 0);
    }
    Ok(())
}

#[test]
fn operations_report_a_damaged_chain_or_free_list_as_corrupt_without_leaking_a_pin() -> TestResult {
    let mut tree = build_scenario(&MemStorage::new(), 8);
    // The chain of key 60 runs into a page that is not an overflow page.
    tree.pool_mut().fetch_page(6)?[7] = 0;
    tree.pool_mut().unpin(6, true);
    assert_eq!(tree.get(b"60"), Err(TreeError::Corrupt));
    let mut it = tree.range(b"60", None)?;
    assert_eq!(it.next(), Err(TreeError::Corrupt));
    assert_eq!(tree.delete(b"60"), Err(TreeError::Corrupt));
    assert!(tree.is_poisoned()); // the cell was already gone
    assert_eq!(tree.pool().pinned_frames(), 0);

    let mut tree = build_scenario(&MemStorage::new(), 8);
    // The free-list head is not a trunk: nothing can be allocated or freed.
    tree.pool_mut().fetch_page(2)?[7] = 0;
    tree.pool_mut().unpin(2, true);
    assert_eq!(tree.put(b"70", &[b'v'; 5000]), Err(TreeError::Corrupt));
    assert!(!tree.is_poisoned()); // nothing had changed yet
    assert_eq!(tree.pool().pinned_frames(), 0);
    Ok(())
}

#[test]
fn open_and_create_check_what_they_are_given() -> TestResult {
    let mem = MemStorage::new();
    // An empty storage is not a tree.
    assert_eq!(
        DiskBTree::open(pool_over(mem.clone(), 4)).err(),
        Some(TreeError::BadMagic)
    );
    let mut tree = create_mem(&mem, 4);
    tree.put(b"k", &[b'v'; 5000])?;
    tree.put(b"k", b"v")?; // page 2 becomes a trunk
    assert_eq!(tree.free_head(), 2);
    tree.close()?;
    assert_eq!(
        DiskBTree::create(pool_over(mem.clone(), 4)).err(),
        Some(TreeError::NotEmpty)
    );

    // Damage the metapage; each time `open` must refuse.
    let patches = [
        (0, b'X', TreeError::BadMagic),
        (8, 1, TreeError::UnsupportedVersion), // chapter 12's format
        (16, 77, TreeError::Corrupt),          // root page id outside the file
        (20, 99, TreeError::Corrupt),          // more pages than the file has
        (32, 0, TreeError::Corrupt),           // the metapage as the free-list head
        (32, 50, TreeError::Corrupt),          // a head outside the file
        (36, 0, TreeError::Corrupt),           // a head but no free pages
        (36, 200, TreeError::Corrupt),         // more free pages than pages
    ];
    for (offset, byte, want) in patches {
        let mut pool = pool_over(mem.clone(), 4);
        pool.fetch_page(0)?[offset] = byte;
        pool.unpin(0, false); // only the cached copy is damaged
        assert_eq!(DiskBTree::open(pool).err(), Some(want));
    }
    let mut tree = DiskBTree::open(pool_over(mem.clone(), 4))?;
    assert_eq!(tree.get(b"k")?.as_deref(), Some(&b"v"[..]));
    assert_eq!(tree.free_count(), 1);
    assert_eq!(tree.pool().pinned_frames(), 0);
    Ok(())
}

#[test]
fn every_page_of_every_role_keeps_its_last_four_bytes_free_for_a_checksum() -> TestResult {
    let mem = MemStorage::new();
    build_scenario(&mem, 13).close()?; // M I T F L L F: every role at once
    let bytes = mem.bytes();
    assert_eq!(bytes.len(), 7 * btree::PAGE_SIZE);
    for page in bytes.chunks(btree::PAGE_SIZE) {
        assert_eq!(
            page[btree::PAGE_SIZE - btree::RESERVED_TAIL as usize..],
            [0, 0, 0, 0]
        );
    }
    assert_eq!(&bytes[..8], btree::MAGIC);
    // A full overflow page: the 3000-byte value was freed from page 6, the
    // 5000-byte one from page 3, whose 4084 payload bytes end at 4092.
    assert_eq!(bytes[3 * btree::PAGE_SIZE + 7], btree::KIND_OVERFLOW);
    assert_eq!(bytes[3 * btree::PAGE_SIZE + 4091], b'j');
    Ok(())
}

#[test]
fn a_crash_between_freeing_a_page_and_reusing_it_leaves_a_file_that_validates_and_lies()
-> TestResult {
    // The same experiment as part 5 of the demo, with the outcomes pinned.
    let before = demo::crash_during_reuse(0)?;
    assert!(!before.completed && before.validate_error.is_none());
    assert_eq!(before.old.state, demo::State::Intact);
    assert_eq!(before.new.state, demo::State::Missing);

    let mut lies = 0;
    let mut writes = 1;
    let after = loop {
        let o = demo::crash_during_reuse(writes)?;
        if o.completed {
            break o;
        }
        assert_eq!(o.validate_error, None); // nothing looks wrong
        if o.new.state == demo::State::WrongBytes {
            // The new cell is on disk, its overflow page is not: the page
            // still holds the tail of the value that owned it before.
            assert_eq!((o.new.first, o.new.last), (b'n', b'o'));
            lies += 1;
        }
        writes += 1;
    };
    assert_eq!(writes, 3); // metapage, leaf, overflow page
    assert_eq!(lies, 1);
    assert!(after.validate_error.is_none());
    assert_eq!(after.new.state, demo::State::Intact);
    assert_eq!(after.old.state, demo::State::Missing);
    Ok(())
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |h, &b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

#[test]
fn zig_and_rust_write_the_same_bytes() -> TestResult {
    // The Zig twin has this test with the same two numbers: FNV-1a hashes of
    // the file after part 1's sixteen steps and after a seeded workload.
    let mem = MemStorage::new();
    build_scenario(&mem, 16).close()?;
    assert_eq!(fnv1a(&mem.bytes()), 4600392725701261712);

    let mem = MemStorage::new();
    let mut model = Model::new();
    let mut tree = create_mem(&mem, 4);
    let mut rng = SplitMix64::new(77);
    let shape = Shape::new(4, 300, 24, 12000);
    for _ in 0..2000 {
        random_op(&mut tree, &mut model, &mut rng, shape)?;
    }
    tree.close()?;
    assert_eq!(fnv1a(&mem.bytes()), 10315806560220619977);
    Ok(())
}
