//! Text rendering of a Db for the demo program and for debugging.
//!
//!     now=7 horizon=3 | height 2, 4 entries, 3 pages
//!       level 0: #2[20.1]
//!       leaves : #0(10:1-) -> #1(20:2-4! 20:4- 30:3-5)
//!       deleted: #5@9->#1
//!       free   : #4
//!
//! `#n` is a page handle. `[..]` is an internal page; a separator is printed
//! as `key.tid`. `(..)` is a leaf; an entry is printed as `key:xmin-xmax`
//! (the two numbers come from the version store, not from the index), `-`
//! with nothing after it means "not deleted", and `!` is the dead hint bit.
//! `#n(half-dead)` is a page between the two phases. A deleted page is shown
//! with its stamp and the right link it keeps. `free` is the arena's free
//! list: the next split takes the first page on it.

use std::io::{self, Write};

use crate::base_arena::NodeId;
use crate::base_node::{self as node, Kind, PageState};
use crate::db::Db;

pub fn dump(db: &Db, w: &mut dyn Write) -> io::Result<()> {
    let index = &db.index;
    writeln!(
        w,
        "now={} horizon={} | height {}, {} entries, {} pages",
        db.store.now,
        db.store.horizon(),
        index.height,
        index.count,
        index.nodes.live_count()
    )?;
    if index.root.is_nil() {
        return Ok(());
    }
    for depth in 1..index.height {
        write!(w, "  level {}:", depth - 1)?;
        print_level(db, index.root, depth - 1, w)?;
        writeln!(w)?;
    }
    write!(w, "  leaves :")?;
    let mut id = index.first_leaf;
    while !id.is_nil() {
        write!(w, " ")?;
        print_node(db, id, w)?;
        id = index.nodes.get(id).leaf().next;
        if !id.is_nil() {
            write!(w, " ->")?;
        }
    }
    writeln!(w)?;
    if !index.deleted_head.is_nil() {
        write!(w, "  deleted:")?;
        id = index.deleted_head;
        while !id.is_nil() {
            let leaf = index.nodes.get(id).leaf();
            let PageState::Deleted(stamp) = leaf.state else {
                unreachable!("only deleted pages are queued");
            };
            write!(w, " #{}@{stamp}->", id.index())?;
            if leaf.next.is_nil() {
                write!(w, "end")?;
            } else {
                write!(w, "#{}", leaf.next.index())?;
            }
            id = leaf.next_deleted;
        }
        writeln!(w)?;
    }
    let free = index.nodes.free_list().expect("intact free list");
    if !free.is_empty() {
        write!(w, "  free   :")?;
        for id in free {
            write!(w, " #{}", id.index())?;
        }
        writeln!(w)?;
    }
    Ok(())
}

/// Prints the internal pages that are `levels_down` levels below `id`.
fn print_level(db: &Db, id: NodeId, levels_down: usize, w: &mut dyn Write) -> io::Result<()> {
    if levels_down == 0 {
        write!(w, " ")?;
        return print_node(db, id, w);
    }
    for &child in db.index.nodes.get(id).child_slice() {
        print_level(db, child, levels_down - 1, w)?;
    }
    Ok(())
}

fn print_node(db: &Db, id: NodeId, w: &mut dyn Write) -> io::Result<()> {
    let n = db.index.nodes.get(id);
    write!(w, "#{}", id.index())?;
    match &n.kind {
        Kind::Internal(_) => {
            write!(w, "[")?;
            for (i, &k) in n.key_slice().iter().enumerate() {
                let space = if i == 0 { "" } else { " " };
                write!(w, "{space}{}.{}", node::user_key(k), node::tid_of(k).index())?;
            }
            write!(w, "]")
        }
        Kind::Leaf(leaf) => {
            if leaf.state == PageState::HalfDead {
                return write!(w, "(half-dead)");
            }
            write!(w, "(")?;
            for (i, &k) in n.key_slice().iter().enumerate() {
                let v = db.store.versions.get(node::tid_of(k));
                let space = if i == 0 { "" } else { " " };
                write!(w, "{space}{}:{}-", v.key, v.xmin)?;
                if v.xmax != 0 {
                    write!(w, "{}", v.xmax)?;
                }
                if leaf.dead[i] {
                    write!(w, "!")?;
                }
            }
            write!(w, ")")
        }
    }
}
