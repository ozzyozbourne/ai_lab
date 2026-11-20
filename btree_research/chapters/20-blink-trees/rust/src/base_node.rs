// Copied from chapters/07-bplus-trees/rust/src/node.rs; trimmed: no removal
// (this chapter has no delete) and no prev/next leaf links (every node of a
// B-link tree, leaf or internal, has a right link; it lives in blink.rs's
// `Page`, next to the high key).
//
//! Keys and payload of one node, and the array surgery done inside it.
//!   * a LEAF holds the entries (key + value);
//!   * an INTERNAL node holds separator keys and child handles, and NO values.

use crate::base_handle::NodeId;

/// Largest order a tree may be created with. The order itself (M = maximum
/// number of children) is a runtime field of the tree so that tests and the
/// visualization can use M = 3, 4, 5, ... with one node type.
pub const MAX_ORDER: usize = 16;

/// A node of order M holds at most M-1 keys, but `put` lets a node overflow
/// by exactly one key before it is split, so the arrays have room for M.
pub const KEY_CAPACITY: usize = MAX_ORDER;
/// An internal node with k keys has k+1 children.
pub const CHILD_CAPACITY: usize = MAX_ORDER + 1;

#[derive(Debug, Clone)]
pub struct Leaf {
    /// values[i] belongs to keys[i].
    pub values: [u64; KEY_CAPACITY],
}

#[derive(Debug, Clone)]
pub struct Internal {
    /// children[i] holds keys <  keys[i]   (and >= keys[i-1]);
    /// children[len] holds keys >= keys[len-1].
    pub children: [NodeId; CHILD_CAPACITY],
}

#[derive(Debug, Clone)]
pub enum Kind {
    Leaf(Leaf),
    Internal(Internal),
}

#[derive(Debug, Clone)]
pub struct Node {
    /// Number of keys in use.
    pub len: usize,
    /// Sorted ascending, no duplicates. In a leaf: the keys of the entries.
    /// In an internal node: separators (signposts, see `Internal::children`).
    pub keys: [u64; KEY_CAPACITY],
    pub kind: Kind,
}

impl Node {
    pub fn new_leaf() -> Node {
        Node {
            len: 0,
            keys: [0; KEY_CAPACITY],
            kind: Kind::Leaf(Leaf {
                values: [0; KEY_CAPACITY],
            }),
        }
    }

    pub fn new_internal() -> Node {
        Node {
            len: 0,
            keys: [0; KEY_CAPACITY],
            kind: Kind::Internal(Internal {
                children: [NodeId::NIL; CHILD_CAPACITY],
            }),
        }
    }

    pub fn is_leaf(&self) -> bool {
        matches!(self.kind, Kind::Leaf(_))
    }

    pub fn key_slice(&self) -> &[u64] {
        &self.keys[..self.len]
    }

    /// The len+1 child handles of an internal node.
    pub fn child_slice(&self) -> &[NodeId] {
        &self.internal().children[..self.len + 1]
    }

    // The four accessors below panic when the node is of the other kind,
    // which is what Zig's `node.kind.leaf` does in a safe build.

    pub fn leaf(&self) -> &Leaf {
        match &self.kind {
            Kind::Leaf(leaf) => leaf,
            Kind::Internal(_) => panic!("expected a leaf"),
        }
    }

    pub fn leaf_mut(&mut self) -> &mut Leaf {
        match &mut self.kind {
            Kind::Leaf(leaf) => leaf,
            Kind::Internal(_) => panic!("expected a leaf"),
        }
    }

    pub fn internal(&self) -> &Internal {
        match &self.kind {
            Kind::Internal(internal) => internal,
            Kind::Leaf(_) => panic!("expected an internal node"),
        }
    }

    pub fn internal_mut(&mut self) -> &mut Internal {
        match &mut self.kind {
            Kind::Internal(internal) => internal,
            Kind::Leaf(_) => panic!("expected an internal node"),
        }
    }

    /// Inserts an entry at position i of a leaf, shifting the tail right.
    pub fn leaf_insert_at(&mut self, i: usize, key: u64, value: u64) {
        let len = self.len;
        assert!(len < KEY_CAPACITY && i <= len);
        // `copy_within` is the overlapping move (Zig: @memmove).
        self.keys.copy_within(i..len, i + 1);
        self.keys[i] = key;
        let leaf = self.leaf_mut();
        leaf.values.copy_within(i..len, i + 1);
        leaf.values[i] = value;
        self.len += 1;
    }

    /// Inserts separator `key` at key position i and `right` as the child to
    /// its right (child position i+1). This is what a parent does when its
    /// child i has split: the new entry is the DOWNLINK to the new sibling.
    pub fn internal_insert_at(&mut self, i: usize, key: u64, right: NodeId) {
        let len = self.len;
        assert!(len < KEY_CAPACITY && i <= len);
        self.keys.copy_within(i..len, i + 1);
        self.keys[i] = key;
        let children = &mut self.internal_mut().children;
        children.copy_within(i + 1..len + 1, i + 2);
        children[i + 1] = right;
        self.len += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaf_insert_keeps_keys_and_values_aligned() {
        let mut n = Node::new_leaf();
        n.leaf_insert_at(0, 20, 200);
        n.leaf_insert_at(0, 10, 100);
        n.leaf_insert_at(2, 30, 300);
        n.leaf_insert_at(1, 15, 150);
        assert_eq!(n.key_slice(), [10, 15, 20, 30]);
        assert_eq!(n.leaf().values[..n.len], [100, 150, 200, 300]);
    }

    #[test]
    fn internal_insert_puts_the_child_to_the_right_of_the_key() {
        let id = NodeId::from_index;
        let mut n = Node::new_internal();
        n.internal_mut().children[0] = id(0);
        n.internal_insert_at(0, 50, id(5)); //  (0) 50 (5)
        n.internal_insert_at(0, 20, id(2)); //  (0) 20 (2) 50 (5)
        n.internal_insert_at(2, 80, id(8)); //  (0) 20 (2) 50 (5) 80 (8)
        assert_eq!(n.key_slice(), [20, 50, 80]);
        assert_eq!(n.child_slice(), [id(0), id(2), id(5), id(8)]);
    }
}
