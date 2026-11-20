//! SECTION C: search, narrated.
//!
//! `explain_get` is `get` from base_search.rs with a print statement at
//! every decision. It returns what `get` returns (a test checks that), and
//! writes one line such as
//!
//! ```text
//! get 17: [6 10 20] child 2 -> [12 15 17] has it at index 2 -> value 170 (2 nodes read)
//! ```
//!
//! The number at the end is the cost that matters once nodes are disk pages
//! (chapter 01): one node per level, never more.

use crate::base_node::{NodeId, Nodes};
use crate::base_search::lower_bound;
use std::io::{self, Write};

pub fn explain_get<P: Nodes + ?Sized>(
    nodes: &P,
    root: Option<NodeId>,
    key: u64,
    w: &mut dyn Write,
) -> io::Result<Option<u64>> {
    write!(w, "get {key}: ")?;
    let Some(root) = root else {
        writeln!(w, "the tree is empty -> absent (0 nodes read)")?;
        return Ok(None);
    };
    let mut node = &nodes[root];
    let mut nodes_read = 1;
    loop {
        write_keys(&node.keys, w)?;
        // i = number of keys in this node that are smaller than `key`.
        let i = lower_bound(&node.keys, key);
        if i < node.len() && node.keys[i] == key {
            write!(w, " has it at index {i} -> value {}", node.values[i])?;
            write_cost(nodes_read, w)?;
            return Ok(Some(node.values[i]));
        }
        if node.leaf {
            write!(w, " is a leaf without it -> absent")?;
            write_cost(nodes_read, w)?;
            return Ok(None);
        }
        // i keys are smaller, so the key can only be in child i: every key
        // there lies between keys[i - 1] and keys[i].
        write!(w, " child {i} -> ")?;
        node = &nodes[node.children[i]];
        nodes_read += 1;
    }
}

fn write_keys(keys: &[u64], w: &mut dyn Write) -> io::Result<()> {
    let keys: Vec<String> = keys.iter().map(u64::to_string).collect();
    write!(w, "[{}]", keys.join(" "))
}

fn write_cost(nodes_read: usize, w: &mut dyn Write) -> io::Result<()> {
    let plural = if nodes_read == 1 { "" } else { "s" };
    writeln!(w, " ({nodes_read} node{plural} read)")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::{HandTree, canonical};

    #[test]
    fn explain_get_answers_like_get_and_reads_at_most_height_nodes() {
        let mut t = HandTree::new(4);
        canonical(&mut t).unwrap();
        for key in 0..40 {
            let mut out = Vec::new();
            let answer = explain_get(&t.arena, t.root, key, &mut out).unwrap();
            assert_eq!(answer, t.get(key));
        }
        let mut out = Vec::new();
        explain_get(&t.arena, t.root, 17, &mut out).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "get 17: [6 10 20] child 2 -> [12 15 17] has it at index 2 -> value 170 (2 nodes read)\n"
        );
        let mut out = Vec::new();
        assert_eq!(explain_get(&t.arena, None, 17, &mut out).unwrap(), None);
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "get 17: the tree is empty -> absent (0 nodes read)\n"
        );
    }
}
