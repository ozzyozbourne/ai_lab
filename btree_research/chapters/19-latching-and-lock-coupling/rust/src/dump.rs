//! Text rendering and a leaf-chain walk. QUIESCENT ONLY, like `validate`.
//!
//! ```text
//! height 2, 5 keys, 3 nodes
//!   level 0: #2[10]
//!   leaves : #0(5 6) -> #1(10 12 20)
//! ```
//!
//! `#n` is a node handle, `[..]` an internal node (separators), `(..)` a leaf
//! (keys; values are omitted). The leaf line follows the `next` links.

use std::io::{self, Write};

use crate::base_node::{Entry, Kind, NodeId};
use crate::tree::Tree;

pub fn dump(tree: &Tree, w: &mut dyn Write) -> io::Result<()> {
    let height = tree.height();
    writeln!(
        w,
        "height {}, {} keys, {} nodes",
        height,
        tree.len(),
        tree.table.count()
    )?;
    for depth in 1..height {
        write!(w, "  level {}:", depth - 1)?;
        let mut first_group = true;
        print_level(tree, tree.root(), depth - 1, &mut first_group, w)?;
        writeln!(w)?;
    }
    write!(w, "  leaves :")?;
    let mut id = first_leaf(tree);
    while !id.is_nil() {
        write!(w, " ")?;
        print_node(tree, id, w)?;
        id = tree.table.read(id).leaf().next;
        if !id.is_nil() {
            write!(w, " ->")?;
        }
    }
    writeln!(w)
}

pub fn dump_to_string(tree: &Tree) -> String {
    let mut out = Vec::new();
    dump(tree, &mut out).expect("writing to a Vec cannot fail");
    String::from_utf8(out).expect("dump is ASCII")
}

/// Prints the internal nodes that are `levels_down` levels below `id`.
fn print_level(
    tree: &Tree,
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
    let children = tree.table.read(id).child_slice().to_vec();
    for child in children {
        print_level(tree, child, levels_down - 1, first_group, w)?;
    }
    Ok(())
}

fn print_node(tree: &Tree, id: NodeId, w: &mut dyn Write) -> io::Result<()> {
    let n = tree.table.read(id);
    let (open, close) = if n.is_leaf() { ('(', ')') } else { ('[', ']') };
    write!(w, "#{}{}", id.index(), open)?;
    for (i, k) in n.key_slice().iter().enumerate() {
        if i != 0 {
            write!(w, " ")?;
        }
        write!(w, "{k}")?;
    }
    write!(w, "{close}")
}

fn first_leaf(tree: &Tree) -> NodeId {
    let mut id = tree.root();
    loop {
        let next = match &tree.table.read(id).kind {
            Kind::Leaf(_) => return id,
            Kind::Internal(internal) => internal.children[0],
        };
        id = next;
    }
}

/// Every entry in key order, by walking the leaf chain. Used to compare the
/// final contents of a tree with the oracle. (Zig has a `Walker` iterator;
/// an iterator here would have to carry a guard, so this collects instead.)
pub fn entries(tree: &Tree) -> Vec<Entry> {
    let mut out = Vec::with_capacity(tree.len());
    let mut id = first_leaf(tree);
    while !id.is_nil() {
        let n = tree.table.read(id);
        let leaf = n.leaf();
        for i in 0..n.len {
            out.push(Entry {
                key: n.keys[i],
                value: leaf.values[i],
            });
        }
        id = leaf.next;
    }
    out
}
