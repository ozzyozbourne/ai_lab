//! tests.rs: everything that tests DiskBTree through its public API.
//!
//! The model tests compare the tree with the oracle of workload.rs after
//! every operation, on memory and on a real file, with pools as small as two
//! frames, with reopens in the middle, and with injected I/O failures.
//!
//! Difference from Zig: there `BufferPool.deinit` asserts that no pin is
//! left and `std.testing.allocator` reports leaks, so every test is a leak
//! test by construction. Here the tests assert `pinned_frames() == 0`
//! themselves. Zig also injects allocation failures into the tree's scratch
//! arena; safe Rust cannot make a `Vec` allocation fail, so the equivalent
//! "the tree cannot get what it needs in the middle of a split" case is the
//! failed page allocation of the I/O tests.

use crate::TempDir;
use crate::base_buffer_pool::BufferPool;
use crate::base_pager::Pager;
use crate::base_slotted_page::SlottedPage;
use crate::base_storage::{Error as IoError, FileStorage, MemStorage, Storage};
use crate::demo;
use crate::disk_btree::{self as btree, DiskBTree, TreeError, Violation};
use crate::prng::SplitMix64;
use crate::workload::{self, Model};

type TestResult = Result<(), TreeError>;

fn pool_over(storage: impl Storage + 'static, frames: usize) -> BufferPool {
    BufferPool::new(Pager::new(Box::new(storage)).expect("whole pages"), frames)
}

fn create_mem(mem: &MemStorage, frames: usize) -> DiskBTree {
    DiskBTree::create(pool_over(mem.clone(), frames)).expect("create")
}

fn expect_range(tree: &mut DiskBTree, model: &Model, lo: &[u8], hi: Option<&[u8]>) -> TestResult {
    let mut it = tree.range(lo, hi)?;
    for expected in model.range(lo, hi) {
        assert_eq!(it.next()?, Some(expected));
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

#[derive(Clone, Copy)]
struct Shape {
    frames: usize,
    key_space: u64,
    max_key: usize,
    max_value: usize,
    ops: usize,
    reopen_every: usize,
    /// How many operations in ten are puts; the rest are gets (2), a range
    /// scan and a flush.
    puts: u64,
}

impl Shape {
    const fn new(frames: usize, key_space: u64, max_key: usize, max_value: usize) -> Self {
        Shape {
            frames,
            key_space,
            max_key,
            max_value,
            ops: 0,
            reopen_every: 1,
            puts: 6,
        }
    }

    const fn run(self, ops: usize, reopen_every: usize) -> Self {
        Shape {
            ops,
            reopen_every,
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
        let value = workload::random_value(rng, shape.max_value);
        tree.put(&key, &value)?;
        model.put(&key, &value);
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

/// `open_storage` hands out another handle to the same storage: a clone of
/// the MemStorage, or the same file opened again.
fn run_model(open_storage: &dyn Fn() -> Box<dyn Storage>, seed: u64, shape: Shape) -> TestResult {
    let pool = || {
        BufferPool::new(
            Pager::new(open_storage()).expect("whole pages"),
            shape.frames,
        )
    };
    let mut model = Model::new();
    let mut tree = DiskBTree::create(pool())?;
    let mut rng = SplitMix64::new(seed);

    for i in 1..=shape.ops {
        random_op(&mut tree, &mut model, &mut rng, shape)?;
        assert_eq!(tree.pool().pinned_frames(), 0);
        if i % 500 == 0 {
            expect_same_content(&mut tree, &model)?;
        }
        if i % shape.reopen_every == 0 {
            tree.close()?;
            tree = DiskBTree::open(pool())?;
        }
    }
    expect_same_content(&mut tree, &model)?;
    tree.pool().validate().expect("pool invariants");
    assert_eq!(tree.root(), 1); // the root never moved
    assert!(tree.height()? >= 2);
    tree.close()
}

#[test]
fn model_memory_storage_tiny_pools_reopen_mid_run() -> TestResult {
    let shapes = [
        // 3 frames: nearly every page access evicts, also in the middle of a split.
        Shape::new(3, 700, 24, 120).run(5000, 1700),
        // 2 frames is the minimum: a split pins two pages.
        Shape::new(2, 500, 40, 300).run(3000, 900),
        // The largest keys and values allowed: three or four cells per leaf.
        Shape::new(4, 400, btree::MAX_KEY_LEN, btree::MAX_VALUE_LEN).run(3000, 1100),
        // Long keys, empty-ish values: interior pages split often.
        Shape::new(16, 5000, btree::MAX_KEY_LEN, 8).run(6000, 2500),
    ];
    for (i, shape) in shapes.into_iter().enumerate() {
        let mem = MemStorage::new();
        run_model(&|| Box::new(mem.clone()), i as u64 + 1, shape)?;
    }
    Ok(())
}

#[test]
fn model_a_real_file_closed_and_opened_again() -> TestResult {
    let tmp = TempDir::new("model_file");
    let path = tmp.0.join("tree.db");
    let shape = Shape::new(5, 800, 48, 400).run(3000, 700);
    drop(FileStorage::create(&path).expect("create file"));
    run_model(
        &|| Box::new(FileStorage::open(&path).expect("open file")),
        42,
        shape,
    )?;

    // Replay the same puts into a model and compare with the file as it
    // was left by the run above: nothing but the file carries the data.
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
fn injected_io_failures_an_error_no_leaked_pin_and_a_tree_that_is_intact_or_poisoned() -> TestResult
{
    let shapes = [
        Shape::new(3, 600, 32, 200),
        // Only puts of large cells: the failure often lands inside a split.
        Shape {
            puts: 10,
            ..Shape::new(3, 5000, 200, 1000)
        },
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
                    // The failure hit between two page changes of a split.
                    poisoned_failures += 1;
                    assert_eq!(tree.put(b"k", b"v"), Err(TreeError::TreePoisoned));
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
    assert!(poisoned_failures >= 3);
    Ok(())
}

#[test]
fn a_failure_between_the_page_changes_of_a_split_poisons_the_handle() -> TestResult {
    let value = [b'v'; 1000];
    let mem = MemStorage::new();
    let mut tree = create_mem(&mem, 8);
    for key in [b"a", b"b", b"c", b"d"] {
        tree.put(key, &value)?;
    }

    // The fifth cell does not fit. Splitting the root leaf allocates two
    // pages; let the first allocation succeed and the second fail.
    mem.set_writes_before_failure(Some(1));
    assert_eq!(
        tree.put(b"e", &value),
        Err(TreeError::Io(IoError::StorageFailure))
    );
    mem.set_writes_before_failure(None);
    assert!(tree.is_poisoned());
    assert_eq!(tree.pool().pinned_frames(), 0);
    // The four calls that would act on the half-split tree refuse.
    assert_eq!(tree.put(b"e", &value), Err(TreeError::TreePoisoned));
    assert_eq!(tree.get(b"a"), Err(TreeError::TreePoisoned));
    assert_eq!(tree.range(b"", None).err(), Some(TreeError::TreePoisoned));
    assert_eq!(tree.flush(), Err(TreeError::TreePoisoned));
    // The three that only look do not: they are how the damage is examined.
    // Here the root moved down (page 1 is an interior page without a key,
    // page 2 has its four cells) and the split of page 2 never started.
    assert_eq!(
        tree.validate(),
        Err(TreeError::Invalid(Violation::EmptyPage))
    );
    assert_eq!(tree.height()?, 2);
    assert_eq!(
        tree.dump()?,
        "page 1  interior  0 keys  0/4076 bytes  | (2)\n\
         \x20 page 2  leaf      4 keys  4028/4076 bytes  next -  | a:1000 b:1000 c:1000 d:1000\n"
    );
    assert_eq!(tree.pool().pinned_frames(), 0);

    // A failure BEFORE the first page change leaves a working tree.
    let mem2 = MemStorage::new();
    let mut tree2 = create_mem(&mem2, 8);
    for key in [b"a", b"b", b"c", b"d"] {
        tree2.put(key, &value)?;
    }
    mem2.set_writes_before_failure(Some(0));
    assert_eq!(
        tree2.put(b"e", &value),
        Err(TreeError::Io(IoError::StorageFailure))
    );
    mem2.set_writes_before_failure(None);
    assert!(!tree2.is_poisoned());
    tree2.validate()?;
    tree2.put(b"e", &value)?;
    tree2.validate()?;
    assert_eq!(tree2.key_count(), 5);
    Ok(())
}

fn build_scenario(mem: &MemStorage) -> DiskBTree {
    let mut tree = create_mem(mem, 8);
    for n in demo::SCENARIO_KEYS {
        tree.put(&demo::scenario_key(n), &demo::scenario_value(n))
            .expect("put");
    }
    tree.validate().expect("valid");
    tree
}

#[test]
fn the_root_page_id_is_stable_while_the_tree_grows_to_three_levels() -> TestResult {
    let mem = MemStorage::new();
    let mut tree = create_mem(&mem, 8);
    assert_eq!(tree.root(), 1);
    assert_eq!(tree.height()?, 1);

    // Keys of 200 bytes: about 19 separators per interior page.
    let mut key = [b'k'; 200];
    for i in 0..2000 {
        key[..6].copy_from_slice(format!("{:06}", i * 7919 % 2000).as_bytes());
        tree.put(&key, b"v")?;
    }
    tree.validate()?;
    assert_eq!(tree.height()?, 3);
    assert_eq!(tree.stats.root_splits, 2);
    assert!(tree.stats.interior_splits > 0);
    assert_eq!(tree.root(), 1);

    // The metapage on disk agrees after a reopen.
    tree.close()?;
    let mut tree = DiskBTree::open(pool_over(mem.clone(), 8))?;
    assert_eq!(tree.root(), 1);
    assert_eq!(tree.key_count(), 2000);
    tree.validate()
}

#[test]
fn full_is_a_number_of_bytes_not_a_number_of_keys() -> TestResult {
    // Cells of 1010 bytes: four fit in 4076 bytes, the fifth splits.
    // Cells of 18 bytes: 226 fit, the 227th splits.
    for (value_len, fit) in [(1000, 4), (8, 226)] {
        assert!(fit * btree::cell_cost(4, value_len) <= btree::PAGE_CAPACITY);
        assert!((fit + 1) * btree::cell_cost(4, value_len) > btree::PAGE_CAPACITY);
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
fn limits_keys_and_values_that_are_too_large_are_refused_the_largest_are_accepted() -> TestResult {
    let mut tree = create_mem(&MemStorage::new(), 4);
    let big = [b'x'; btree::MAX_VALUE_LEN + 1];
    assert_eq!(
        tree.put(&big[..btree::MAX_KEY_LEN + 1], b"v"),
        Err(TreeError::KeyTooLarge)
    );
    assert_eq!(tree.put(b"k", &big), Err(TreeError::ValueTooLarge));
    assert_eq!(tree.key_count(), 0);

    // Every cell as large as allowed: any three fit in a page.
    let mut key = [b'k'; btree::MAX_KEY_LEN];
    for i in 0..200 {
        key[..3].copy_from_slice(format!("{:03}", i * 37 % 200).as_bytes());
        tree.put(&key, &big[..btree::MAX_VALUE_LEN])?;
    }
    tree.validate()?;
    assert_eq!(tree.key_count(), 200);
    // The empty key and the empty value are legal.
    tree.put(b"", b"")?;
    assert_eq!(tree.get(b"")?.as_deref(), Some(&b""[..]));
    // Overwriting with a larger value can split, with a smaller one cannot.
    tree.put(&key, b"small")?;
    assert_eq!(tree.get(&key)?.as_deref(), Some(&b"small"[..]));
    tree.validate()?;
    assert_eq!(tree.key_count(), 201);
    Ok(())
}

#[test]
fn range_bounds_are_half_open_leaves_are_followed_through_their_links() -> TestResult {
    let mut tree = build_scenario(&MemStorage::new());
    /// (lo, hi, first key returned, number of entries)
    type Case<'a> = (&'a [u8], Option<&'a [u8]>, Option<&'a [u8]>, usize);
    let cases: [Case; 7] = [
        (b"", None, Some(b"01"), 24),
        (b"10", Some(b"20"), Some(b"10"), 7), // 20 itself is excluded
        (b"13", Some(b"13"), None, 0),
        (b"13", Some(b"16"), Some(b"14"), 2), // neither bound is a key
        (b"20", Some(b"10"), None, 0),
        (b"29", None, Some(b"29"), 2),
        (b"31", None, None, 0),
    ];
    for (lo, hi, first, expected_count) in cases {
        let mut it = tree.range(lo, hi)?;
        let mut count = 0;
        let mut previous = vec![0u8; 2];
        while let Some((key, _)) = it.next()? {
            if count == 0 {
                assert_eq!(Some(key), first);
            }
            assert!(previous.as_slice() < key);
            previous = key.to_vec();
            count += 1;
        }
        assert_eq!(count, expected_count);
        assert_eq!(tree.pool().pinned_frames(), 0);
    }
    Ok(())
}

/// A value that depends on the key, so that a get which finds the wrong
/// key cannot return the right bytes.
fn edge_value(key: &[u8]) -> Vec<u8> {
    let first = key.first().copied().unwrap_or(0xAA);
    vec![first ^ key.len() as u8; key.len() * 37 % 500]
}

/// Keys that a tree of byte strings must get right and that `key_for` (1 to
/// n letters 'a' to 'f') never produces: the empty key, the bytes 0x00 and
/// 0xFF, and long chains in which every key is a prefix of the next.
/// The Zig twin issues the same puts in the same order.
fn put_edge_keys(tree: &mut DiskBTree, model: &mut Model) -> TestResult {
    let mut put = |key: &[u8]| -> TestResult {
        let value = edge_value(key);
        tree.put(key, &value)?;
        model.put(key, &value);
        Ok(())
    };
    let runs: [(u8, &[usize]); 2] = [
        (0x00, &[0, 1, 2, 3, 4]), // length 0 is the empty key
        (0xFF, &[1, 2, 3, 4, btree::MAX_KEY_LEN]),
    ];
    for (byte, lens) in runs {
        for &len in lens {
            put(&vec![byte; len])?;
        }
    }
    // "a", "aa", ... up to 256 bytes, longest first: every put is a prefix
    // of all the keys already there and must land in front of them.
    for len in (1..=btree::MAX_KEY_LEN).rev() {
        put(&vec![b'a'; len])?;
    }
    // 0x00 and 0xFF after a common prefix sort before and after every "aa...".
    let tails: [&[u8]; 4] = [b"a\x00", b"a\xff", b"a\x00\xff", b"a\xff\x00"];
    for key in tails {
        put(key)?;
    }
    Ok(())
}

fn expect_edge_keys(tree: &mut DiskBTree, model: &Model) -> TestResult {
    expect_same_content(tree, model)?;
    for (key, value) in model.range(b"", None) {
        assert_eq!(tree.get(key)?.as_deref(), Some(value));
    }
    assert_eq!(model.len(), 5 + 5 + 256 + 4);

    // Order: the empty key is the smallest, a key sorts before everything it
    // is a prefix of, 0x00 sorts first and 0xFF last (bytes are unsigned).
    let all_ff = [0xFFu8; btree::MAX_KEY_LEN];
    let expected_head: [&[u8]; 10] = [
        b"",
        b"\x00",
        b"\x00\x00",
        b"\x00\x00\x00",
        b"\x00\x00\x00\x00",
        b"a",
        b"a\x00",
        b"a\x00\xff",
        b"aa",
        b"aaa",
    ];
    let mut it = tree.range(b"", None)?;
    for key in expected_head {
        assert_eq!(it.next()?.map(|(k, _)| k), Some(key));
    }
    let mut last = Vec::new();
    while let Some((key, _)) = it.next()? {
        last = key.to_vec();
    }
    assert_eq!(last, all_ff);

    // Bounds made of these bytes.
    type Case<'a> = (&'a [u8], Option<&'a [u8]>, usize);
    let cases: [Case; 8] = [
        (b"", Some(b""), 0),
        (b"", Some(b"\x00"), 1), // the empty key alone
        (b"\x00", Some(b"\x00\x00\x00"), 2),
        (b"\x00\x00\x00\x00\x00", Some(b"a"), 0), // five zero bytes: not a key
        (b"a", Some(b"b"), 256 + 4),
        (b"a\xff", None, 2 + 5), // a FF, a FF 00, and the five FF runs
        (b"\xff", None, 5),
        (&all_ff, None, 1),
    ];
    for (lo, hi, count) in cases {
        expect_range(tree, model, lo, hi)?;
        assert_eq!(model.range(lo, hi).len(), count);
    }
    // Neighbours that are not keys.
    assert_eq!(tree.get(b"\x00\x00\x00\x00\x00")?, None);
    assert_eq!(tree.get(b"a\x00\x00")?, None);
    assert_eq!(tree.get(&all_ff[..btree::MAX_KEY_LEN - 1])?, None);
    assert_eq!(tree.get(b"b")?, None);
    Ok(())
}

#[test]
fn the_empty_key_0x00_and_0xff_bytes_and_keys_that_are_prefixes_of_each_other() -> TestResult {
    // 2 frames: every one of these puts works with the minimum of memory.
    for frames in [2, 8] {
        let mem = MemStorage::new();
        let mut model = Model::new();
        let mut tree = create_mem(&mem, frames);

        put_edge_keys(&mut tree, &mut model)?;
        expect_edge_keys(&mut tree, &model)?;
        assert!(tree.height()? >= 3); // long keys: interior pages split too
        assert!(tree.stats.interior_splits > 0);

        // The same from the file alone.
        tree.close()?;
        let mut tree = DiskBTree::open(pool_over(mem.clone(), frames))?;
        expect_edge_keys(&mut tree, &model)?;

        // Overwriting the empty key and the longest key changes only them.
        let all_ff = [0xFFu8; btree::MAX_KEY_LEN];
        tree.put(b"", b"empty key, new value")?;
        model.put(b"", b"empty key, new value");
        tree.put(&all_ff, b"")?;
        model.put(&all_ff, b"");
        expect_edge_keys(&mut tree, &model)?;
    }
    Ok(())
}

/// FNV-1a, 64 bits: small enough to write out twice, and any change of one
/// byte of the file changes it.
fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, &b| {
        (hash ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[test]
fn the_file_is_the_format_a_fixed_run_of_puts_gives_the_same_bytes_in_zig_and_in_rust() -> TestResult
{
    // The constants below are also in tests.zig. If a change to the tree, the
    // slotted page or the pool moves one byte of the file, this test fails
    // in the language that changed; change both or neither.
    assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);

    let mem = MemStorage::new();
    let mut model = Model::new();
    let mut tree = create_mem(&mem, 3);

    put_edge_keys(&mut tree, &mut model)?;
    tree.close()?;
    let mut tree = DiskBTree::open(pool_over(mem.clone(), 3))?;
    let mut rng = SplitMix64::new(12);
    for _ in 0..400 {
        let key = workload::key_for(rng.below(250), 40);
        let value = workload::random_value(&mut rng, 300);
        tree.put(&key, &value)?;
        model.put(&key, &value);
    }
    tree.flush()?;
    expect_same_content(&mut tree, &model)?;

    assert_eq!(tree.pool().pager().page_count(), 71);
    assert_eq!(tree.key_count(), 478);
    assert_eq!(mem.bytes().len(), 71 * btree::PAGE_SIZE);
    assert_eq!(fnv1a64(&mem.bytes()), 0x27e1_691c_5290_7390);
    Ok(())
}

#[test]
fn validate_detects_each_kind_of_damage() -> TestResult {
    let set_link = |page: &mut SlottedPage, id: u32| {
        page.user_area_mut()[..4].copy_from_slice(&id.to_le_bytes())
    };
    let cases = [
        ("link", Violation::LeafChainBroken),
        ("bounds", Violation::KeyOutOfBounds),
        ("count", Violation::KeyCountMismatch),
        ("orphan", Violation::UnreachablePage),
        ("twice", Violation::PageReachedTwice),
        ("zeroed", Violation::BadPage),
        ("emptied", Violation::EmptyPage),
        ("depth", Violation::UnevenDepth),
    ];
    for (damage, want) in cases {
        let mem = MemStorage::new();
        let mut tree = build_scenario(&mem);
        // In the scenario tree page 1 is the root, page 2 the leftmost leaf
        // and page 7 the leaf after it (see expected_output.txt).
        match damage {
            "link" => {
                let pool = tree.pool_mut();
                set_link(&mut SlottedPage::open(pool.fetch_page(2)?), 3); // skips page 7
                pool.unpin(2, true);
            }
            "bounds" => {
                let pool = tree.pool_mut();
                let mut leaf = SlottedPage::open(pool.fetch_page(7)?);
                leaf.put(b"99", b"far too large for this leaf")
                    .expect("fits");
                pool.unpin(7, true);
            }
            "count" => {
                // The key count is private here: write a metapage with a
                // wrong count and open the file again.
                tree.close()?;
                let mut pool = pool_over(mem.clone(), 8);
                pool.fetch_page(0)?[24] += 1;
                pool.unpin(0, true);
                tree = DiskBTree::open(pool)?;
            }
            "orphan" => {
                let pool = tree.pool_mut();
                let (id, _) = pool.new_page()?;
                pool.unpin(id, false);
            }
            "twice" => {
                let pool = tree.pool_mut();
                set_link(&mut SlottedPage::open(pool.fetch_page(1)?), 2); // rightmost child = first child
                pool.unpin(1, true);
            }
            "zeroed" => {
                let pool = tree.pool_mut();
                pool.fetch_page(7)?.fill(0);
                pool.unpin(7, true);
            }
            "emptied" => {
                let pool = tree.pool_mut();
                let mut leaf = SlottedPage::open(pool.fetch_page(7)?);
                while leaf.count() > 0 {
                    leaf.delete_at(0);
                }
                pool.unpin(7, true);
            }
            _ => {
                // Turn leaf 2 into an interior page over two new leaves that
                // hold its keys: every invariant holds except T4.
                let pool = tree.pool_mut();
                let (a, _) = pool.new_page()?;
                let (b, _) = pool.new_page()?;
                let old = *pool.fetch_page(2)?;
                *pool.page_mut(a) = old;
                *pool.page_mut(b) = old;
                let mut left = SlottedPage::open(pool.page_mut(a));
                while left.count() > 3 {
                    left.delete_at(3);
                }
                set_link(&mut left, b);
                let mut right = SlottedPage::open(pool.page_mut(b));
                for _ in 0..3 {
                    right.delete_at(0);
                }
                let sep = right.key(0).to_vec();
                let mut parent = SlottedPage::init_reserved(pool.page_mut(2), btree::RESERVED_TAIL);
                parent.set_kind(btree::KIND_INTERIOR);
                set_link(&mut parent, b);
                parent.insert_at(0, &sep, &a.to_le_bytes()).expect("fits");
                for id in [2, a, b] {
                    pool.unpin(id, true);
                }
            }
        }
        assert_eq!(tree.validate(), Err(TreeError::Invalid(want)), "{damage}");
        assert_eq!(tree.pool().pinned_frames(), 0);
    }
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
    tree.put(b"k", b"v")?;
    tree.close()?;
    assert_eq!(
        DiskBTree::create(pool_over(mem.clone(), 4)).err(),
        Some(TreeError::NotEmpty)
    );

    // Damage the metapage in four ways; each time `open` must refuse.
    let patches = [
        (0, b'X', TreeError::BadMagic),
        (8, 9, TreeError::UnsupportedVersion),
        (16, 77, TreeError::Corrupt), // root page id outside the file
        (20, 99, TreeError::Corrupt), // more pages than the file has
    ];
    for (offset, byte, want) in patches {
        let mut pool = pool_over(mem.clone(), 4);
        pool.fetch_page(0)?[offset] = byte;
        pool.unpin(0, false); // only the cached copy is damaged
        assert_eq!(DiskBTree::open(pool).err(), Some(want));
    }
    let mut tree = DiskBTree::open(pool_over(mem.clone(), 4))?;
    assert_eq!(tree.get(b"k")?.as_deref(), Some(&b"v"[..]));
    assert_eq!(tree.pool().pinned_frames(), 0);
    Ok(())
}

#[test]
fn every_tree_page_keeps_its_last_four_bytes_free_for_a_checksum() -> TestResult {
    let mem = MemStorage::new();
    build_scenario(&mem).close()?;
    let bytes = mem.bytes();
    assert_eq!(bytes.len(), 8 * btree::PAGE_SIZE);
    for page in bytes.chunks(btree::PAGE_SIZE) {
        assert_eq!(
            page[btree::PAGE_SIZE - btree::RESERVED_TAIL as usize..],
            [0, 0, 0, 0]
        );
    }
    assert_eq!(&bytes[..8], btree::MAGIC);
    Ok(())
}

#[test]
fn a_split_interrupted_between_page_writes_leaves_a_broken_file() -> TestResult {
    // The same experiment as part 4 of the demo, with the outcomes pinned.
    let before = demo::crash_during_split(0)?;
    assert!(!before.completed && before.validate_error.is_none());
    assert_eq!(before.old_keys_readable, demo::CRASH_PUT);
    assert!(!before.new_key_readable); // the old tree, untouched

    let mut broken = 0;
    let mut lost_keys = 0;
    let mut writes = 1;
    let after = loop {
        let o = demo::crash_during_split(writes)?;
        if o.completed {
            break o;
        }
        assert_eq!(o.open_error, None);
        // Neither the tree before the put nor the tree after it:
        assert!(o.validate_error.is_some());
        broken += 1;
        if o.old_keys_readable < demo::CRASH_PUT {
            lost_keys += 1;
        }
        writes += 1;
    };
    assert_eq!(writes, 5); // allocation + metapage + three tree pages
    assert_eq!(broken, 4);
    assert_eq!(lost_keys, 2); // keys that were safely on disk are gone
    assert!(after.validate_error.is_none() && after.new_key_readable);
    assert_eq!(after.old_keys_readable, demo::CRASH_PUT);
    Ok(())
}
