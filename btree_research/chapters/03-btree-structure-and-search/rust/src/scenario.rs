//! The fixed scenario printed by `cargo run` (and by `zig build run`, byte
//! for byte). The chapter README quotes this output and the visualization
//! checks its JavaScript model against it.

use crate::base_node::{NodeId, Nodes};
use crate::base_stats::Shape;
use crate::broken::{CASES, keys_found};
use crate::height;
use crate::prng::SplitMix64;
use crate::redblack::{RbTree, describe};
use crate::trace::explain_get;
use crate::tree::{HandTree, canonical, value_of};
use std::error::Error;
use std::io::Write;

/// Part 2: one lookup per interesting case.
pub const LOOKUPS: [u64; 5] = [10, 17, 1, 8, 31];
/// Part 7: the orders checked against the oracle.
pub const ORACLE_ORDERS: [usize; 4] = [3, 4, 5, 8];
pub const ORACLE_KEY_SPACE: u64 = 2000;
pub const ORACLE_SEED: u64 = 3;

type Outcome = Result<(), Box<dyn Error>>;

pub fn run(w: &mut dyn Write) -> Outcome {
    parts_one_to_three(w)?;
    broken_trees(w)?;
    heights(w)?;
    red_black(w)?;
    oracle_check(w)
}

fn parts_one_to_three(w: &mut dyn Write) -> Outcome {
    let mut t = HandTree::new(4);
    canonical(&mut t)?;

    writeln!(
        w,
        "== 1. The canonical tree, built by hand (M = 4: 1 to 3 keys per node) =="
    )?;
    t.render(w, "  ")?;
    print_shape(w, t.shape())?;
    t.validate().map_err(|e| format!("{e:?}"))?;
    writeln!(w, "validate: ok")?;
    // An arena has no way to free one node, so the second number is a constant.
    writeln!(
        w,
        "node storage: {} nodes created, 0 freed one by one, all released together",
        t.arena.len()
    )?;

    writeln!(w, "\n== 2. Search reads one node per level ==")?;
    for key in LOOKUPS {
        explain_get(&t.arena, t.root, key, w)?;
    }

    writeln!(
        w,
        "\n== 3. In-order traversal visits the keys in ascending order =="
    )?;
    let mut keys = Vec::new();
    t.in_order(|key, value| {
        assert_eq!(value, value_of(key));
        keys.push(key.to_string());
    });
    writeln!(w, "{}", keys.join(" "))?;
    Ok(())
    // `t` is dropped here: one deallocation of the Vec's buffer (plus each
    // node's own small Vecs; see README, "Allocator notes").
}

fn broken_trees(w: &mut dyn Write) -> Outcome {
    writeln!(
        w,
        "\n== 4. Break the canonical tree on purpose: one change, one broken invariant =="
    )?;
    for (number, case) in CASES.iter().enumerate() {
        // A fresh tree per case; the previous one is dropped as a whole.
        let mut t = HandTree::new(4);
        canonical(&mut t)?;
        (case.apply)(&mut t)?;
        writeln!(w, "{:>2}. {}", number + 1, case.what)?;
        match t.validate() {
            Ok(()) => write!(w, "    validate: ok")?,
            Err(violation) => write!(w, "    validate: {violation:?}")?,
        }
        if case.searchable {
            writeln!(w, "; get finds {} of 12 keys", keys_found(&t))?;
        } else {
            writeln!(w, "; get not tried (it could follow the erased pointer)")?;
        }
    }
    Ok(())
}

fn heights(w: &mut dyn Write) -> Outcome {
    writeln!(w, "\n== 5. Height: how few and how many keys fit ==")?;
    {
        let mut sparse = HandTree::new(4);
        let leaves = [
            sparse.leaf(&[1])?,
            sparse.leaf(&[3])?,
            sparse.leaf(&[5])?,
            sparse.leaf(&[7])?,
        ];
        let left = sparse.interior(&[2], &leaves[0..2])?;
        let right = sparse.interior(&[6], &leaves[2..4])?;
        sparse.root = Some(sparse.interior(&[4], &[left, right])?);
        sparse.validate().map_err(|e| format!("{e:?}"))?;
        writeln!(
            w,
            "sparsest tree with 3 levels at M = 4 ({} keys):",
            sparse.len
        )?;
        sparse.render(w, "  ")?;
    }
    {
        let mut full = HandTree::new(4);
        let leaves = [
            full.leaf(&[1, 2, 3])?,
            full.leaf(&[5, 6, 7])?,
            full.leaf(&[9, 10, 11])?,
            full.leaf(&[13, 14, 15])?,
        ];
        full.root = Some(full.interior(&[4, 8, 12], &leaves)?);
        full.validate().map_err(|e| format!("{e:?}"))?;
        writeln!(
            w,
            "fullest tree with 2 levels at M = 4 ({} keys):",
            full.len
        )?;
        full.render(w, "  ")?;
    }
    writeln!(
        w,
        "keys in a tree of h levels: 2*t^(h-1) - 1 up to M^h - 1, with t = ceil(M/2)"
    )?;
    for m in [4, 256] {
        write!(w, "  M={m}:")?;
        for h in 1..5 {
            let (min, max) = (height::min_keys(m, h), height::max_keys(m, h));
            write!(w, " h={h}: {min}..{max}")?;
        }
        writeln!(w)?;
    }
    writeln!(w, "possible heights for n keys (shortest..tallest):")?;
    for n in [12, 1000, 1_000_000, 1_000_000_000] {
        write!(w, "  n={n}:")?;
        for m in [4, 16, 256, 1024] {
            let (min, max) = (height::min_height(m, n), height::max_height(m, n));
            write!(w, " M={m}: {min}..{max}")?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn red_black(w: &mut dyn Write) -> Outcome {
    writeln!(w, "\n== 6. The 2-3-4 tree as a red-black tree ==")?;
    let mut t = HandTree::new(4);
    canonical(&mut t)?;
    if let Some(root) = t.root {
        describe_nodes(&t.arena, root, w)?;
    }
    let summary = RbTree::from_tree(&t.arena, t.root)
        .check()
        .map_err(|e| format!("{e:?}"))?;
    writeln!(
        w,
        "red-black tree: {} nodes, {} black nodes on every path (B-tree height {}), paths of {} to {} nodes",
        summary.nodes,
        summary.black_height,
        t.shape().height,
        summary.shortest_path,
        summary.longest_path
    )?;
    Ok(())
}

/// One line per 2-3-4 node, parents before children.
fn describe_nodes<P: Nodes + ?Sized>(nodes: &P, id: NodeId, w: &mut dyn Write) -> Outcome {
    let node = &nodes[id];
    let keys: Vec<String> = node.keys.iter().map(u64::to_string).collect();
    write!(w, "  [{}] -> ", keys.join(" "))?;
    describe(&node.keys, w)?;
    writeln!(w)?;
    for &child in &node.children {
        describe_nodes(nodes, child, w)?;
    }
    Ok(())
}

fn oracle_check(w: &mut dyn Write) -> Outcome {
    // The oracle: one bool per possible key. Slow and obviously correct.
    let mut prng = SplitMix64::new(ORACLE_SEED);
    let present: Vec<bool> = (0..ORACLE_KEY_SPACE).map(|_| prng.chance(3, 10)).collect();
    let sorted: Vec<u64> = (0..ORACLE_KEY_SPACE)
        .filter(|&key| present[key as usize])
        .collect();
    let n = sorted.len() as u64;
    writeln!(
        w,
        "\n== 7. Oracle check: {n} of the keys 0..{} (seed {ORACLE_SEED}), several orders ==",
        ORACLE_KEY_SPACE - 1
    )?;
    for order in ORACLE_ORDERS {
        let mut t = HandTree::new(order);
        t.from_sorted(&sorted)?;
        t.validate().map_err(|e| format!("{e:?}"))?;
        let agree = (0..ORACLE_KEY_SPACE)
            .filter(|&key| t.get(key) == present[key as usize].then(|| value_of(key)))
            .count();
        let s = t.shape();
        let m = order as u64;
        writeln!(
            w,
            "  M={order}: height={} (bounds {}..{}) nodes={} fill={}% validate ok, {agree} of {ORACLE_KEY_SPACE} lookups agree",
            s.height,
            height::min_height(m, n),
            height::max_height(m, n),
            s.nodes,
            s.fill_percent()
        )?;
    }
    Ok(())
}

fn print_shape(w: &mut dyn Write, s: Shape) -> std::io::Result<()> {
    writeln!(
        w,
        "shape: height={} nodes={} leaves={} keys={} fill={}%",
        s.height,
        s.nodes,
        s.leaves,
        s.keys,
        s.fill_percent()
    )
}

#[cfg(test)]
mod tests {
    #[test]
    fn run_prints_exactly_expected_output_txt() {
        let mut out = Vec::new();
        super::run(&mut out).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            include_str!("../../expected_output.txt")
        );
    }
}
