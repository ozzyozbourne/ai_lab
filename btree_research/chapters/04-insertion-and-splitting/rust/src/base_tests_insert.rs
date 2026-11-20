// Copied from chapters/05-deletion-and-rebalancing/rust/src/tests_insert.rs; fixes go there first
//! Tests of search and bottom-up insert. tests_topdown.rs reuses the helpers
//! declared `pub` here.

use crate::base_btree::BTree;
use crate::base_pool::OutOfNodes;
use crate::ops::{Config, Entry, Op, OpStream, Oracle, Weights};

/// The guide's canonical insertion order (chapters 03 to 08), M = 4.
pub const CANONICAL_KEYS: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

pub fn render(tree: &BTree) -> String {
    let mut out = Vec::new();
    tree.render(&mut out, "").unwrap();
    String::from_utf8(out).unwrap()
}

pub fn expect_tree(tree: &BTree, expected: &str) {
    assert_eq!(render(tree), expected);
    assert_eq!(tree.validate(), Ok(()));
}

pub fn build_canonical() -> BTree {
    let mut tree = BTree::new(4);
    for key in CANONICAL_KEYS {
        tree.put(key, key * 10).unwrap();
    }
    tree
}

fn put_all(tree: &mut BTree, keys: &[u64]) {
    for &key in keys {
        tree.put(key, key * 10).unwrap();
    }
}

#[test]
fn put_the_canonical_example_step_by_step() {
    let mut tree = BTree::new(4);
    expect_tree(&tree, "(empty)\n");
    put_all(&mut tree, &[10, 20, 5]);
    expect_tree(&tree, "[5 10 20]\n");
    tree.put(6, 60).unwrap(); // overflow: split, 10 becomes the root
    expect_tree(&tree, "[10]\n[5 6] [20]\n");
    put_all(&mut tree, &[12, 30, 7, 17]);
    expect_tree(&tree, "[10 20]\n[5 6 7] [12 17] [30]\n");
    put_all(&mut tree, &[3, 25, 1, 15]);
    expect_tree(&tree, "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n");
    assert_eq!(tree.counters.splits, 3);
    assert_eq!(tree.counters.root_splits, 1);
}

#[test]
fn put_overwrites_get_finds_keys_in_leaves_and_interior_nodes() {
    let mut tree = build_canonical();
    assert_eq!(tree.len, 12);
    assert_eq!(tree.get(10), Some(100)); // interior
    assert_eq!(tree.get(15), Some(150)); // leaf
    assert_eq!(tree.get(11), None);
    assert_eq!(tree.put(10, 111), Ok(Some(100)));
    assert_eq!(tree.get(10), Some(111));
    assert_eq!(tree.len, 12);
}

#[test]
fn shape_and_fill_statistics() {
    let s = build_canonical().shape();
    assert_eq!(s.height, 2);
    assert_eq!(s.nodes, 5);
    assert_eq!(s.leaves, 4);
    assert_eq!(s.keys, 12);
    assert_eq!(s.capacity, 15); // 5 nodes * 3 keys
    assert_eq!(s.fill_percent(), 80);
}

#[test]
fn the_extreme_keys_0_and_u64_max_are_ordinary_keys() {
    let max = u64::MAX;
    let mut tree = BTree::new(4);
    for key in [max, 0, max - 1, 1, max - 2, 2] {
        tree.put(key, key ^ 5).unwrap();
    }
    assert_eq!(tree.validate(), Ok(()));
    assert_eq!(tree.get(max), Some(max ^ 5));
    assert_eq!(tree.get(0), Some(5));
}

#[test]
fn validate_reports_a_leaked_node() {
    // Simulate a node the tree lost track of: one node is live in the pool that the root cannot reach. A slab never
    // leaks to the operating system, so the live-node counter is the only
    // witness. (In Zig the leak checker of std.testing.allocator also sees
    // it, but only when every node is an allocation of its own.)
    use crate::base_node::Node;
    use crate::base_validate::ValidateError;
    let mut tree = build_canonical();
    let orphan = tree.pool.alloc(Node::new(true)).unwrap();
    assert_eq!(tree.validate(), Err(ValidateError::NodeCountMismatch));
    tree.pool.free(orphan);
    assert_eq!(tree.validate(), Ok(()));
}

fn model_test_put_only(order: usize, seed: u64) {
    let mut tree = BTree::new(order);
    let mut oracle = Oracle::new();
    // No deletes: the tree only grows. 400 possible keys in 1500 operations
    // give both fresh inserts and overwrites.
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
            Op::Put { key, value } => assert_eq!(tree.put(key, value), Ok(oracle.put(key, value))),
            Op::Delete { .. } => unreachable!("weight 0"),
            Op::Get { key } => assert_eq!(tree.get(key), oracle.get(key)),
            Op::Range { lo, hi } => {
                let mut seen = Vec::new();
                tree.range(lo, hi, |key, value| seen.push(Entry { key, value }));
                assert_eq!(seen, oracle.range(lo, hi));
            }
        }
        assert_eq!(tree.len, oracle.len());
        assert_eq!(tree.validate(), Ok(())); // every invariant, after every operation
    }
    let mut all = Vec::new();
    tree.in_order(|key, value| all.push(Entry { key, value }));
    assert_eq!(all, oracle.range(0, 400));
    assert!(tree.shape().height >= 3);
}

#[test]
fn model_test_puts_only_every_order_from_3_to_9_against_the_oracle() {
    // Same seeds as the Zig test's first pool (the slab is the only pool here).
    for order in 3..10 {
        model_test_put_only(order, order as u64);
    }
}

#[test]
fn put_under_allocation_failure_leaves_the_tree_unchanged() {
    let mut tree = BTree::new(4);
    // Keys 1..9 in order give [3 6] over [1 2] [4 5] [7 8 9]: the next
    // ascending key splits the right-most leaf, which needs one new node.
    for key in 1..10 {
        tree.put(key, key).unwrap();
    }
    expect_tree(&tree, "[3 6]\n[1 2] [4 5] [7 8 9]\n");

    tree.pool.fail_after = Some(0); // the next allocation fails, and all after it
    assert_eq!(tree.put(10, 10), Err(OutOfNodes));
    expect_tree(&tree, "[3 6]\n[1 2] [4 5] [7 8 9]\n"); // nothing changed, nothing leaked
    assert_eq!(tree.len, 9);

    // Overwrites and inserts into a node with room need no memory at all.
    assert_eq!(tree.put(5, 55), Ok(Some(5)));
    assert_eq!(tree.put(0, 0), Ok(None));
    expect_tree(&tree, "[3 6]\n[0 1 2] [4 5] [7 8 9]\n");

    // A cascade needs several nodes; fail the LAST one. The earlier
    // reservations must be handed back.
    tree.pool.fail_after = None;
    for key in [10, 11, 12] {
        tree.put(key, key).unwrap();
    }
    expect_tree(&tree, "[3 6 9]\n[0 1 2] [4 5] [7 8] [10 11 12]\n");
    let usage = tree.pool.usage;
    let counters = tree.counters;
    tree.pool.fail_after = Some(2); // leaf split ok, root split ok, new root fails
    assert_eq!(tree.put(13, 13), Err(OutOfNodes));
    // Not only live(): created, destroyed and peak are as before too, so the
    // two reservations that were handed back left no trace in the statistics.
    assert_eq!(tree.pool.usage, usage);
    assert_eq!(tree.counters, counters);
    assert_eq!(tree.get(13), None);
    expect_tree(&tree, "[3 6 9]\n[0 1 2] [4 5] [7 8] [10 11 12]\n");

    tree.pool.fail_after = None; // memory is back: the same put succeeds
    tree.put(13, 13).unwrap();
    expect_tree(
        &tree,
        "[9]\n[3 6] [12]\n[0 1 2] [4 5] [7 8] | [10 11] [13]\n",
    );
    assert_eq!(tree.pool.usage.created, usage.created + 3);
}

#[test]
fn the_same_failures_with_a_node_budget() {
    // The other switch: a limit on live nodes instead of a countdown.
    let mut tree = BTree::new(4);
    for key in 1..13 {
        tree.put(key, key).unwrap();
    }
    expect_tree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");
    let usage = tree.pool.usage;
    for room in 0..3 {
        // Key 13 needs three nodes; `room` are available.
        tree.pool.budget = Some(usage.live() + room);
        assert_eq!(tree.put(13, 13), Err(OutOfNodes));
        assert_eq!(tree.pool.usage, usage);
        expect_tree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");
    }
    tree.pool.budget = Some(usage.live() + 3);
    assert_eq!(tree.put(13, 13), Ok(None));
    expect_tree(&tree, "[9]\n[3 6] [12]\n[1 2] [4 5] [7 8] | [10 11] [13]\n");
}

pub const BUILD_COUNT: u64 = 80;
pub fn build_key(i: u64) -> u64 {
    (i * 37) % BUILD_COUNT // 37 and 80 are coprime: every key once, scattered
}

/// Build the 80-key tree under a node budget. A failed put must leave a
/// valid tree holding exactly the keys inserted so far.
fn build(budget: Option<u64>) -> Result<u64, OutOfNodes> {
    let mut tree = BTree::new(4);
    tree.pool.budget = budget;
    for i in 0..BUILD_COUNT {
        if let Err(out_of_nodes) = tree.put(build_key(i), i) {
            assert_eq!(tree.validate(), Ok(()));
            assert_eq!(tree.len as u64, i);
            return Err(out_of_nodes);
        }
    }
    assert_eq!(tree.validate(), Ok(()));
    Ok(tree.pool.usage.peak)
}

#[test]
fn every_node_budget_fails_cleanly_or_succeeds() {
    // The Rust mirror of Zig's checkAllAllocationFailures: try every budget
    // below what the build needs; each must fail without corrupting the tree.
    let peak = build(None).unwrap();
    for budget in 0..peak {
        assert_eq!(build(Some(budget)), Err(OutOfNodes));
    }
    assert_eq!(build(Some(peak)), Ok(peak));
}

/// Build the same tree, but allocation number `fail_at` fails. The put that
/// hits it must change nothing, and must succeed when it is repeated with
/// memory available. Returns the final tree as text and whether the failure
/// was hit (false: the build needed fewer than `fail_at + 1` allocations).
fn build_with_one_failure(fail_at: Option<u64>) -> (String, bool) {
    let mut tree = BTree::new(4);
    tree.pool.fail_after = fail_at;
    let mut failed = false;
    for i in 0..BUILD_COUNT {
        let usage = tree.pool.usage;
        let counters = tree.counters;
        match tree.put(build_key(i), i) {
            Ok(old) => assert_eq!(old, None),
            Err(OutOfNodes) => {
                failed = true;
                assert_eq!(tree.pool.usage, usage);
                assert_eq!(tree.counters, counters);
                assert_eq!(tree.len as u64, i);
                assert_eq!(tree.get(build_key(i)), None);
                assert_eq!(tree.validate(), Ok(()));
                tree.pool.fail_after = None;
                assert_eq!(tree.put(build_key(i), i), Ok(None));
            }
        }
    }
    assert_eq!(tree.validate(), Ok(()));
    (render(&tree), failed)
}

#[test]
fn a_put_that_fails_in_the_middle_of_a_build_changes_nothing_and_the_build_goes_on() {
    let (want, failed) = build_with_one_failure(None);
    assert!(!failed);
    let mut fail_at = 0;
    loop {
        let (got, failed) = build_with_one_failure(Some(fail_at));
        // The failure is invisible afterwards: same tree as without it.
        assert_eq!(got, want);
        if !failed {
            break;
        }
        fail_at += 1;
    }
    assert!(fail_at >= 2);
}
