//! Chapter 10: one deterministic 2D boids step, six ways.
//!
//!   naive          every boid against every boid, O(n²) distance checks
//!   grid           counting-sort uniform grid; boids stay in spawn order and are reached through `order`
//!   sorted         the same grid, but the boid columns are gathered into cell order every step
//!   morton         like sorted, with cells numbered along a Z-order (Morton) curve instead of row by row
//!   sorted simd    sorted, with the inner loop written as 8 independent lanes
//!   simd 2 threads sorted simd, with the output range split across 2 threads
//!
//! All variants start from the same seeded state. Neighbour counts must match exactly; positions may
//! differ in the last bits because the sums run in a different order, so they are compared with a tolerance.
//!
//!   cargo run --release -q -p ch10_boids_spatial_hash -- [N] [--quick]
//!
//! Sweeps N = 1024, 4096, ... up to N (default 1 << 20; --quick caps it at 4096). Naive runs up to 16384.

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

use std::hint::select_unpredictable;
use std::ops::Range;
use std::thread;

// ---- the model: one step of Reynolds' three rules ----
const NEIGHBOR_R2: f32 = 1.0; // neighbour radius 1.0 = one grid cell
const SEPARATION_R2: f32 = 0.0625; // separation radius 0.25
const COHESION: f32 = 0.02;
const ALIGNMENT: f32 = 0.05;
const SEPARATION: f32 = 0.5;
const MAX_SPEED: f32 = 2.0;
const DT: f32 = 0.05;
const BOIDS_PER_CELL: usize = 4; // average density; the world grows with N
const LANES: usize = 8;
const THREADS: usize = 2;
const NAIVE_MAX: usize = 1 << 14;
const SEED: u64 = 0x5EED_B01D;

/// SplitMix64: the same generator, bit for bit, in all three languages.
struct SplitMix64(u64);

impl SplitMix64 {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    /// Uniform in [0, 1) from the top 24 bits, so every value is exact in f32.
    fn unit(&mut self) -> f32 {
        (self.next() >> 40) as f32 * (1.0 / 16_777_216.0)
    }
}

/// The boid state as hand-written SoA: one Vec per field. `id` is the spawn index, which survives
/// reordering. Every column has LANES spare elements at the end so 8-wide loads never run off it.
#[derive(Clone)]
struct Boids {
    n: usize,
    x: Vec<f32>,
    y: Vec<f32>,
    vx: Vec<f32>,
    vy: Vec<f32>,
    id: Vec<u32>,
}

impl Boids {
    fn new(n: usize) -> Self {
        let col = || vec![0.0f32; n + LANES];
        Boids { n, x: col(), y: col(), vx: col(), vy: col(), id: vec![0; n + LANES] }
    }

    fn spawn(n: usize, w: World) -> Self {
        let mut b = Boids::new(n);
        let mut rng = SplitMix64(SEED);
        for i in 0..n {
            b.x[i] = rng.unit() * w.size;
            b.y[i] = rng.unit() * w.size;
            b.vx[i] = rng.unit() * 2.0 - 1.0;
            b.vy[i] = rng.unit() * 2.0 - 1.0;
            b.id[i] = i as u32;
        }
        b
    }

    /// The reorder: copy every column into the order the grid sorted them (a gather).
    fn gather_from(&mut self, src: &Boids, order: &[u32]) {
        for (k, &j) in order.iter().enumerate() {
            let j = j as usize;
            self.x[k] = src.x[j];
            self.y[k] = src.y[j];
            self.vx[k] = src.vx[j];
            self.vy[k] = src.vy[j];
            self.id[k] = src.id[j];
        }
    }

    fn out(&mut self) -> Out<'_> {
        let n = self.n;
        Out { x: &mut self.x[..n], y: &mut self.y[..n], vx: &mut self.vx[..n], vy: &mut self.vy[..n], id: &mut self.id[..n] }
    }
}

/// Mutable view of the output columns, splittable so threads write disjoint ranges.
struct Out<'a> {
    x: &'a mut [f32],
    y: &'a mut [f32],
    vx: &'a mut [f32],
    vy: &'a mut [f32],
    id: &'a mut [u32],
}

impl<'a> Out<'a> {
    fn split_at(self, mid: usize) -> (Out<'a>, Out<'a>) {
        let (x0, x1) = self.x.split_at_mut(mid);
        let (y0, y1) = self.y.split_at_mut(mid);
        let (vx0, vx1) = self.vx.split_at_mut(mid);
        let (vy0, vy1) = self.vy.split_at_mut(mid);
        let (id0, id1) = self.id.split_at_mut(mid);
        (Out { x: x0, y: y0, vx: vx0, vy: vy0, id: id0 }, Out { x: x1, y: y1, vx: vx1, vy: vy1, id: id1 })
    }

    fn set(&mut self, k: usize, s: [f32; 4], id: u32) {
        [self.x[k], self.y[k], self.vx[k], self.vy[k]] = s;
        self.id[k] = id;
    }
}

/// A square world of side × side unit cells. The cell size equals the neighbour radius,
/// so every neighbour of a boid lies in its own cell or one of the eight around it.
#[derive(Clone, Copy)]
struct World {
    side: u32,
    size: f32,
}

impl World {
    fn for_count(n: usize) -> World {
        let side = ((n / BOIDS_PER_CELL) as f64).sqrt().round().max(1.0) as u32;
        World { side, size: side as f32 }
    }
    fn cell_xy(self, x: f32, y: f32) -> (u32, u32) {
        ((x as u32).min(self.side - 1), (y as u32).min(self.side - 1))
    }
    /// Row-major cell number: cells in one row are consecutive.
    fn row_major(self, x: f32, y: f32) -> u32 {
        let (cx, cy) = self.cell_xy(x, y);
        cy * self.side + cx
    }
    /// The 3×3 block around a cell, clipped at the walls: (x0, x1, y0, y1), inclusive.
    fn block(self, x: f32, y: f32) -> (u32, u32, u32, u32) {
        let (cx, cy) = self.cell_xy(x, y);
        (cx.saturating_sub(1), (cx + 1).min(self.side - 1), cy.saturating_sub(1), (cy + 1).min(self.side - 1))
    }
    /// Cells needed by the Morton numbering: the side rounded up to a power of two, squared.
    fn morton_cells(self) -> usize {
        let p = self.side.next_power_of_two() as usize;
        p * p
    }
}

/// Interleaves the bits of x and y (x in the even bits): the Z-order curve.
fn morton(cx: u32, cy: u32) -> u32 {
    fn spread(v: u32) -> u32 {
        let mut v = v & 0xFFFF;
        v = (v | (v << 8)) & 0x00FF_00FF;
        v = (v | (v << 4)) & 0x0F0F_0F0F;
        v = (v | (v << 2)) & 0x3333_3333;
        (v | (v << 1)) & 0x5555_5555
    }
    spread(cx) | (spread(cy) << 1)
}

/// What one boid accumulates over its neighbours (itself included, so n >= 1).
#[derive(Clone, Copy, Default)]
struct Acc {
    n: u32,
    sx: f32, // sum of offsets to neighbours (cohesion)
    sy: f32,
    ax: f32, // sum of neighbour velocities (alignment)
    ay: f32,
    qx: f32, // push away from very close neighbours (separation)
    qy: f32,
}

impl Acc {
    #[inline(always)]
    fn visit(&mut self, xi: f32, yi: f32, xj: f32, yj: f32, vxj: f32, vyj: f32) {
        let dx = xj - xi;
        let dy = yj - yi;
        let d2 = dx * dx + dy * dy;
        // About a third of the candidates are neighbours, so a branch here mispredicts all the time
        // (Chapter 7). The first version branched the way the rules read:
        //     if d2 < NEIGHBOR_R2 {
        //         self.n += 1;
        //         self.sx += dx;
        //         // ...
        //         if d2 < SEPARATION_R2 { self.qx -= dx; self.qy -= dy; }
        //     }
        // select_unpredictable asks for a conditional move/blend instead; a plain
        // `if near { dx } else { 0.0 }` was compiled back into a jump.
        let near = d2 < NEIGHBOR_R2;
        let close = d2 < SEPARATION_R2;
        self.n += near as u32;
        self.sx += select_unpredictable(near, dx, 0.0);
        self.sy += select_unpredictable(near, dy, 0.0);
        self.ax += select_unpredictable(near, vxj, 0.0);
        self.ay += select_unpredictable(near, vyj, 0.0);
        self.qx -= select_unpredictable(close, dx, 0.0);
        self.qy -= select_unpredictable(close, dy, 0.0);
    }

    /// Steer, clamp the speed, move, and bounce off the walls. Returns [x, y, vx, vy].
    #[inline(always)]
    fn integrate(&self, w: World, x: f32, y: f32, vx: f32, vy: f32) -> [f32; 4] {
        let inv = 1.0 / self.n as f32;
        let mut nvx = vx + COHESION * (self.sx * inv) + ALIGNMENT * (self.ax * inv - vx) + SEPARATION * self.qx;
        let mut nvy = vy + COHESION * (self.sy * inv) + ALIGNMENT * (self.ay * inv - vy) + SEPARATION * self.qy;
        let s2 = nvx * nvx + nvy * nvy;
        if s2 > MAX_SPEED * MAX_SPEED {
            let k = MAX_SPEED / s2.sqrt();
            nvx *= k;
            nvy *= k;
        }
        let (nx, nvx) = bounce(x + nvx * DT, nvx, w.size);
        let (ny, nvy) = bounce(y + nvy * DT, nvy, w.size);
        [nx, ny, nvx, nvy]
    }
}

fn bounce(p: f32, v: f32, size: f32) -> (f32, f32) {
    if p < 0.0 {
        (-p, -v)
    } else if p > size {
        (size + size - p, -v)
    } else {
        (p, v)
    }
}

/// Visits a contiguous run of boids (all four columns read in lockstep).
#[inline(always)]
fn visit_span(acc: &mut Acc, b: &Boids, r: Range<usize>, xi: f32, yi: f32) {
    let cols = b.x[r.clone()].iter().zip(&b.y[r.clone()]).zip(&b.vx[r.clone()]).zip(&b.vy[r]);
    for (((&xj, &yj), &vxj), &vyj) in cols {
        acc.visit(xi, yi, xj, yj, vxj, vyj);
    }
}

// ---- the counting-sort grid ----

/// `start[c]..start[c + 1]` is the slice of `order` holding the boids of cell c.
struct Grid {
    start: Vec<u32>, // cells + 1 entries
    cell: Vec<u32>,  // cell of each boid
    order: Vec<u32>, // boid indices sorted by cell
}

impl Grid {
    fn new(cells: usize, n: usize) -> Self {
        Grid { start: vec![0; cells + 1], cell: vec![0; n], order: vec![0; n] }
    }

    /// Counting sort by cell key: count, prefix sum, scatter. O(n + cells), no allocation.
    fn build(&mut self, xs: &[f32], ys: &[f32], key: impl Fn(f32, f32) -> u32) {
        // 1. count: start[c] = boids in cell c
        self.start.fill(0);
        for ((c, &x), &y) in self.cell.iter_mut().zip(xs).zip(ys) {
            *c = key(x, y);
            self.start[*c as usize] += 1;
        }
        // 2. inclusive prefix sum: start[c] = boids in cells 0..=c
        let mut sum = 0;
        for s in &mut self.start {
            sum += *s;
            *s = sum;
        }
        // 3. scatter back to front: each boid takes the last free slot of its cell, so start[c]
        //    ends at the first slot of cell c and boids keep their spawn order inside a cell.
        for (i, &c) in self.cell.iter().enumerate().rev() {
            let s = &mut self.start[c as usize];
            *s -= 1;
            self.order[*s as usize] = i as u32;
        }
    }

    /// Positions in `order` of cells first..=last (consecutive cell numbers).
    fn span(&self, first: u32, last: u32) -> Range<usize> {
        self.start[first as usize] as usize..self.start[last as usize + 1] as usize
    }
}

// ---- the variants. Each reads `cur`, writes `next` (double buffering) and returns total neighbours. ----

fn step_naive(w: World, cur: &Boids, next: &mut Boids) -> u64 {
    let n = cur.n;
    let mut out = next.out();
    let mut total = 0;
    for i in 0..n {
        let mut acc = Acc::default();
        visit_span(&mut acc, cur, 0..n, cur.x[i], cur.y[i]);
        total += acc.n as u64;
        out.set(i, acc.integrate(w, cur.x[i], cur.y[i], cur.vx[i], cur.vy[i]), cur.id[i]);
    }
    total
}

fn step_grid(w: World, g: &mut Grid, cur: &Boids, next: &mut Boids) -> u64 {
    let n = cur.n;
    g.build(&cur.x[..n], &cur.y[..n], |x, y| w.row_major(x, y));
    let mut out = next.out();
    let mut total = 0;
    for i in 0..n {
        let (xi, yi) = (cur.x[i], cur.y[i]);
        let (x0, x1, y0, y1) = w.block(xi, yi);
        let mut acc = Acc::default();
        for row in y0..=y1 {
            // three cells of one row are consecutive in `order`, but the boids they name are anywhere
            for &j in &g.order[g.span(row * w.side + x0, row * w.side + x1)] {
                let j = j as usize;
                acc.visit(xi, yi, cur.x[j], cur.y[j], cur.vx[j], cur.vy[j]);
            }
        }
        total += acc.n as u64;
        out.set(i, acc.integrate(w, xi, yi, cur.vx[i], cur.vy[i]), cur.id[i]);
    }
    total
}

fn step_sorted(w: World, g: &mut Grid, cur: &Boids, s: &mut Boids, next: &mut Boids) -> u64 {
    let n = cur.n;
    g.build(&cur.x[..n], &cur.y[..n], |x, y| w.row_major(x, y));
    s.gather_from(cur, &g.order); // now cell c is s[start[c]..start[c + 1]]
    let mut out = next.out();
    let mut total = 0;
    for k in 0..n {
        let (xi, yi) = (s.x[k], s.y[k]);
        let (x0, x1, y0, y1) = w.block(xi, yi);
        let mut acc = Acc::default();
        for row in y0..=y1 {
            visit_span(&mut acc, s, g.span(row * w.side + x0, row * w.side + x1), xi, yi);
        }
        total += acc.n as u64;
        out.set(k, acc.integrate(w, xi, yi, s.vx[k], s.vy[k]), s.id[k]);
    }
    total
}

fn step_morton(w: World, g: &mut Grid, cur: &Boids, s: &mut Boids, next: &mut Boids) -> u64 {
    let n = cur.n;
    g.build(&cur.x[..n], &cur.y[..n], |x, y| {
        let (cx, cy) = w.cell_xy(x, y);
        morton(cx, cy)
    });
    s.gather_from(cur, &g.order);
    let mut out = next.out();
    let mut total = 0;
    for k in 0..n {
        let (xi, yi) = (s.x[k], s.y[k]);
        let (x0, x1, y0, y1) = w.block(xi, yi);
        let mut acc = Acc::default();
        for row in y0..=y1 {
            for col in x0..=x1 {
                let c = morton(col, row); // neighbouring cells are no longer consecutive: 9 spans
                visit_span(&mut acc, s, g.span(c, c), xi, yi);
            }
        }
        total += acc.n as u64;
        out.set(k, acc.integrate(w, xi, yi, s.vx[k], s.vy[k]), s.id[k]);
    }
    total
}

/// Eight independent accumulators: lane l sums elements l, l + 8, l + 16, ... of each span.
#[derive(Clone, Copy, Default)]
struct Acc8 {
    n: [u32; LANES],
    sx: [f32; LANES],
    sy: [f32; LANES],
    ax: [f32; LANES],
    ay: [f32; LANES],
    qx: [f32; LANES],
    qy: [f32; LANES],
}

impl Acc8 {
    /// Branch-free: every lane computes, and a mask decides what it adds. Lanes past the end of
    /// the span read real (or padding) boids that the index mask throws away.
    #[inline(always)]
    #[allow(clippy::needless_range_loop)] // the lane index also feeds the mask
    fn visit_span(&mut self, b: &Boids, r: Range<usize>, xi: f32, yi: f32) {
        let mut j = r.start;
        while j < r.end {
            let x = b.x[j..].first_chunk::<LANES>().unwrap();
            let y = b.y[j..].first_chunk::<LANES>().unwrap();
            let vx = b.vx[j..].first_chunk::<LANES>().unwrap();
            let vy = b.vy[j..].first_chunk::<LANES>().unwrap();
            for l in 0..LANES {
                let dx = x[l] - xi;
                let dy = y[l] - yi;
                let d2 = dx * dx + dy * dy;
                let live = (j + l < r.end) & (d2 < NEIGHBOR_R2);
                let close = live & (d2 < SEPARATION_R2);
                self.n[l] += live as u32;
                self.sx[l] += select_unpredictable(live, dx, 0.0);
                self.sy[l] += select_unpredictable(live, dy, 0.0);
                self.ax[l] += select_unpredictable(live, vx[l], 0.0);
                self.ay[l] += select_unpredictable(live, vy[l], 0.0);
                self.qx[l] -= select_unpredictable(close, dx, 0.0);
                self.qy[l] -= select_unpredictable(close, dy, 0.0);
            }
            j += LANES;
        }
    }

    /// Adds the lanes in order 0..8, the same order the Zig and Odin versions use.
    fn reduce(&self) -> Acc {
        let sum = |v: &[f32; LANES]| v.iter().fold(0.0, |a, &b| a + b);
        Acc {
            n: self.n.iter().sum(),
            sx: sum(&self.sx),
            sy: sum(&self.sy),
            ax: sum(&self.ax),
            ay: sum(&self.ay),
            qx: sum(&self.qx),
            qy: sum(&self.qy),
        }
    }
}

/// The neighbour pass of the SIMD variants for sorted boids k0..k0 + out.len().
fn simd_range(w: World, g: &Grid, s: &Boids, mut out: Out, k0: usize) -> u64 {
    let mut total = 0;
    for o in 0..out.x.len() {
        let k = k0 + o;
        let (xi, yi) = (s.x[k], s.y[k]);
        let (x0, x1, y0, y1) = w.block(xi, yi);
        let mut acc8 = Acc8::default();
        for row in y0..=y1 {
            acc8.visit_span(s, g.span(row * w.side + x0, row * w.side + x1), xi, yi);
        }
        let acc = acc8.reduce();
        total += acc.n as u64;
        out.set(o, acc.integrate(w, xi, yi, s.vx[k], s.vy[k]), s.id[k]);
    }
    total
}

fn step_simd(w: World, g: &mut Grid, cur: &Boids, s: &mut Boids, next: &mut Boids) -> u64 {
    let n = cur.n;
    g.build(&cur.x[..n], &cur.y[..n], |x, y| w.row_major(x, y));
    s.gather_from(cur, &g.order);
    simd_range(w, g, s, next.out(), 0)
}

/// Build and gather stay serial; the neighbour pass is split into THREADS disjoint output ranges.
fn step_threads(w: World, g: &mut Grid, cur: &Boids, s: &mut Boids, next: &mut Boids) -> u64 {
    let n = cur.n;
    g.build(&cur.x[..n], &cur.y[..n], |x, y| w.row_major(x, y));
    s.gather_from(cur, &g.order);
    let (g, s) = (&*g, &*s);
    let chunk = n.div_ceil(THREADS);
    thread::scope(|scope| {
        let mut rest = next.out();
        let mut handles = Vec::with_capacity(THREADS);
        for t in 0..THREADS {
            let k0 = t * chunk;
            let (mine, tail) = rest.split_at(chunk.min(n - k0));
            rest = tail;
            handles.push(scope.spawn(move || simd_range(w, g, s, mine, k0)));
        }
        handles.into_iter().map(|h| h.join().unwrap()).sum()
    })
}

// ---- driver ----

const LABELS: [&str; 6] = ["naive", "grid", "sorted", "morton", "sorted simd", "simd 2 threads"];

/// The state indexed by spawn id, so outputs stored in different orders can be compared.
fn by_id(b: &Boids) -> Vec<[f32; 4]> {
    let mut v = vec![[0.0; 4]; b.n];
    for k in 0..b.n {
        v[b.id[k] as usize] = [b.x[k], b.y[k], b.vx[k], b.vy[k]];
    }
    v
}

/// FNV-1a over the bits of the state in spawn order: equal only if every float is bit-identical.
fn checksum(v: &[[f32; 4]]) -> u64 {
    v.iter().flatten().fold(0xCBF2_9CE4_8422_2325, |h, f| (h ^ f.to_bits() as u64).wrapping_mul(0x100_0000_01B3))
}

/// Largest difference in any position or velocity component.
fn max_diff(a: &[[f32; 4]], b: &[[f32; 4]]) -> f32 {
    let d = |p: &[f32; 4], q: &[f32; 4]| p.iter().zip(q).map(|(u, v)| (u - v).abs()).fold(0.0, f32::max);
    a.iter().zip(b).map(|(p, q)| d(p, q)).fold(0.0, f32::max)
}

/// Distance checks per step: n² for naive, the sum of 3×3 block sizes for the grid.
fn grid_checks(w: World, g: &Grid, b: &Boids) -> u64 {
    let mut checks = 0;
    for i in 0..b.n {
        let (x0, x1, y0, y1) = w.block(b.x[i], b.y[i]);
        for row in y0..=y1 {
            checks += g.span(row * w.side + x0, row * w.side + x1).len() as u64;
        }
    }
    checks
}

fn main() {
    let args = parse_args();
    println!("ch10 (rust): boids step, {BOIDS_PER_CELL} boids per unit cell on average, neighbour radius 1, {THREADS} threads; quick={}", args.quick);
    let mut sizes: Vec<usize> = (10..=20).step_by(2).map(|e| 1 << e).filter(|&s| s <= args.n).collect();
    if sizes.is_empty() {
        sizes.push(args.n.max(1));
    }
    let mut ok = true;
    for n in sizes {
        let w = World::for_count(n);
        let spawned = Boids::spawn(n, w);
        let mut g = Grid::new(w.side as usize * w.side as usize, n);
        let mut gm = Grid::new(w.morton_cells(), n);
        g.build(&spawned.x[..n], &spawned.y[..n], |x, y| w.row_major(x, y));
        let checks = grid_checks(w, &g, &spawned);
        // Inputs as the previous frame would leave them: spawn order for naive and grid,
        // cell order for the variants that reorder every step.
        let mut in_rows = Boids::new(n);
        in_rows.gather_from(&spawned, &g.order);
        gm.build(&spawned.x[..n], &spawned.y[..n], |x, y| {
            let (cx, cy) = w.cell_xy(x, y);
            morton(cx, cy)
        });
        let mut in_morton = Boids::new(n);
        in_morton.gather_from(&spawned, &gm.order);

        println!(
            "\nN = {n}: world {0}×{0} cells, distance checks per step: naive {1}, grid {checks} ({2:.1} per boid)",
            w.side,
            n as u64 * n as u64,
            checks as f64 / n as f64
        );
        println!("  {:<15} {:>12} {:>10} {:>12} {:>14}", "variant", "median", "ns/boid", "neighbours", "max |diff|");
        let mut s = Boids::new(n);
        let mut next = Boids::new(n);
        let mut reference: Option<(u64, Vec<[f32; 4]>)> = None;
        for (v, label) in LABELS.iter().enumerate() {
            if v == 0 && n > NAIVE_MAX {
                continue;
            }
            let mut step = |next: &mut Boids| match v {
                0 => step_naive(w, &spawned, next),
                1 => step_grid(w, &mut g, &spawned, next),
                2 => step_sorted(w, &mut g, &in_rows, &mut s, next),
                3 => step_morton(w, &mut gm, &in_morton, &mut s, next),
                4 => step_simd(w, &mut g, &in_rows, &mut s, next),
                _ => step_threads(w, &mut g, &in_rows, &mut s, next),
            };
            let total = step(&mut next);
            let pos = by_id(&next);
            let (ref_total, ref_pos) = reference.get_or_insert_with(|| (total, pos.clone()));
            let diff = max_diff(ref_pos, &pos);
            let good = total == *ref_total && diff <= 1e-4;
            if v <= 1 {
                println!("  ({label} state checksum {:016x})", checksum(&pos));
            }
            ok &= good;
            let runs = bench_runs(|| step(&mut next));
            let med = runs[RUNS / 2];
            println!(
                "  {:<15} {:>12.3?} {:>10.2} {:>12} {:>14.2e} {}",
                label,
                med,
                med.as_nanos() as f64 / n as f64,
                total,
                diff,
                if good { "ok" } else { "MISMATCH" }
            );
            emit_bench("ch10-boids", label, n, &runs);
        }
    }
    println!("\nall variants agree (neighbour counts exact, state within 1e-4): {}", if ok { "yes" } else { "NO" });
    if !ok {
        std::process::exit(1);
    }
}
