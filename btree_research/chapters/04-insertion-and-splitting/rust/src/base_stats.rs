// Copied from chapters/05-deletion-and-rebalancing/rust/src/stats.rs; fixes go there first
//! Shape statistics and a text rendering of the tree.
//! This file needs only base_node.rs.

use crate::base_node::{NodeId, Nodes, max_keys};
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

pub fn shape<P: Nodes + ?Sized>(nodes: &P, order: usize, root: Option<NodeId>) -> Shape {
    let mut s = Shape::default();
    let mut node = root;
    while let Some(id) = node {
        s.height += 1;
        node = nodes[id].children.first().copied();
    }
    if let Some(root) = root {
        add_node(nodes, order, root, &mut s);
    }
    s
}

fn add_node<P: Nodes + ?Sized>(nodes: &P, order: usize, id: NodeId, s: &mut Shape) {
    let node = &nodes[id];
    s.nodes += 1;
    s.keys += node.len();
    s.capacity += max_keys(order);
    if node.leaf {
        s.leaves += 1;
    }
    for &child in &node.children {
        add_node(nodes, order, child, s);
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
pub fn render<P: Nodes + ?Sized>(
    nodes: &P,
    order: usize,
    root: Option<NodeId>,
    w: &mut dyn Write,
    indent: &str,
) -> io::Result<()> {
    let Some(root_id) = root else {
        return writeln!(w, "{indent}(empty)");
    };
    for level in 0..shape(nodes, order, root).height {
        write!(w, "{indent}")?;
        let mut first = true;
        render_level(nodes, root_id, level, w, &mut first)?;
        writeln!(w)?;
    }
    Ok(())
}

/// Print the nodes `remaining` levels below `id`, left to right.
fn render_level<P: Nodes + ?Sized>(
    nodes: &P,
    id: NodeId,
    remaining: usize,
    w: &mut dyn Write,
    first: &mut bool,
) -> io::Result<()> {
    let node = &nodes[id];
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
        render_level(nodes, child, remaining - 1, w, first)?;
    }
    Ok(())
}
