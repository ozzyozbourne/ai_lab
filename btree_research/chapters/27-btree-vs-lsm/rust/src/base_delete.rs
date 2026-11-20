// Copied from chapters/07-bplus-trees/rust/src/delete.rs; changes for chapter 27 are marked "ch27:"
//! Delete: remove the entry from its leaf, then repair underfull nodes on the
//! way back up by borrowing from a sibling or merging with one.
//!
//! Compared with the classic B-tree of chapter 05 there is no "delete from an
//! internal node" case at all: entries are only in leaves. If the deleted key
//! also appears as a separator higher up, the separator simply STAYS. It is
//! still a correct signpost ("everything to my right is >= me"), it just no
//! longer names a key that exists. `validate` accepts that on purpose.

use crate::base_arena::NodeId;
use crate::base_node::Kind;
use crate::base_search::{child_index, lower_bound};
use crate::base_tree::BPlusTree;

impl BPlusTree {
    /// Removes a key. Returns its value, or `None` if it was absent.
    /// Never needs a new node, so it cannot fail.
    pub fn delete(&mut self, key: u64) -> Option<u64> {
        if self.root.is_nil() {
            return None;
        }
        let removed = self.delete_from(self.root, key)?;
        self.count -= 1;

        // The root is allowed to be underfull, but not to be empty.
        let root = self.nodes.get(self.root);
        if root.len == 0 {
            let old_root = self.root;
            match &root.kind {
                // Last entry gone: back to the empty tree, zero nodes.
                Kind::Leaf(_) => {
                    self.root = NodeId::NIL;
                    self.first_leaf = NodeId::NIL;
                    self.last_leaf = NodeId::NIL;
                }
                // An internal root with no separator has exactly one child
                // (its two children were just merged). That child becomes the
                // root: the only way a B-tree gets shorter, again for all
                // paths at once.
                Kind::Internal(internal) => self.root = internal.children[0],
            }
            self.nodes.free(old_root);
            self.height -= 1;
        }
        Some(removed)
    }

    fn delete_from(&mut self, id: NodeId, key: u64) -> Option<u64> {
        let n = self.nodes.get_mut(id);
        let (i, child_id) = match &n.kind {
            Kind::Leaf(_) => {
                let i = lower_bound(n.key_slice(), key);
                if i == n.len || n.keys[i] != key {
                    return None;
                }
                return Some(n.leaf_remove_at(i).value);
            }
            Kind::Internal(internal) => {
                let i = child_index(n.key_slice(), key);
                (i, internal.children[i])
            }
        };
        let removed = self.delete_from(child_id, key)?;
        if self.nodes.get(child_id).len < self.min_keys() {
            self.rebalance(id, i);
        }
        Some(removed)
    }

    /// Child `i` of `parent` has one key too few. Preference order:
    ///   1. borrow from the left sibling   (cheap: 3 nodes touched, none freed)
    ///   2. borrow from the right sibling
    ///   3. merge with the left sibling    (frees a node, parent loses a key and
    ///   4. merge with the right sibling    may now be underfull itself)
    ///
    /// A merge is only chosen when both siblings are at the minimum, which is
    /// exactly when the two nodes are guaranteed to fit into one.
    fn rebalance(&mut self, parent_id: NodeId, i: usize) {
        let parent = self.nodes.get(parent_id);
        let children = parent.child_slice();
        let min = self.min_keys();
        if i > 0 && self.nodes.get(children[i - 1]).len > min {
            self.borrow_from_left(parent_id, i);
        } else if i < parent.len && self.nodes.get(children[i + 1]).len > min {
            self.borrow_from_right(parent_id, i);
        } else if i > 0 {
            self.merge(parent_id, i - 1);
        } else {
            self.merge(parent_id, i);
        }
    }

    /// Moves the last item of the left sibling to the front of child `i`.
    /// The separator between the two is parent.keys[i-1].
    ///
    /// Three nodes are involved. Rust cannot hold `&mut` to all three as
    /// easily as Zig holds three pointers, so the parent's part is done with
    /// copies: read the old separator first, write the new one last.
    fn borrow_from_left(&mut self, parent_id: NodeId, i: usize) {
        let parent = self.nodes.get(parent_id);
        let old_separator = parent.keys[i - 1];
        let (left_id, child_id) = (parent.child_slice()[i - 1], parent.child_slice()[i]);
        let (left, child) = self.nodes.pair_mut(left_id, child_id);
        let new_separator = if child.is_leaf() {
            // The entry moves sideways; the parent gets a fresh COPY of the
            // child's new first key.
            let e = left.leaf_remove_at(left.len - 1);
            child.leaf_insert_at(0, e.key, e.value);
            child.keys[0]
        } else {
            // Rotation through the parent, as in a classic B-tree: the old
            // separator comes down, the left sibling's last key goes up, and
            // the left sibling's last child changes parent.
            let moved_child = left.internal().children[left.len];
            let len = child.len;
            child.keys.copy_within(0..len, 1);
            child.keys[0] = old_separator;
            let children = &mut child.internal_mut().children;
            children.copy_within(0..len + 1, 1);
            children[0] = moved_child;
            child.len += 1;
            left.len -= 1;
            left.keys[left.len]
        };
        self.nodes.get_mut(parent_id).keys[i - 1] = new_separator;
        self.stats.borrows += 1;
    }

    /// Moves the first item of the right sibling to the end of child `i`.
    /// The separator between the two is parent.keys[i].
    fn borrow_from_right(&mut self, parent_id: NodeId, i: usize) {
        let parent = self.nodes.get(parent_id);
        let old_separator = parent.keys[i];
        let (child_id, right_id) = (parent.child_slice()[i], parent.child_slice()[i + 1]);
        let (child, right) = self.nodes.pair_mut(child_id, right_id);
        let new_separator = if child.is_leaf() {
            let e = right.leaf_remove_at(0);
            child.leaf_insert_at(child.len, e.key, e.value);
            right.keys[0]
        } else {
            let len = child.len;
            child.keys[len] = old_separator;
            child.internal_mut().children[len + 1] = right.internal().children[0];
            child.len += 1;
            let up = right.keys[0];
            // Drop right's first key and first child.
            let rlen = right.len;
            right.keys.copy_within(1..rlen, 0);
            right.internal_mut().children.copy_within(1..rlen + 1, 0);
            right.len -= 1;
            up
        };
        self.nodes.get_mut(parent_id).keys[i] = new_separator;
        self.stats.borrows += 1;
    }

    /// Merges child `li + 1` into child `li` and frees it. Always right INTO
    /// left, so the surviving node keeps its handle and `first_leaf` never
    /// needs to change.
    fn merge(&mut self, parent_id: NodeId, li: usize) {
        let parent = self.nodes.get(parent_id);
        let separator = parent.keys[li];
        let (left_id, right_id) = (parent.child_slice()[li], parent.child_slice()[li + 1]);
        let (left, right) = self.nodes.pair_mut(left_id, right_id);
        let (llen, rlen) = (left.len, right.len);
        if left.is_leaf() {
            // The separator between two leaves was only a copy: drop it.
            left.keys[llen..llen + rlen].copy_from_slice(&right.keys[..rlen]);
            left.leaf_mut().values[llen..llen + rlen].copy_from_slice(&right.leaf().values[..rlen]);
            left.len += rlen;
            // Unlink `right` from the chain (invariant 6).
            let next = right.leaf().next;
            left.leaf_mut().next = next;
            if next.is_nil() {
                self.last_leaf = left_id;
            } else {
                self.nodes.get_mut(next).leaf_mut().prev = left_id;
            }
        } else {
            // The separator between two internal nodes is real routing
            // information for the children being joined: pull it DOWN.
            left.keys[llen] = separator;
            left.keys[llen + 1..llen + 1 + rlen].copy_from_slice(&right.keys[..rlen]);
            left.internal_mut().children[llen + 1..llen + 2 + rlen]
                .copy_from_slice(&right.internal().children[..rlen + 1]);
            left.len += 1 + rlen;
        }
        assert!(self.nodes.get(left_id).len <= self.max_keys());
        self.nodes.get_mut(parent_id).internal_remove_at(li);
        self.nodes.free(right_id);
        self.stats.merges += 1;
    }
}
