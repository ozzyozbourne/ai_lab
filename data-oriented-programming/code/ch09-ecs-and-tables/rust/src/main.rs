// Chapter 9: ECS and Thinking in Tables.
// A tiny ECS with generational entity ids (src/entity.rs) and two storages for the same data:
//   1. sparse sets, one per component type (src/sparse.rs), the EnTT layout;
//   2. one table per component combination (src/archetype.rs), the Unity/Bevy/flecs layout.
// The same world is built in both: N entities with Pos, every 2nd with Vel, every 4th with Hp.
// Benchmarks: add/remove churn (toggle Vel on N/16 random entities), then iteration of a
// 2-component query (Pos += Vel) and a 3-component query (Pos, Vel -> Hp). Checksums must match.
// Usage: cargo run --release -p ch09_ecs_and_tables -- [N] [--quick]

mod archetype;
mod entity;
mod sparse;

use archetype::{ArchWorld, HP, POS, VEL};
use entity::Entity;
use sparse::{SparseWorld, query2, query3};

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

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Pos {
    pub x: i32,
    pub y: i32,
}
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Vel {
    pub x: i32,
    pub y: i32,
}
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Hp(pub i32);

/// splitmix64: the same sequence in all three languages (as in Chapter 5).
struct Rng(u64);
impl Rng {
    fn below(&mut self, n: usize) -> usize {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        ((z ^ (z >> 31)) % n as u64) as usize
    }
}
const SEED: u64 = 9;

fn initial(i: usize) -> (Pos, Option<Vel>, Option<Hp>) {
    let k = i as i32;
    let vel = i.is_multiple_of(2).then_some(Vel { x: (i % 7) as i32 - 3, y: 1 });
    (Pos { x: k, y: -k }, vel, i.is_multiple_of(4).then_some(Hp(100)))
}

fn vel_for(e: Entity) -> Vel {
    Vel { x: (e.index % 5) as i32 - 2, y: -1 }
}

/// Order-independent: wrapping sums commute, so both storages must agree whatever their row order.
fn mix(p: Option<&Pos>, v: Option<&Vel>, h: Option<&Hp>) -> u64 {
    let mut s = 0u64;
    if let Some(p) = p {
        s = s.wrapping_add(p.x.wrapping_mul(31).wrapping_add(p.y.wrapping_mul(17)) as u32 as u64);
    }
    if let Some(v) = v {
        s = s.wrapping_add((v.x.wrapping_mul(7) ^ v.y) as u32 as u64).wrapping_add(1 << 32);
    }
    if let Some(h) = h {
        s = s.wrapping_add(h.0.wrapping_mul(3) as u32 as u64).wrapping_add(1 << 40);
    }
    s
}

// ---- sparse-set systems ----
fn sparse_move(w: &mut SparseWorld) -> u64 {
    let mut s = 0u64;
    query2(&mut w.pos, &w.vel, |p, v| {
        p.x = p.x.wrapping_add(v.x);
        p.y = p.y.wrapping_add(v.y);
        s = s.wrapping_add(p.x as u32 as u64);
    });
    s
}

fn sparse_damage(w: &mut SparseWorld) -> u64 {
    let mut s = 0u64;
    query3(&w.pos, &w.vel, &mut w.hp, |p, v, h| {
        h.0 = h.0.wrapping_sub(p.x & 15).wrapping_add(v.y);
        s = s.wrapping_add(h.0 as u32 as u64);
    });
    s
}

fn sparse_toggle(w: &mut SparseWorld, rng: &mut Rng, k: usize) -> u64 {
    for _ in 0..k {
        let e = w.entities.at(rng.below(w.entities.capacity()));
        if w.vel.remove(e).is_none() {
            w.vel.insert(e, vel_for(e));
        }
    }
    w.vel.len() as u64
}

fn sparse_checksum(w: &SparseWorld) -> u64 {
    (0..w.entities.capacity()).map(|i| w.entities.at(i)).filter(|&e| w.entities.alive(e)).fold(0, |s, e| {
        s.wrapping_add(mix(w.pos.get(e), w.vel.get(e), w.hp.get(e)))
    })
}

// ---- archetype systems: a query is a loop over matching tables, then plain zipped columns ----
fn arch_move(w: &mut ArchWorld) -> u64 {
    let mut s = 0u64;
    for t in w.tables_with(POS | VEL) {
        for (p, v) in t.pos.iter_mut().zip(&t.vel) {
            p.x = p.x.wrapping_add(v.x);
            p.y = p.y.wrapping_add(v.y);
            s = s.wrapping_add(p.x as u32 as u64);
        }
    }
    s
}

fn arch_damage(w: &mut ArchWorld) -> u64 {
    let mut s = 0u64;
    for t in w.tables_with(POS | VEL | HP) {
        for ((p, v), h) in t.pos.iter().zip(&t.vel).zip(&mut t.hp) {
            h.0 = h.0.wrapping_sub(p.x & 15).wrapping_add(v.y);
            s = s.wrapping_add(h.0 as u32 as u64);
        }
    }
    s
}

fn arch_toggle(w: &mut ArchWorld, rng: &mut Rng, k: usize) -> u64 {
    for _ in 0..k {
        let e = w.entities.at(rng.below(w.entities.capacity()));
        if w.has(e, VEL) {
            w.remove_vel(e);
        } else {
            w.add_vel(e, vel_for(e));
        }
    }
    w.count_with(VEL) as u64
}

fn arch_checksum(w: &ArchWorld) -> u64 {
    (0..w.entities.capacity()).map(|i| w.entities.at(i)).filter(|&e| w.entities.alive(e)).fold(0, |s, e| {
        let (p, v, h) = w.get(e);
        s.wrapping_add(mix(p, v, h))
    })
}

/// Generations at work: a despawned id must stop resolving in both storages, even after its
/// index is reused.
fn stale_id_demo() {
    let (mut sw, mut aw) = (SparseWorld::default(), ArchWorld::default());
    let ids: Vec<(Entity, Entity)> = (0..4)
        .map(|i| {
            let (p, v, h) = initial(i);
            (sw.spawn(p, v, h), aw.spawn(p, v, h))
        })
        .collect();
    let (old_s, old_a) = ids[2];
    assert!(sw.despawn(old_s) && aw.despawn(old_a));
    let (new_s, new_a) = (sw.spawn(Pos { x: 7, y: 7 }, None, None), aw.spawn(Pos { x: 7, y: 7 }, None, None));
    assert!(new_s.index == old_s.index && new_s.generation == old_s.generation + 1 && new_a == new_s);
    assert!(sw.pos.get(old_s).is_none() && !aw.has(old_a, POS) && !sw.despawn(old_s));
    assert!(sw.pos.get(new_s) == Some(&Pos { x: 7, y: 7 }) && aw.get(new_a).0 == Some(&Pos { x: 7, y: 7 }));
    println!(
        "stale id check: despawned {}v{}, respawn reused it as {}v{}; the old id resolves to nothing in both storages",
        old_s.index, old_s.generation, new_s.index, new_s.generation
    );
}

fn main() {
    let args = parse_args();
    let n = args.n;
    let k = (n / 16).max(1);
    stale_id_demo();

    let (mut sw, mut aw) = (SparseWorld::default(), ArchWorld::default());
    for i in 0..n {
        let (p, v, h) = initial(i);
        let (a, b) = (sw.spawn(p, v, h), aw.spawn(p, v, h));
        debug_assert_eq!(a, b);
    }
    println!(
        "{n} entities: Pos {}, Vel {}, Hp {}; Entity = {} B, sparse slot = 4 B",
        sw.pos.len(),
        sw.vel.len(),
        sw.hp.len(),
        size_of::<Entity>()
    );

    // 1. structural churn: toggle Vel on k random entities per run (8 runs incl. warm-up)
    let mut rng = Rng(SEED);
    let runs = bench_runs(|| sparse_toggle(&mut sw, &mut rng, k));
    emit_bench("ch09-churn", "sparse set: toggle Vel", k, &runs);
    let ss = runs[RUNS / 2];
    let mut rng = Rng(SEED);
    let runs = bench_runs(|| arch_toggle(&mut aw, &mut rng, k));
    emit_bench("ch09-churn", "archetype: toggle Vel", k, &runs);
    let ar = runs[RUNS / 2];
    println!(
        "churn, {k} toggles: sparse {:.1} ns/op, archetype {:.1} ns/op; Vel now on {} | {} entities",
        ss.as_nanos() as f64 / k as f64,
        ar.as_nanos() as f64 / k as f64,
        sw.vel.len(),
        aw.count_with(VEL)
    );
    println!("archetype table sizes by mask [-, P, V, PV, H, PH, VH, PVH]: {:?}", aw.table_sizes());

    // 2. iteration: the same two systems over both storages
    for (label, sys_s, sys_a) in [
        ("move P+=V", sparse_move as fn(&mut SparseWorld) -> u64, arch_move as fn(&mut ArchWorld) -> u64),
        ("damage P,V->H", sparse_damage, arch_damage),
    ] {
        let rs = bench_runs(|| sys_s(&mut sw));
        let ra = bench_runs(|| sys_a(&mut aw));
        emit_bench("ch09-iterate", &format!("sparse set: {label}"), n, &rs);
        emit_bench("ch09-iterate", &format!("archetype: {label}"), n, &ra);
        println!(
            "{label:<14} sparse {:>7.2} ns/entity  archetype {:>7.2} ns/entity  ({:.1}x)",
            rs[RUNS / 2].as_nanos() as f64 / n as f64,
            ra[RUNS / 2].as_nanos() as f64 / n as f64,
            rs[RUNS / 2].as_secs_f64() / ra[RUNS / 2].as_secs_f64()
        );
    }

    let (cs, ca) = (sparse_checksum(&sw), arch_checksum(&aw));
    println!("checksum sparse {cs:#018x} archetype {ca:#018x} {}", if cs == ca { "(match)" } else { "MISMATCH" });
    assert_eq!(cs, ca, "the two storages disagree");
}
