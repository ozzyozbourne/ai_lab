// Chapter 3: Size, Alignment and Padding (Rust 1.100, edition 2024, std only).
// Part (a) prints sizes, alignments and offsets (src/layout.rs).
// Part (b) sweeps N from 10k to 10M monsters and times one pass over three layouts of the same data:
//   24 B: pointer-sized anim handle, u32 hp, u32 y, bool    (Kelley's "fat" monster)
//   16 B: u32 anim index instead of the pointer-sized handle
//   12 B: u32 anim index and y quantized to u16
// Every variant computes the same checksum. Usage: [N = largest size, default 10_000_000] [--quick]

mod layout;

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

// monsters
/// 8 + 4 + 4 + 1 = 17 bytes of fields, padded to 24 (align 8).
#[derive(Clone, Copy)]
struct Fat {
    anim: usize, // stands in for a pointer: same size and alignment
    hp: u32,
    y: u32,
    alive: bool,
}

/// 4 + 4 + 4 + 1 = 13 bytes of fields, padded to 16 (align 4).
#[derive(Clone, Copy)]
struct Index {
    anim: u32,
    hp: u32,
    y: u32,
    alive: bool,
}

/// 4 + 4 + 2 + 1 = 11 bytes of fields, padded to 12 (align 4).
#[derive(Clone, Copy)]
struct Small {
    anim: u32,
    hp: u32,
    y: u16,
    alive: bool,
}

const _: () = assert!(size_of::<Fat>() == 24);
const _: () = assert!(size_of::<Index>() == 16);
const _: () = assert!(size_of::<Small>() == 12);
// monsters

// score
/// The per-monster work: read every field, sum the live ones.
/// Branch-free on purpose: `alive` is random, and a branch would measure mispredictions (Chapter 7).
trait Score {
    fn score(&self) -> u64;
}

impl Score for Fat {
    fn score(&self) -> u64 {
        (self.anim as u64 + self.hp as u64 + self.y as u64) * self.alive as u64
    }
}

impl Score for Index {
    fn score(&self) -> u64 {
        (self.anim as u64 + self.hp as u64 + self.y as u64) * self.alive as u64
    }
}

impl Score for Small {
    fn score(&self) -> u64 {
        (self.anim as u64 + self.hp as u64 + self.y as u64) * self.alive as u64
    }
}

fn total<M: Score>(ms: &[M]) -> u64 {
    ms.iter().map(M::score).sum()
}
// score

/// splitmix64 of i: a stateless hash, so all three languages generate the same monsters.
fn mix(i: u64) -> u64 {
    let mut z = i.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// (anim, hp, y, alive) for monster i: anim < 4096, hp < 1000, y < 65536, 75% alive.
fn fields(i: usize) -> (u32, u32, u16, bool) {
    let r = mix(i as u64);
    (
        (r & 0xFFF) as u32,
        ((r >> 12) % 1000) as u32,
        (r >> 24) as u16,
        (r >> 40) & 3 != 0,
    )
}

/// Builds the monsters, times one pass, prints a line and a BENCH record. Returns the checksum.
fn run<M: Score>(label: &str, n: usize, make: impl Fn(usize) -> M) -> u64 {
    let ms: Vec<M> = (0..n).map(make).collect();
    let runs = bench_runs(|| total(black_box(&ms)));
    let sum = total(&ms);
    let med = runs[RUNS / 2];
    println!(
        "  {label:<10} {:>3} B/elem  {:>11} B total  {:>6.3} ns/elem  checksum {sum}",
        size_of::<M>(),
        size_of::<M>() * n,
        med.as_nanos() as f64 / n as f64
    );
    emit_bench("ch03-monsters", label, n, &runs);
    sum
}

fn main() {
    let args = parse_args();
    layout::print();

    // The harness caps N at 4096 under --quick; this sweep has its own sizes.
    let explicit_n = std::env::args().skip(1).any(|a| a.parse::<usize>().is_ok());
    let max_n = if args.quick {
        100_000
    } else if explicit_n {
        args.n
    } else {
        10_000_000
    };
    let sizes = [
        10_000, 30_000, 100_000, 300_000, 1_000_000, 3_000_000, 10_000_000,
    ];

    println!("== padding-waste sweep (one pass, median of {RUNS}) ==");
    for n in sizes.into_iter().filter(|&n| n <= max_n) {
        println!("N = {n}");
        let a = run("24 B fat", n, |i| {
            let (anim, hp, y, alive) = fields(i);
            Fat {
                anim: anim as usize,
                hp,
                y: y as u32,
                alive,
            }
        });
        let b = run("16 B index", n, |i| {
            let (anim, hp, y, alive) = fields(i);
            Index {
                anim,
                hp,
                y: y as u32,
                alive,
            }
        });
        let c = run("12 B small", n, |i| {
            let (anim, hp, y, alive) = fields(i);
            Small { anim, hp, y, alive }
        });
        assert!(a == b && b == c, "checksums differ: {a} {b} {c}");
        println!("  checksums match");
    }
}
