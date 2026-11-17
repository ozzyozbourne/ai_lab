//! Chapter 25: cache-conscious search and layout (twin of zig/src/main.zig).
//!
//! `cargo run` prints a fixed, deterministic scenario made only of counts
//! (comparisons, compare instructions, cache lines). It is byte-identical to
//! the Zig twin and to ../expected_output.txt.
//!
//! `cargo run --release -- --bench` additionally prints wall-clock timings to
//! STDERR. Timings depend on your machine and are never part of the expected
//! output or of any test.

mod layout;
mod node;
#[allow(dead_code)] // the copied PRNG has helpers this chapter does not call
mod prng;
mod search;
mod trace;

use std::fmt::Write as _;

use layout::{AlignedKeys, BlockTree, Eytzinger, SENTINEL};
use prng::SplitMix64;
use search::Select;
use trace::{LINE_BYTES, Layout, NoTrace, Trace};

/// Totals over many lookups of one algorithm.
#[derive(Debug, Clone, Copy, Default)]
struct Stats {
    lookups: u64,
    comparisons: u64,
    steps: u64,
    lines: u64,
    max_lines: u64,
    prefetches: u64,
    uncovered: u64,
}

impl Stats {
    fn add(&mut self, t: &Trace) {
        self.lookups += 1;
        self.comparisons += u64::from(t.comparisons);
        self.steps += u64::from(t.steps);
        self.lines += u64::from(t.lines_read());
        self.max_lines = self.max_lines.max(u64::from(t.lines_read()));
        self.prefetches += u64::from(t.prefetches);
        self.uncovered += u64::from(t.uncovered);
    }
}

/// "12.34" for total / count, rounded down, using integers only so that both
/// languages print the same digits.
fn avg(total: u64, count: u64) -> String {
    let hundredths = total * 100 / count;
    format!("{}.{:02}", hundredths / 100, hundredths % 100)
}

/// Strictly increasing keys with random gaps of 1..100.
fn make_keys(n: usize, seed: u64) -> Vec<u64> {
    let mut rng = SplitMix64::new(seed);
    let mut key = 0;
    (0..n)
        .map(|_| {
            key += 1 + rng.below(100);
            key
        })
        .collect()
}

/// Every searchable form of one sorted key set.
struct Index {
    sorted: Vec<u64>,
    padded: AlignedKeys,
    eytzinger: Eytzinger,
    blocks: BlockTree,
}

impl Index {
    fn new(sorted: Vec<u64>) -> Self {
        let padded = AlignedKeys::padded(&sorted);
        let eytzinger = Eytzinger::new(&sorted);
        let blocks = BlockTree::new(&sorted);
        eytzinger
            .validate()
            .expect("freshly built Eytzinger layout is valid");
        blocks
            .validate()
            .expect("freshly built block tree is valid");
        Self {
            sorted,
            padded,
            eytzinger,
            blocks,
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum Algorithm {
    Classic,
    Halving,
    Vector,
    Eytzinger,
    Blocktree,
}

const ALGORITHMS: [Algorithm; 5] = [
    Algorithm::Classic,
    Algorithm::Halving,
    Algorithm::Vector,
    Algorithm::Eytzinger,
    Algorithm::Blocktree,
];

impl Algorithm {
    fn name(self) -> &'static str {
        match self {
            Algorithm::Classic => "classic",
            Algorithm::Halving => "halving",
            Algorithm::Vector => "vector",
            Algorithm::Eytzinger => "eytzinger",
            Algorithm::Blocktree => "blocktree",
        }
    }
}

fn run_one(index: &Index, algorithm: Algorithm, needle: u64, t: &mut Trace) -> usize {
    match algorithm {
        Algorithm::Classic => search::lower_bound_classic(&index.sorted, needle, t),
        Algorithm::Halving => {
            search::lower_bound_halving(Select::Hinted, false, &index.sorted, needle, t)
        }
        Algorithm::Vector => search::lower_bound_vector(&index.padded, needle, t),
        Algorithm::Eytzinger => index.eytzinger.lower_bound(needle, false, t),
        Algorithm::Blocktree => index.blocks.lower_bound(needle, t),
    }
}

// Writing to a String cannot fail, so the `fmt::Result`s below are unwrapped
// once, in `scenario`.
fn print_keys(w: &mut String, keys: impl Iterator<Item = u64>) -> std::fmt::Result {
    for k in keys {
        if k == SENTINEL {
            w.push_str(" -")
        } else {
            write!(w, " {k}")?
        }
    }
    Ok(())
}

fn hand_example(w: &mut String) -> std::fmt::Result {
    w.push_str("== 1. Fifteen keys by hand ==\n");
    let index = Index::new((1..=15).map(|i| i * 10).collect());

    w.push_str("sorted    :");
    print_keys(w, index.sorted.iter().copied())?;
    w.push_str("\neytzinger :");
    print_keys(w, index.eytzinger.keys.iter().skip(1))?;
    w.push_str("\nblocktree :");
    print_keys(w, index.blocks.keys.iter().take(8))?;
    w.push_str(" |");
    print_keys(w, index.blocks.keys.iter().skip(8))?;
    w.push('\n');

    for needle in [70, 95, 999] {
        let want = search::lower_bound_linear(&index.sorted, needle);
        writeln!(w, "needle {needle} -> index {want}")?;
        for algorithm in ALGORITHMS {
            let mut t = Trace::new(Layout::KEYS);
            let got = run_one(&index, algorithm, needle, &mut t);
            assert_eq!(got, want);
            write!(
                w,
                "  {:<9} cmps {:>2} steps {} lines {} probes",
                algorithm.name(),
                t.comparisons,
                t.steps,
                t.lines_read()
            )?;
            for p in t.probes() {
                write!(w, " {p}")?;
            }
            w.push('\n');
        }
    }
    Ok(())
}

const LOOKUPS_PER_SIZE: u64 = 1000;

fn size_table(w: &mut String, agree: &mut u64, checksum: &mut u64) -> std::fmt::Result {
    writeln!(
        w,
        "\n== 2. {LOOKUPS_PER_SIZE} lookups per size: comparisons and cache lines per lookup =="
    )?;
    w.push_str("     n  algorithm     cmps   steps   lines  max lines\n");
    for n in [7usize, 15, 63, 255, 1023, 4095] {
        let index = Index::new(make_keys(n, 1000 + n as u64));
        let mut stats = [Stats::default(); ALGORITHMS.len()];
        let mut rng = SplitMix64::new(2000 + n as u64);
        for _ in 0..LOOKUPS_PER_SIZE {
            let needle = rng.below(index.sorted[n - 1] + 50);
            let want = search::lower_bound_linear(&index.sorted, needle);
            let mut all_equal = true;
            for (algorithm, s) in ALGORITHMS.into_iter().zip(&mut stats) {
                let mut t = Trace::new(Layout::KEYS);
                let got = run_one(&index, algorithm, needle, &mut t);
                all_equal = all_equal && got == want;
                s.add(&t);
            }
            *agree += u64::from(all_equal);
            *checksum += want as u64;
        }
        // The halving search is the one whose cost is known before it runs.
        assert_eq!(
            stats[1].comparisons,
            u64::from(search::halving_comparisons(n)) * LOOKUPS_PER_SIZE
        );
        for (algorithm, s) in ALGORITHMS.into_iter().zip(&stats) {
            writeln!(
                w,
                "{:>6}  {:<9} {:>8} {:>7} {:>7} {:>10}",
                n,
                algorithm.name(),
                avg(s.comparisons, s.lookups),
                avg(s.steps, s.lookups),
                avg(s.lines, s.lookups),
                s.max_lines
            )?;
        }
    }
    Ok(())
}

fn node_layouts(w: &mut String) -> std::fmt::Result {
    let capacity = 255usize;
    writeln!(
        w,
        "\n== 3. One {capacity}-entry node: array of structs vs struct of arrays =="
    )?;
    let keys = make_keys(capacity, 3000);
    let mut soa = node::SoaNode::new(capacity);
    let mut aos = node::AosNode::new(capacity);
    // Insert in a shuffled order so that `put` really has to keep the node sorted.
    let mut order = keys.clone();
    let mut rng = SplitMix64::new(3001);
    rng.shuffle(&mut order);
    for (i, &k) in order.iter().enumerate() {
        soa.put(k, i as u32 + 1)
            .expect("capacity equals the number of keys");
        aos.put(k, i as u32 + 1)
            .expect("capacity equals the number of keys");
    }
    soa.validate().expect("soa node is sorted");
    aos.validate().expect("aos node is sorted");
    assert_eq!(soa.keys(), keys);
    assert_eq!(soa.len(), capacity);

    let mut soa_stats = Stats::default();
    let mut aos_stats = Stats::default();
    let mut hits = 0u64;
    for _ in 0..LOOKUPS_PER_SIZE {
        // Half the needles are keys that exist, half are random.
        let needle = if rng.chance(1, 2) {
            keys[rng.below(capacity as u64) as usize]
        } else {
            rng.below(keys[capacity - 1] + 50)
        };
        let mut ts = Trace::new(node::SOA_LAYOUT);
        let mut ta = Trace::new(node::AOS_LAYOUT);
        let a = soa.get(needle, &mut ts);
        let b = aos.get(needle, &mut ta);
        assert_eq!(a, b);
        hits += u64::from(a.is_some());
        soa_stats.add(&ts);
        aos_stats.add(&ta);
    }
    w.push_str("layout  bytes/key  key bytes  key lines    cmps   lines  max lines\n");
    for (name, layout, stats) in [
        ("aos", node::AOS_LAYOUT, aos_stats),
        ("soa", node::SOA_LAYOUT, soa_stats),
    ] {
        let bytes = layout.stride * capacity;
        writeln!(
            w,
            "{:<6} {:>10} {:>10} {:>10} {:>7} {:>7} {:>10}",
            name,
            layout.stride,
            bytes,
            bytes.div_ceil(LINE_BYTES),
            avg(stats.comparisons, stats.lookups),
            avg(stats.lines, stats.lookups),
            stats.max_lines
        )?;
    }
    writeln!(
        w,
        "found {hits} of {LOOKUPS_PER_SIZE} needles; both layouts returned the same child every time"
    )
}

fn prefetch_table(w: &mut String) -> std::fmt::Result {
    let n = 4095usize;
    writeln!(w, "\n== 4. Prefetch coverage, n = {n}, per lookup ==")?;
    let index = Index::new(make_keys(n, 1000 + n as u64));
    let mut stats = [Stats::default(); 4];
    let mut rng = SplitMix64::new(4000);
    for _ in 0..LOOKUPS_PER_SIZE {
        let needle = rng.below(index.sorted[n - 1] + 50);
        let mut traces: [Trace; 4] = std::array::from_fn(|_| Trace::new(Layout::KEYS));
        let r0 = search::lower_bound_halving(
            Select::Hinted,
            false,
            &index.sorted,
            needle,
            &mut traces[0],
        );
        let r1 = search::lower_bound_halving(
            Select::Hinted,
            true,
            &index.sorted,
            needle,
            &mut traces[1],
        );
        let r2 = index.eytzinger.lower_bound(needle, false, &mut traces[2]);
        let r3 = index.eytzinger.lower_bound(needle, true, &mut traces[3]);
        assert!(r0 == r1 && r1 == r2 && r2 == r3);
        for (s, t) in stats.iter_mut().zip(&traces) {
            s.add(t);
        }
    }
    w.push_str("algorithm            lines   hints  lines not hinted\n");
    let names = [
        "halving",
        "halving+prefetch",
        "eytzinger",
        "eytzinger+prefetch",
    ];
    for (name, s) in names.into_iter().zip(&stats) {
        writeln!(
            w,
            "{:<18} {:>7} {:>7} {:>17}",
            name,
            avg(s.lines, s.lookups),
            avg(s.prefetches, s.lookups),
            avg(s.uncovered, s.lookups)
        )?;
    }
    Ok(())
}

fn write_scenario(w: &mut String) -> std::fmt::Result {
    w.push_str("Chapter 25: cache-conscious search and layout\n");
    w.push_str("model: 64-byte cache lines, 8-byte keys, arrays start on a line boundary\n\n");
    hand_example(w)?;
    let mut agree = 0;
    let mut checksum = 0;
    size_table(w, &mut agree, &mut checksum)?;
    node_layouts(w)?;
    prefetch_table(w)?;
    w.push_str("\n== 5. Agreement ==\n");
    writeln!(
        w,
        "all five algorithms returned the linear-scan answer in {agree} of {} lookups",
        6 * LOOKUPS_PER_SIZE
    )?;
    writeln!(w, "checksum of answers: {checksum}")
}

/// The whole deterministic scenario as one string. Tests compare it with
/// expected_output.txt.
fn scenario() -> String {
    let mut out = String::new();
    write_scenario(&mut out).expect("writing to a String cannot fail");
    out
}

/// Optional micro-benchmark. STDERR only; numbers vary by machine and build
/// mode and mean nothing in a debug build.
fn bench() {
    use std::hint::black_box;
    eprintln!("micro-benchmark (stderr only; build with --release for meaningful numbers)");
    type Lookup = fn(&Index, u64) -> usize;
    let variants: [(&str, Lookup); 9] = [
        ("classic", |ix, x| {
            search::lower_bound_classic(&ix.sorted, x, &mut NoTrace)
        }),
        ("halving-branch", |ix, x| {
            search::lower_bound_halving(Select::Branch, false, &ix.sorted, x, &mut NoTrace)
        }),
        ("halving-arith", |ix, x| {
            search::lower_bound_halving(Select::Arithmetic, false, &ix.sorted, x, &mut NoTrace)
        }),
        ("halving-hinted", |ix, x| {
            search::lower_bound_halving(Select::Hinted, false, &ix.sorted, x, &mut NoTrace)
        }),
        ("halving+prefetch", |ix, x| {
            search::lower_bound_halving(Select::Hinted, true, &ix.sorted, x, &mut NoTrace)
        }),
        ("vector", |ix, x| {
            search::lower_bound_vector(&ix.padded, x, &mut NoTrace)
        }),
        ("eytzinger", |ix, x| {
            ix.eytzinger.lower_bound(x, false, &mut NoTrace)
        }),
        ("eytzinger+prefetch", |ix, x| {
            ix.eytzinger.lower_bound(x, true, &mut NoTrace)
        }),
        ("blocktree", |ix, x| ix.blocks.lower_bound(x, &mut NoTrace)),
    ];
    for n in [15usize, 255, 4095] {
        let index = Index::new(make_keys(n, 1000 + n as u64));
        let mut rng = SplitMix64::new(9);
        let needles: Vec<u64> = (0..1 << 16)
            .map(|_| rng.below(index.sorted[n - 1] + 50))
            .collect();
        for (name, lookup) in variants {
            let start = std::time::Instant::now();
            let mut sum = 0usize;
            for _ in 0..8 {
                for &x in &needles {
                    sum = sum.wrapping_add(lookup(&index, x));
                }
            }
            black_box(sum);
            let centi = start.elapsed().as_nanos() * 100 / (8 * needles.len() as u128);
            eprintln!(
                "  n={:>5} {:<19} {:>4}.{:02} ns/lookup",
                n,
                name,
                centi / 100,
                centi % 100
            );
        }
    }
}

fn main() {
    print!("{}", scenario());
    if std::env::args().skip(1).any(|arg| arg == "--bench") {
        bench();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_scenario_prints_exactly_expected_output_txt() {
        assert_eq!(scenario(), include_str!("../../expected_output.txt"));
    }
}
