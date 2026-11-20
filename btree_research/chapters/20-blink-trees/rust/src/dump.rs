//! Text rendering of a tree for the demo program and for debugging.
//!
//! ```text
//! height 2, 7 keys, 5 nodes
//!   level 1: #2[10 20]
//!   level 0: #0(5 6)<10 -> #1(10 12)<20 {incomplete} -> #4(20 25)<30 {no downlink} -> #3(30 40)
//! ```
//!
//! `#n` is a node handle, `[..]` an internal node (separators), `(..)` a leaf
//! (keys). `<k` is the node's high key (keys in the node are below k); the
//! rightmost node of a level has none. `->` is a right link. `{incomplete}`
//! marks INCOMPLETE_SPLIT; the node after it is tagged `{no downlink}`.
//!
//! Every level is printed by following right links from its leftmost node,
//! because that is the only way to see a node whose downlink is missing.
//! Meaningful only while no other thread modifies the tree.

use std::io::{self, Write};

use crate::base_handle::NodeId;
use crate::blink::BLinkTree;

pub fn dump(tree: &BLinkTree, w: &mut dyn Write) -> io::Result<()> {
    let meta = tree.meta_snapshot();
    writeln!(
        w,
        "height {}, {} keys, {} nodes",
        meta.height,
        tree.len(),
        tree.node_count()
    )?;
    for level in (0..meta.height).rev() {
        write!(w, "  level {level}:")?;
        let mut id = meta.level_head[level];
        let mut left_is_incomplete = false;
        while !id.is_nil() {
            write!(w, " ")?;
            print_node(tree, id, w)?;
            let p = tree.read(id);
            if let Some(hk) = p.high_key {
                write!(w, "<{hk}")?;
            }
            if p.incomplete_split {
                write!(w, " {{incomplete}}")?;
            }
            if left_is_incomplete {
                write!(w, " {{no downlink}}")?;
            }
            if !p.right.is_nil() {
                write!(w, " ->")?;
            }
            left_is_incomplete = p.incomplete_split;
            id = p.right;
        }
        writeln!(w)?;
    }
    Ok(())
}

pub fn print_node(tree: &BLinkTree, id: NodeId, w: &mut dyn Write) -> io::Result<()> {
    let p = tree.read(id);
    let (open, close) = if p.level == 0 { ('(', ')') } else { ('[', ']') };
    write!(w, "#{}{open}", id.index())?;
    for (i, k) in p.node.key_slice().iter().enumerate() {
        if i != 0 {
            write!(w, " ")?;
        }
        write!(w, "{k}")?;
    }
    write!(w, "{close}")
}
