//! The fixed scenario printed by `cargo run` (and by `zig build run`, byte
//! for byte). The chapter README quotes this output and the visualization
//! replays parts 1, 2 and rows of part 4 with a JavaScript model.

use crate::base_btree::{BTree, Counters};
use crate::measure::{self, KeyOrder, Measured, Variant};
use crate::topdown;
use std::error::Error;
use std::io::Write;

/// The guide's canonical insertion order (chapters 03 to 08), M = 4.
pub const CANONICAL_KEYS: [u64; 12] = [10, 20, 5, 6, 12, 30, 7, 17, 3, 25, 1, 15];
/// Part 3: keys 1..12 in ascending order, then 13.
pub const FAILURE_COUNT: u64 = 12;
/// Parts 4 and 5: this many distinct keys per measurement.
pub const MEASURE_COUNT: usize = 100_000;
pub const MEASURE_SEED: u64 = 4;
pub const BOTTOM_UP_ORDERS: [usize; 9] = [3, 4, 5, 8, 16, 32, 64, 128, 256];
pub const TOP_DOWN_ORDERS: [usize; 5] = [4, 8, 16, 64, 256];

pub fn run(w: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    writeln!(
        w,
        "== 1. Bottom-up insert: the canonical keys (M = 4: at most 3 keys per node) =="
    )?;
    let mut bottom = BTree::new(4);
    for key in CANONICAL_KEYS {
        let before = bottom.counters;
        bottom.put(key, key * 10)?;
        describe_put(w, key, before, bottom.counters, bottom.shape().height)?;
        bottom.render(w, "  ")?;
    }
    bottom.validate().map_err(|e| format!("{e:?}"))?;
    print_shape(w, &bottom)?;

    writeln!(
        w,
        "\n== 2. Top-down insert (textbook, CLRS): the same keys =="
    )?;
    let mut top = BTree::new(4);
    for key in CANONICAL_KEYS {
        let before = top.counters;
        topdown::put(&mut top, key, key * 10)?;
        describe_put(w, key, before, top.counters, top.shape().height)?;
    }
    top.validate().map_err(|e| format!("{e:?}"))?;
    top.render(w, "  ")?;
    print_shape(w, &top)?;
    let mut seen = 0;
    let mut ok = true;
    top.in_order(|key, value| {
        ok &= bottom.get(key) == Some(value);
        seen += 1;
    });
    let same = if ok && seen == bottom.len {
        "yes"
    } else {
        "NO"
    };
    writeln!(w, "same keys and values as the bottom-up tree: {same}")?;

    writeln!(
        w,
        "\n== 3. A put that runs out of memory (the third node allocation fails) =="
    )?;
    failure_demo(w)?;

    writeln!(
        w,
        "\n== 4. Fill and split cost, bottom-up: {MEASURE_COUNT} distinct keys per row (random: seed {MEASURE_SEED}) =="
    )?;
    print_table_header(w)?;
    for order_of_keys in [KeyOrder::Ascending, KeyOrder::Random] {
        let keys = measure::fill_keys(MEASURE_COUNT, order_of_keys, MEASURE_SEED);
        for order in BOTTOM_UP_ORDERS {
            let r = measure::build(order, Variant::BottomUp, &keys)?;
            print_row(w, order, order_of_keys.name(), "bottom-up", &r)?;
        }
    }
    writeln!(
        w,
        "references: all nodes at the minimum = about 50%; textbook (Yao 1978), random inserts, large M: ln 2 = 69.3%"
    )?;

    writeln!(
        w,
        "\n== 5. Top-down against bottom-up on the same keys (even M only) =="
    )?;
    print_table_header(w)?;
    for order_of_keys in [KeyOrder::Ascending, KeyOrder::Random] {
        let keys = measure::fill_keys(MEASURE_COUNT, order_of_keys, MEASURE_SEED);
        for order in TOP_DOWN_ORDERS {
            let r = measure::build(order, Variant::BottomUp, &keys)?;
            print_row(w, order, order_of_keys.name(), "bottom-up", &r)?;
            let r = measure::build(order, Variant::TopDown, &keys)?;
            print_row(w, order, order_of_keys.name(), "top-down", &r)?;
        }
    }
    Ok(())
}

/// One line per put: what it did to the structure (from the counter deltas).
fn describe_put(
    w: &mut dyn Write,
    key: u64,
    before: Counters,
    after: Counters,
    height: usize,
) -> std::io::Result<()> {
    let splits = after.splits - before.splits;
    write!(w, "put {key}:")?;
    if splits == 0 {
        return writeln!(w, " no split");
    }
    write!(w, " {splits} split{}", if splits == 1 { "" } else { "s" })?;
    if after.root_splits > before.root_splits {
        write!(w, ", the root split: height {height}")?;
    }
    writeln!(w)
}

fn failure_demo(w: &mut dyn Write) -> Result<(), Box<dyn Error>> {
    // `fail_after = Some(n)`: n more node allocations succeed, then every
    // allocation fails (Zig: `FailingAllocator.fail_index`).
    let mut bottom = BTree::new(4);
    let mut top = BTree::new(4);
    // Both trees are built the same way, so they start out identical.
    for key in 1..=FAILURE_COUNT {
        bottom.put(key, key)?;
        top.put(key, key)?;
    }
    writeln!(w, "both trees before:")?;
    bottom.render(w, "  ")?;

    // Key 13 goes into the full leaf [10 11 12] under the full root: the
    // put needs three nodes (leaf half, root half, new root).
    bottom.pool.fail_after = Some(2);
    let bottom_before = bottom.counters;
    if bottom.put(13, 13).is_ok() {
        return Err("expected OutOfNodes".into());
    }
    bottom.validate().map_err(|e| format!("{e:?}"))?;
    writeln!(
        w,
        "bottom-up put 13: OutOfMemory; splits done: {}; keys: {}; tree unchanged:",
        bottom.counters.splits - bottom_before.splits,
        bottom.len
    )?;
    bottom.render(w, "  ")?;

    top.pool.fail_after = Some(2);
    let top_before = top.counters;
    if topdown::put(&mut top, 13, 13).is_ok() {
        return Err("expected OutOfNodes".into());
    }
    top.validate().map_err(|e| format!("{e:?}"))?;
    writeln!(
        w,
        "top-down put 13: OutOfMemory; splits done: {}; keys: {}; valid tree, same keys, new shape:",
        top.counters.splits - top_before.splits,
        top.len
    )?;
    top.render(w, "  ")?;

    bottom.pool.fail_after = None; // memory is back
    top.pool.fail_after = None;
    bottom.put(13, 13)?;
    topdown::put(&mut top, 13, 13)?;
    bottom.validate().map_err(|e| format!("{e:?}"))?;
    top.validate().map_err(|e| format!("{e:?}"))?;
    writeln!(w, "with memory again, bottom-up put 13:")?;
    bottom.render(w, "  ")?;
    writeln!(w, "with memory again, top-down put 13:")?;
    top.render(w, "  ")?;
    Ok(())
}

fn print_shape(w: &mut dyn Write, tree: &BTree) -> std::io::Result<()> {
    let s = tree.shape();
    writeln!(
        w,
        "shape: height={} nodes={} leaves={} keys={} fill={}% splits={} root_splits={}",
        s.height,
        s.nodes,
        s.leaves,
        s.keys,
        s.fill_percent(),
        tree.counters.splits,
        tree.counters.root_splits
    )
}

fn print_table_header(w: &mut dyn Write) -> std::io::Result<()> {
    writeln!(
        w,
        "   M  keys       variant    height   nodes    fill  splits  per 1000 puts  most in one put"
    )
}

fn print_row(
    w: &mut dyn Write,
    order: usize,
    keys: &str,
    variant: &str,
    r: &Measured,
) -> std::io::Result<()> {
    let fill = r.fill_permille();
    let rate = r.splits_per_1000_tenths();
    writeln!(
        w,
        "{:>4}  {:<9}  {:<9}  {:>6}  {:>6}  {:>3}.{}%  {:>6}  {:>11}.{}  {:>15}",
        order,
        keys,
        variant,
        r.shape.height,
        r.shape.nodes,
        fill / 10,
        fill % 10,
        r.splits,
        rate / 10,
        rate % 10,
        r.most_splits_in_one_put
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
