//! `validate`: checks every invariant listed in tree.rs and names the first
//! one that is broken.
//!
//! QUIESCENT ONLY: call it when no operation is in flight, i.e. after the
//! worker threads have been joined, or between the operations of a
//! single-threaded test. (It takes each node's latch to read it, because
//! Rust offers no other way in, but it does not couple them and so proves
//! nothing while writers are running.) A concurrent test that ends with a
//! valid tree AND the right contents has not proved the protocol correct,
//! but a protocol bug very often leaves one of these broken.

use crate::base_node::{Kind, NodeId};
use crate::tree::Tree;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Violation {
    /// The root handle does not name a node of the table.
    BadRoot,
    /// A child handle is nil or beyond the nodes handed out so far.
    DanglingChild,
    /// More than M-1 keys.
    NodeOverfull,
    /// Fewer than ceil(M/2)-1 keys in a non-root node, or an empty internal root.
    NodeUnderfull,
    /// Keys inside a node are not strictly ascending.
    KeysNotSorted,
    /// A key lies outside the range its ancestors' separators allow.
    KeyOutOfBounds,
    /// Leaves are not all at the same depth.
    UnevenLeafDepth,
    /// The `next` chain is not the leaves in tree order.
    BrokenLeafChain,
    /// `count` is not the number of entries in the leaves.
    WrongCount,
    /// A node was handed out by the table but is not reachable from the root:
    /// a split reserved it and never linked it in.
    UnreachableNode,
}

#[derive(Default)]
struct Walk {
    /// The leaf the chain says comes next; None before the first leaf.
    expected_leaf: Option<NodeId>,
    leaf_depth: Option<usize>,
    entries: usize,
    nodes: usize,
}

impl Tree {
    /// Checks every invariant listed at the top of tree.rs. Quiescent only.
    pub fn validate(&self) -> Result<(), Violation> {
        let root = self.root();
        if root.is_nil() || root.index() >= self.table.count() as usize {
            return Err(Violation::BadRoot);
        }
        let mut walk = Walk::default();
        self.check_node(root, 1, None, None, &mut walk)?;
        // The chain must end at the last leaf of the tree.
        if walk.expected_leaf != Some(NodeId::NIL) {
            return Err(Violation::BrokenLeafChain);
        }
        if walk.entries != self.len() {
            return Err(Violation::WrongCount);
        }
        if walk.nodes != self.table.count() as usize {
            return Err(Violation::UnreachableNode);
        }
        Ok(())
    }

    /// Checks the subtree rooted at `id`. `lo` (inclusive) and `hi`
    /// (exclusive) are the bounds inherited from the separators above.
    fn check_node(
        &self,
        id: NodeId,
        depth: usize,
        lo: Option<u64>,
        hi: Option<u64>,
        walk: &mut Walk,
    ) -> Result<(), Violation> {
        let n = self.table.read(id);
        let keys = n.key_slice();
        let is_root = depth == 1;
        walk.nodes += 1;

        if n.len > self.max_keys() {
            return Err(Violation::NodeOverfull);
        }
        // The root may be an empty leaf (the tree starts that way).
        let min = match (is_root, n.is_leaf()) {
            (false, _) => self.min_keys(),
            (true, true) => 0,
            (true, false) => 1,
        };
        if n.len < min {
            return Err(Violation::NodeUnderfull);
        }
        for (i, &k) in keys.iter().enumerate() {
            if i > 0 && keys[i - 1] >= k {
                return Err(Violation::KeysNotSorted);
            }
            if lo.is_some_and(|lo| k < lo) || hi.is_some_and(|hi| k >= hi) {
                return Err(Violation::KeyOutOfBounds);
            }
        }

        match &n.kind {
            Kind::Leaf(leaf) => {
                if *walk.leaf_depth.get_or_insert(depth) != depth {
                    return Err(Violation::UnevenLeafDepth);
                }
                // Leaves are visited left to right, so each one must be what
                // the previous leaf's `next` link announced.
                if walk.expected_leaf.is_some_and(|expected| expected != id) {
                    return Err(Violation::BrokenLeafChain);
                }
                walk.expected_leaf = Some(leaf.next);
                walk.entries += n.len;
            }
            Kind::Internal(_) => {
                for (i, &child) in n.child_slice().iter().enumerate() {
                    if child.is_nil() || child.index() >= self.table.count() as usize {
                        return Err(Violation::DanglingChild);
                    }
                    let child_lo = if i == 0 { lo } else { Some(keys[i - 1]) };
                    let child_hi = if i == n.len { hi } else { Some(keys[i]) };
                    self.check_node(child, depth + 1, child_lo, child_hi, walk)?;
                }
            }
        }
        Ok(())
    }
}
