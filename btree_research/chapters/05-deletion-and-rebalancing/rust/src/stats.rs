//! SECTION 6b of 6: shape statistics and a text rendering of the tree.

use crate::node::{NodeId, max_keys};
use crate::pool::Slab;
use std::io::{self, Write};

/// What the tree looks like right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Shape {
    /// Number of levels; 0 for an empty tree, 1 for a single leaf.
    pub height: usize,
    pub nodes: usize,
    pub leaves: usize,
    pub keys: usize,
    /// Key slots available in the existing nodes: nodes * (M - 1).
    pub capacity: usize,
}

impl Shape {
    /// Average node fill in whole percent (rounded down). A tree whose every
    /// non-root node is at the legal minimum is roughly 50% full; the ratio
    /// says how much of the allocated node space holds data.
    pub fn fill_percent(&self) -> usize {
        (self.keys * 100).checked_div(self.capacity).unwrap_or(0)
    }
}

pub fn shape(pool: &Slab, order: usize, root: Option<NodeId>) -> Shape {
    let mut s = Shape::default();
    let mut node = root;
    while let Some(id) = node {
        s.height += 1;
        node = pool[id].children.first().copied();
    }
    if let Some(root) = root {
        add_node(pool, order, root, &mut s);
    }
    s
}

fn add_node(pool: &Slab, order: usize, id: NodeId, s: &mut Shape) {
    let node = &pool[id];
    s.nodes += 1;
    s.keys += node.len();
    s.capacity += max_keys(order);
    if node.leaf {
        s.leaves += 1;
    }
    for &child in &node.children {
        add_node(pool, order, child, s);
    }
}

/// One line per level, root first. Nodes are `[k k k]`; ` | ` separates
/// nodes that have different parents:
///
/// ```text
/// [9]
/// [3 6] [12]
/// [1 2] [4 5] [7 8] | [10 11] [13]
/// ```
///
/// Every line starts with `indent`. An empty tree prints `(empty)`.
pub fn render(
    pool: &Slab,
    order: usize,
    root: Option<NodeId>,
    w: &mut dyn Write,
    indent: &str,
) -> io::Result<()> {
    let Some(root_id) = root else {
        return writeln!(w, "{indent}(empty)");
    };
    for level in 0..shape(pool, order, root).height {
        write!(w, "{indent}")?;
        let mut first = true;
        render_level(pool, root_id, level, w, &mut first)?;
        writeln!(w)?;
    }
    Ok(())
}

/// Print the nodes `remaining` levels below `id`, left to right.
fn render_level(
    pool: &Slab,
    id: NodeId,
    remaining: usize,
    w: &mut dyn Write,
    first: &mut bool,
) -> io::Result<()> {
    let node = &pool[id];
    if remaining == 0 {
        let keys: Vec<String> = node.keys.iter().map(u64::to_string).collect();
        return write!(w, "[{}]", keys.join(" "));
    }
    for (i, &child) in node.children.iter().enumerate() {
        if remaining == 1 {
            // Siblings are separated by a space, families by " | ".
            if i > 0 {
                write!(w, " ")?;
            } else if !*first {
                write!(w, " | ")?;
            }
            *first = false;
        }
        render_level(pool, child, remaining - 1, w, first)?;
    }
    Ok(())
}
