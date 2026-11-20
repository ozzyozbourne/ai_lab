// Copied from chapters/05-deletion-and-rebalancing/rust/src/btree.rs
// Changes for chapter 06: the `bug` field (`BTree::with_bug`), `Counters`
// replaced by `Coverage`, `validate` returns a `Violation` (what and where)
// and also compares the slab's occupied slots with the reachable nodes.
//! The complete in-memory B-tree of chapter 05, as the system under test.
//!
//! ```text
//! file              content                              needs
//! base_node.rs      the node type (chapter 03)           -
//! base_search.rs    get, in_order, range (chapter 03)    node
//! base_validate.rs  the invariants as code               node
//! base_stats.rs     shape, fill, text rendering          node
//! base_pool.rs      the slab: where nodes come from      node
//! base_insert.rs    put, split (chapter 04)              node, search, pool, btree
//! base_delete.rs    delete, borrow, merge, root shrink   node, search, pool, btree
//! coverage.rs       which branches ran (new in chapter 06)
//! ```

use crate::base_node::NodeId;
use crate::base_pool::{OutOfNodes, Slab};
use crate::base_stats::Shape;
use crate::base_validate::{ValidateError, Violation};
use crate::coverage::Coverage;
use crate::{base_delete, base_insert, base_search, base_stats, base_validate};
use std::io::{self, Write};

/// The deliberately broken variants. Each one changes ONE line of
/// base_insert.rs or base_delete.rs (search for "SEAM").
///
/// The Zig twin makes this a compile-time parameter of the tree type, so the
/// correct tree contains no trace of the faults. Here it is a plain field
/// tested at run time: the order is a run-time field already (base_node.rs),
/// and one more `match` on an enum costs a predictable branch. A zero-cost
/// Rust version would be a type parameter `BTree<F: Fault>` with an
/// associated `const BUG: Bug`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bug {
    None,
    /// insert: a split sends the median KEY up with its left neighbour's VALUE.
    SplitWrongValue,
    /// delete: a merge unlinks the emptied node but never frees its slot.
    MergeLeaksNode,
    /// delete: a borrow between interior nodes moves the key but not the child.
    BorrowForgetsChild,
    // The next two are not part of the chapter's story. They break the
    // rollback of a failed `put`, and exist so that tests.rs can show that
    // the HARNESS notices (a check nobody has seen fail is not a check).
    /// insert: a failed put hands back one reserved node too few.
    RollbackLeaksNode,
    /// insert: a failed put does not restore `pool.usage`.
    RollbackKeepsUsage,
}

impl Bug {
    /// The name used in the program output (same spelling as the Zig enum).
    pub fn name(self) -> &'static str {
        match self {
            Bug::None => "none",
            Bug::SplitWrongValue => "split_wrong_value",
            Bug::MergeLeaksNode => "merge_leaks_node",
            Bug::BorrowForgetsChild => "borrow_forgets_child",
            Bug::RollbackLeaksNode => "rollback_leaks_node",
            Bug::RollbackKeepsUsage => "rollback_keeps_usage",
        }
    }
}

/// A B-tree of order `order` (at most `order` children, at most `order - 1`
/// keys per node) mapping u64 keys to u64 values, with nodes in a [`Slab`].
///
/// ```
/// let mut tree = ch06_testing_a_btree::base_btree::BTree::new(4);
/// tree.put(10, 100).unwrap();
/// assert_eq!(tree.delete(10), Some(100));
/// ```
#[derive(Debug)]
pub struct BTree {
    pub order: usize,
    pub bug: Bug,
    /// `None` means the tree is empty: an empty tree owns no nodes.
    pub root: Option<NodeId>,
    /// Number of keys.
    pub len: usize,
    pub pool: Slab,
    /// Instrumentation, not state: it also counts failed puts.
    pub coverage: Coverage,
}

impl BTree {
    /// The correct tree.
    pub fn new(order: usize) -> Self {
        Self::with_bug(order, Bug::None)
    }

    pub fn with_bug(order: usize, bug: Bug) -> Self {
        assert!(order >= 3, "order 2 would allow nodes with zero keys");
        Self {
            order,
            bug,
            root: None,
            len: 0,
            pool: Slab::new(),
            coverage: Coverage::default(),
        }
    }

    // No `deinit`: dropping the tree drops the slab, which drops every node,
    // reachable or not. (The Zig twin has to walk the tree, and must not do
    // that when the tree is corrupt.)

    pub fn get(&self, key: u64) -> Option<u64> {
        base_search::get(&self.pool, self.root, key)
    }

    /// Insert or overwrite. Returns the previous value of the key, if any.
    /// On `Err(OutOfNodes)` the tree and `pool.usage` are exactly as before
    /// the call.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
        base_insert::put(self, key, value)
    }

    /// Remove a key. Returns its value, or `None` if it was not present.
    /// Never asks the slab for a node, so it cannot fail.
    pub fn delete(&mut self, key: u64) -> Option<u64> {
        base_delete::delete(self, key)
    }

    /// `visit(key, value)` for every entry, ascending.
    pub fn in_order(&self, mut visit: impl FnMut(u64, u64)) {
        base_search::in_order(&self.pool, self.root, &mut visit);
    }

    /// `visit(key, value)` for every entry with lo <= key < hi, ascending.
    pub fn range(&self, lo: u64, hi: u64, mut visit: impl FnMut(u64, u64)) {
        base_search::range(&self.pool, self.root, lo, hi, &mut visit);
    }

    /// Checks every structural invariant, the key count, and that no node
    /// was lost: the nodes reachable from the root must equal BOTH counts the
    /// slab keeps. `usage.live()` is the bookkeeping `put` and `delete`
    /// maintain; `live_slots()` is what the slab really holds. They differ
    /// when a failed `put` restores `usage` without freeing every slot it
    /// reserved.
    pub fn validate(&self) -> Result<(), Violation> {
        base_validate::validate(&self.pool, self.order, self.root, self.len)?;
        let reachable = self.shape().nodes;
        if reachable as u64 != self.pool.usage.live() || reachable != self.pool.live_slots() {
            return Err(Violation::whole_tree(ValidateError::NodeCountMismatch));
        }
        Ok(())
    }

    pub fn shape(&self) -> Shape {
        base_stats::shape(&self.pool, self.order, self.root)
    }

    pub fn render(&self, w: &mut dyn Write, indent: &str) -> io::Result<()> {
        base_stats::render(&self.pool, self.order, self.root, w, indent)
    }
}
