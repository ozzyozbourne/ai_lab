// Copied from chapters/07-bplus-trees/rust/src/walk.rs; behaviour unchanged (only the
// module paths were renamed to base_*). Do not edit here.
//! The minimal in-order walk over the leaf chain.
//!
//! This is deliberately small: forward only, positioned at the first entry or
//! at the first entry >= a key. It exists to show that an ordered scan of a
//! B+tree never goes back up into the internal nodes, and to give `validate`
//! and the model test something to compare with. Bounds, backward scans and
//! cursors that survive changes to the tree are the subject of chapter 08.
//!
//! The walker holds a handle and an index, and it does not allocate. Because
//! it borrows the tree, the compiler rejects a `put` or `delete` while a
//! walker is alive (in Zig that rule is only a comment).

use crate::base_arena::NodeId;
use crate::base_node::Entry;
use crate::base_search::lower_bound;
use crate::base_tree::BPlusTree;

pub struct LeafWalker<'a> {
    tree: &'a BPlusTree,
    /// Current leaf, `NIL` when the walk is finished.
    leaf: NodeId,
    /// Next entry to return inside `leaf`.
    index: usize,
}

impl<'a> LeafWalker<'a> {
    /// Starts at the smallest key.
    pub fn first(tree: &'a BPlusTree) -> LeafWalker<'a> {
        LeafWalker {
            tree,
            leaf: tree.first_leaf,
            index: 0,
        }
    }

    /// Starts at the first entry with key >= `key`: one root-to-leaf descent,
    /// then a binary search in the leaf.
    pub fn seek(tree: &'a BPlusTree, key: u64) -> LeafWalker<'a> {
        let leaf = tree.find_leaf(key);
        if leaf.is_nil() {
            return LeafWalker {
                tree,
                leaf,
                index: 0,
            };
        }
        // The index may equal the leaf's length (every key in this leaf is
        // smaller). `next` then steps to the following leaf by itself.
        let index = lower_bound(tree.nodes.get(leaf).key_slice(), key);
        LeafWalker { tree, leaf, index }
    }
}

impl Iterator for LeafWalker<'_> {
    type Item = Entry;

    fn next(&mut self) -> Option<Entry> {
        while !self.leaf.is_nil() {
            let n = self.tree.nodes.get(self.leaf);
            if self.index < n.len {
                let entry = Entry {
                    key: n.keys[self.index],
                    value: n.leaf().values[self.index],
                };
                self.index += 1;
                return Some(entry);
            }
            // End of this leaf: follow the sibling link. No parent needed.
            self.leaf = n.leaf().next;
            self.index = 0;
        }
        None
    }
}
