//! SECTION 1 of 6: the node type.
//!
//! A B-tree of order M (Knuth: M = maximum number of children) is made of
//! nodes that hold
//!   * at most      M - 1          keys (`max_keys`),
//!   * at least     ceil(M/2) - 1  keys (`min_keys`), except the root,
//!   * and, if the node is interior, exactly `keys.len() + 1` children.
//!
//! This is a plain B-tree (not a B+tree): every key lives exactly once, with
//! its value, either in a leaf or in an interior node.
//!
//! Difference from the Zig twin: there the order is a compile-time parameter
//! and a node is three fixed arrays (`[M]u64`, `[M]u64`, `[M + 1]?*Node`).
//! Stable Rust cannot compute an array length from a const generic
//! (`[u64; M - 1]` is rejected), so here the order is a run-time field of the
//! tree and a node holds three `Vec`s. A node may briefly hold M keys inside
//! `insert.rs` ("overflow, then split"); `validate` rejects that state.

/// Handle of a node: an index into the slab (pool.rs), not a pointer.
/// Indices are `Copy`, stay valid when the slab's `Vec` reallocates, and let
/// the tree hold "pointers" to parent, child and sibling at the same time
/// without fighting the borrow checker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId(pub u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    pub key: u64,
    pub value: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    /// Leaves have no children. All leaves are at the same depth.
    pub leaf: bool,
    /// Strictly ascending.
    pub keys: Vec<u64>,
    /// `values[i]` belongs to `keys[i]`.
    pub values: Vec<u64>,
    /// Interior nodes: `keys.len() + 1` children. Every key in `children[i]`
    /// is < `keys[i]`; every key in `children[i + 1]` is > `keys[i]`.
    pub children: Vec<NodeId>,
}

impl Node {
    pub fn new(leaf: bool) -> Self {
        Self {
            leaf,
            keys: Vec::new(),
            values: Vec::new(),
            children: Vec::new(),
        }
    }

    /// Number of keys currently stored.
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }

    /// Open a gap at index `i` and store the entry there.
    pub fn insert_entry(&mut self, i: usize, key: u64, value: u64) {
        self.keys.insert(i, key);
        self.values.insert(i, value);
    }

    /// Remove and return the entry at index `i`.
    pub fn remove_entry(&mut self, i: usize) -> Entry {
        Entry {
            key: self.keys.remove(i),
            value: self.values.remove(i),
        }
    }
}

/// Most keys a node may hold between operations.
pub fn max_keys(order: usize) -> usize {
    order - 1
}

/// Fewest keys a non-root node may hold: ceil(M/2) - 1.
pub fn min_keys(order: usize) -> usize {
    order.div_ceil(2) - 1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capacity_limits_follow_the_order() {
        assert_eq!(max_keys(4), 3); // a 2-3-4 tree
        assert_eq!(min_keys(4), 1);
        assert_eq!(min_keys(3), 1);
        assert_eq!(min_keys(5), 2);
        assert_eq!(min_keys(6), 2);
        assert_eq!(min_keys(7), 3);
    }

    #[test]
    fn insert_entry_and_remove_entry_keep_the_arrays_dense() {
        let mut n = Node::new(true);
        n.insert_entry(0, 20, 200);
        n.insert_entry(0, 10, 100);
        n.insert_entry(2, 30, 300);
        n.insert_entry(1, 15, 150);
        assert_eq!(n.keys, [10, 15, 20, 30]);
        assert_eq!(
            n.remove_entry(1),
            Entry {
                key: 15,
                value: 150
            }
        );
        assert_eq!(
            n.remove_entry(2),
            Entry {
                key: 30,
                value: 300
            }
        );
        assert_eq!(n.keys, [10, 20]);
        assert_eq!(n.values, [100, 200]);
        assert_eq!(n.len(), 2);
        assert!(!n.is_empty());
    }
}
