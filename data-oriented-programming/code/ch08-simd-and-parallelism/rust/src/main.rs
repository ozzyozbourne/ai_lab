//! Chapter 8: SIMD and parallelism.
//!   1. f32 dot product four ways (naive, 8 accumulators, explicit AVX2, algebraic) at L1 / L2 / DRAM sizes
//!   2. a branch in SIMD: sum and count of the positive values, branchy vs 8-lane mask
//!   3. false sharing: per-thread atomic counters packed in one line vs padded to 64 B / 128 B
//!   4. thread scaling: SoA particle step split into chunks over 1, 2 and 4 threads
//!
//! Run: cargo run --release -q -p ch08_simd_and_parallelism -- [N] [--quick]   (DRAM control = 16·N floats)

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

use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;

/// lowbias32 (Chris Wellons): the same integer hash in all three languages, so the data is identical.
fn hash(mut x: u32) -> u32 {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb_352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846c_a68b);
    x ^ (x >> 16)
}

/// 24 random bits as an exact f32 in [-1, 1).
fn signed(h: u32) -> f32 {
    (h >> 8) as f32 * (1.0 / 8_388_608.0) - 1.0
}

// ---- dot ----
/// 1. The obvious loop: one accumulator, strict left-to-right order. Each add waits for the previous one.
fn dot_naive(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// 2. Eight accumulators: we reassociate by hand, so the compiler may put `acc` in SIMD lanes.
fn dot_acc8(a: &[f32], b: &[f32]) -> f32 {
    let (ca, ta) = a.as_chunks::<8>();
    let (cb, tb) = b.as_chunks::<8>();
    let mut acc = [0.0_f32; 8];
    for (x, y) in ca.iter().zip(cb) {
        for ((s, x), y) in acc.iter_mut().zip(x).zip(y) {
            *s += x * y;
        }
    }
    let mut s = 0.0;
    for v in acc {
        s += v;
    }
    for (x, y) in ta.iter().zip(tb) {
        s += x * y;
    }
    s
}

/// 3a. Explicit AVX2: four 8-lane accumulators (32 partial sums) so four adds are in flight at once.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
fn dot_avx2(a: &[f32], b: &[f32]) -> f32 {
    use std::arch::x86_64::*;
    let (ca, ta) = a.as_chunks::<32>();
    let (cb, tb) = b.as_chunks::<32>();
    let mut acc = [_mm256_setzero_ps(); 4];
    for (x, y) in ca.iter().zip(cb) {
        for (k, acc) in acc.iter_mut().enumerate() {
            // SAFETY: x and y are [f32; 32], so lanes 8k..8k+8 are in bounds; loadu needs no alignment.
            let (vx, vy) = unsafe { (_mm256_loadu_ps(x.as_ptr().add(8 * k)), _mm256_loadu_ps(y.as_ptr().add(8 * k))) };
            *acc = _mm256_add_ps(*acc, _mm256_mul_ps(vx, vy)); // value-only intrinsics are safe here (1.87+)
        }
    }
    let v = _mm256_add_ps(_mm256_add_ps(_mm256_add_ps(acc[0], acc[1]), acc[2]), acc[3]);
    let mut lanes = [0.0_f32; 8];
    // SAFETY: `lanes` has room for 8 f32; storeu needs no alignment.
    unsafe { _mm256_storeu_ps(lanes.as_mut_ptr(), v) };
    let mut s = 0.0;
    for l in lanes {
        s += l;
    }
    for (x, y) in ta.iter().zip(tb) {
        s += x * y;
    }
    s
}

/// 3b. Scalar fallback with the same 4×8 accumulator layout, so it returns the same bits as `dot_avx2`.
fn dot_acc32(a: &[f32], b: &[f32]) -> f32 {
    let (ca, ta) = a.as_chunks::<32>();
    let (cb, tb) = b.as_chunks::<32>();
    let mut acc = [[0.0_f32; 8]; 4];
    for (x, y) in ca.iter().zip(cb) {
        for (k, acc) in acc.iter_mut().enumerate() {
            for (j, s) in acc.iter_mut().enumerate() {
                *s += x[8 * k + j] * y[8 * k + j];
            }
        }
    }
    let mut s = 0.0;
    for j in 0..8 {
        s += ((acc[0][j] + acc[1][j]) + acc[2][j]) + acc[3][j];
    }
    for (x, y) in ta.iter().zip(tb) {
        s += x * y;
    }
    s
}

/// 3. Runtime dispatch: AVX2 if this CPU has it, the portable version otherwise.
fn dot_simd(a: &[f32], b: &[f32]) -> f32 {
    #[cfg(target_arch = "x86_64")]
    if is_x86_feature_detected!("avx2") {
        // SAFETY: we just checked at run time that the CPU supports AVX2.
        return unsafe { dot_avx2(a, b) };
    }
    dot_acc32(a, b)
}

/// 4. The naive loop with algebraic ops (stable 1.98): the compiler may reassociate, so it vectorizes.
fn dot_algebraic(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).fold(0.0, |s, (x, y)| s.algebraic_add(x.algebraic_mul(*y)))
}
// ---- dot ----

// ---- mask ----
/// Branchy scalar: sum and count of the positive values.
fn pos_branchy(a: &[f32]) -> (f32, u32) {
    let (mut s, mut c) = (0.0_f32, 0_u32);
    for &x in a {
        if x > 0.0 {
            s += x;
            c += 1;
        }
    }
    (s, c)
}

/// Branch-free lanes, AVX2: compare makes a mask (all ones where x > 0); AND keeps x or 0.0.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
fn pos_avx2(a: &[f32]) -> (f32, u32) {
    use std::arch::x86_64::*;
    let (chunks, tail) = a.as_chunks::<8>();
    let zero = _mm256_setzero_ps();
    let (mut s, mut c) = (zero, _mm256_setzero_si256());
    for x in chunks {
        // SAFETY: x is [f32; 8]; loadu needs no alignment.
        let v = unsafe { _mm256_loadu_ps(x.as_ptr()) };
        let m = _mm256_cmp_ps::<_CMP_GT_OQ>(v, zero); // lane = 0xFFFF_FFFF where x > 0, else 0
        s = _mm256_add_ps(s, _mm256_and_ps(v, m)); // x where true, +0.0 where false
        c = _mm256_sub_epi32(c, _mm256_castps_si256(m)); // all ones is -1, so subtracting counts
    }
    let (mut sl, mut cl) = ([0.0_f32; 8], [0_u32; 8]);
    // SAFETY: both arrays hold exactly 8 lanes; storeu needs no alignment.
    unsafe {
        _mm256_storeu_ps(sl.as_mut_ptr(), s);
        _mm256_storeu_si256(cl.as_mut_ptr().cast(), c);
    }
    let (mut s, mut c) = (0.0, 0);
    for j in 0..8 {
        s += sl[j];
        c += cl[j];
    }
    let (ts, tc) = pos_branchy(tail);
    (s + ts, c + tc)
}

/// The same masks in portable code: 8 lanes, `if` replaced by a select. Same bits as `pos_avx2`.
fn pos_lanes(a: &[f32]) -> (f32, u32) {
    let (chunks, tail) = a.as_chunks::<8>();
    let (mut sl, mut cl) = ([0.0_f32; 8], [0_u32; 8]);
    for x in chunks {
        for j in 0..8 {
            let m = x[j] > 0.0;
            sl[j] += if m { x[j] } else { 0.0 };
            cl[j] += m as u32;
        }
    }
    let (mut s, mut c) = (0.0, 0);
    for j in 0..8 {
        s += sl[j];
        c += cl[j];
    }
    let (ts, tc) = pos_branchy(tail);
    (s + ts, c + tc)
}

fn pos_mask(a: &[f32]) -> (f32, u32) {
    #[cfg(target_arch = "x86_64")]
    if is_x86_feature_detected!("avx2") {
        // SAFETY: AVX2 support checked at run time just above.
        return unsafe { pos_avx2(a) };
    }
    pos_lanes(a)
}
// ---- mask ----

// ---- false sharing ----
/// Two counters in one 64-byte line (the array is aligned so it cannot straddle two lines).
#[repr(align(64))]
struct Packed([AtomicU64; 2]);

/// One counter per 64-byte line: adjacent lines still form one 128-byte pair for the spatial prefetcher.
#[repr(align(64))]
struct Pad64(AtomicU64);

/// One counter per 128-byte block, as crossbeam's CachePadded does on x86-64.
#[repr(align(128))]
struct Pad128(AtomicU64);

const _: () = assert!(size_of::<Packed>() == 64 && size_of::<Pad64>() == 64 && size_of::<Pad128>() == 128);

fn hammer(c: &AtomicU64, iters: u64) {
    for _ in 0..iters {
        c.fetch_add(1, Ordering::Relaxed);
    }
}

/// Each of the two threads increments its own counter `iters` times. Returns the total.
fn two_threads(c0: &AtomicU64, c1: &AtomicU64, iters: u64) -> u64 {
    thread::scope(|s| {
        s.spawn(|| hammer(c0, iters));
        s.spawn(|| hammer(c1, iters));
    });
    c0.load(Ordering::Relaxed) + c1.load(Ordering::Relaxed)
}
// ---- false sharing ----

// ---- threads ----
const DT: f32 = 0.01;

/// One SoA particle step over a chunk: x += vx·dt, y += vy·dt.
fn step(x: &mut [f32], y: &mut [f32], vx: &[f32], vy: &[f32]) {
    for (((x, y), vx), vy) in x.iter_mut().zip(y.iter_mut()).zip(vx).zip(vy) {
        *x += vx * DT;
        *y += vy * DT;
    }
}

/// Split the SoA columns into `threads` disjoint chunks (whole multiples of 32 floats = 128 B; the columns
/// are 128-byte aligned, so no two threads write the same cache-line pair), and let each thread run `passes` steps over its chunk.
fn step_parallel(x: &mut [f32], y: &mut [f32], vx: &[f32], vy: &[f32], threads: usize, passes: usize) {
    let chunk = x.len().div_ceil(threads).next_multiple_of(32);
    thread::scope(|s| {
        let cols = x.chunks_mut(chunk).zip(y.chunks_mut(chunk)).zip(vx.chunks(chunk)).zip(vy.chunks(chunk));
        for (((x, y), vx), vy) in cols {
            s.spawn(move || {
                for _ in 0..passes {
                    step(x, y, vx, vy);
                }
            });
        }
    });
}
// ---- threads ----

/// SoA columns. A `Vec<f32>` is only 16-byte aligned (glibc malloc), so 128-byte chunk boundaries would fall
/// inside line pairs. Each column gets 31 floats of slack and starts at the first 128-byte boundary in it.
struct Soa {
    n: usize,
    cols: [(Vec<f32>, usize); 4], // (buffer, offset of the aligned start) for x, y, vx, vy
}

fn soa(n: usize) -> Soa {
    let col = |k: u32| {
        let mut v = vec![0.0_f32; n + 31];
        let off = (128 - v.as_ptr().addr() % 128) % 128 / 4;
        assert_eq!(v[off..].as_ptr().addr() % 128, 0);
        for (i, x) in v[off..off + n].iter_mut().enumerate() {
            *x = signed(hash(4 * i as u32 + k));
        }
        (v, off)
    };
    Soa { n, cols: [col(0), col(1), col(2), col(3)] }
}

impl Soa {
    /// The four columns as 128-byte-aligned slices of exactly `n` floats.
    fn cols(&mut self) -> (&mut [f32], &mut [f32], &[f32], &[f32]) {
        let n = self.n;
        let [(x, a), (y, b), (vx, c), (vy, d)] = &mut self.cols;
        (&mut x[*a..*a + n], &mut y[*b..*b + n], &vx[*c..*c + n], &vy[*d..*d + n])
    }
}

/// Order-sensitive checksum of the bits of a column.
fn bits_sum(v: &[f32]) -> u64 {
    v.iter().fold(0_u64, |h, x| h.rotate_left(5) ^ x.to_bits() as u64)
}

type Dot = fn(&[f32], &[f32]) -> f32;
type Pos = fn(&[f32]) -> (f32, u32);

fn main() {
    let args = parse_args();
    let dram = 16 * args.n; // DRAM control: 2 × 64 MiB of f32 at the default N
    const L1: usize = 4096; // 2 arrays × 16 KiB = 32 KiB  < 48 KiB L1d
    const L2: usize = 65536; // 2 arrays × 256 KiB = 512 KiB < 1.25 MiB L2
    #[cfg(target_arch = "x86_64")]
    let avx2 = is_x86_feature_detected!("avx2");
    #[cfg(not(target_arch = "x86_64"))]
    let avx2 = false;
    println!("ch08 rust: N={} quick={} avx2={avx2} threads available={:?}", args.n, args.quick, thread::available_parallelism().map(|n| n.get()));

    // ---- 1. dot product ----
    {
        let len = dram.max(L2);
        let a: Vec<f32> = (0..len as u32).map(|i| signed(hash(2 * i))).collect();
        let b: Vec<f32> = (0..len as u32).map(|i| signed(hash(2 * i + 1))).collect();
        let variants: [(&str, Dot); 4] = [
            ("naive (1 accumulator)", dot_naive),
            ("8 accumulators", dot_acc8),
            ("explicit SIMD (4x8 lanes)", dot_simd),
            ("reassociation allowed", dot_algebraic),
        ];
        for (id, size) in [("ch08-dot-l1", L1), ("ch08-dot-l2", L2), ("ch08-dot-dram", dram)] {
            let (a, b) = (&a[..size], &b[..size]);
            let reps = (dram / size).max(1);
            let exact: f64 = a.iter().zip(b).map(|(x, y)| *x as f64 * *y as f64).sum();
            let scale: f64 = a.iter().zip(b).map(|(x, y)| (*x as f64 * *y as f64).abs()).sum();
            println!("{id}: {size} floats x2 ({} KiB), {reps} reps, f64 reference {exact:.6}", size * 8 / 1024);
            for (label, f) in variants {
                let r = f(a, b);
                let err = (r as f64 - exact).abs();
                assert!(err <= 1e-3 * scale, "{label}: {r} too far from {exact}");
                let runs = bench_runs(|| {
                    let mut s = 0.0_f32;
                    for _ in 0..reps {
                        s += f(black_box(a), black_box(b));
                    }
                    s
                });
                let ns = runs[RUNS / 2].as_nanos() as f64 / (size * reps) as f64;
                println!("  {label:<27} {ns:>7.3} ns/elem  result {r:>14.6} (bits {:08x}, |err| {err:.2e})", r.to_bits());
                emit_bench(id, label, size * reps, &runs);
            }
            assert_eq!(dot_simd(a, b).to_bits(), dot_acc32(a, b).to_bits(), "AVX2 and its scalar fallback differ");
        }
    }

    // ---- 2. masks ----
    {
        let a: Vec<f32> = (0..L2 as u32).map(|i| signed(hash(i ^ 0x5bd1_e995))).collect();
        let reps = (dram / L2).max(1);
        let (s0, c0) = pos_branchy(&a);
        let (s1, c1) = pos_mask(&a);
        assert_eq!(c0, c1, "counts must match exactly");
        assert!((s0 - s1).abs() <= 1e-3 * s0, "sums too far apart");
        assert_eq!(pos_mask(&a).0.to_bits(), pos_lanes(&a).0.to_bits());
        println!("ch08-mask: {L2} floats, {reps} reps, count {c0} (both), sum branchy {s0:.4} vs mask {s1:.4}");
        let fs: [(&str, Pos); 2] = [("branchy scalar", pos_branchy), ("8-lane mask", pos_mask)];
        for (label, f) in fs {
            let runs = bench_runs(|| {
                let mut c = 0_u32;
                for _ in 0..reps {
                    let (s, n) = f(black_box(&a));
                    c = c.wrapping_add(n ^ s.to_bits()); // keep both results, so neither half can be dropped
                }
                c
            });
            println!("  {label:<27} {:>7.3} ns/elem", runs[RUNS / 2].as_nanos() as f64 / (L2 * reps) as f64);
            emit_bench("ch08-mask", label, L2 * reps, &runs);
        }
    }

    // ---- 3. false sharing ----
    {
        let iters: u64 = if args.quick { 1 << 14 } else { 1 << 24 };
        let n = iters as usize;
        let report = |label: &str, total: u64, want: u64, runs: &[Duration]| {
            assert_eq!(total, want, "{label}: lost increments");
            println!("  {label:<27} {:>7.3} ns per increment (wall), total {total}", runs[RUNS / 2].as_nanos() as f64 / iters as f64);
            emit_bench("ch08-false-sharing", label, n, runs);
        };
        println!("ch08-false-sharing: {iters} relaxed fetch_add per thread");
        let one = Pad128(AtomicU64::new(0));
        let runs = bench_runs(|| hammer(&one.0, iters));
        report("1 thread alone", one.0.load(Ordering::Relaxed), 8 * iters, &runs);
        let p = Packed([AtomicU64::new(0), AtomicU64::new(0)]);
        let runs = bench_runs(|| two_threads(&p.0[0], &p.0[1], iters));
        report("2 threads, same line", two_threads(&p.0[0], &p.0[1], 0), 16 * iters, &runs);
        let q = [Pad64(AtomicU64::new(0)), Pad64(AtomicU64::new(0))];
        let runs = bench_runs(|| two_threads(&q[0].0, &q[1].0, iters));
        report("2 threads, padded 64 B", two_threads(&q[0].0, &q[1].0, 0), 16 * iters, &runs);
        let r = [Pad128(AtomicU64::new(0)), Pad128(AtomicU64::new(0))];
        let runs = bench_runs(|| two_threads(&r[0].0, &r[1].0, iters));
        report("2 threads, padded 128 B", two_threads(&r[0].0, &r[1].0, 0), 16 * iters, &runs);
        println!("  addresses: packed {:p} {:p}, pad64 {:p} {:p}", &p.0[0], &p.0[1], &q[0], &q[1]);
    }

    // ---- 4. thread scaling ----
    {
        let mut sums = Vec::new();
        for threads in [1, 2, 4] {
            let mut s = soa(L2);
            let (x, y, vx, vy) = s.cols();
            step_parallel(x, y, vx, vy, threads, 3);
            sums.push(bits_sum(x) ^ bits_sum(y));
        }
        assert!(sums.iter().all(|&h| h == sums[0]), "thread count changed the result");
        println!("ch08-threads: checksum {:016x} for 1, 2 and 4 threads (identical)", sums[0]);
        let big = (dram / 2).max(L2);
        for (id, n, passes) in [("ch08-threads-l2", L2, (dram / L2).max(1)), ("ch08-threads-dram", big, 1)] {
            let mut s = soa(n);
            println!("{id}: {n} particles ({} KiB of SoA), {passes} passes", n * 16 / 1024);
            for threads in [1, 2, 4] {
                let runs = bench_runs(|| {
                    let (x, y, vx, vy) = s.cols();
                    step_parallel(x, y, vx, vy, threads, passes);
                    x[0]
                });
                let label = format!("{threads} thread{}", if threads == 1 { "" } else { "s" });
                println!("  {label:<27} {:>7.3} ns/particle-step", runs[RUNS / 2].as_nanos() as f64 / (n * passes) as f64);
                emit_bench(id, &label, n * passes, &runs);
            }
        }
    }
}
