// Chapter 2, "The Machine": what the memory hierarchy costs, measured four ways.
//   (a) ch02-list    sum 4·N nodes as an array, as a list linked in memory order, and as a shuffled list
//   (b) ch02-sweep   a dependent random chase (Sattolo single cycle, one load per 64 B line) from 4 KiB to 512 MiB
//   (c) ch02-access  the same 16·N u32s read sequentially, at a 64 B stride, at a 4 KiB stride, in random order,
//                    and in random order with a software prefetch
//   (d) ch02-mlp     the same chase split into 1, 2, 4 or 8 independent chains (memory-level parallelism)
// N defaults to 2^20, so (a), (c) and (d) each touch 64 MiB, more than this orb's 54 MiB L3.
// Run: cargo run --release -q -p ch02_the_machine -- --quick   (from code/)

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

/// splitmix64. The Zig and Odin versions use the same generator and seeds, so all three
/// programs build identical permutations and print identical checksums.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    /// Uniform-enough integer in 0..n (multiply-high, no division).
    fn below(&mut self, n: usize) -> usize {
        ((self.next() as u128 * n as u128) >> 64) as usize
    }
}

/// Fisher-Yates: a uniformly random permutation of 0..n.
fn shuffled(n: usize, rng: &mut Rng) -> Vec<u32> {
    let mut p: Vec<u32> = (0..n as u32).collect();
    for i in (1..n).rev() {
        p.swap(i, rng.below(i + 1));
    }
    p
}

/// Sattolo's algorithm: like Fisher-Yates but j < i, never j == i. The result, read as
/// "next = p[i]", is ONE cycle through all n elements, so a chase can never get stuck in a short loop.
fn sattolo(n: usize, rng: &mut Rng) -> Vec<u32> {
    let mut p: Vec<u32> = (0..n as u32).collect();
    for i in (1..n).rev() {
        p.swap(i, rng.below(i));
    }
    p
}

// ---- (a) array vs linked list ----

const END: u32 = u32::MAX;

/// 16 bytes: 8 value + 4 next + 4 padding, so four nodes share a 64-byte line.
#[derive(Clone, Copy)]
struct Node {
    value: u64,
    next: u32,
}

/// Links the nodes in `order`: order[0] is the head and each node points to the next one in `order`.
fn link(order: &[u32]) -> (Vec<Node>, u32) {
    let mut nodes = vec![Node { value: 0, next: END }; order.len()];
    for (k, &i) in order.iter().enumerate() {
        nodes[i as usize] = Node { value: i as u64, next: order.get(k + 1).copied().unwrap_or(END) };
    }
    (nodes, order[0])
}

fn sum_array(nodes: &[Node]) -> u64 {
    nodes.iter().map(|n| n.value).sum()
}

fn sum_list(nodes: &[Node], head: u32) -> u64 {
    let (mut s, mut i) = (0, head);
    while i != END {
        let n = nodes[i as usize];
        s += n.value;
        i = n.next; // the next address is only known when this load returns
    }
    s
}

// ---- (b) and (d) dependent chase, one u32 per 64-byte line ----

const LINE_U32: usize = 64 / 4;

/// `bytes` of memory with one live u32 per 64-byte line: buf[16·k] = 16·next(k), next a Sattolo cycle.
fn chase_buffer(bytes: usize, rng: &mut Rng) -> Vec<u32> {
    let lines = bytes / 64;
    let mut buf = vec![0u32; lines * LINE_U32];
    for (k, &nx) in sattolo(lines, rng).iter().enumerate() {
        buf[k * LINE_U32] = nx * LINE_U32 as u32;
    }
    buf
}

fn chase(buf: &[u32], hops: usize) -> u64 {
    let (mut s, mut i) = (0u64, 0usize);
    for _ in 0..hops {
        i = buf[i] as usize; // each load needs the previous one's result
        s += i as u64;
    }
    s
}

/// One full trip around a cycle of `lines` lines visits every line once: sum of 16·k for k < lines.
fn trip_sum(lines: usize) -> u64 {
    (LINE_U32 * lines * (lines - 1) / 2) as u64
}

/// K cursors spread evenly around the same cycle, advanced in lockstep. The K loads in one
/// round do not depend on each other, so the core can have K misses in flight at once.
fn chase_k<const K: usize>(buf: &[u32], starts: &[usize; K], hops_each: usize) -> u64 {
    let (mut cur, mut s) = (*starts, 0u64);
    for _ in 0..hops_each {
        for c in &mut cur {
            *c = buf[*c] as usize;
            s += *c as u64;
        }
    }
    s
}

fn starts<const K: usize>(buf: &[u32], lines: usize) -> [usize; K] {
    let mut out = [0; K];
    let mut i = 0;
    for (k, slot) in out.iter_mut().enumerate() {
        *slot = i;
        if k + 1 < K {
            for _ in 0..lines / K {
                i = buf[i] as usize;
            }
        }
    }
    out
}

// ---- (c) access patterns over the same bytes ----

fn sum_seq(a: &[u32]) -> u64 {
    a.iter().map(|&x| x as u64).sum()
}

/// Visits every element exactly once: `stride` passes, each touching every stride-th element.
fn sum_strided(a: &[u32], stride: usize) -> u64 {
    let mut s = 0;
    for off in 0..stride {
        s += a[off..].iter().step_by(stride).map(|&x| x as u64).sum::<u64>();
    }
    s
}

fn sum_gather(a: &[u32], idx: &[u32]) -> u64 {
    idx.iter().map(|&i| a[i as usize] as u64).sum()
}

/// Software prefetch hint (`prefetcht0`). Other targets get a no-op.
#[cfg(target_arch = "x86_64")]
fn prefetch(p: &u32) {
    use std::arch::x86_64::{_MM_HINT_T0, _mm_prefetch};
    // The check is a cached bit test, and always true: SSE is part of the x86_64 baseline.
    if is_x86_feature_detected!("sse") {
        // SAFETY: the CPU supports SSE (checked above), which is all `_mm_prefetch` requires.
        // A prefetch is only a hint: it never faults and does not change program behaviour.
        unsafe { _mm_prefetch::<_MM_HINT_T0>(std::ptr::from_ref(p).cast()) }
    }
}
#[cfg(not(target_arch = "x86_64"))]
fn prefetch(_: &u32) {}

const PREFETCH_AHEAD: usize = 16;

fn sum_gather_prefetch(a: &[u32], idx: &[u32]) -> u64 {
    let mut s = 0;
    for (k, &i) in idx.iter().enumerate() {
        if let Some(&ahead) = idx.get(k + PREFETCH_AHEAD) {
            prefetch(&a[ahead as usize]); // ask for a line we will need 16 iterations from now
        }
        s += a[i as usize] as u64;
    }
    s
}

fn ns_per(d: Duration, n: usize) -> f64 {
    d.as_nanos() as f64 / n as f64
}

fn main() {
    let args = parse_args();
    let n = args.n;
    let mut all_ok = true;
    println!("ch02 the machine: N = {n}, quick = {}", args.quick);

    // (a) array vs linked list over 4·N 16-byte nodes
    {
        let count = 4 * n;
        let mut rng = Rng(1);
        let (in_order, head0) = link(&(0..count as u32).collect::<Vec<_>>());
        let (scattered, head1) = link(&shuffled(count, &mut rng));
        let want = (count * (count - 1) / 2) as u64;
        let sums = [sum_array(&scattered), sum_list(&in_order, head0), sum_list(&scattered, head1)];
        let ok = sums.iter().all(|&s| s == want);
        all_ok &= ok;
        println!("(a) {count} nodes x 16 B = {} KiB, checksum {want} ({})", count * 16 / 1024, if ok { "all match" } else { "MISMATCH" });
        let cases: [(&str, &dyn Fn() -> u64); 3] = [
            ("array", &|| sum_array(black_box(&scattered))),
            ("list, in order", &|| sum_list(black_box(&in_order), head0)),
            ("list, shuffled", &|| sum_list(black_box(&scattered), head1)),
        ];
        for (label, f) in cases {
            let runs = bench_runs(f);
            println!("    {label:<16} {:>7.2} ns/node", ns_per(runs[RUNS / 2], count));
            emit_bench("ch02-list", label, count, &runs);
        }
    }

    // (b) working-set sweep: 4 KiB .. 512 MiB (2 MiB with --quick), powers of two and 1.5x midpoints
    {
        let max = if args.quick { 2 << 20 } else { 512 << 20 };
        let min_hops: usize = if args.quick { 1 << 16 } else { 1 << 21 };
        let mut sizes = Vec::new();
        let mut b: usize = 4 << 10;
        while b <= max {
            sizes.push(b);
            if b * 3 / 2 <= max {
                sizes.push(b * 3 / 2);
            }
            b *= 2;
        }
        println!("(b) dependent random chase, one load per 64 B line, >= {min_hops} loads per size");
        let mut rng = Rng(2);
        let mut ok = true;
        for bytes in sizes {
            let buf = chase_buffer(bytes, &mut rng);
            let lines = bytes / 64;
            let rounds = (min_hops / lines).max(1);
            ok &= chase(&buf, rounds * lines) == rounds as u64 * trip_sum(lines);
            let runs = bench_runs(|| chase(black_box(&buf), rounds * lines));
            // one sample = one trip around the cycle, so ns/n is the latency of one load
            let per_trip = runs.map(|d| d / rounds as u32);
            println!("    {:>8} KiB  {:>7.2} ns/load", bytes >> 10, ns_per(per_trip[RUNS / 2], lines));
            emit_bench("ch02-sweep", "random chase", lines, &per_trip);
        }
        all_ok &= ok;
        println!("    every trip visited every line once: {}", if ok { "yes" } else { "NO" });
    }

    // (c) sequential vs strided vs random over the same 16·N u32s
    {
        let m = 16 * n;
        let mut rng = Rng(3);
        let a: Vec<u32> = (0..m as u32).map(|i| i.wrapping_mul(2_654_435_761)).collect();
        let idx = shuffled(m, &mut rng);
        let want = sum_seq(&a);
        let got = [sum_strided(&a, 16), sum_strided(&a, 1024), sum_gather(&a, &idx), sum_gather_prefetch(&a, &idx)];
        let ok = got.iter().all(|&s| s == want);
        all_ok &= ok;
        println!("(c) {m} u32 = {} KiB, checksum {want} ({})", m * 4 / 1024, if ok { "all match" } else { "MISMATCH" });
        let cases: [(&str, &dyn Fn() -> u64); 5] = [
            ("sequential", &|| sum_seq(black_box(&a))),
            ("stride 64 B", &|| sum_strided(black_box(&a), 16)),
            ("stride 4 KiB", &|| sum_strided(black_box(&a), 1024)),
            ("random", &|| sum_gather(black_box(&a), black_box(&idx))),
            ("random + prefetch", &|| sum_gather_prefetch(black_box(&a), black_box(&idx))),
        ];
        for (label, f) in cases {
            let runs = bench_runs(f);
            println!("    {label:<18} {:>7.2} ns/elem", ns_per(runs[RUNS / 2], m));
            emit_bench("ch02-access", label, m, &runs);
        }
    }

    // (d) memory-level parallelism: the same N-line cycle walked by 1, 2, 4 or 8 chains
    {
        let lines = n / 8 * 8;
        let mut rng = Rng(4);
        let buf = chase_buffer(lines * 64, &mut rng);
        let (s1, s2, s4, s8) = (starts::<1>(&buf, lines), starts::<2>(&buf, lines), starts::<4>(&buf, lines), starts::<8>(&buf, lines));
        let want = trip_sum(lines);
        let got = [chase_k(&buf, &s1, lines), chase_k(&buf, &s2, lines / 2), chase_k(&buf, &s4, lines / 4), chase_k(&buf, &s8, lines / 8)];
        let ok = got.iter().all(|&s| s == want);
        all_ok &= ok;
        println!("(d) {lines} lines = {} KiB, checksum {want} ({})", lines * 64 / 1024, if ok { "all match" } else { "MISMATCH" });
        let cases: [(&str, &dyn Fn() -> u64); 4] = [
            ("1 chain", &|| chase_k(black_box(&buf), &s1, lines)),
            ("2 chains", &|| chase_k(black_box(&buf), &s2, lines / 2)),
            ("4 chains", &|| chase_k(black_box(&buf), &s4, lines / 4)),
            ("8 chains", &|| chase_k(black_box(&buf), &s8, lines / 8)),
        ];
        for (label, f) in cases {
            let runs = bench_runs(f);
            println!("    {label:<9} {:>7.2} ns/load", ns_per(runs[RUNS / 2], lines));
            emit_bench("ch02-mlp", label, lines, &runs);
        }
    }

    if !all_ok {
        eprintln!("checksum mismatch");
        std::process::exit(1);
    }
}
