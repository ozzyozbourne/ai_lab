//! Tests of the B-link tree. Deterministic first: the interesting states of
//! a concurrent split are reached WITHOUT threads, through three hooks:
//!
//!   * `set_abandon_splits(true)` makes a writer stop between step 1 and
//!     step 2 of a split, leaving the state a crashed or failed writer leaves;
//!   * `Descent::step` runs a search one node at a time, so a test can put a
//!     complete split between "read the parent" and "visit the child";
//!   * `put_from` starts a writer at a former root and can pause it on its
//!     leaf (`Pause`), so a test can split, half-split or outgrow the
//!     parents that writer remembers before it climbs back up.
//!
//! Only the last tests use threads, and they assert nothing about timing.

use crate::base_handle::{NodeId, OutOfNodes};
use crate::blink::{BLinkTree, Page};
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
// ---------------------------------------------------------------------
// Stale WRITERS. A reader goes stale between two nodes; a writer goes stale
// between its way down and its way up: the parents it remembers may have
// split, been left half split, or stopped being the top of the tree. The
// second hook, `put_from` with a `Pause`, stops one writer on its leaf and
// lets the test run other writers in that gap. Still one thread, no sleeps.
// ---------------------------------------------------------------------

/// Order 3 (two keys per node): a root with three FULL leaves, so that one
/// more key anywhere splits a leaf and the next split splits the root.
fn build_three_full_leaves() -> BLinkTree {
    let tree = BLinkTree::new(3, 16);
    for key in [10, 20, 30, 40, 15, 25] {
        tree.put(key, key * 100).unwrap();
    }
    assert_eq!(
        dump_string(&tree),
        "height 2, 6 keys, 4 nodes\n\
         \x20 level 1: #2[20 30]\n\
         \x20 level 0: #0(10 15)<20 -> #1(20 25)<30 -> #3(30 40)\n"
    );
    tree
}

#[test]
fn a_paused_writer_whose_parent_split_meanwhile_re_finds_the_downlink_by_moving_right() {
    let tree = build_three_full_leaves();

    let mut others = |t: &BLinkTree, leaf_id: NodeId, leaf: &Page| {
        // The paused writer holds exactly its leaf, exclusively.
        assert!(leaf_id == id(3) && leaf.node.len == 2 && t.slots[3].try_write().is_err());
        // Another writer splits leaf #0. Its downlink overflows #2, the
        // node the paused writer remembers as "my parent" and as "the
        // root". #2 splits; the downlink to #3 moves into the new #5.
        t.put(12, 1200).unwrap();
    };
    // put 32 goes down #2 -> #3 and is paused there. #3 is full: it will split.
    assert_eq!(
        tree.put_from(tree.root_id(), 32, 3200, Some(&mut others)),
        Ok(None)
    );

    // Step 2 for #3 started at the remembered #2, did not find #3 among its
    // children, moved right to #5 and inserted (32, #7) there.
    tree.validate().unwrap();
    assert_eq!(
        dump_string(&tree),
        "height 3, 8 keys, 8 nodes\n\
         \x20 level 2: #6[20]\n\
         \x20 level 1: #2[12]<20 -> #5[30 32]\n\
         \x20 level 0: #0(10)<12 -> #4(12 15)<20 -> #1(20 25)<30 -> #3(30)<32 -> #7(32 40)\n"
    );
    assert_eq!(tree.incomplete_splits(), 0);
    expect_all_found(&tree, &[10, 12, 15, 20, 25, 30, 32, 40]);
    expect_no_latch_held(&tree);
}

#[test]
fn two_paused_writers_a_half_split_parent_and_a_grown_root_finish_first_then_find_the_parent_level()
 {
    let tree = build_three_full_leaves();

    // Three writers. The first is paused on leaf #0, the second on leaf #1,
    // and the third runs to the end while both stand still.
    let mut third = |t: &BLinkTree, _: NodeId, _: &Page| {
        t.set_abandon_splits(true);
        t.put(35, 3500).unwrap(); // leaf #3 splits, step 1 only: #3 -> #4
        // 31 is routed to the flagged #3. Finishing that split puts a
        // third key into the root #2, which splits, step 1 only.
        t.put(31, 3100).unwrap();
        t.set_abandon_splits(false);
        // #2 is still the root, is flagged, and has a right sibling #5
        // that nothing points down to.
        assert!(t.root_id() == id(2) && t.read(id(2)).incomplete_split);
        assert!(t.read(id(2)).right == id(5) && t.incomplete_splits() == 1);
    };
    let mut second = |t: &BLinkTree, _: NodeId, _: &Page| {
        // put 22: paused on #1 while the third writer runs. Afterwards
        // #1 splits. Its remembered parent #2 is flagged: the split of
        // #2 is finished first (that builds the new root #7), and only
        // then does #2 receive the downlink (22, #6).
        t.put_from(t.root_id(), 22, 2200, Some(&mut third)).unwrap();
        assert!(t.root_id() == id(7) && t.incomplete_splits() == 0);
        assert_eq!(t.stats().finished_later, 2); // #3 by the third writer, #2 by the second
    };
    // put 12: paused on #0. When it started, #2 was the root, so it remembers
    // no node above #2.
    assert_eq!(
        tree.put_from(tree.root_id(), 12, 1200, Some(&mut second)),
        Ok(None)
    );

    // After the pause #0 splits. Its downlink is the third key for #2, so #2
    // splits again, and step 2 of THAT split has no remembered parent. #2 is
    // not the root any more: the parent level is found through level_head.
    tree.validate().unwrap();
    assert_eq!(
        dump_string(&tree),
        "height 3, 10 keys, 10 nodes\n\
         \x20 level 2: #7[20 30]\n\
         \x20 level 1: #2[12]<20 -> #9[22]<30 -> #5[35]\n\
         \x20 level 0: #0(10)<12 -> #8(12 15)<20 -> #1(20)<22 -> #6(22 25)<30 -> #3(30 31)<35 -> #4(35 40)\n"
    );
    assert_eq!(tree.incomplete_splits(), 0);
    expect_all_found(&tree, &[10, 12, 15, 20, 22, 25, 30, 31, 35, 40]);
    expect_no_latch_held(&tree);
}

#[test]
fn a_writer_that_starts_at_an_old_root_moves_right_then_finds_the_parent_level_through_level_head()
 {
    let tree = BLinkTree::new(4, 8);
    for key in [1, 2, 3] {
        tree.put(key, key * 100).unwrap();
    }

    // A writer loads the root pointer: #0, a leaf. Before it latches
    // anything, two other puts split #0 and build the root #2.
    let old_root = tree.root_id();
    for key in [4, 5] {
        tree.put(key, key * 100).unwrap();
    }
    assert_eq!(tree.root_id(), id(2));
    assert_eq!(tree.meta_snapshot().level_head[0], id(0));

    // The writer continues from #0: move right to #1(3 4 5), which is full.
    // It splits. The writer came through no node of level 1 and #1 is not
    // the root, so step 2 starts at level_head[1]. It must NOT build a root.
    let before = tree.stats().moves_right;
    assert_eq!(tree.put_from(old_root, 6, 600, None), Ok(None));
    assert_eq!(tree.stats().moves_right - before, 1);
    tree.validate().unwrap();
    assert_eq!(
        dump_string(&tree),
        "height 2, 6 keys, 4 nodes\n\
         \x20 level 1: #2[3 5]\n\
         \x20 level 0: #0(1 2)<3 -> #1(3 4)<5 -> #3(5 6)\n"
    );
    expect_all_found(&tree, &[1, 2, 3, 4, 5, 6]);
    expect_no_latch_held(&tree);
}

#[test]
fn moving_right_on_an_internal_level_a_stale_reader_and_a_stale_writer() {
    let tree = build_canonical(32);
    // #6 = [20 26 28] is full, and so is its last leaf #9(28 30 32).
    for key in [26, 27, 28, 32] {
        tree.put(key, key * 100).unwrap();
    }

    // The reader reads the root and is told "#6". It holds nothing.
    let mut reader = Descent::begin(&tree, 32, Mode::FollowRightLinks);
    let step = reader.step(&tree);
    assert!(matches!(step, Step::Descended { to, .. } if to == id(6)));
    // put 31 splits leaf #9, and that splits #6 into #6[20 26]<28 -> #11[31].
    tree.put(31, 3100).unwrap();
    assert_eq!(
        dump_string(&tree),
        "height 3, 17 keys, 12 nodes\n\
         \x20 level 2: #7[15 28]\n\
         \x20 level 1: #2[6 10]<15 -> #6[20 26]<28 -> #11[31]\n\
         \x20 level 0: #0(1 3 5)<6 -> #4(6 7)<10 -> #1(10 12)<15 -> #5(15 17)<20 -> #3(20 25)<26 -> #8(26 27)<28 -> #9(28 30)<31 -> #10(31 32)\n"
    );
    // The reader's next node is the INTERNAL node #6, and 32 >= 28.
    assert_eq!(
        reader.step(&tree),
        Step::MovedRight {
            from: id(6),
            to: id(11),
            high_key: 28
        }
    );
    assert_eq!(tree.read(id(6)).level, 1);
    let step = reader.step(&tree);
    assert!(matches!(step, Step::Descended { to, .. } if to == id(10)));
    assert_eq!(
        reader.step(&tree),
        Step::Done {
            leaf: id(10),
            value: Some(3200)
        }
    );
    assert_eq!(reader.moves_right, 1);

    // A writer that loaded the root pointer when #2 was the root (it is the
    // leftmost node of level 1): two hops on level 1, none on the leaves.
    // Without the internal hops it would still arrive, by descending from
    // #2 into leaf #1 and walking five leaves to the right: moving right on
    // the leaf level is what makes the search correct, moving right on the
    // internal levels is what keeps the walk short.
    assert_eq!(tree.meta_snapshot().level_head[1], id(2));
    let before = tree.stats().moves_right;
    assert_eq!(tree.put_from(id(2), 33, 3300, None), Ok(None));
    assert_eq!(tree.stats().moves_right - before, 2);
    assert_eq!(tree.get(33), Some(3300));
    tree.validate().unwrap();
}

/// State of the seeded test below, borrowed by the callback.
struct PausedModel {
    rng: SplitMix64,
    present: Vec<bool>,
    /// Puts the other writers make during the next pause.
    others: u64,
    hook_runs: usize,
}

impl PausedModel {
    const KEY_SPACE: u64 = 300;

    fn value(key: u64) -> u64 {
        key * 100 + 1
    }

    fn put(&mut self, tree: &BLinkTree, key: u64) {
        tree.put(key, Self::value(key)).unwrap();
        self.present[key as usize] = true;
    }

    fn at_leaf(&mut self, tree: &BLinkTree, leaf_id: NodeId, leaf: &Page) {
        self.hook_runs += 1;
        // The key range of the latched leaf: its lower bound is the high key
        // of its left neighbour, found by walking the leaf level.
        let mut low = 0;
        let mut at = tree.meta_snapshot().level_head[0];
        while at != leaf_id {
            let page = tree.read(at);
            low = page.high_key.unwrap();
            at = page.right;
        }
        let high = leaf.high_key.unwrap_or(u64::MAX);
        for _ in 0..self.others {
            let key = self.rng.below(Self::KEY_SPACE);
            if key >= low && key < high {
                continue; // would wait for the paused writer
            }
            tree.set_abandon_splits(self.rng.chance(1, 2));
            self.put(tree, key);
        }
        tree.set_abandon_splits(false);
    }
}

#[test]
fn model_test_with_paused_writers_stale_parents_flagged_parents_old_roots_seeded() {
    let mut level_head_starts = 0;
    for order in [3, 4, 5] {
        for seed in 1..=40 {
            let tree = BLinkTree::new(order, 1024);
            let mut model = PausedModel {
                rng: SplitMix64::new(seed * 977 + order as u64),
                present: vec![false; PausedModel::KEY_SPACE as usize],
                others: 0,
                hook_runs: 0,
            };
            for _ in 0..model.rng.below(40) {
                tree.set_abandon_splits(model.rng.chance(1, 3));
                let key = model.rng.below(PausedModel::KEY_SPACE);
                model.put(&tree, key);
            }
            tree.set_abandon_splits(false);
            for _ in 0..25 {
                let key = model.rng.below(PausedModel::KEY_SPACE);
                // Start at the root, or at any node that was the root once.
                let meta = tree.meta_snapshot();
                let level = model.rng.below(meta.height as u64) as usize;
                if level + 1 < meta.height {
                    level_head_starts += 1;
                }
                model.others = model.rng.below(25);
                let mut pause = |t: &BLinkTree, leaf_id: NodeId, leaf: &Page| {
                    model.at_leaf(t, leaf_id, leaf);
                };
                tree.put_from(
                    meta.level_head[level],
                    key,
                    PausedModel::value(key),
                    Some(&mut pause),
                )
                .unwrap();
                model.present[key as usize] = true;
                tree.validate().unwrap();
                for (k, &present) in model.present.iter().enumerate() {
                    let expected = present.then(|| PausedModel::value(k as u64));
                    assert_eq!(tree.get(k as u64), expected);
                }
                expect_no_latch_held(&tree);
            }
            assert_eq!(model.hook_runs, 25);
        }
    }
    assert!(level_head_starts > 0);
}

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
