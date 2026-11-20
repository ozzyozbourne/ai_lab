// Copied from chapters/07-bplus-trees/rust/src/node.rs and arena.rs (NodeId
// and OutOfNodes only), trimmed for chapter 19: no delete helpers, and a leaf
// keeps only the `next` link. With a `prev` link a leaf split would have to
// write into the right neighbour, a node the splitting thread has not latched.
//! Node layout of the B+tree, and the array surgery done inside one node.
//!
//!   * a LEAF holds the entries (key + value) and the link to the next leaf;
//!   * an INTERNAL node holds separator keys and child handles, and NO values.
//!
//! Nothing in this file knows about latches: every function works on one node
//! that the caller is allowed to touch.

/// Handle of a node: an index into the node table. `NodeId::NIL` plays the
/// role of a null pointer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId(u32);

impl NodeId {
    pub const NIL: NodeId = NodeId(u32::MAX);

    pub fn is_nil(self) -> bool {
        self == NodeId::NIL
    }

    /// Position in the table. Never call on `NIL`.
    pub fn index(self) -> usize {
        assert!(!self.is_nil(), "NIL handle dereferenced");
        self.0 as usize
    }

    pub fn from_index(i: usize) -> NodeId {
        let raw = u32::try_from(i).expect("table full");
        assert!(raw != u32::MAX, "table full"); // u32::MAX is reserved for NIL
        NodeId(raw)
    }

    /// The bits stored in the tree's atomic root field.
    pub fn raw(self) -> u32 {
        self.0
    }

    pub fn from_raw(raw: u32) -> NodeId {
        NodeId(raw)
    }
}

/// The node table has no room for the nodes an insert needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfNodes;

impl std::fmt::Display for OutOfNodes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("node table exhausted")
    }
}

impl std::error::Error for OutOfNodes {}

/// Largest order a tree may be created with. The order itself (M = maximum
/// number of children) is a runtime field of the tree.
pub const MAX_ORDER: usize = 16;

/// A node of order M holds at most M-1 keys, but `put` lets a node overflow
/// by exactly one key before it is split, so the arrays have room for M.
pub const KEY_CAPACITY: usize = MAX_ORDER;
/// An internal node with k keys has k+1 children.
pub const CHILD_CAPACITY: usize = MAX_ORDER + 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub key: u64,
    pub value: u64,
}

#[derive(Debug, Clone)]
pub struct Leaf {
    /// values[i] belongs to keys[i].
    pub values: [u64; KEY_CAPACITY],
    /// Singly linked list of all leaves in key order.
    pub next: NodeId,
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
    /// Sorted ascending, no duplicates.
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
                next: NodeId::NIL,
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

    /// Inserts an entry at position i, shifting the tail right.
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
    /// child i has split.
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
    fn internal_insert_moves_the_child_to_the_right_of_the_key() {
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
