//! SECTION A: the typed arena.
//!
//! The Zig twin of this chapter puts nodes into a bump allocator: memory is
//! handed out front to back, single nodes are never given back, and
//! everything is released at once. The Rust idiom with the same behaviour is
//! a `Vec<Node>` that is only ever pushed to:
//!
//! ```text
//! alloc(node) -> Result<NodeId, OutOfNodes>     push, return the index
//! arena[id]                                     the node
//! drop(arena)                                   frees every node at once
//! ```
//!
//! A node is named by its index (`NodeId`, a `u32`), not by a pointer. That
//! is what makes this safe Rust: an index stays valid when the `Vec`
//! reallocates, it is `Copy`, and a parent can hold the ids of its children
//! without owning or borrowing them.
//!
//! There is no `free`. The trees of this chapter are built once and never
//! change, so no node dies before the whole tree does. Chapter 05 deletes
//! nodes one by one and turns this arena into a slab with a free list.
//!
//! Rust aborts the process when the global allocator fails, so "out of
//! memory" is modelled by the arena itself: with `budget = Some(n)` the
//! arena refuses to hold more than n nodes. (Zig tests the real thing with
//! `std.testing.FailingAllocator`.)

use crate::base_node::{Node, NodeId};
use std::ops::{Index, IndexMut};

/// The arena's node budget is exhausted (the stand-in for `error.OutOfMemory`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfNodes;

impl std::fmt::Display for OutOfNodes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("node budget exhausted")
    }
}

impl std::error::Error for OutOfNodes {}

#[derive(Debug, Default)]
pub struct Arena {
    nodes: Vec<Node>,
    /// `None`: unlimited. `Some(n)`: at most n nodes.
    pub budget: Option<usize>,
}

impl Arena {
    pub fn new() -> Self {
        Self::default()
    }

    /// Stores the node and returns its id. Ids are handed out in order:
    /// 0, 1, 2, ... (the bump cursor is simply `nodes.len()`).
    pub fn alloc(&mut self, node: Node) -> Result<NodeId, OutOfNodes> {
        if self.budget.is_some_and(|budget| self.nodes.len() >= budget) {
            return Err(OutOfNodes);
        }
        let id = NodeId(u32::try_from(self.nodes.len()).expect("more than 2^32 nodes"));
        self.nodes.push(node);
        Ok(id)
    }

    /// Number of nodes ever allocated (none can be freed on its own).
    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }
}

impl Index<NodeId> for Arena {
    type Output = Node;
    fn index(&self, id: NodeId) -> &Node {
        &self.nodes[id.0 as usize]
    }
}

impl IndexMut<NodeId> for Arena {
    fn index_mut(&mut self, id: NodeId) -> &mut Node {
        &mut self.nodes[id.0 as usize]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leaf(key: u64) -> Node {
        let mut node = Node::new(true);
        node.insert_entry(0, key, key);
        node
    }

    #[test]
    fn ids_are_handed_out_one_after_the_other() {
        let mut arena = Arena::new();
        assert!(arena.is_empty());
        let x = arena.alloc(leaf(1)).unwrap();
        let y = arena.alloc(leaf(3)).unwrap();
        assert_eq!((x, y), (NodeId(0), NodeId(1)));
        assert_eq!(arena[x].keys, [1]); // y did not overwrite x
        arena[y].keys[0] = 4;
        assert_eq!(arena[y].keys, [4]);
        assert_eq!(arena.len(), 2);
    }

    #[test]
    fn ids_stay_valid_while_the_vec_grows() {
        // A pointer into a Vec would dangle after a reallocation; an index does not.
        let mut arena = Arena::new();
        let first = arena.alloc(leaf(7)).unwrap();
        for key in 0..10_000 {
            arena.alloc(leaf(key)).unwrap();
        }
        assert_eq!(arena[first].keys, [7]);
    }

    #[test]
    fn the_budget_reports_failure_and_the_arena_stays_usable() {
        let mut arena = Arena::new();
        arena.budget = Some(1);
        let a = arena.alloc(leaf(1)).unwrap();
        assert_eq!(arena.alloc(leaf(2)), Err(OutOfNodes));
        assert_eq!(arena.len(), 1);
        assert_eq!(arena[a].keys, [1]);
        arena.budget = None;
        assert!(arena.alloc(leaf(2)).is_ok());
    }
}
