//! Wide nodes: the idea behind the B-tree, without building one yet.
//!
//! Binary search halves the remaining keys with every page it reads. If one
//! page holds M-1 separator keys, reading that page can cut the remaining
//! keys into M parts instead of 2. That is all a B-tree node is: a sorted
//! array of separators, plus one child pointer for each gap between them.
//!
//! This file does NOT build nodes. It searches an ordinary sorted slice the
//! way a balanced, evenly filled tree of order M laid over that slice would,
//! and counts one page read per node it would visit. Chapters 03 to 05 build
//! the real, updatable structure; here we only need the cost of a lookup.
//!
//! "Order M" follows Knuth: a node has at most M children and M-1 keys.

use crate::cost::{Entry, Trace};
use crate::height;
use std::cmp::Ordering;

/// Look `key` up in `sorted` as a tree of order `m` would. Requires m >= 2.
pub fn get_traced(sorted: &[Entry], m: usize, key: u64, trace: &mut Trace) -> Option<u64> {
    assert!(m >= 2);
    // The subtree we are in covers sorted[lo..hi].
    let mut lo = 0;
    let mut hi = sorted.len();
    while lo < hi {
        trace.page_reads += 1; // read the node that is the root of this subtree
        let size = hi - lo;
        let levels = height::min_height(size as u64, m as u64); // of this subtree; >= 1

        if levels == 1 {
            // Leaf: all remaining keys (at most m-1) are in this one node.
            // Scan them. (Chapter 02 replaces this scan by a binary search.
            // Either way it is work inside a page that is already in memory.)
            for entry in &sorted[lo..hi] {
                trace.comparisons += 1;
                if entry.key == key {
                    return Some(entry.value);
                }
                if entry.key > key {
                    return None;
                }
            }
            return None;
        }

        // Interior node. A child is a subtree of levels-1 levels and holds at
        // most m^(levels-1) - 1 keys, so `children` of them (plus the
        // children-1 separators between them) are needed for `size` keys.
        let child_capacity_plus_one = m.pow(levels - 1);
        let children = (size + child_capacity_plus_one) / child_capacity_plus_one; // ceil((size+1) / cap+1), 2..m
        // The separators cut the other keys into children whose sizes differ
        // by at most one, so every child is at least about half full.
        let below = size - (children - 1);
        let base = below / children;
        let extra = below % children; // the first `extra` children get one more key
        let mut child_start = lo;
        let mut child = 0;
        loop {
            let child_len = base + usize::from(child < extra);
            let separator = child_start + child_len; // index of the key after this child
            if child == children - 1 {
                // Larger than every separator: the last child.
                lo = child_start;
                hi = child_start + child_len;
                break;
            }
            trace.comparisons += 1;
            match key.cmp(&sorted[separator].key) {
                Ordering::Equal => return Some(sorted[separator].value), // interior nodes hold entries too
                Ordering::Less => {
                    lo = child_start;
                    hi = separator;
                    break;
                }
                Ordering::Greater => child_start = separator + 1,
            }
            child += 1;
        }
    }
    None // only reached when `sorted` is empty
}

pub fn get(sorted: &[Entry], m: usize, key: u64) -> Option<u64> {
    get_traced(sorted, m, key, &mut Trace::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_sorted(n: usize) -> Vec<Entry> {
        (0..n as u64)
            .map(|i| Entry {
                key: (i + 1) * 10,
                value: i,
            })
            .collect()
    }

    #[test]
    fn finds_every_key_and_nothing_else_for_many_sizes_and_orders() {
        for n in [0, 1, 2, 3, 4, 5, 15, 16, 63, 64, 255, 300] {
            let sorted = make_sorted(n);
            for m in [2, 3, 4, 5, 16, 171] {
                let levels = u64::from(height::min_height(n as u64, m as u64));
                let mut deepest = 0;
                for entry in &sorted {
                    let mut trace = Trace::new();
                    assert_eq!(
                        get_traced(&sorted, m, entry.key, &mut trace),
                        Some(entry.value)
                    );
                    deepest = deepest.max(trace.page_reads);
                    // Absent keys just below and just above each present key.
                    for absent in [entry.key - 1, entry.key + 1] {
                        let mut trace = Trace::new();
                        assert_eq!(get_traced(&sorted, m, absent, &mut trace), None);
                        // A miss always ends in a leaf, and for m >= 3 all leaves
                        // are at the same depth: the mark of a B-tree.
                        if m >= 3 {
                            assert_eq!(trace.page_reads, levels);
                        }
                    }
                }
                // The stand-in is as shallow as a tree of order m can be.
                assert_eq!(deepest, levels);
            }
        }
    }

    #[test]
    fn the_canonical_12_keys_with_m_4_need_2_page_reads() {
        let keys = [1, 3, 5, 6, 7, 10, 12, 15, 17, 20, 25, 30];
        let sorted: Vec<Entry> = keys
            .iter()
            .map(|&k| Entry {
                key: k,
                value: k * 10,
            })
            .collect();
        // Root holds 6, 12, 20; children are [1 3 5] [7 10] [15 17] [25 30].
        let mut trace = Trace::new();
        assert_eq!(get_traced(&sorted, 4, 17, &mut trace), Some(170));
        assert_eq!(trace.page_reads, 2);
        let mut trace = Trace::new();
        assert_eq!(get_traced(&sorted, 4, 12, &mut trace), Some(120));
        assert_eq!(trace.page_reads, 1); // found in the root
    }

    #[test]
    fn a_node_gets_only_as_many_children_as_it_needs() {
        // 5 keys, M = 4: two leaves are enough, so the root holds ONE separator
        // (30) with children [10 20] and [40 50], not three separators.
        let sorted = make_sorted(5);
        let mut trace = Trace::new();
        assert_eq!(get_traced(&sorted, 4, 30, &mut trace), Some(2));
        assert_eq!((trace.page_reads, trace.comparisons), (1, 1));
        let mut trace = Trace::new();
        assert_eq!(get_traced(&sorted, 4, 50, &mut trace), Some(4));
        assert_eq!((trace.page_reads, trace.comparisons), (2, 3)); // 30, then 40 and 50 in the leaf
    }
}
