// Copied from chapters/05-deletion-and-rebalancing/rust/src/validate.rs
// Changes for chapter 06: the error is a `Violation` (WHICH invariant and
// WHERE), and a node's own checks all run before the walk descends.
//! The invariants as code (README section "Invariants as code").
//!
//! `validate` walks the whole tree and returns the first broken invariant.
//! Each invariant has its own `ValidateError`, so a failing fuzz run says
//! WHICH promise was broken; the `Violation` around it says WHERE.
//!
//! In Rust the details travel inside the `Err` value. A Zig error is a bare
//! tag, so the Zig twin fills in a `Diagnostic` out-parameter instead.
//!
//! This file needs only base_node.rs: it knows nothing about the slab,
//! insert or delete, and works on trees built by hand in a `Vec<Node>`.

use crate::base_node::{Node, NodeId, Nodes, max_keys, min_keys};

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
    /// The pool's live-node counter differs from the number of nodes
    /// reachable from the root: a node was leaked. Not returned by the
    /// function below, which sees no pool; `BTree::validate` adds this check.
    NodeCountMismatch,
}

/// A broken invariant and the node where the walk found it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Violation {
    pub error: ValidateError,
    /// Depth of the offending node (root = 0).
    pub depth: usize,
    /// Its first key, to find the node in a rendering of the tree. `None`
    /// for errors about the tree as a whole (and for a node without keys).
    pub first_key: Option<u64>,
}

impl Violation {
    pub fn whole_tree(error: ValidateError) -> Self {
        Self {
            error,
            depth: 0,
            first_key: None,
        }
    }
}

pub fn validate<P: Nodes + ?Sized>(
    nodes: &P,
    order: usize,
    root: Option<NodeId>,
    expected_len: usize,
) -> Result<(), Violation> {
    let mut count = 0;
    if let Some(root) = root {
        if nodes[root].is_empty() {
            return Err(Violation::whole_tree(ValidateError::EmptyRoot));
        }
        let mut walk = Walk {
            nodes,
            order,
            leaf_depth: None,
            count: 0,
        };
        walk.check(root, None, None, 0)?;
        count = walk.count;
    }
    if count != expected_len {
        return Err(Violation::whole_tree(ValidateError::WrongKeyCount));
    }
    Ok(())
}

struct Walk<'a, P: Nodes + ?Sized> {
    nodes: &'a P,
    order: usize,
    leaf_depth: Option<usize>,
    count: usize,
}

impl<P: Nodes + ?Sized> Walk<'_, P> {
    /// `lo` / `hi` are exclusive bounds inherited from the separators in the
    /// ancestors (`None` = unbounded).
    fn check(
        &mut self,
        id: NodeId,
        lo: Option<u64>,
        hi: Option<u64>,
        depth: usize,
    ) -> Result<(), Violation> {
        let node = &self.nodes[id];
        // Everything that can be said about this node alone comes first, so
        // the error names the node closest to the root that is wrong.
        self.check_node(node, lo, hi, depth)
            .map_err(|error| Violation {
                error,
                depth,
                first_key: node.keys.first().copied(),
            })?;
        for (i, &child) in node.children.iter().enumerate() {
            // Child i lives strictly between separator i - 1 and separator i.
            let child_lo = if i == 0 { lo } else { Some(node.keys[i - 1]) };
            let child_hi = if i == node.len() {
                hi
            } else {
                Some(node.keys[i])
            };
            self.check(child, child_lo, child_hi, depth + 1)?;
        }
        Ok(())
    }

    fn check_node(
        &mut self,
        node: &Node,
        lo: Option<u64>,
        hi: Option<u64>,
        depth: usize,
    ) -> Result<(), ValidateError> {
        if node.len() > max_keys(self.order) {
            return Err(ValidateError::NodeOverfull);
        }
        if depth > 0 && node.len() < min_keys(self.order) {
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

        // Children: exactly len + 1 in an interior node, none in a leaf.
        let want = if node.leaf { 0 } else { node.len() + 1 };
        if node.children.len() < want {
            return Err(ValidateError::MissingChild);
        }
        if node.children.len() > want {
            return Err(ValidateError::UnexpectedChild);
        }

        if node.leaf {
            match self.leaf_depth {
                Some(d) if d != depth => return Err(ValidateError::LeavesAtDifferentDepths),
                _ => self.leaf_depth = Some(depth),
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::base_node::Node;

    /// Only the error kind, for the table of cases below.
    fn kind(nodes: &[Node], order: usize, root: NodeId, len: usize) -> Result<(), ValidateError> {
        validate(nodes, order, Some(root), len).map_err(|v| v.error)
    }

    fn leaf(keys: &[u64]) -> Node {
        let mut node = Node::new(true);
        node.keys = keys.to_vec();
        node.values = vec![0; keys.len()];
        node
    }

    fn push(nodes: &mut Vec<Node>, node: Node) -> NodeId {
        nodes.push(node);
        NodeId(nodes.len() as u32 - 1)
    }

    #[test]
    fn validate_names_the_broken_invariant() {
        use ValidateError::*;
        //            [20]
        //     [5 10]      [30 40]
        let mut nodes: Vec<Node> = Vec::new(); // a typed arena is enough here
        let left = push(&mut nodes, leaf(&[5, 10]));
        let right = push(&mut nodes, leaf(&[30, 40]));
        let mut top = leaf(&[20]);
        top.leaf = false;
        top.children = vec![left, right];
        let root = push(&mut nodes, top);
        assert_eq!(kind(&nodes, 4, root, 5), Ok(()));
        assert_eq!(validate(&nodes, 4, None, 0), Ok(()));

        assert_eq!(kind(&nodes, 4, root, 4), Err(WrongKeyCount));

        nodes[left].keys[1] = 5;
        assert_eq!(kind(&nodes, 4, root, 5), Err(KeysOutOfOrder));
        nodes[left].keys[1] = 25; // sorted inside the leaf, but on the wrong side of 20
        assert_eq!(
            kind(&nodes, 4, root, 5),
            Err(KeyOutsideParentBounds)
        );
        nodes[left].keys[1] = 10;

        nodes[right] = leaf(&[]);
        assert_eq!(kind(&nodes, 4, root, 3), Err(NodeUnderfull));
        nodes[right] = leaf(&[30, 40, 50, 60]);
        assert_eq!(kind(&nodes, 4, root, 7), Err(NodeOverfull));
        nodes[right] = leaf(&[30, 40]);

        nodes[root].children.pop();
        assert_eq!(kind(&nodes, 4, root, 5), Err(MissingChild));
        nodes[root].children.push(right);
        nodes[left].children.push(right);
        assert_eq!(kind(&nodes, 4, root, 5), Err(UnexpectedChild));
        nodes[left].children.clear();

        // Hang a subtree under the right slot: its leaves are one level deeper.
        let deep_a = push(&mut nodes, leaf(&[25]));
        let deep_b = push(&mut nodes, leaf(&[35]));
        let mut mid = leaf(&[30]);
        mid.leaf = false;
        mid.children = vec![deep_a, deep_b];
        let mid = push(&mut nodes, mid);
        nodes[root].children[1] = mid;
        assert_eq!(
            kind(&nodes, 4, root, 6),
            Err(LeavesAtDifferentDepths)
        );

        let empty_root = push(&mut nodes, leaf(&[]));
        assert_eq!(kind(&nodes, 4, empty_root, 0), Err(EmptyRoot));

        // The violation points at the node that broke the rule.
        nodes[root].children[1] = right;
        nodes[right].keys[0] = 50; // [50 40]
        assert_eq!(
            validate(&nodes, 4, Some(root), 5),
            Err(Violation {
                error: KeysOutOfOrder,
                depth: 1,
                first_key: Some(50)
            })
        );
    }
}
