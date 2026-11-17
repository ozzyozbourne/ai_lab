//! Tests of the whole tree: fixed scenarios, a seeded model test against the
//! oracle, the node budget (Rust's stand-in for allocation failure), and
//! proof that `validate` catches corruption.
//! (arena.rs, node.rs and search.rs carry their own unit tests.)

use crate::arena::{NodeId, OutOfNodes};
use crate::dump;
use crate::node::Node;
use crate::ops::{Config, Op, OpStream, Oracle, Weights};
use crate::tree::BPlusTree;
use crate::validate::Violation;
use crate::walk::LeafWalker;

const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

fn build_canonical() -> BPlusTree {
    let mut tree = BPlusTree::new(4);
    for k in CANONICAL {
        tree.put(k, k * 100).unwrap();
    }
    tree
}

fn dump_string(tree: &BPlusTree) -> String {
    let mut out = Vec::new();
    dump::dump(tree, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

/// Checks the chain in both directions against `expected` (ascending keys).
fn expect_chain(expected: &[u64], tree: &BPlusTree) {
    let forward: Vec<u64> = LeafWalker::first(tree).map(|e| e.key).collect();
    assert_eq!(forward, expected);

    // Backward by hand through the prev links: the last key first.
    let mut backward: Vec<u64> = Vec::new();
    let mut id = tree.last_leaf;
    while !id.is_nil() {
        let n = tree.nodes.get(id);
        backward.extend(n.key_slice().iter().rev());
        id = n.leaf().prev;
    }
    backward.reverse();
    assert_eq!(backward, expected);
}

#[test]
fn canonical_example_has_the_shape_shown_in_the_readme() {
    let tree = build_canonical();
    tree.validate().unwrap();
    assert_eq!(
        dump_string(&tree),
        "height 3, 12 keys, 8 nodes\n\
         \x20 level 0: #7[15]\n\
         \x20 level 1: #2[6 10] #6[20]\n\
         \x20 leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10 12) <-> #5(15 17) <-> #3(20 25 30)\n"
    );
    expect_chain(&[1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30], &tree);
    for k in CANONICAL {
        assert_eq!(tree.get(k), Some(k * 100));
    }
    assert_eq!(tree.get(13), None);
    assert_eq!(tree.stats.leaf_splits, 4);
    assert_eq!(tree.stats.internal_splits, 1);
}

#[test]
fn copy_up_keeps_the_key_in_the_leaf_push_up_moves_the_separator() {
    let tree = build_canonical();
    // 15 was copied up from leaf #5 and then pushed up out of node #2:
    // it is in the root and in a leaf, but in no other internal node.
    let root = tree.nodes.get(tree.root);
    assert_eq!(root.key_slice(), [15]);
    for &child in root.child_slice() {
        assert!(!tree.nodes.get(child).key_slice().contains(&15));
    }
    assert_eq!(tree.get(15), Some(1500));
}

#[test]
fn put_overwrites_and_reports_the_old_value() {
    let mut tree = BPlusTree::new(4);
    assert_eq!(tree.put(1, 10), Ok(None));
    assert_eq!(tree.put(1, 11), Ok(Some(10)));
    assert_eq!(tree.get(1), Some(11));
    assert_eq!(tree.len(), 1);
}

#[test]
fn a_separator_may_outlive_its_key() {
    let mut tree = build_canonical();
    assert_eq!(tree.delete(15), Some(1500));
    assert_eq!(tree.delete(15), None);
    assert_eq!(tree.get(15), None);
    // The root still says 15, and that is a valid tree.
    assert_eq!(tree.nodes.get(tree.root).key_slice(), [15]);
    tree.validate().unwrap();
    // Keys on both sides of the stale separator are still routed correctly.
    assert_eq!(tree.put(14, 1), Ok(None));
    assert_eq!(tree.put(16, 2), Ok(None));
    assert_eq!(tree.put(15, 3), Ok(None));
    tree.validate().unwrap();
    expect_chain(&[1, 3, 5, 6, 7, 10, 12, 14, 15, 16, 17, 20, 25, 30], &tree);
}

#[test]
fn delete_walks_through_borrow_merge_and_root_shrink() {
    let mut tree = build_canonical();
    for k in [15, 17, 20, 25, 30, 12] {
        assert_eq!(tree.delete(k), Some(k * 100));
        tree.validate().unwrap();
    }
    assert_eq!(tree.stats.borrows, 4);
    assert_eq!(tree.stats.merges, 3);
    assert_eq!(
        dump_string(&tree),
        "height 2, 6 keys, 4 nodes\n\
         \x20 level 0: #2[6 10]\n\
         \x20 leaves : #0(1 3 5) <-> #4(6 7) <-> #1(10)\n"
    );
}

#[test]
fn deleting_everything_frees_every_node_and_the_tree_can_be_refilled() {
    let mut tree = build_canonical();
    for k in CANONICAL {
        assert_eq!(tree.delete(k), Some(k * 100));
        tree.validate().unwrap();
    }
    assert_eq!(tree.nodes.live_count(), 0);
    assert_eq!(tree.height, 0);
    assert!(tree.root.is_nil());
    let slots = tree.nodes.slot_count();
    for k in CANONICAL {
        tree.put(k, k).unwrap();
    }
    tree.validate().unwrap();
    // The second build fits entirely into recycled slots.
    assert_eq!(tree.nodes.slot_count(), slots);
}

#[test]
fn ascending_and_descending_inserts_keep_both_ends_of_the_chain_right() {
    for order in [3, 4, 5, 8] {
        let mut up = BPlusTree::new(order);
        let mut down = BPlusTree::new(order);
        let expected: Vec<u64> = (0..200).collect();
        for i in 0..200 {
            up.put(i, i).unwrap();
            down.put(199 - i, i).unwrap();
        }
        up.validate().unwrap();
        down.validate().unwrap();
        expect_chain(&expected, &up);
        expect_chain(&expected, &down);
        // Empty one from the front and the other from the back.
        for i in 0..200 {
            assert_eq!(up.delete(i), Some(i));
            assert!(down.delete(199 - i).is_some());
            up.validate().unwrap();
            down.validate().unwrap();
        }
        assert_eq!(up.nodes.live_count(), 0);
        assert_eq!(down.nodes.live_count(), 0);
    }
}

#[test]
fn seek_positions_the_walker_at_the_first_key_at_or_after_the_argument() {
    let tree = build_canonical();
    assert_eq!(LeafWalker::seek(&tree, 12).next().unwrap().key, 12);
    // 13 is absent and falls after the last key of leaf #1: the walker must
    // step over the leaf boundary to 15.
    assert_eq!(LeafWalker::seek(&tree, 13).next().unwrap().key, 15);
    assert_eq!(LeafWalker::seek(&tree, 0).next().unwrap().key, 1);
    assert!(LeafWalker::seek(&tree, 31).next().is_none());
    let empty = BPlusTree::new(4);
    assert!(LeafWalker::seek(&empty, 1).next().is_none());
}

/// The seeded model test: the same operation stream goes to the tree and to
/// the oracle and every answer must agree. The Zig twin replays the
/// identical stream.
fn model_test(order: usize, seed: u64, count: u64, key_space: u64) {
    let mut tree = BPlusTree::new(order);
    let mut oracle = Oracle::new();
    let config = Config {
        seed,
        count,
        key_space,
        weights: Weights::default(),
    };
    for op in OpStream::new(config) {
        match op {
            Op::Put { key, value } => assert_eq!(tree.put(key, value), Ok(oracle.put(key, value))),
            Op::Delete { key } => assert_eq!(tree.delete(key), oracle.delete(key)),
            Op::Get { key } => assert_eq!(tree.get(key), oracle.get(key)),
            Op::Range { lo, hi } => {
                let mut walker = LeafWalker::seek(&tree, lo);
                for expected in oracle.range(lo, hi) {
                    let got = walker.next().unwrap();
                    assert_eq!((got.key, got.value), (expected.key, expected.value));
                }
                assert!(walker.next().is_none_or(|after| after.key >= hi));
            }
        }
        assert_eq!(tree.len(), oracle.len());
        tree.validate().unwrap();
    }
}

#[test]
fn model_test_against_the_oracle_several_orders_and_key_spaces() {
    for order in [3, 4, 5, 6, 7, 16] {
        // A small key space keeps the tree tiny and churning (many merges and
        // root shrinks); a large one makes it tall.
        model_test(order, 1, 3000, 40);
        model_test(order, 2, 3000, 2000);
        model_test(order, 3 + order as u64, 1500, 300);
    }
}

#[test]
fn model_test_with_delete_heavy_weights_empties_the_tree_repeatedly() {
    let mut tree = BPlusTree::new(4);
    let mut oracle = Oracle::new();
    let weights = Weights {
        put: 2,
        delete: 5,
        get: 1,
        range: 0,
    };
    let mut times_empty = 0;
    for op in OpStream::new(Config {
        seed: 11,
        count: 5000,
        key_space: 6,
        weights,
    }) {
        match op {
            Op::Put { key, value } => assert_eq!(tree.put(key, value), Ok(oracle.put(key, value))),
            Op::Delete { key } => {
                assert_eq!(tree.delete(key), oracle.delete(key));
                if tree.is_empty() {
                    times_empty += 1;
                }
            }
            Op::Get { key } => assert_eq!(tree.get(key), oracle.get(key)),
            Op::Range { .. } => unreachable!(),
        }
        tree.validate().unwrap();
    }
    assert!(times_empty > 50);
}

// ------------------------------------------------------------ node budget

#[test]
fn a_put_that_runs_out_of_nodes_leaves_the_tree_exactly_as_it_was() {
    // Give the tree a fixed node budget and insert until it runs out; then
    // repeat with a larger budget, so the failure hits trees of every size.
    let mut failures = 0;
    for budget in 0..=80 {
        let mut tree = BPlusTree::with_node_budget(3, budget);
        for i in 0..64u64 {
            let key = (i * 37) % 64;
            let before = dump_string(&tree);
            match tree.put(key, key) {
                Ok(old) => {
                    assert_eq!(old, None);
                    tree.validate().unwrap();
                }
                Err(OutOfNodes) => {
                    failures += 1;
                    // Nothing changed: same picture, still valid, key absent,
                    // and the tree is still usable for reads and deletes.
                    assert_eq!(dump_string(&tree), before);
                    tree.validate().unwrap();
                    assert_eq!(tree.get(key), None);
                    assert_eq!(tree.len() as u64, i);
                    if i > 0 {
                        assert_eq!(tree.delete(0), Some(0));
                    }
                    tree.validate().unwrap();
                    break;
                }
            }
        }
        assert!(tree.nodes.live_count() <= budget);
    }
    assert!(failures > 10);
}

// ------------------------------------------- validate catches corruption

#[test]
fn validate_names_the_broken_invariant() {
    type Corrupt = fn(&mut BPlusTree);
    let cases: [(Violation, Corrupt); 10] = [
        (Violation::KeysNotSorted, |t| {
            t.nodes.get_mut(t.first_leaf).keys.swap(0, 1);
        }),
        (Violation::KeyOutOfBounds, |t| {
            // Leaf #4 is (6 7) and sits left of separator 10. Changing 7 to
            // 11 keeps the leaf sorted but breaks the separator's promise.
            t.nodes.get_mut(NodeId::from_index(4)).keys[1] = 11;
        }),
        (Violation::NodeUnderfull, |t| {
            t.nodes.get_mut(t.last_leaf).len = 0;
        }),
        (Violation::NodeOverfull, |t| {
            t.nodes.get_mut(t.last_leaf).leaf_insert_at(3, 40, 0);
        }),
        (Violation::BrokenLeafChain, |t| {
            t.nodes.get_mut(t.last_leaf).leaf_mut().prev = t.first_leaf;
        }),
        (Violation::BrokenLeafChain, |t| {
            // Skip a leaf in the forward direction.
            let second = t.nodes.get(t.first_leaf).leaf().next;
            let third = t.nodes.get(second).leaf().next;
            t.nodes.get_mut(t.first_leaf).leaf_mut().next = third;
        }),
        (Violation::WrongCount, |t| {
            t.count += 1;
        }),
        (Violation::UnevenLeafDepth, |t| {
            t.height += 1;
        }),
        (Violation::DanglingChild, |t| {
            // Free a leaf behind the tree's back: its parent still points at it.
            t.nodes.free(t.last_leaf);
        }),
        (Violation::ArenaLeak, |t| {
            // A node nobody points at: a leak inside the arena.
            t.nodes.alloc(Node::new_leaf()).unwrap();
        }),
    ];
    for (expected, corrupt) in cases {
        let mut tree = build_canonical();
        tree.validate().unwrap();
        corrupt(&mut tree);
        assert_eq!(tree.validate(), Err(expected));
    }
}
