// Chapter 12, "Measure, and Know When Not To": three ways a benchmark lies to you, measured.
//   (a) ch12-deadcode  one sum of squares timed three ways: result discarded (the optimizer deletes it),
//                      input visible to the optimizer (the loop becomes a formula), and kept alive (honest)
//   (b) ch12-noise     a 16 KiB and a 16 MiB sum, each timed SAMPLES times; every sample is printed for bench-dist
//   (c) ch12-aa        an A/A test: the same kernel as "A" and "B", timed A-then-B and A,B,A,B
// Usage: cargo run --release -q -p ch12_measure_and_know_when_not_to -- [N] [--quick]

// ---- harness ----
use std::hint::black_box;
use std::time::{Duration, Instant};

const RUNS: usize = 7;

/// Runs `f` once to warm up, then RUNS timed times. Returns the sorted timings.
fn bench_runs<R>(mut f: impl FnMut() -> R) -> [Duration; RUNS] {
    black_box(f());
    let mut t = [Duration::ZERO; RUNS];
    for slot in &mut t {
        let t0 = Instant::now();
        black_box(f());
        *slot = t0.elapsed();
    }
    t.sort_unstable();
    t
}

/// Median of RUNS timed runs (after one warm-up run).
#[allow(dead_code)]
fn bench<R>(f: impl FnMut() -> R) -> Duration {
    bench_runs(f)[RUNS / 2]
}

struct Args {
    n: usize,
    quick: bool,
}

/// Positional integer N (default 1 << 20) and `--quick` (caps N at 1 << 12).
fn parse_args() -> Args {
    let mut a = Args { n: 1 << 20, quick: false };
    for arg in std::env::args().skip(1) {
        if arg == "--quick" {
            a.quick = true
        } else if let Ok(n) = arg.parse() {
            a.n = n
        }
    }
    if a.quick {
        a.n = a.n.min(1 << 12)
    }
    a
}

/// Prints one machine-readable line for bench_all.sh:
/// BENCH {"id":"chNN-x","label":"...","lang":"rust","n":N,"ns":median,"samples":[...]}
/// `runs` must be sorted (as returned by `bench_runs`). `ns` is the median total time for one run.
fn emit_bench(id: &str, label: &str, n: usize, runs: &[Duration]) {
    let esc = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let samples: Vec<String> = runs.iter().map(|d| d.as_nanos().to_string()).collect();
    println!(
        "BENCH {{\"id\":\"{}\",\"label\":\"{}\",\"lang\":\"rust\",\"n\":{},\"ns\":{},\"samples\":[{}]}}",
        esc(id),
        esc(label),
        n,
        runs[runs.len() / 2].as_nanos(),
        samples.join(",")
    );
}
// ---- harness ----

/// A layout guard: the build fails if someone grows the hot record.
#[allow(dead_code)] // only its layout matters in this program
#[derive(Clone, Copy)]
struct Particle {
    pos: [f32; 3],
    vel: [f32; 3],
    alive: bool,
    kind: u8,
}
const _: () = assert!(size_of::<Particle>() == 28);

/// Timed runs per noise sample set (bench-dist draws every one of them).
const SAMPLES: usize = 41;
/// Timed runs per side of the A/A test, and how many times the whole test is repeated.
const AA: usize = 31;
const AA_ROUNDS: usize = 7;

/// Below this many ns per element, a loop over memory is not believable: at 2.6 GHz it would
/// mean about 8 elements per clock cycle, more than this loop can sustain. The honest run takes about 0.4 ns.
const MIN_PLAUSIBLE_NS_PER_ELEM: f64 = 0.05;

/// The kernel for the dead-code demo: a wrapping sum of squares over a slice.
fn sum_squares(v: &[u64]) -> u64 {
    v.iter().fold(0, |s, &x| s.wrapping_add(x.wrapping_mul(x)))
}

/// The same sum with no input data: v[i] = i, so the loop only needs n.
fn sum_squares_range(n: u64) -> u64 {
    (0..n).fold(0, |s, x| s.wrapping_add(x.wrapping_mul(x)))
}

/// A broken harness: identical to `bench_runs`, except that the result is dropped.
fn bench_runs_discarding<R>(mut f: impl FnMut() -> R) -> [Duration; RUNS] {
    let _ = f();
    let mut t = [Duration::ZERO; RUNS];
    for slot in &mut t {
        let t0 = Instant::now();
        let _ = f(); // nothing reads this, so the optimizer may delete the call
        *slot = t0.elapsed();
    }
    t.sort_unstable();
    t
}

/// Two sanity checks every timing should pass before anyone looks at a ratio.
fn verdict(d: Duration, timer_floor: Duration, n: usize) -> &'static str {
    if d < 2 * timer_floor {
        "<- SUSPICIOUS: no slower than timing nothing"
    } else if d.as_nanos() as f64 / (n as f64) < MIN_PLAUSIBLE_NS_PER_ELEM {
        "<- SUSPICIOUS: faster than the core can do the work"
    } else {
        "plausible"
    }
}

/// The noise kernel: sum a slice of u32 into a u64.
fn sum_u32(v: &[u32]) -> u64 {
    v.iter().map(|&x| u64::from(x)).sum()
}

/// Same input in all three languages: x[i] = i * 2654435761 (mod 2^32).
fn make_u32(n: usize) -> Vec<u32> {
    (0..n as u32).map(|i| i.wrapping_mul(2_654_435_761)).collect()
}

/// `bench_runs` with K timed runs instead of RUNS: one warm-up, then K sorted timings.
fn sample_runs<const K: usize, R>(mut f: impl FnMut() -> R) -> [Duration; K] {
    black_box(f());
    let mut t = [Duration::ZERO; K];
    for slot in &mut t {
        let t0 = Instant::now();
        black_box(f());
        *slot = t0.elapsed();
    }
    t.sort_unstable();
    t
}

/// Coefficient of variation: sample standard deviation divided by the mean.
fn cv(runs: &[Duration]) -> f64 {
    let xs: Vec<f64> = runs.iter().map(|d| d.as_nanos() as f64).collect();
    let mean = xs.iter().sum::<f64>() / xs.len() as f64;
    let var = xs.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / (xs.len() - 1) as f64;
    var.sqrt() / mean
}

fn med(runs: &[Duration]) -> f64 {
    runs[runs.len() / 2].as_nanos() as f64
}

/// A/A test, sequential: all AA runs of "A", then all AA runs of "B". Same code, different buffers.
fn aa_sequential(a: &[u32], b: &[u32]) -> ([Duration; AA], [Duration; AA]) {
    let ta = sample_runs::<AA, _>(|| sum_u32(black_box(a)));
    let tb = sample_runs::<AA, _>(|| sum_u32(black_box(b)));
    (ta, tb)
}

/// A/A test, alternating: A, B, A, B, ... so slow drift hits both sides equally.
fn aa_alternating(a: &[u32], b: &[u32]) -> ([Duration; AA], [Duration; AA]) {
    black_box(sum_u32(black_box(a)));
    black_box(sum_u32(black_box(b)));
    let (mut ta, mut tb) = ([Duration::ZERO; AA], [Duration::ZERO; AA]);
    for i in 0..AA {
        let t0 = Instant::now();
        black_box(sum_u32(black_box(a)));
        ta[i] = t0.elapsed();
        let t0 = Instant::now();
        black_box(sum_u32(black_box(b)));
        tb[i] = t0.elapsed();
    }
    ta.sort_unstable();
    tb.sort_unstable();
    (ta, tb)
}

fn main() {
    let args = parse_args();
    let n = args.n;

    // ---- (a) dead code: the same work, timed three ways ----
    let v: Vec<u64> = (0..n as u64).collect();
    let empty = bench_runs(|| 0u64); // nothing but two clock reads
    let discarded = bench_runs_discarding(|| sum_squares(&v));
    let folded = bench_runs(|| sum_squares_range(n as u64));
    let kept = bench_runs(|| sum_squares(black_box(&v)));
    println!("(a) sum of squares over {n} u64, median of {RUNS}:");
    for (label, runs) in [
        ("empty (timer only)", &empty),
        ("result discarded", &discarded),
        ("input visible", &folded),
        ("kept alive", &kept),
    ] {
        let m = runs[RUNS / 2];
        println!(
            "    {label:<17} {:>12} ns  {:>9.4} ns/elem  {}",
            m.as_nanos(),
            m.as_nanos() as f64 / n as f64,
            if label.starts_with("empty") {
                "(the floor: two clock reads)"
            } else {
                verdict(m, empty[RUNS / 2], n)
            }
        );
        emit_bench("ch12-deadcode", label, n, runs);
    }
    println!(
        "    checksum: kept alive {}, input visible {}",
        sum_squares(black_box(&v)),
        sum_squares_range(black_box(n as u64))
    );

    // ---- (b) noise: one kernel, many samples ----
    println!("(b) noise, {SAMPLES} timed runs each:");
    for (label, len) in [("16 KiB (L1)", 1usize << 12), ("16 MiB (L3/DRAM)", 1 << 22)] {
        let x = make_u32(len);
        let runs = sample_runs::<SAMPLES, _>(|| sum_u32(black_box(&x)));
        println!(
            "    {label:<17} min {:>10} ns  median {:>10} ns  max {:>10} ns  CV {:>5.1}%  checksum {}",
            runs[0].as_nanos(),
            runs[SAMPLES / 2].as_nanos(),
            runs[SAMPLES - 1].as_nanos(),
            100.0 * cv(&runs),
            sum_u32(&x)
        );
        emit_bench("ch12-noise", label, len, &runs);
    }

    // ---- (c) A/A test: sequential versus alternating ----
    let len = 1usize << 16; // 256 KiB per buffer: both fit in L2 together
    let (a, b) = (make_u32(len), make_u32(len));
    println!("(c) A/A test on 2 x 256 KiB, {AA} runs per side; B/A ratio of medians (truth: 1.000)");
    let (mut seq, mut alt) = (Vec::new(), Vec::new());
    for round in 0..AA_ROUNDS {
        let (sa, sb) = aa_sequential(&a, &b);
        let (aa, ab) = aa_alternating(&a, &b);
        seq.push(med(&sb) / med(&sa));
        alt.push(med(&ab) / med(&aa));
        if round == 0 {
            emit_bench("ch12-aa", "A, sequential", len, &sa);
            emit_bench("ch12-aa", "B, sequential", len, &sb);
            emit_bench("ch12-aa", "A, alternating", len, &aa);
            emit_bench("ch12-aa", "B, alternating", len, &ab);
        }
    }
    let show = |xs: &[f64]| xs.iter().map(|r| format!("{r:.3}")).collect::<Vec<_>>().join(" ");
    // (median, worst) of |B/A - 1| over the rounds
    let err = |xs: &[f64]| {
        let mut d: Vec<f64> = xs.iter().map(|r| (r - 1.0).abs()).collect();
        d.sort_by(f64::total_cmp);
        (100.0 * d[d.len() / 2], 100.0 * d[d.len() - 1])
    };
    for (name, xs) in [("sequential", &seq), ("alternating", &alt)] {
        let (m, w) = err(xs);
        println!("    {name:<11} {}  |B/A-1| median {m:.1}%, worst {w:.1}%", show(xs));
    }
    println!("    checksum: A {} B {}", sum_u32(&a), sum_u32(&b));

    // ---- (d) layout guard: checked at compile time, printed for the reader ----
    use std::mem::offset_of;
    println!(
        "(d) Particle: {} B, align {}; pos @{}, vel @{}, alive @{}, kind @{}",
        size_of::<Particle>(),
        align_of::<Particle>(),
        offset_of!(Particle, pos),
        offset_of!(Particle, vel),
        offset_of!(Particle, alive),
        offset_of!(Particle, kind)
    );
}
