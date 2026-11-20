//! The fixed scenario printed by `cargo run` (and by `zig build run`, byte
//! for byte). The chapter README quotes this output and the visualization
//! replays parts 1 to 3 with a JavaScript model.

use crate::btree::BTree;
use crate::ops::{Config, Op, OpStream, Weights};
use std::error::Error;
use std::io::Write;

/// The guide's canonical insertion order (chapters 03 to 08), M = 4.
pub const CANONICAL_KEYS: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];
/// Part 2: one delete per case, on the canonical tree.
pub const CASE_DELETES: [u64; 10] = [3, 7, 6, 20, 10, 12, 15, 17, 30, 25];
/// Part 3: a three-level tree (keys 1..13 in ascending order), where an
/// underflow travels up through an interior node.
pub const TALL_COUNT: u64 = 13;
pub const TALL_DELETES: [u64; 6] = [9, 13, 10, 1, 2, 3];

pub fn run(w: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    writeln!(
        w,
        "== 1. Build the canonical tree (M = 4: 1 to 3 keys per node) =="
    )?;
    let mut tree = BTree::new(4);
    write!(w, "put")?;
    for key in CANONICAL_KEYS {
        tree.put(key, key * 10)?;
        write!(w, " {key}")?;
    }
    writeln!(w)?;
    tree.render(w, "  ")?;
    print_shape(w, &tree)?;

    writeln!(w, "\n== 2. Delete, one case at a time ==")?;
    for key in CASE_DELETES {
        delete_and_show(w, &mut tree, key)?;
    }

    writeln!(
        w,
        "\n== 3. An underflow that travels up (keys 1..13 inserted in order) =="
    )?;
    let mut tall = BTree::new(4);
    for key in 1..=TALL_COUNT {
        tall.put(key, key * 10)?;
    }
    tall.render(w, "  ")?;
    for key in TALL_DELETES {
        delete_and_show(w, &mut tall, key)?;
    }

    writeln!(
        w,
        "\n== 4. Random workload: 20000 operations on 500 possible keys (seed 5) =="
    )?;
    let mut big = BTree::new(4);
    let stream = OpStream::new(Config {
        seed: 5,
        count: 20_000,
        key_space: 500,
        weights: Weights::default(),
    });
    let mut checksum: u64 = 0; // folds every answer, so Zig and Rust must agree on all of them
    for op in stream {
        let answer = match op {
            Op::Put { key, value } => big.put(key, value)?.unwrap_or(1),
            Op::Delete { key } => big.delete(key).unwrap_or(2),
            Op::Get { key } => big.get(key).unwrap_or(3),
            Op::Range { lo, hi } => {
                let mut total: u64 = 0;
                big.range(lo, hi, |key, value| total = total.wrapping_add(key ^ value));
                total
            }
        };
        checksum = checksum.wrapping_add(answer);
    }
    big.validate().map_err(|e| format!("{e:?}"))?;
    writeln!(w, "answers checksum: {checksum:016x}")?;
    print_shape(w, &big)?;
    print_counters(w, &big)?;

    writeln!(
        w,
        "\n== 5. Delete every remaining key in ascending order =="
    )?;
    for key in 0..500 {
        big.delete(key);
    }
    big.validate().map_err(|e| format!("{e:?}"))?;
    big.render(w, "  ")?;
    print_shape(w, &big)?;
    print_counters(w, &big)?;
    let usage = big.pool.usage;
    writeln!(
        w,
        "node pool: created={} destroyed={} live={} peak={} reused={}",
        usage.created,
        usage.destroyed,
        usage.live(),
        usage.peak,
        // Every create beyond the peak was served from the free list.
        usage.created - usage.peak,
    )?;
    Ok(())
}

/// Delete one key and say which repairs it needed (from the counter deltas).
fn delete_and_show(w: &mut dyn Write, tree: &mut BTree, key: u64) -> Result<(), Box<dyn Error>> {
    let before = tree.counters;
    let removed = tree.delete(key);
    tree.validate().map_err(|e| format!("{e:?}"))?;
    let after = tree.counters;
    write!(w, "delete {key}:")?;
    if removed.is_none() {
        write!(w, " not found")?;
    }
    if after.predecessor_swaps > before.predecessor_swaps {
        write!(w, " interior key, replaced by its predecessor;")?;
    } else if removed.is_some() {
        write!(w, " leaf key;")?;
    }
    let parts = [
        // In the order they happen: merges first (each one passes the
        // underflow up a level), then at most one borrow, which ends it.
        (after.merges - before.merges, "merge"),
        (after.borrows_left - before.borrows_left, "borrow from left"),
        (
            after.borrows_right - before.borrows_right,
            "borrow from right",
        ),
        (after.root_shrinks - before.root_shrinks, "root shrink"),
    ];
    let mut repairs = 0;
    for (n, text) in parts {
        if n == 0 {
            continue;
        }
        write!(w, "{}", if repairs == 0 { " " } else { ", " })?;
        if n > 1 {
            write!(w, "{n} x ")?;
        }
        write!(w, "{text}")?;
        repairs += 1;
    }
    if repairs == 0 && removed.is_some() {
        write!(w, " no underflow")?;
    }
    writeln!(w)?;
    tree.render(w, "  ")?;
    Ok(())
}

fn print_shape(w: &mut dyn Write, tree: &BTree) -> std::io::Result<()> {
    let s = tree.shape();
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

fn print_counters(w: &mut dyn Write, tree: &BTree) -> std::io::Result<()> {
    let c = tree.counters;
    writeln!(
        w,
        "counters: splits={} root_splits={} predecessor_swaps={} borrows_left={} borrows_right={} merges={} root_shrinks={}",
        c.splits,
        c.root_splits,
        c.predecessor_swaps,
        c.borrows_left,
        c.borrows_right,
        c.merges,
        c.root_shrinks
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
