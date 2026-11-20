//! Top-down insert ("proactive" or "preventive" splitting): the textbook
//! alternative to base_insert.rs. This is B-TREE-INSERT from Cormen,
//! Leiserson, Rivest and Stein (CLRS), written for the order M of this guide
//! (CLRS minimum degree t = M / 2).
//!
//! The idea: never walk into a full node. On the way DOWN, a full child is
//! split before it is entered. The node we are standing in is therefore never
//! full, so it always has room for the median that a split below pushes up,
//! and nothing ever has to travel back up: one pass, no remembered path.
//!
//! What it costs:
//!
//! * M must be even. A full node has M - 1 keys. Taking the median out
//!   leaves M - 2, and both halves need ceil(M/2) - 1 keys. For even M that
//!   is exactly (M - 2) / 2 each. For odd M the halves would have to share
//!   M - 2 (an odd number) and each need (M - 1) / 2: one key short. The
//!   bottom-up split has one more key to share (the new one), so it works
//!   for every M.
//! * It splits nodes that did not need it: a full node on the path is split
//!   even when the leaf below has room (and even when the key turns out to
//!   be present already and is only overwritten).
//! * "Full" must be known before the key arrives. With fixed-size keys that
//!   is a count. With variable-length keys a page is full or not depending
//!   on the size of the separator that will come up, which is not known on
//!   the way down, so this method does not carry over to byte-sized pages
//!   as it stands.
//!
//! Allocation failure: each split is complete before the next one starts, so
//! an `Err(OutOfNodes)` half-way down leaves a VALID tree holding exactly the
//! same keys as before, but possibly with a different shape (the splits that
//! already happened stay). Compare base_insert.rs, which reserves all nodes
//! first and leaves the tree unchanged.
//!
//! Difference from the Zig twin: there an odd order is a compile error
//! (`@compileError`), because the order is a compile-time parameter. Here the
//! order is a run-time field, so the same mistake is a panic on the first call.

use crate::base_btree::BTree;
use crate::base_node::{Entry, Node, NodeId, max_keys, min_keys};
use crate::base_pool::OutOfNodes;
use crate::base_search::lower_bound;

/// Returns the previous value if the key was already present (overwrite).
///
/// # Panics
/// If the tree's order is odd.
pub fn put(tree: &mut BTree, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
    assert!(
        tree.order.is_multiple_of(2),
        "top-down splitting needs an even order M (see the file header)"
    );
    let full = max_keys(tree.order);

    let Some(root) = tree.root else {
        let mut leaf = Node::new(true);
        leaf.insert_entry(0, key, value);
        tree.root = Some(tree.pool.alloc(leaf)?);
        tree.len = 1;
        return Ok(None);
    };

    let mut id = root;
    if tree.pool[root].len() == full {
        // A full root is split before anything else: the tree grows at the
        // top. Two nodes are needed; take both before touching the tree so
        // that this split either happens completely or not at all.
        let usage_before = tree.pool.usage;
        let right = tree.pool.alloc(Node::new(true))?;
        let new_root = match tree.pool.alloc(Node::new(false)) {
            Ok(id) => id,
            Err(out_of_nodes) => {
                tree.pool.free(right);
                tree.pool.usage = usage_before;
                return Err(out_of_nodes);
            }
        };
        let median = split_full(tree, root, right);
        let node = &mut tree.pool[new_root];
        node.insert_entry(0, median.key, median.value);
        node.children = vec![root, right];
        tree.root = Some(new_root);
        tree.counters.splits += 1;
        tree.counters.root_splits += 1;
        id = new_root;
    }

    // Loop invariant: the node `id` is NOT full, so it can take one more key.
    loop {
        let node = &mut tree.pool[id];
        debug_assert!(node.len() < full);
        let i = lower_bound(&node.keys, key);
        if i < node.len() && node.keys[i] == key {
            return Ok(Some(std::mem::replace(&mut node.values[i], value)));
        }
        if node.leaf {
            node.insert_entry(i, key, value); // room is guaranteed
            tree.len += 1;
            return Ok(None);
        }
        let mut child = node.children[i];
        if tree.pool[child].len() == full {
            // Split the full child BEFORE entering it. Its median moves into
            // the current node, which has room by the invariant.
            let right = tree.pool.alloc(Node::new(true))?;
            let median = split_full(tree, child, right);
            let node = &mut tree.pool[id];
            node.children.insert(i + 1, right);
            node.insert_entry(i, median.key, median.value);
            tree.counters.splits += 1;
            // The key now belongs left of the median, right of it, or IS it.
            if key == median.key {
                node.values[i] = value;
                return Ok(Some(median.value));
            }
            if key > median.key {
                child = right;
            }
        }
        id = child;
    }
}

/// Split a FULL node (M - 1 keys, M even) around its median. `left` keeps
/// the lower M/2 - 1 keys, `right` (reserved, still empty) receives the upper
/// M/2 - 1, and the median entry is returned for the parent. Both halves end
/// up at exactly `min_keys`: a split never produces a node with fewer keys.
fn split_full(tree: &mut BTree, left: NodeId, right: NodeId) -> Entry {
    let min = min_keys(tree.order);
    let node = &mut tree.pool[left];
    debug_assert_eq!(node.len(), max_keys(tree.order));
    let mid = node.len() / 2;
    let upper = Node {
        leaf: node.leaf,
        keys: node.keys.split_off(mid + 1),
        values: node.values.split_off(mid + 1),
        // Children right of the median move with their keys.
        children: if node.leaf {
            Vec::new()
        } else {
            node.children.split_off(mid + 1)
        },
    };
    let median = Entry {
        key: node.keys.pop().expect("median"),
        value: node.values.pop().expect("median"),
    };
    debug_assert!(node.len() == min && upper.len() == min);
    tree.pool[right] = upper;
    median
}
