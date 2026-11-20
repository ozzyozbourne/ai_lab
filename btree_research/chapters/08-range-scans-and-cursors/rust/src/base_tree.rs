// Copied from chapters/07-bplus-trees/rust/src/tree.rs; behaviour unchanged (only the
// module paths were renamed to base_*). Do not edit here.
//! The B+tree object: its fields and constructors. The algorithms live in one
//! file each (search, insert, delete, walk, validate) as further
//! `impl BPlusTree` blocks.
//!
//! Invariants (checked by `validate`):
//!   1. Entries (key + value) are stored only in leaves.
//!   2. Keys inside a node are strictly ascending.
//!   3. An internal node with k keys has k+1 children; child i holds only
//!      keys in [keys[i-1], keys[i]). Separators route; they need not exist
//!      as keys in any leaf.
//!   4. A node has at most M-1 keys; every node except the root has at least
//!      ceil(M/2)-1; an internal root has at least 1 key.
//!   5. All leaves are at the same depth (`height`).
//!   6. The leaves form a doubly linked list in key order from `first_leaf`
//!      to `last_leaf`.

use crate::base_arena::{Arena, NodeId};
use crate::base_node::{MAX_ORDER, Node};

/// Counters of structural changes. Counts only; used by the demo program to
/// say what an operation did, and by tests to prove a path was exercised.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub leaf_splits: usize,
    pub internal_splits: usize,
    pub borrows: usize,
    pub merges: usize,
}

#[derive(Debug)]
pub struct BPlusTree {
    /// M: maximum number of children of an internal node (Knuth's order).
    pub order: usize,
    pub nodes: Arena<Node>,
    /// `NIL` when the tree is empty.
    pub root: NodeId,
    /// Ends of the leaf chain; `NIL` when the tree is empty.
    pub first_leaf: NodeId,
    pub last_leaf: NodeId,
    /// Number of levels: 0 for an empty tree, 1 when the root is a leaf.
    pub height: usize,
    /// Number of entries.
    pub count: usize,
    pub stats: Stats,
}

impl BPlusTree {
    /// Does not allocate; the first `put` creates the root leaf.
    pub fn new(order: usize) -> BPlusTree {
        Self::with_node_budget(order, usize::MAX)
    }

    /// A tree that may never hold more than `max_nodes` nodes. `put` returns
    /// `Err(OutOfNodes)` instead of exceeding it. This mirrors the Zig tests
    /// that make the allocator fail.
    pub fn with_node_budget(order: usize, max_nodes: usize) -> BPlusTree {
        assert!((3..=MAX_ORDER).contains(&order));
        BPlusTree {
            order,
            nodes: Arena::with_budget(max_nodes),
            root: NodeId::NIL,
            first_leaf: NodeId::NIL,
            last_leaf: NodeId::NIL,
            height: 0,
            count: 0,
            stats: Stats::default(),
        }
    }

    /// Most keys a node may hold: M-1.
    pub fn max_keys(&self) -> usize {
        self.order - 1
    }

    /// Fewest keys a non-root node may hold: ceil(M/2)-1.
    pub fn min_keys(&self) -> usize {
        self.order.div_ceil(2) - 1
    }

    pub fn len(&self) -> usize {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }
}
