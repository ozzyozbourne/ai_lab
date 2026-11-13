# Odin (dev-2026-11) idiom cheat-sheet: data-oriented design

Research slice: **Odin**, for the DOD book (Rust / Zig / Odin).
Toolchain checked: `odin version` printed `dev-2026-11-nightly:9a69916`. The source tree is at `~/langsrc/odin`, commit `9a69916…` (2026-11-03), which is the same day as the `dev-2026-11` release tag (2026-11-03). Linux x64, 4-vCPU Intel Xeon @ 2.60 GHz (an orb).
Every snippet marked **VERIFIED** below was compiled and run with `odin run <file>.odin -file` (plus the flags noted). All of them also passed `odin check <file> -file -vet -strict-style` with no warnings. The probe sources were in `/tmp/odinprobe/` and the important ones are copied in full below.

---

## 0. TL;DR: what changed and what the book must use

| Topic | Use this (current) | Do NOT use (outdated) |
|---|---|---|
| OS / files | `import "core:os"`, which **is the former os2**. `os.read_entire_file(path, context.allocator) -> ([]byte, os.Error)` | `import "core:os/os2"` (gone: "Path does not exist"), `core:os/old` (gone: removed Q3 2026 as announced), `data, ok := os.read_entire_file(path)` (old 1-arg/bool form), `os.Handle` (now `^os.File`) |
| `using` as a statement | Write `v.x` explicitly. `using` on struct **fields** is still fine | `using v` inside a proc body is now a **compile error** unless the file has `#+feature using-stmt` |
| Small inline arrays | `[dynamic; N]T` (fixed-capacity dynamic array, value type, no allocator) | `core:container/small_array` `Small_Array(N,T)`. It still compiles without a warning, but the docs say `[dynamic; N]T` "replaces" it |
| Generational handles | `core:container/handle_map` (new in 2026 Q1): `Static_Handle_Map`, `Dynamic_Handle_Map`, `Handle16/32/64`. You can also write your own (shown below) | Third-party libs only (Zylinski's odin-handle-map predates core) |
| Stable-address growable array | `core:container/xar` (exponential array, elements never move) | Pointer-into-`[dynamic]T` across appends |
| Random | `core:math/rand` procs take `gen := context.random_generator`. The default is a **thread-local chacha8rand seeded from OS entropy**. For determinism: `state := rand.create(seed); context.random_generator = rand.default_random_generator(&state)` | `rand.Rand` structs and `rand.init(&r, seed)` (old API; no such procs exist now) |
| Timing | `time.tick_now()`, `time.tick_since(t)` / `time.tick_diff(a,b)`, `time.duration_milliseconds(d)`, `time.Stopwatch`, `time.SCOPED_TICK_DURATION(&d)` | `time.now()` for benchmarks (wall clock) |
| fmt widths | **BREAKING dev-2026-11:** `%6.2f` pads with *spaces*; use `%06.2f` for zeros (C printf rules) | Assuming zero padding |
| Fast-math | `@(fast_math={.Allow_Reassoc})` (the flags bit_set is **required**; flags are `intrinsics.Fast_Math_Flag`) | bare `@(fast_math)` (error: "Expected a constant bit_set of type 'intrinsics.Fast_Math_Flags'") |
| Big bit sets | `bit_set[E; [4]u64]` (array-backed, Oct 2026) | Hand-rolled bit arrays for >128 elements |
| Uninitialised alloc | `non_zero_make([]T, n)` (new dev-2026-11) | `make` followed by overwriting everything |
| SOA dynamic | `make(#soa[dynamic]T, len, cap)`, and the plain builtins `append`, `delete`, `pop`, `unordered_remove`, `ordered_remove` work on SOA | `append_soa` / `delete_soa` still exist (the plain names are overload groups that include them), but you no longer need to spell them out |
| compress | `core:compress/deflate` | `core:compress/zlib`, `gzip` (`@(deprecated)` wrappers) |
| strconv | `strconv.write_int`, `parse_int`, `parse_f64`, `write_float` | `strconv.append_int` etc. (deprecated, see `core/strconv/deprecated.odin`) |

Optimisation flags (from `odin build -help`): `-o:none | -o:minimal (default) | -o:size | -o:speed | -o:aggressive ("use this with caution")`. Related flags: `-debug` (sets `ODIN_DEBUG`, default `-o:none`), `-microarch:native`, `-target-features:"avx2,…"`, `-no-bounds-check`, `-lto:thin`. Per-block bounds-check removal is `#no_bounds_check`. dev-2026-11 also *elides* bounds checks it can prove redundant (PR #7905).

---

## 1. Verified snippets

### 1.1 `#soa` fixed, slice and dynamic arrays, iteration, removal, zip/unzip: VERIFIED

```odin
package soa_probe

import "core:fmt"

Particle :: struct {
	pos:  [3]f32,
	vel:  [3]f32,
	mass: f32,
	id:   u32,
}

main :: proc() {
	// fixed-size SOA array
	fixed: #soa[4]Particle
	fixed[0].mass = 1        // AoS-style syntax
	fixed.mass[1] = 2        // SoA-style syntax
	assert(&fixed[0].mass == &fixed.mass[0])

	// dynamic SOA array: plain make/append/delete work
	ps := make(#soa[dynamic]Particle, 0, 1024)
	defer delete(ps)
	for i in 0..<8 {
		append(&ps, Particle{pos = {f32(i), 0, 0}, vel = {1, 2, 3}, mass = 1, id = u32(i)})
	}
	fmt.println("len", len(ps), "cap", cap(ps))

	// iterate by reference to modify in place (`&p` is required)
	dt: f32 = 0.5
	for &p in ps {
		p.pos += p.vel * dt   // array programming on [3]f32
	}
	// index-based column access
	for i in 0..<len(ps) {
		ps.pos[i].y += 1
	}
	// a whole column as a normal []f32 slice (hot loop food)
	masses := ps.mass[:len(ps)]
	total: f32
	for m in masses { total += m }
	fmt.println("total mass", total, "first", ps[0].pos)

	// SOA slice
	s: #soa[]Particle = ps[2:5]
	fmt.println("slice len", len(s), s[0].id)

	// removal (plain builtins dispatch to *_soa)
	unordered_remove(&ps, 0)   // swap-with-last, O(1)
	ordered_remove(&ps, 0)     // shifts every column, O(n)
	fmt.println("after removes len", len(ps), "ids", ps.id[:len(ps)])

	// soa_zip / soa_unzip: treat parallel slices as one SOA slice
	xs := []f32{1, 2, 3}
	ys := []f32{4, 5, 6}
	z := soa_zip(x = xs, y = ys)
	for v, i in z { fmt.println(i, v.x, v.y) }
	a, b := soa_unzip(z)
	fmt.println(a, b)

	sl := make(#soa[]Particle, 16)
	defer delete(sl)
	fmt.println(len(sl), size_of(#soa[]Particle), size_of(#soa[dynamic]Particle))

	ptr := &ps[0]                      // an SOA pointer, not ^Particle
	fmt.println(typeid_of(type_of(ptr)))
	ptr.mass = 42
	fmt.println(ps[0].mass)
}
```
Output:
```
len 8 cap 1024
total mass 8 first [0.5, 2, 1.5]
slice len 3 2
after removes len 6 ids [1, 2, 3, 4, 5, 6]
0 1 4
1 2 5
2 3 6
[1, 2, 3] [4, 5, 6]
16 40 64
#soa ^#soa[dynamic]Particle
42
```
Facts shown by this run:
- `size_of(#soa[]Particle) == 40`: one pointer per field (4) plus `len`. `size_of(#soa[dynamic]Particle) == 64`: 4 pointers, `len`, `cap`, and a 16-byte `Allocator`.
- `&ps[0]` has type `#soa ^#soa[dynamic]Particle`: a (pointer-to-container, index) pair. You **cannot** get a `^Particle` into SOA storage.
- `for p in ps { p.mass = 1 }` is a compile error: *"'p' is immutable, declare it as '&p' to make it mutable"* (VERIFIED).
- `#soa[dynamic; N]T` is **not** allowed: *"Invalid tag applied to fixed capacity dynamic array, got #soa"* (VERIFIED). Use `#soa[N]T` with your own length counter instead.

### 1.2 AoS vs SoA "sum one hot field" benchmark with timer and seeded rand: VERIFIED

```odin
package bench_probe

import "core:fmt"
import "core:math/rand"
import "core:time"

N :: 4_000_000

Entity :: struct {
	pos:    [3]f32,
	vel:    [3]f32,
	health: f32,
	name:   [32]u8, // cold data
	flags:  u32,
}

sum_health_aos :: proc(es: []Entity) -> (total: f32) {
	for e in es { total += e.health }
	return
}

sum_health_soa :: proc(es: #soa[]Entity) -> (total: f32) {
	for h in es.health[:len(es)] { total += h }
	return
}

main :: proc() {
	// deterministic seed: swap the context generator's state
	state := rand.create(12345)
	context.random_generator = rand.default_random_generator(&state)

	aos := make([]Entity, N)
	defer delete(aos)
	soa := make(#soa[]Entity, N)
	defer delete(soa)
	for i in 0..<N {
		h := rand.float32_range(0, 100)
		aos[i].health = h
		soa[i].health = h
	}

	REPS :: 10
	t0 := time.tick_now()
	a: f32
	for _ in 0..<REPS { a += sum_health_aos(aos) }
	aos_d := time.tick_since(t0)

	t1 := time.tick_now()
	b: f32
	for _ in 0..<REPS { b += sum_health_soa(soa) }
	soa_d := time.tick_since(t1)

	fmt.printfln("size_of(Entity) = %v bytes", size_of(Entity))
	fmt.printfln("AoS: %.2f ms  (sum %v)", time.duration_milliseconds(aos_d) / REPS, a)
	fmt.printfln("SoA: %.2f ms  (sum %v)", time.duration_milliseconds(soa_d) / REPS, b)
	fmt.printfln("speedup x%.1f", f64(aos_d) / f64(soa_d))

	sw: time.Stopwatch
	time.stopwatch_start(&sw)
	_ = sum_health_soa(soa)
	time.stopwatch_stop(&sw)
	fmt.println("stopwatch:", time.stopwatch_duration(sw))
	fmt.println("rand int_max:", rand.int_max(10), rand.float64())
}
```
Results on this orb (4M entities, 64-byte struct, 10 reps):

| build | AoS | SoA | speedup |
|---|---|---|---|
| `-o:speed` | 23.98 ms | 4.96 ms | **x4.8** |
| default (`-o:minimal`) | (not recorded) | 17.16 ms | x1.6 |

- This is the textbook DOD result. The AoS loop drags 64 bytes per element through cache to use 4 of them; the SoA loop streams exactly the `health` column. 4.8x is below the 16x byte ratio because the loop is a strict sequential f32 sum (a dependency chain, not vectorised) and still memory-bound.
- **Pitfall caught:** the `Stopwatch` run printed **313 ns** at `-o:speed` (versus 17 ms unoptimised). The result was discarded (`_ = ...`), so LLVM deleted the work. Always consume benchmark results (accumulate and print them, as the AoS/SoA loops do).
- `%v` on a `time.Duration` prints a human string (`17.19727ms`).

### 1.3 Allocators: tracking, `mem.Arena`, virtual arenas, temp allocator, `core:os`: VERIFIED (`-debug`)

```odin
package alloc_probe

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			for _, entry in track.allocation_map {
				fmt.eprintf("%v leaked %v bytes\n", entry.location, entry.size)
			}
			for entry in track.bad_free_array {
				fmt.eprintf("%v bad free %p\n", entry.location, entry.memory)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	// 1. Fixed-buffer arena (core:mem): bump pointer into your buffer
	buf: [4096]byte
	fa: mem.Arena
	mem.arena_init(&fa, buf[:])
	{
		context.allocator = mem.arena_allocator(&fa)
		xs := make([]int, 100)
		ys := make([dynamic]f32, 0, 16)
		append(&ys, 1, 2, 3)
		fmt.println("mem.Arena used", fa.offset, len(xs), ys[:])
	}
	free_all(mem.arena_allocator(&fa))
	fmt.println("after free_all", fa.offset)

	// 2. Growing virtual-memory arena (blocks, default 1 MiB)
	va: vmem.Arena
	err := vmem.arena_init_growing(&va)
	assert(err == nil)
	defer vmem.arena_destroy(&va)
	arena_alloc := vmem.arena_allocator(&va)
	nums := make([dynamic]int, arena_alloc)
	for i in 0..<100_000 { append(&nums, i) }
	fmt.println("vmem growing total_used", va.total_used, "reserved", va.total_reserved)

	// 3. Static virtual arena: reserve 1 GiB address space, commit lazily
	sa: vmem.Arena
	_ = vmem.arena_init_static(&sa, reserved = 1 << 30)
	defer vmem.arena_destroy(&sa)
	big := make([]u8, 64 << 20, vmem.arena_allocator(&sa))
	big[len(big)-1] = 1
	fmt.println("static arena used", sa.total_used)

	// 4. Scoped rewind of an arena
	{
		tmp := vmem.arena_temp_begin(&va)
		defer vmem.arena_temp_end(tmp)
		_ = make([]u8, 1 << 20, arena_alloc)
	}
	fmt.println("after temp end", va.total_used)

	// 5. context.temp_allocator: per-frame scratch
	s := fmt.tprintf("frame %d", 7)
	fmt.println(s)
	free_all(context.temp_allocator)

	// 6. New core:os: allocator is REQUIRED, error is os.Error
	data, rerr := os.read_entire_file("alloc.odin", context.allocator)
	if rerr == nil {
		fmt.println("read bytes", len(data) > 0)
		delete(data)
	}

	leak := new(int) // intentional, reported by the tracker
	_ = leak
}
```
Output:
```
mem.Arena used 864 100 [1, 2, 3]
after free_all 0
vmem growing total_used 1048576 reserved 1048576
static arena used 67108864
after temp end 1048576
frame 7
read bytes true
/tmp/odinprobe/alloc.odin(77:10) leaked 8 bytes
```
- The **"graveyard" effect** shows up: 100 ints (800 B) plus 16 f32 (64 B) = 864 B used. With a growing `[dynamic]` in a `mem.Arena`, old blocks are never freed (see Zylinski, §3).
- Growing vmem arena: 100k ints = 800 KB grew *in place* because the last allocation can be extended. `total_used` reports the whole 1 MiB block.
- Default-temp-allocator scope guard (VERIFIED in kernel probe): `runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()` (`import "base:runtime"`). It is a `@(deferred_out)` proc that rewinds the temp arena at scope end.
- `core:mem/virtual` API list (from source): `arena_init_growing`, `arena_init_static`, `arena_init_buffer`, `arena_allocator`, `arena_free_all`, `arena_destroy`, `arena_temp_begin/end/ignore`, `arena_growing_bootstrap_new`, `arena_static_bootstrap_new`, plus typed helpers `vmem.new`, `vmem.make`, …
- Other `core:mem` allocators: `Arena`, `Scratch` (old name `Scratch_Allocator` kept as an alias), `Dynamic_Arena` (WASM-friendly growing arena), `Rollback_Stack`, `Buddy_Allocator`, `Tracking_Allocator`, `mutex_allocator`, `panic_allocator`, plus `core:mem/tlsf`.

### 1.4 bit_set, bit_field, enumerated arrays, SIMD, matrix, array programming, `core:container/handle_map`: VERIFIED

```odin
package misc_probe

import "core:fmt"
import "core:simd"
import hm "core:container/handle_map"
import "base:intrinsics"

Flag :: enum u8 { Alive, Visible, Dirty, Selected }
Flags :: bit_set[Flag; u8]

Packed :: bit_field u32 {
	kind:  u8  | 4,
	layer: u8  | 4,
	index: u32 | 24,
}

Entity :: struct {
	handle: hm.Handle32,     // handle_map requires a `handle` field of the handle type
	pos:    [2]f32,
}

add_simd :: proc(a, b: []f32, out: []f32) {
	W :: 8
	V :: #simd[W]f32
	i := 0
	for ; i + W <= len(a); i += W {
		va := simd.from_slice(V, a[i:])
		vb := simd.from_slice(V, b[i:])
		r := simd.to_array(va * vb + va)
		copy(out[i:], r[:])
	}
	for ; i < len(a); i += 1 { out[i] = a[i]*b[i] + a[i] }   // scalar tail
}

main :: proc() {
	f: Flags = {.Alive, .Visible}
	f += {.Dirty}
	f -= {.Visible}
	fmt.println(f, .Alive in f, card(f), size_of(Flags), transmute(u8)f)

	p := Packed{kind = 3, layer = 2, index = 123456}
	p.layer = 7
	fmt.println(p, size_of(Packed), p.index)

	counts: [Flag]int
	counts[.Dirty] += 1
	fmt.println(counts)

	a := []f32{1,2,3,4,5,6,7,8,9,10}
	b := []f32{1,1,1,1,1,1,1,1,1,1}
	out := make([]f32, len(a)); defer delete(out)
	add_simd(a, b, out)
	fmt.println(out)
	v := simd.f32x4{1, 2, 3, 4}
	fmt.println(simd.reduce_add_ordered(v), simd.HAS_HARDWARE_SIMD)
	mask := simd.lanes_gt(v, simd.f32x4(2))
	fmt.println(simd.select(mask, v, simd.f32x4(0)))

	m := matrix[2, 2]f32{1, 2, 3, 4}       // literal is written row by row
	vv := [2]f32{1, 1}
	fmt.println(m * vv, m[0, 1], size_of(m))
	rm: #row_major matrix[2, 2]f32 = {1, 2, 3, 4}
	fmt.println(transmute([4]f32)m, transmute([4]f32)rm)  // storage order

	x := [3]f32{1, 2, 3}
	y := x * 2 + 1
	fmt.println(y, y.zyx, intrinsics.type_is_simd_vector(simd.f32x4))

	ents: hm.Dynamic_Handle_Map(Entity, hm.Handle32)
	hm.dynamic_init(&ents, context.allocator)
	defer hm.dynamic_destroy(&ents)
	h1 := hm.add(&ents, Entity{pos = {1, 4}})
	h2 := hm.add(&ents, Entity{pos = {9, 16}})
	hm.remove(&ents, h1)
	h3 := hm.add(&ents, Entity{pos = {6, 7}})
	fmt.println("h1", h1, "h3", h3, "h1 valid?", hm.is_valid(&ents, h1), "len", hm.len(ents))
	if e, ok := hm.get(&ents, h2); ok { e.pos.x += 32 }
	it := hm.iterator_make(&ents)
	for e, h in hm.iterate(&it) { fmt.println(h, e.pos) }
}
```
Output:
```
bit_set[Flag; u8]{Alive, Dirty} true 2 1 5
Packed{kind = 3, layer = 7, index = 123456} 4 123456
[.Alive = 0, .Visible = 0, .Dirty = 1, .Selected = 0]
[2, 4, 6, 8, 10, 12, 14, 16, 18, 20]
10 true
<0, 0, 3, 4>
[3, 7] 2 16
[1, 3, 2, 4] [1, 2, 3, 4]
[3, 5, 7] [7, 5, 3] true
h1 Handle32{idx = 1, gen = 1} h3 Handle32{idx = 1, gen = 2} h1 valid? false len 2
Handle32{idx = 1, gen = 2} [6, 7]
Handle32{idx = 2, gen = 1} [41, 16]
```
- `bit_set[Flag; u8]` is **1 byte**. A bool-per-flag struct would be 4.
- Matrices are **column-major** by default (`[1,3,2,4]`); `#row_major` stores rows (`[1,2,3,4]`). Literals are always written row by row. dev-2026-11: matrices align to the largest power of two dividing their column stride (cap 16) and have no padding.
- Handle maps reserve index 0 as a "none" sentinel, so capacity is N-1 and `Handle32` allows up to 65534 items. Slot reuse bumps `gen`, so the stale `h1` becomes invalid.
- `#simd[N]T`: N must be a power of two up to 64. `simd.HAS_HARDWARE_SIMD` exists, and named aliases (`simd.f32x4`, `f32x8`, `u8x16`, …) are available. Useful ops: `from_slice`, `to_array`, `reduce_add_ordered`/`_pairs`/`_bisect`, `lanes_lt/gt/eq…`, `select`, `gather`/`scatter`, `masked_load/store`, `shuffle`, `swizzle`, `extract_msbs`, `sqrt`, `floor`, `simd.fused_mul_add` (seen in source, not run). Platform intrinsics live in `core:simd/x86` and `core:simd/arm` (AVX2 and NEON sets were filled out in dev-2026-11).

### 1.5 Hand-rolled generational handle pool (for teaching what `handle_map` does): VERIFIED with `-vet -strict-style`

```odin
package handles_probe

import "core:fmt"

Handle :: struct {
	index: u32,
	gen:   u32,
}

Slot :: struct($T: typeid) {
	item:  T,
	gen:   u32,
	alive: bool,
}

Pool :: struct($T: typeid) {
	slots: [dynamic]Slot(T),
	free:  [dynamic]u32,
}

pool_add :: proc(p: ^Pool($T), item: T) -> Handle {
	if n := len(p.free); n > 0 {
		idx := pop(&p.free)
		s := &p.slots[idx]
		s.item, s.alive = item, true
		return {idx, s.gen}
	}
	append(&p.slots, Slot(T){item = item, gen = 1, alive = true})
	return {u32(len(p.slots) - 1), 1}
}

pool_get :: proc(p: ^Pool($T), h: Handle) -> (^T, bool) #optional_ok {
	if int(h.index) >= len(p.slots) do return nil, false
	s := &p.slots[h.index]
	if !s.alive || s.gen != h.gen do return nil, false
	return &s.item, true
}

pool_remove :: proc(p: ^Pool($T), h: Handle) {
	if _, ok := pool_get(p, h); !ok do return
	s := &p.slots[h.index]
	s.alive = false
	s.gen += 1            // bump on release (Weissflog's 2018 update)
	append(&p.free, h.index)
}

pool_destroy :: proc(p: ^Pool($T)) {
	delete(p.slots)
	delete(p.free)
}

Monster :: struct { hp: int }

main :: proc() {
	p: Pool(Monster)
	defer pool_destroy(&p)
	a := pool_add(&p, Monster{10})
	b := pool_add(&p, Monster{20})
	pool_remove(&p, a)
	c := pool_add(&p, Monster{30}) // reuses slot 0 with gen 2
	_, a_ok := pool_get(&p, a)
	m := pool_get(&p, c)           // #optional_ok: second value may be dropped
	fmt.println(a, c, "stale a ok?", a_ok, "c hp", m.hp, b)
}
```
Output: `Handle{index = 0, gen = 1} Handle{index = 0, gen = 2} stale a ok? false c hp 30 Handle{index = 1, gen = 1}`

### 1.6 SoA columns + explicit SIMD + `@(fast_math)` + temp guard: VERIFIED (`-o:speed`)

```odin
package kernel_probe

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:time"

Body :: struct {
	x, y, vx, vy: f32,
	name:         [24]u8, // cold
}

N :: 1 << 22

integrate_scalar :: proc(b: #soa[]Body, dt: f32) {
	xs, ys := b.x[:len(b)], b.y[:len(b)]
	vxs, vys := b.vx[:len(b)], b.vy[:len(b)]
	#no_bounds_check for i in 0..<len(b) {
		xs[i] += vxs[i] * dt
		ys[i] += vys[i] * dt
	}
}

integrate_simd :: proc(b: #soa[]Body, dt: f32) {
	W :: 8
	V :: #simd[W]f32
	n := len(b)
	xs, vxs := b.x[:n], b.vx[:n]
	ys, vys := b.y[:n], b.vy[:n]
	vdt := V(dt)
	i := 0
	for ; i + W <= n; i += W {
		px := (^V)(&xs[i])
		py := (^V)(&ys[i])
		// #simd[8]f32 has align 32; slice elements are only 4-aligned -> unaligned ops
		nx := intrinsics.unaligned_load(px) + intrinsics.unaligned_load((^V)(&vxs[i])) * vdt
		ny := intrinsics.unaligned_load(py) + intrinsics.unaligned_load((^V)(&vys[i])) * vdt
		intrinsics.unaligned_store(px, nx)
		intrinsics.unaligned_store(py, ny)
	}
	for ; i < n; i += 1 {
		xs[i] += vxs[i] * dt
		ys[i] += vys[i] * dt
	}
}

@(fast_math={.Allow_Reassoc})
sum_fast :: proc(xs: []f32) -> (s: f32) {
	for v in xs { s += v }
	return
}

sum_strict :: proc(xs: []f32) -> (s: f32) {
	for v in xs { s += v }
	return
}

main :: proc() {
	bodies := make(#soa[]Body, N)
	defer delete(bodies)
	for i in 0..<N { bodies[i] = {x = f32(i), vx = 1, vy = 2} }

	{
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		tmp := make([]int, 1000, context.temp_allocator)
		_ = tmp
	}

	t := time.tick_now()
	for _ in 0..<10 { integrate_scalar(bodies, 0.016) }
	d1 := time.tick_since(t)
	t = time.tick_now()
	for _ in 0..<10 { integrate_simd(bodies, 0.016) }
	d2 := time.tick_since(t)
	xs := bodies.x[:N]
	t = time.tick_now()
	s1 := sum_strict(xs)
	d3 := time.tick_since(t)
	t = time.tick_now()
	s2 := sum_fast(xs)
	d4 := time.tick_since(t)
	fmt.printfln("scalar %.2fms simd %.2fms | strict sum %.2fms fast_math sum %.2fms (%v vs %v)",
		time.duration_milliseconds(d1)/10, time.duration_milliseconds(d2)/10,
		time.duration_milliseconds(d3), time.duration_milliseconds(d4), s1, s2)
	fmt.println(bodies[1].x, align_of(#simd[8]f32))
}
```
Output (`-o:speed`): `scalar 5.55ms simd 3.91ms | strict sum 5.21ms fast_math sum 1.37ms (8.809265e+12 vs 8.796133e+12)`; `1.3200006 32`.
With `-microarch:native`: `scalar 5.24ms simd 4.99ms | strict 5.32ms fast_math 1.28ms`.
- **Teaching points:** (1) the streaming integrate is memory-bound, so hand-written SIMD buys little over the auto-vectorised scalar loop on SoA data. (2) The reduction is latency-bound. Allowing reassociation gave **~4x** and a *different* answer (8.809e12 vs 8.796e12), the classic float-ordering trade-off. (3) `#simd[8]f32` has `align_of == 32`. Casting `&xs[i]` to `^#simd[8]f32` and dereferencing it assumes 32-byte alignment, so use `intrinsics.unaligned_load/store` or `simd.from_slice`, or allocate with `make_aligned([]f32, n, 64)`.

### 1.7 New in 2026: fixed-capacity dynamic arrays, array-backed bit sets, `non_zero_make`, fmt padding: VERIFIED

```odin
package newfeat

import "core:fmt"

Big :: enum {A = 0, B = 100, C = 200}
Big_Set :: bit_set[Big; [4]u64]

V :: struct { x, y: f32 }

main :: proc() {
	y := [dynamic; 8]int{1, 2, 3}      // inline, no allocator, never delete
	append(&y, 4)
	fmt.println(len(y), cap(y), y[:], size_of(y))   // 4 8 [1, 2, 3, 4] 72
	unordered_remove(&y, 0)
	fmt.println(y[:])                                // [4, 2, 3]

	s := Big_Set{.A, .C}
	fmt.println(.C in s, card(s), size_of(Big_Set)) // true 2 32

	buf := non_zero_make([]f32, 1024)               // skip zeroing
	defer delete(buf)

	d := make(#soa[dynamic]V, 0, 4)
	defer delete(d)
	append(&d, V{1, 2}, V{3, 4})
	for &v, i in d { v.x += f32(i) }
	fmt.println(d.x[:len(d)])                        // [1, 4]

	fmt.printfln("[%6.2f] [%06.2f] [%5d] [%05d]", 3.14159, 3.14159, 42, 42)
	// [  3.14] [003.14] [   42] [00042]
}
```

`using` statement, VERIFIED error text:
```
Error: 'using' has been disallowed as it is considered bad practice to use as a statement outside of immediate refactoring
	If you do require it for refactoring purposes or legacy code, it can be enabled on a per-file basis with '#+feature using-stmt'
```

---

## 2. API ground truth from local source (`~/langsrc/odin`)

- **`core:time`** (`time.odin`, `perf.odin`): `tick_now() -> Tick`, `tick_diff(start, end) -> Duration`, `tick_since(start)`, `tick_lap_time(&prev)`, `SCOPED_TICK_DURATION(&d)` (deferred), `duration_nanoseconds -> i64`, `duration_microseconds/milliseconds/seconds -> f64`, `Stopwatch` + `stopwatch_start/stop/reset/duration`, `read_cycle_counter()`, `has_invariant_tsc()`, `tsc_frequency()`, `accurate_sleep(d)`. There is also a `time.benchmark(&Benchmark_Options)` harness with `setup/bench/teardown` callbacks and `rounds_per_second` / `megabytes_per_second` outputs. All of these are `"contextless"` except `benchmark`.
- **`core:math/rand`**: every proc takes `gen := context.random_generator`. Ints: `uint32/64/128`, `int31/63/127`, `int_max(n)`, `int_range(lo, hi)` (plus sized variants), `uint_range`. Floats: `float32()`, `float64()`, `float32_range(lo, hi)`, `float64_range`, and in `distributions.odin` `float32_normal(mean, sd)`, `_exponential`, `_gamma`, `_beta`, `_uniform` (alias of `_range`), etc. Also `shuffle(slice)`, `choice(slice)`, `choice_enum(T)`, `choice_bit_set`, `perm(n)`, `read(bytes)`. State: `rand.create(seed: u64) -> Default_Random_State` (proc group over `create_u64`/`create_bytes`), `rand.default_random_generator(&state) -> Generator`, `rand.reset(seed)`, plus `rand.xoshiro256_random_generator(&state)` as an alternative PRNG. The default is chacha8rand (`base/runtime/random_generator_chacha8*.odin`, with simd128/simd256 refill), thread-local, and lazily seeded via `rand_bytes`.
- **SOA runtime** (`base/runtime/core_builtin_soa.odin`, all `@builtin`): `make_soa` (slice / dynamic / len / len+cap / aligned), `resize_soa`, `non_zero_resize_soa`, `reserve_soa`, `append_soa` (elem / elems), `non_zero_append_soa_*`, `append_nothing_soa`, `inject_at_soa`, `delete_soa`, `clear_soa`, `into_dynamic_soa`, `pop_soa`, `pop_safe_soa`, `pop_front_soa`, `unordered_remove_soa`, `ordered_remove_soa`. The generic `make/append/delete/pop/…` groups include them. `soa_zip`/`soa_unzip` are compiler builtins (`base/builtin/builtin.odin:349`).
- **`core:os`** (the old os2): `os.open(name, flags := {.Read}, perm) -> (^File, Error)`, `read_entire_file` (proc group: `_from_path(name, allocator)` / `_from_file(f, allocator)`), `write_entire_file(name, data: []byte | string, perm, truncate := true) -> Error`, `os.args`. There is no `os2` subdirectory and no `old` subdirectory.
- **Deprecations present in tree** (`rg '@\(deprecated'`): `core:compress/zlib` and `gzip` procs, four `core:strconv` procs, one `core:os/file_util.odin` rune writer, `strconv.quote`. Nothing in `mem`, `time`, `rand`, `slice` or `simd` is deprecated. `Small_Array` is not marked deprecated in code (docs say it is replaced).
- **`core:container/*`**: `avl, bit_array, handle_map, intrusive, lru, pool, priority_queue, queue, rbtree, small_array, topological_sort, xar`.
- **`core:slice`**: `sort`, `sort_by(data, less)`, `sort_by_with_indices`, `sort_with_indices`, … (`core/slice/sort.odin`).
- `mem.Kilobyte/Megabyte/Gigabyte` constants (aliases of `runtime.*`).

---

## 3. Pitfalls (for "gotcha" boxes)

1. **Immutable loop variables**: `for p in soa_or_slice` gives copies (SOA: a read-only proxy), so mutation needs `for &p in …`. The compiler error tells you this.
2. **No `^T` into SOA storage**: `&soa[i]` is an SOA pointer (container pointer + index). It cannot be passed to a proc expecting `^Particle`. Pass the index, or a column slice.
3. **SOA plus random access across many fields is slower**: each field is a separate stream, and random access to k fields touches k cache lines (forum explanation, §5).
4. **`ordered_remove` on SOA** shifts *every* column. Prefer `unordered_remove`, or swap-and-pop with handles.
5. **Arena + growing `[dynamic]`** leaves a trail of dead blocks (Zylinski). Fix it by pre-sizing (`make([dynamic]T, 0, N, arena)` and then `arr.allocator = mem.panic_allocator()`), by using a static/growing **virtual** arena (it extends the most recent allocation in place), or by keeping dynamic arrays on `context.allocator`.
6. **Benchmarks get optimised away** at `-o:speed` (313 ns "measurement" above). Consume results.
7. **SIMD alignment**: `#simd[8]f32` is 32-byte aligned. Pointer-casting into a `[]f32` is UB-adjacent, so use unaligned load/store or `simd.from_slice`/`to_array`.
8. **`@(fast_math)` needs flags** (`{.Allow_Reassoc}` etc.) and changes results.
9. **Default `-o:minimal`** is not a release build. Always say `-o:speed` (and optionally `-microarch:native`) when quoting numbers.
10. **`core:os` signatures changed**: explicit allocator, `os.Error` union, `^os.File`. Pre-2026 blog code (including Zylinski's 2024 intro, `data, ok := os.read_entire_file(...)`) no longer compiles.
11. **`using` statement is opt-in** (`#+feature using-stmt`). Old DOD examples that wrote `using entity` inside procs must be rewritten.
12. **fmt zero-padding changed** in dev-2026-11. Benchmark table formatting like `%8.3f` now space-pads.
13. **`#soa[dynamic; N]T` is not supported**.
14. Matrix literal order vs storage order: you write rows, it stores columns (unless `#row_major`).
15. `handle_map` items **must** have a field named `handle` of the handle type. Index 0 is a sentinel, so capacity is N-1.

---

## 4. DOD facts for the Odin chapter(s)

- Odin ships DOD layouts as **language types**: `#soa[N]T`, `#soa[]T`, `#soa[dynamic]T`, with the same indexing syntax as AoS. Switching layout is one keyword, and code that indexes `a[i].field` compiles unchanged. This is the strongest "Odin vs Rust/Zig" contrast (Zig has `std.MultiArrayList`; Rust needs crates or hand-written SoA).
- `soa_zip` turns N parallel slices into one SOA view with no copy, and `soa_unzip` is the reverse.
- Built-in arrays for numeric DOD: array programming on `[N]T` (`x*2+1`, swizzles `.zyx`), `matrix[R,C]T` (column-major, SIMD-friendly alignment), `#simd[N]T` (portable vectors, with `core:simd` wrappers and per-ISA intrinsics), `bit_set` (flags as a 1-byte set), `bit_field` (well-defined LSB-first packing), enumerated arrays `[Enum]T`.
- The allocation model is part of the language: `context.allocator` / `context.temp_allocator` are passed implicitly to every Odin-convention call, so *any* library code can be redirected into an arena by the caller. The temp allocator is a growing arena cleared with `free_all(context.temp_allocator)` once per frame.
- gingerBill's allocation taxonomy (size known/unknown × lifetime known/unknown, with ~95% "both known") and the three lifetime generations (permanent, transient per cycle/frame, scratch) map directly onto `context.allocator`, a per-frame arena, and `context.temp_allocator`.
- Handles over pointers: generational indices are now in core (`core:container/handle_map`), and stable-address arrays (`core:container/xar`) arrived in 2026 Q1.
- Production use: JangaFX writes **all** its products in Odin (EmberGen, LiquiGen, IlluGen, GeoGen). EmberGen is used at Bethesda, CAPCOM, Codemasters, THQ Nordic, Warner Bros, Weta Digital, and in "over 150 leading game studios" (odin-lang.org showcase). gingerBill works at JangaFX.
- RTTI vs CTTI: Odin prefers one table-driven procedure (`fmt.println` over the type table) to N instantiations, which gingerBill frames explicitly as a *data-driven* choice. This is a nice tie-in for a "data-driven code" sidebar.

---

## 5. Quotes (verbatim, with source)

- gingerBill, *Memory Allocation Strategies Part 1* (2019): "trying to abstract away memory allocation comes at a higher cost than most people realize."
- Same article: "When it comes to allocation, there are three main aspects to think about: The size of the allocation; The lifetime of that memory; The usage of that memory." Also: "You know much more about your program than the compiler could ever know." And: "My personal issue with regards to ownership semantics is that it naturally focuses on the ownership of single objects rather than in systems."
- gingerBill, *Memory Allocation Strategies Part 1*: "Memory is not longer this dualistic model of the stack and the heap but rather a monistic model where everything is virtual memory." ("not longer" is sic.)
- gingerBill, *Blessed Syntax and Ergonomics* (2026-04-29): Odin is "just trying to solve the average common case very well, rather than allowing the ability to solve 'everything' poorly". Also: "When I designed Odin, I thought what do the vast majority of people use operator overloading from in practice, and just implement that directly into the language—solving the common case rather than the general case."
- gingerBill, *CTTI is Exponential, RTTI is Linear* (2026-09-02): "I chose RTTI in Odin because it is a data-driven approach (one procedure over a table)."
- odin-lang.org overview (SOA example comment): "Same syntax as AOS and treat as if it was an array".
- Odin forum, *How SOA works under the hood?*: "Odin smooths things over so that it semantically behaves as similarly to a regular array of structs as it can".
- Overview, matrix: "Column-major is used in order to utilize (SIMD) vector instructions effectively on modern hardware, if possible."
- Overview, context: "`context.temp_allocator` is for temporary and short lived allocations, which are to be freed once per cycle/frame/etc."
- Odin forum, *How SOA works under the hood?*: "it's a somewhat niche feature that's really nice to have when it matches what you want to do, but isn't something you should be using by default."
- Karl Zylinski, *Data-oriented ideas for small gamedev teams* (2024): "Avoid separately allocating objects that live in an array. Pack them tightly. Your CPU loves it!" And: "If you need to store a permanent reference to an array element, then use handles, not pointers." And: "Personally, I think ECS is often an over-engineered solution that makes gameplay code both harder and less fun to write."
- Zylinski, *Mistakes and cool things to do with arena allocators* (2025): "It's just a graveyard of old blocks in a trail behind the currently used block." And: "Since everything in an arena should share the same lifetime, there is only one deallocation that makes sense: Deallocating everything in the arena."
- Zylinski, *Handles are the better pointers: an Odin gamedev follow-up* (2025): "You still need the handle because it contains the generation, and the generation makes sure that things are not replaced under your nose."
- Andre Weissflog, *Handles are the better pointers* (2018): "move all memory management into centralized systems … with the systems being the sole owner of their memory allocations" and "only convert a handle to a pointer when absolutely needed, and don't store the pointer anywhere".
- *Moving Towards a New "core:os"* (2025-10-31): "Requiring an explicit allocator makes it very clear who and what is allocating where."

---

## 6. Visualisation ideas (Odin-specific)

1. **AoS vs `#soa` memory strip**: one horizontal strip of 64-byte cache lines for `[]Entity` with the `health` bytes highlighted (1 of 16 floats useful per line), next to the `#soa` `health` column (16/16 useful). A toggle replays the measured 24 ms vs 5 ms bars.
2. **"One keyword" diff view**: `entities: [dynamic]Entity` changed to `entities: #soa[dynamic]Entity`, with the unchanged loop body and the before/after timing.
3. **SOA header anatomy**: boxes for `#soa[dynamic]Particle`: 4 column pointers, len, cap, and the allocator, totalling 64 B. Arrows to four separate heap columns. Contrast with `[dynamic]Particle` (ptr, len, cap, allocator = 40 B → one buffer).
4. **Arena graveyard animation**: `append` into a `mem.Arena` repeatedly, with dead blocks accumulating behind the live one. Side by side, a virtual growing arena extends in place, then jumps to a new block once it passes the block size.
5. **Allocation generations stack**: permanent (`context.allocator` / static vmem arena) → per-frame arena → `context.temp_allocator`, each with a `free_all` at its cycle boundary.
6. **Generational handle slots**: a table of slots with `gen` counters. Removing h1 bumps the gen and reuses the slot as h3, and the stale handle lookup shows a red ✗.
7. **Reduction ordering**: a strict sequential sum (a dependency chain of N adds) against 8-lane reassociated partial sums (`@(fast_math={.Allow_Reassoc})`), with the 5.2 ms → 1.4 ms numbers and the result drift.
8. **bit_set vs struct-of-bools** byte layout (1 B vs 4 B per entity × 1M entities).

---

## 7. Assumptions and caveats

- The installed binary reports `dev-2026-11-nightly:9a69916`. The task called the release "dev-2026-11a"; I treated the local source/binary as ground truth. The GitHub release page is tag `dev-2026-11` (2026-11-03).
- Benchmark numbers come from one run each on a shared 4-vCPU cloud VM, so they are noisy. Treat them as illustrative ratios, not book-final numbers; rerun on the book's reference machine.
- I could not read Zylinski's book itself (paid); I cited only the free sample/odinbook.com page (v1.10, April 2026: "We will discuss data-oriented programming in chapter 20").
- I found no gingerBill article specifically titled "Odin's #soa". SOA material comes from the official overview, demo.odin and the forum thread.
- I did not find specific public write-ups of *how* JangaFX applies DOD internally beyond the showcase and gingerBill's statements, so do not invent internals.

---

## SOURCES (all opened or seen in search results during this research)

| # | URL | Title | Author | Year | Note |
|---|---|---|---|---|---|
| 1 | http://www.gingerbill.org/article/2019/02/01/memory-allocation-strategies-001 | Memory Allocation Strategies – Part 1: Thinking About Memory and Allocation | Ginger Bill | 2019 | Read in full: size/lifetime/usage table, generations, quotes |
| 2 | http://www.gingerbill.org/article/2019/02/08/memory-allocation-strategies-002 | Part 2: Linear/Arena Allocators | Ginger Bill | 2019 | Search excerpt: arena = offset bump, free all at once |
| 3 | https://www.gingerbill.org/article/2019/02/15/memory-allocation-strategies-003 | Part 3: Stack Allocators | Ginger Bill | 2019 | Excerpt: LIFO, header per allocation |
| 4 | http://www.gingerbill.org/article/2019/02/16/memory-allocation-strategies-004 | Part 4: Pool Allocators | Ginger Bill | 2019 | Excerpt: O(1) alloc/free via free list |
| 5 | https://www.gingerbill.org/article/2021/11/30/memory-allocation-strategies-005/ | Part 5: Free List Allocators | Ginger Bill | 2021 | Excerpt: first-fit / best-fit, coalescing |
| 6 | https://www.gingerbill.org/article/2021/12/02/memory-allocation-strategies-006/ | Part 6: Buddy Allocators | Ginger Bill | 2021 | Excerpt |
| 7 | https://www.gingerbill.org/series/memory-allocation-strategies | Memory Allocation Strategies – series index | Ginger Bill | 2019–2021 | 6 parts listed |
| 8 | https://www.gingerbill.org/article/2026/04/29/blessed-syntax-and-ergonomics | Blessed Syntax and Ergonomics | Ginger Bill | 2026 | Read: built-in data structures list incl. `[dynamic; N]T`, #soa; quotes |
| 9 | https://www.gingerbill.org/article/2026/09/02/ctti-is-exponential-rtti-is-linear | CTTI is Exponential, RTTI is Linear | Ginger Bill | 2026 | Excerpt: "data-driven approach" quote |
| 10 | https://www.gingerbill.org/article/2026/01/11/mitigating-the-billion-dollar-mistake/ | Mitigating the Billion Dollar Mistake | Ginger Bill | 2026 | Excerpt: slices/explicit pointers reduce nil issues |
| 11 | https://www.gingerbill.org/article/2024/04/04/video-that-inspired-odin/ | The Video That Inspired Me To Create Odin | Ginger Bill | 2024 | "all of our products [at JangaFX] are written in it" |
| 12 | https://odin-lang.org/docs/overview/ | Odin Overview | Odin team | live (read 2026-11) | SOA, soa_zip, SOA pointers, matrix/#row_major, #simd, bit_set (array-backed), bit_field, `[dynamic; N]T`, context, allocators, tracking allocator |
| 13 | http://odin-lang.org/news/newsletter-2026-q1 | 2025 Q4 and 2026 Q1 Newsletter | Odin team | 2026 | New core:os, core:os/old until Q3 2026, `#+feature using-stmt`, chacha8rand default, xar, handle_map |
| 14 | https://odin-lang.org/news/moving-towards-a-new-core-os | Moving Towards a New "core:os" | Odin team | 2025 | Explicit allocators, `^os.File`, `os.Error`, examples |
| 15 | https://github.com/odin-lang/Odin/releases/tag/dev-2026-11 | Release dev-2026-11 | odin-lang | 2026 | Read in full: fmt padding BREAKING, compress overhaul, non_zero_make, bounds-check elision, matrix alignment, escape analysis |
| 16 | https://odin-lang.org/news/newsletter-2026-11/ | November 2026 Newsletter | Odin team | 2026 | Excerpt: release highlights, core:diff |
| 17 | http://odin-lang.org/news/newsletter-2026-10 | October 2026 Newsletter | Odin team | 2026 | Excerpt: bit_set backed by arrays of integers; compiler speedups |
| 18 | http://odin-lang.org/news/newsletter-2026-09 | September 2026 Newsletter | Odin team | 2026 | Excerpt: experimental inline asm; macOS amd64 deprecation |
| 19 | https://odin-lang.org/news/newsletter-2026-spring-summer/ | 2026 Spring & Summer Newsletter | Odin team | 2026 | New packages table (crypto, rexcode, debug/trace) |
| 20 | https://github.com/odin-lang/Odin/releases/tag/dev-2026-06 | Release dev-2026-06 | odin-lang | 2026 | Excerpt: `@(fast_math)`, `**` expand_values, fixed capacity dynamic arrays `[dynamic; N]T` |
| 21 | https://forum.odin-lang.org/t/how-soa-works-under-the-hood/383 | How SOA works under the hood? | Odin forum (community) | n.d. | Read: layouts, pros/cons, SOA pointer = ptr+index, internals |
| 22 | https://zylinski.se/posts/data-oriented-ideas-for-small-gamedev-teams | Data-oriented ideas for small gamedev teams | Karl Zylinski | 2024 | Read: "avoid separately allocating", handles, anti-ECS quote |
| 23 | https://zylinski.se/posts/dynamic-arrays-and-arenas | Mistakes and cool things to do with arena allocators | Karl Zylinski | 2025 | Read: graveyard, panic_allocator trick, virtual growing/static arenas |
| 24 | https://zylinski.se/posts/handle-based-arrays | "Handles are the better pointers": An Odin gamedev follow-up | Karl Zylinski | 2025 | Read: Handle_Array impl, index-0 dummy, generation quote |
| 25 | https://zylinski.se/posts/handle-based-maps-three-implementations | Handle-based maps: Three implementations | Karl Zylinski | 2025 | Excerpt: fixed/dynamic/virtual variants; `#soa [N]T` conversion |
| 26 | https://zylinski.se/posts/temporary-allocator-your-first-arena | Understand the Temporary Allocator; Understand arenas | Karl Zylinski | 2025 | Excerpt: temp allocator per frame |
| 27 | https://zylinski.se/posts/a-programming-language-for-me | Odin: A programming language made for me | Karl Zylinski | 2025 | Excerpt: custom/temp/tracking allocators, #soa |
| 28 | https://odinbook.com/sample.html | Understanding the Odin Programming Language (sample, v1.10) | Karl Zylinski | 2026 | Book; DOD = chapter 20; memory mgmt chapters 9–13 |
| 29 | https://news.zylinski.se/p/march-2025 | March 2025 newsletter | Karl Zylinski | 2025 | odin-handle-map library origin |
| 30 | https://floooh.github.io/2018/06/17/handles-vs-pointers.html | Handles are the better pointers | Andre Weissflog | 2018 | Read: centralised systems, index+generation |
| 31 | http://odin-lang.org/showcase/embergen | EmberGen (showcase) | Odin team / JangaFX | 2022 | "written fully in Odin"; studio list |
| 32 | http://odin-lang.org/showcase | Showcase | Odin team | live | LiquiGen, IlluGen, GeoGen by JangaFX |
| 33 | https://dev.to/dimension-ai/just-what-is-odin-anyway-542a | Just What IS Odin, Anyway? | dimension-ai (DEV) | n.d. | Secondary: "In Odin, it is a single keyword" (#soa vs Rust) |
| 34 | https://github.com/odin-lang/Odin (local clone `~/langsrc/odin` @ 9a69916) | Odin source: base/runtime, core/* , examples/demo/demo.odin | odin-lang | 2026 | Ground truth for all APIs above |
