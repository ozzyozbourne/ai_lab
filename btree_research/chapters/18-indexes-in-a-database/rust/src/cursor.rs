//! Cost counters and the counting index cursor.
//!
//! Every query of this chapter is built from two primitives and the counters
//! count exactly those:
//!
//!   * a DESCENT: walk one tree from its root to a leaf (`height` nodes);
//!   * a ROW FETCH: leave an index entry and go and get the row it points to.
//!
//! What a row fetch costs is the whole difference between the two layouts,
//! so `table.rs` is where it is charged. Counts only, never timings.
//!
//! The counters sit in a `Cell`: counting is the one thing a read-only query
//! changes, and interior mutability lets every query keep taking `&self`.
//! (The Zig queries take `*Table` for the same reason and nothing stops them
//! from changing more.)

use std::cell::Cell;

use crate::base_arena::NodeId;
use crate::base_search::lower_bound;
use crate::base_tree::BPlusTree;
use crate::row::KeyRange;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Counters {
    /// Root-to-leaf walks, in any tree.
    pub descents: usize,
    /// Tree nodes read: `height` per descent, plus one per leaf-link hop.
    pub tree_nodes: usize,
    /// Index entries a scan returned.
    pub index_entries: usize,
    /// Times a query followed a locator from an index entry to the row.
    pub row_fetches: usize,
    /// Heap pages read by TID (always 0 in the clustered layout, where a row
    /// fetch is a descent of the primary tree and shows up in `tree_nodes`).
    pub heap_reads: usize,
}

impl Counters {
    /// Nodes and heap pages are both "one page" on disk. This is the number
    /// of page reads with no cache at all (chapter 09 adds the cache).
    pub fn page_reads(&self) -> usize {
        self.tree_nodes + self.heap_reads
    }

    pub fn minus(&self, earlier: Counters) -> Counters {
        Counters {
            descents: self.descents - earlier.descents,
            tree_nodes: self.tree_nodes - earlier.tree_nodes,
            index_entries: self.index_entries - earlier.index_entries,
            row_fetches: self.row_fetches - earlier.row_fetches,
            heap_reads: self.heap_reads - earlier.heap_reads,
        }
    }
}

/// Read, change, write back: the whole API of a `Cell` of a `Copy` struct.
pub fn count(counters: &Cell<Counters>, change: impl FnOnce(&mut Counters)) {
    let mut c = counters.get();
    change(&mut c);
    counters.set(c);
}

/// Charges one root-to-leaf walk of `tree`.
pub fn charge_descent(counters: &Cell<Counters>, tree: &BPlusTree) {
    count(counters, |c| {
        c.descents += 1;
        c.tree_nodes += tree.height;
    });
}

/// Forward scan of the keys in a closed range: one descent to the first key
/// that is not below range.lo, then the leaf chain until a key is above range.hi. It never goes
/// back up the tree, and it never looks at a row: it returns index KEYS, and
/// the caller decides whether those are enough (a covering scan) or whether
/// each one must be followed to its row.
///
/// Holds a handle and an index. Because it borrows the tree, the compiler
/// rejects a `put` or `delete` while a cursor is alive.
pub struct Cursor<'a> {
    tree: &'a BPlusTree,
    counters: &'a Cell<Counters>,
    leaf: NodeId,
    index: usize,
    hi: u64,
}

impl<'a> Cursor<'a> {
    pub fn seek(tree: &'a BPlusTree, range: KeyRange, counters: &'a Cell<Counters>) -> Cursor<'a> {
        charge_descent(counters, tree);
        let leaf = tree.find_leaf(range.lo);
        let index = if leaf.is_nil() {
            0
        } else {
            lower_bound(tree.nodes.get(leaf).key_slice(), range.lo)
        };
        Cursor {
            tree,
            counters,
            leaf,
            index,
            hi: range.hi,
        }
    }
}

impl Iterator for Cursor<'_> {
    type Item = u64;

    fn next(&mut self) -> Option<u64> {
        while !self.leaf.is_nil() {
            let n = self.tree.nodes.get(self.leaf);
            if self.index < n.len {
                let key = n.keys[self.index];
                if key > self.hi {
                    break; // keys only grow from here: done
                }
                self.index += 1;
                count(self.counters, |c| c.index_entries += 1);
                return Some(key);
            }
            // End of this leaf: follow the sibling link, one more node read.
            self.leaf = n.leaf().next;
            self.index = 0;
            if !self.leaf.is_nil() {
                count(self.counters, |c| c.tree_nodes += 1);
            }
        }
        self.leaf = NodeId::NIL;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_returns_the_closed_range_and_counts_its_work() {
        let mut tree = BPlusTree::new(4);
        for k in 1..21 {
            tree.put(k * 10, 0).unwrap();
        }
        assert_eq!(tree.height, 3);

        let counters = Cell::new(Counters::default());
        let mut cursor = Cursor::seek(&tree, KeyRange { lo: 45, hi: 90 }, &counters);
        for expected in [50, 60, 70, 80, 90] {
            assert_eq!(cursor.next(), Some(expected));
        }
        assert_eq!(cursor.next(), None);
        assert_eq!(cursor.next(), None);
        let c = counters.get();
        assert_eq!(c.descents, 1);
        assert_eq!(c.index_entries, 5);
        // 3 nodes for the descent, the rest are leaf-link hops; never a second descent.
        assert!(c.tree_nodes > 3 && c.tree_nodes <= 3 + 3);

        // An empty range and an empty tree cost a descent and return nothing.
        let mut none = Cursor::seek(&tree, KeyRange { lo: 91, hi: 99 }, &counters);
        assert_eq!(none.next(), None);
        let empty = BPlusTree::new(4);
        let mut on_empty = Cursor::seek(&empty, KeyRange::ALL, &counters);
        assert_eq!(on_empty.next(), None);
        assert_eq!(counters.get().descents, 3);
    }
}
