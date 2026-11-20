//! Tests of the B-link tree. Deterministic first: the interesting states of
//! a concurrent split are reached WITHOUT threads, through two hooks:
//!
//!   * `set_abandon_splits(true)` makes a writer stop between step 1 and
//!     step 2 of a split, leaving the state a crashed or failed writer leaves;
//!   * `Descent::step` runs a search one node at a time, so a test can put a
//!     complete split between "read the parent" and "visit the child".
//!
//! Only the last tests use threads, and they assert nothing about timing.

use crate::base_handle::{NodeId, OutOfNodes};
use crate::blink::BLinkTree;
use crate::dump;
use crate::ops::{Config, Op, OpStream, Oracle, Weights};
use crate::prng::SplitMix64;
use crate::search::{Descent, Mode, Step};
use crate::stress;
use crate::validate::Violation;

const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

fn id(i: usize) -> NodeId {
    NodeId::from_index(i)
}

fn build_canonical(capacity: usize) -> BLinkTree {
    let tree = BLinkTree::new(4, capacity);
    for key in CANONICAL {
        assert_eq!(tree.put(key, key * 100), Ok(None));
    }
    tree.validate().unwrap();
    tree
}

/// The canonical keys plus some more.
fn canonical_and(extra: &[u64]) -> Vec<u64> {
    let mut keys = CANONICAL.to_vec();
    keys.extend_from_slice(extra);
    keys
}

fn dump_string(tree: &BLinkTree) -> String {
    let mut out = Vec::new();
    dump::dump(tree, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

/// Every key answers with `key * 100` when right links are followed.
fn expect_all_found(tree: &BLinkTree, keys: &[u64]) {
    for &key in keys {
        assert_eq!(tree.get(key), Some(key * 100));
    }
}

/// No latch is held on any node: every one can be taken exclusively.
fn expect_no_latch_held(tree: &BLinkTree) {
    for slot in &tree.slots[..tree.node_count()] {
        assert!(slot.try_write().is_ok());
    }
}

#[test]
fn canonical_build_has_the_shape_of_chapter_07_plus_high_keys_and_right_links() {
    let tree = build_canonical(16);
    assert_eq!(
        dump_string(&tree),
        "height 3, 12 keys, 8 nodes\n\
         \x20 level 2: #7[15]\n\
         \x20 level 1: #2[6 10]<15 -> #6[20]\n\
         \x20 level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25 30)\n"
    );
    assert_eq!(tree.incomplete_splits(), 0);
    assert_eq!(tree.get(13), None);
    assert_eq!(tree.put(12, 1201), Ok(Some(1200))); // overwrite returns the old value
    assert_eq!(tree.get(12), Some(1201));
    assert_eq!(tree.len(), 12);
}

#[test]
fn paused_between_step_1_and_step_2_every_key_is_found_by_moving_right() {
    let tree = build_canonical(16);

    tree.set_abandon_splits(true);
    assert_eq!(tree.put(26, 2600), Ok(None)); // splits leaf #3, step 1 only
    tree.set_abandon_splits(false);

    // The half-finished state is a VALID state of the tree.
    tree.validate().unwrap();
    assert_eq!(tree.incomplete_splits(), 1);
    {
        let left = tree.read(id(3));
        assert!(left.incomplete_split);
        assert_eq!(left.right, id(8));
        assert_eq!(left.high_key, Some(26));
    }
    // The parent level has not been touched.
    assert_eq!(tree.read(id(6)).node.key_slice(), [20]);
    assert_eq!(tree.stats().half_splits - tree.stats().completed_splits, 1);

    expect_all_found(&tree, &canonical_and(&[26]));
    // Keys in the right half are reached through the right link ...
    for key in [26, 30] {
        assert_eq!(tree.lookup(key, Mode::FollowRightLinks).moves_right, 1);
    }
    // ... keys in the left half are not affected.
    assert_eq!(tree.lookup(25, Mode::FollowRightLinks).moves_right, 0);
    expect_no_latch_held(&tree);
}

#[test]
fn the_same_state_with_move_right_disabled_misses_exactly_the_moved_keys() {
    let tree = build_canonical(16);
    tree.set_abandon_splits(true);
    tree.put(26, 2600).unwrap();
    tree.set_abandon_splits(false);

    let missed: Vec<u64> = canonical_and(&[26])
        .into_iter()
        .filter(|&key| tree.lookup(key, Mode::IgnoreRightLinks).value.is_none())
        .collect();
    // 30 was in the tree long before the split began, and is now invisible.
    assert_eq!(missed, [30, 26]);
}

#[test]
fn an_insert_that_meets_the_flag_finishes_the_split_before_its_own_work() {
    let tree = build_canonical(16);
    tree.set_abandon_splits(true);
    tree.put(26, 2600).unwrap();
    tree.set_abandon_splits(false);

    // A writer that never latches the flagged node does not finish anything.
    tree.put(2, 200).unwrap();
    assert_eq!(tree.incomplete_splits(), 1);
    assert_eq!(tree.stats().finished_later, 0);

    // 27 belongs to the right half #8. The writer is sent to #3 (the only
    // node with a downlink), sees the flag, finishes, then moves right.
    tree.put(27, 2700).unwrap();
    tree.validate().unwrap();
    assert_eq!(tree.incomplete_splits(), 0);
    assert_eq!(tree.stats().finished_later, 1);
    assert_eq!(tree.read(id(6)).node.key_slice(), [20, 26]);
    assert_eq!(tree.read(id(6)).node.child_slice(), [id(5), id(3), id(8)]);
    assert_eq!(tree.read(id(8)).node.key_slice(), [26, 27, 30]);

    // With the downlink in place even the broken search finds everything.
    for key in canonical_and(&[2, 26, 27]) {
        assert_eq!(
            tree.lookup(key, Mode::IgnoreRightLinks).value,
            Some(key * 100)
        );
    }
    expect_no_latch_held(&tree);
}

#[test]
fn a_reader_overtaken_by_a_complete_split_recovers_by_moving_right() {
    let tree = build_canonical(16);

    // The reader reads the root and the level-1 node. It now knows "30 is in
    // leaf #3" and holds no latch at all.
    let mut reader = Descent::begin(&tree, 30, Mode::FollowRightLinks);
    let step = reader.step(&tree);
    assert!(matches!(step, Step::Descended { to, .. } if to == id(6)));
    expect_no_latch_held(&tree); // one latch at a time means none in between
    let step = reader.step(&tree);
    assert!(matches!(step, Step::Descended { to, .. } if to == id(3)));
    expect_no_latch_held(&tree);

    // A writer splits #3 completely (both steps): 30 moves to the new #8.
    tree.put(26, 2600).unwrap();
    assert_eq!(tree.incomplete_splits(), 0);

    // The reader's knowledge is stale. The high key of #3 tells it so.
    assert_eq!(
        reader.step(&tree),
        Step::MovedRight {
            from: id(3),
            to: id(8),
            high_key: 26
        }
    );
    assert_eq!(
        reader.step(&tree),
        Step::Done {
            leaf: id(8),
            value: Some(3000)
        }
    );

    // The same interleaving without right links: wrong answer, no error.
    let mut broken = Descent::begin(&tree, 30, Mode::IgnoreRightLinks);
    broken.step(&tree);
    let step = broken.step(&tree);
    assert!(matches!(step, Step::Descended { to, .. } if to == id(8)));
    tree.put(27, 2700).unwrap(); // #8 = (26 27 30), full
    tree.put(28, 2800).unwrap(); // splits #8: 28 and 30 move to #9
    assert_eq!(
        broken.step(&tree),
        Step::Done {
            leaf: id(8),
            value: None
        }
    );
    assert_eq!(tree.get(30), Some(3000));
}

#[test]
fn a_reader_that_starts_at_an_old_root_still_finds_everything() {
    let tree = BLinkTree::new(4, 8);
    for key in [1, 2, 3] {
        tree.put(key, key * 100).unwrap();
    }

    // Reads the root pointer (#0) and is then overtaken by a root split.
    let mut reader = Descent::begin(&tree, 4, Mode::FollowRightLinks);
    tree.put(4, 400).unwrap();
    assert_eq!(tree.height(), 2);
    assert_eq!(tree.root_id(), id(2));
    let step = reader.step(&tree);
    assert!(matches!(step, Step::MovedRight { to, .. } if to == id(1)));
    let step = reader.step(&tree);
    assert!(matches!(
        step,
        Step::Done {
            value: Some(400),
            ..
        }
    ));
}

#[test]
fn a_root_split_paused_after_step_1_then_finished_by_the_next_writer() {
    let tree = BLinkTree::new(4, 8);
    for key in [1, 2, 3] {
        tree.put(key, key * 100).unwrap();
    }
    tree.set_abandon_splits(true);
    tree.put(4, 400).unwrap();
    tree.set_abandon_splits(false);

    tree.validate().unwrap();
    assert_eq!(
        dump_string(&tree),
        "height 1, 4 keys, 2 nodes\n\
         \x20 level 0: #0(1 2)<3 {incomplete} -> #1(3 4) {no downlink}\n"
    );
    expect_all_found(&tree, &[1, 2, 3, 4]);
    assert_eq!(tree.lookup(4, Mode::IgnoreRightLinks).value, None);

    tree.put(5, 500).unwrap();
    tree.validate().unwrap();
    assert_eq!(
        dump_string(&tree),
        "height 2, 5 keys, 3 nodes\n\
         \x20 level 1: #2[3]\n\
         \x20 level 0: #0(1 2)<3 -> #1(3 4 5)\n"
    );
    assert_eq!(tree.stats().finished_later, 1);
}

#[test]
fn an_internal_node_paused_after_step_1() {
    let tree = BLinkTree::new(3, 256);
    // Order 3: two keys per node. Ascending inserts with the hook always on:
    // every put first finishes the previous half split, and that step 2 is
    // what overflows a parent and leaves an INTERNAL node half split.
    tree.set_abandon_splits(true);
    let mut seen_internal = false;
    for key in 1..=40u64 {
        tree.put(key, key * 100).unwrap();
        tree.validate().unwrap();
        for k in 1..=key {
            assert_eq!(tree.get(k), Some(k * 100));
        }
        for slot in &tree.slots[..tree.node_count()] {
            let page = slot.read().unwrap();
            if page.level > 0 && page.incomplete_split {
                seen_internal = true;
            }
        }
    }
    assert!(seen_internal);
    assert!(tree.stats().finished_later > 0);

    // Hook off: ordinary inserts clean up every flag they pass.
    tree.set_abandon_splits(false);
    for key in 41..=60u64 {
        tree.put(key, key * 100).unwrap();
    }
    tree.validate().unwrap();
    assert_eq!(tree.incomplete_splits(), 0);
    for k in 1..=60u64 {
        assert_eq!(tree.get(k), Some(k * 100));
    }
    expect_no_latch_held(&tree);
}

#[test]
fn a_full_node_table_put_fails_cleanly_or_leaves_a_legal_incomplete_split() {
    let mut saw_incomplete = false;
    let mut saw_clean_failure = false;
    // Every table size from 1 to 40 nodes: the table runs out at a leaf
    // split, at an internal split and at a root split in turn.
    for capacity in 1..=40usize {
        let tree = BLinkTree::new(4, capacity);
        let mut inserted = 0u64;
        let mut ran_out = false;
        for key in 0..400u64 {
            let before = tree.len();
            match tree.put(key, key * 100) {
                Ok(old) => {
                    assert_eq!(old, None);
                    inserted += 1;
                }
                Err(OutOfNodes) => {
                    // The contract of the error: nothing was inserted.
                    assert_eq!(tree.len(), before);
                    assert_eq!(tree.get(key), None);
                    saw_clean_failure = true;
                    ran_out = true;
                    break;
                }
            }
        }
        assert!(ran_out); // the table did run out
        tree.validate().unwrap();
        assert_eq!(tree.len(), inserted);
        assert_eq!(tree.node_count(), capacity);
        for k in 0..inserted {
            assert_eq!(tree.get(k), Some(k * 100));
        }
        // A put succeeded although the PARENT could not be split: the key is
        // in, and the leaf split simply stays incomplete.
        if tree.incomplete_splits() > 0 {
            saw_incomplete = true;
        }
        // Overwrites need no node and still work, unless the leaf is flagged
        // and cannot be finished.
        if let Ok(old) = tree.put(0, 1) {
            assert_eq!(old, Some(0));
        }
        tree.validate().unwrap();
        expect_no_latch_held(&tree);
    }
    assert!(saw_clean_failure);
    assert!(saw_incomplete);
}

/// Zig's twin of this test injects allocation failures into `init` and
/// proves that `put` never calls the allocator. Rust aborts on a failed
/// allocation, so the same fact is shown from the other side: the table is a
/// boxed slice that cannot grow, and it is the same memory before and after.
#[test]
fn the_only_allocation_is_the_node_table_put_never_allocates() {
    let tree = BLinkTree::new(4, 16);
    let table = tree.slots.as_ptr();
    for key in CANONICAL {
        tree.put(key, key).unwrap();
    }
    tree.validate().unwrap();
    assert_eq!(tree.capacity(), 16);
    assert_eq!(tree.slots.as_ptr(), table);
}

#[test]
fn validate_names_the_broken_invariant() {
    let tree = build_canonical(16);
    tree.set_abandon_splits(true);
    tree.put(26, 2600).unwrap();
    tree.set_abandon_splits(false);
    tree.validate().unwrap();

    // The flag is the only thing that excuses #8's missing downlink.
    tree.write(id(3)).incomplete_split = false;
    assert_eq!(tree.validate(), Err(Violation::MissingDownlink));
    tree.write(id(3)).incomplete_split = true;

    // A high key that does not bound the keys of the node.
    tree.write(id(3)).high_key = Some(25);
    assert_eq!(tree.validate(), Err(Violation::KeyOutOfBounds));
    tree.write(id(3)).high_key = Some(26);

    // A right link without a high key.
    tree.write(id(3)).high_key = None;
    assert_eq!(tree.validate(), Err(Violation::BrokenRightLink));
    tree.write(id(3)).high_key = Some(26);

    // A flag on the rightmost node of a level has nothing to point at.
    tree.write(id(8)).incomplete_split = true;
    assert_eq!(tree.validate(), Err(Violation::BadSplitFlag));
    tree.write(id(8)).incomplete_split = false;

    // A separator that disagrees with the child's lower bound.
    tree.write(id(6)).node.keys[0] = 19;
    assert_eq!(tree.validate(), Err(Violation::SeparatorMismatch));
    tree.write(id(6)).node.keys[0] = 20;

    tree.count
        .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    assert_eq!(tree.validate(), Err(Violation::WrongCount));
    tree.count
        .fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
    tree.validate().unwrap();
}

#[test]
fn model_test_seeded_puts_and_gets_against_the_oracle_splits_abandoned_by_a_seeded_coin() {
    for order in [3usize, 4, 5, 16] {
        let tree = BLinkTree::new(order, 2048);
        let mut oracle = Oracle::new();
        let stream = OpStream::new(Config {
            seed: 20 + order as u64,
            count: 6000,
            key_space: 700,
            weights: Weights {
                put: 4,
                delete: 0,
                get: 3,
                range: 0,
            },
        });
        let mut coin = SplitMix64::new(order as u64);
        for (n, op) in stream.enumerate() {
            match op {
                Op::Put { key, value } => {
                    tree.set_abandon_splits(coin.chance(1, 3));
                    assert_eq!(tree.put(key, value), Ok(oracle.put(key, value)));
                }
                Op::Get { key } => assert_eq!(tree.get(key), oracle.get(key)),
                Op::Delete { .. } | Op::Range { .. } => unreachable!(),
            }
            if n % 64 == 0 {
                tree.validate().unwrap();
            }
        }
        tree.validate().unwrap();
        assert_eq!(tree.len(), oracle.len() as u64);
        for e in oracle.range(0, u64::MAX) {
            assert_eq!(tree.get(e.key), Some(e.value));
        }
        let s = tree.stats();
        assert!(s.finished_later > 0 && s.moves_right > 0);
        assert_eq!(
            s.half_splits - s.completed_splits,
            tree.incomplete_splits() as u64
        );
    }
}

#[test]
fn stress_4_threads_normal_splits() {
    let r = stress::run(&stress::Config {
        order: 4,
        threads: stress::MAX_THREADS,
        puts_per_thread: 5000,
        key_space: 8000,
        preload: 500,
        seed: 1,
        capacity: 8192,
        abandon_splits: false,
    });
    assert_eq!(
        r,
        stress::Report {
            keys: r.expected_keys,
            expected_keys: r.expected_keys,
            valid: true,
            ..Default::default()
        }
    );
    assert!(r.keys > 500);
}

#[test]
fn stress_4_threads_every_split_abandoned_and_finished_by_another_writer() {
    for order in [3usize, 4, 16] {
        let mut r = stress::run(&stress::Config {
            order,
            threads: stress::MAX_THREADS,
            puts_per_thread: 3000,
            key_space: 5000,
            preload: 200,
            seed: 2 + order as u64,
            capacity: 16384,
            abandon_splits: true,
        });
        // How many flags are left depends on the interleaving.
        r.incomplete_splits = 0;
        assert_eq!(
            r,
            stress::Report {
                keys: r.expected_keys,
                expected_keys: r.expected_keys,
                valid: true,
                ..Default::default()
            }
        );
    }
}
