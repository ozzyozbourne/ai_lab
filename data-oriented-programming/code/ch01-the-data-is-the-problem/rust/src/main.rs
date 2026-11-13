//! Chapter 1: the shapes benchmark (after Casey Muratori, "Clean" Code, Horrible Performance, 2023).
//!
//! The same job four ways: compute the area of every shape into an output array.
//!   1. dynamic dispatch    `Vec<Box<dyn Shape>>`, one heap object per shape, one virtual call per shape
//!   2. tagged union        `Vec<ShapeEnum>`, a `match` per shape, no pointers
//!   3. coefficient table   `Vec<FlatShape>`, `COEF[kind] * width * height`, no branch
//!   4. per-kind arrays     one array per kind and one loop per array, no tag at all (preview of Chapter 7)
//!
//! Plus two controls: versions 1 and 2 again on the same shapes sorted by kind, so every branch predicts.
//!
//! Run: `cargo run --release -q -p ch01_the_data_is_the_problem -- [N] [--quick]`

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

use std::f32::consts::PI;

// ---- the shapes: plain structs, shared by every version ----
#[derive(Clone, Copy)]
struct Square {
    side: f32,
}
#[derive(Clone, Copy)]
struct Rectangle {
    width: f32,
    height: f32,
}
#[derive(Clone, Copy)]
struct Triangle {
    base: f32,
    height: f32,
}
#[derive(Clone, Copy)]
struct Circle {
    radius: f32,
}

// ---- 1. dynamic dispatch: a trait object per shape ----
trait Shape {
    fn area(&self) -> f32;
}
impl Shape for Square {
    fn area(&self) -> f32 {
        self.side * self.side
    }
}
impl Shape for Rectangle {
    fn area(&self) -> f32 {
        self.width * self.height
    }
}
impl Shape for Triangle {
    fn area(&self) -> f32 {
        0.5 * self.base * self.height
    }
}
impl Shape for Circle {
    fn area(&self) -> f32 {
        PI * self.radius * self.radius
    }
}

/// Each element is a 16-byte fat pointer (data pointer + vtable pointer) to its own heap allocation.
fn areas_dyn(shapes: &[Box<dyn Shape>], out: &mut [f32]) {
    for (o, s) in out.iter_mut().zip(shapes) {
        *o = s.area(); // load vtable pointer, load fn pointer, indirect call
    }
}

// ---- 2. tagged union: the same structs inside an enum, dispatched by `match` ----
enum ShapeEnum {
    Square(Square),
    Rectangle(Rectangle),
    Triangle(Triangle),
    Circle(Circle),
}

/// Same structs, same `area` methods; only the dispatch changed. The compiler sees every case and inlines it.
fn areas_match(shapes: &[ShapeEnum], out: &mut [f32]) {
    for (o, s) in out.iter_mut().zip(shapes) {
        *o = match s {
            ShapeEnum::Square(q) => q.area(),
            ShapeEnum::Rectangle(r) => r.area(),
            ShapeEnum::Triangle(t) => t.area(),
            ShapeEnum::Circle(c) => c.area(),
        };
    }
}

// ---- 3. coefficient table: notice that every area is c * width * height ----
#[derive(Clone, Copy)]
#[repr(u8)]
enum Kind {
    Square,
    Rectangle,
    Triangle,
    Circle,
}

/// Squares and circles store their one dimension twice (height = width), as in Muratori's version.
#[derive(Clone, Copy)]
struct FlatShape {
    kind: Kind,
    width: f32,
    height: f32,
}

const COEF: [f32; 4] = [1.0, 1.0, 0.5, PI];

fn areas_table(shapes: &[FlatShape], out: &mut [f32]) {
    for (o, s) in out.iter_mut().zip(shapes) {
        *o = COEF[s.kind as usize] * s.width * s.height; // no branch: one load from a 16-byte table
    }
}

// ---- 4. per-kind arrays: the kind is which array a shape is in ----
#[derive(Default)]
struct ShapesByKind {
    squares: Vec<f32>,         // side
    rectangles: Vec<[f32; 2]>, // width, height
    triangles: Vec<[f32; 2]>,  // base, height
    circles: Vec<f32>,         // radius
}

/// Four tight loops with no dispatch. `out` is filled kind by kind, so its order differs from the other versions.
fn areas_by_kind(s: &ShapesByKind, out: &mut [f32]) {
    let (o_sq, rest) = out.split_at_mut(s.squares.len());
    let (o_re, rest) = rest.split_at_mut(s.rectangles.len());
    let (o_tr, o_ci) = rest.split_at_mut(s.triangles.len());
    for (o, &side) in o_sq.iter_mut().zip(&s.squares) {
        *o = side * side;
    }
    for (o, &[w, h]) in o_re.iter_mut().zip(&s.rectangles) {
        *o = w * h;
    }
    for (o, &[b, h]) in o_tr.iter_mut().zip(&s.triangles) {
        *o = 0.5 * b * h;
    }
    for (o, &r) in o_ci.iter_mut().zip(&s.circles) {
        *o = PI * r * r;
    }
}

// ---- data: the same seeded generator in Rust, Zig and Odin, so all three see the same shapes ----
struct SplitMix64(u64);

impl SplitMix64 {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    /// A dimension in [0.5, 16.5) with 12 fractional bits, so it is exact in f32.
    fn dim(&mut self) -> f32 {
        (self.next() >> 48) as f32 / 4096.0 + 0.5
    }
}

/// n shapes in random kind order: (kind, width, height) with height == width for squares and circles.
fn generate(n: usize) -> Vec<FlatShape> {
    let mut rng = SplitMix64(2023);
    let kinds = [Kind::Square, Kind::Rectangle, Kind::Triangle, Kind::Circle];
    (0..n)
        .map(|_| {
            let kind = kinds[(rng.next() >> 62) as usize];
            let width = rng.dim();
            let height = if matches!(kind, Kind::Square | Kind::Circle) { width } else { rng.dim() };
            FlatShape { kind, width, height }
        })
        .collect()
}

/// Order-independent checksum: wrapping sum of the f32 bit patterns. Equal iff every version produced the
/// same multiset of areas, bit for bit.
fn checksum(out: &[f32]) -> u64 {
    out.iter().fold(0u64, |acc, a| acc.wrapping_add(u64::from(a.to_bits())))
}

fn to_boxed(flat: &[FlatShape]) -> Vec<Box<dyn Shape>> {
    flat.iter()
        .map(|s| -> Box<dyn Shape> {
            match s.kind {
                Kind::Square => Box::new(Square { side: s.width }),
                Kind::Rectangle => Box::new(Rectangle { width: s.width, height: s.height }),
                Kind::Triangle => Box::new(Triangle { base: s.width, height: s.height }),
                Kind::Circle => Box::new(Circle { radius: s.width }),
            }
        })
        .collect()
}

fn to_tagged(flat: &[FlatShape]) -> Vec<ShapeEnum> {
    flat.iter()
        .map(|s| match s.kind {
            Kind::Square => ShapeEnum::Square(Square { side: s.width }),
            Kind::Rectangle => ShapeEnum::Rectangle(Rectangle { width: s.width, height: s.height }),
            Kind::Triangle => ShapeEnum::Triangle(Triangle { base: s.width, height: s.height }),
            Kind::Circle => ShapeEnum::Circle(Circle { radius: s.width }),
        })
        .collect()
}

fn main() {
    let args = parse_args();
    let n = args.n;
    let flat = generate(n);

    let boxed = to_boxed(&flat);
    let tagged = to_tagged(&flat);
    let mut by_kind = ShapesByKind::default();
    for s in &flat {
        match s.kind {
            Kind::Square => by_kind.squares.push(s.width),
            Kind::Rectangle => by_kind.rectangles.push([s.width, s.height]),
            Kind::Triangle => by_kind.triangles.push([s.width, s.height]),
            Kind::Circle => by_kind.circles.push(s.width),
        }
    }

    // Machine-independent facts: how many bytes each representation reads per shape.
    let mut gaps: Vec<usize> = boxed
        .windows(2)
        .map(|w| (&raw const *w[1]).addr().abs_diff((&raw const *w[0]).addr()))
        .collect();
    gaps.sort_unstable();
    let heap_gap = gaps.get(gaps.len() / 2).copied().unwrap_or(0);
    let kind_bytes = 4 * (by_kind.squares.len() + by_kind.circles.len())
        + 8 * (by_kind.rectangles.len() + by_kind.triangles.len());
    println!(
        "{n} shapes: {} squares, {} rectangles, {} triangles, {} circles (random order)",
        by_kind.squares.len(),
        by_kind.rectangles.len(),
        by_kind.triangles.len(),
        by_kind.circles.len()
    );
    println!(
        "bytes per shape read: Box<dyn Shape> {} + heap object (median {heap_gap} B apart) | ShapeEnum {} | FlatShape {} | per-kind {:.1} avg",
        size_of::<Box<dyn Shape>>(),
        size_of::<ShapeEnum>(),
        size_of::<FlatShape>(),
        kind_bytes as f64 / n as f64
    );

    let mut out = vec![0.0f32; n];
    let mut sums = Vec::new();
    let mut report = |label: &str, runs: [Duration; RUNS], out: &[f32]| {
        let sum = checksum(out);
        let total: f64 = out.iter().map(|&a| f64::from(a)).sum();
        let ns = runs[RUNS / 2].as_nanos() as f64 / n as f64;
        println!("{label:<25} {ns:7.3} ns/shape   checksum {sum:#018x}   total area {total:.1}");
        emit_bench("ch01-shapes", label, n, &runs);
        sums.push(sum);
    };

    let runs = bench_runs(|| areas_dyn(black_box(&boxed), &mut out));
    report("dynamic dispatch", runs, &out);
    let runs = bench_runs(|| areas_match(black_box(&tagged), &mut out));
    report("tagged union", runs, &out);
    let runs = bench_runs(|| areas_table(black_box(&flat), &mut out));
    report("coefficient table", runs, &out);
    let runs = bench_runs(|| areas_by_kind(black_box(&by_kind), &mut out));
    report("per-kind arrays", runs, &out);

    // Controls: the same shapes sorted by kind (stable), so every branch and call predicts well.
    // The objects are allocated in sorted order, so the heap is walked in order just like above.
    let mut sorted = flat.clone();
    sorted.sort_by_key(|s| s.kind as u8);
    let boxed_sorted = to_boxed(&sorted);
    let tagged_sorted = to_tagged(&sorted);
    let runs = bench_runs(|| areas_dyn(black_box(&boxed_sorted), &mut out));
    report("dynamic dispatch, sorted", runs, &out);
    let runs = bench_runs(|| areas_match(black_box(&tagged_sorted), &mut out));
    report("tagged union, sorted", runs, &out);

    assert!(sums.windows(2).all(|w| w[0] == w[1]), "versions disagree: {sums:x?}");
    println!("checksums: all {} runs match", sums.len());
}
