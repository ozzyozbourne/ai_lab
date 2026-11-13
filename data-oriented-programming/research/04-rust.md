# 04 — Rust slice: Rust 1.100 / edition 2024 idiom cheat-sheet for data-oriented design

Toolchain checked: `rustc 1.100.0 (0ef1bc386 2026-11-09)`, `cargo 1.100.0 (3acc79c0c 2026-11-05)`.
I checked stability attributes against `~/langsrc/rust` at commit `8eb778d04094d3af4b26580cab327e0413eb1e02` (2026-11-12) and its `RELEASES.md`.
Probe crate: `/tmp/rustprobe/probe` (`cargo new`, `edition = "2024"`, no dependencies), with bins `layout`, `aos_soa`, `genarena`, `vectorize`, `idioms`, `parallel`. Asm probes are in `/tmp/rustprobe/asm`.
Test machine: an orb with 4 vCPUs, "Intel Xeon Processor @ 2.60GHz", AVX2 detected at runtime. Use the numbers to show direction only; they are not hard benchmarks.

**Build status:** `cargo build --release --bins` gives **0 rustc warnings** for every snippet below. `cargo clippy` gives 3 style lints, listed in §9.

---

## 0. TL;DR facts for the book (all verified)

| Claim | Status in 1.100 | Evidence |
|---|---|---|
| `std::simd` / `core::simd` (portable SIMD) | **Still unstable** (nightly only) | `library/std/src/lib.rs:663` and `library/core/src/lib.rs:395`: `#[unstable(feature = "portable_simd", issue = "86656")]`. Using `std::simd::f32x8` on stable fails with `error[E0658]: use of unstable library feature 'portable_simd'` |
| `std::arch` x86 intrinsics | Stable since 1.27; **safe to call inside a matching `#[target_feature]` fn since 1.87**. Pointer loads/stores still need `unsafe` | RELEASES.md 1.87 Libraries; stdarch `#[stable(feature = "simd_x86", since = "1.27.0")]` |
| `#[target_feature]` on a *safe* fn | Stable 1.86 | RELEASES.md 1.86 "Allow safe functions to be marked with the #[target_feature] attribute" |
| `std::alloc::Allocator`, `Vec::new_in`, `Vec::with_capacity_in`, `Box::new_in` | **Stable 1.100.0** (new!) | `core/src/alloc/mod.rs:233` `#[stable(feature = "allocator_api", since = "1.100.0")]`; `alloc/src/vec/mod.rs:1029` |
| `AllocatorClone`, other allocator extras | Unstable (`allocator_ext`, #163177) | `core/src/alloc/mod.rs:580` |
| Never type `!` | Stable 1.100 (`Infallible` is now an alias of `!`) | RELEASES.md 1.100 |
| `core::mem::DropGuard`, `Vec::from_fn`, `bool::toggle`, `Box::map` | Stable 1.100 | RELEASES.md 1.100 Stabilized APIs |
| `hint::black_box` | Stable 1.66, const 1.86 | `core/src/hint.rs:488-489` |
| `hint::select_unpredictable` | Stable 1.88 | `core/src/hint.rs:830` |
| `hint::cold_path` | Stable 1.95 | `core/src/hint.rs` `#[stable(feature = "cold_path", since = "1.95.0")]` |
| `slice::chunk_by` | 1.77 | RELEASES.md |
| `mem::offset_of!` | 1.77 (nested fields 1.82) | RELEASES.md |
| `LazyLock` / `LazyCell` | 1.80 (`LazyLock::get`/`force_mut` 1.94) | `std/src/sync/lazy_lock.rs:80` |
| `<[[T;N]]>::as_flattened(_mut)` | 1.80 (const 1.87) | RELEASES.md |
| inline `const { }` blocks | 1.79 | RELEASES.md |
| `iter::repeat_n`, `Box/Rc/Arc::new_uninit` | 1.82 | RELEASES.md |
| `<[T]>::get_disjoint_mut`, `HashMap::get_disjoint_mut` | 1.86 | `core/src/slice/mod.rs:5225` |
| `Vec::extract_if` | 1.87 (`HashMap`/`HashSet` 1.88, `BTree*` 1.91) | `alloc/src/vec/mod.rs:4465` |
| `<[T]>::as_chunks::<N>()` / `as_chunks_mut` | 1.88 | RELEASES.md, `core/src/slice/mod.rs:1395` |
| let-chains (`if let … && let … && cond`) | 1.88, **edition 2024 only** | RELEASES.md 1.88 |
| `if let` guards on match arms | 1.95 | RELEASES.md 1.95 |
| `<[T]>::array_windows::<N>()` | 1.94 | `core/src/slice/mod.rs:1651` |
| `Vec::push_mut` / `insert_mut` | 1.95 | RELEASES.md |
| `{f32,f64}::algebraic_add/mul/…` (lets the compiler reassociate) | 1.98 | RELEASES.md 1.98 |
| `{f32,f64}::mul_add` in core | 1.94 | RELEASES.md |
| `cfg_select!` | 1.95 | RELEASES.md |
| `assert_matches!` | 1.96 | RELEASES.md |
| Edition 2024 | Stable 1.85 (2025-02-20) | RELEASES.md 1.85 |
| `#[bench]` | Fully destabilized in 1.88, so use `Instant` + `black_box` or a crate | RELEASES.md 1.88 |
| AVX-512 target features | 1.89 | RELEASES.md |

---

## 1. Layout: `size_of`, `align_of`, `offset_of!`, `repr`, niches

Verified program (`src/bin/layout.rs`):

```rust
// Layout facts: field reordering, repr(C), niches, alignment, offset_of!
use std::mem::{align_of, offset_of, size_of};
use std::num::NonZeroU32;

#[allow(dead_code)]
struct DefaultRepr { a: u8, b: u64, c: u8, d: u32 }

#[allow(dead_code)]
#[repr(C)]
struct CRepr { a: u8, b: u64, c: u8, d: u32 }

#[allow(dead_code)]
#[repr(C, align(64))]
struct CacheLinePadded { counter: u64 }

#[allow(dead_code)]
#[repr(u8)]
#[derive(Clone, Copy)]
enum Kind { Rock, Paper, Scissors }

// Compile-time layout guard: fails the build if the struct grows.
const _: () = assert!(size_of::<CRepr>() == 24);
const _: () = assert!(size_of::<CacheLinePadded>() == 64);

fn main() {
    println!("DefaultRepr  size={:>2} align={}", size_of::<DefaultRepr>(), align_of::<DefaultRepr>());
    println!("CRepr        size={:>2} align={}", size_of::<CRepr>(), align_of::<CRepr>());
    println!("  offsets default: a={} b={} c={} d={}",
        offset_of!(DefaultRepr, a), offset_of!(DefaultRepr, b),
        offset_of!(DefaultRepr, c), offset_of!(DefaultRepr, d));
    println!("  offsets repr(C): a={} b={} c={} d={}",
        offset_of!(CRepr, a), offset_of!(CRepr, b), offset_of!(CRepr, c), offset_of!(CRepr, d));
    println!("Option<NonZeroU32>     {}", size_of::<Option<NonZeroU32>>());
    // ... (full table below)
}
```

Output (x86_64, 1.100):

```text
DefaultRepr  size=16 align=8
CRepr        size=24 align=8
  offsets default: a=12 b=0 c=13 d=8      <- compiler reordered fields
  offsets repr(C): a=0 b=8 c=16 d=20      <- declaration order, 7+3 bytes padding
CacheLinePadded size=64 align=64
u32                    4
Option<u32>            8      <- no niche, so a tag is added and padded to align
Option<NonZeroU32>     4      <- niche: 0 encodes None
&u64 / Option<&u64>    8 / 8
Box<u64> / Option<Box<u64>>   8 / 8
Vec<u64> / Option<Vec<u64>>   24 / 24
Kind (repr u8) / Option<Kind> 1 / 1   <- unused discriminant values are the niche
bool / Option<bool>    1 / 1
char / Option<char>    4 / 4
&[u8] (fat ptr)        16
&dyn Fn() (fat ptr)    16
String                 24
() / [u8;0]            0 / 0
Result<u32, ()>        8
(u8, u32, u8) tuple    8      <- tuples are reordered too
```

DOD facts and pitfalls:
- **Default `repr(Rust)` reorders fields.** The Reference: "The ordering does not have to be the same as the order in which the fields are specified in the declaration of the type." The same struct is 16 B under `repr(Rust)` and 24 B under `repr(C)`. The Reference also warns that layout "can be changed with each compilation", so don't rely on the 16-byte order. Use `repr(C)` when you need a fixed order (FFI, GPU buffers, hand-placed hot fields).
- The perf-book says: "Rust types that are larger than 128 bytes are copied with memcpy rather than inline code." It also says the compiler reorders fields "so you do not have to worry about field ordering. But there are other ways to minimize the size of hot types": boxing rare large enum variants, using smaller integer types, and so on.
- **Layout guard idiom:** `const _: () = assert!(size_of::<T>() == N);`. It is stable, needs no macros, and fails at compile time. rustc's own `static_assert_size!` (in `compiler/rustc_index/src/lib.rs:36`) is `const _: [(); $size] = [(); ::std::mem::size_of::<$ty>()];`, and `rustc_ast` pins sizes this way, e.g. `static_assert_size!(Expr, 64)` and `static_assert_size!(Attribute, 32)`.
- `size_of`/`align_of` are in the prelude since 1.80, so `use std::mem::size_of` is optional (`aos_soa.rs` calls them without importing).
- `-Zprint-type-sizes` is nightly only. On stable, use `size_of` and `offset_of!`.
- 1.100 adds a lint against repeated `#[repr(..)]` attributes. Also new in 1.100: `repr(align)` fields inside a `repr(packed)` type trigger the deny-by-default lint `aligned_fields_in_packed`. Taking a reference to a field of a `repr(packed)` struct is an error, so use `&raw const s.field` / `ptr::read_unaligned`.
- **Niche optimization** makes `Option<Handle>` free when the handle wraps `NonZeroU32`. rustc's `newtype_index!` does the same thing: indices default to max `0xFFFF_FF00` (`rustc_index_macros/src/newtype.rs:103`), which leaves room so that `Option<Idx>` is still 4 bytes.

---

## 2. AoS vs SoA vs hot/cold split, with a std-only bench harness

Verified program (`src/bin/aos_soa.rs`). N = 1,000,000, median of 21 runs:

```rust
use std::hint::black_box;
use std::time::{Duration, Instant};

const N: usize = 1_000_000;
const RUNS: usize = 21;

/// Runs `f` RUNS times and reports the median; black_box keeps the result alive.
fn bench<R>(name: &str, mut f: impl FnMut() -> R) -> Duration {
    black_box(f()); // warm-up: page in memory, fill caches/TLB
    let mut times: Vec<Duration> = (0..RUNS)
        .map(|_| {
            let t = Instant::now();
            black_box(f());
            t.elapsed()
        })
        .collect();
    times.sort_unstable();
    let median = times[RUNS / 2];
    println!("{name:<28} median {:>9.3?}  ({:.2} ns/elem)", median, median.as_nanos() as f64 / N as f64);
    median
}

// AoS: 80-byte "fat" particle; the update only touches 24 bytes of it.
#[derive(Clone, Copy, Default)]
#[allow(dead_code)]
struct Particle {
    pos: [f32; 3], vel: [f32; 3], color: [u8; 4], name_id: u64,
    birth_time: f64, mass: f32, flags: u32, _reserved: [u64; 3],
}

// SoA: one Vec per field.
#[derive(Default)]
struct Particles {
    pos_x: Vec<f32>, pos_y: Vec<f32>, pos_z: Vec<f32>,
    vel_x: Vec<f32>, vel_y: Vec<f32>, vel_z: Vec<f32>,
    mass: Vec<f32>,
}

// Hot/cold split: the hot part stays dense; cold data lives in a parallel Vec with the same index.
#[derive(Clone, Copy, Default)]
struct HotParticle { pos: [f32; 3], vel: [f32; 3] }
#[derive(Clone, Copy, Default)]
#[allow(dead_code)]
struct ColdParticle { color: [u8; 4], name_id: u64, birth_time: f64, mass: f32, flags: u32, _reserved: [u64; 3] }

fn update_aos(ps: &mut [Particle], dt: f32) {
    for p in ps {
        p.pos[0] += p.vel[0] * dt;
        p.pos[1] += p.vel[1] * dt;
        p.pos[2] += p.vel[2] * dt;
    }
}

fn update_soa(ps: &mut Particles, dt: f32) {
    // Re-slicing to one length lets LLVM drop bounds checks and vectorize.
    let n = ps.pos_x.len();
    let (px, py, pz) = (&mut ps.pos_x[..n], &mut ps.pos_y[..n], &mut ps.pos_z[..n]);
    let (vx, vy, vz) = (&ps.vel_x[..n], &ps.vel_y[..n], &ps.vel_z[..n]);
    for i in 0..n {
        px[i] += vx[i] * dt;
        py[i] += vy[i] * dt;
        pz[i] += vz[i] * dt;
    }
}

fn update_hot(ps: &mut [HotParticle], dt: f32) {
    for p in ps {
        for k in 0..3 { p.pos[k] += p.vel[k] * dt; }
    }
}

fn sum_x_aos(ps: &[Particle]) -> f32 { ps.iter().map(|p| p.pos[0]).sum() }
fn sum_x_soa(ps: &Particles) -> f32 { ps.pos_x.iter().sum() }
// main(): build all three layouts, then run bench(...) on each; dt = black_box(0.016)
```

Output:

```text
size_of Particle = 80 B, HotParticle = 24 B, ColdParticle = 56 B
update AoS (80 B/elem)       median   7.335ms  (7.34 ns/elem)
update hot/cold (24 B/elem)  median   1.335ms  (1.33 ns/elem)
update SoA (24 B/elem)       median 801.375µs  (0.80 ns/elem)
sum pos.x AoS                median   5.407ms  (5.41 ns/elem)
sum pos.x SoA                median   1.221ms  (1.22 ns/elem)
speedup update: hot/cold 5.5x, SoA 9.2x; sum: SoA 4.4x
```

Teaching points:
- The bytes the loop touches decide the cost. In AoS the loop uses 24 of every 80 bytes, so it pulls about 3.3× more memory than it needs. The hot/cold split gets most of the win while keeping a struct; SoA adds full vectorization on top.
- Bounds-check idiom: `let x = &mut v[..n];` before the loop, or use iterators/`zip`. The perf-book lists "make a slice of the Vec before the loop and then index into the slice", "use iteration", and "add assertions on the ranges".
- The SoA `Particles` above is hand-rolled, which is fine for a book. In practice, `soa_derive` (`#[derive(StructOfArray)]` generates a `CheeseVec` with one `Vec` per field) and `soa-rs` (`#[derive(Soars)]`, one allocation for all fields) automate it. These are crates, so don't use them in the book's std-only examples.
- Harness rules: warm up once, take the **median**, wrap inputs and outputs in `black_box`, build with `--release`. The std docs say `black_box` is "best-effort" and "cannot rely on black_box for correctness", but "can generally be relied upon for benchmarking, and should be used there". `#[bench]` is no longer usable on stable (destabilized 1.88), so `Instant` + `black_box` is the std-only answer. Criterion and Divan are the crate options the perf-book names.
- `{:?}` on `Duration` with precision (`{:>9.3?}`) prints values like `801.375µs`.

---

## 3. Generational-index arena (std only, no `unsafe`)

Verified program (`src/bin/genarena.rs`). It uses edition 2024 let-chains, `NonZeroU32` niches, and `get_disjoint_mut`:

```rust
use std::marker::PhantomData;
use std::num::NonZeroU32;

/// Typed handle: 8 bytes, Copy, and Option<Handle<T>> is still 8 bytes (niche in NonZeroU32).
pub struct Handle<T> {
    index: u32,
    generation: NonZeroU32,
    _marker: PhantomData<fn() -> T>,
}
// Manual impls: derive would wrongly require T: Copy/Eq.
impl<T> Clone for Handle<T> { fn clone(&self) -> Self { *self } }
impl<T> Copy for Handle<T> {}
impl<T> PartialEq for Handle<T> {
    fn eq(&self, o: &Self) -> bool { self.index == o.index && self.generation == o.generation }
}
impl<T> Eq for Handle<T> {}
impl<T> std::fmt::Debug for Handle<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Handle({}v{})", self.index, self.generation)
    }
}

enum Slot<T> {
    Occupied { generation: NonZeroU32, value: T },
    Free { generation: NonZeroU32, next_free: Option<u32> },
}

pub struct Arena<T> { slots: Vec<Slot<T>>, free_head: Option<u32>, len: usize }

impl<T> Arena<T> {
    pub const fn new() -> Self { Self { slots: Vec::new(), free_head: None, len: 0 } }

    pub fn insert(&mut self, value: T) -> Handle<T> {
        if let Some(index) = self.free_head
            && let Slot::Free { generation, next_free } = self.slots[index as usize]
        {
            self.free_head = next_free;
            self.slots[index as usize] = Slot::Occupied { generation, value };
            self.len += 1;
            return Handle { index, generation, _marker: PhantomData };
        }
        let index = u32::try_from(self.slots.len()).expect("arena full");
        let generation = NonZeroU32::MIN;
        self.slots.push(Slot::Occupied { generation, value });
        self.len += 1;
        Handle { index, generation, _marker: PhantomData }
    }

    pub fn remove(&mut self, h: Handle<T>) -> Option<T> {
        let slot = self.slots.get_mut(h.index as usize)?;
        match slot {
            Slot::Occupied { generation, .. } if *generation == h.generation => {
                // Bump generation so stale handles stop matching (wrap back to 1, never 0).
                let next_gen = generation.checked_add(1).unwrap_or(NonZeroU32::MIN);
                let old = std::mem::replace(slot, Slot::Free { generation: next_gen, next_free: self.free_head });
                self.free_head = Some(h.index);
                self.len -= 1;
                match old {
                    Slot::Occupied { value, .. } => Some(value),
                    Slot::Free { .. } => unreachable!(),
                }
            }
            _ => None,
        }
    }

    pub fn get(&self, h: Handle<T>) -> Option<&T> {
        match self.slots.get(h.index as usize)? {
            Slot::Occupied { generation, value } if *generation == h.generation => Some(value),
            _ => None,
        }
    }

    pub fn get_mut(&mut self, h: Handle<T>) -> Option<&mut T> {
        match self.slots.get_mut(h.index as usize)? {
            Slot::Occupied { generation, value } if *generation == h.generation => Some(value),
            _ => None,
        }
    }

    /// Two live, distinct handles -> two &mut at once (no RefCell, no unsafe).
    pub fn get2_mut(&mut self, a: Handle<T>, b: Handle<T>) -> Option<[&mut T; 2]> {
        let [sa, sb] = self.slots.get_disjoint_mut([a.index as usize, b.index as usize]).ok()?;
        match (sa, sb) {
            (Slot::Occupied { generation: ga, value: va }, Slot::Occupied { generation: gb, value: vb })
                if *ga == a.generation && *gb == b.generation => Some([va, vb]),
            _ => None,
        }
    }

    pub fn len(&self) -> usize { self.len }

    pub fn iter(&self) -> impl Iterator<Item = (Handle<T>, &T)> {
        self.slots.iter().enumerate().filter_map(|(i, s)| match s {
            Slot::Occupied { generation, value } =>
                Some((Handle { index: i as u32, generation: *generation, _marker: PhantomData }, value)),
            Slot::Free { .. } => None,
        })
    }
}
```

Output:

```text
size_of Handle<Entity>         = 8
size_of Option<Handle<Entity>> = 8
size_of Slot<Entity>           = 32
after trade: Some(Entity { name: "orc", hp: 7 }) Some(Entity { name: "elf", hp: 10 })
removed Some(Entity { name: "orc", hp: 7 }); stale lookup = None
goblin reuses slot: Handle(0v2) vs stale Handle(0v1); get(orc) = None
  live Handle(0v2) -> Entity { name: "goblin", hp: 6 }
  live Handle(1v1) -> Entity { name: "elf", hp: 10 }
len = 2
```

Notes:
- `get_disjoint_mut` returns `Err` for overlapping or out-of-bounds indices, so `get2_mut(elf, elf)` returns `None`. The probe asserts this.
- `PhantomData<fn() -> T>` makes the handle `Send`/`Sync` and covariant whatever `T` is, and it doesn't imply ownership of a `T`.
- In edition 2024, `impl Iterator` in return position captures all in-scope lifetimes (the RPIT capture rules), so `iter()` needs no `+ '_`.
- Possible upgrade to show: the "struct of arrays" version keeps `generations: Vec<u32>` separate from `values: Vec<MaybeUninit<T>>`. That makes the generation-check scan dense. It needs `unsafe`, so keep it optional.
- West's version has the allocator separate from the storage ("GenerationalIndexAllocator" + "GenerationalIndexArray"). One allocator can then key many component arrays, which is the ECS shape. Use this to bridge into the ECS chapter.

---

## 4. Autovectorization: `chunks_exact`, `as_chunks`, `std::arch`

Verified program (`src/bin/vectorize.rs`):

```rust
use std::hint::black_box;
use std::time::Instant;

/// Naive: float add is not associative, so LLVM will NOT vectorize this reduction.
fn sum_naive(xs: &[f32]) -> f32 { xs.iter().sum() }

/// 8 independent accumulators: LLVM maps `acc` onto SIMD registers.
fn sum_chunks_exact(xs: &[f32]) -> f32 {
    let mut acc = [0.0_f32; 8];
    let chunks = xs.chunks_exact(8);
    let tail = chunks.remainder();
    for c in chunks {
        for i in 0..8 { acc[i] += c[i]; }
    }
    acc.iter().sum::<f32>() + tail.iter().sum::<f32>()
}

/// Same idea with as_chunks (stable 1.88): yields &[[f32; 8]] so the length is in the type.
fn sum_as_chunks(xs: &[f32]) -> f32 {
    let (chunks, tail) = xs.as_chunks::<8>();
    let mut acc = [0.0_f32; 8];
    for c in chunks {
        for i in 0..8 { acc[i] += c[i]; }
    }
    acc.iter().sum::<f32>() + tail.iter().sum::<f32>()
}

/// Explicit AVX2 intrinsics; safe to call only after runtime feature detection.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
fn sum_avx2(xs: &[f32]) -> f32 {
    use std::arch::x86_64::*;
    let (chunks, tail) = xs.as_chunks::<8>();
    // Since 1.87 value-only intrinsics are safe inside a matching #[target_feature] fn;
    // only the pointer load/store still needs `unsafe`.
    let mut acc = _mm256_setzero_ps();
    for c in chunks {
        let v = unsafe { _mm256_loadu_ps(c.as_ptr()) };
        acc = _mm256_add_ps(acc, v);
    }
    let mut lanes = [0.0_f32; 8];
    unsafe { _mm256_storeu_ps(lanes.as_mut_ptr(), acc) };
    lanes.iter().sum::<f32>() + tail.iter().sum::<f32>()
}

fn time(name: &str, f: impl Fn() -> f32) {
    black_box(f());
    let mut best = f64::MAX;
    let mut r = 0.0;
    for _ in 0..11 {
        let t = Instant::now();
        r = black_box(f());
        best = best.min(t.elapsed().as_secs_f64());
    }
    println!("{name:<18} {:>8.3} ms   result {r}", best * 1e3);
}

fn main() {
    let xs: Vec<f32> = (0..8_000_003).map(|i| (i % 7) as f32).collect();
    let xs = black_box(xs);
    time("naive iter().sum", || sum_naive(&xs));
    time("chunks_exact x8", || sum_chunks_exact(&xs));
    time("as_chunks::<8>", || sum_as_chunks(&xs));
    #[cfg(target_arch = "x86_64")]
    if is_x86_feature_detected!("avx2") {
        // SAFETY: we just checked the CPU supports AVX2.
        time("avx2 intrinsics", || unsafe { sum_avx2(&xs) });
    }
}
```

Output (8,000,003 f32, best of 11):

```text
naive iter().sum     10.153 ms   result 23656060     <- wrong! f32 precision loss with one serial accumulator
chunks_exact x8       1.734 ms   result 24000002
as_chunks::<8>        1.728 ms   result 24000002
avx2 intrinsics       1.412 ms   result 24000002
```

Asm check (`rustc --edition 2024 --crate-type=lib -C opt-level=3 --emit asm`, default x86-64 baseline = SSE2):
- `sum_naive`: the inner loop is 8× unrolled **scalar `addss`**. It does not vectorize because float addition isn't associative and LLVM keeps strict order.
- `sum_chunks` (as_chunks + 8 accumulators): **`addps`**, i.e. packed SSE.
- `sum_i32` (`xs.iter().sum::<i32>()`): **`paddd`**. Integer reductions vectorize with no help.
- Even with `-C target-cpu=native`, `sum_naive` emitted no packed adds.

Points for the book:
1. "Write the loop so the compiler can see the independence." Multiple accumulators give a ~5.9× speedup on stable with no `unsafe`. As a bonus they are more accurate here, since the naive sum's result is wrong, which makes a great sidebar.
2. `as_chunks::<N>()` (1.88) is the modern idiom: `&[[T; N]]` plus a tail, with the chunk length in the type. Clippy now flags `chunks_exact(8)` with a constant and suggests it ("using `chunks_exact` with a constant chunk size").
3. Explicit SIMD on stable means `std::arch` + `#[target_feature(enable = "...")]` + `is_x86_feature_detected!`. Calling the `target_feature` fn from a non-feature context is `unsafe`. Inside it, arithmetic intrinsics are safe (1.87).
4. `-C target-cpu=native` or `RUSTFLAGS="-C target-cpu=x86-64-v3"` unlocks AVX2 codegen globally, at the cost of portability.
5. `f32::algebraic_add` / `algebraic_mul` (1.98) let LLVM reassociate float math. I did not probe them; the Sesame Disk article (2026) says they let the compiler auto-vectorize float loops that were previously ineligible. **Unverified:** run one asm check before printing this claim.
6. `std::simd` is **not stable**. Book code must not use it. If shown, mark it nightly-only with `#![feature(portable_simd)]`. Blockers are tracked in rust-lang/portable-simd#364 (lane-count restrictions, swizzle API, trait shape).

---

## 5. Recent idioms useful in DOD code (all compile and run on 1.100)

Verified program (`src/bin/idioms.rs`):

```rust
use std::alloc::{AllocError, Allocator, Layout};
use std::cell::Cell;
use std::collections::HashMap;
use std::ptr::NonNull;
use std::sync::LazyLock;

// LazyLock (1.80): lazily built global lookup table.
static SIN_TABLE: LazyLock<[f32; 256]> =
    LazyLock::new(|| std::array::from_fn(|i| (i as f32 / 256.0 * std::f32::consts::TAU).sin()));

/// A minimal bump (linear) arena usable with Vec::new_in / Box::new_in (Allocator stable in 1.100).
/// Deallocation is a no-op; everything is freed when the arena's backing buffer drops.
struct Bump { buf: Box<[u8]>, used: Cell<usize> }
impl Bump {
    fn with_capacity(n: usize) -> Self { Self { buf: vec![0u8; n].into_boxed_slice(), used: Cell::new(0) } }
    fn reset(&mut self) { self.used.set(0); } // &mut self: no outstanding allocations can exist
}
unsafe impl Allocator for Bump {
    fn allocate(&self, layout: Layout) -> Result<NonNull<[u8]>, AllocError> {
        let base = self.buf.as_ptr() as usize;
        let start = (base + self.used.get()).next_multiple_of(layout.align()) - base;
        let end = start.checked_add(layout.size()).ok_or(AllocError)?;
        if end > self.buf.len() { return Err(AllocError); }
        self.used.set(end);
        let ptr = unsafe { NonNull::new_unchecked(self.buf.as_ptr().add(start) as *mut u8) };
        Ok(NonNull::slice_from_raw_parts(ptr, layout.size()))
    }
    unsafe fn deallocate(&self, _ptr: NonNull<u8>, _layout: Layout) {}
}

fn main() {
    // let-chains (edition 2024, stable 1.88)
    let cfg: HashMap<&str, i32> = HashMap::from([("threads", 4)]);
    if let Some(&t) = cfg.get("threads")
        && t > 1
        && let Ok(n) = u8::try_from(t)
    {
        println!("let-chain: {n} threads");
    }

    // inline const (1.79): array repeat of a non-Copy type
    let buckets: [Vec<u32>; 4] = [const { Vec::new() }; 4];

    // slice::chunk_by (1.77): run-length groups in sorted data
    let keys = [1, 1, 2, 2, 2, 5, 7, 7];
    let runs: Vec<(i32, usize)> = keys.chunk_by(|a, b| a == b).map(|g| (g[0], g.len())).collect();

    // array_windows (1.94): fixed-size windows as &[T; N]
    let deltas: Vec<i32> = keys.array_windows().map(|[a, b]| b - a).collect();

    // as_flattened (1.80): view [[f32;3]] as flat [f32]
    let positions = [[1.0f32, 2.0, 3.0], [4.0, 5.0, 6.0]];
    let flat: &[f32] = positions.as_flattened();

    // get_disjoint_mut (1.86): two &mut into one slice
    let mut hp = [10, 20, 30];
    if let Ok([a, c]) = hp.get_disjoint_mut([0, 2]) { std::mem::swap(a, c); }

    // hint::select_unpredictable (1.88) + hint::cold_path (1.95)
    let xs = [3, -1, 4, -1, 5];
    let clamped: Vec<i32> = xs.iter().map(|&x| std::hint::select_unpredictable(x < 0, 0, x)).collect();
    for &x in &xs { if x < 0 { std::hint::cold_path(); /* rare error path */ } }

    // Vec::extract_if (1.87): remove-and-collect matching items in one pass
    let mut alive = vec![1, 0, 3, 0, 5];
    let dead: Vec<i32> = alive.extract_if(.., |hp| *hp == 0).collect();

    println!("LazyLock table[64] = {:.3}", SIN_TABLE[64]);

    // Allocator API (stable 1.100): per-frame bump arena
    let mut frame = Bump::with_capacity(1 << 16);
    for f in 0..3 {
        {
            let mut scratch: Vec<u64, &Bump> = Vec::with_capacity_in(100, &frame);
            scratch.extend((0..100).map(|i| i * f));
            let b = Box::new_in([0u8; 32], &frame);
            println!("frame {f}: scratch sum {} used {} B, box len {}",
                scratch.iter().sum::<u64>(), frame.used.get(), b.len());
        }
        frame.reset();
    }
    let _ = (buckets, runs, deltas, flat, clamped, dead);
}
```

(The real probe prints each value; I collapsed the printlns here. Output: `chunk_by runs: [(1, 2), (2, 3), (5, 1), (7, 2)]`, `array_windows deltas: [0, 1, 0, 0, 3, 2, 0]`, `get_disjoint_mut swap: [30, 20, 10]`, `select_unpredictable: [3, 0, 4, 0, 5]`, `extract_if: alive=[1, 3, 5] dead=[0, 0]`, `LazyLock table[64] = 1.000`, `frame N: … used 832 B, box len 32` for every frame, which shows the reset works.)

Allocator notes (new in 1.100, a big deal for a DOD book because it matches Zig/Odin arenas):
- The trait is `unsafe` to implement. Required methods are `allocate` and `deallocate`; `grow`, `shrink`, and `allocate_zeroed` have defaults.
- Per the safety contract (source comments; also Microsoft/techinnovateit notes), allocation methods **must not unwind**.
- Borrowing the arena (`&Bump`) ties each `Vec`'s lifetime to it, and `reset(&mut self)` can't be called while any `Vec<_, &Bump>` is alive. **The borrow checker enforces "no use after frame reset"**, which is a strong contrast to Zig/Odin.
- Only `Vec` and `Box` (plus `Rc`/`Arc` for some impls) are allocator-generic on stable. `HashMap`, `String`, and the other collections are not yet. The 1.100 blog post: "currently `Vec` and `Box`".
- The `Bump` above (`Box<[u8]>` buffer + `Cell` cursor) is simplified. The `Allocator` docs warn that "an allocator of the type MyAlloc([u8; N]) cannot be soundly created without being pinned". My version heap-allocates the buffer, so moving `Bump` doesn't move the bytes. Keep it that way in the book.

---

## 6. Parallelism with std only (`thread::scope`) and false sharing

Verified program (`src/bin/parallel.rs`):

```rust
use std::hint::black_box;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Instant;

#[derive(Default)]
struct Packed { a: AtomicU64, b: AtomicU64 } // same 64-byte line

#[derive(Default)]
#[repr(align(64))]
struct Padded(AtomicU64);

const ITERS: u64 = 20_000_000;

fn main() {
    // 1) Split a column into disjoint &mut chunks, one per thread (no locks, no unsafe).
    let mut xs: Vec<f32> = (0..8_000_000).map(|i| i as f32).collect();
    let threads = thread::available_parallelism().map_or(4, |n| n.get());
    let chunk = xs.len().div_ceil(threads);
    thread::scope(|s| {
        for part in xs.chunks_mut(chunk) {
            s.spawn(move || for x in part { *x = *x * 0.5 + 1.0; });
        }
    });

    // 2) False sharing: two threads hammer two counters on the same cache line.
    let p = Packed::default();
    let t = Instant::now();
    thread::scope(|s| {
        s.spawn(|| (0..ITERS).for_each(|_| { p.a.fetch_add(1, Ordering::Relaxed); }));
        s.spawn(|| (0..ITERS).for_each(|_| { p.b.fetch_add(1, Ordering::Relaxed); }));
    });
    let shared = t.elapsed();
    black_box(&p);

    let q = [Padded::default(), Padded::default()];
    let t = Instant::now();
    thread::scope(|s| {
        s.spawn(|| (0..ITERS).for_each(|_| { q[0].0.fetch_add(1, Ordering::Relaxed); }));
        s.spawn(|| (0..ITERS).for_each(|_| { q[1].0.fetch_add(1, Ordering::Relaxed); }));
    });
    println!("false sharing: same line {shared:?}, padded {:?}", t.elapsed());
}
```

Output (two runs):

```text
scoped 4 threads over 8M f32: 2.345525ms (xs[10]=6)
false sharing: same line 622.951608ms, padded 127.019138ms (4.9x)
false sharing: same line 676.480741ms, padded 127.103477ms (5.3x)
size_of Packed=16 Padded=64
```

- `thread::scope` (1.63) + `chunks_mut` is the std answer to rayon's `par_chunks_mut`. Mention rayon as the production choice: "usually, you just change your `foo.iter()` call into `foo.par_iter()`" (rayon README; work-stealing; rayon 1.12, MSRV 1.80). It is an external crate, so keep it out of the core examples.
- `#[repr(align(64))]` padding gave ~5× here. Pitfall: some CPUs prefetch adjacent lines in pairs, which is why crossbeam's `CachePadded` uses 128 on x86_64. I didn't measure this; it is my inference from crossbeam's source, not something I checked here.

---

## 7. Edition 2024 changes a book reader will hit

Edition 2024 became stable in 1.85 (2025-02-20). `cargo new` defaults to `edition = "2024"` (verified).
- **Let-chains** work only in 2024 (1.88). The 1.88 blog post says they depend on the `if let` temporary scope change.
- **RPIT lifetime capture:** `-> impl Iterator<Item=&T>` captures all in-scope lifetimes. Use `+ use<..>` to narrow it (1.82).
- **`if let` temporary scope** and **tail-expression temporary scope**: temporaries drop earlier. This matters with `RefCell`/`Mutex` guards in `if let`.
- **`unsafe extern "C" { ... }`** is required. Items inside can be marked `safe fn` or `unsafe fn`.
- **Unsafe attributes:** `#[unsafe(no_mangle)]`, `#[unsafe(export_name = ..)]`, `#[unsafe(link_section = ..)]`. My asm probe used `#[unsafe(no_mangle)]`.
- **`unsafe_op_in_unsafe_fn` warns by default:** unsafe operations inside an `unsafe fn` need their own `unsafe {}` block.
- **References to `static mut` are a deny-by-default error** (`static_mut_refs`). Use atomics, `LazyLock`, `OnceLock`, or `&raw mut STATIC`.
- `gen` is a reserved keyword, so don't name variables `gen`. Generation fields in the arena must be `generation`, not `gen`. **Easy pitfall.**
- `Future`/`IntoFuture` are in the prelude.
- 1.100 compatibility notes: never-type fallback is `!` on all editions; closures capture more precisely in `if let`; `box` patterns were removed.

---

## 8. rustc's own DOD (great "Rust eats its own dog food" sidebar)

All checked in `~/langsrc/rust` @ 8eb778d0:
- **`IndexVec<I, T>`** (`compiler/rustc_index/src/vec.rs:38-43`): `#[repr(transparent)] pub struct IndexVec<I: Idx, T> { pub raw: Vec<T>, _marker: PhantomData<fn(&I)> }`. The doc comment says the index type "documents what the index is indexing", and it has a `compile_fail` test showing that `vec1[idx2]` with the wrong index type is a compile error. Quote: "While it's possible to use `u32` or `usize` directly for `I`, you almost certainly want to use a `newtype_index!`-generated type instead."
- **`newtype_index!`** (`compiler/rustc_index_macros/src/lib.rs`): "Internally, the index uses a u32", with default max `0xFFFF_FF00` (`newtype.rs:103`). The reserved values at the top give `Option<Idx>` a niche. Examples: `CrateNum`, `DefIndex` ("an interned shorthand for a particular DefPath") in `compiler/rustc_span/src/def_id.rs`.
- **Arenas** (`compiler/rustc_arena/src/lib.rs`): `TypedArena<T>` ("An arena that can hold objects of only one type", line 103) and `DroplessArena` (for `Copy` / `!needs_drop` types, line 343). Chunks grow up to `HUGE_PAGE = 2 * 1024 * 1024`.
- **Interning:** `Symbol(SymbolIndex)` is a 4-byte handle for strings (`rustc_span/src/symbol.rs:2725`). `Interned<'a, T>(pub &'a T, …)` (`rustc_data_structures/src/intern.rs:36`) compares by pointer. rustc-dev-guide: "for each interned type X, we implemented PartialEq for X, so we can just compare pointers", and "When you see a reference with a lifetime like 'tcx, you know that it refers to arena-allocated data".
- **Type-size guards:** `static_assert_size!(Expr, 64)`, `(Attribute, 32)`, `(Fn, 192)`, … in `compiler/rustc_ast/src/ast.rs:4632+`. Nethercote (2022) shrank `Attribute` from 152 to 32 bytes for "a max-rss reduction of 5.13%". He also notes that many other shrinks "didn't have much effect on performance". That is a useful honest point: measure, don't assume.

---

## 9. Pitfalls checklist

1. Forgetting `--release`: debug builds are 10-50× slower and never vectorize. (I did not measure the exact factor.)
2. A benchmark gets optimized away: use `black_box` on inputs (`black_box(0.016_f32)`) and outputs.
3. Measuring with `Instant` without a warm-up, or reporting the mean: use warm-up + median.
4. Float reductions don't vectorize by default: use multiple accumulators, `as_chunks`, or `algebraic_*` (1.98).
5. Index loops over several `Vec`s keep bounds checks: re-slice to a common `n`, or `zip` iterators.
6. `Option<u32>` is 8 bytes and `Option<NonZeroU32>` is 4. Pick handle types with niches.
7. `derive(Clone, Copy, PartialEq)` on `Handle<T>` adds `T: Clone`/`Copy`/`PartialEq` bounds, so implement them by hand.
8. Assuming `repr(Rust)` field order, or relying on it across compilations. Only `repr(C)` / `repr(transparent)` / primitive reprs give guarantees.
9. Using `std::simd` in book code: it won't build on stable 1.100.
10. Variables named `gen` fail to parse in edition 2024.
11. `static mut` for global tables is a deny lint in 2024. Use `LazyLock` / `const` tables.
12. Clippy on the probes (style only, 3 lints): `Arena::len` without `is_empty`, `Arena::new` without `Default`, and `chunks_exact` with a constant size (suggests `as_chunks`). Add `is_empty`/`Default` in book versions, or `#[allow]` them with a note.

---

## 10. Quotes (verbatim from sources I read)

- Catherine West, blog draft of the RustConf 2018 keynote: "Rust highly rewards data-oriented design with simple, understandable ownership semantics, and this is great news because this is a really good fit for game development."
- West: "I'm convinced that 'ECS design' in games is so great because it forces you to think about your data rather than be stuck in OO mode, not because of the magic of 'structs of arrays'."
- West: "You can do a LOT with indexes into Vecs. This is way easier than self borrowing or Rc<RefCell>."
- West: "Generational indexes are never re-used because the generation will always increment, yet the 'real indexes' will always be 'small'."
- West: "ECS is just SQL for games."
- West slides: "For games, OO hurts more than it helps."
- Bevy 0.5 release notes (hybrid storage): Tables are "The default storage … Fast iteration by default … Slower add/remove operations".
- Bevy cheat book: "Table storage is optimized for fast query iteration … Sparse-Set storage is optimized for fast adding/removing of a component to existing entities, at the cost of slower querying."
- hecs docs: "It is a library, not a framework. In place of an explicit 'System' abstraction, a World's entities are easily queried from regular code." Also: "specs played a key role in popularizing ECS in Rust; legion reduced boilerplate and improved cache locality".
- perf-book: "Rust types that are larger than 128 bytes are copied with memcpy rather than inline code."
- std docs on `black_box`: "only (and can only be) provided on a 'best-effort' basis … can generally be relied upon for benchmarking, and should be used there."
- Rust Reference: "The ordering does not have to be the same as the order in which the fields are specified in the declaration of the type."
- Rust 1.100 blog: "This release brings about the stabilization of the core parts of allocator_api … currently Vec and Box."

---

## 11. ECS landscape (for history and comparison paragraphs)

- **specs** (Amethyst, from about 2016): popularized ECS in Rust. Storage is chosen per component (VecStorage, DenseVecStorage, …). Amethyst's RFC #22 proposed moving from specs to **legion**, an archetypal ECS with chunked archetype storage and query filters. Amethyst was archived on 2022-04-18 (doomy.org), and legion is unmaintained (Rodney Lab).
- **hecs** (Ralith): minimalist archetypal ECS. Bevy 0.1 (Aug 2020) used "a heavily forked version of the minimalist Hecs ECS".
- **Bevy ECS V2** (0.5, 2021): a from-scratch rewrite with "a novel archetype/sparse-set hybrid storage model" and an "archetype graph". Storage is chosen per component with `#[component(storage = "SparseSet")]`; the default is Table. Bevy's own `SparseSet` docs describe it as "a sparse array mapping keys to dense indexes, plus dense arrays of indexes and keys". Discussion #19164 (2025) proposes **removing** sparse-set storage because tables plus `Option<T>` often win and the dual code paths cost complexity. This is a good, current "tradeoffs are empirical" point.
- **shipyard**: sparse-set ECS inspired by EnTT.
- **slotmap**: `SlotMap` (fastest except iteration), `HopSlotMap` (deprecated since 1.1.0), and `DenseSlotMap` ("two indirections per random access … iteration is … as fast as a normal Vec"), plus `SecondaryMap` / `SparseSecondaryMap` for attaching extra columns to the same keys. Memory per slot is `4 + max(sizeof(T), 4)`. **generational-arena** says it was "Inspired by Catherine West's closing keynote at RustConf 2018".

---

## 12. Visualization ideas

1. **Byte-level layout strip:** `DefaultRepr` vs `CRepr`, with colored field boxes and grey padding, 16 B vs 24 B, using the `offset_of!` numbers above.
2. **Cache-line ribbon:** a 64 B line under AoS `Particle` (80 B, so each particle straddles lines and only 24 B is useful, shown in red/green) next to SoA `pos_x` (16 floats per line, all useful).
3. **Bar chart:** ns/elem for AoS 7.34, hot/cold 1.33, SoA 0.80, plus the sum benchmark: 5.41 vs 1.22.
4. **Generational slot animation:** insert orc (0v1) → remove (slot 0 becomes v2 and joins the free list) → insert goblin (0v2). The stale handle 0v1 bounces off.
5. **Vectorization diagram:** one serial accumulator chain (latency-bound `addss`) vs 8 lanes (`addps`), with the timings 10.15 ms vs 1.73 ms vs 1.41 ms (AVX2), and the "wrong answer" callout for the naive sum.
6. **False-sharing diagram:** two cores ping-ponging one cache line (620 ms) vs padded lines (127 ms).
7. **ECS storage diagram:** archetype tables (columns per component, one table per component set) vs a sparse set (sparse → dense indices), with an arrow showing an entity moving between tables on component add.
8. **Bump arena timeline:** a per-frame buffer filling up, then `reset()`. The borrow checker blocks reset while a `Vec<_, &Bump>` lives.

---

## SOURCES (only pages I actually opened or saw in search results)

| URL | Title | Author | Year | Note |
|---|---|---|---|---|
| https://kyren.github.io/2018/09/14/rustconf-talk.html | My RustConf 2018 Closing Keynote (blog draft) | Catherine West | 2018 | Read in full: thesis, generational indexes, AnyMap, "ECS is SQL for games" |
| https://kyren.github.io/rustconf_2018_slides/index.html | Using Rust for Game Development (slides) | Catherine West | 2018 | "Rust rewards data-oriented design", the GenerationalIndex struct |
| https://2018.rustconf.com/program.html | RustConf 2018 Program | RustConf | 2018 | Keynote abstract |
| https://news.ycombinator.com/item?id=17977906 | Using Rust for Game Development [video], HN | various (raphlinus) | 2018 | Community reception, slotmap mention |
| https://crates.io/crates/generational-arena/0.2.0 | generational-arena | fitzgen | 2018 | "Inspired by Catherine West's closing keynote" |
| https://bevy.org/news/bevy-0-5/ | Bevy 0.5 | Carter Anderson (cart) | 2021 | Hybrid table/sparse-set storage, archetype graph |
| https://bevy.org/news/introducing-bevy/ | Introducing Bevy 0.1 | Carter Anderson | 2020 | Bevy ECS forked from hecs |
| https://bevy.org/news/bevys-first-birthday | Bevy's First Birthday | Carter Anderson | 2021 | "first hybrid Archetypal / Sparse Set ECS" |
| https://bevy-cheatbook.github.io/patterns/component-storage.html | Component Storage (Table/Sparse-Set) | Unofficial Bevy Cheat Book | n.d. | Tradeoffs, `storage = "SparseSet"` |
| https://github.com/bevyengine/bevy/discussions/19164 | Consider Removing Sparse Set Component Storage | Bevy contributors | 2025 | Current debate on whether sparse sets are worth it |
| https://docs.rs/bevy/latest/bevy/ecs/storage/struct.SparseSet.html | SparseSet in bevy::ecs::storage | Bevy | 2026 | Sparse → dense design |
| https://taintedcoders.com/bevy/archetypes | Bevy Archetypes | Tainted Coders | 2026 | Archetype vs table explanation (Bevy 0.20) |
| https://docs.rs/hecs | hecs crate docs | Benjamin Saunders (Ralith) | current | "library, not a framework", priorities |
| https://crates.io/crates/hecs/0.4.0 | hecs 0.4 README | Ralith | 2020 | Credits specs/legion |
| https://github.com/amethyst/legion | legion README | Amethyst / Tom Gillen | 2020 | Archetypal ECS |
| https://github.com/amethyst/rfcs/issues/22 | [RFC] Legion ECS Evolution | Amethyst team | 2019 | specs → legion rationale |
| https://rodneylab.com/rust-entity-component-systems | Rust Entity Component Systems | Rodney Lab | n.d. | Ecosystem overview; legion/amethyst unmaintained |
| https://doomy.org/bevys-fourth-birthday/ | Bevy's fourth birthday | doomy | 2024 | Amethyst archived 2022-04-18 |
| https://docs.rs/slotmap/latest/slotmap | slotmap docs | Orson Peters | current | SlotMap/HopSlotMap/DenseSlotMap/SecondaryMap tradeoffs |
| https://docs.rs/slotmap/latest/slotmap/struct.HopSlotMap.html | HopSlotMap | Orson Peters | current | Deprecated since 1.1.0 |
| https://docs.rs/soa_derive/latest/soa_derive | soa_derive docs | Guillaume Fraux | current | `#[derive(StructOfArray)]` |
| https://github.com/tim-harding/soa-rs | soa-rs | Tim Harding | current | `#[derive(Soars)]`, single allocation; comparison with soa_derive |
| https://rustc-dev-guide.rust-lang.org/memory.html | Memory management in rustc | rustc-dev-guide | current | Arenas, interning, `'tcx` |
| https://rustc-dev-guide.rust-lang.org/overview.html | Overview of the compiler | rustc-dev-guide | current | String interning, arena |
| https://github.com/rust-lang/rustc-dev-guide/blob/main/src/ty.md | The ty module | rustc-dev-guide | current | Types interned, so compare with == |
| https://doc.rust-lang.org/nightly/nightly-rustc/rustc_pattern_analysis/struct.IndexVec.html | IndexVec rustdoc | rustc | 2026 | Typed index doc |
| https://nnethercote.github.io/perf-book/type-sizes.html | Type Sizes, Rust Performance Book | Nicholas Nethercote et al. | 2020– | 128-byte memcpy, -Zprint-type-sizes, field reordering |
| https://nnethercote.github.io/perf-book/bounds-checks.html | Bounds Checks, Rust Performance Book | Nethercote | 2020– | Safe ways to elide checks |
| https://nnethercote.github.io/perf-book/benchmarking.html | Benchmarking, Rust Performance Book | Nethercote | 2020– | Criterion/Divan/Hyperfine; #[bench] nightly |
| https://nnethercote.github.io/perf-book/machine-code.html | Machine Code, Rust Performance Book | Nethercote | 2020– | Godbolt, cargo-show-asm, core::arch |
| https://nnethercote.github.io/perf-book/heap-allocations.html | Heap Allocations, Rust Performance Book | Nethercote | 2020– | Vec = ptr/len/cap; Box to shrink types |
| https://nnethercote.github.io/2022/10/27/how-to-speed-up-the-rust-compiler-in-october-2022.html | How to speed up the Rust compiler in October 2022 | Nethercote | 2022 | Attribute 152→32 B, −5.13% max-rss |
| https://doc.rust-lang.org/reference/type-layout.html | Type layout, Rust Reference | Rust project | current | repr(Rust)/C/align/packed guarantees |
| https://doc.rust-lang.org/std/hint/fn.black_box.html | black_box | Rust std docs | current | "best-effort" caveat |
| https://github.com/rust-lang/rust/issues/86656 | Tracking Issue for RFC 2948: Portable SIMD | rust-lang | 2021–2026 | Still open |
| https://github.com/rust-lang/portable-simd/issues/364 | Critical issues before stabilization | Caleb Zulawski | 2023 (updated 2026-08) | Stabilization blockers |
| https://doc.rust-lang.org/beta/unstable-book/library-features/portable-simd.html | portable_simd, Unstable Book | Rust project | 2026 | Feature gate |
| https://pythonspeed.com/articles/simd-stable-rust | Using portable SIMD in stable Rust | Itamar Turner-Trauring | 2024/2026 | `wide` crate as the stable alternative |
| https://sesamedisk.com/rust-simd-support-2026 | Rust SIMD Support and Performance in 2026 | Sesame Disk | 2026 | std::simd nightly-only; algebraic ops 1.98 (secondary source) |
| https://feamcor.github.io/rust-standard-library-tutorials/22_2_simd_std_arch.html | SIMD with std::arch | feamcor | 2026 | "std::simd is still unstable as of 1.99" |
| https://elsolitario.org/en/2026/08/10/vectorware-portable-simd-gpu-rust | SIMD on GPU: core::simd runs on warps | El Solitario | 2026 | Nightly-only, no stabilization date |
| https://goals.rust-lang.org/2025h1/simd-multiversioning.html | Nightly support for ergonomic SIMD multiversioning | Luca Versari / Rust Project Goals | 2025 | Multiversioning motivation |
| https://blog.rust-lang.org/2026/11/12/Rust-1.100.0 | Announcing Rust 1.100.0 | Rust Release Team | 2026 | Never type, Allocator API |
| https://releases.rs/docs/1.100.0/ | 1.100.0 changelog | releases.rs | 2026 | Branch date 2026-09-25 |
| https://doc.rust-lang.org/nightly/std/alloc/trait.Allocator.html | Allocator trait docs | Rust std | 2026 | Stable 1.100; pinning caveat |
| https://techinnovateit.com/rust-1-100-custom-allocator-api-no-unwind/ | Rust 1.100 Allocator API (JP) | techinnovateit | 2026 | No-unwind requirement (secondary source) |
| https://blog.rust-lang.org/2025/02/20/Rust-1.85.0 | Announcing Rust 1.85.0 and Rust 2024 | Rust Release Team | 2025 | Edition 2024 change list |
| https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-attributes.html | Unsafe attributes, Edition Guide | Rust project | 2025 | `#[unsafe(no_mangle)]` |
| https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-extern.html | Unsafe extern blocks, Edition Guide | Rust project | 2025 | `unsafe extern`, `safe fn` items |
| https://doc.rust-lang.org/1.85.0/edition-guide/rust-2024/rpit-lifetime-capture.html | RPIT lifetime capture rules | Rust project | 2025 | `use<..>` |
| https://dev-doc.rust-lang.org/stable/edition-guide/rust-2024/temporary-if-let-scope.html | if let temporary scope | Rust project | 2025 | Drop-order change |
| https://doc.rust-lang.org/1.85.0/edition-guide/rust-2024/temporary-tail-expr-scope.html | Tail expression temporary scope | Rust project | 2025 | Drop-order change |
| https://blog.rust-lang.org/2025/05/15/Rust-1.87.0 | Announcing Rust 1.87.0 and ten years of Rust! | Rust Release Team | 2025 | Safe arch intrinsics |
| https://blog.rust-lang.org/2025/06/26/Rust-1.88.0 | Announcing Rust 1.88.0 | Rust Release Team | 2025 | Let-chains (edition 2024 only), naked fns |
| https://docs.rs/crate/rayon/latest | rayon 1.12.0 | rayon-rs (Niko Matsakis, Josh Stone) | 2026 | `par_iter`, work-stealing, MSRV 1.80 |
| https://docs.rs/rayon/latest/rayon/slice/trait.ParallelSliceMut.html | ParallelSliceMut | rayon-rs | current | `par_chunks_mut` |
| https://fyrox-book.github.io/performance/index.html | Performance, Fyrox Book | Fyrox | n.d. | Counterpoint: generational pools instead of ECS |
| https://users.rust-lang.org/t/brainstorming-ecs-for-compilers/21775 | Brainstorming ECS for Compilers | CAD97 et al. | 2018 | ECS beyond games |
| Local: `~/langsrc/rust` @ 8eb778d04094d3af4b26580cab327e0413eb1e02 | rust-lang/rust source + RELEASES.md | rust-lang | 2026-11-12 | Ground truth for every stability claim |

Not verified / gaps:
- I did not watch the YouTube video; quotes come from West's blog draft and slides.
- I did not open the Rust Performance Book chapter on general "Iterators".
- I did not separately read the 1.98 announcement for `algebraic_*` vectorization; I saw only RELEASES.md and the secondary Sesame Disk article.
- The crossbeam 128-byte padding claim is from memory and not re-checked here.
