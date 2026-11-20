//! Cursor design 1: leaf handle + index, moving along the sibling links.
//!
//! This is the textbook B+tree scan and the shape of a Postgres index scan:
//! descend once, then walk the leaf level and never look at an internal node
//! again. The position is two words and never allocates.
//!
//! The price is paid elsewhere: every leaf split and merge has to maintain
//! the `prev` / `next` links (chapter 07), and on disk a split must write the
//! neighbour's page too.

use crate::base_arena::NodeId;
use crate::base_node::{Entry, Kind, Node};
use crate::base_search::child_index;
use crate::base_tree::BPlusTree;
use crate::cursor::{Cursor, Landing, Position, Seek, Stats, landing};

pub type LinkCursor = Cursor<LinkPosition>;

#[derive(Debug, Clone)]
pub struct LinkPosition {
    pub leaf: NodeId,
    pub index: usize,
}

impl Default for LinkPosition {
    fn default() -> Self {
        Self::new()
    }
}

impl LinkPosition {
    pub fn new() -> Self {
        LinkPosition {
            leaf: NodeId::NIL,
            index: 0,
        }
    }

    /// Moves to entry `start` of the current leaf, or, if the leaf has no
    /// such entry, to the first entry of the next leaf: ONE link, no parent.
    fn settle_forward(&mut self, tree: &BPlusTree, start: usize, stats: &mut Stats) -> Option<Entry> {
        let mut i = start;
        while !self.leaf.is_nil() {
            let n = tree.nodes.get(self.leaf);
            if i < n.len {
                self.index = i;
                return Some(entry_at(n, i));
            }
            self.leaf = n.leaf().next;
            if !self.leaf.is_nil() {
                stats.node_visits += 1;
            }
            i = 0;
        }
        None // ran off the right end of the chain
    }

    /// Moves to the last of the first `count` entries of the current leaf,
    /// or, if `count` is 0, to the last entry of the previous leaf.
    fn settle_backward(&mut self, tree: &BPlusTree, count: usize, stats: &mut Stats) -> Option<Entry> {
        let mut n_qualifying = count;
        loop {
            let n = tree.nodes.get(self.leaf);
            if n_qualifying > 0 {
                self.index = n_qualifying - 1;
                return Some(entry_at(n, self.index));
            }
            self.leaf = n.leaf().prev;
            if self.leaf.is_nil() {
                return None; // ran off the left end
            }
            stats.node_visits += 1;
            n_qualifying = tree.nodes.get(self.leaf).len;
        }
    }
}

impl Position for LinkPosition {
    fn seek(&mut self, tree: &BPlusTree, target: Seek, stats: &mut Stats) -> Option<Entry> {
        self.leaf = match target {
            // The tree keeps handles of both ends of the chain: no descent.
            Seek::First => tree.first_leaf,
            Seek::Last => tree.last_leaf,
            Seek::Ge(key) | Seek::Gt(key) | Seek::Le(key) | Seek::Lt(key) => descend(tree, key, stats),
        };
        if self.leaf.is_nil() {
            return None; // empty tree
        }
        if matches!(target, Seek::First | Seek::Last) {
            stats.node_visits += 1;
        }
        match landing(tree.nodes.get(self.leaf).key_slice(), target) {
            Landing::Forward(i) => self.settle_forward(tree, i, stats),
            Landing::Backward(n) => self.settle_backward(tree, n, stats),
        }
    }

    fn next(&mut self, tree: &BPlusTree, stats: &mut Stats) -> Option<Entry> {
        self.settle_forward(tree, self.index + 1, stats)
    }

    fn prev(&mut self, tree: &BPlusTree, stats: &mut Stats) -> Option<Entry> {
        self.settle_backward(tree, self.index, stats)
    }

    fn entry(&self, tree: &BPlusTree) -> Entry {
        entry_at(tree.nodes.get(self.leaf), self.index)
    }
}

/// Root-to-leaf descent for `key`, counting the nodes on the way.
/// (`BPlusTree::find_leaf` without the counter.)
fn descend(tree: &BPlusTree, key: u64, stats: &mut Stats) -> NodeId {
    let mut id = tree.root;
    if id.is_nil() {
        return NodeId::NIL;
    }
    loop {
        let n = tree.nodes.get(id);
        stats.node_visits += 1;
        match &n.kind {
            Kind::Leaf(_) => return id,
            Kind::Internal(internal) => id = internal.children[child_index(n.key_slice(), key)],
        }
    }
}

pub fn entry_at(n: &Node, i: usize) -> Entry {
    Entry {
        key: n.keys[i],
        value: n.leaf().values[i],
    }
}
