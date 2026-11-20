// Copied from chapters/05-deletion-and-rebalancing/rust/src/search.rs
//! SECTION 3: search and ordered traversal (explained in chapter 03).
//!
//! Nothing here allocates or modifies the tree. This file needs only
//! node.rs: the nodes are reached through the [`Nodes`] trait, so they may
//! live in the slab of pool.rs or in a plain `Vec<Node>`.

use crate::node::{NodeId, Nodes};

/// Index of the first key that is >= `key` (chapter 02). For a key that is
/// absent this is both the place where it would be inserted and the index of
/// the child whose subtree would contain it.
pub fn lower_bound(keys: &[u64], key: u64) -> usize {
    let mut lo = 0;
    let mut hi = keys.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if keys[mid] < key {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}

/// Walk down from the root: one node per level.
pub fn get<P: Nodes + ?Sized>(nodes: &P, root: Option<NodeId>, key: u64) -> Option<u64> {
    let mut node = &nodes[root?];
    loop {
        let i = lower_bound(&node.keys, key);
        if i < node.len() && node.keys[i] == key {
            return Some(node.values[i]);
        }
        if node.leaf {
            return None;
        }
        node = &nodes[node.children[i]];
    }
}

/// In-order traversal: child 0, key 0, child 1, key 1, ..., last child.
/// Calls `visit(key, value)` for every entry in ascending key order.
pub fn in_order<P: Nodes + ?Sized>(
    nodes: &P,
    root: Option<NodeId>,
    visit: &mut dyn FnMut(u64, u64),
) {
    let Some(id) = root else { return };
    let node = &nodes[id];
    for i in 0..=node.len() {
        if !node.leaf {
            in_order(nodes, Some(node.children[i]), visit);
        }
        if i < node.len() {
            visit(node.keys[i], node.values[i]);
        }
    }
}

/// Entries with lo <= key < hi in ascending order. Like `in_order`, but it
/// skips the subtrees left of `lo` and stops at the first key >= `hi`.
///
/// Limitation of the half-open interval: no `hi` is larger than `u64::MAX`,
/// so this function can never return the key `u64::MAX`. `get` and
/// `in_order` reach it. Chapter 08 introduces inclusive and unbounded bounds.
pub fn range<P: Nodes + ?Sized>(
    nodes: &P,
    root: Option<NodeId>,
    lo: u64,
    hi: u64,
    visit: &mut dyn FnMut(u64, u64),
) {
    let Some(id) = root else { return };
    let node = &nodes[id];
    let mut i = lower_bound(&node.keys, lo);
    loop {
        // children[i] holds keys below keys[i]; some of them may be >= lo.
        if !node.leaf {
            range(nodes, Some(node.children[i]), lo, hi, visit);
        }
        if i == node.len() || node.keys[i] >= hi {
            return;
        }
        visit(node.keys[i], node.values[i]);
        i += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::Node;

    #[test]
    fn lower_bound_cases() {
        let keys = [10, 20, 30];
        assert_eq!(lower_bound(&keys, 5), 0);
        assert_eq!(lower_bound(&keys, 10), 0);
        assert_eq!(lower_bound(&keys, 11), 1);
        assert_eq!(lower_bound(&keys, 30), 2);
        assert_eq!(lower_bound(&keys, 31), 3);
        assert_eq!(lower_bound(&[], 1), 0);
    }

    #[test]
    fn get_in_order_and_range_on_a_tree_built_by_hand() {
        //            [20]
        //     [5 10]      [30 40]
        // A plain Vec<Node> is enough: search does not care where nodes live.
        let mut nodes: Vec<Node> = Vec::new();
        let mut alloc = |node: Node| {
            nodes.push(node);
            NodeId(nodes.len() as u32 - 1)
        };
        let mut left = Node::new(true);
        left.insert_entry(0, 5, 50);
        left.insert_entry(1, 10, 100);
        let mut right = Node::new(true);
        right.insert_entry(0, 30, 300);
        right.insert_entry(1, 40, 400);
        let mut top = Node::new(false);
        top.insert_entry(0, 20, 200);
        top.children = vec![alloc(left), alloc(right)];
        let root = Some(alloc(top));

        assert_eq!(get(&nodes, root, 20), Some(200)); // found in the interior node
        assert_eq!(get(&nodes, root, 40), Some(400));
        assert_eq!(get(&nodes, root, 25), None);
        assert_eq!(get(&nodes, None, 25), None);

        let mut all = Vec::new();
        in_order(&nodes, root, &mut |key, value| {
            assert_eq!(value, key * 10);
            all.push(key);
        });
        assert_eq!(all, [5, 10, 20, 30, 40]);
        let mut some = Vec::new();
        range(&nodes, root, 10, 31, &mut |key, _| some.push(key));
        assert_eq!(some, [10, 20, 30]);
        let mut none = Vec::new();
        range(&nodes, root, 21, 30, &mut |key, _| none.push(key));
        assert!(none.is_empty());
    }

    #[test]
    fn range_cannot_reach_the_key_u64_max_get_and_in_order_can() {
        let mut leaf = Node::new(true);
        leaf.insert_entry(0, 7, 70);
        leaf.insert_entry(1, u64::MAX, 1);
        let nodes = vec![leaf];
        let root = Some(NodeId(0));
        assert_eq!(get(&nodes, root, u64::MAX), Some(1));
        let mut all = Vec::new();
        in_order(&nodes, root, &mut |key, _| all.push(key));
        assert_eq!(all, [7, u64::MAX]);
        let mut widest = Vec::new();
        range(&nodes, root, 0, u64::MAX, &mut |key, _| widest.push(key)); // the widest interval there is
        assert_eq!(widest, [7]);
    }
}
