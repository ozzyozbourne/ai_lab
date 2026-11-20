// Copied from chapters/07-bplus-trees/rust/src/insert.rs; behaviour unchanged (only the
// module paths were renamed to base_*). Do not edit here.
//! Insert: descend to the leaf, insert there, and split overflowing nodes on
//! the way back up (bottom-up splitting, as in chapter 04).
//!
//! The two splits are NOT the same, and that difference is the chapter:
//!
//!   leaf split      COPY-UP : the first key of the new right leaf is copied
//!                             into the parent. The entry itself stays in the
//!                             leaf, because leaves are the only place where
//!                             values live.
//!   internal split  PUSH-UP : the middle separator MOVES into the parent and
//!                             is in neither half, exactly as in a classic
//!                             B-tree. A separator is needed once per boundary.

use crate::base_arena::{NodeId, OutOfNodes};
use crate::base_node::{Kind, Node};
use crate::base_search::{child_index, lower_bound};
use crate::base_tree::BPlusTree;

/// What a child reports to its parent after an insert below it.
struct Split {
    /// Smallest key that may appear in `right`'s subtree.
    separator: u64,
    right: NodeId,
}

enum Outcome {
    /// The key existed; only a value changed. Carries the old value.
    Replaced(u64),
    /// A new entry was added and this subtree absorbed it.
    Inserted,
    /// A new entry was added and this node split in two.
    Split(Split),
}

impl BPlusTree {
    /// Inserts or overwrites. Returns the previous value if the key existed.
    /// On `Err(OutOfNodes)` the tree is unchanged.
    pub fn put(&mut self, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
        // Reserve the worst case BEFORE touching anything: one new node per
        // level (every node on the path splits) plus one new root. For an
        // empty tree that is 0 + 1: the first leaf.
        //   * If the reservation fails the tree has not been modified at all.
        //   * After it succeeds nothing below can fail.
        // The price: even an overwrite, which needs no node, can report
        // OutOfNodes. Simplicity wins here.
        self.nodes.reserve(self.height + 1)?;

        if self.root.is_nil() {
            let id = self.nodes.alloc_reserved(Node::new_leaf());
            self.root = id;
            self.first_leaf = id;
            self.last_leaf = id;
            self.height = 1;
        }

        match self.insert_into(self.root, key, value) {
            Outcome::Replaced(old) => return Ok(Some(old)),
            Outcome::Inserted => {}
            Outcome::Split(s) => {
                // The root itself split: grow a new root above the two halves.
                // This is the only way a B-tree gets taller, and it adds one
                // level to EVERY path at once, which keeps all leaves at the
                // same depth.
                let mut new_root = Node::new_internal();
                new_root.internal_mut().children[0] = self.root;
                new_root.internal_insert_at(0, s.separator, s.right);
                self.root = self.nodes.alloc_reserved(new_root);
                self.height += 1;
            }
        }
        self.count += 1;
        Ok(None)
    }

    fn insert_into(&mut self, id: NodeId, key: u64, value: u64) -> Outcome {
        let max_keys = self.max_keys();
        let n = self.nodes.get_mut(id);
        let (i, child) = match &mut n.kind {
            Kind::Leaf(leaf) => {
                let i = lower_bound(&n.keys[..n.len], key);
                if i < n.len && n.keys[i] == key {
                    return Outcome::Replaced(std::mem::replace(&mut leaf.values[i], value));
                }
                // Insert first, split afterwards: the arrays have one spare
                // slot (KEY_CAPACITY), so the leaf may briefly hold M keys.
                n.leaf_insert_at(i, key, value);
                if n.len <= max_keys {
                    return Outcome::Inserted;
                }
                return Outcome::Split(self.split_leaf(id));
            }
            Kind::Internal(internal) => {
                let i = child_index(&n.keys[..n.len], key);
                (i, internal.children[i])
            }
        };
        // The borrow of `n` ends here: the recursive call needs all of
        // `self`. (Zig keeps its `*Node` across the call; see the README.)
        match self.insert_into(child, key, value) {
            Outcome::Split(s) => {
                // Child i became two nodes: i (left half, same handle) and
                // s.right. Slot the separator in between them.
                let n = self.nodes.get_mut(id);
                n.internal_insert_at(i, s.separator, s.right);
                if n.len <= max_keys {
                    return Outcome::Inserted;
                }
                Outcome::Split(self.split_internal(id))
            }
            other => other,
        }
    }

    /// Splits a leaf holding M entries (one too many).
    /// The left half keeps the old handle, so the parent's child pointer and
    /// the left neighbour's `next` link stay correct without being touched.
    fn split_leaf(&mut self, left_id: NodeId) -> Split {
        let right_id = self.nodes.alloc_reserved(Node::new_leaf());
        let (left, right) = self.nodes.pair_mut(left_id, right_id);

        // floor(M/2) entries stay, ceil(M/2) move. Both halves end up with at
        // least ceil(M/2)-1 keys, the minimum (invariant 4).
        let mid = left.len / 2;
        let moved = left.len - mid;
        right.keys[..moved].copy_from_slice(&left.keys[mid..left.len]);
        right.leaf_mut().values[..moved].copy_from_slice(&left.leaf().values[mid..left.len]);
        right.len = moved;
        left.len = mid;

        // Splice the new leaf into the chain right after the old one
        // (invariant 6):
        //   left <-> old_next      becomes      left <-> right <-> old_next
        let old_next = left.leaf().next;
        right.leaf_mut().prev = left_id;
        right.leaf_mut().next = old_next;
        left.leaf_mut().next = right_id;
        // COPY-UP: right.keys[0] goes to the parent AND stays in the leaf.
        let separator = right.keys[0];
        if old_next.is_nil() {
            self.last_leaf = right_id; // we split the rightmost leaf
        } else {
            self.nodes.get_mut(old_next).leaf_mut().prev = right_id;
        }

        self.stats.leaf_splits += 1;
        Split {
            separator,
            right: right_id,
        }
    }

    /// Splits an internal node holding M separators and M+1 children.
    fn split_internal(&mut self, left_id: NodeId) -> Split {
        let right_id = self.nodes.alloc_reserved(Node::new_internal());
        let (left, right) = self.nodes.pair_mut(left_id, right_id);

        //   keys:      k0 .. k(mid-1) | k(mid) | k(mid+1) .. k(len-1)
        //   children: c0 ..    c(mid) |        | c(mid+1) ..   c(len)
        //              stay in left     goes up    move to right
        let mid = left.len / 2;
        let separator = left.keys[mid];
        let moved = left.len - mid - 1;
        right.keys[..moved].copy_from_slice(&left.keys[mid + 1..left.len]);
        right.internal_mut().children[..moved + 1]
            .copy_from_slice(&left.internal().children[mid + 1..left.len + 1]);
        right.len = moved;
        left.len = mid;

        self.stats.internal_splits += 1;
        // PUSH-UP: the separator is returned to the parent and kept in
        // neither half.
        Split {
            separator,
            right: right_id,
        }
    }
}
