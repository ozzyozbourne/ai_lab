//! Chapter 7: branches, batches and existence.
//!
//! 1. Branches: a filter (stream compaction) over L1/L2-resident data, branchy vs branchless,
//!    swept over predictability: keep 0..100% of random values, sorted, period-k patterns.
//!    Plus the famous "sum if x < t" loop on random vs sorted data.
//! 2. Existence: "alive" as a field + `if`, as an out-of-band bool array, as a bit set, and as
//!    membership in an alive table (rows moved with swap-and-pop). Same checksum.
//! 3. Batches: one pipeline, three dynamically dispatched stages, batch size 1 .. N.
//! 4. Lookup: classify bytes with comparisons vs a 256-entry table.
//!
//! Run: `cargo run --release -q -p ch07_branches_batches_existence -- [N] [--quick]`

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

// ---- shared: the same generator and seeds as the Zig and Odin programs ----

/// splitmix64. All three programs use it with the same seeds, so they build identical
/// inputs and print identical checksums.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    /// Integer in 0..n (multiply-high, no division).
    fn below(&mut self, n: u64) -> u64 {
        ((self.next() as u128 * n as u128) >> 64) as u64
    }
}

// =====================================================================================
// 1. Branches: a filter (stream compaction) with a predictable or unpredictable branch
// =====================================================================================

/// Branchy: push `x` into the output only when it passes. The store itself is conditional,
/// so the compiler cannot turn this into a conditional move: it must keep the jump.
#[inline(never)]
fn filter_branchy(input: &[u32], t: u32, out: &mut [u32]) -> usize {
    let mut n = 0;
    for &x in input {
        if x < t {
            out[n] = x;
            n += 1;
        }
    }
    n
}

/// Branchless: always write, then advance the cursor by 0 or 1. `out` must be as long as
/// `input`. `select_unpredictable` asks for a conditional move instead of a jump.
#[inline(never)]
fn filter_branchless(input: &[u32], t: u32, out: &mut [u32]) -> usize {
    let mut n = 0;
    for &x in input {
        out[n] = x;
        n = std::hint::select_unpredictable(x < t, n + 1, n);
    }
    n
}

/// The famous sorted-array loop: sum the elements below `t`. No store depends on the
/// condition, so the optimizer is free to make it branchless (and vectorize it).
#[inline(never)]
fn sum_if(input: &[u32], t: u32) -> u64 {
    let mut s = 0u64;
    for &x in input {
        if x < t {
            s += x as u64;
        }
    }
    s
}

/// Values in 0..100. Keeping `x < p` keeps about p% of them, in random order.
fn random_values(n: usize, rng: &mut Rng) -> Vec<u32> {
    (0..n).map(|_| rng.below(100) as u32).collect()
}

/// A pattern of `k` random keep/drop decisions, repeated. Keeping `x < 50` keeps half.
/// Short periods are learnable by the predictor; long ones look random.
fn periodic_values(n: usize, k: usize, rng: &mut Rng) -> Vec<u32> {
    let bits: Vec<bool> = (0..k).map(|_| rng.next() & 1 == 1).collect();
    (0..n)
        .map(|i| {
            let r = rng.below(50) as u32;
            if bits[i % k] { r } else { 50 + r }
        })
        .collect()
}

/// Runs both filters `reps` times over `input`, checks they agree, emits two BENCH lines.
/// `x_n` and `scale` let a sweep report "time per period" or "time per element" honestly:
/// the reported ns are the measured ns for `reps * input.len()` elements times `scale`.
#[allow(clippy::too_many_arguments)]
fn filter_pair(
    id: &str,
    labels: [&str; 2],
    input: &[u32],
    t: u32,
    reps: usize,
    out: &mut [u32],
    x_n: usize,
    scale: f64,
) -> (Duration, Duration) {
    let mut kept = [0usize; 2];
    let mut sums = [0u64; 2];
    let mut med = [Duration::ZERO; 2];
    for (v, label) in labels.iter().enumerate() {
        let f = if v == 0 { filter_branchy } else { filter_branchless };
        let runs = bench_runs(|| {
            let mut total = 0;
            for _ in 0..reps {
                total += f(black_box(input), black_box(t), out);
            }
            total
        });
        kept[v] = f(input, t, out);
        sums[v] = out[..kept[v]].iter().map(|&x| x as u64).sum();
        med[v] = runs[RUNS / 2];
        let scaled: Vec<Duration> = runs.iter().map(|d| d.mul_f64(scale)).collect();
        emit_bench(id, label, x_n, &scaled);
    }
    assert_eq!((kept[0], sums[0]), (kept[1], sums[1]), "{id}: filters disagree");
    (med[0], med[1])
}

fn branches(quick: bool) {
    let n = if quick { 1 << 12 } else { 1 << 16 }; // 16 KiB (L1) or 256 KiB (L2) of u32, same again for output
    let reps = if quick { 16 } else { (1 << 20) / n };
    let total = n * reps;
    let mut out = vec![0u32; n];
    let per_elem = |d: Duration| d.as_nanos() as f64 / total as f64;
    println!("== branches: filter {n} u32 values ({} KiB), {reps} passes per run", n * 4 / 1024);

    // (a) random values, keep p% of them
    let mut rng = Rng(7);
    let vals = random_values(n, &mut rng);
    println!("  keep%  branchy ns/elem  branchless ns/elem");
    for p in (0..=100).step_by(10) {
        let labels = [format!("branchy {p}%"), format!("branchless {p}%")];
        let (a, b) = filter_pair("ch07-predict", [&labels[0], &labels[1]], &vals, p, reps, &mut out, total, 1.0);
        println!("  {p:>4}%  {:>15.2}  {:>18.2}", per_elem(a), per_elem(b));
    }

    // (b) the same values sorted: the branch flips once
    let mut sorted = vals.clone();
    sorted.sort_unstable();
    let (rb, rl) = filter_pair("ch07-patterns", ["branchy, random", "branchless, random"], &vals, 50, reps, &mut out, total, 1.0);
    let (sb, sl) = filter_pair("ch07-patterns", ["branchy, sorted", "branchless, sorted"], &sorted, 50, reps, &mut out, total, 1.0);
    println!(
        "  keep 50%: branchy random {:.2} / sorted {:.2} ns/elem, branchless random {:.2} / sorted {:.2}",
        per_elem(rb), per_elem(sb), per_elem(rl), per_elem(sl)
    );

    // (c) the sorted-array demo itself: sum the elements below 50
    let mut s = [0u64; 2];
    for (i, (data, label)) in [(&vals, "if-sum, random"), (&sorted, "if-sum, sorted")].into_iter().enumerate() {
        let runs = bench_runs(|| (0..reps).map(|_| sum_if(black_box(data), black_box(50))).sum::<u64>());
        s[i] = sum_if(data, 50);
        emit_bench("ch07-patterns", label, total, &runs);
        println!("  {label}: {:.2} ns/elem", per_elem(runs[RUNS / 2]));
    }
    assert_eq!(s[0], s[1], "sum_if: sorting changed the sum");

    // (d) period-k patterns, keep 50%: where does the predictor stop learning?
    println!("  period k  branchy ns/elem  branchless ns/elem");
    let mut k = 2;
    while k <= n {
        let mut rng = Rng(11 + k as u64);
        let data = periodic_values(n, k, &mut rng);
        // report time per period: n = k, ns scaled by k / total
        let (a, b) = filter_pair("ch07-period", ["branchy", "branchless"], &data, 50, reps, &mut out, k, k as f64 / total as f64);
        println!("  {k:>8}  {:>15.2}  {:>18.2}", per_elem(a), per_elem(b));
        k *= 4;
    }
    println!("  checksums: branchy == branchless for every pattern (asserted)");
}

// =====================================================================================
// 2. Existence: where does "alive" live?
// =====================================================================================

/// Version 1: the flag is a field. 17 bytes of data, 20 with padding.
#[derive(Clone, Copy)]
struct Entity {
    x: i32,
    y: i32,
    vx: i32,
    vy: i32,
    alive: bool,
}

/// Versions 2-4: the same data without the flag. 16 bytes.
#[derive(Clone, Copy)]
struct Body {
    x: i32,
    y: i32,
    vx: i32,
    vy: i32,
}

const _: () = assert!(size_of::<Entity>() == 20);
const _: () = assert!(size_of::<Body>() == 16);

fn body(rng: &mut Rng) -> Body {
    let mut c = || rng.below(2001) as i32 - 1000;
    Body { x: c(), y: c(), vx: c() / 100, vy: c() / 100 }
}

/// Does entity `id` die during setup? A hash, so all three programs agree.
fn dies(id: u32, dead_pct: u64) -> bool {
    Rng(id as u64 ^ 0xD1E).next() % 100 < dead_pct
}

#[inline(never)]
fn update_flag(es: &mut [Entity]) {
    for e in es {
        if e.alive {
            e.x += e.vx;
            e.y += e.vy;
        }
    }
}

#[inline(never)]
fn update_bool_array(bodies: &mut [Body], alive: &[bool]) {
    for (b, &a) in bodies.iter_mut().zip(alive) {
        if a {
            b.x += b.vx;
            b.y += b.vy;
        }
    }
}

/// Out-of-band bits: visit only the set bits, 64 entities per word.
#[inline(never)]
fn update_bitset(bodies: &mut [Body], alive: &[u64]) {
    for (w, &word) in alive.iter().enumerate() {
        let mut m = word;
        while m != 0 {
            let b = &mut bodies[w * 64 + m.trailing_zeros() as usize];
            b.x += b.vx;
            b.y += b.vy;
            m &= m - 1; // clear the lowest set bit
        }
    }
}

/// A table per state. The rows of `ids` and `bodies` move together.
#[derive(Default)]
struct Table {
    ids: Vec<u32>,
    bodies: Vec<Body>,
}

impl Table {
    fn push(&mut self, id: u32, b: Body) {
        self.ids.push(id);
        self.bodies.push(b);
    }
    /// Swap-and-pop: the last row moves into the hole. O(1), and the table stays dense.
    fn swap_remove(&mut self, row: usize) -> (u32, Body) {
        (self.ids.swap_remove(row), self.bodies.swap_remove(row))
    }
}

/// Changing state is moving a row from one table to another.
fn kill_where(alive: &mut Table, dead: &mut Table, pred: impl Fn(u32) -> bool) {
    let mut row = 0;
    while row < alive.ids.len() {
        if pred(alive.ids[row]) {
            let (id, b) = alive.swap_remove(row);
            dead.push(id, b);
            // do not advance: the row now holds what was the last element
        } else {
            row += 1;
        }
    }
}

/// Existence: no flag, no branch. Every row in this table is alive.
#[inline(never)]
fn update_alive(alive: &mut [Body]) {
    for b in alive {
        b.x += b.vx;
        b.y += b.vy;
    }
}

fn mix(acc: u64, b: &Body) -> u64 {
    acc.wrapping_add((b.x as i64 * 3 + b.y as i64) as u64)
}

fn existence(n: usize, dead_pct: u64, id: &str) {
    let mut rng = Rng(42);
    let bodies: Vec<Body> = (0..n).map(|_| body(&mut rng)).collect();

    // 1. flag in the struct
    let mut ents: Vec<Entity> = bodies
        .iter()
        .enumerate()
        .map(|(i, b)| Entity { x: b.x, y: b.y, vx: b.vx, vy: b.vy, alive: !dies(i as u32, dead_pct) })
        .collect();
    // 2. out-of-band bool array
    let mut b2 = bodies.clone();
    let alive2: Vec<bool> = (0..n).map(|i| !dies(i as u32, dead_pct)).collect();
    // 3. out-of-band bit set
    let mut b3 = bodies.clone();
    let mut bits = vec![0u64; n.div_ceil(64)];
    for i in (0..n).filter(|&i| !dies(i as u32, dead_pct)) {
        bits[i / 64] |= 1 << (i % 64);
    }
    // 4. one table per state, filled by moving rows with swap-and-pop
    let mut alive = Table::default();
    let mut dead = Table::default();
    for (i, &b) in bodies.iter().enumerate() {
        alive.push(i as u32, b);
    }
    kill_where(&mut alive, &mut dead, |i| dies(i, dead_pct));

    let live = alive.ids.len();
    println!(
        "== existence: {n} entities, {live} alive ({}%), Entity {} B, Body {} B",
        100 - dead_pct,
        size_of::<Entity>(),
        size_of::<Body>()
    );
    println!(
        "  bytes read per update: flag {} | bool array {} | bitset {} + {} | table {}",
        n * size_of::<Entity>(),
        n * (size_of::<Body>() + 1),
        live * size_of::<Body>(),
        bits.len() * 8,
        live * size_of::<Body>()
    );

    let r1 = bench_runs(|| update_flag(black_box(&mut ents)));
    let r2 = bench_runs(|| update_bool_array(black_box(&mut b2), &alive2));
    let r3 = bench_runs(|| update_bitset(black_box(&mut b3), &bits));
    let r4 = bench_runs(|| update_alive(black_box(&mut alive.bodies)));

    // 8 updates each (1 warm-up + 7 timed). Same entities alive, so the same checksum.
    let c1 = ents.iter().filter(|e| e.alive).fold(0, |a, e| mix(a, &Body { x: e.x, y: e.y, vx: 0, vy: 0 }));
    let c2 = b2.iter().zip(&alive2).filter(|p| *p.1).fold(0, |a, p| mix(a, p.0));
    let c3 = (0..n).filter(|&i| bits[i / 64] >> (i % 64) & 1 == 1).fold(0, |a, i| mix(a, &b3[i]));
    let c4 = alive.bodies.iter().fold(0, mix);
    for (label, runs, c) in [
        ("flag in struct + if", r1, c1),
        ("bool array + if", r2, c2),
        ("bitset, set bits only", r3, c3),
        ("alive table, no branch", r4, c4),
    ] {
        println!("  {label:<24} {:>8.2} ns/entity  checksum {c:#018x}", runs[RUNS / 2].as_nanos() as f64 / n as f64);
        emit_bench(id, label, n, &runs);
    }
    assert!(c1 == c2 && c2 == c3 && c3 == c4, "existence: checksums differ");
    assert_eq!(dead.ids.len() + live, n);
}

/// A dirty list: remember *which* rows changed, once each, instead of a dirty flag per row
/// that every consumer has to scan for.
struct DirtyList {
    seen: Vec<u64>, // one bit per row: already listed?
    rows: Vec<u32>,
}

impl DirtyList {
    fn new(n: usize) -> Self {
        DirtyList { seen: vec![0; n.div_ceil(64)], rows: Vec::new() }
    }
    fn mark(&mut self, row: u32) {
        let (w, bit) = (row as usize / 64, 1u64 << (row % 64));
        if self.seen[w] & bit == 0 {
            self.seen[w] |= bit;
            self.rows.push(row);
        }
    }
    /// Hand the dirty rows to `f`, then forget them. Cost: O(dirty), not O(rows).
    fn drain(&mut self, mut f: impl FnMut(u32)) {
        for &row in &self.rows {
            f(row);
            self.seen[row as usize / 64] &= !(1u64 << (row % 64));
        }
        self.rows.clear();
    }
}

fn dirty_demo(n: usize) {
    let mut rng = Rng(5);
    let mut d = DirtyList::new(n);
    for _ in 0..n / 8 {
        d.mark(rng.below(n as u64 / 4) as u32); // repeats are common: listed once
    }
    let (mut count, mut sum) = (0u64, 0u64);
    d.drain(|row| {
        count += 1;
        sum += row as u64;
    });
    println!("== dirty list: {} marks over {} rows -> {count} distinct dirty rows, row sum {sum}", n / 8, n / 4);
}

/// Several bools per entity, packed into one byte of flags, kept out of band in their own column.
const ALIVE: u8 = 1 << 0;
const VISIBLE: u8 = 1 << 1;
const DIRTY: u8 = 1 << 2;
#[allow(dead_code)]
const SELECTED: u8 = 1 << 3;

fn flags_demo(n: usize) {
    let mut rng = Rng(9);
    let flags: Vec<u8> = (0..n).map(|_| (rng.next() & 0xF) as u8).collect();
    let want = ALIVE | VISIBLE;
    let count = flags.iter().filter(|&&f| f & (want | DIRTY) == want).count();
    println!("== flags: {n} entities x 1 B of flags (4 separate bools: 4 B); alive, visible and clean: {count}");
}

// =====================================================================================
// 3. Batches: the same pipeline, items pushed through in batches of size B
// =====================================================================================

/// One stage of a tiny vectorised interpreter (X100-style): it processes a whole batch per call.
trait Op {
    fn run(&self, base: u64, inp: &[u64], out: &mut [u64]);
}

struct Gen;
struct Mix;
struct Scale(u64);

impl Op for Gen {
    fn run(&self, base: u64, _inp: &[u64], out: &mut [u64]) {
        for (i, o) in out.iter_mut().enumerate() {
            *o = (base + i as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        }
    }
}
impl Op for Mix {
    fn run(&self, _base: u64, inp: &[u64], out: &mut [u64]) {
        for (o, &x) in out.iter_mut().zip(inp) {
            *o = x ^ (x >> 29);
        }
    }
}
impl Op for Scale {
    fn run(&self, _base: u64, inp: &[u64], out: &mut [u64]) {
        for (o, &x) in out.iter_mut().zip(inp) {
            *o = x.wrapping_mul(self.0);
        }
    }
}

/// Push `total` items through gen -> mix -> scale -> sum, `batch` at a time.
/// Per batch: three dynamic calls and a sum. Working set: two buffers of `batch` u64.
#[inline(never)]
fn run_pipeline(ops: &[&dyn Op], total: usize, batch: usize, a: &mut [u64], b: &mut [u64]) -> u64 {
    let mut sum = 0u64;
    let mut base = 0;
    while base < total {
        let len = batch.min(total - base);
        let (a, b) = (&mut a[..len], &mut b[..len]);
        ops[0].run(base as u64, &[], a);
        ops[1].run(base as u64, a, b);
        ops[2].run(base as u64, b, a);
        sum = a.iter().fold(sum, |s, &x| s.wrapping_add(x));
        base += len;
    }
    sum
}

fn batches(quick: bool) {
    let total = if quick { 1 << 16 } else { 1 << 22 };
    let ops: [&dyn Op; 3] = [&Gen, &Mix, &Scale(0xBF58_476D_1CE4_E5B9)];
    println!("== batches: {total} items through 3 stages; per item ns by batch size (working set = 16 B x batch)");
    let mut first = None;
    let mut batch = 1;
    while batch <= total {
        let mut a = vec![0u64; batch];
        let mut b = vec![0u64; batch];
        let runs = bench_runs(|| run_pipeline(black_box(&ops), total, batch, &mut a, &mut b));
        let sum = run_pipeline(black_box(&ops), total, batch, &mut a, &mut b);
        assert_eq!(*first.get_or_insert(sum), sum, "batch size changed the result");
        // n = batch size; ns = time per batch, so ns/n is time per item
        let scaled: Vec<Duration> = runs.iter().map(|d| d.mul_f64(batch as f64 / total as f64)).collect();
        emit_bench("ch07-batch", "pipeline", batch, &scaled);
        println!(
            "  batch {batch:>8} ({:>9} B): {:>6.2} ns/item  checksum {sum:#018x}",
            16 * batch,
            runs[RUNS / 2].as_nanos() as f64 / total as f64
        );
        batch *= 4;
    }
}

// =====================================================================================
// 4. Lookup tables: classify bytes with comparisons or with a 256-entry table
// =====================================================================================

#[inline(never)]
fn count_ident_branchy(text: &[u8]) -> usize {
    text.iter().filter(|&&c| c.is_ascii_alphanumeric() || c == b'_').count()
}

/// Built at compile time: 1 for [A-Za-z0-9_], else 0.
const IDENT: [u8; 256] = {
    let mut t = [0u8; 256];
    let mut c = 0;
    while c < 256 {
        let b = c as u8;
        t[c] = (b.is_ascii_alphanumeric() || b == b'_') as u8;
        c += 1;
    }
    t
};

#[inline(never)]
fn count_ident_lut(text: &[u8]) -> usize {
    text.iter().map(|&c| IDENT[c as usize] as usize).sum()
}

fn lookup(quick: bool) {
    let n = if quick { 1 << 12 } else { 1 << 16 };
    let reps = 16;
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ (){}[];.,+-*/=<>\n\t\"'";
    let mut rng = Rng(3);
    let text: Vec<u8> = (0..n).map(|_| ALPHABET[rng.below(ALPHABET.len() as u64) as usize]).collect();
    let r1 = bench_runs(|| (0..reps).map(|_| count_ident_branchy(black_box(&text))).sum::<usize>());
    let r2 = bench_runs(|| (0..reps).map(|_| count_ident_lut(black_box(&text))).sum::<usize>());
    let (c1, c2) = (count_ident_branchy(&text), count_ident_lut(&text));
    assert_eq!(c1, c2);
    let total = n * reps;
    println!("== lookup: {n} bytes, {c1} identifier bytes");
    for (label, runs) in [("comparisons", r1), ("256-entry table", r2)] {
        println!("  {label:<16} {:.3} ns/byte", runs[RUNS / 2].as_nanos() as f64 / total as f64);
        emit_bench("ch07-lut", label, total, &runs);
    }
}

fn main() {
    let args = parse_args();
    branches(args.quick);
    existence(args.n, 50, "ch07-exist");
    existence(args.n, 90, "ch07-exist-10");
    dirty_demo(args.n);
    flags_demo(args.n);
    batches(args.quick);
    lookup(args.quick);
}
