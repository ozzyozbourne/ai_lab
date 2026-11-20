//! Demo program of chapter 27. Its stdout is exactly ../expected_output.txt
//! (checked by the test at the bottom) and is identical to the Zig program's.

use std::fmt::Write as _;
use std::io::{self, Write};

use ch27_btree_vs_lsm::bench::{self, Workload};
use ch27_btree_vs_lsm::device::Kind;
use ch27_btree_vs_lsm::run::Run;
use ch27_btree_vs_lsm::{BPlusTree, Lsm, NodeId, lsm};

fn main() -> io::Result<()> {
    let mut out = io::BufWriter::new(io::stdout().lock());
    run(&mut out)?;
    out.flush()
}

fn run(w: &mut dyn Write) -> io::Result<()> {
    trace(w)?;
    for (i, wl) in bench::WORKLOADS.iter().enumerate() {
        compare(w, wl, i + 3)?;
    }
    growth_sweep(w)
}

// ------------------------------------------------------------ 1. trace

#[derive(Clone, Copy)]
enum TraceOp {
    Put(u64, u64),
    Delete(u64),
    Get(u64),
    Scan(u64, u64),
}
use TraceOp::{Delete, Get, Put, Scan};

/// The canonical keys of chapters 03 to 08, then lookups, a delete, an
/// overwrite and more inserts: enough to see a flush, a compaction, a
/// tombstone and a stale version.
const TRACE_OPS: [TraceOp; 23] = [
    Put(10, 1000),
    Put(20, 2000),
    Put(5, 500),
    Put(6, 600),
    Put(12, 1200),
    Put(30, 3000),
    Put(7, 700),
    Put(17, 1700),
    Put(3, 300),
    Put(25, 2500),
    Put(1, 100),
    Put(15, 1500),
    Get(15),
    Get(12),
    Get(13),
    Delete(15),
    Put(20, 2001),
    Put(11, 1100),
    Put(13, 1300),
    Put(14, 1400),
    Get(15),
    Get(20),
    Scan(5, 14),
];

const TRACE_ORDER: usize = 4;
const TRACE_LSM: lsm::Config = lsm::Config {
    block_entries: TRACE_ORDER - 1,
    index_fanout: TRACE_ORDER,
    memtable_entries: 4,
    l0_runs: 2,
    growth: 2,
};

/// No budgets are set in this program, so writes cannot fail.
const NO_BUDGET: &str = "no budget set";

fn trace(w: &mut dyn Write) -> io::Result<()> {
    let mut tree = BPlusTree::new(TRACE_ORDER);
    let mut lsm = Lsm::new(TRACE_LSM);
    let mut tree_out = Vec::new();
    let mut lsm_out = Vec::new();

    writeln!(w, "== 1. One trace, two structures ==")?;
    writeln!(w, "B+tree: order M = 4, so 3 entries per leaf block.")?;
    writeln!(w, "LSM: 3 slots per data block, memtable of 4 keys, level 0 holds 2 runs, growth 2.")?;
    writeln!(w, "r = blocks read, w = blocks written by that one operation.\n")?;

    for op in TRACE_OPS {
        let t0 = tree.dev.counters;
        let l0 = lsm.dev.counters;
        let ts = tree.stats;
        let th = tree.height;
        let ls = lsm.stats;
        let mut answer = String::new();
        let name = match op {
            Put(key, value) => {
                tree.put(key, value).expect(NO_BUDGET);
                lsm.put(key, value).expect(NO_BUDGET);
                format!("put {key}")
            }
            Delete(key) => {
                tree.delete(key);
                lsm.delete(key).expect(NO_BUDGET);
                format!("delete {key}")
            }
            Get(key) => {
                let a = tree.get(key);
                assert_eq!(a, lsm.get(key));
                match a {
                    Some(v) => write!(answer, " = {v}").unwrap(),
                    None => answer.push_str(" = none"),
                }
                format!("get {key}")
            }
            Scan(lo, hi) => {
                tree_out.clear();
                lsm_out.clear();
                tree.range(lo, hi, &mut tree_out);
                lsm.range(lo, hi, &mut lsm_out);
                assert_eq!(tree_out, lsm_out);
                answer.push_str(" =");
                for e in &tree_out {
                    write!(answer, " {}", e.key).unwrap();
                }
                format!("scan [{lo},{hi})")
            }
        };
        let t = tree.dev.counters.since(&t0);
        let l = lsm.dev.counters.since(&l0);
        write!(
            w,
            "{name:<12}| btree r={} w={} | lsm r={:>2} w={:>2} |{answer}",
            t.total_reads(),
            t.total_writes(),
            l.total_reads(),
            l.total_writes(),
        )?;
        // What the counters mean, from the structures' own statistics.
        let notes = [
            (tree.stats.leaf_splits > ts.leaf_splits, " btree: leaf split."),
            (tree.stats.internal_splits > ts.internal_splits, " btree: internal split."),
            (tree.height > th && th > 0, " btree: new root."),
            (tree.stats.borrows > ts.borrows, " btree: borrow."),
            (tree.stats.merges > ts.merges, " btree: merge."),
            (lsm.stats.flushes > ls.flushes, " lsm: flush."),
            (lsm.stats.l0_compactions > ls.l0_compactions, " lsm: compact level 0 into level 1."),
            (lsm.stats.level_merges > ls.level_merges, " lsm: merge a level down."),
        ];
        for (happened, note) in notes {
            if happened {
                w.write_all(note.as_bytes())?;
            }
        }
        writeln!(w)?;
    }
    tree.validate().expect("valid tree");
    lsm.validate().expect("valid lsm");

    writeln!(w, "\n== 2. Where the data ended up ==")?;
    writeln!(w, "B+tree: height {}, {} blocks", tree.height, tree.dev.live)?;
    dump_tree(w, &tree)?;
    writeln!(
        w,
        "LSM: {} blocks on the device holding {} slots, {} key(s) in the memtable",
        lsm.dev.live,
        lsm.slots_on_device(),
        lsm.mem.count()
    )?;
    dump_lsm(w, &lsm)?;
    let (tc, lc) = (tree.dev.counters, lsm.dev.counters);
    writeln!(
        w,
        "totals: btree reads={} writes={} | lsm reads={} writes={}",
        tc.total_reads(),
        tc.total_writes(),
        lc.total_reads(),
        lc.total_writes()
    )?;
    writeln!(
        w,
        "lsm compaction dropped {} stale version(s) and {} tombstone(s)",
        lsm.stats.versions_dropped, lsm.stats.tombstones_dropped
    )
}

/// One line per level: internal nodes as [separators], leaves as (keys).
fn dump_tree(w: &mut dyn Write, tree: &BPlusTree) -> io::Result<()> {
    for depth in 1..=tree.height {
        write!(w, "  level {depth}:")?;
        dump_depth(w, tree, tree.root, depth)?;
        writeln!(w)?;
    }
    Ok(())
}

fn dump_depth(w: &mut dyn Write, tree: &BPlusTree, id: NodeId, depth: usize) -> io::Result<()> {
    let n = tree.nodes.get(id);
    if depth > 1 {
        for &child in n.child_slice() {
            dump_depth(w, tree, child, depth - 1)?;
        }
        return Ok(());
    }
    let keys: Vec<String> = n.key_slice().iter().map(u64::to_string).collect();
    if n.is_leaf() { write!(w, " ({})", keys.join(" ")) } else { write!(w, " [{}]", keys.join(" ")) }
}

fn dump_lsm(w: &mut dyn Write, lsm: &Lsm) -> io::Result<()> {
    write!(w, "  memtable:")?;
    for slot in lsm.mem.iter_from(lsm.mem.first()) {
        write!(w, " {}{}", if slot.value.is_none() { "~" } else { "" }, slot.key)?;
    }
    write!(w, "\n  level 0 (oldest first):")?;
    for run in &lsm.l0 {
        dump_run(w, run)?;
    }
    if lsm.l0.is_empty() {
        write!(w, " -")?;
    }
    writeln!(w)?;
    for i in 0..lsm.deepest_level() {
        write!(w, "  level {}:", i + 1)?;
        match &lsm.levels[i] {
            Some(run) => dump_run(w, run)?,
            None => write!(w, " -")?,
        }
        writeln!(w)?;
    }
    Ok(())
}

fn dump_run(w: &mut dyn Write, run: &Run) -> io::Result<()> {
    let slots: Vec<String> = run
        .slots
        .iter()
        .map(|s| format!("{}{}", if s.value.is_none() { "~" } else { "" }, s.key))
        .collect();
    write!(w, " ({})", slots.join(" "))
}

// ------------------------------------------------- 3 to 5. workloads

/// `num / den` with two decimals, by integer arithmetic only (truncated),
/// so that Zig and Rust print the same digits. "-" when there is no data.
fn ratio(num: u64, den: u64) -> String {
    if den == 0 {
        return "-".to_string();
    }
    let hundredths = num * 100 / den;
    format!("{}.{:02}", hundredths / 100, hundredths % 100)
}

fn row_count(w: &mut dyn Write, label: &str, a: u64, b: u64) -> io::Result<()> {
    writeln!(w, "{label:<42}{a:>10}{b:>10}")
}

fn row_ratio(w: &mut dyn Write, label: &str, a: (u64, u64), b: (u64, u64)) -> io::Result<()> {
    writeln!(w, "{label:<42}{:>10}{:>10}", ratio(a.0, a.1), ratio(b.0, b.1))
}

fn compare(w: &mut dyn Write, wl: &Workload, section: usize) -> io::Result<()> {
    let cfg = bench::BENCH_LSM;
    let r = bench::run_workload(wl, bench::BENCH_ORDER, cfg);
    let (b, l) = (&r.btree, &r.lsm);
    let index = Kind::Index as usize;
    let per_block = cfg.block_entries as u64;

    writeln!(w, "\n== {section}. Workload: {} ==", wl.name)?;
    writeln!(
        w,
        "seed {}, preload {} puts, then {} operations over {} keys; put/delete/get/scan = {}/{}/{}/{}",
        wl.seed,
        wl.preload,
        wl.count,
        wl.key_space,
        wl.weights.put,
        wl.weights.delete,
        wl.weights.get,
        wl.weights.range
    )?;
    writeln!(
        w,
        "live keys at the end: {}; answers that differ from the oracle: {}\n",
        r.live_keys, r.mismatches
    )?;

    writeln!(w, "{:<42}{:>10}{:>10}", "", "B+tree", "LSM")?;
    let (bw, lw) = (b.writes.io.total_writes(), l.writes.io.total_writes());
    row_count(w, "write operations (put + delete)", b.writes.ops, l.writes.ops)?;
    row_count(w, "  blocks written", bw, lw)?;
    row_ratio(w, "  blocks written per write", (bw, b.writes.ops), (lw, l.writes.ops))?;
    row_ratio(
        w,
        "  WRITE AMPLIFICATION (slots per entry)",
        (bw * per_block, b.writes.ops),
        (lw * per_block, l.writes.ops),
    )?;
    row_ratio(
        w,
        "  blocks read per write",
        (b.writes.io.total_reads(), b.writes.ops),
        (l.writes.io.total_reads(), l.writes.ops),
    )?;
    row_count(w, "  most blocks written by one write", b.writes.max_writes, l.writes.max_writes)?;
    row_count(w, "point lookups (get)", b.gets.ops, l.gets.ops)?;
    row_ratio(
        w,
        "  READ AMPLIFICATION (blocks per get)",
        (b.gets.io.total_reads(), b.gets.ops),
        (l.gets.io.total_reads(), l.gets.ops),
    )?;
    row_ratio(
        w,
        "    of which index blocks",
        (b.gets.io.reads[index], b.gets.ops),
        (l.gets.io.reads[index], l.gets.ops),
    )?;
    row_count(w, "short scans", b.scans.ops, l.scans.ops)?;
    row_ratio(
        w,
        "  entries returned per scan",
        (b.scans.entries, b.scans.ops),
        (l.scans.entries, l.scans.ops),
    )?;
    row_ratio(
        w,
        "  blocks read per scan",
        (b.scans.io.total_reads(), b.scans.ops),
        (l.scans.io.total_reads(), l.scans.ops),
    )?;
    let packed_blocks = (r.live_keys as u64).div_ceil(per_block);
    row_count(w, "blocks on the device at the end", b.blocks, l.blocks)?;
    row_count(w, "  blocks if every live key were packed", packed_blocks, packed_blocks)?;
    row_ratio(w, "  SPACE AMPLIFICATION (at the end)", (b.blocks, packed_blocks), (l.blocks, packed_blocks))?;
    row_count(w, "  most blocks at any moment", b.peak, l.peak)?;
    row_ratio(w, "  space amplification (at the peak)", (b.peak, packed_blocks), (l.peak, packed_blocks))?;

    let s = r.lsm_stats;
    writeln!(
        w,
        "B+tree: height {}. LSM: {} level(s) below level 0, {} run(s) in level 0, {} slots on the device.",
        r.btree_height, r.lsm_levels, r.lsm_l0_runs, r.lsm_slots
    )?;
    writeln!(
        w,
        "LSM maintenance: {} flushes, {} level-0 compactions, {} level merges; dropped {} stale versions, {} tombstones.",
        s.flushes, s.l0_compactions, s.level_merges, s.versions_dropped, s.tombstones_dropped
    )?;
    writeln!(
        w,
        "LSM lookups: {} runs probed, {} of those without finding the key, {} runs skipped by min/max.",
        s.runs_probed, s.probes_wasted, s.runs_skipped
    )
}

fn growth_sweep(w: &mut dyn Write) -> io::Result<()> {
    writeln!(w, "\n== 6. The growth factor is the tuning knob ==")?;
    writeln!(w, "LSM only, insert-heavy workload again, everything else unchanged.\n")?;
    writeln!(
        w,
        "{:<8}{:>8}{:>16}{:>16}{:>16}{:>14}",
        "growth", "levels", "write amp", "blocks per get", "blocks per scan", "peak blocks"
    )?;
    for growth in [2, 4, 8, 16] {
        let cfg = lsm::Config { growth, ..bench::BENCH_LSM };
        let r = bench::run_workload(&bench::WORKLOADS[0], bench::BENCH_ORDER, cfg);
        let l = &r.lsm;
        writeln!(
            w,
            "{:<8}{:>8}{:>16}{:>16}{:>16}{:>14}",
            growth,
            r.lsm_levels,
            ratio(l.writes.io.total_writes() * cfg.block_entries as u64, l.writes.ops),
            ratio(l.gets.io.total_reads(), l.gets.ops),
            ratio(l.scans.io.total_reads(), l.scans.ops),
            l.peak
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
        assert_eq!(String::from_utf8(out).unwrap(), include_str!("../../expected_output.txt"));
    }
}
