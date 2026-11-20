//! SECTION B: a tree built by hand.
//!
//! This chapter has no insert and no delete. A tree is assembled bottom-up:
//! make the leaves, then the node above them, and so on up to the root.
//!
//! ```
//! use ch03_btree_structure_and_search::tree::HandTree;
//! let mut t = HandTree::new(4);
//! let a = t.leaf(&[5, 10]).unwrap();
//! let b = t.leaf(&[30, 40]).unwrap();
//! t.root = Some(t.interior(&[20], &[a, b]).unwrap());
//! assert_eq!(t.get(30), Some(300));
//! assert!(t.validate().is_ok());
//! ```
//!
//! `leaf` and `interior` check NOTHING about the B-tree rules. That is on
//! purpose: the same builder makes valid trees and the broken ones of
//! broken.rs, and `validate` is the only judge.
//!
//! Difference from the Zig twin: there the tree is generic over a node pool
//! and the caller passes an allocator to every building call (a tracking
//! allocator, a bump allocator or an arena). Here the tree owns its
//! [`Arena`], and dropping the tree frees every node. There is no `deinit`
//! and no way to free a single node.

use crate::arena::{Arena, OutOfNodes};
use crate::base_node::{Node, NodeId};
use crate::base_stats::Shape;
use crate::base_validate::ValidateError;
use crate::{base_search, base_stats, base_validate, height};
use std::io::{self, Write};

/// The guide's convention for example data: the value of key k is 10 * k.
/// `wrapping_mul` wraps around instead of panicking: every u64 is a legal
/// key, also the ones above `u64::MAX / 10`, and the value is only example
/// data.
pub fn value_of(key: u64) -> u64 {
    key.wrapping_mul(10)
}

/// A read-only B-tree of order `order` (at most `order` children, at most
/// `order - 1` keys per node) with nodes in a typed arena.
#[derive(Debug)]
pub struct HandTree {
    pub order: usize,
    /// `None` means the tree is empty: an empty tree owns no nodes.
    pub root: Option<NodeId>,
    /// Number of keys the tree claims to hold. `leaf` and `interior` add the
    /// keys they are given; `validate` compares with what it finds.
    pub len: usize,
    pub arena: Arena,
}

impl HandTree {
    pub fn new(order: usize) -> Self {
        assert!(order >= 3, "order 2 would allow nodes with zero keys");
        Self {
            order,
            root: None,
            len: 0,
            arena: Arena::new(),
        }
    }

    // ----------------------------------------------------------- building

    /// A new leaf holding `keys` (the caller promises nothing about them).
    pub fn leaf(&mut self, keys: &[u64]) -> Result<NodeId, OutOfNodes> {
        self.new_node(true, keys, &[])
    }

    /// A new interior node: `children[i]` is meant to hold the keys below
    /// `keys[i]`, the last child the keys above the last key.
    pub fn interior(&mut self, keys: &[u64], children: &[NodeId]) -> Result<NodeId, OutOfNodes> {
        self.new_node(false, keys, children)
    }

    fn new_node(
        &mut self,
        leaf: bool,
        keys: &[u64],
        children: &[NodeId],
    ) -> Result<NodeId, OutOfNodes> {
        // Order, fill and child count are deliberately left to `validate`.
        let mut node = Node::new(leaf);
        node.keys = keys.to_vec();
        node.values = keys.iter().map(|&key| value_of(key)).collect();
        node.children = children.to_vec();
        let id = self.arena.alloc(node)?;
        self.len += keys.len();
        Ok(id)
    }

    /// Build a valid tree of the smallest possible height from keys in
    /// strictly ascending order. The tree must be empty.
    ///
    /// Not an insertion algorithm: it deals the keys out top-down, like
    /// laying out a book index (chapter 16 does this properly, bottom-up
    /// and streaming). It exists so tests can check big trees.
    pub fn from_sorted(&mut self, sorted: &[u64]) -> Result<(), OutOfNodes> {
        assert!(self.root.is_none());
        if sorted.is_empty() {
            return Ok(());
        }
        let h = height::min_height(self.order as u64, sorted.len() as u64);
        self.root = Some(self.build_subtree(sorted, h, true)?);
        Ok(())
    }

    fn build_subtree(
        &mut self,
        keys: &[u64],
        h: usize,
        is_root: bool,
    ) -> Result<NodeId, OutOfNodes> {
        if h == 1 {
            return self.leaf(keys);
        }
        // Fewest children such that each child subtree fits into h - 1
        // levels. The root may have 2 children, other nodes at least t.
        let child_capacity = height::max_keys(self.order as u64, h - 1);
        let mut n_children = if is_root { 2 } else { self.order.div_ceil(2) };
        while (keys.len() - (n_children - 1)).div_ceil(n_children) as u64 > child_capacity {
            n_children += 1;
        }

        // n_children - 1 keys stay here as separators; the others are dealt
        // out evenly, the left children taking the remainder.
        let below = keys.len() - (n_children - 1);
        let mut separators = Vec::with_capacity(n_children - 1);
        let mut children = Vec::with_capacity(n_children);
        let mut pos = 0;
        for i in 0..n_children {
            let take = below / n_children + usize::from(i < below % n_children);
            children.push(self.build_subtree(&keys[pos..pos + take], h - 1, false)?);
            pos += take;
            if i + 1 < n_children {
                separators.push(keys[pos]); // this key lives in the interior node, nowhere else
                pos += 1;
            }
        }
        self.interior(&separators, &children)
    }

    // ------------------------------------------------------------ reading

    pub fn get(&self, key: u64) -> Option<u64> {
        base_search::get(&self.arena, self.root, key)
    }

    /// `visit(key, value)` for every entry, ascending.
    pub fn in_order(&self, mut visit: impl FnMut(u64, u64)) {
        base_search::in_order(&self.arena, self.root, &mut visit);
    }

    /// Checks every structural invariant, the key count, and that the number
    /// of nodes reachable from the root equals the number of nodes in the
    /// arena (a node nothing points to is a leak).
    pub fn validate(&self) -> Result<(), ValidateError> {
        base_validate::validate(&self.arena, self.order, self.root, self.len)?;
        if self.shape().nodes != self.arena.len() {
            return Err(ValidateError::NodeCountMismatch);
        }
        Ok(())
    }

    pub fn shape(&self) -> Shape {
        base_stats::shape(&self.arena, self.order, self.root)
    }

    pub fn render(&self, w: &mut dyn Write, indent: &str) -> io::Result<()> {
        base_stats::render(&self.arena, self.order, self.root, w, indent)
    }

    // No teardown section: dropping the tree drops the arena, and with it
    // every node. The Zig twin has to choose between walking the tree and
    // releasing a whole allocator.
}

/// The tree that inserting 10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15 in that
/// order produces at M = 4 (chapter 04 shows how; chapter 05 prints it):
///
/// ```text
///              [6 10 20]
/// [1 3 5]  [7]  [12 15 17]  [25 30]
/// ```
pub fn canonical(t: &mut HandTree) -> Result<(), OutOfNodes> {
    assert!(t.root.is_none() && t.order == 4);
    let a = t.leaf(&[1, 3, 5])?;
    let b = t.leaf(&[7])?;
    let c = t.leaf(&[12, 15, 17])?;
    let d = t.leaf(&[25, 30])?;
    t.root = Some(t.interior(&[6, 10, 20], &[a, b, c, d])?);
    Ok(())
}

/// The canonical keys in insertion order.
pub const CANONICAL_KEYS: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;

    fn rendered(t: &HandTree) -> String {
        let mut out = Vec::new();
        t.render(&mut out, "").unwrap();
        String::from_utf8(out).unwrap()
    }

    const CANONICAL_TEXT: &str = "[6 10 20]\n[1 3 5] [7] [12 15 17] [25 30]\n";

    #[test]
    fn the_canonical_tree_shape_search_validate() {
        let mut t = HandTree::new(4);
        canonical(&mut t).unwrap();
        assert_eq!(t.validate(), Ok(()));
        assert_eq!(rendered(&t), CANONICAL_TEXT);
        let want = Shape {
            height: 2,
            nodes: 5,
            leaves: 4,
            keys: 12,
            capacity: 15,
        };
        assert_eq!(t.shape(), want);
        for key in CANONICAL_KEYS {
            assert_eq!(t.get(key), Some(value_of(key)));
        }
        for key in [0, 2, 4, 8, 9, 11, 16, 21, 31, u64::MAX] {
            assert_eq!(t.get(key), None);
        }
    }

    /// A two-level tree: `seps` in the root above the given leaves.
    fn two_levels(order: usize, seps: &[u64], leaves: &[&[u64]]) -> HandTree {
        let mut t = HandTree::new(order);
        let ids: Vec<NodeId> = leaves.iter().map(|keys| t.leaf(keys).unwrap()).collect();
        t.root = Some(t.interior(seps, &ids).unwrap());
        t
    }

    /// Exercise 1 (b): [30] above [10 20] and [40], five leaves of two keys.
    fn one_key_interior(order: usize) -> HandTree {
        let mut t = HandTree::new(order);
        let l: Vec<NodeId> = [[2, 5], [12, 15], [22, 25], [32, 35], [42, 45]]
            .iter()
            .map(|keys| t.leaf(keys).unwrap())
            .collect();
        let left = t.interior(&[10, 20], &l[0..3]).unwrap();
        let right = t.interior(&[40], &l[3..5]).unwrap();
        t.root = Some(t.interior(&[30], &[left, right]).unwrap());
        t
    }

    #[test]
    fn order_5_the_minimum_fill_is_two_keys_except_in_the_root() {
        // The README's order 5 example and the three trees of exercise 1. At
        // M = 4 the minimum is one key, so rule 4 only says "not empty"; at
        // M = 5 it is ceil(5/2) - 1 = 2 and a one-key node below the root is
        // an error.

        // README: valid, every size from the minimum (2) to the maximum (4).
        let valid = two_levels(5, &[10, 20], &[&[2, 5], &[12, 15, 17], &[25, 30, 35, 40]]);
        assert_eq!(valid.validate(), Ok(()));

        // README: the middle leaf has one key. Broken at M = 5, legal at M = 4.
        let thin: [&[u64]; 3] = [&[2, 5], &[15], &[25, 30, 35]];
        assert_eq!(
            two_levels(5, &[10, 20], &thin).validate(),
            Err(ValidateError::NodeUnderfull)
        );
        assert_eq!(two_levels(4, &[10, 20], &thin).validate(), Ok(()));

        // Exercise 1 (a): a root with one key is legal at every order.
        let a = two_levels(5, &[20], &[&[5, 10, 15], &[25, 30]]);
        assert_eq!(a.validate(), Ok(()));

        // Exercise 1 (b): interior node [40] is not the root and has one key.
        assert_eq!(
            one_key_interior(5).validate(),
            Err(ValidateError::NodeUnderfull)
        );
        assert_eq!(one_key_interior(4).validate(), Ok(())); // a legal 2-3-4 tree

        // Exercise 1 (c): every node is full enough, but 21 is right of separator 20.
        let c = two_levels(5, &[10, 20], &[&[2, 5], &[12, 21], &[25, 30]]);
        assert_eq!(c.validate(), Err(ValidateError::KeyOutsideParentBounds));
        assert_eq!(c.get(21), None); // stored, but a search goes to [25 30]
    }

    #[test]
    fn every_u64_is_a_legal_key_the_largest_ones_can_be_stored_and_found() {
        // Regression: value_of multiplied with `*`, which panics above
        // u64::MAX / 10 in a debug build.
        let max = u64::MAX;
        let mut t = HandTree::new(4);
        let low = t.leaf(&[0, max / 10]).unwrap();
        let high = t.leaf(&[max - 1, max]).unwrap();
        t.root = Some(t.interior(&[max / 10 + 1], &[low, high]).unwrap());
        assert_eq!(t.validate(), Ok(()));
        assert_eq!(t.get(max / 10), Some(max / 10 * 10)); // the last key whose value does not wrap
        assert_eq!(t.get(max / 10 + 1), Some(value_of(max / 10 + 1)));
        assert_eq!(t.get(max - 1), Some(value_of(max - 1)));
        assert_eq!(t.get(max), Some(value_of(max)));
        assert_eq!(value_of(max), max - 9); // (2^64 - 1) * 10 mod 2^64
        assert_eq!(t.get(max - 2), None);
    }

    #[test]
    fn arena_nodes_are_neighbours_ids_in_creation_order() {
        let mut t = HandTree::new(4);
        canonical(&mut t).unwrap();
        // Leaves were created first, left to right, the root last.
        let root = t.root.unwrap();
        assert_eq!(
            t.arena[root].children,
            [NodeId(0), NodeId(1), NodeId(2), NodeId(3)]
        );
        assert_eq!(root, NodeId(4));
        assert_eq!(t.arena.len(), 5);
    }

    #[test]
    fn allocation_failure_at_every_point_of_a_build_leaks_nothing() {
        // Rust has nothing to leak here (the arena owns every node); what
        // is checked is that every failure point reports OutOfNodes.
        let keys: Vec<u64> = (0..200).map(|i| i * 3).collect();
        let mut full = HandTree::new(4);
        full.from_sorted(&keys).unwrap();
        let needed = full.arena.len();
        for budget in 0..needed {
            let mut t = HandTree::new(4);
            t.arena.budget = Some(budget);
            assert_eq!(t.from_sorted(&keys), Err(OutOfNodes));
            assert!(t.root.is_none());
            assert_eq!(t.arena.len(), budget);
        }
        let mut t = HandTree::new(4);
        t.arena.budget = Some(needed);
        assert_eq!(t.from_sorted(&keys), Ok(()));
        assert_eq!(t.validate(), Ok(()));
    }

    #[test]
    fn allocation_failure_the_builder_reports_it() {
        let mut t = HandTree::new(4);
        t.arena.budget = Some(2);
        let a = t.leaf(&[1, 2]).unwrap();
        let b = t.leaf(&[4, 5]).unwrap();
        assert_eq!(t.interior(&[3], &[a, b]), Err(OutOfNodes));
        assert_eq!(t.arena.len(), 2); // the failed node was not stored
        assert_eq!(t.len, 4); // and its key was not counted
    }

    #[test]
    fn from_sorted_valid_and_of_minimal_height_for_every_size_and_several_orders() {
        let keys: Vec<u64> = (0..400).map(|i| i * 2 + 1).collect();
        for order in [3, 4, 5, 6, 7, 16] {
            for n in 0..=keys.len() {
                let mut t = HandTree::new(order);
                t.from_sorted(&keys[..n]).unwrap();
                assert_eq!(t.validate(), Ok(()), "order {order}, {n} keys");
                assert_eq!(t.len, n);
                assert_eq!(t.shape().height, height::min_height(order as u64, n as u64));
            }
        }
    }

    #[test]
    fn seeded_model_test_get_and_in_order_agree_with_an_oracle() {
        // The oracle is the simplest thing that can answer "is k present?":
        // one bool per possible key.
        const KEY_SPACE: u64 = 1500;
        for order in [3, 4, 5, 8] {
            for seed in [1, 2, 3] {
                let mut prng = SplitMix64::new(seed * 100 + order as u64);
                let present: Vec<bool> = (0..KEY_SPACE).map(|_| prng.chance(seed, 4)).collect();
                let sorted: Vec<u64> = (0..KEY_SPACE).filter(|&k| present[k as usize]).collect();
                let mut t = HandTree::new(order);
                t.from_sorted(&sorted).unwrap();
                assert_eq!(t.validate(), Ok(()));

                for key in 0..KEY_SPACE {
                    let want = present[key as usize].then(|| value_of(key));
                    assert_eq!(t.get(key), want);
                }
                let mut seen = Vec::new();
                t.in_order(|key, value| {
                    assert_eq!(value, value_of(key));
                    seen.push(key);
                });
                assert_eq!(seen, sorted);
            }
        }
    }
}
