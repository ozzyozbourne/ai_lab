//! Demo program of chapter 07. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Zig program's.

use std::io::{self, Write};

use ch07_bplus_trees::ops::{Config, Op, OpStream, Oracle, Weights};
use ch07_bplus_trees::{BPlusTree, LeafWalker, NodeId, Stats, dump};

/// Canonical hand example of chapters 03 to 08.
const CANONICAL: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    run(&mut out)?;
    out.flush()
}

/// No node budget is set in this program, so `put` cannot fail.
const NO_BUDGET: &str = "no node budget set";

fn run(w: &mut dyn Write) -> io::Result<()> {
    let mut tree = BPlusTree::new(4);

    writeln!(
        w,
        "== 1. Build: canonical keys, order M = 4 (at most 3 keys per node) =="
    )?;
    for key in CANONICAL {
        let before = snapshot(&tree);
        tree.put(key, key * 100).expect(NO_BUDGET);
        write!(w, "put {key}:")?;
        report_change(w, before, &tree)?;
    }
    tree.validate().expect("valid tree");

    writeln!(w, "\n== 2. The leaf chain ==")?;
    write!(w, "forward  (next links):")?;
    for e in LeafWalker::first(&tree) {
        write!(w, " {}", e.key)?;
    }
    write!(w, "\nbackward (prev links), leaf handles:")?;
    dump::dump_chain_backward(&tree, w)?;
    write!(w, "\nseparators:")?;
    print_separators(w, &tree)?;

    writeln!(w, "\n== 3. Lookups always end in a leaf ==")?;
    for key in [15, 12, 13] {
        writeln!(w, "get {key} = {}", optional(tree.get(key)))?;
    }

    writeln!(
        w,
        "\n== 4. Delete: stale separator, borrow, merge, shrink =="
    )?;
    for key in [15, 17, 20, 25, 30, 12] {
        let before = snapshot(&tree);
        tree.delete(key);
        write!(w, "delete {key}:")?;
        report_change(w, before, &tree)?;
        if key == 15 {
            write!(w, "  get 15 = {}, but separators:", optional(tree.get(15)))?;
            print_separators(w, &tree)?;
        }
    }
    tree.validate().expect("valid tree");

    writeln!(w, "\n== 5. Handles: freed slots are reused ==")?;
    print_arena(w, &tree)?;
    for key in [11, 13, 14] {
        let before = snapshot(&tree);
        tree.put(key, key * 100).expect(NO_BUDGET);
        write!(w, "put {key}:")?;
        report_change(w, before, &tree)?;
    }
    print_arena(w, &tree)?;
    tree.validate().expect("valid tree");

    duplicates_demo(w)?;
    model_run(w)
}

/// Zig prints an optional integer with `{?d}`: the number, or `null`.
fn optional(value: Option<u64>) -> String {
    value.map_or("null".to_string(), |v| v.to_string())
}

struct Snapshot {
    stats: Stats,
    height: usize,
}

fn snapshot(tree: &BPlusTree) -> Snapshot {
    Snapshot {
        stats: tree.stats,
        height: tree.height,
    }
}

/// Says what the last operation did to the structure, and prints the tree
/// whenever a node was created, freed or rebalanced.
fn report_change(w: &mut dyn Write, before: Snapshot, tree: &BPlusTree) -> io::Result<()> {
    let s = tree.stats;
    let old = before.stats;
    let mut events = 0;
    if before.height == 0 && tree.height == 1 {
        event(w, &mut events, "first leaf", 1)?;
    }
    event(
        w,
        &mut events,
        "leaf split (copy-up)",
        s.leaf_splits - old.leaf_splits,
    )?;
    event(
        w,
        &mut events,
        "internal split (push-up)",
        s.internal_splits - old.internal_splits,
    )?;
    // Within one delete, merges happen below the borrow that ends the repair.
    event(w, &mut events, "merge", s.merges - old.merges)?;
    event(w, &mut events, "borrow", s.borrows - old.borrows)?;
    if before.height != 0 && tree.height > before.height {
        event(w, &mut events, "new root", 1)?;
    }
    if tree.height < before.height {
        event(w, &mut events, "root removed", 1)?;
    }
    if events == 0 {
        return writeln!(w, " no structural change");
    }
    write!(w, "\n  ")?;
    dump::dump(tree, w)
}

fn event(w: &mut dyn Write, events: &mut usize, name: &str, times: usize) -> io::Result<()> {
    if times == 0 {
        return Ok(());
    }
    write!(w, "{}{name}", if *events == 0 { " " } else { ", " })?;
    if times > 1 {
        write!(w, " x{times}")?;
    }
    *events += 1;
    Ok(())
}

/// Lists every separator of every internal node and marks the ones that no
/// longer exist as a key in any leaf.
fn print_separators(w: &mut dyn Write, tree: &BPlusTree) -> io::Result<()> {
    if tree.height < 2 {
        return writeln!(w, " none");
    }
    print_separators_of(w, tree, tree.root)?;
    writeln!(w)
}

fn print_separators_of(w: &mut dyn Write, tree: &BPlusTree, id: NodeId) -> io::Result<()> {
    let n = tree.nodes.get(id);
    if n.is_leaf() {
        return Ok(());
    }
    for (i, &child) in n.child_slice().iter().enumerate() {
        print_separators_of(w, tree, child)?;
        if i < n.len {
            let stale = tree.get(n.keys[i]).is_none();
            write!(w, " {}{}", n.keys[i], if stale { "(stale)" } else { "" })?;
        }
    }
    Ok(())
}

fn print_arena(w: &mut dyn Write, tree: &BPlusTree) -> io::Result<()> {
    let free_list = tree.nodes.free_list().expect("intact free list");
    write!(
        w,
        "arena: {} slots, {} live, {} free; free list:",
        tree.nodes.slot_count(),
        tree.nodes.live_count(),
        free_list.len()
    )?;
    for id in free_list {
        write!(w, " #{}", id.index())?;
    }
    writeln!(w)
}

/// Duplicate user keys through a tie-breaker: the tree key is
/// (user key, row id) packed into one u64, so every tree key is unique and
/// all rows of one user key are adjacent in the leaf chain.
fn duplicates_demo(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 6. Duplicates through a tie-breaker: key = (user key, row id) =="
    )?;
    let mut tree = BPlusTree::new(4);
    let rows = [(7, 1), (3, 2), (7, 3), (9, 4), (7, 5), (3, 6), (7, 7)];
    for (user_key, row_id) in rows {
        let old = tree
            .put(composite(user_key, row_id), row_id)
            .expect(NO_BUDGET);
        assert!(old.is_none()); // never an overwrite: the row id makes it unique
    }
    tree.validate().expect("valid tree");
    write!(w, "leaf order (user key, row id):")?;
    for e in LeafWalker::first(&tree) {
        write!(w, " ({},{})", e.key >> 32, e.key & 0xFFFF_FFFF)?;
    }
    writeln!(w)?;
    for user_key in [7, 3, 8] {
        write!(w, "row ids with user key {user_key}:")?;
        // Seek to (user_key, 0) and walk while the user key still matches.
        for e in LeafWalker::seek(&tree, composite(user_key, 0)) {
            if e.key >> 32 != user_key {
                break;
            }
            write!(w, " {}", e.key & 0xFFFF_FFFF)?;
        }
        writeln!(w)?;
    }
    Ok(())
}

fn composite(user_key: u64, row_id: u64) -> u64 {
    (user_key << 32) | row_id
}

/// A seeded random workload against the reference oracle; prints only counts.
fn model_run(w: &mut dyn Write) -> io::Result<()> {
    writeln!(
        w,
        "\n== 7. Model run: 20000 random operations against a sorted-array oracle =="
    )?;
    for order in [3, 4, 16] {
        let mut tree = BPlusTree::new(order);
        let mut oracle = Oracle::new();
        let config = Config {
            seed: 7,
            count: 20_000,
            key_space: 500,
            weights: Weights::default(),
        };
        let mut mismatches = 0;
        for op in OpStream::new(config) {
            match op {
                Op::Put { key, value } => {
                    if tree.put(key, value).expect(NO_BUDGET) != oracle.put(key, value) {
                        mismatches += 1;
                    }
                }
                Op::Delete { key } => {
                    if tree.delete(key) != oracle.delete(key) {
                        mismatches += 1;
                    }
                }
                Op::Get { key } => {
                    if tree.get(key) != oracle.get(key) {
                        mismatches += 1;
                    }
                }
                Op::Range { lo, hi } => {
                    let mut walker = LeafWalker::seek(&tree, lo);
                    for expected in oracle.range(lo, hi) {
                        let got = walker.next();
                        if got.is_none_or(|g| g.key != expected.key || g.value != expected.value) {
                            mismatches += 1;
                        }
                    }
                    if walker.next().is_some_and(|after| after.key < hi) {
                        mismatches += 1;
                    }
                }
            }
        }
        tree.validate().expect("valid tree");
        let s = tree.stats;
        writeln!(
            w,
            "M={order:<2} keys={} height={} nodes={} slots={} | leaf splits={} internal splits={} borrows={} merges={} | mismatches={mismatches}",
            tree.len(),
            tree.height,
            tree.nodes.live_count(),
            tree.nodes.slot_count(),
            s.leaf_splits,
            s.internal_splits,
            s.borrows,
            s.merges,
        )?;
    }
    Ok(())
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
