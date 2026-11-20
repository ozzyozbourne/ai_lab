//! Text rendering of one tree (any `View`) for the demo program and tests.
//!
//!     txn 13: root #11, height 3, 13 keys
//!       level 0: #11[15]
//!       level 1: #8[6 10] #10[20]
//!       leaves : #0(1 3 5) #4(6 7) #9(10 12 13) | #5(15 17) #3(20 25 30)
//!
//! `#n` is a page id, `[..]` an internal node (separators), `(..)` a leaf
//! (keys; values are omitted). `|` separates groups of siblings. Every level
//! is printed by descending from the root: there is no leaf chain to follow.

use std::io::{self, Write};

use crate::base_node::PageId;
use crate::read::View;

pub fn dump(view: View<'_>, txn_id: u64, w: &mut dyn Write) -> io::Result<()> {
    if view.root.is_nil() {
        return writeln!(w, "txn {txn_id}: empty tree");
    }
    writeln!(
        w,
        "txn {txn_id}: root #{}, height {}, {} keys",
        view.root.index(),
        view.height,
        view.count
    )?;
    for level in 0..view.height {
        if level + 1 == view.height {
            write!(w, "  leaves :")?;
        } else {
            write!(w, "  level {level}:")?;
        }
        let mut first_group = true;
        print_level(view, view.root, level, &mut first_group, w)?;
        writeln!(w)?;
    }
    Ok(())
}

/// Prints the nodes that are `levels_down` levels below `id`.
fn print_level(view: View<'_>, id: PageId, levels_down: usize, first_group: &mut bool, w: &mut dyn Write) -> io::Result<()> {
    if levels_down == 0 {
        write!(w, " ")?;
        return print_node(view, id, w);
    }
    if levels_down == 1 {
        // `id` is a parent of printed nodes: a bar between sibling groups.
        if !*first_group {
            write!(w, " |")?;
        }
        *first_group = false;
    }
    for &child in view.node(id).child_slice() {
        print_level(view, child, levels_down - 1, first_group, w)?;
    }
    Ok(())
}

fn print_node(view: View<'_>, id: PageId, w: &mut dyn Write) -> io::Result<()> {
    let n = view.node(id);
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

/// Sets `marks[p]` for every page the view's root reaches. `marks` must have
/// one entry per page of the store (and the view must be a committed one).
pub fn mark_reachable(view: View<'_>, marks: &mut [bool]) {
    if !view.root.is_nil() {
        mark_from(view, view.root, marks);
    }
}

fn mark_from(view: View<'_>, id: PageId, marks: &mut [bool]) {
    marks[id.index()] = true;
    let n = view.node(id);
    if n.is_leaf() {
        return;
    }
    for &child in n.child_slice() {
        mark_from(view, child, marks);
    }
}
