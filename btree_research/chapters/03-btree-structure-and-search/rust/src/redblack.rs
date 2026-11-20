//! SECTION F: a 2-3-4 tree is a red-black tree in disguise.
//!
//! A B-tree of order 4 has nodes with 1, 2 or 3 keys. Draw each node as a
//! tiny binary tree: one BLACK node on top, the other keys as RED children.
//!
//! ```text
//! [b]        [a b]          [a b c]
//!
//!  b           b               b            black
//!             /               / \
//!            a               a   c          red
//! ```
//!
//! A red node therefore means "I belong to the same B-tree node as my
//! parent". The subtrees of the B-tree node hang below, in the same
//! left-to-right order. (For two keys the red one could also go to the
//! right; we always put it on the left, the "left-leaning" choice.)
//!
//! A red-black tree is a binary search tree (one key and at most two
//! children per node) with one colour per node, kept balanced by three
//! rules. Each of them follows from a B-tree rule:
//!   * the root is black             (the top of the root's B-tree node)
//!   * a red node has no red child   (a B-tree node has at most 3 keys)
//!   * every path from the root down to a missing child passes the same
//!     number of black nodes         (all B-tree leaves are on one level)
//!
//! `check` verifies all three and the order of the keys, so a broken
//! conversion would be caught.
//!
//! Like the B-tree, the red-black tree lives in a typed arena: a
//! `Vec<RbNode>` with `u32` indices instead of pointers.

use crate::base_node::{NodeId, Nodes};
use std::io::{self, Write};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Color {
    Red,
    Black,
}

/// Index of a node in `RbTree::nodes`.
pub type RbId = u32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RbNode {
    pub key: u64,
    pub color: Color,
    pub left: Option<RbId>,
    pub right: Option<RbId>,
}

#[derive(Debug, Default)]
pub struct RbTree {
    pub nodes: Vec<RbNode>,
    pub root: Option<RbId>,
}

impl RbTree {
    /// Convert the 2-3-4 tree below `root` into a red-black tree with the
    /// same keys: one `RbNode` per key.
    pub fn from_tree<P: Nodes + ?Sized>(nodes: &P, root: Option<NodeId>) -> Self {
        let mut tree = Self::default();
        tree.root = root.map(|id| tree.convert(nodes, id));
        tree
    }

    fn convert<P: Nodes + ?Sized>(&mut self, nodes: &P, id: NodeId) -> RbId {
        let n = &nodes[id];
        assert!((1..=3).contains(&n.len()), "not a 2-3-4 node");
        // Converted subtrees, left to right (all None below a leaf).
        let mut sub = [None; 4];
        for (i, &child) in n.children.iter().enumerate() {
            sub[i] = Some(self.convert(nodes, child));
        }
        let k = &n.keys;
        match n.len() {
            1 => self.make(k[0], Color::Black, sub[0], sub[1]),
            2 => {
                let red = self.make(k[0], Color::Red, sub[0], sub[1]);
                self.make(k[1], Color::Black, Some(red), sub[2])
            }
            _ => {
                let left = self.make(k[0], Color::Red, sub[0], sub[1]);
                let right = self.make(k[2], Color::Red, sub[2], sub[3]);
                self.make(k[1], Color::Black, Some(left), Some(right))
            }
        }
    }

    fn make(&mut self, key: u64, color: Color, left: Option<RbId>, right: Option<RbId>) -> RbId {
        self.nodes.push(RbNode {
            key,
            color,
            left,
            right,
        });
        (self.nodes.len() - 1) as RbId
    }

    /// Check the red-black rules and the search-tree order.
    pub fn check(&self) -> Result<Summary, RbError> {
        let Some(root) = self.root else {
            return Ok(Summary::default());
        };
        if self.nodes[root as usize].color == Color::Red {
            return Err(RbError::RootIsRed);
        }
        let mut s = Summary {
            shortest_path: usize::MAX,
            ..Summary::default()
        };
        s.black_height = self.walk(root, None, None, 1, &mut s)?;
        Ok(s)
    }

    /// Returns the number of black nodes from `id` down to a missing child.
    fn walk(
        &self,
        id: RbId,
        lo: Option<u64>,
        hi: Option<u64>,
        level: usize,
        s: &mut Summary,
    ) -> Result<usize, RbError> {
        let node = &self.nodes[id as usize];
        s.nodes += 1;
        if lo.is_some_and(|lo| node.key <= lo) || hi.is_some_and(|hi| node.key >= hi) {
            return Err(RbError::KeysOutOfOrder);
        }
        let mut black = [0; 2];
        let sides = [
            (node.left, lo, Some(node.key)),
            (node.right, Some(node.key), hi),
        ];
        for (side, (child, child_lo, child_hi)) in sides.into_iter().enumerate() {
            if let Some(c) = child {
                if node.color == Color::Red && self.nodes[c as usize].color == Color::Red {
                    return Err(RbError::RedHasRedChild);
                }
                black[side] = self.walk(c, child_lo, child_hi, level + 1, s)?;
            } else {
                // A path ends here.
                s.shortest_path = s.shortest_path.min(level);
                s.longest_path = s.longest_path.max(level);
            }
        }
        if black[0] != black[1] {
            return Err(RbError::BlackHeightDiffers);
        }
        Ok(black[0] + usize::from(node.color == Color::Black))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RbError {
    RootIsRed,
    RedHasRedChild,
    BlackHeightDiffers,
    KeysOutOfOrder,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Summary {
    pub nodes: usize,
    /// Black nodes on every path from the root to a missing child.
    pub black_height: usize,
    /// Nodes on the shortest / longest such path.
    pub shortest_path: usize,
    pub longest_path: usize,
}

/// One line for one 2-3-4 node, e.g. "10 black, red children 6 and 20".
pub fn describe(keys: &[u64], w: &mut dyn Write) -> io::Result<()> {
    match keys {
        [b] => write!(w, "{b} black"),
        [a, b] => write!(w, "{b} black, red left child {a}"),
        [a, b, c] => write!(w, "{b} black, red children {a} and {c}"),
        _ => panic!("not a 2-3-4 node"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::{HandTree, canonical};

    #[test]
    fn the_canonical_tree_as_a_red_black_tree() {
        let mut t = HandTree::new(4);
        canonical(&mut t).unwrap();
        let rb = RbTree::from_tree(&t.arena, t.root);
        //             10
        //        6r        20r
        //      3    7    15    30
        //    1r 5r     12r 17r 25r
        let node = |id: Option<RbId>| rb.nodes[id.unwrap() as usize];
        let root = node(rb.root);
        assert_eq!(root.key, 10);
        assert_eq!(node(root.left).color, Color::Red);
        assert_eq!(node(root.left).key, 6);
        assert_eq!(node(node(root.left).right).key, 7);
        let thirty = node(node(root.right).right);
        assert_eq!(thirty.key, 30);
        assert_eq!(node(thirty.left).key, 25);
        assert_eq!(thirty.right, None);
        let want = Summary {
            nodes: 12,
            black_height: 2,
            shortest_path: 3,
            longest_path: 4,
        };
        assert_eq!(rb.check(), Ok(want));
        assert_eq!(RbTree::default().check(), Ok(Summary::default()));
    }

    #[test]
    fn black_height_equals_btree_height_no_path_is_more_than_twice_as_long_as_another() {
        let keys: Vec<u64> = (0..300).collect();
        for n in 0..=keys.len() {
            let mut t = HandTree::new(4);
            t.from_sorted(&keys[..n]).unwrap();
            let s = RbTree::from_tree(&t.arena, t.root).check().unwrap();
            assert_eq!(s.nodes, n);
            assert_eq!(s.black_height, t.shape().height);
            assert!(s.longest_path <= 2 * s.shortest_path);
        }
    }

    #[test]
    fn check_rejects_trees_that_break_a_red_black_rule() {
        let node = |key, color, left| RbNode {
            key,
            color,
            left,
            right: None,
        };
        // index 0: a = 1, index 1: b = 2 above a, index 2: c = 3 above b
        let mut rb = RbTree {
            nodes: vec![
                node(1, Color::Red, None),
                node(2, Color::Red, Some(0)),
                node(3, Color::Black, Some(1)),
            ],
            root: Some(1),
        };
        assert_eq!(rb.check(), Err(RbError::RootIsRed));
        rb.root = Some(2);
        assert_eq!(rb.check(), Err(RbError::RedHasRedChild));
        rb.nodes[0].color = Color::Black; // 3 -> 2r -> 1: the left path has one more black node
        assert_eq!(rb.check(), Err(RbError::BlackHeightDiffers));
        rb.nodes[0] = node(9, Color::Red, None);
        rb.nodes[1].color = Color::Black;
        rb.root = Some(1);
        assert_eq!(rb.check(), Err(RbError::KeysOutOfOrder));
    }
}
