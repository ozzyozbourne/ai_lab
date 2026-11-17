//! Tests of the whole tree. (Each section file also has its own unit tests.)

use crate::btree::BTree;
use crate::ops::{Config, Entry, Op, OpStream, Oracle, Weights};
use crate::pool::OutOfNodes;
use crate::prng::SplitMix64;
use crate::scenario::{CANONICAL_KEYS, TALL_COUNT};

fn expect_tree(tree: &BTree, expected: &str) {
    let mut out = Vec::new();
    tree.render(&mut out, "").unwrap();
    assert_eq!(String::from_utf8(out).unwrap(), expected);
    assert_eq!(tree.validate(), Ok(()));
}

fn build_canonical() -> BTree {
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
fn delete_leaf_key_without_underflow() {
    let mut tree = build_canonical();
    assert_eq!(tree.delete(3), Some(30));
    expect_tree(&tree, "[6 10 20]\n[1 5] [7] [12 15 17] [25 30]\n");
    assert_eq!(tree.delete(3), None); // already gone: no change
    assert_eq!(tree.delete(11), None);
    expect_tree(&tree, "[6 10 20]\n[1 5] [7] [12 15 17] [25 30]\n");
    assert_eq!(tree.len, 11);
}

#[test]
fn delete_borrow_from_the_left_sibling_rotates_through_the_parent() {
    let mut tree = build_canonical();
    tree.delete(7); // [7] becomes empty; [1 3 5] can spare a key
    expect_tree(&tree, "[5 10 20]\n[1 3] [6] [12 15 17] [25 30]\n");
    assert_eq!(tree.counters.borrows_left, 1);
    assert_eq!(tree.counters.merges, 0);
    assert_eq!(tree.get(6), Some(60)); // values travel with their keys
    assert_eq!(tree.get(5), Some(50));
}

#[test]
fn delete_borrow_from_the_right_sibling_when_the_left_one_is_at_minimum() {
    let mut tree = build_canonical();
    tree.delete(3);
    tree.delete(7);
    expect_tree(&tree, "[5 10 20]\n[1] [6] [12 15 17] [25 30]\n");
    tree.delete(6); // left [1] is at minimum, right [12 15 17] is not
    expect_tree(&tree, "[5 12 20]\n[1] [10] [15 17] [25 30]\n");
    assert_eq!(tree.counters.borrows_right, 1);
}

#[test]
fn delete_interior_key_is_replaced_by_its_predecessor() {
    let mut tree = build_canonical();
    assert_eq!(tree.delete(20), Some(200));
    expect_tree(&tree, "[6 10 17]\n[1 3 5] [7] [12 15] [25 30]\n");
    assert_eq!(tree.counters.predecessor_swaps, 1);
    assert_eq!(tree.get(17), Some(170));
    // Predecessor taken from a minimal leaf: the leaf underflows and is repaired.
    assert_eq!(tree.delete(10), Some(100));
    expect_tree(&tree, "[5 7 17]\n[1 3] [6] [12 15] [25 30]\n");
}

#[test]
fn delete_merge_then_the_root_shrinks() {
    let mut tree = BTree::new(4);
    for key in [10, 20, 30, 40] {
        tree.put(key, key).unwrap();
    }
    expect_tree(&tree, "[30]\n[10 20] [40]\n");
    tree.delete(10);
    expect_tree(&tree, "[30]\n[20] [40]\n");
    assert_eq!(tree.pool.usage.live(), 3);
    tree.delete(40); // nobody can lend: [20] + 30 + [] merge, root is empty
    expect_tree(&tree, "[20 30]\n");
    assert_eq!(tree.counters.merges, 1);
    assert_eq!(tree.counters.root_shrinks, 1);
    assert_eq!(tree.pool.usage.live(), 1); // two nodes went back to the pool
    tree.delete(20);
    tree.delete(30);
    expect_tree(&tree, "(empty)\n");
    assert_eq!(tree.pool.usage.live(), 0);
    assert_eq!(tree.counters.root_shrinks, 1); // emptying a leaf root is not a shrink
}

#[test]
fn delete_an_underflow_travels_up_through_interior_nodes() {
    let mut tree = BTree::new(4);
    for key in 1..=TALL_COUNT {
        tree.put(key, key * 10).unwrap();
    }
    expect_tree(&tree, "[9]\n[3 6] [12]\n[1 2] [4 5] [7 8] | [10 11] [13]\n");
    tree.delete(9); // predecessor 8 comes from two levels down
    tree.delete(13);
    expect_tree(&tree, "[8]\n[3 6] [11]\n[1 2] [4 5] [7] | [10] [12]\n");
    // Leaf merge empties interior node [11]; it borrows from interior [3 6],
    // and the child [7] changes parent together with the borrowed key.
    tree.delete(10);
    expect_tree(&tree, "[6]\n[3] [8]\n[1 2] [4 5] | [7] [11 12]\n");
    assert_eq!(tree.get(7), Some(70));
    tree.delete(1);
    tree.delete(2);
    expect_tree(&tree, "[6]\n[4] [8]\n[3] [5] | [7] [11 12]\n");
    // Leaf merge, interior merge, root shrink: three levels become two.
    let merges_before = tree.counters.merges;
    tree.delete(3);
    expect_tree(&tree, "[6 8]\n[4 5] [7] [11 12]\n");
    assert_eq!(tree.counters.merges, merges_before + 2);
    assert_eq!(tree.counters.root_shrinks, 1);
}

fn model_test(order: usize, seed: u64) {
    let mut tree = BTree::new(order);
    let mut oracle = Oracle::new();
    // A small key space makes overwrites and deletes of present keys common.
    let weights = Weights {
        put: 4,
        delete: 4,
        get: 2,
        range: 1,
    };
    for op in OpStream::new(Config {
        seed,
        count: 3000,
        key_space: 120,
        weights,
    }) {
        match op {
            Op::Put { key, value } => assert_eq!(tree.put(key, value), Ok(oracle.put(key, value))),
            Op::Delete { key } => assert_eq!(tree.delete(key), oracle.delete(key)),
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
    assert_eq!(all, oracle.range(0, 120));
}

#[test]
fn model_test_every_order_from_3_to_9_against_the_oracle() {
    // Same seeds as the Zig test's first pool (the slab is the only pool here).
    for order in 3..10 {
        model_test(order, order as u64);
    }
}

#[test]
fn the_free_list_recycles_slots() {
    let mut tree = BTree::new(4);
    for op in OpStream::new(Config {
        seed: 7,
        count: 5000,
        key_space: 300,
        weights: Weights::default(),
    }) {
        match op {
            Op::Put { key, value } => drop(tree.put(key, value)),
            Op::Delete { key } => drop(tree.delete(key)),
            _ => {}
        }
    }
    assert_eq!(tree.validate(), Ok(()));
    // The free list did its job: far fewer slots than alloc() calls.
    assert_eq!(tree.pool.slot_count() as u64, tree.pool.usage.peak);
    assert!(tree.pool.usage.peak < tree.pool.usage.created);
}

#[test]
fn delete_everything_in_random_order_every_node_goes_back() {
    for order in [3, 4, 5, 8] {
        let mut tree = BTree::new(order);
        let mut keys: Vec<u64> = (0..400).map(|i| i * 3).collect();
        let mut rng = SplitMix64::new(order as u64);
        rng.shuffle(&mut keys);
        for &key in &keys {
            tree.put(key, key + 1).unwrap();
        }
        assert_eq!(tree.validate(), Ok(()));
        assert!(tree.shape().height >= 3);
        rng.shuffle(&mut keys);
        for (i, &key) in keys.iter().enumerate() {
            assert_eq!(tree.delete(key), Some(key + 1));
            assert_eq!(tree.get(key), None);
            if i % 7 == 0 {
                assert_eq!(tree.validate(), Ok(()));
            }
        }
        assert_eq!(tree.root, None);
        assert_eq!(tree.pool.usage.live(), 0);
        assert_eq!(tree.pool.usage.created, tree.pool.usage.destroyed);
        // Every root split was undone by exactly one root shrink.
        assert_eq!(tree.counters.root_splits, tree.counters.root_shrinks);
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

    tree.pool.budget = Some(tree.pool.usage.live()); // the very next allocation fails
    assert_eq!(tree.put(10, 10), Err(OutOfNodes));
    expect_tree(&tree, "[3 6]\n[1 2] [4 5] [7 8 9]\n"); // nothing changed, nothing leaked
    assert_eq!(tree.len, 9);

    // Overwrites and inserts into a node with room need no memory at all.
    assert_eq!(tree.put(5, 55), Ok(Some(5)));
    tree.delete(9);
    assert_eq!(tree.put(9, 9), Ok(None));

    // A cascade needs several nodes; fail the LAST one. The earlier
    // reservations must be handed back.
    tree.pool.budget = None;
    for key in [10, 11, 12] {
        tree.put(key, key).unwrap();
    }
    expect_tree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");
    let live = tree.pool.usage.live();
    tree.pool.budget = Some(live + 2); // leaf split ok, root split ok, new root fails
    assert_eq!(tree.put(13, 13), Err(OutOfNodes));
    assert_eq!(tree.pool.usage.live(), live);
    expect_tree(&tree, "[3 6 9]\n[1 2] [4 5] [7 8] [10 11 12]\n");

    tree.pool.budget = None; // memory is back: the same put succeeds
    tree.put(13, 13).unwrap();
    expect_tree(&tree, "[9]\n[3 6] [12]\n[1 2] [4 5] [7 8] | [10 11] [13]\n");
}

/// Build 80 keys, then delete them all, under a node budget.
fn build_then_drain(budget: Option<u64>) -> Result<u64, OutOfNodes> {
    let mut tree = BTree::new(4);
    tree.pool.budget = budget;
    for i in 0..80 {
        if let Err(out_of_nodes) = tree.put((i * 37) % 80, i) {
            // The failed put must leave a valid tree holding exactly the
            // keys inserted so far.
            assert_eq!(tree.validate(), Ok(()));
            assert_eq!(tree.len as u64, i);
            return Err(out_of_nodes);
        }
    }
    assert_eq!(tree.validate(), Ok(()));
    for key in 0..80 {
        tree.delete(key);
    }
    assert_eq!(tree.root, None);
    Ok(tree.pool.usage.peak)
}

#[test]
fn every_node_budget_fails_cleanly_or_succeeds() {
    // The Rust mirror of Zig's checkAllAllocationFailures: try every budget
    // below what the run needs; each must fail without corrupting the tree.
    let peak = build_then_drain(None).unwrap();
    for budget in 0..peak {
        assert_eq!(build_then_drain(Some(budget)), Err(OutOfNodes));
    }
    assert_eq!(build_then_drain(Some(peak)), Ok(peak));
}

#[test]
fn validate_reports_a_leaked_node() {
    // Simulate the classic merge bug "unlink the node but forget to free it".
    // In Zig the leak checker of std.testing.allocator reports this; a slab
    // never leaks to the operating system, so the live-node counter is the
    // only witness.
    use crate::node::Node;
    use crate::validate::ValidateError;
    let mut tree = build_canonical();
    let orphan = tree.pool.alloc(Node::new(true)).unwrap();
    assert_eq!(tree.validate(), Err(ValidateError::NodeCountMismatch));
    tree.pool.free(orphan);
    assert_eq!(tree.validate(), Ok(()));
}
