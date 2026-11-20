//! `validate`: checks every invariant listed in blink.rs and names the first
//! one that is broken.
//!
//! A B+tree checker walks from the root through child handles. That is not
//! enough here: a node whose downlink is still missing cannot be reached that
//! way. In a B-link tree the authoritative structure of a level is its LINKED
//! LIST (`level_head[l]`, then right links), so the checker walks every level
//! as a list and, next to it, the sequence of downlinks of the level above,
//! and demands that the two agree except where a flag says "split in
//! progress".
//!
//! Zig reads the pages without latching them. Safe Rust cannot, so this takes
//! shared latches (one or two at a time, never waiting for anything while no
//! writer runs). The result is meaningful only when no other thread is
//! modifying the tree.

use crate::base_handle::NodeId;
use crate::blink::{BLinkTree, MAX_LEVELS};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Violation {
    /// root / height / level_head disagree.
    BadRoot,
    /// A right link or child handle names a slot that was never allocated,
    /// or a level's list does not end.
    DanglingLink,
    /// A node is on the list of a level it does not belong to.
    WrongLevel,
    /// More than M-1 keys.
    NodeOverfull,
    /// Fewer than ceil(M/2)-1 keys in a non-root node, or an empty internal root.
    NodeUnderfull,
    /// Keys inside a node are not strictly ascending.
    KeysNotSorted,
    /// A key lies outside [left sibling's high key, own high key).
    KeyOutOfBounds,
    /// High key without right link or the reverse, or high keys not ascending.
    BrokenRightLink,
    /// INCOMPLETE_SPLIT set on a node that has no right sibling.
    BadSplitFlag,
    /// A node has no downlink although its left sibling is not flagged, or
    /// the downlinks of the parent level name other nodes than the list.
    MissingDownlink,
    /// The separator in front of a downlink is not the child's lower bound.
    SeparatorMismatch,
    /// `count` is not the number of entries in the leaves.
    WrongCount,
    /// Allocated nodes that are on no level's list.
    OrphanNode,
}

impl std::fmt::Display for Violation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for Violation {}

/// One downlink as the parent level sees it.
struct Downlink {
    child: NodeId,
    /// Lower bound the parent promises for the child (None = -infinity).
    low: Option<u64>,
}

/// Walks all downlinks of one level, left to right, across its nodes.
struct DownlinkCursor<'a> {
    tree: &'a BLinkTree,
    /// Used for the top level, which has no parent: one imaginary downlink
    /// to the root.
    virtual_root: Option<NodeId>,
    node: NodeId,
    index: usize,
    node_low: Option<u64>,
}

impl DownlinkCursor<'_> {
    fn next(&mut self) -> Option<Downlink> {
        if let Some(root) = self.virtual_root.take() {
            return Some(Downlink {
                child: root,
                low: None,
            });
        }
        if self.node.is_nil() {
            return None;
        }
        let p = self.tree.read(self.node);
        let link = Downlink {
            child: p.node.internal().children[self.index],
            low: if self.index == 0 {
                self.node_low
            } else {
                Some(p.node.keys[self.index - 1])
            },
        };
        self.index += 1;
        if self.index > p.node.len {
            self.node_low = p.high_key;
            self.node = p.right;
            self.index = 0;
        }
        Some(link)
    }
}

pub(crate) fn validate(tree: &BLinkTree) -> Result<(), Violation> {
    let allocated = tree.node_count();
    let root = tree.root_id();
    let meta = tree.meta_snapshot();
    let height = meta.height;
    if height == 0 || height > MAX_LEVELS {
        return Err(Violation::BadRoot);
    }
    if meta.level_head[height - 1] != root {
        return Err(Violation::BadRoot);
    }

    let mut nodes = 0usize;
    let mut entries = 0u64;
    for level in (0..height).rev() {
        let top = level + 1 == height;
        let mut downlinks = DownlinkCursor {
            tree,
            virtual_root: top.then_some(root),
            node: if top {
                NodeId::NIL
            } else {
                meta.level_head[level + 1]
            },
            index: 0,
            node_low: None,
        };

        let mut id = meta.level_head[level];
        let mut low: Option<u64> = None; // high key of the node to the left
        let mut left_is_incomplete = false;
        while !id.is_nil() {
            if id.index() >= allocated {
                return Err(Violation::DanglingLink);
            }
            nodes += 1;
            if nodes > allocated {
                return Err(Violation::DanglingLink); // a cycle
            }
            let p = tree.read(id);
            if p.level as usize != level || p.node.is_leaf() != (level == 0) {
                return Err(Violation::WrongLevel);
            }

            // Occupancy.
            let keys = p.node.key_slice();
            if keys.len() > tree.max_keys() {
                return Err(Violation::NodeOverfull);
            }
            let min = if id != root {
                tree.min_keys()
            } else if level == 0 {
                0
            } else {
                1
            };
            if keys.len() < min {
                return Err(Violation::NodeUnderfull);
            }

            // Keys: ascending, and inside [low, high_key). A separator of
            // an internal node is strictly above the node's lower bound.
            for (i, &k) in keys.iter().enumerate() {
                if i > 0 && keys[i - 1] >= k {
                    return Err(Violation::KeysNotSorted);
                }
                if low.is_some_and(|lo| k < lo || (level > 0 && k == lo)) {
                    return Err(Violation::KeyOutOfBounds);
                }
                if p.high_key.is_some_and(|hk| k >= hk) {
                    return Err(Violation::KeyOutOfBounds);
                }
            }

            // High key and right link come as a pair, and high keys ascend.
            if p.high_key.is_none() != p.right.is_nil() {
                return Err(Violation::BrokenRightLink);
            }
            if let (Some(lo), Some(hk)) = (low, p.high_key)
                && hk <= lo
            {
                return Err(Violation::BrokenRightLink);
            }
            if p.incomplete_split && p.right.is_nil() {
                return Err(Violation::BadSplitFlag);
            }

            // Downlink: every node has one, with the right separator,
            // unless its left sibling says the split is still in progress.
            if !left_is_incomplete {
                let link = downlinks.next().ok_or(Violation::MissingDownlink)?;
                if link.child != id {
                    return Err(Violation::MissingDownlink);
                }
                if link.low != low {
                    return Err(Violation::SeparatorMismatch);
                }
            }

            if level == 0 {
                entries += keys.len() as u64;
            }
            low = p.high_key;
            left_is_incomplete = p.incomplete_split;
            id = p.right;
        }
        // A downlink left over would point at a node that is not on the list.
        if downlinks.next().is_some() {
            return Err(Violation::MissingDownlink);
        }
    }
    if entries != tree.len() {
        return Err(Violation::WrongCount);
    }
    if nodes != allocated {
        return Err(Violation::OrphanNode);
    }
    Ok(())
}

/// Number of flagged nodes, counted by walking every level's list.
pub(crate) fn incomplete_splits(tree: &BLinkTree) -> usize {
    let meta = tree.meta_snapshot();
    let mut flagged = 0;
    for level in 0..meta.height {
        let mut id = meta.level_head[level];
        while !id.is_nil() {
            let p = tree.read(id);
            if p.incomplete_split {
                flagged += 1;
            }
            id = p.right;
        }
    }
    flagged
}
