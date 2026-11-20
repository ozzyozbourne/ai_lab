//! Chapter 29: zone maps and vector indexes.
//!
//! Library root. `run_scenario` builds the chapter's fixed scenario as a
//! string; main.rs prints it and a test below compares it with
//! expected_output.txt.
use std::fmt::Write;

pub mod ivf;
pub mod prng;
pub mod zonemap;
pub mod zorder;

use ivf::{Hit, Ivf};
use prng::SplitMix64;
use zonemap::{Filter, Op, OutOfRows, ZoneMap};

// ---- scenario parameters (the visualization pages use the same numbers) ----
pub const ZONE_ROWS: u64 = 2000;
pub const ZONE_CHUNK: u32 = 100;
pub const ZONE_SEED: u64 = 29;
pub const GRID_SIDE: u32 = 16;
pub const BLOB_SEED: u64 = 2901;
pub const TRAIN_SEED: u64 = 2902;
pub const QUERY_SEED: u64 = 2903;
pub const WIDE_SEED: u64 = 2904;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Layout {
    Sorted,
    Arrival,
    Shuffled,
}

impl Layout {
    pub const ALL: [Layout; 3] = [Layout::Sorted, Layout::Arrival, Layout::Shuffled];

    pub fn name(self) -> &'static str {
        match self {
            Layout::Sorted => "sorted",
            Layout::Arrival => "arrival",
            Layout::Shuffled => "shuffled",
        }
    }
}

/// The same 2000 rows' worth of values in three physical orders.
///   sorted:   v = row number (a column the table is clustered on)
///   arrival:  v = row number + a delay of 0..299 (timestamps that arrive
///             roughly, not exactly, in order)
///   shuffled: 0..1999 in random order (no correlation with position)
pub fn fill_layout(zm: &mut ZoneMap, layout: Layout) -> Result<(), OutOfRows> {
    let mut rng = SplitMix64::new(ZONE_SEED);
    match layout {
        Layout::Sorted => (0..ZONE_ROWS).try_for_each(|i| zm.append(i)),
        Layout::Arrival => (0..ZONE_ROWS).try_for_each(|i| zm.append(i + rng.below(300))),
        Layout::Shuffled => {
            let mut vs: Vec<u64> = (0..ZONE_ROWS).collect();
            rng.shuffle(&mut vs);
            zm.append_slice(&vs)
        }
    }
}

pub const ZONE_FILTERS: [(&str, Filter); 5] = [
    ("v = 777", Filter::Cmp { op: Op::Eq, c: 777 }),
    (
        "v >= 1500",
        Filter::Cmp {
            op: Op::Ge,
            c: 1500,
        },
    ),
    ("v < 250", Filter::Cmp { op: Op::Lt, c: 250 }),
    ("400 <= v <= 449", Filter::Between { lo: 400, hi: 449 }),
    ("v != 777", Filter::Cmp { op: Op::Ne, c: 777 }),
];

/// n points in 2-D, drawn around `blobs` random centres. Each coordinate is
/// centre + (sum of two uniform draws) - spread, clamped to 0..999, which
/// gives a soft triangular bump without any floating point.
pub fn gen_blobs(seed: u64, n: usize, blobs: usize, spread: u64) -> Vec<i32> {
    let mut rng = SplitMix64::new(seed);
    let centres: Vec<i32> = (0..blobs * 2).map(|_| rng.range(150, 850) as i32).collect();
    let mut data = Vec::with_capacity(n * 2);
    for i in 0..n {
        for j in 0..2 {
            let offset = (rng.below(spread + 1) + rng.below(spread + 1)) as i32;
            let v = centres[(i % blobs) * 2 + j] + offset - spread as i32;
            data.push(v.clamp(0, 999));
        }
    }
    data
}

/// Queries that look like the data: a random stored 2-D point moved by up to
/// `jitter` in each coordinate. (Queries far from all data are easy for IVF:
/// the interesting ones fall near a cell boundary.)
pub fn gen_near_data(seed: u64, data: &[i32], nq: usize, jitter: u64) -> Vec<i32> {
    let mut rng = SplitMix64::new(seed);
    let mut queries = Vec::with_capacity(nq * 2);
    for _ in 0..nq {
        let src = rng.below(data.len() as u64 / 2) as usize;
        for j in 0..2 {
            let offset = rng.below(2 * jitter + 1) as i32;
            queries.push((data[src * 2 + j] + offset - jitter as i32).clamp(0, 999));
        }
    }
    queries
}

pub fn gen_uniform(seed: u64, n: usize, dim: usize) -> Vec<i32> {
    let mut rng = SplitMix64::new(seed);
    (0..n * dim).map(|_| rng.below(1000) as i32).collect()
}

/// The whole scenario as text. Writing to a `String` cannot fail, so the
/// `fmt::Result`s are unwrapped once here instead of threading `?` through.
pub fn run_scenario() -> String {
    let mut w = String::new();
    zone_section(&mut w).unwrap();
    order_section(&mut w).unwrap();
    ivf_section_2d(&mut w).unwrap();
    ivf_section_wide(&mut w).unwrap();
    w
}

fn zone_section(w: &mut String) -> std::fmt::Result {
    writeln!(
        w,
        "== 1. zone maps: {} rows in {} chunks of {} ==",
        ZONE_ROWS,
        ZONE_ROWS / u64::from(ZONE_CHUNK),
        ZONE_CHUNK
    )?;
    writeln!(
        w,
        "layout    predicate        skip  all  scan  rows compared  matches"
    )?;
    for layout in Layout::ALL {
        let mut zm = ZoneMap::new(ZONE_CHUNK);
        fill_layout(&mut zm, layout).expect("no budget set");
        zm.validate().expect("valid zone map");
        for (text, filter) in ZONE_FILTERS {
            let s = zm.scan(filter);
            writeln!(
                w,
                "{:<9} {:<15} {:>5} {:>4} {:>5} {:>14} {:>8}",
                layout.name(),
                text,
                s.chunks_skipped,
                s.chunks_all,
                s.chunks_scanned,
                s.rows_compared,
                s.matches
            )?;
        }
    }
    // Maintenance is append-only: new rows widen the last zone or open one.
    let mut zm = ZoneMap::new(ZONE_CHUNK);
    fill_layout(&mut zm, Layout::Sorted).expect("no budget set");
    for i in 0..150 {
        zm.append(5000 - i).expect("no budget set");
    }
    zm.validate().expect("valid zone map");
    let last = zm.zones().last().expect("at least one zone");
    writeln!(
        w,
        "append 150 rows (5000 down to 4851) to 'sorted': {} chunks, last chunk has {} rows, min {}, max {}\n",
        zm.zones().len(),
        last.count,
        last.min,
        last.max
    )
}

fn order_section(w: &mut String) -> std::fmt::Result {
    writeln!(
        w,
        "== 2. one sort order for two dimensions: touching cells on a {GRID_SIDE} x {GRID_SIDE} grid =="
    )?;
    writeln!(
        w,
        "order      pairs  gap >= {GRID_SIDE}  largest gap  sum of gaps"
    )?;
    for curve in [zorder::Curve::RowMajor, zorder::Curve::ZOrder] {
        let s = zorder::gap_stats(curve, GRID_SIDE);
        writeln!(
            w,
            "{:<9} {:>6} {:>10} {:>12} {:>12}",
            curve.name(),
            s.pairs,
            s.far_pairs,
            s.max_gap,
            s.sum_gap
        )?;
    }
    writeln!(w)
}

/// Run every query at every nprobe in `probes` and print the recall table.
fn recall_table(
    w: &mut String,
    index: &Ivf,
    data: &[i32],
    queries: &[i32],
    k: usize,
    probes: &[usize],
) -> std::fmt::Result {
    let dim = index.dim;
    let nq = queries.len() / dim;
    // One buffer for all queries: `rank_lists` clears it but keeps the
    // memory, so after the first query ranking costs no allocation at all.
    let mut scratch = Vec::new();
    let mut want = vec![Hit { dist: 0, id: 0 }; k];
    let mut got = want.clone();
    writeln!(
        w,
        "nprobe  vectors scanned  of brute force  true neighbours found  recall"
    )?;
    for &nprobe in probes {
        let (mut scanned, mut found) = (0u64, 0u64);
        for query in queries.chunks_exact(dim) {
            let want_len = ivf::flat_search(data, dim, query, &mut want);
            let stats = index.search(&mut scratch, query, nprobe, &mut got);
            scanned += u64::from(stats.vectors_scanned);
            found += u64::from(ivf::overlap(&got[..stats.hits], &want[..want_len]));
        }
        let total = (nq * k) as u64;
        writeln!(
            w,
            "{:>6} {:>16} {:>15} {:>15} / {:<4} {:>6}%",
            nprobe,
            scanned,
            nq * (data.len() / dim),
            found,
            total,
            found * 100 / total
        )?;
    }
    Ok(())
}

fn ivf_section_2d(w: &mut String) -> std::fmt::Result {
    const N: usize = 240;
    const NLIST: usize = 8;
    const K: usize = 5;
    const NQ: usize = 24;
    let data = gen_blobs(BLOB_SEED, N, 6, 110);
    let queries = gen_near_data(QUERY_SEED, &data, NQ, 40);
    let index = Ivf::build(&data, 2, NLIST, TRAIN_SEED, 50);
    index.validate(&data).expect("valid index");

    writeln!(
        w,
        "== 3. IVF in 2 dimensions: {N} points, {NLIST} lists, k = {K}, {NQ} queries =="
    )?;
    writeln!(
        w,
        "k-means: assignments stopped changing after {} centroid updates",
        index.iterations
    )?;
    writeln!(w, "list  size  centroid")?;
    for c in 0..NLIST {
        let cen = index.centroid(c);
        writeln!(
            w,
            "{:>4} {:>5}  ({}, {})",
            c,
            index.list_len(c),
            cen[0],
            cen[1]
        )?;
    }
    recall_table(w, &index, &data, &queries, K, &[1, 2, 3, 4, 8])?;

    // The boundary problem, on one concrete query: the first query whose
    // true nearest neighbour is not in the list of its nearest centroid.
    let mut order = Vec::new();
    for (q, query) in queries.chunks_exact(2).enumerate() {
        let mut best = [Hit { dist: 0, id: 0 }];
        ivf::flat_search(&data, 2, query, &mut best);
        index.rank_lists(query, &mut order);
        let id = best[0].id as usize;
        let home = index.assign[id];
        if home == order[0].id {
            continue;
        }
        let rank = order
            .iter()
            .position(|o| o.id == home)
            .expect("every list is ranked");
        writeln!(w, "first miss: query {} at ({}, {})", q, query[0], query[1])?;
        writeln!(
            w,
            "  true nearest: id {} at ({}, {}), dist2 {}, stored in list {}",
            id,
            data[id * 2],
            data[id * 2 + 1],
            best[0].dist,
            home
        )?;
        writeln!(
            w,
            "  nearest centroid: list {} (dist2 {}); list {} ranks {} (dist2 {})",
            order[0].id,
            order[0].dist,
            home,
            rank + 1,
            order[rank].dist
        )?;
        writeln!(w, "  so nprobe must be at least {} to find it", rank + 1)?;
        break;
    }
    writeln!(w)
}

fn ivf_section_wide(w: &mut String) -> std::fmt::Result {
    const N: usize = 2000;
    const DIM: usize = 16;
    const NLIST: usize = 16;
    const K: usize = 10;
    const NQ: usize = 50;
    let data = gen_uniform(WIDE_SEED, N, DIM);
    let queries = gen_uniform(WIDE_SEED + 1, NQ, DIM);
    let index = Ivf::build(&data, DIM, NLIST, TRAIN_SEED, 25);
    index.validate(&data).expect("valid index");

    writeln!(
        w,
        "== 4. IVF in {DIM} dimensions: {N} uniform points, {NLIST} lists, k = {K}, {NQ} queries =="
    )?;
    writeln!(
        w,
        "k-means: {} centroid updates (limit 25)",
        index.iterations
    )?;
    let sizes = (0..NLIST).map(|c| index.list_len(c));
    let (smallest, largest) = (sizes.clone().min().unwrap_or(0), sizes.max().unwrap_or(0));
    writeln!(w, "list sizes: smallest {smallest}, largest {largest}")?;
    recall_table(w, &index, &data, &queries, K, &[1, 2, 4, 8, 16])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_output_matches_expected_output_txt() {
        assert_eq!(run_scenario(), include_str!("../../expected_output.txt"));
    }

    #[test]
    fn layouts_same_row_count_sorted_and_shuffled_hold_the_same_values() {
        let mut sums = [0u64; 3];
        for (i, layout) in Layout::ALL.into_iter().enumerate() {
            let mut zm = ZoneMap::new(ZONE_CHUNK);
            fill_layout(&mut zm, layout).unwrap();
            zm.validate().unwrap();
            assert_eq!(zm.values().len() as u64, ZONE_ROWS);
            sums[i] = zm.values().iter().sum();
        }
        assert_eq!(sums[0], sums[2]);
    }
}
