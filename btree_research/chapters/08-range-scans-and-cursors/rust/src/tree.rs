//! `Tree`: the chapter 07 B+tree plus ONE new field, a change counter.
//!
//! The B+tree itself is copied unchanged (`base_*.rs`). This wrapper adds
//! what cursors need to notice that the tree changed between two of their
//! steps: `version` goes up whenever an entry is added or removed. Those are
//! exactly the operations that can shift entries inside a leaf, split or
//! merge nodes, and free a node whose handle is then reused for another one.
//!
//! An overwrite (`put` on an existing key) moves nothing, so it does not
//! count: a cursor standing on that entry simply sees the new value.

use std::ops::RangeBounds;

use crate::base_arena::OutOfNodes;
use crate::base_tree::BPlusTree;
use crate::base_validate::Violation;
use crate::bounds::Direction;
use crate::cursor::Cursor;
use crate::link_cursor::LinkPosition;
use crate::scan::{Scan, ScanIter};

#[derive(Debug)]
pub struct Tree {
    pub base: BPlusTree,
    /// Number of inserts and deletes so far. A cursor remembers the value it
    /// saw when it computed its position; a different value means "your
    /// (node, index) may point anywhere now: seek again by key".
    pub version: u64,
}

impl Tree {
    pub fn new(order: usize) -> Tree {
        Self::with_node_budget(order, usize::MAX)
    }

    /// A tree that may never hold more than `max_nodes` nodes (Rust's
    /// stand-in for Zig's allocation failure, see chapter 07).
    pub fn with_node_budget(order: usize, max_nodes: usize) -> Tree {
        Tree {
            base: BPlusTree::with_node_budget(order, max_nodes),
            version: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.base.len()
    }

    pub fn is_empty(&self) -> bool {
        self.base.is_empty()
    }

    pub fn get(&self, key: u64) -> Option<u64> {
        self.base.get(key)
    }

    /// Inserts or overwrites; returns the previous value if the key existed.
    /// On `Err(OutOfNodes)` neither the tree nor `version` has changed.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
        let old = self.base.put(key, value)?;
        if old.is_none() {
            self.version += 1; // a new entry: positions may have moved
        }
        Ok(old)
    }

    pub fn delete(&mut self, key: u64) -> Option<u64> {
        let removed = self.base.delete(key);
        if removed.is_some() {
            self.version += 1;
        }
        removed
    }

    pub fn validate(&self) -> Result<(), Violation> {
        self.base.validate()
    }

    /// Entries inside `range` in ascending order, through a leaf-link cursor
    /// (no allocation). Accepts range syntax (`6..17`, `..=17`, `..`) or a
    /// pair of `Bound`s. For the other cursor, or to change the tree during
    /// the scan, build a `Scan` directly.
    pub fn range(&self, range: impl RangeBounds<u64>) -> ScanIter<'_, LinkPosition> {
        Scan::new(Cursor::new(LinkPosition::new()), range, Direction::Forward).iter(self)
    }

    /// The same entries in descending order.
    pub fn range_backward(&self, range: impl RangeBounds<u64>) -> ScanIter<'_, LinkPosition> {
        Scan::new(Cursor::new(LinkPosition::new()), range, Direction::Backward).iter(self)
    }
}
