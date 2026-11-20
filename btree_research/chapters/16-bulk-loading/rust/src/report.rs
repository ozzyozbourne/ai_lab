//! The chapter's fixed scenario. `cargo run` prints it; the test at the
//! bottom checks it against ../expected_output.txt, and the Zig version
//! prints exactly the same bytes.

use std::fmt::Write;

use crate::bptree::{Entry, Error, Stats, Tree};
use crate::bulk::{Options, bulk_load};
use crate::prng::SplitMix64;

/// Print the nodes of one level, left to right. Leaves show their keys in
/// [ ], interior nodes show their separators (keys[1..]) in ( ).
fn write_level(out: &mut String, tree: &Tree, id: u32, depth: usize, wanted: usize) {
    let node = &tree.nodes[id as usize];
    if depth < wanted {
        for &child in &node.slots[..node.len] {
            write_level(out, tree, child as u32, depth + 1, wanted);
        }
        return;
    }
    let first = if node.is_leaf { 0 } else { 1 };
    let keys: Vec<String> = node.keys[first..node.len].iter().map(u64::to_string).collect();
    let (open, close) = if node.is_leaf { ('[', ']') } else { ('(', ')') };
    write!(out, " {open}{}{close}", keys.join(" ")).unwrap();
}

fn write_tree(out: &mut String, tree: &Tree) {
    for depth in 1..=tree.height {
        write!(out, "  level {}:", tree.height - depth).unwrap();
        write_level(out, tree, tree.root, 1, depth);
        out.push('\n');
    }
    let s = tree.shape();
    writeln!(out, "  pages {}, page writes {}, splits {}", s.pages(), tree.stats.page_writes, tree.stats.splits).unwrap();
}

/// Leaf fill in percent, rounded down: entries / (leaves * capacity).
fn leaf_fill(tree: &Tree) -> usize {
    let s = tree.shape();
    if s.leaves == 0 {
        return 0;
    }
    s.entries * 100 / (s.leaves * tree.leaf_cap())
}

fn write_row(out: &mut String, name: &str, tree: &Tree) {
    let s = tree.shape();
    writeln!(
        out,
        "{:<22}{:>7}{:>8}{:>7}{:>7}{:>10}%{:>13}{:>12}{:>8}",
        name,
        s.height,
        s.leaves,
        s.inner,
        s.pages(),
        leaf_fill(tree),
        tree.stats.page_writes,
        tree.stats.page_reads,
        tree.stats.splits
    )
    .unwrap();
}

fn insert_all(order: usize, entries: &[Entry]) -> Result<Tree, Error> {
    let mut tree = Tree::new(order);
    for e in entries {
        tree.put(e.key, e.value)?;
    }
    Ok(tree)
}

pub fn write(out: &mut String) -> Result<(), Error> {
    out.push_str("Chapter 16: bulk loading\n");

    // ---- 1. the hand example from the README ----
    out.push_str("\n== 1. Hand example: keys 1..13, order M = 4 ==\n");
    {
        let entries: Vec<Entry> = (1..=13).map(|k| Entry { key: k, value: k * 10 }).collect();

        out.push_str("bulk load, fill 100%:\n");
        let loaded = bulk_load(4, &entries, Options::default())?;
        assert_eq!(loaded.validate(), Ok(()));
        write_tree(out, &loaded);

        out.push_str("one-by-one insert, ascending:\n");
        let inserted = insert_all(4, &entries)?;
        assert_eq!(inserted.validate(), Ok(()));
        write_tree(out, &inserted);
    }

    // ---- 2. cost of building a larger tree four ways ----
    let n: u64 = 10_000;
    let order = 16;
    let entries: Vec<Entry> = (0..n).map(|i| Entry { key: i * 10, value: i }).collect();

    writeln!(out, "\n== 2. Building n = {n} keys, order M = {order} ==").unwrap();
    out.push_str("method                 height  leaves  inner  pages  leaf fill  page writes  page reads  splits\n");
    {
        let t = bulk_load(order, &entries, Options::default())?;
        assert_eq!(t.validate(), Ok(()));
        write_row(out, "bulk load 100%", &t);
    }
    {
        let t = bulk_load(order, &entries, Options { leaf_fill: 90, inner_fill: 70 })?;
        assert_eq!(t.validate(), Ok(()));
        write_row(out, "bulk load 90% / 70%", &t);
    }
    {
        let t = insert_all(order, &entries)?;
        assert_eq!(t.validate(), Ok(()));
        write_row(out, "insert, ascending", &t);
    }
    {
        // The same entries in a random order (Fisher-Yates over the indices).
        let mut perm: Vec<u64> = (0..n).collect();
        SplitMix64::new(16).shuffle(&mut perm);
        let mut t = Tree::new(order);
        for &i in &perm {
            t.put(entries[i as usize].key, entries[i as usize].value)?;
        }
        assert_eq!(t.validate(), Ok(()));
        write_row(out, "insert, shuffled", &t);
    }

    // ---- 3. what the fill factor buys once inserts start ----
    let extra: u64 = 1000;
    writeln!(out, "\n== 3. {extra} random inserts after the bulk load ==").unwrap();
    out.push_str("leaf / inner fill  pages before  splits  page writes  pages after\n");
    for (leaf_fill, inner_fill) in [(100u8, 100u8), (90, 70), (70, 70)] {
        let mut t = bulk_load(order, &entries, Options { leaf_fill, inner_fill })?;
        let before = t.shape().pages();
        t.stats = Stats::default(); // count only the inserts
        let mut rng = SplitMix64::new(1616);
        for i in 0..extra {
            // Loaded keys are multiples of 10; these never are. A key that
            // was already drawn is drawn again, so that every `put` is a
            // real insert and not an overwrite.
            let mut key = rng.below(n) * 10 + 1 + rng.below(9);
            while t.get(key).is_some() {
                key = rng.below(n) * 10 + 1 + rng.below(9);
            }
            t.put(key, i)?;
        }
        assert_eq!(t.validate(), Ok(()));
        assert_eq!(t.count as u64, n + extra);
        writeln!(
            out,
            "{:>4}% / {:>3}%     {:>12}{:>8}{:>13}{:>13}",
            leaf_fill,
            inner_fill,
            before,
            t.stats.splits,
            t.stats.page_writes,
            t.shape().pages()
        )
        .unwrap();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_report_matches_expected_output_txt() {
        let mut out = String::new();
        super::write(&mut out).unwrap();
        assert_eq!(out, include_str!("../../expected_output.txt"));
    }
}
