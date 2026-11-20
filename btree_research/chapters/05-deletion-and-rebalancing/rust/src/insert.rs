//! SECTION 4: insert with bottom-up splitting (explained in chapter 04).
//!
//! `put` works in three phases:
//!
//! 1. descend to the leaf, remembering the path (node + child index per level);
//! 2. RESERVE every node the splits will need. This is the only step that
//!    can fail, and the tree has not been touched yet;
//! 3. COMMIT: insert into the leaf, then split upwards along the path while
//!    a node is overfull. Nothing in this phase can fail.
//!
//! Reserving first means a failed allocation leaves the tree exactly as it
//! was (see `put_under_allocation_failure_leaves_the_tree_unchanged` in
//! tests_insert.rs). The slab's `usage` counters are put back as well, so a
//! failed `put` cannot be seen from the tree at all. The one trace it can
//! leave is inside the slab: a slot that was pushed for a reservation and
//! returned stays on the free list.
//!
//! This file needs node.rs, search.rs (`lower_bound`) and the slab, nothing
//! from delete.rs.

use crate::btree::BTree;
use crate::node::{Entry, Node, NodeId, max_keys, min_keys};
use crate::pool::OutOfNodes;
use crate::search::lower_bound;

/// A tree of order 3 with 2^64 keys is at most 64 levels high (chapter 03).
pub const MAX_HEIGHT: usize = 64;

/// Returns the previous value if the key was already present (overwrite).
/// On `Err(OutOfNodes)` the tree, its counters and `pool.usage` are unchanged.
pub fn put(tree: &mut BTree, key: u64, value: u64) -> Result<Option<u64>, OutOfNodes> {
    let Some(root) = tree.root else {
        let mut leaf = Node::new(true);
        leaf.insert_entry(0, key, value);
        tree.root = Some(tree.pool.alloc(leaf)?);
        tree.len = 1;
        return Ok(None);
    };

    // Phase 1: descend. path[d].1 is the child we followed at depth d
    // (in the leaf: the position where the key belongs).
    let mut path = [(root, 0usize); MAX_HEIGHT];
    let mut depth = 0;
    let mut id = root;
    loop {
        let node = &mut tree.pool[id];
        let i = lower_bound(&node.keys, key);
        if i < node.len() && node.keys[i] == key {
            // Duplicate key: overwrite, no structural change.
            return Ok(Some(std::mem::replace(&mut node.values[i], value)));
        }
        path[depth] = (id, i);
        depth += 1;
        if node.leaf {
            break;
        }
        id = node.children[i];
    }

    // Phase 2: reserve. A split propagates upwards exactly as long as the
    // nodes on the path are full, so count the full nodes from the leaf up.
    let full = max_keys(tree.order);
    let mut need = 0;
    while need < depth && tree.pool[path[depth - 1 - need].0].len() == full {
        need += 1;
    }
    if need == depth {
        need += 1; // the root splits too: one more node for the new root
    }
    let mut spare: Vec<NodeId> = Vec::with_capacity(need);
    let usage_before = tree.pool.usage;
    for _ in 0..need {
        match tree.pool.alloc(Node::new(true)) {
            Ok(id) => spare.push(id),
            Err(out_of_nodes) => {
                // Hand back what we already took (Zig: `errdefer`), and
                // forget that we took it: `usage` (created, destroyed, peak)
                // counts nodes of the tree, and these never became part of it.
                for id in spare {
                    tree.pool.free(id);
                }
                tree.pool.usage = usage_before;
                return Err(out_of_nodes);
            }
        }
    }

    // Phase 3: commit.
    let mut level = depth - 1;
    tree.pool[path[level].0].insert_entry(path[level].1, key, value);
    tree.len += 1;
    let mut spare = spare.into_iter();
    while tree.pool[path[level].0].len() > full {
        let left = path[level].0;
        let right = spare.next().expect("reserved");
        let median = split_node(tree, left, right);
        tree.counters.splits += 1;
        if level == 0 {
            // The root was split: the tree grows by one level, at the top.
            // This is the only way a B-tree gets taller, which is why all
            // leaves stay at the same depth.
            let new_root = spare.next().expect("reserved");
            let node = &mut tree.pool[new_root];
            node.leaf = false;
            node.insert_entry(0, median.key, median.value);
            node.children = vec![left, right];
            tree.root = Some(new_root);
            tree.counters.root_splits += 1;
            break;
        }
        // Push the median into the parent, right half next to the left half.
        // The parent may now be overfull: the loop handles it.
        level -= 1;
        let (parent, at) = path[level];
        tree.pool[parent].children.insert(at + 1, right);
        tree.pool[parent].insert_entry(at, median.key, median.value);
    }
    debug_assert!(spare.next().is_none());
    Ok(None)
}

/// Split an overfull node (M keys) around its median. `left` keeps the lower
/// half, `right` (reserved, still empty) receives the upper half, and the
/// median entry is returned for the parent. With `mid = M / 2`:
/// left keeps mid keys, right gets M - 1 - mid keys; both are >= min_keys.
fn split_node(tree: &mut BTree, left: NodeId, right: NodeId) -> Entry {
    let node = &mut tree.pool[left];
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
    debug_assert!(node.len() >= min_keys(tree.order) && upper.len() >= min_keys(tree.order));
    tree.pool[right] = upper;
    median
}
