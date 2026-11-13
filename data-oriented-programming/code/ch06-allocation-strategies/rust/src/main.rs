// Chapter 6: allocation strategies. Same workloads as ../zig/main.zig and ../odin/main.odin.
//   1. frame: every tick builds many short-lived byte strings, uses them, throws them away.
//      heap per object (Global) vs a frame arena (`Bump`) reset once per tick.
//   2. pool: projectiles with individual lifetimes. Box per object (Global) vs a `Pool`.
//   3. the arena + growing array pitfall, and 4. reserve-then-commit, as printed counters.
// Run: cargo run --release -q -p ch06_allocation_strategies -- [N] [--quick]

use ch06_allocation_strategies::{Bump, Pool};
use std::alloc::{Allocator, Global};

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

const TICKS: usize = 16; // frames per benchmark run
const MAX_MSG: usize = 71; // longest message in bytes
const POOL_TICKS: usize = 64;
const MAX_TTL: u64 = 16;

/// A splitmix64-style mix of (tick, i). Every language computes the same numbers.
fn mix(tick: u64, i: u64) -> u64 {
    let mut h = i.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ tick.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    h ^= h >> 31;
    h = h.wrapping_mul(0x94D0_49BB_1331_11EB);
    h ^ (h >> 29)
}

// ---- 1. frame workload ----

/// One frame: build `count` short-lived messages (8..=71 bytes), use them, drop them.
/// The same code runs on the global heap (`Global`) and on a frame arena (`&Bump`).
fn tick<A: Allocator + Copy>(alloc: A, t: u64, count: usize) -> u64 {
    let mut msgs: Vec<Vec<u8, A>, A> = Vec::with_capacity_in(count, alloc);
    for i in 0..count as u64 {
        let h = mix(t, i);
        let len = 8 + (h >> 58) as usize;
        let mut m = Vec::with_capacity_in(len, alloc);
        m.extend((0..len).map(|j| (h as u8).wrapping_add(j as u8)));
        msgs.push(m);
    }
    let mut sum = 0u64;
    for m in &msgs {
        let bytes: u64 = m.iter().map(|&b| u64::from(b)).sum();
        sum = sum.wrapping_add(bytes ^ ((m.len() as u64) << 32));
    }
    sum
    // `msgs` drops here: count + 1 calls to `free` on Global, nothing at all on &Bump.
}

fn frames_heap(count: usize) -> u64 {
    (0..TICKS as u64).fold(0, |acc, t| acc.wrapping_add(tick(Global, t, count)))
}

fn frames_arena(frame: &mut Bump, count: usize) -> u64 {
    let mut acc = 0u64;
    for t in 0..TICKS as u64 {
        acc = acc.wrapping_add(tick(&*frame, t, count));
        frame.reset(); // compiles only because nothing from this frame is still alive
    }
    acc
}

// ---- 2. pool workload ----

#[derive(Clone, Copy)]
struct Projectile {
    x: i32,
    y: i32,
    vx: i32,
    vy: i32,
    ttl: u32,
    id: u32,
}
const _: () = assert!(size_of::<Projectile>() == 24);

fn score(p: &Projectile) -> u64 {
    u64::from(p.x as u32) ^ (u64::from(p.y as u32) << 20) ^ (u64::from(p.id) << 40)
}

/// Spawn `spawn` projectiles per tick, move them, despawn each when its ttl runs out.
/// Every projectile is its own allocation with its own lifetime.
fn simulate<A: Allocator + Copy>(alloc: A, spawn: usize) -> u64 {
    let mut live: Vec<Box<Projectile, A>> = Vec::new();
    let mut sum = 0u64;
    for t in 0..POOL_TICKS as u64 {
        for i in 0..spawn as u64 {
            let h = mix(t + 1000, i);
            let p = Projectile {
                x: (h & 0xFFFF) as i32,
                y: ((h >> 16) & 0xFFFF) as i32,
                vx: ((h >> 32) & 15) as i32 - 8,
                vy: ((h >> 36) & 15) as i32 - 8,
                ttl: 1 + ((h >> 40) % MAX_TTL) as u32,
                id: (t * spawn as u64 + i) as u32,
            };
            live.push(Box::new_in(p, alloc));
        }
        let mut k = 0;
        while k < live.len() {
            let p = &mut live[k];
            p.x += p.vx;
            p.y += p.vy;
            p.ttl -= 1;
            if p.ttl == 0 {
                sum = sum.wrapping_add(score(p));
                live.swap_remove(k); // drops the Box: `free`, or a push onto the pool's free list
            } else {
                k += 1;
            }
        }
    }
    live.iter().fold(sum, |s, p| s.wrapping_add(score(p)))
}

// ---- 4. reserve, then commit ----

/// Resident set size in bytes, from /proc/self/statm (Linux only; 0 elsewhere).
fn rss_bytes() -> usize {
    let statm = std::fs::read_to_string("/proc/self/statm").unwrap_or_default();
    let pages: usize = statm.split_whitespace().nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    pages * 4096
}

fn main() {
    let args = parse_args();
    let per_tick = (args.n / TICKS).max(1);
    let n = per_tick * TICKS;
    println!("ch06 frame workload: {TICKS} ticks x {per_tick} messages (8..={MAX_MSG} B), quick={}", args.quick);

    // Worst case per tick: one Vec header and MAX_MSG bytes per message (TigerStyle: size it once).
    let cap = per_tick * (size_of::<Vec<u8, &Bump>>() + MAX_MSG) + 64;
    let mut frame = Bump::with_capacity(cap);

    let one = tick(&frame, 0, per_tick);
    println!(
        "  one tick: {} allocations, arena high-water mark {} of {} B ({:.1} B/message)",
        per_tick + 1,
        frame.used(),
        frame.capacity(),
        frame.used() as f64 / per_tick as f64
    );
    black_box(one);
    frame.reset();

    let heap_sum = frames_heap(per_tick);
    let arena_sum = frames_arena(&mut frame, per_tick);
    println!("  checksum heap={heap_sum:#018x} arena={arena_sum:#018x} match={}", heap_sum == arena_sum);
    assert_eq!(heap_sum, arena_sum);

    let heap = bench_runs(|| frames_heap(black_box(per_tick)));
    let arena = bench_runs(|| frames_arena(&mut frame, black_box(per_tick)));
    let ns = |r: &[Duration]| r[RUNS / 2].as_nanos() as f64 / n as f64;
    println!("  heap per object: {:.1} ns/message", ns(&heap));
    println!("  frame arena:     {:.1} ns/message ({:.1}x)", ns(&arena), ns(&heap) / ns(&arena));
    emit_bench("ch06-frame", "heap per object", n, &heap);
    emit_bench("ch06-frame", "frame arena", n, &arena);

    // ---- 2. pool ----
    let spawn = (args.n / POOL_TICKS / 4).max(1);
    let total = spawn * POOL_TICKS;
    let pool = Pool::for_type::<Projectile>(spawn * MAX_TTL as usize);
    println!("ch06 pool workload: {POOL_TICKS} ticks x {spawn} spawns, 24 B projectiles, ttl 1..={MAX_TTL}");
    let heap_sum = simulate(Global, spawn);
    let pool_sum = simulate(&pool, spawn);
    println!("  checksum heap={heap_sum:#018x} pool={pool_sum:#018x} match={}", heap_sum == pool_sum);
    assert_eq!(heap_sum, pool_sum);
    let heap = bench_runs(|| simulate(Global, black_box(spawn)));
    let pooled = bench_runs(|| simulate(&pool, black_box(spawn)));
    let ns = |r: &[Duration]| r[RUNS / 2].as_nanos() as f64 / total as f64;
    println!("  Box per object:  {:.1} ns/projectile", ns(&heap));
    println!("  pool:            {:.1} ns/projectile ({:.1}x)", ns(&pooled), ns(&heap) / ns(&pooled));
    emit_bench("ch06-pool", "heap per object", total, &heap);
    emit_bench("ch06-pool", "pool", total, &pooled);

    // ---- 3. pitfall: growing arrays inside an arena leave dead copies behind ----
    let scratch = Bump::with_capacity(1 << 16);
    let mut a: Vec<u32, &Bump> = Vec::new_in(&scratch);
    let mut b: Vec<u32, &Bump> = Vec::new_in(&scratch);
    for i in 0..1000 {
        a.push(i); // the two vectors take turns at the end of the arena, so
        b.push(i); // neither can grow in place: every regrow copies and abandons the old block
    }
    let live = (a.capacity() + b.capacity()) * 4;
    println!("arena + growing Vec: 2 x 1000 u32, live {live} B, arena used {} B ({:.1}x)", scratch.used(), scratch.used() as f64 / live as f64);

    // ---- 4. reserve, then commit ----
    // Rust's std has no reserve/commit API. A huge zeroed Vec gets fresh zero pages from mmap
    // (via calloc), and the kernel only backs a page with RAM when it is first written.
    let before = rss_bytes();
    let mut big = vec![0u8; 1 << 30];
    let reserved = rss_bytes();
    for page in big[..16 << 20].chunks_mut(4096) {
        page[0] = 1;
    }
    let touched = rss_bytes();
    black_box(&big);
    const MIB: f64 = 1024.0 * 1024.0;
    println!(
        "1 GiB zeroed Vec: RSS +{:.1} MiB after allocating, +{:.1} MiB after touching 16 MiB",
        reserved.saturating_sub(before) as f64 / MIB,
        touched.saturating_sub(before) as f64 / MIB
    );
}
