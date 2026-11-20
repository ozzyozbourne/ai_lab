//! Tests of the top-down insert, always next to the bottom-up one: both must
//! give valid trees that hold the same keys. The shapes may differ.

use crate::base_btree::BTree;
use crate::base_pool::OutOfNodes;
use crate::base_tests_insert::{BUILD_COUNT, CANONICAL_KEYS, build_key, expect_tree};
use crate::ops::{Config, Entry, Op, OpStream, Oracle, Weights};
use crate::topdown;

fn put_all(tree: &mut BTree, keys: &[u64]) {
    for &key in keys {
        topdown::put(tree, key, key * 10).unwrap();
    }
}

#[test]
fn top_down_put_the_canonical_example_step_by_step() {
    let mut tree = BTree::new(4);
    put_all(&mut tree, &[10, 20, 5]);
    expect_tree(&tree, "[5 10 20]\n");
    // The root is full, so it is split BEFORE 6 is placed: 1 + median + 1.
    put_all(&mut tree, &[6]);
    expect_tree(&tree, "[10]\n[5 6] [20]\n");
    put_all(&mut tree, &[12, 30, 7, 17, 3]);
    // Up to here the tree is the one bottom-up builds.
    expect_tree(&tree, "[6 10 20]\n[3 5] [7] [12 17] [30]\n");
    // 25 belongs in the leaf [30], which has room. Bottom-up would just put
    // it there. Top-down meets a full root first and splits it anyway.
    put_all(&mut tree, &[25]);
    expect_tree(&tree, "[10]\n[6] [20]\n[3 5] [7] | [12 17] [25 30]\n");
    put_all(&mut tree, &[1, 15]);
    expect_tree(&tree, "[10]\n[6] [20]\n[1 3 5] [7] | [12 15 17] [25 30]\n");
    assert_eq!(tree.counters.splits, 4);
    assert_eq!(tree.counters.root_splits, 2);
    for key in CANONICAL_KEYS {
        assert_eq!(tree.get(key), Some(key * 10));
    }
}

#[test]
fn top_down_overwrite_returns_the_old_value_also_when_the_key_is_the_median_that_moves_up() {
    let mut tree = BTree::new(4);
    put_all(&mut tree, &[10, 20, 5, 6, 7]);
    expect_tree(&tree, "[10]\n[5 6 7] [20]\n");
    // The leaf [5 6 7] is full, so it is split on the way down; its median 6
    // moves into the root, and 6 is the key being written.
    assert_eq!(topdown::put(&mut tree, 6, 61), Ok(Some(60)));
    expect_tree(&tree, "[6 10]\n[5] [7] [20]\n"); // an overwrite that changed the shape
    assert_eq!(tree.get(6), Some(61));
    assert_eq!(tree.len, 5);
    assert_eq!(topdown::put(&mut tree, 20, 201), Ok(Some(200))); // found in a leaf
    assert_eq!(topdown::put(&mut tree, 10, 101), Ok(Some(100))); // found in the root
}

#[test]
fn the_worked_example_continued_put_2_splits_a_leaf_and_then_the_interior_root() {
    let mut tree = BTree::new(4);
    for key in CANONICAL_KEYS {
        tree.put(key, key * 10).unwrap();
    }
    expect_tree(&tree, "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n");
    let before = tree.counters;
    // Leaf [1 2 3 5]: 3 goes up. Root [3 6 10 20] with five children: 10
    // goes up, [3 6] keeps the first three children, [20] gets the last two.
    assert_eq!(tree.put(2, 20), Ok(None));
    expect_tree(
        &tree,
        "[10]\n[3 6] [20]\n[1 2] [5] [7] | [12 15 17] [25 30]\n",
    );
    assert_eq!(tree.counters.splits - before.splits, 2);
    assert_eq!(tree.counters.root_splits - before.root_splits, 1);
    assert_eq!(tree.validate(), Ok(()));

    // Top-down splits its interior root one put earlier (at 25, in the
    // canonical example above); 2 then splits only the leaf. For these
    // thirteen keys both variants end with the same tree.
    let mut top = BTree::new(4);
    put_all(&mut top, &CANONICAL_KEYS);
    let top_before = top.counters;
    assert_eq!(topdown::put(&mut top, 2, 20), Ok(None));
    expect_tree(
        &top,
        "[10]\n[3 6] [20]\n[1 2] [5] [7] | [12 15 17] [25 30]\n",
    );
    assert_eq!(top.counters.splits - top_before.splits, 1);
    assert_eq!(top.validate(), Ok(()));
}

#[test]
fn exercise_1_ascending_keys_the_first_interior_splits_root_at_13_below_the_root_at_22() {
    let mut tree = BTree::new(4);
    for key in 1..13 {
        tree.put(key, key).unwrap();
    }
    expect_tree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");
    // 13: leaf [10 11 12 13], 12 goes up. Root [3 6 9 12] with five
    // children: 9 goes up, [3 6] keeps three children, [12] gets two.
    let before = tree.counters;
    tree.put(13, 13).unwrap();
    expect_tree(&tree, "[9]\n[3 6] [12]\n[1 2] [4 5] [7 8] | [10 11] [13]\n");
    assert_eq!(tree.counters.splits - before.splits, 2);
    assert_eq!(tree.counters.root_splits - before.root_splits, 1);
    // 14 to 21: two leaf splits (at 16 and 19) fill the interior node [12 15 18].
    for key in 14..22 {
        tree.put(key, key).unwrap();
    }
    expect_tree(
        &tree,
        "[9]\n[3 6] [12 15 18]\n[1 2] [4 5] [7 8] | [10 11] [13 14] [16 17] [19 20 21]\n",
    );
    // 22: leaf [19 20 21 22], 21 goes up. [12 15 18 21] is an interior node
    // that is NOT the root: its median 18 goes into the existing root, which
    // has room. No new root, same height.
    let before = tree.counters;
    tree.put(22, 22).unwrap();
    expect_tree(
        &tree,
        "[9 18]\n[3 6] [12 15] [21]\n[1 2] [4 5] [7 8] | [10 11] [13 14] [16 17] | [19 20] [22]\n",
    );
    assert_eq!(tree.counters.splits - before.splits, 2);
    assert_eq!(tree.counters.root_splits - before.root_splits, 0);
    assert_eq!(tree.validate(), Ok(()));
}

#[test]
fn neither_variant_is_always_the_taller_one() {
    // The canonical keys make the top-down tree taller (height 3 against 2,
    // see the first test of this file). These ten keys make it SHORTER. The
    // two variants cut at different points (bottom-up cuts M keys and leaves
    // M / 2 on the left, top-down cuts M - 1 keys and leaves M / 2 - 1 on
    // each side), so the keys spread over the nodes differently, and the put
    // that overflows the root of one tree does not overflow the other.
    let mut bottom = BTree::new(4);
    let mut top = BTree::new(4);
    for key in [82, 83, 57, 74, 11, 67, 62, 48, 9, 29] {
        bottom.put(key, key).unwrap();
        topdown::put(&mut top, key, key).unwrap();
    }
    expect_tree(
        &bottom,
        "[67]\n[29 57] [82]\n[9 11] [48] [62] | [74] [83]\n",
    );
    expect_tree(&top, "[11 57 82]\n[9] [29 48] [62 67 74] [83]\n");
    assert_eq!(bottom.validate(), Ok(()));
    assert_eq!(top.validate(), Ok(()));
}

#[test]
fn why_top_down_needs_an_even_m_the_arithmetic() {
    // A full node has M - 1 keys; without its median, M - 2 are left for two
    // halves that each need min_keys = ceil(M/2) - 1.
    let min_keys = |m: usize| m.div_ceil(2) - 1;
    for m in [4, 6, 8, 64] {
        assert!((m - 2) / 2 >= min_keys(m));
    }
    for m in [3, 5, 7, 63] {
        assert!((m - 2) / 2 < min_keys(m));
    }
    // Bottom-up splits M keys (the new one included): M - 1 to share, enough for every M.
    for m in [3, 4, 5, 6, 7, 8] {
        assert!((m - 1) / 2 >= min_keys(m));
    }
}

#[test]
#[should_panic(expected = "even order")]
fn top_down_put_on_an_odd_order_panics() {
    // Zig rejects this at compile time; here the order is a run-time value.
    let mut tree = BTree::new(5);
    let _ = topdown::put(&mut tree, 1, 1);
}

/// The same operation stream goes into a bottom-up tree, a top-down tree and
/// the oracle. Every answer must agree and both trees must stay valid.
fn model_test_both_variants(order: usize, seed: u64) {
    let mut bottom = BTree::new(order);
    let mut top = BTree::new(order);
    let mut oracle = Oracle::new();
    let weights = Weights {
        put: 5,
        delete: 0,
        get: 2,
        range: 1,
    };
    for op in OpStream::new(Config {
        seed,
        count: 1500,
        key_space: 400,
        weights,
    }) {
        match op {
            Op::Put { key, value } => {
                let want = oracle.put(key, value);
                assert_eq!(bottom.put(key, value), Ok(want));
                assert_eq!(topdown::put(&mut top, key, value), Ok(want));
            }
            Op::Delete { .. } => unreachable!("weight 0"),
            Op::Get { key } => {
                assert_eq!(bottom.get(key), oracle.get(key));
                assert_eq!(top.get(key), oracle.get(key));
            }
            Op::Range { lo, hi } => {
                let (mut a, mut b) = (Vec::new(), Vec::new());
                bottom.range(lo, hi, |key, value| a.push(Entry { key, value }));
                top.range(lo, hi, |key, value| b.push(Entry { key, value }));
                assert_eq!(a, oracle.range(lo, hi));
                assert_eq!(b, oracle.range(lo, hi));
            }
        }
        assert_eq!(top.len, oracle.len());
        assert_eq!(bottom.validate(), Ok(()));
        assert_eq!(top.validate(), Ok(())); // every invariant, after every operation
    }
    // Same keys and values, in the same order, in both trees.
    let (mut all_bottom, mut all_top) = (Vec::new(), Vec::new());
    bottom.in_order(|key, value| all_bottom.push(Entry { key, value }));
    top.in_order(|key, value| all_top.push(Entry { key, value }));
    assert_eq!(all_bottom, oracle.range(0, 400));
    assert_eq!(all_top, oracle.range(0, 400));
    // Nothing is asserted about the two heights: either tree can be the
    // taller one (see `neither_variant_is_always_the_taller_one`).
}

#[test]
fn model_test_bottom_up_and_top_down_hold_the_same_keys_every_even_order_from_4_to_12() {
    // Same seeds as the Zig test's first pool (the slab is the only pool here).
    for order in [4, 6, 8, 10, 12] {
        model_test_both_variants(order, order as u64);
    }
}

#[test]
fn top_down_put_under_allocation_failure_valid_tree_same_keys_the_finished_splits_stay() {
    let mut tree = BTree::new(4);
    for key in 1..13 {
        tree.put(key, key).unwrap();
    }
    expect_tree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");

    // The root split needs two nodes. If the second is missing, the first is
    // handed back and nothing has changed, counters included.
    let usage = tree.pool.usage;
    tree.pool.fail_after = Some(1);
    assert_eq!(topdown::put(&mut tree, 13, 13), Err(OutOfNodes));
    assert_eq!(tree.pool.usage, usage);
    assert_eq!(tree.counters.splits, 3);
    expect_tree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");

    // Now the root split succeeds and the leaf split below it fails. The
    // root split is not undone: the tree is valid and holds the same 12
    // keys, one level taller.
    tree.pool.fail_after = Some(2);
    assert_eq!(topdown::put(&mut tree, 13, 13), Err(OutOfNodes));
    expect_tree(&tree, "[6]\n[3] [9]\n[1 2] [4 5] | [7 8] [10 11 12]\n");
    assert_eq!(tree.len, 12);
    assert_eq!(tree.get(13), None);
    assert_eq!(tree.pool.usage.created, usage.created + 2); // real nodes of the tree

    tree.pool.fail_after = None;
    assert_eq!(topdown::put(&mut tree, 13, 13), Ok(None));
    expect_tree(&tree, "[6]\n[3] [9 11]\n[1 2] [4 5] | [7 8] [10] [12 13]\n");
}

/// Build the 80-key tree top-down with allocation number `fail_at` failing
/// (and all later ones). The put that hits it must leave a valid tree with
/// exactly the keys inserted so far. Returns whether the failure was hit.
fn top_down_build(fail_at: Option<u64>) -> bool {
    let mut tree = BTree::new(4);
    tree.pool.fail_after = fail_at;
    for i in 0..BUILD_COUNT {
        if topdown::put(&mut tree, build_key(i), i) == Err(OutOfNodes) {
            assert_eq!(tree.len as u64, i);
            assert_eq!(tree.get(build_key(i)), None);
            for j in 0..i {
                assert_eq!(tree.get(build_key(j)), Some(j));
            }
            assert_eq!(tree.validate(), Ok(()));
            return true;
        }
    }
    assert_eq!(tree.validate(), Ok(()));
    false
}

#[test]
fn top_down_every_allocation_in_a_build_may_fail_the_tree_stays_valid() {
    // The Rust mirror of Zig's checkAllAllocationFailures: fail allocation
    // 0, 1, 2, ... until the build gets through without reaching it.
    let mut fail_at = 0;
    while top_down_build(Some(fail_at)) {
        fail_at += 1;
    }
    assert!(fail_at >= 2);
    assert!(!top_down_build(None));
}
