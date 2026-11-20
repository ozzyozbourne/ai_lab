// Copied from chapters/07-bplus-trees/rust/src/dump.rs; behaviour unchanged (only the
// module paths were renamed to base_*). Do not edit here.
//! Text rendering of a tree for the demo program and for debugging.
//!
//! ```text
//! height 2, 5 keys, 3 nodes
//!   level 0: #2[10]
//!   leaves : #0(5 6) <-> #1(10 12 20)
//! ```
//!
//! `#n` is a node handle, `[..]` an internal node (separators), `(..)` a leaf
//! (keys; values are omitted). Internal levels are printed by descending from
//! the root; the leaf line is printed by following the `next` links only, so
//! it shows the chain rather than the tree. `|` separates groups of siblings.

use std::io::{self, Write};

use crate::base_arena::NodeId;
use crate::base_tree::BPlusTree;

pub fn dump(tree: &BPlusTree, w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "height {}, {} keys, {} nodes",
        tree.height,
        tree.count,
        tree.nodes.live_count()
    )?;
    if tree.root.is_nil() {
        return Ok(());
    }
    for depth in 1..tree.height {
        write!(w, "  level {}:", depth - 1)?;
        let mut first_group = true;
        print_level(tree, tree.root, depth - 1, &mut first_group, w)?;
        writeln!(w)?;
    }
    write!(w, "  leaves :")?;
    let mut id = tree.first_leaf;
    while !id.is_nil() {
        write!(w, " ")?;
        print_node(tree, id, w)?;
        id = tree.nodes.get(id).leaf().next;
        if !id.is_nil() {
            write!(w, " <->")?;
        }
    }
    writeln!(w)
}

/// Prints the internal nodes that are `levels_down` levels below `id`.
fn print_level(
    tree: &BPlusTree,
    id: NodeId,
    levels_down: usize,
    first_group: &mut bool,
    w: &mut dyn Write,
) -> io::Result<()> {
    if levels_down == 0 {
        write!(w, " ")?;
        return print_node(tree, id, w);
    }
    if levels_down == 1 {
        // `id` is a parent of printed nodes: a bar between sibling groups.
        if !*first_group {
            write!(w, " |")?;
        }
        *first_group = false;
    }
    for &child in tree.nodes.get(id).child_slice() {
        print_level(tree, child, levels_down - 1, first_group, w)?;
    }
    Ok(())
}

fn print_node(tree: &BPlusTree, id: NodeId, w: &mut dyn Write) -> io::Result<()> {
    let n = tree.nodes.get(id);
    let (open, close) = if n.is_leaf() { ('(', ')') } else { ('[', ']') };
    write!(w, "#{}{open}", id.index())?;
    for (i, k) in n.key_slice().iter().enumerate() {
        if i != 0 {
            write!(w, " ")?;
        }
        write!(w, "{k}")?;
    }
    write!(w, "{close}")
}

/// The leaf handles from last to first, following `prev` links only.
pub fn dump_chain_backward(tree: &BPlusTree, w: &mut dyn Write) -> io::Result<()> {
    let mut id = tree.last_leaf;
    while !id.is_nil() {
        write!(w, " #{}", id.index())?;
        id = tree.nodes.get(id).leaf().prev;
    }
    Ok(())
}
