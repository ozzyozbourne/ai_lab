//! Chapter 4: one particle update in four layouts (AoS, hot/cold, SoA, AoSoA) plus three controls:
//! read every field (AoS catches up), random whole-record reads (AoS wins), and 16 page-aligned
//! columns versus staggered columns (cache-set aliasing). Every variant of one experiment must print
//! the same checksum, in all three languages.
//!
//!   cargo run --release -q -p ch04_aos_soa_hot_cold -- [N] [--quick]
//!
//! Sizes: N/64, N and 4N particles (default N = 1 << 20; --quick caps N at 4096).

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

/// A power of two, so `v * DT` is exact and fused or unfused multiply-add give the same bits.
const DT: f32 = 1.0 / 64.0;
/// AoSoA block width: eight f32 lanes, one AVX2 register.
const LANES: usize = 8;

// ---- the data: a fat 64-byte particle ----
/// Sixteen 4-byte fields. The update reads 6 of them (24 B) and writes 3.
#[derive(Clone, Copy, Default)]
#[repr(align(64))] // one particle = exactly one cache line
struct Particle {
    px: f32, py: f32, pz: f32, // hot: read and written every frame
    vx: f32, vy: f32, vz: f32, // hot: read every frame
    mass: f32, age: f32, life: f32, size: f32, // cold from here on
    color: u32, id: u32, flags: u32, seed: u32, emitter: u32, group: u32,
}
const _: () = assert!(size_of::<Particle>() == 64);

/// lowbias32 (Chris Wellons): the same integer hash in all three languages, so the data is identical.
fn hash(mut x: u32) -> u32 {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb_352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846c_a68b);
    x ^ (x >> 16)
}

/// 24 random bits as an exact f32 in [0, 1).
fn unit(h: u32) -> f32 {
    (h >> 8) as f32 / 16_777_216.0
}

fn particle(i: usize) -> Particle {
    let i = i as u32;
    let h = |f: u32| hash(i.wrapping_mul(16).wrapping_add(f));
    Particle {
        px: unit(h(0)) * 128.0, py: unit(h(1)) * 128.0, pz: unit(h(2)) * 128.0,
        vx: unit(h(3)) - 0.5, vy: unit(h(4)) - 0.5, vz: unit(h(5)) - 0.5,
        mass: unit(h(6)) + 1.0, age: unit(h(7)), life: unit(h(8)) * 4.0, size: unit(h(9)),
        color: h(10), id: i, flags: h(12) & 0xff, seed: h(13), emitter: h(14) & 63, group: h(15) & 7,
    }
}

/// The record checksum: the bit patterns of all 16 fields, summed as integers (exact, any order).
fn field_sum(p: &Particle) -> u64 {
    let (f, u) = (|x: f32| x.to_bits() as u64, |x: u32| x as u64);
    f(p.px) + f(p.py) + f(p.pz) + f(p.vx) + f(p.vy) + f(p.vz) + f(p.mass) + f(p.age) + f(p.life) + f(p.size)
        + u(p.color) + u(p.id) + u(p.flags) + u(p.seed) + u(p.emitter) + u(p.group)
}

fn pos_sum(p: &Particle) -> u64 {
    [p.px, p.py, p.pz].map(|x| x.to_bits() as u64).iter().sum()
}

/// Every layout answers the same four questions.
trait Layout {
    const LABEL: &'static str;
    /// Bytes the update loop pulls through the cache per particle (model: whole lines, sequential).
    const UPDATE_BYTES: usize;
    fn build(n: usize) -> Self;
    /// pos += vel * dt for every particle.
    fn update(&mut self, dt: f32);
    /// Gather one whole record (AoS view of particle i).
    fn get(&self, i: usize) -> Particle;
    fn len(&self) -> usize;
    /// Sum of every field of every particle, in index order.
    fn every(&self) -> u64 {
        (0..self.len()).map(|i| field_sum(&self.get(i))).fold(0, u64::wrapping_add)
    }
}

// ---- 1. AoS ----
struct Aos {
    ps: Vec<Particle>,
}
impl Layout for Aos {
    const LABEL: &'static str = "AoS";
    const UPDATE_BYTES: usize = 64;
    fn build(n: usize) -> Self {
        Aos { ps: (0..n).map(particle).collect() }
    }
    fn update(&mut self, dt: f32) {
        for p in &mut self.ps {
            p.px += p.vx * dt;
            p.py += p.vy * dt;
            p.pz += p.vz * dt;
        }
    }
    fn get(&self, i: usize) -> Particle {
        self.ps[i]
    }
    fn len(&self) -> usize {
        self.ps.len()
    }
    fn every(&self) -> u64 {
        self.ps.iter().map(field_sum).fold(0, u64::wrapping_add)
    }
}

// ---- 2. hot/cold split: two parallel Vecs, same index ----
#[derive(Clone, Copy, Default)]
struct Hot {
    px: f32, py: f32, pz: f32,
    vx: f32, vy: f32, vz: f32,
}
#[derive(Clone, Copy, Default)]
struct Cold {
    mass: f32, age: f32, life: f32, size: f32,
    color: u32, id: u32, flags: u32, seed: u32, emitter: u32, group: u32,
}
const _: () = assert!(size_of::<Hot>() == 24 && size_of::<Cold>() == 40);

struct HotCold {
    hot: Vec<Hot>,
    cold: Vec<Cold>,
}
impl Layout for HotCold {
    const LABEL: &'static str = "hot/cold";
    const UPDATE_BYTES: usize = 24;
    fn build(n: usize) -> Self {
        let (hot, cold) = (0..n)
            .map(|i| {
                let p = particle(i);
                let h = Hot { px: p.px, py: p.py, pz: p.pz, vx: p.vx, vy: p.vy, vz: p.vz };
                let c = Cold {
                    mass: p.mass, age: p.age, life: p.life, size: p.size, color: p.color,
                    id: p.id, flags: p.flags, seed: p.seed, emitter: p.emitter, group: p.group,
                };
                (h, c)
            })
            .unzip();
        HotCold { hot, cold }
    }
    fn update(&mut self, dt: f32) {
        for h in &mut self.hot {
            h.px += h.vx * dt;
            h.py += h.vy * dt;
            h.pz += h.vz * dt;
        }
    }
    fn get(&self, i: usize) -> Particle {
        HotCold::join(&self.hot[i], &self.cold[i])
    }
    fn len(&self) -> usize {
        self.hot.len()
    }
    fn every(&self) -> u64 {
        // Walk both arrays in lockstep: zipped iterators, no bounds checks (like the other layouts).
        let rows = self.hot.iter().zip(&self.cold);
        rows.map(|(h, c)| field_sum(&HotCold::join(h, c))).fold(0, u64::wrapping_add)
    }
}
impl HotCold {
    /// Glue one hot and one cold record back into a whole particle.
    fn join(h: &Hot, c: &Cold) -> Particle {
        Particle {
            px: h.px, py: h.py, pz: h.pz, vx: h.vx, vy: h.vy, vz: h.vz,
            mass: c.mass, age: c.age, life: c.life, size: c.size, color: c.color,
            id: c.id, flags: c.flags, seed: c.seed, emitter: c.emitter, group: c.group,
        }
    }
}

// ---- 3. SoA, hand-written: one Vec per field ----
#[derive(Default)]
struct Soa {
    px: Vec<f32>, py: Vec<f32>, pz: Vec<f32>,
    vx: Vec<f32>, vy: Vec<f32>, vz: Vec<f32>,
    mass: Vec<f32>, age: Vec<f32>, life: Vec<f32>, size: Vec<f32>,
    color: Vec<u32>, id: Vec<u32>, flags: Vec<u32>, seed: Vec<u32>, emitter: Vec<u32>, group: Vec<u32>,
}
impl Soa {
    fn push(&mut self, p: Particle) {
        self.px.push(p.px); self.py.push(p.py); self.pz.push(p.pz);
        self.vx.push(p.vx); self.vy.push(p.vy); self.vz.push(p.vz);
        self.mass.push(p.mass); self.age.push(p.age); self.life.push(p.life); self.size.push(p.size);
        self.color.push(p.color); self.id.push(p.id); self.flags.push(p.flags);
        self.seed.push(p.seed); self.emitter.push(p.emitter); self.group.push(p.group);
    }
}
impl Layout for Soa {
    const LABEL: &'static str = "SoA";
    const UPDATE_BYTES: usize = 24;
    fn build(n: usize) -> Self {
        let mut s = Soa::default();
        (0..n).for_each(|i| s.push(particle(i)));
        s
    }
    fn update(&mut self, dt: f32) {
        // No multi-slice `for` in Rust: zip the columns. Disjoint field borrows are fine.
        let pos = self.px.iter_mut().zip(&mut self.py).zip(&mut self.pz);
        let vel = self.vx.iter().zip(&self.vy).zip(&self.vz);
        for (((x, y), z), ((vx, vy), vz)) in pos.zip(vel) {
            *x += vx * dt;
            *y += vy * dt;
            *z += vz * dt;
        }
    }
    fn get(&self, i: usize) -> Particle {
        Particle {
            px: self.px[i], py: self.py[i], pz: self.pz[i],
            vx: self.vx[i], vy: self.vy[i], vz: self.vz[i],
            mass: self.mass[i], age: self.age[i], life: self.life[i], size: self.size[i],
            color: self.color[i], id: self.id[i], flags: self.flags[i],
            seed: self.seed[i], emitter: self.emitter[i], group: self.group[i],
        }
    }
    fn len(&self) -> usize {
        self.px.len()
    }
    fn every(&self) -> u64 {
        // Row by row over 16 columns. Re-slicing every column to n proves the lengths once,
        // so the loop has no bounds checks (a plain self.get(i) loop pays 16 per record).
        let n = self.px.len();
        let f = [&self.px, &self.py, &self.pz, &self.vx, &self.vy, &self.vz, &self.mass, &self.age, &self.life, &self.size];
        let u = [&self.color, &self.id, &self.flags, &self.seed, &self.emitter, &self.group];
        let (f, u) = (f.map(|c| &c[..n]), u.map(|c| &c[..n]));
        let mut total = 0u64;
        for i in 0..n {
            let fs: u64 = f.iter().map(|c| c[i].to_bits() as u64).sum();
            let us: u64 = u.iter().map(|c| c[i] as u64).sum();
            total = total.wrapping_add(fs + us);
        }
        total
    }
}

// ---- 4. AoSoA: blocks of 8 particles, SoA inside each block ----
#[derive(Clone, Copy, Default)]
#[repr(align(64))]
struct Block {
    px: [f32; LANES], py: [f32; LANES], pz: [f32; LANES],
    vx: [f32; LANES], vy: [f32; LANES], vz: [f32; LANES],
    mass: [f32; LANES], age: [f32; LANES], life: [f32; LANES], size: [f32; LANES],
    color: [u32; LANES], id: [u32; LANES], flags: [u32; LANES],
    seed: [u32; LANES], emitter: [u32; LANES], group: [u32; LANES],
}
const _: () = assert!(size_of::<Block>() == 16 * 4 * LANES);

struct Aosoa {
    blocks: Vec<Block>,
}
impl Aosoa {
    /// Gather lane j of one block into a whole record.
    fn lane(b: &Block, j: usize) -> Particle {
        Particle {
            px: b.px[j], py: b.py[j], pz: b.pz[j], vx: b.vx[j], vy: b.vy[j], vz: b.vz[j],
            mass: b.mass[j], age: b.age[j], life: b.life[j], size: b.size[j],
            color: b.color[j], id: b.id[j], flags: b.flags[j],
            seed: b.seed[j], emitter: b.emitter[j], group: b.group[j],
        }
    }
}
impl Layout for Aosoa {
    const LABEL: &'static str = "AoSoA";
    const UPDATE_BYTES: usize = 24;
    fn build(n: usize) -> Self {
        assert!(n.is_multiple_of(LANES), "AoSoA needs n to be a multiple of {LANES}");
        let mut blocks = vec![Block::default(); n / LANES];
        for (i, p) in (0..n).map(particle).enumerate() {
            let (b, j) = (&mut blocks[i / LANES], i % LANES);
            (b.px[j], b.py[j], b.pz[j], b.vx[j], b.vy[j], b.vz[j]) = (p.px, p.py, p.pz, p.vx, p.vy, p.vz);
            (b.mass[j], b.age[j], b.life[j], b.size[j]) = (p.mass, p.age, p.life, p.size);
            (b.color[j], b.id[j], b.flags[j]) = (p.color, p.id, p.flags);
            (b.seed[j], b.emitter[j], b.group[j]) = (p.seed, p.emitter, p.group);
        }
        Aosoa { blocks }
    }
    // AoSoA update: a lane loop over each block's fixed [f32; 8] arrays.
    fn update(&mut self, dt: f32) {
        for b in &mut self.blocks {
            for j in 0..LANES {
                b.px[j] += b.vx[j] * dt;
                b.py[j] += b.vy[j] * dt;
                b.pz[j] += b.vz[j] * dt;
            }
        }
    }
    fn get(&self, i: usize) -> Particle {
        Aosoa::lane(&self.blocks[i / LANES], i % LANES)
    }
    fn len(&self) -> usize {
        self.blocks.len() * LANES
    }
    fn every(&self) -> u64 {
        let lanes = |b: &Block| (0..LANES).map(|j| field_sum(&Aosoa::lane(b, j))).sum::<u64>();
        self.blocks.iter().map(lanes).fold(0, u64::wrapping_add)
    }
}

// ---- the experiments ----
/// Random whole-record reads: the access pattern where AoS wins.
fn random_reads<L: Layout>(l: &L, idx: &[u32]) -> u64 {
    idx.iter().map(|&i| field_sum(&l.get(i as usize))).fold(0, u64::wrapping_add)
}

struct Row {
    label: &'static str,
    bytes: usize,
    ns: [u128; 3],
    sums: [u64; 3],
}

fn run<L: Layout>(n: usize, idx: &[u32]) -> Row {
    let mut l = L::build(n);
    let up = bench_runs(|| l.update(black_box(DT))); // 1 warm-up + 7 timed = 8 updates
    let pos = (0..n).map(|i| pos_sum(&l.get(i))).fold(0, u64::wrapping_add);
    let every = bench_runs(|| black_box(&l).every());
    let rnd = bench_runs(|| random_reads(black_box(&l), black_box(idx)));
    emit_bench("ch04-update", L::LABEL, n, &up);
    emit_bench("ch04-every", L::LABEL, n, &every);
    emit_bench("ch04-random", L::LABEL, n, &rnd);
    Row {
        label: L::LABEL,
        bytes: L::UPDATE_BYTES,
        ns: [up[RUNS / 2], every[RUNS / 2], rnd[RUNS / 2]].map(|d| d.as_nanos()),
        sums: [pos, l.every(), random_reads(&l, idx)],
    }
}

// ---- 16 columns in one buffer: 4 KiB apart vs staggered by one cache line ----
const COLS: usize = 16;

fn sum_columns(cols: &[&[u32]; COLS]) -> u64 {
    let n = cols[0].len();
    let cols = cols.map(|c| &c[..n]); // equal lengths: no bounds checks in the loop
    let mut total = 0u64;
    for i in 0..n {
        total = total.wrapping_add(cols.iter().map(|c| c[i] as u64).sum::<u64>());
    }
    total
}

/// Column k starts at k * stride elements. stride = n (n a power of two): every column start is a
/// multiple of 4 KiB from the first, so element i of all 16 columns maps to the same L1 set.
fn columns(buf: &[u32], n: usize, stride: usize) -> [&[u32]; COLS] {
    std::array::from_fn(|k| &buf[k * stride..k * stride + n])
}

fn alias_experiment(n: usize) -> [u64; 2] {
    let skew = 16; // 16 u32 = 64 B = one cache line
    let mut buf = vec![0u32; COLS * (n + skew)];
    let mut sums = [0; 2];
    for (s, stride, label) in [(0, n, "4 KiB-aligned columns"), (1, n + skew, "staggered columns")] {
        for k in 0..COLS {
            for i in 0..n {
                buf[k * stride + i] = hash((i * COLS + k) as u32);
            }
        }
        let cols = columns(&buf, n, stride);
        let runs = bench_runs(|| sum_columns(black_box(&cols)));
        sums[s] = sum_columns(&cols);
        let offs: Vec<String> = cols[..4].iter().map(|c| (c.as_ptr().addr() % 4096).to_string()).collect();
        println!(
            "  {label:<22} {:>8.3} ns/elem  checksum {:016x}  column starts mod 4096: {} ...",
            runs[RUNS / 2].as_nanos() as f64 / n as f64,
            sums[s],
            offs.join(", ")
        );
        emit_bench("ch04-alias", label, n, &runs);
    }
    sums
}

fn main() {
    let args = parse_args();
    let base = args.n.max(64) / LANES * LANES;
    println!(
        "ch04 (rust): size_of Particle {} B, Hot {} B, Cold {} B, Block {} B; quick={}",
        size_of::<Particle>(),
        size_of::<Hot>(),
        size_of::<Cold>(),
        size_of::<Block>(),
        args.quick
    );
    {
        // Where hand-written SoA columns land: every large Vec is its own allocation (mmap'd by malloc).
        let probe = Soa::build(1 << 18);
        let off = |v: &[f32]| v.as_ptr().addr() % 4096;
        println!(
            "hand-written Soa, 262144 particles: px, vx, size columns start at page offsets {}, {}, {}",
            off(&probe.px),
            off(&probe.vx),
            off(&probe.size)
        );
    }
    let mut ok = true;
    for n in [base / 64 / LANES * LANES, base, base * 4] {
        let n = n.max(LANES);
        let idx: Vec<u32> = (0..n as u32).map(|k| hash(k ^ 0x9e37_79b9) % n as u32).collect();
        println!("\nn = {n} particles ({} of AoS)", fmt_bytes(n * 64));
        println!("  {:<9} {:>7} {:>14} {:>14} {:>16}   checksums (update / every / random)", "layout", "B/p", "update ns/p", "every ns/p", "random ns/read");
        let rows = [run::<Aos>(n, &idx), run::<HotCold>(n, &idx), run::<Soa>(n, &idx), run::<Aosoa>(n, &idx)];
        for r in &rows {
            println!(
                "  {:<9} {:>7} {:>14.3} {:>14.3} {:>16.3}   {:016x} / {:016x} / {:016x}",
                r.label,
                r.bytes,
                r.ns[0] as f64 / n as f64,
                r.ns[1] as f64 / n as f64,
                r.ns[2] as f64 / n as f64,
                r.sums[0],
                r.sums[1],
                r.sums[2]
            );
            ok &= r.sums == rows[0].sums;
        }
        // Columns of n u32 are a multiple of 4 KiB apart only when n is a multiple of 1024.
        if n.is_multiple_of(1024) {
            let a = alias_experiment(n);
            ok &= a[0] == a[1];
        } else {
            println!("  (alias experiment skipped: {n} u32 columns are not a multiple of 4 KiB)");
        }
    }
    println!("\nchecksums match across layouts: {}", if ok { "yes" } else { "NO" });
    assert!(ok, "layouts disagree");
}

fn fmt_bytes(b: usize) -> String {
    match b {
        b if b >= 1 << 20 => format!("{} MiB", b >> 20),
        b if b >= 1 << 10 => format!("{} KiB", b >> 10),
        b => format!("{b} B"),
    }
}
