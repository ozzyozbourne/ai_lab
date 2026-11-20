//! The allocator side of this chapter, Rust version: the slab with a node
//! budget, and the proof that a failed bottom-up `put` leaves the tree
//! unchanged.
//!
//! The Zig twin uses `std.testing.checkAllAllocationFailures`, which runs a
//! function once per allocation it makes and fails exactly that allocation.
//! Rust cannot make the global allocator fail without aborting, so the slab
//! plays that role: `fail_after = Some(n)` fails node allocation number n and
//! every later one; `budget = Some(n)` caps the number of live nodes.

use crate::base_btree::BTree;
use crate::base_pool::OutOfNodes;
use crate::base_tests_insert::render;

const KEY_COUNT: u64 = 120;
fn key_at(i: u64) -> u64 {
    (i * 77) % KEY_COUNT // 77 and 120 are coprime: every key once, scattered
}

/// Build the tree; a failed put must change nothing: not the picture of the
/// tree, not a counter. Returns the number of nodes on success.
fn build(order: usize, fail_after: Option<u64>, budget: Option<u64>) -> Result<u64, OutOfNodes> {
    let mut tree = BTree::new(order);
    tree.pool.fail_after = fail_after;
    tree.pool.budget = budget;
    for i in 0..KEY_COUNT {
        let before = render(&tree);
        let usage = tree.pool.usage;
        let counters = tree.counters;
        if let Err(out_of_nodes) = tree.put(key_at(i), i) {
            assert_eq!(render(&tree), before);
            assert_eq!(tree.pool.usage, usage);
            assert_eq!(tree.counters, counters);
            assert_eq!(tree.len as u64, i);
            assert_eq!(tree.validate(), Ok(()));
            return Err(out_of_nodes);
        }
    }
    assert_eq!(tree.validate(), Ok(()));
    Ok(tree.pool.usage.live())
}

#[test]
fn every_failing_allocation_a_failed_put_leaves_the_tree_unchanged() {
    for order in [3, 4, 7] {
        let nodes = build(order, None, None).unwrap();
        // An insert-only build allocates exactly one slot per node, so
        // allocation indices 0 .. nodes are all the failure points there are.
        for fail_at in 0..nodes {
            assert_eq!(build(order, Some(fail_at), None), Err(OutOfNodes));
        }
        assert_eq!(build(order, Some(nodes), None), Ok(nodes));
    }
}

#[test]
fn every_node_budget_a_failed_put_leaves_the_tree_unchanged() {
    for order in [3, 4, 7] {
        let nodes = build(order, None, None).unwrap();
        for budget in 0..nodes {
            assert_eq!(build(order, None, Some(budget)), Err(OutOfNodes));
        }
        assert_eq!(build(order, None, Some(nodes)), Ok(nodes));
    }
}

#[test]
fn what_a_build_asks_of_the_slab_one_slot_per_node_none_freed() {
    let mut tree = BTree::new(4);
    for i in 0..KEY_COUNT {
        tree.put(key_at(i), i).unwrap();
    }
    let nodes = tree.shape().nodes;
    assert_eq!(tree.pool.usage.live(), nodes as u64);
    assert_eq!(tree.pool.usage.destroyed, 0); // an insert-only tree never frees a node
    assert_eq!(tree.pool.slot_count(), nodes); // and the slab never grew beyond the tree
}
