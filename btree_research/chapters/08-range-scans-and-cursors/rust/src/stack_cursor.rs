//! Cursor design 2: a root-to-leaf path, and NO sibling links.
//!
//! The position is a stack of frames, one per internal node on the path:
//! "in node N, I went down child number C". To reach the next leaf the
//! cursor climbs until some ancestor has a child to the right of the one it
//! took, steps to that child, and descends along the left edge. This is how
//! a SQLite-format tree (Turso) is scanned: its pages have no sibling links
//! at all, so the path is the only way to find a neighbour.
//!
//! What it buys: splits and merges have no leaf chain to maintain.
//! What it costs: the cursor is bigger (a frame per level), and crossing a
//! leaf boundary touches at least the parent as well.
//!
//! The functions below never read `leaf.prev`, `leaf.next`,
//! `tree.first_leaf` or `tree.last_leaf`; a test scrambles those fields to
//! prove it.

use crate::base_arena::NodeId;
use crate::base_node::{Entry, Kind};
use crate::base_search::child_index;
use crate::base_tree::BPlusTree;
use crate::cursor::{Cursor, Landing, Position, Seek, Stats, landing};
use crate::link_cursor::entry_at;

pub type StackCursor = Cursor<StackPosition>;

/// Most frames a path can need. Handles are 32 bits, so a tree has fewer
/// than 2^32 nodes; every internal node has at least 2 children, so a tree
/// of height h has at least 2^(h-1) leaves; hence h <= 32 and a path has at
/// most 31 internal nodes. (Turso uses the same idea with a fixed limit of
/// 20 levels and treats a deeper tree as corrupt.)
pub const MAX_DEPTH: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame {
    /// An internal node on the path.
    pub node: NodeId,
    /// Which of its children the path continues into (0 ..= node.len).
    pub child: usize,
}

#[derive(Clone, Copy)]
enum Step {
    Forward,
    Backward,
}

#[derive(Debug)]
pub struct StackPosition {
    /// frames[0] is the root, the last frame is the leaf's parent. Capacity
    /// for `MAX_DEPTH` frames is reserved ONCE, so seeking and stepping
    /// never allocate (`push` stays within the capacity).
    frames: Vec<Frame>,
    pub leaf: NodeId,
    pub index: usize,
}

/// Written by hand: the derived `Clone` copies a `Vec` with a capacity of
/// only its length, so a clone would have to allocate on a later re-seek in
/// a taller tree. A clone must keep the property stated on `frames`.
impl Clone for StackPosition {
    fn clone(&self) -> Self {
        let mut frames = Vec::with_capacity(MAX_DEPTH);
        frames.extend_from_slice(&self.frames);
        StackPosition {
            frames,
            leaf: self.leaf,
            index: self.index,
        }
    }
}

impl Default for StackPosition {
    fn default() -> Self {
        Self::new()
    }
}

impl StackPosition {
    pub fn new() -> Self {
        Self::with_buffer(Vec::new())
    }

    /// Reuses the allocation of an earlier position (see `into_buffer`).
    /// This is Rust's version of Zig's `arena.reset(.retain_capacity)`:
    /// the memory of the last scan serves the next one.
    pub fn with_buffer(mut buffer: Vec<Frame>) -> Self {
        buffer.clear();
        buffer.reserve_exact(MAX_DEPTH);
        StackPosition {
            frames: buffer,
            leaf: NodeId::NIL,
            index: 0,
        }
    }

    pub fn into_buffer(self) -> Vec<Frame> {
        self.frames
    }

    /// The internal part of the path, root first.
    pub fn path(&self) -> &[Frame] {
        &self.frames
    }

    /// Walks down from `start` to a leaf, pushing a frame per internal node.
    fn descend(
        &mut self,
        tree: &BPlusTree,
        start: NodeId,
        target: Seek,
        stats: &mut Stats,
    ) -> NodeId {
        let mut id = start;
        loop {
            let n = tree.nodes.get(id);
            stats.node_visits += 1;
            match &n.kind {
                Kind::Leaf(_) => return id,
                Kind::Internal(internal) => {
                    let child = match target {
                        Seek::First => 0,
                        Seek::Last => n.len,
                        Seek::Ge(key) | Seek::Gt(key) | Seek::Le(key) | Seek::Lt(key) => {
                            child_index(n.key_slice(), key)
                        }
                    };
                    assert!(self.frames.len() < MAX_DEPTH);
                    self.frames.push(Frame { node: id, child });
                    id = internal.children[child];
                }
            }
        }
    }

    fn settle_forward(
        &mut self,
        tree: &BPlusTree,
        start: usize,
        stats: &mut Stats,
    ) -> Option<Entry> {
        let mut i = start;
        loop {
            let n = tree.nodes.get(self.leaf);
            if i < n.len {
                self.index = i;
                return Some(entry_at(n, i));
            }
            if !self.step_leaf(tree, Step::Forward, stats) {
                return None;
            }
            i = 0;
        }
    }

    fn settle_backward(
        &mut self,
        tree: &BPlusTree,
        count: usize,
        stats: &mut Stats,
    ) -> Option<Entry> {
        let mut n_qualifying = count;
        loop {
            let n = tree.nodes.get(self.leaf);
            if n_qualifying > 0 {
                self.index = n_qualifying - 1;
                return Some(entry_at(n, self.index));
            }
            if !self.step_leaf(tree, Step::Backward, stats) {
                return None;
            }
            n_qualifying = tree.nodes.get(self.leaf).len;
        }
    }

    /// Moves to the neighbouring leaf using only the path: pop, step, push.
    /// Returns false (with an empty stack) if there is no such leaf.
    fn step_leaf(&mut self, tree: &BPlusTree, direction: Step, stats: &mut Stats) -> bool {
        while let Some(frame) = self.frames.last_mut() {
            let parent = tree.nodes.get(frame.node);
            stats.node_visits += 1; // back up in the parent
            let has_sibling = match direction {
                Step::Forward => frame.child < parent.len,
                Step::Backward => frame.child > 0,
            };
            if has_sibling {
                // Entering a subtree from the left we want its first leaf;
                // from the right, its last.
                let edge = match direction {
                    Step::Forward => {
                        frame.child += 1;
                        Seek::First
                    }
                    Step::Backward => {
                        frame.child -= 1;
                        Seek::Last
                    }
                };
                let subtree = parent.internal().children[frame.child];
                self.leaf = self.descend(tree, subtree, edge, stats);
                return true;
            }
            self.frames.pop(); // this ancestor has nothing further: pop it
        }
        self.leaf = NodeId::NIL;
        false
    }
}

impl Position for StackPosition {
    fn seek(&mut self, tree: &BPlusTree, target: Seek, stats: &mut Stats) -> Option<Entry> {
        self.frames.clear();
        self.leaf = NodeId::NIL;
        if tree.root.is_nil() {
            return None; // empty tree
        }
        // `First` and `Last` are descents too (along the left or right
        // edge): without links there is no other way to find the end leaves.
        self.leaf = self.descend(tree, tree.root, target, stats);
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
