// Chapter 5: Indices, Handles and Generations.
//   1. A generational pool (src/pool.rs) and a stale-handle demo (unit tests: `cargo test -p ch05_indices_handles`).
//   2. The same binary search tree built two ways: individually boxed nodes linked by pointers,
//      and one Vec of nodes linked by typed u32 indices. Memory per node and traversal time.
//   3. What the generation check costs: random lookups through Vec indices vs pool handles.
// Usage: cargo run --release -p ch05_indices_handles -- [N] [--quick]

mod pool;

use pool::{Handle, Pool};
use std::num::NonZeroU32;

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

/// Memory figures are not times: "ns" is 0 and "value" carries bytes per node.
fn emit_memory(label: &str, n: usize, bytes_per_node: f64) {
    println!(
        "BENCH {{\"id\":\"ch05-memory\",\"label\":\"{label}\",\"lang\":\"rust\",\"n\":{n},\"ns\":0,\"value\":{bytes_per_node:.2},\"unit\":\"B/node\"}}"
    );
}

/// splitmix64: the same key sequence in all three languages.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
}

fn keys(n: usize) -> Vec<u32> {
    let mut r = Rng(42);
    (0..n).map(|_| (r.next() >> 32) as u32).collect()
}

// ---------------------------------------------------------------------------
// Pointer tree: every node is its own heap allocation.
// ---------------------------------------------------------------------------
struct PNode {
    key: u32,
    left: Option<Box<PNode>>, // 8 bytes: Box is never null, so None uses the null niche
    right: Option<Box<PNode>>,
}
const _: () = assert!(size_of::<PNode>() == 24); // 4 + 4 padding + 8 + 8, align 8

/// Inserts `key` and returns the depth it landed at (the sum of depths is our build checksum).
fn ptr_insert(root: &mut Option<Box<PNode>>, key: u32) -> u64 {
    let mut cur = root;
    let mut depth = 0;
    while let Some(node) = cur {
        cur = if key < node.key { &mut node.left } else { &mut node.right };
        depth += 1;
    }
    *cur = Some(Box::new(PNode { key, left: None, right: None }));
    depth
}

/// In-order walk folding the keys into an order-sensitive hash.
fn ptr_walk(node: &Option<Box<PNode>>, mut h: u64) -> u64 {
    if let Some(n) = node {
        h = ptr_walk(&n.left, h);
        h = h.wrapping_mul(31).wrapping_add(n.key as u64);
        h = ptr_walk(&n.right, h);
    }
    h
}

/// Lowest and highest node address: how far apart the allocator put the nodes.
fn ptr_span(node: &Option<Box<PNode>>, lo: &mut usize, hi: &mut usize) {
    if let Some(n) = node {
        let a = (&raw const **n).addr(); // pointer -> integer is safe; we never go back
        *lo = (*lo).min(a);
        *hi = (*hi).max(a + size_of::<PNode>());
        ptr_span(&n.left, lo, hi);
        ptr_span(&n.right, lo, hi);
    }
}

// ---------------------------------------------------------------------------
// Index tree: one Vec, links are typed 32-bit indices.
// ---------------------------------------------------------------------------
/// A node index that cannot be mixed up with any other integer. It stores index + 1 in a
/// NonZeroU32, so Option<NodeId> is 4 bytes with 0 meaning None.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct NodeId(NonZeroU32);

impl NodeId {
    fn new(index: usize) -> Self {
        let raw = u32::try_from(index + 1).expect("more than 2^32 - 1 nodes");
        NodeId(NonZeroU32::new(raw).expect("index + 1 is never 0"))
    }
    fn index(self) -> usize {
        self.0.get() as usize - 1
    }
}

struct INode {
    key: u32,
    left: Option<NodeId>,
    right: Option<NodeId>,
}
const _: () = assert!(size_of::<Option<NodeId>>() == 4);
const _: () = assert!(size_of::<INode>() == 12 && align_of::<INode>() == 4);

#[derive(Default)]
struct Tree {
    nodes: Vec<INode>,
    root: Option<NodeId>,
}

impl Tree {
    fn insert(&mut self, key: u32) -> u64 {
        let id = NodeId::new(self.nodes.len());
        self.nodes.push(INode { key, left: None, right: None });
        let Some(mut at) = self.root else {
            self.root = Some(id);
            return 0;
        };
        let mut depth = 1;
        loop {
            let n = &mut self.nodes[at.index()];
            let link = if key < n.key { &mut n.left } else { &mut n.right };
            match *link {
                Some(next) => at = next,
                None => {
                    *link = Some(id);
                    return depth;
                }
            }
            depth += 1;
        }
    }

    fn walk(&self, node: Option<NodeId>, mut h: u64) -> u64 {
        if let Some(id) = node {
            let n = &self.nodes[id.index()];
            h = self.walk(n.left, h);
            h = h.wrapping_mul(31).wrapping_add(n.key as u64);
            h = self.walk(n.right, h);
        }
        h
    }

    /// Indices are positions, not addresses, so we can move every node and fix the links:
    /// copy the tree in pre-order (a node, then its left subtree, then its right subtree).
    fn relayout_preorder(&self) -> Tree {
        let mut out = Tree { nodes: Vec::with_capacity(self.nodes.len()), root: None };
        out.root = self.copy_preorder(self.root, &mut out.nodes);
        out
    }

    fn copy_preorder(&self, node: Option<NodeId>, out: &mut Vec<INode>) -> Option<NodeId> {
        let n = &self.nodes[node?.index()];
        let me = out.len();
        out.push(INode { key: n.key, left: None, right: None });
        out[me].left = self.copy_preorder(n.left, out);
        out[me].right = self.copy_preorder(n.right, out);
        Some(NodeId::new(me))
    }
}

fn ptr_build(keys: &[u32]) -> (Option<Box<PNode>>, u64) {
    let mut root = None;
    let depth_sum = keys.iter().map(|&k| ptr_insert(&mut root, k)).sum();
    (root, depth_sum)
}

fn idx_build(keys: &[u32]) -> (Tree, u64) {
    let mut t = Tree::default();
    let depth_sum = keys.iter().map(|&k| t.insert(k)).sum();
    (t, depth_sum)
}

// ---------------------------------------------------------------------------
// The pool in action (the same story the unit tests check).
// ---------------------------------------------------------------------------
#[derive(Debug, Clone, Copy, PartialEq)]
struct Monster {
    hp: i32,
}

fn pool_demo() {
    let mut pool: Pool<Monster> = Pool::new();
    let orc = pool.insert(Monster { hp: 10 });
    let elf = pool.insert(Monster { hp: 20 });
    pool.remove(orc);
    let goblin = pool.insert(Monster { hp: 30 }); // reuses slot 0, generation 2
    println!("pool: orc={orc:?} elf={elf:?} goblin={goblin:?} (goblin reused orc's slot)");
    println!("pool: get(orc) = {:?}  <- stale handle detected", pool.get(orc));
    println!("pool: get(goblin) = {:?}", pool.get(goblin));
    assert!(pool.get(orc).is_none() && pool.get(goblin) == Some(&Monster { hp: 30 }));
    assert!(goblin.index() == orc.index() && goblin.generation() == orc.generation() + 1);
    if let Some(m) = pool.get_mut(orc) {
        m.hp = 0; // never runs: a stale handle cannot write into the goblin
    }
    if let Some([g, e]) = pool.get2_mut(goblin, elf) {
        g.hp -= 5; // the goblin hits the elf, through two &mut at once
        e.hp -= 5;
    }
    assert_eq!(pool.get(elf).map(|m| m.hp), Some(15));
    assert!(pool.get2_mut(elf, elf).is_none());
    let live: Vec<_> = pool.iter().map(|(h, m)| format!("{h:?}:{}hp", m.hp)).collect();
    println!("pool: live {}", live.join(" "));
    assert!(!pool.is_empty());
    println!(
        "pool: size_of Handle = {} B, Option<Handle> = {} B, live = {}, slots = {}",
        size_of::<Handle<Monster>>(),
        size_of::<Option<Handle<Monster>>>(),
        pool.len(),
        pool.slot_count()
    );
}

fn main() {
    let args = parse_args();
    let n = args.n;
    pool_demo();

    // ---- build both trees from the same keys ----
    let ks = keys(n);
    let (ptree, pdepth) = ptr_build(&ks);
    let (itree, idepth) = idx_build(&ks);
    let dtree = itree.relayout_preorder();
    assert_eq!(pdepth, idepth, "both trees must have the same shape");

    let (mut lo, mut hi) = (usize::MAX, 0);
    ptr_span(&ptree, &mut lo, &mut hi);
    let ptr_span_per_node = (hi - lo) as f64 / n as f64;
    let idx_cap_per_node = (itree.nodes.capacity() * size_of::<INode>()) as f64 / n as f64;
    println!(
        "tree: n={n} average depth {:.1}; pointer node {} B (heap span {ptr_span_per_node:.1} B/node), index node {} B (Vec capacity {idx_cap_per_node:.1} B/node)",
        pdepth as f64 / n as f64,
        size_of::<PNode>(),
        size_of::<INode>()
    );
    emit_memory("pointers: node size", n, size_of::<PNode>() as f64);
    emit_memory("pointers: heap span", n, ptr_span_per_node);
    emit_memory("indices: node size", n, size_of::<INode>() as f64);
    emit_memory("indices: array capacity", n, idx_cap_per_node);

    // ---- traversal: the same in-order walk, three memory layouts ----
    let p = bench_runs(|| ptr_walk(black_box(&ptree), 0));
    let i = bench_runs(|| itree.walk(black_box(itree.root), 0));
    let d = bench_runs(|| dtree.walk(black_box(dtree.root), 0));
    let (hp, hi_, hd) = (ptr_walk(&ptree, 0), itree.walk(itree.root, 0), dtree.walk(dtree.root, 0));
    println!("traverse checksum: pointers {hp:#018x}  indices {hi_:#018x}  indices/DFS {hd:#018x}");
    assert!(hp == hi_ && hi_ == hd, "checksums differ");
    for (label, r) in [("pointer nodes", &p), ("u32 indices", &i), ("u32 indices, DFS order", &d)] {
        println!("traverse {label:<24} {:>10.2?}  ({:.2} ns/node)", r[RUNS / 2], r[RUNS / 2].as_nanos() as f64 / n as f64);
        emit_bench("ch05-traverse", label, n, r);
    }

    // ---- build + free: n allocations vs one growing Vec ----
    let pb = bench_runs(|| ptr_build(black_box(&ks)).1); // the tree is dropped (freed) inside the timing
    let ib = bench_runs(|| idx_build(black_box(&ks)).1);
    println!("build+free checksum (sum of depths): pointers {pdepth}  indices {idepth}");
    for (label, r) in [("pointer nodes", &pb), ("u32 indices", &ib)] {
        println!("build+free {label:<22} {:>10.2?}", r[RUNS / 2]);
        emit_bench("ch05-build", label, n, r);
    }
    drop(ptree);

    // ---- what does the generation check cost? n random lookups ----
    let mut pool: Pool<u64> = Pool::new();
    let mut plain: Vec<u64> = Vec::with_capacity(n);
    let handles: Vec<Handle<u64>> = (0..n as u64)
        .map(|v| {
            plain.push(v);
            pool.insert(v)
        })
        .collect();
    let mut r = Rng(7);
    let order: Vec<usize> = (0..n).map(|_| (r.next() % n as u64) as usize).collect();
    let picked: Vec<Handle<u64>> = order.iter().map(|&j| handles[j]).collect();
    let lv = bench_runs(|| {
        let plain = black_box(&plain);
        black_box(&order).iter().map(|&j| plain[j]).fold(0u64, u64::wrapping_add)
    });
    let lp = bench_runs(|| {
        let pool = black_box(&pool);
        black_box(&picked).iter().map(|&h| pool.get(h).copied().unwrap_or(0)).fold(0u64, u64::wrapping_add)
    });
    let cv = order.iter().map(|&j| plain[j]).fold(0u64, u64::wrapping_add);
    let cp = picked.iter().map(|&h| *pool.get(h).unwrap()).fold(0u64, u64::wrapping_add);
    println!("lookup checksum: Vec {cv}  pool {cp}");
    assert_eq!(cv, cp);
    for (label, r) in [("array[index]", &lv), ("pool.get(handle)", &lp)] {
        println!("lookup {label:<22} {:>10.2?}  ({:.2} ns/lookup)", r[RUNS / 2], r[RUNS / 2].as_nanos() as f64 / n as f64);
        emit_bench("ch05-lookup", label, n, r);
    }
}
