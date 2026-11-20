// Copied from chapters/07-bplus-trees/rust/src/walk.rs; changes for chapter 27 are marked "ch27:"
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
use crate::device::Kind as BlockKind; // ch27

///
/// ch27: the walker counts block reads, so it borrows the tree mutably.
/// `seek` pays for the descent (one read per level) and every step to the
/// next leaf pays one data block. `first` is used only by tests and dumps
/// and is not charged.
pub struct LeafWalker<'a> {
    tree: &'a mut BPlusTree,
    /// Current leaf, `NIL` when the walk is finished.
    leaf: NodeId,
    /// Next entry to return inside `leaf`.
    index: usize,
}

impl<'a> LeafWalker<'a> {
    /// Starts at the smallest key.
    pub fn first(tree: &'a mut BPlusTree) -> LeafWalker<'a> {
        let leaf = tree.first_leaf;
        LeafWalker {
            tree,
            leaf,
            index: 0,
        }
    }

    /// Starts at the first entry with key >= `key`: one root-to-leaf descent,
    /// then a binary search in the leaf.
    pub fn seek(tree: &'a mut BPlusTree, key: u64) -> LeafWalker<'a> {
        let leaf = tree.find_leaf(key);
        tree.dev.end_op(); // ch27: the descent is over; nothing was dirtied
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
            if !self.leaf.is_nil() {
                self.tree.dev.read(BlockKind::Data, 1); // ch27
            }
        }
        None
    }
}

impl BPlusTree {
    /// ch27: appends every entry with lo <= key < hi to `out`, ascending.
    /// One descent, then the leaf chain: height + (leaves crossed) reads.
    pub fn range(&mut self, lo: u64, hi: u64, out: &mut Vec<Entry>) {
        if lo >= hi {
            return;
        }
        out.extend(LeafWalker::seek(self, lo).take_while(|e| e.key < hi));
    }
}
