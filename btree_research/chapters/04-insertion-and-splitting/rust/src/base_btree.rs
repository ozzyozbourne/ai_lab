// Copied from chapters/05-deletion-and-rebalancing/rust/src/btree.rs; fixes go there first
//! Trimmed for chapter 04: no `delete`, no delete counters.
//!
//! The in-memory B-tree with search and insert: this file only ties the
//! parts together (see lib.rs for the list of files).

use crate::base_node::NodeId;
use crate::base_pool::{OutOfNodes, Slab};
use crate::base_stats::Shape;
use crate::base_validate::ValidateError;
use crate::{
    base_insert as insert, base_search as search, base_stats as stats, base_validate as validate,
};
use std::io::{self, Write};

/// How often each structural change happened since the tree was created.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Counters {
    // Written by base_insert.rs and topdown.rs.
    /// Node splits, including root splits.
    pub splits: u64,
    /// Splits of the root: each one made the tree one level taller.
    pub root_splits: u64,
}

/// A B-tree of order `order` (at most `order` children, at most `order - 1`
/// keys per node) mapping u64 keys to u64 values, with nodes in a [`Slab`].
///
/// ```
/// let mut tree = ch04_insertion_and_splitting::base_btree::BTree::new(4);
/// assert_eq!(tree.put(10, 100), Ok(None));
/// assert_eq!(tree.put(10, 101), Ok(Some(100)));
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

    /// `visit(key, value)` for every entry, ascending.
    pub fn in_order(&self, mut visit: impl FnMut(u64, u64)) {
        search::in_order(&self.pool, self.root, &mut visit);
    }

    /// `visit(key, value)` for every entry with lo <= key < hi, ascending.
    /// (Half-open, so the key `u64::MAX` is out of reach: see base_search.rs.)
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
