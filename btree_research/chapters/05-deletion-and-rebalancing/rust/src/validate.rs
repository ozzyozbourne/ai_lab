//! SECTION 6a of 6: the invariants as code.
//!
//! `validate` walks the whole tree and returns the first broken invariant.
//! Every test calls it after every operation; chapter 06 builds a fuzzer on it.

use crate::node::{NodeId, max_keys, min_keys};
use crate::pool::Slab;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValidateError {
    /// Keys inside a node are not strictly ascending.
    KeysOutOfOrder,
    /// A key is not between the two separators above it.
    KeyOutsideParentBounds,
    /// More than M - 1 keys.
    NodeOverfull,
    /// A non-root node with fewer than ceil(M/2) - 1 keys.
    NodeUnderfull,
    /// A root with zero keys (an empty tree has no root at all).
    EmptyRoot,
    /// Two leaves at different depths.
    LeavesAtDifferentDepths,
    /// An interior node with fewer than len + 1 children.
    MissingChild,
    /// A leaf with children, or an interior node with more than len + 1.
    UnexpectedChild,
    /// The number of keys in the tree differs from the tree's `len`.
    WrongKeyCount,
    /// The pool's live-node counter differs from the nodes reachable from
    /// the root: a node was leaked (checked by `BTree::validate`).
    NodeCountMismatch,
}

pub fn validate(
    pool: &Slab,
    order: usize,
    root: Option<NodeId>,
    expected_len: usize,
) -> Result<(), ValidateError> {
    let mut count = 0;
    if let Some(root) = root {
        if pool[root].is_empty() {
            return Err(ValidateError::EmptyRoot);
        }
        let mut walk = Walk {
            pool,
            order,
            leaf_depth: None,
            count: 0,
        };
        walk.check(root, None, None, true, 0)?;
        count = walk.count;
    }
    if count != expected_len {
        return Err(ValidateError::WrongKeyCount);
    }
    Ok(())
}

struct Walk<'a> {
    pool: &'a Slab,
    order: usize,
    leaf_depth: Option<usize>,
    count: usize,
}

impl Walk<'_> {
    /// `lo` / `hi` are exclusive bounds inherited from the separators in the
    /// ancestors (`None` = unbounded).
    fn check(
        &mut self,
        id: NodeId,
        lo: Option<u64>,
        hi: Option<u64>,
        is_root: bool,
        depth: usize,
    ) -> Result<(), ValidateError> {
        let node = &self.pool[id];
        if node.len() > max_keys(self.order) {
            return Err(ValidateError::NodeOverfull);
        }
        if !is_root && node.len() < min_keys(self.order) {
            return Err(ValidateError::NodeUnderfull);
        }
        self.count += node.len();

        for (i, &key) in node.keys.iter().enumerate() {
            if i > 0 && node.keys[i - 1] >= key {
                return Err(ValidateError::KeysOutOfOrder);
            }
            if lo.is_some_and(|lo| key <= lo) || hi.is_some_and(|hi| key >= hi) {
                return Err(ValidateError::KeyOutsideParentBounds);
            }
        }

        if node.leaf {
            if !node.children.is_empty() {
                return Err(ValidateError::UnexpectedChild);
            }
            return match self.leaf_depth {
                Some(d) if d != depth => Err(ValidateError::LeavesAtDifferentDepths),
                _ => {
                    self.leaf_depth = Some(depth);
                    Ok(())
                }
            };
        }

        if node.children.len() < node.len() + 1 {
            return Err(ValidateError::MissingChild);
        }
        if node.children.len() > node.len() + 1 {
            return Err(ValidateError::UnexpectedChild);
        }
        for (i, &child) in node.children.iter().enumerate() {
            // Child i lives strictly between separator i - 1 and separator i.
            let child_lo = if i == 0 { lo } else { Some(node.keys[i - 1]) };
            let child_hi = if i == node.len() {
                hi
            } else {
                Some(node.keys[i])
            };
            self.check(child, child_lo, child_hi, false, depth + 1)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::Node;

    fn leaf(keys: &[u64]) -> Node {
        let mut node = Node::new(true);
        node.keys = keys.to_vec();
        node.values = vec![0; keys.len()];
        node
    }

    #[test]
    fn validate_names_the_broken_invariant() {
        use ValidateError::*;
        //            [20]
        //     [5 10]      [30 40]
        let mut pool = Slab::new();
        let left = pool.alloc(leaf(&[5, 10])).unwrap();
        let right = pool.alloc(leaf(&[30, 40])).unwrap();
        let mut top = leaf(&[20]);
        top.leaf = false;
        top.children = vec![left, right];
        let root = pool.alloc(top).unwrap();
        assert_eq!(validate(&pool, 4, Some(root), 5), Ok(()));
        assert_eq!(validate(&pool, 4, None, 0), Ok(()));

        assert_eq!(validate(&pool, 4, Some(root), 4), Err(WrongKeyCount));

        pool[left].keys[1] = 5;
        assert_eq!(validate(&pool, 4, Some(root), 5), Err(KeysOutOfOrder));
        pool[left].keys[1] = 25; // sorted inside the leaf, but on the wrong side of 20
        assert_eq!(
            validate(&pool, 4, Some(root), 5),
            Err(KeyOutsideParentBounds)
        );
        pool[left].keys[1] = 10;

        pool[right] = leaf(&[]);
        assert_eq!(validate(&pool, 4, Some(root), 3), Err(NodeUnderfull));
        pool[right] = leaf(&[30, 40, 50, 60]);
        assert_eq!(validate(&pool, 4, Some(root), 7), Err(NodeOverfull));
        pool[right] = leaf(&[30, 40]);

        pool[root].children.pop();
        assert_eq!(validate(&pool, 4, Some(root), 5), Err(MissingChild));
        pool[root].children.push(right);
        pool[left].children.push(right);
        assert_eq!(validate(&pool, 4, Some(root), 5), Err(UnexpectedChild));
        pool[left].children.clear();

        // Hang a subtree under the right slot: its leaves are one level deeper.
        let deep_a = pool.alloc(leaf(&[25])).unwrap();
        let deep_b = pool.alloc(leaf(&[35])).unwrap();
        let mut mid = leaf(&[30]);
        mid.leaf = false;
        mid.children = vec![deep_a, deep_b];
        let mid = pool.alloc(mid).unwrap();
        pool[root].children[1] = mid;
        assert_eq!(
            validate(&pool, 4, Some(root), 6),
            Err(LeavesAtDifferentDepths)
        );

        let empty_root = pool.alloc(leaf(&[])).unwrap();
        assert_eq!(validate(&pool, 4, Some(empty_root), 0), Err(EmptyRoot));
    }
}
