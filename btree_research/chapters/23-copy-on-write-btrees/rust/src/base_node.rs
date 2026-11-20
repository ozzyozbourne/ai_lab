// Copied from chapters/07-bplus-trees/rust/src/node.rs (plus `NodeId` from
// arena.rs, renamed `PageId`). Trimmed for chapter 23: the leaf has NO
// `prev` / `next` sibling links, because they cannot survive path copying
// (see README, "Why the leaf chain has to go").
//! Node layout of the B+tree, and the array surgery done inside one node.
//!
//!   * a LEAF holds the entries (key + value);
//!   * an INTERNAL node holds separator keys and child page ids, and NO values.
//!
//! In this chapter a node is the content of one PAGE: a fixed-size slot of the
//! page store, named by a `PageId`. Every function here works on one node and
//! knows nothing about the store or about transactions.

/// Name of a page: its slot number in the page store. `PageId::NIL` plays the
/// role of "no page" (an empty tree has root `NIL`).
///
/// A newtype instead of a bare `u32` so that the compiler refuses to mix page
/// ids up with key counts and array indices.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PageId(u32);

impl PageId {
    pub const NIL: PageId = PageId(u32::MAX);

    pub fn is_nil(self) -> bool {
        self == PageId::NIL
    }

    /// Slot number. Never call on `NIL`.
    pub fn index(self) -> usize {
        assert!(!self.is_nil(), "NIL page id dereferenced");
        self.0 as usize
    }

    pub fn from_index(i: usize) -> PageId {
        let raw = u32::try_from(i).expect("page store full");
        assert!(raw != u32::MAX, "page store full"); // u32::MAX is reserved for NIL
        PageId(raw)
    }

    /// The on-disk form (used by the metapage).
    pub fn raw(self) -> u32 {
        self.0
    }

    pub fn from_raw(raw: u32) -> PageId {
        PageId(raw)
    }
}

/// Largest order a tree may be created with. The order itself (M = maximum
/// number of children) is a runtime field of the database so that tests and
/// the visualization can use M = 3, 4, 5, ... with one node type.
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
}

#[derive(Debug, Clone)]
pub struct Internal {
    /// children[i] holds keys <  keys[i]   (and >= keys[i-1]);
    /// children[len] holds keys >= keys[len-1].
    pub children: [PageId; CHILD_CAPACITY],
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
                children: [PageId::NIL; CHILD_CAPACITY],
            }),
        }
    }

    pub fn is_leaf(&self) -> bool {
        matches!(self.kind, Kind::Leaf(_))
    }

    pub fn key_slice(&self) -> &[u64] {
        &self.keys[..self.len]
    }

    /// The len+1 child page ids of an internal node.
    pub fn child_slice(&self) -> &[PageId] {
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

    // ------------------------------------------------------------ leaf

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

    /// Removes and returns the entry at position i, shifting the tail left.
    pub fn leaf_remove_at(&mut self, i: usize) -> Entry {
        let len = self.len;
        assert!(i < len);
        let removed = Entry {
            key: self.keys[i],
            value: self.leaf().values[i],
        };
        self.keys.copy_within(i + 1..len, i);
        self.leaf_mut().values.copy_within(i + 1..len, i);
        self.len -= 1;
        removed
    }

    // -------------------------------------------------------- internal

    /// Inserts separator `key` at key position i and `right` as the child to
    /// its right (child position i+1). This is what a parent does when its
    /// child i has split.
    pub fn internal_insert_at(&mut self, i: usize, key: u64, right: PageId) {
        let len = self.len;
        assert!(len < KEY_CAPACITY && i <= len);
        self.keys.copy_within(i..len, i + 1);
        self.keys[i] = key;
        let children = &mut self.internal_mut().children;
        children.copy_within(i + 1..len + 1, i + 2);
        children[i + 1] = right;
        self.len += 1;
    }

    /// Removes separator i and the child to its right (child i+1). This is
    /// what a parent does when children i and i+1 have been merged into i.
    pub fn internal_remove_at(&mut self, i: usize) {
        let len = self.len;
        assert!(i < len);
        self.keys.copy_within(i + 1..len, i);
        self.internal_mut()
            .children
            .copy_within(i + 2..len + 1, i + 1);
        self.len -= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaf_insert_and_remove_keep_keys_and_values_aligned() {
        let mut n = Node::new_leaf();
        n.leaf_insert_at(0, 20, 200);
        n.leaf_insert_at(0, 10, 100);
        n.leaf_insert_at(2, 30, 300);
        n.leaf_insert_at(1, 15, 150);
        assert_eq!(n.key_slice(), [10, 15, 20, 30]);
        assert_eq!(n.leaf().values[..n.len], [100, 150, 200, 300]);
        assert_eq!(
            n.leaf_remove_at(1),
            Entry {
                key: 15,
                value: 150
            }
        );
        assert_eq!(
            n.leaf_remove_at(2),
            Entry {
                key: 30,
                value: 300
            }
        );
        assert_eq!(n.key_slice(), [10, 20]);
        assert_eq!(n.leaf().values[..n.len], [100, 200]);
    }

    #[test]
    fn internal_insert_and_remove_move_the_child_to_the_right_of_the_key() {
        let id = PageId::from_index;
        let mut n = Node::new_internal();
        n.internal_mut().children[0] = id(0);
        n.internal_insert_at(0, 50, id(5)); //  (0) 50 (5)
        n.internal_insert_at(0, 20, id(2)); //  (0) 20 (2) 50 (5)
        n.internal_insert_at(2, 80, id(8)); //  (0) 20 (2) 50 (5) 80 (8)
        assert_eq!(n.key_slice(), [20, 50, 80]);
        assert_eq!(n.child_slice(), [id(0), id(2), id(5), id(8)]);
        n.internal_remove_at(1); //             (0) 20 (2) 80 (8)
        assert_eq!(n.key_slice(), [20, 80]);
        assert_eq!(n.child_slice(), [id(0), id(2), id(8)]);
    }
}
