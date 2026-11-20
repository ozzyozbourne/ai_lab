// Copied from chapters/05-deletion-and-rebalancing/rust/src/btree.rs
//! The complete in-memory B-tree: this file only ties the sections together.

use crate::base_node::NodeId;
use crate::base_pool::{OutOfNodes, Slab};
use crate::base_stats::Shape;
use crate::base_validate::ValidateError;
use crate::{delete, insert, search, stats, validate};
use std::io::{self, Write};

/// How often each structural change happened since the tree was created.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Counters {
    // Written by insert.rs.
    /// Node splits, including root splits.
    pub splits: u64,
    /// Splits of the root: each one made the tree one level taller.
    pub root_splits: u64,
    // Written by delete.rs.
    /// Deletes that hit a key in an interior node and replaced it with its
    /// in-order predecessor from a leaf.
    pub predecessor_swaps: u64,
    /// Underflows repaired by taking a key from the left sibling.
    pub borrows_left: u64,
    /// Underflows repaired by taking a key from the right sibling.
    pub borrows_right: u64,
    /// Underflows repaired by merging two siblings (one node freed).
    pub merges: u64,
    /// Times an empty interior root was replaced by its only child.
    pub root_shrinks: u64,
}

/// A B-tree of order `order` (at most `order` children, at most `order - 1`
/// keys per node) mapping u64 keys to u64 values, with nodes in a [`Slab`].
///
/// ```
/// let mut tree = ch05_deletion_and_rebalancing::btree::BTree::new(4);
/// tree.put(10, 100).unwrap();
/// assert_eq!(tree.delete(10), Some(100));
/// ```
#[derive(Debug)]
pub struct BTree {
    pub order: usize,
    /// `None` means the tree is empty: an empty tree owns no nodes.
    pub root: Option<NodeId>,
    /// Number of keys.
    pub len: usize,
    pub pool: Slab,
    pub counters: Counters,
}

impl BTree {
    pub fn new(order: usize) -> Self {
        assert!(order >= 3, "order 2 would allow nodes with zero keys");
        Self {
            order,
            root: None,
            len: 0,
            pool: Slab::new(),
            counters: Counters::default(),
        }
    }

    // No `deinit`: dropping the tree drops the slab, which drops every node.
    // The Zig twin has to walk the tree and return each node.

    pub fn get(&self, key: u64) -> Option<u64> {
        search::get(&self.pool, self.root, key)
    }

    /// Insert or overwrite. Returns the previous value of the key, if any.
    /// On `Err(OutOfNodes)` the tree, `counters` and `pool.usage` are exactly
    /// as before the call.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
        insert::put(self, key, value)
    }

    /// Remove a key. Returns its value, or `None` if it was not present.
    /// Never allocates, so it cannot fail.
    pub fn delete(&mut self, key: u64) -> Option<u64> {
        delete::delete(self, key)
    }

    /// `visit(key, value)` for every entry, ascending.
    pub fn in_order(&self, mut visit: impl FnMut(u64, u64)) {
        search::in_order(&self.pool, self.root, &mut visit);
    }

    /// `visit(key, value)` for every entry with lo <= key < hi, ascending.
    /// (Half-open, so the key `u64::MAX` is out of reach: see search.rs.)
    pub fn range(&self, lo: u64, hi: u64, mut visit: impl FnMut(u64, u64)) {
        search::range(&self.pool, self.root, lo, hi, &mut visit);
    }

    /// Checks every structural invariant, the key count, and that the pool's
    /// live-node counter matches the nodes reachable from the root.
    pub fn validate(&self) -> Result<(), ValidateError> {
        validate::validate(&self.pool, self.order, self.root, self.len)?;
        if self.shape().nodes as u64 != self.pool.usage.live() {
            return Err(ValidateError::NodeCountMismatch);
        }
        Ok(())
    }

    pub fn shape(&self) -> Shape {
        stats::shape(&self.pool, self.order, self.root)
    }

    pub fn render(&self, w: &mut dyn Write, indent: &str) -> io::Result<()> {
        stats::render(&self.pool, self.order, self.root, w, indent)
    }
}
