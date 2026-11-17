//! SECTION 3 of 6: search and ordered traversal (explained in chapter 03).
//!
//! Nothing here allocates or modifies the tree.

use crate::node::NodeId;
use crate::pool::Slab;

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
pub fn get(pool: &Slab, root: Option<NodeId>, key: u64) -> Option<u64> {
    let mut node = &pool[root?];
    loop {
        let i = lower_bound(&node.keys, key);
        if i < node.len() && node.keys[i] == key {
            return Some(node.values[i]);
        }
        if node.leaf {
            return None;
        }
        node = &pool[node.children[i]];
    }
}

/// In-order traversal: child 0, key 0, child 1, key 1, ..., last child.
/// Calls `visit(key, value)` for every entry in ascending key order.
pub fn in_order(pool: &Slab, root: Option<NodeId>, visit: &mut dyn FnMut(u64, u64)) {
    let Some(id) = root else { return };
    let node = &pool[id];
    for i in 0..=node.len() {
        if !node.leaf {
            in_order(pool, Some(node.children[i]), visit);
        }
        if i < node.len() {
            visit(node.keys[i], node.values[i]);
        }
    }
}

/// Entries with lo <= key < hi in ascending order. Like `in_order`, but it
/// skips the subtrees left of `lo` and stops at the first key >= `hi`.
pub fn range(pool: &Slab, root: Option<NodeId>, lo: u64, hi: u64, visit: &mut dyn FnMut(u64, u64)) {
    let Some(id) = root else { return };
    let node = &pool[id];
    let mut i = lower_bound(&node.keys, lo);
    loop {
        // children[i] holds keys below keys[i]; some of them may be >= lo.
        if !node.leaf {
            range(pool, Some(node.children[i]), lo, hi, visit);
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
        let mut pool = Slab::new();
        let mut left = Node::new(true);
        left.insert_entry(0, 5, 50);
        left.insert_entry(1, 10, 100);
        let mut right = Node::new(true);
        right.insert_entry(0, 30, 300);
        right.insert_entry(1, 40, 400);
        let mut top = Node::new(false);
        top.insert_entry(0, 20, 200);
        top.children = vec![pool.alloc(left).unwrap(), pool.alloc(right).unwrap()];
        let root = Some(pool.alloc(top).unwrap());

        assert_eq!(get(&pool, root, 20), Some(200)); // found in the interior node
        assert_eq!(get(&pool, root, 40), Some(400));
        assert_eq!(get(&pool, root, 25), None);
        assert_eq!(get(&pool, None, 25), None);

        let mut all = Vec::new();
        in_order(&pool, root, &mut |key, value| {
            assert_eq!(value, key * 10);
            all.push(key);
        });
        assert_eq!(all, [5, 10, 20, 30, 40]);
        let mut some = Vec::new();
        range(&pool, root, 10, 31, &mut |key, _| some.push(key));
        assert_eq!(some, [10, 20, 30]);
        let mut none = Vec::new();
        range(&pool, root, 21, 30, &mut |key, _| none.push(key));
        assert!(none.is_empty());
    }
}
