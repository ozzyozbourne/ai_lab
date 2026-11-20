//! Search in a B-link tree: one shared latch at a time, and "move right".
//!
//! The descent is written as a little state machine (`Descent`) that visits
//! exactly one node per `step`. Between two steps it holds NO latch, only the
//! handle of the node it wants to visit next. That is precisely the moment at
//! which another thread may split that node, and writing the descent this way
//! lets a single-threaded test put a split exactly there.

use std::sync::atomic::Ordering;

use crate::base_handle::NodeId;
use crate::base_node::Kind;
use crate::base_search::{child_index, lower_bound};
use crate::blink::BLinkTree;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// The real algorithm.
    FollowRightLinks,
    /// The broken variant, for demonstration: behave like a plain B+tree and
    /// trust that the node we were sent to still covers the key.
    IgnoreRightLinks,
}

/// What one visit did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Internal node: followed the downlink to `to`.
    Descended { from: NodeId, to: NodeId },
    /// The key is at or above the node's high key: followed the right link.
    MovedRight {
        from: NodeId,
        to: NodeId,
        high_key: u64,
    },
    /// Leaf reached and searched: the answer.
    Done { leaf: NodeId, value: Option<u64> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Lookup {
    pub value: Option<u64>,
    /// Right links followed on the way.
    pub moves_right: usize,
    /// Nodes visited (each under its own shared latch).
    pub visited: usize,
}

#[derive(Debug, Clone)]
pub struct Descent {
    pub key: u64,
    pub mode: Mode,
    /// The node to visit next. No latch is held on it.
    pub next: NodeId,
    pub moves_right: usize,
    pub visited: usize,
}

impl Descent {
    /// Reads the root pointer and nothing else.
    pub fn begin(tree: &BLinkTree, key: u64, mode: Mode) -> Descent {
        Descent {
            key,
            mode,
            next: tree.root_id(),
            moves_right: 0,
            visited: 0,
        }
    }

    /// Latches `next` (shared), looks at it, decides where to go, unlatches.
    /// Do not call again after it returned `Step::Done`.
    pub fn step(&mut self, tree: &BLinkTree) -> Step {
        let id = self.next;
        // The guard is dropped at the end of this function, BEFORE the next
        // node is latched: there is never a moment with two latches, so
        // there is nothing to deadlock on.
        let page = tree.read(id);
        self.visited += 1;

        // Move right. The node may have split since we were given its
        // handle; if so, the keys we want moved into a new right sibling.
        // Postgres: _bt_moveright, nbtsearch.c:309-313.
        if self.mode == Mode::FollowRightLinks && page.is_beyond(self.key) {
            self.next = page.right;
            self.moves_right += 1;
            tree.moves_right.fetch_add(1, Ordering::Relaxed);
            return Step::MovedRight {
                from: id,
                to: page.right,
                high_key: page.high_key.expect("is_beyond implies a high key"),
            };
        }

        let keys = page.node.key_slice();
        match &page.node.kind {
            Kind::Internal(internal) => {
                self.next = internal.children[child_index(keys, self.key)];
                Step::Descended {
                    from: id,
                    to: self.next,
                }
            }
            Kind::Leaf(leaf) => {
                let i = lower_bound(keys, self.key);
                let value = (i < keys.len() && keys[i] == self.key).then(|| leaf.values[i]);
                Step::Done { leaf: id, value }
            }
        }
    }
}

pub(crate) fn lookup(tree: &BLinkTree, key: u64, mode: Mode) -> Lookup {
    let mut d = Descent::begin(tree, key, mode);
    loop {
        if let Step::Done { value, .. } = d.step(tree) {
            return Lookup {
                value,
                moves_right: d.moves_right,
                visited: d.visited,
            };
        }
    }
}
