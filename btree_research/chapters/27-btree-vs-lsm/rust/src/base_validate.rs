// Copied from chapters/07-bplus-trees/rust/src/validate.rs; changes for chapter 27 are marked "ch27:"
//! `validate`: checks every invariant listed in tree.rs and names the first
//! one that is broken. Tests call it after every few operations; a bug in
//! insert or delete then fails close to the operation that caused it.
//!
//! The checker trusts nothing it reads from a node: a child handle is tested
//! with `is_live` before it is followed.

use crate::base_arena::NodeId;
use crate::base_node::Kind;
use crate::base_tree::BPlusTree;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Violation {
    /// root / first_leaf / last_leaf / height / count disagree about emptiness.
    BadRoot,
    /// A child handle is NIL, out of range, or names a freed slot.
    DanglingChild,
    /// More than M-1 keys.
    NodeOverfull,
    /// Fewer than ceil(M/2)-1 keys in a non-root node, or an empty root.
    NodeUnderfull,
    /// Keys inside a node are not strictly ascending.
    KeysNotSorted,
    /// A key lies outside the range its ancestors' separators allow.
    KeyOutOfBounds,
    /// A leaf is not at depth `height`.
    UnevenLeafDepth,
    /// The next/prev chain is not the leaves in tree order.
    BrokenLeafChain,
    /// `count` is not the number of entries in the leaves.
    WrongCount,
    /// Live arena slots that the tree does not reach, or a corrupt free list.
    ArenaLeak,
    /// ch27: the device's block count is not the number of live nodes, or an
    /// operation left blocks pinned.
    DeviceAccounting,
}

impl std::fmt::Display for Violation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for Violation {}

struct Walk {
    /// The leaf the chain says comes next (starts at tree.first_leaf).
    expected_leaf: NodeId,
    /// The leaf visited before it.
    prev_leaf: NodeId,
    entries: usize,
    nodes: usize,
}

impl BPlusTree {
    /// Checks every invariant listed at the top of tree.rs.
    pub fn validate(&self) -> Result<(), Violation> {
        if self.root.is_nil() {
            if !self.first_leaf.is_nil() || !self.last_leaf.is_nil() {
                return Err(Violation::BadRoot);
            }
            if self.height != 0 || self.count != 0 {
                return Err(Violation::BadRoot);
            }
            if self.nodes.live_count() != 0 {
                return Err(Violation::ArenaLeak);
            }
        } else {
            if !self.nodes.is_live(self.root) {
                return Err(Violation::BadRoot);
            }
            let mut walk = Walk {
                expected_leaf: self.first_leaf,
                prev_leaf: NodeId::NIL,
                entries: 0,
                nodes: 0,
            };
            self.check_node(self.root, 1, None, None, &mut walk)?;
            // The chain must end exactly where the tree's last leaf is.
            if !walk.expected_leaf.is_nil() || walk.prev_leaf != self.last_leaf {
                return Err(Violation::BrokenLeafChain);
            }
            if walk.entries != self.count {
                return Err(Violation::WrongCount);
            }
            // Every live slot must be reachable from the root: nothing leaked.
            if walk.nodes != self.nodes.live_count() {
                return Err(Violation::ArenaLeak);
            }
        }
        // ch27: one block per node, and no operation is in progress.
        if self.dev.live != self.nodes.live_count() as u64 || self.dev.pinned() != 0 {
            return Err(Violation::DeviceAccounting);
        }
        // live + free must account for every slot ever created.
        let free = self.nodes.free_count().ok_or(Violation::ArenaLeak)?;
        if free + self.nodes.live_count() != self.nodes.slot_count() {
            return Err(Violation::ArenaLeak);
        }
        Ok(())
    }

    /// Checks the subtree rooted at `id`. `lo` (inclusive) and `hi`
    /// (exclusive) are the bounds inherited from the separators above; `None`
    /// means unbounded. Leaves are visited left to right, so the visit order
    /// can be compared with the sibling links as we go.
    fn check_node(
        &self,
        id: NodeId,
        depth: usize,
        lo: Option<u64>,
        hi: Option<u64>,
        walk: &mut Walk,
    ) -> Result<(), Violation> {
        let n = self.nodes.get(id);
        let keys = n.key_slice();
        let is_root = id == self.root;
        walk.nodes += 1;

        if n.len > self.max_keys() {
            return Err(Violation::NodeOverfull);
        }
        if n.len < (if is_root { 1 } else { self.min_keys() }) {
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
                if depth != self.height {
                    return Err(Violation::UnevenLeafDepth);
                }
                if walk.expected_leaf != id || leaf.prev != walk.prev_leaf {
                    return Err(Violation::BrokenLeafChain);
                }
                walk.prev_leaf = id;
                walk.expected_leaf = leaf.next;
                walk.entries += n.len;
            }
            Kind::Internal(_) => {
                for (i, &child) in n.child_slice().iter().enumerate() {
                    if !self.nodes.is_live(child) {
                        return Err(Violation::DanglingChild);
                    }
                    // Child i may hold keys in [keys[i-1], keys[i]).
                    let child_lo = if i == 0 { lo } else { Some(keys[i - 1]) };
                    let child_hi = if i == n.len { hi } else { Some(keys[i]) };
                    self.check_node(child, depth + 1, child_lo, child_hi, walk)?;
                }
            }
        }
        Ok(())
    }
}
