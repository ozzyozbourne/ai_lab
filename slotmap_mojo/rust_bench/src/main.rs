//! Reference benchmark: Rust `slotmap::SlotMap<DefaultKey, u64>`.
//! Mirrors ../bench.mojo workload-for-workload (same PRNG, same op order,
//! same checksums) so the two can be compared line by line.
use slotmap::{DefaultKey, Key, SlotMap};
use std::hint::black_box;
use std::time::Instant;

struct Rng(u64);
impl Rng {
    #[inline(always)]
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    /// Uniform-ish integer in [0, n) via multiply-shift.
    #[inline(always)]
    fn below(&mut self, n: u64) -> u64 {
        (((self.next() >> 32) as u128 * n as u128) >> 32) as u64
    }
}

fn shuffle<T>(v: &mut [T], rng: &mut Rng) {
    let mut i = v.len();
    while i > 1 {
        let j = rng.below(i as u64) as usize;
        i -= 1;
        v.swap(i, j);
    }
}

type Map = SlotMap<DefaultKey, u64>;

fn build(n: usize) -> (Map, Vec<DefaultKey>) {
    let mut sm = Map::new();
    let mut keys = Vec::with_capacity(n);
    for i in 0..n {
        keys.push(sm.insert((i as u64).wrapping_mul(3).wrapping_add(1)));
    }
    (sm, keys)
}

#[inline(always)]
fn ffi(k: DefaultKey) -> u64 {
    k.data().as_ffi()
}

const CAL_ITERS: u64 = 50_000;

/// Calibration: a dependent shift-xor-multiply chain (5 cycles per iteration
/// on current x86 cores; it has no closed form the compiler could exploit). Its wall time tracks the core's current clock speed,
/// which lets results be reported in CPU cycles instead of nanoseconds.
#[inline(never)]
fn calib_once(seed: u64) -> (u64, u64) {
    let mut x = black_box(seed);
    let t = Instant::now();
    for _ in 0..CAL_ITERS {
        x = (x ^ (x >> 29)).wrapping_mul(0xBF58476D1CE4E5B9);
    }
    let e = t.elapsed().as_nanos() as u64;
    (e, black_box(x))
}

fn calib() -> f64 {
    let mut best = u64::MAX;
    for i in 0..3 {
        best = best.min(calib_once(i).0);
    }
    best as f64
}

/// Runs `f` `reps` times in batches bracketed by calibration runs. A batch
/// only counts if the clock speed was the same before and after it. Prints
/// name, n, cycles/op (best valid batch), checksum, raw best ns/op.
fn bench<F: FnMut(u64) -> (u64, u64)>(name: &str, n: usize, ops: usize, reps: usize, mut f: F) {
    let filter = std::env::args().nth(2).unwrap_or_default();
    if !filter.is_empty() && !filter.split(',').any(|p| name.contains(p)) {
        return;
    }
    let mut best_cyc = f64::MAX;
    let mut best_ns = u64::MAX;
    let mut chk = 0u64;
    let mut done = 0;
    while done < reps {
        let c0 = calib();
        let start = Instant::now();
        let mut bmin = u64::MAX;
        while done < reps && (bmin == u64::MAX || start.elapsed().as_nanos() < 20_000_000) {
            let (t, c) = f(done as u64);
            bmin = bmin.min(t);
            chk = chk.wrapping_add(c);
            done += 1;
        }
        let c1 = calib();
        best_ns = best_ns.min(bmin);
        if (c1 - c0).abs() <= 0.02 * c0 {
            let cyc = bmin as f64 / (0.5 * (c0 + c1)) * (CAL_ITERS * 5) as f64;
            best_cyc = best_cyc.min(cyc);
        }
    }
    if best_cyc == f64::MAX {
        best_cyc = f64::NAN;
    }
    println!(
        "{}\t{}\t{:.4}\t{}\t{:.4}",
        name,
        n,
        best_cyc / ops as f64,
        chk,
        best_ns as f64 / ops as f64
    );
}

fn run(n: usize, reps: usize) {
    bench("insert_grow", n, n, reps, |_rep| {
        let mut sm = Map::new();
        let mut chk = 0u64;
        let t = Instant::now();
        for i in 0..n {
            chk = chk.wrapping_add(ffi(sm.insert(i as u64)));
        }
        black_box(&sm);
        let e = t.elapsed().as_nanos() as u64;
        (e, chk.wrapping_add(sm.len() as u64))
    });

    bench("insert_reserved", n, n, reps, |_rep| {
        let mut sm = Map::with_capacity(n);
        let mut chk = 0u64;
        let t = Instant::now();
        for i in 0..n {
            chk = chk.wrapping_add(ffi(sm.insert(i as u64)));
        }
        black_box(&sm);
        let e = t.elapsed().as_nanos() as u64;
        (e, chk.wrapping_add(sm.len() as u64))
    });

    bench("get_seq", n, n, reps, |_rep| {
        let (sm, keys) = build(n);
        let mut sum = 0u64;
        let t = Instant::now();
        for &k in &keys {
            if let Some(v) = sm.get(k) {
                sum = sum.wrapping_add(*v);
            }
        }
        black_box(sum);
        (t.elapsed().as_nanos() as u64, sum)
    });

    bench("get_rand", n, n, reps, |rep| {
        let (sm, mut keys) = build(n);
        shuffle(&mut keys, &mut Rng(1 + 100 * rep));
        let mut sum = 0u64;
        let t = Instant::now();
        for &k in &keys {
            if let Some(v) = sm.get(k) {
                sum = sum.wrapping_add(*v);
            }
        }
        black_box(sum);
        (t.elapsed().as_nanos() as u64, sum)
    });

    bench("get_mixed_rand", n, n, reps, |rep| {
        let (mut sm, mut keys) = build(n);
        shuffle(&mut keys, &mut Rng(2 + 100 * rep));
        for &k in &keys[..n / 2] {
            sm.remove(k);
        }
        shuffle(&mut keys, &mut Rng(3 + 100 * rep));
        let mut sum = 0u64;
        let t = Instant::now();
        for &k in &keys {
            if let Some(v) = sm.get(k) {
                sum = sum.wrapping_add(*v);
            }
        }
        black_box(sum);
        (t.elapsed().as_nanos() as u64, sum)
    });

    bench("iter_values_full", n, n, reps, |_rep| {
        let (sm, _keys) = build(n);
        let mut sum = 0u64;
        let t = Instant::now();
        for v in sm.values() {
            sum = sum.wrapping_add(*v);
        }
        black_box(sum);
        (t.elapsed().as_nanos() as u64, sum)
    });

    bench("iter_values_half", n, n, reps, |rep| {
        let (mut sm, mut keys) = build(n);
        shuffle(&mut keys, &mut Rng(4 + 100 * rep));
        for &k in &keys[..n / 2] {
            sm.remove(k);
        }
        let mut sum = 0u64;
        let t = Instant::now();
        for v in sm.values() {
            sum = sum.wrapping_add(*v);
        }
        black_box(sum);
        (t.elapsed().as_nanos() as u64, sum)
    });

    bench("iter_kv_half", n, n, reps, |rep| {
        let (mut sm, mut keys) = build(n);
        shuffle(&mut keys, &mut Rng(5 + 100 * rep));
        for &k in &keys[..n / 2] {
            sm.remove(k);
        }
        let mut sum = 0u64;
        let t = Instant::now();
        for (k, v) in sm.iter() {
            sum = sum.wrapping_add(*v ^ ffi(k));
        }
        black_box(sum);
        (t.elapsed().as_nanos() as u64, sum)
    });

    bench("remove_seq", n, n, reps, |_rep| {
        let (mut sm, keys) = build(n);
        let mut sum = 0u64;
        let t = Instant::now();
        for &k in &keys {
            if let Some(v) = sm.remove(k) {
                sum = sum.wrapping_add(v);
            }
        }
        black_box(&sm);
        let e = t.elapsed().as_nanos() as u64;
        (e, sum.wrapping_add(sm.len() as u64))
    });

    bench("remove_rand", n, n, reps, |rep| {
        let (mut sm, mut keys) = build(n);
        shuffle(&mut keys, &mut Rng(6 + 100 * rep));
        let mut sum = 0u64;
        let t = Instant::now();
        for &k in &keys {
            if let Some(v) = sm.remove(k) {
                sum = sum.wrapping_add(v);
            }
        }
        black_box(&sm);
        let e = t.elapsed().as_nanos() as u64;
        (e, sum.wrapping_add(sm.len() as u64))
    });

    bench("reinsert_rand", n, n, reps, |rep| {
        let (mut sm, mut keys) = build(n);
        shuffle(&mut keys, &mut Rng(7 + 100 * rep));
        for &k in &keys {
            sm.remove(k);
        }
        let mut chk = 0u64;
        let t = Instant::now();
        for i in 0..n {
            chk = chk.wrapping_add(ffi(sm.insert(i as u64)));
        }
        black_box(&sm);
        let e = t.elapsed().as_nanos() as u64;
        (e, chk.wrapping_add(sm.len() as u64))
    });

    bench("churn", n, n, reps, |rep| {
        let (mut sm, mut keys) = build(n);
        let mut rng = Rng(8 + 100 * rep);
        let mut sum = 0u64;
        let t = Instant::now();
        for i in 0..n {
            let j = rng.below(n as u64) as usize;
            if let Some(v) = sm.remove(keys[j]) {
                sum = sum.wrapping_add(v);
            }
            let k = sm.insert(i as u64);
            keys[j] = k;
            sum = sum.wrapping_add(ffi(k));
        }
        black_box(&sm);
        let e = t.elapsed().as_nanos() as u64;
        (e, sum.wrapping_add(sm.len() as u64))
    });
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let scale: f64 = args.get(1).map(|s| s.parse().unwrap()).unwrap_or(1.0);
    for &n in &[1_000usize, 100_000, 2_000_000] {
        let reps = ((2.0e7 * scale) as usize / n).clamp(7, 3000);
        run(n, reps);
    }
}
