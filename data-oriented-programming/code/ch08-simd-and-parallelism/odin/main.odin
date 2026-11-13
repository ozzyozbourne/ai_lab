// Chapter 8: SIMD and parallelism (Odin dev-2026-11).
//   1. f32 dot product (naive, 8 accumulators, explicit #simd + AVX2 dispatch, @(fast_math)) at L1 / L2 / DRAM sizes
//   2. a branch in SIMD: sum and count of the positive values, branchy vs 8-lane simd.select
//   3. false sharing: per-thread atomic counters packed in one line vs padded with #align(64) / #align(128)
//   4. thread scaling: #soa particle step split into chunks over 1, 2 and 4 core:thread threads
// Run (from code/ch08-simd-and-parallelism): odin run odin -o:speed -vet -strict-style -- [N] [--quick]
package main

// ---- harness ----
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

RUNS :: 7

// Odin has no black_box: a volatile store into a file-private global keeps results alive.
@(private = "file")
sink: u64

keep :: proc "contextless" (v: $T) where size_of(T) <= 8 {
	intrinsics.volatile_store((^T)(&sink), v)
}

// Runs f(ctx) once to warm up, then RUNS timed times. Returns the sorted timings.
bench_runs :: proc(f: proc(ctx: $C) -> u64, ctx: C) -> (t: [RUNS]time.Duration) {
	keep(f(ctx))
	for &d in t {
		t0 := time.tick_now()
		keep(f(ctx))
		d = time.tick_since(t0)
	}
	slice.sort(t[:])
	return
}

// Median of RUNS timed runs (after one warm-up run).
bench :: proc(f: proc(ctx: $C) -> u64, ctx: C) -> time.Duration {
	t := bench_runs(f, ctx)
	return t[RUNS / 2]
}

Args :: struct {
	n:     int,
	quick: bool,
}

// Positional integer N (default 1 << 20) and `--quick` (caps N at 1 << 12).
parse_args :: proc() -> (a: Args) {
	a.n = 1 << 20
	for arg in os.args[1:] {
		if arg == "--quick" {
			a.quick = true
		} else if v, ok := strconv.parse_int(arg); ok {
			a.n = v
		}
	}
	if a.quick {
		a.n = min(a.n, 1 << 12)
	}
	return
}

// Prints one machine-readable line for bench_all.sh:
// BENCH {"id":"chNN-x","label":"...","lang":"odin","n":N,"ns":median,"samples":[...]}
// `runs` must be sorted (as returned by bench_runs). Labels must not contain `"` or `\`.
emit_bench :: proc(id, label: string, n: int, runs: []time.Duration) {
	sb := strings.builder_make(context.temp_allocator)
	for r, i in runs {
		fmt.sbprintf(&sb, "%s%d", i == 0 ? "" : ",", i64(r))
	}
	fmt.printfln(
		`BENCH {{"id":"%s","label":"%s","lang":"odin","n":%d,"ns":%d,"samples":[%s]}}`,
		id,
		label,
		n,
		i64(runs[len(runs) / 2]),
		strings.to_string(sb),
	)
	free_all(context.temp_allocator)
}
// ---- harness ----

import "core:math/bits"
import "core:simd"
import "core:sys/info"
import "core:thread"

// lowbias32 (Chris Wellons): the same integer hash in all three languages, so the data is identical.
hash :: proc "contextless" (x: u32) -> u32 {
	x := x
	x ~= x >> 16
	x *= 0x7feb352d
	x ~= x >> 15
	x *= 0x846ca68b
	return x ~ (x >> 16)
}

// 24 random bits as an exact f32 in [-1, 1).
signed :: proc "contextless" (h: u32) -> f32 {
	return f32(h >> 8) * (1.0 / 8388608.0) - 1.0
}

// ---- dot ----
// 1. The obvious loop: one accumulator, strict left-to-right order. Each add waits for the previous one.
dot_naive :: proc(a, b: []f32) -> f32 {
	s: f32
	#no_bounds_check for x, i in a {
		s += x * b[i]
	}
	return s
}

// 2. Eight accumulators: we reassociate by hand, so the compiler may put `acc` in SIMD lanes.
dot_acc8 :: proc(a, b: []f32) -> f32 {
	acc: [8]f32
	i := 0
	#no_bounds_check for ; i + 8 <= len(a); i += 8 {
		for j in 0 ..< 8 {
			acc[j] += a[i + j] * b[i + j]
		}
	}
	s: f32
	for v in acc {
		s += v
	}
	#no_bounds_check for ; i < len(a); i += 1 {
		s += a[i] * b[i]
	}
	return s
}

V :: #simd[8]f32

// 3. Explicit SIMD: four #simd[8]f32 accumulators (32 partial sums), four adds in flight at once.
// Written once; the AVX2 wrapper below compiles the same body with 256-bit registers.
dot_lanes :: #force_inline proc "contextless" (a, b: []f32) -> f32 {
	acc: [4]V
	i := 0
	#no_bounds_check for ; i + 32 <= len(a); i += 32 {
		#unroll for k in 0 ..< 4 {
			// slice elements are only 4-byte aligned, #simd[8]f32 wants 32: use unaligned loads
			va := intrinsics.unaligned_load((^V)(&a[i + 8 * k]))
			vb := intrinsics.unaligned_load((^V)(&b[i + 8 * k]))
			acc[k] += va * vb
		}
	}
	lanes := simd.to_array(((acc[0] + acc[1]) + acc[2]) + acc[3])
	s: f32
	for l in lanes {
		s += l // ordered, so the bits match Rust and Zig
	}
	#no_bounds_check for ; i < len(a); i += 1 {
		s += a[i] * b[i]
	}
	return s
}

@(enable_target_feature = "avx2")
dot_avx2 :: proc "contextless" (a, b: []f32) -> f32 {
	return dot_lanes(a, b)
}

// Odin's default target is x86-64-v2 (SSE4.2), so #simd[8]f32 is two 128-bit halves unless we opt in.
// Runtime dispatch: checked once at startup, because cpuid is slow (and traps in a VM).
has_avx2: bool

dot_simd :: proc(a, b: []f32) -> f32 {
	return has_avx2 ? dot_avx2(a, b) : dot_lanes(a, b)
}

// 4. The naive loop with reassociation allowed for this one procedure.
@(fast_math = {.Allow_Reassoc})
dot_reassoc :: proc(a, b: []f32) -> f32 {
	s: f32
	#no_bounds_check for x, i in a {
		s += x * b[i]
	}
	return s
}
// ---- dot ----

// ---- mask ----
Pos :: struct {
	sum:   f32,
	count: u32,
}

// Branchy scalar: sum and count of the positive values.
pos_branchy :: proc(a: []f32) -> (r: Pos) {
	for x in a {
		if x > 0 {
			r.sum += x
			r.count += 1
		}
	}
	return
}

// Branch-free lanes: lanes_gt gives all-ones where x > 0; select keeps x or 0.0 per lane.
pos_mask :: proc(a: []f32) -> (r: Pos) {
	U :: #simd[8]u32
	zero: V
	s: V
	c: U
	i := 0
	#no_bounds_check for ; i + 8 <= len(a); i += 8 {
		v := intrinsics.unaligned_load((^V)(&a[i]))
		m := simd.lanes_gt(v, zero) // #simd[8]u32: 0xFFFF_FFFF or 0
		s += simd.select(m, v, zero)
		c += m & U(1)
	}
	for l in simd.to_array(s) {
		r.sum += l
	}
	r.count = simd.reduce_add_ordered(c)
	t := pos_branchy(a[i:])
	return {r.sum + t.sum, r.count + t.count}
}
// ---- mask ----

// ---- false sharing ----
// Two counters in one 64-byte line (aligned so the pair cannot straddle two lines).
Packed :: struct #align (64) {
	c: [2]u64,
}
// One counter per 64-byte line: adjacent lines still form one 128-byte pair for the spatial prefetcher.
Pad64 :: struct #align (64) {
	c: u64,
}
// One counter per 128-byte block, as crossbeam and Zig's std.atomic.cache_line do on x86-64.
Pad128 :: struct #align (128) {
	c: u64,
}
#assert(size_of(Packed) == 64 && size_of(Pad64) == 64 && size_of(Pad128) == 128)

Job :: struct {
	c:     ^u64,
	iters: u64,
}

hammer :: proc(j: Job) {
	for _ in 0 ..< j.iters {
		intrinsics.atomic_add_explicit(j.c, 1, .Relaxed)
	}
}

Two :: struct {
	c0, c1: ^u64,
	iters:  u64,
}

// Each of the two threads increments its own counter `iters` times. Returns the total.
two_threads :: proc(t: Two) -> u64 {
	t0 := thread.create_and_start_with_poly_data(Job{t.c0, t.iters}, hammer)
	t1 := thread.create_and_start_with_poly_data(Job{t.c1, t.iters}, hammer)
	thread.join_multiple(t0, t1)
	thread.destroy(t0)
	thread.destroy(t1)
	return intrinsics.atomic_load_explicit(t.c0, .Relaxed) + intrinsics.atomic_load_explicit(t.c1, .Relaxed)
}

hammer_one :: proc(t: Two) -> u64 {
	hammer(Job{t.c0, t.iters})
	return intrinsics.atomic_load_explicit(t.c0, .Relaxed)
}
// ---- false sharing ----

// ---- threads ----
DT :: f32(0.01)

Particle :: struct {
	x, y, vx, vy: f32,
}

Chunk :: struct {
	p:      #soa[]Particle,
	passes: int,
}

// One particle step over a chunk: x += vx·dt, y += vy·dt. Columns hoisted into locals first.
worker :: proc(c: Chunk) {
	n := len(c.p)
	xs, ys, vxs, vys := c.p.x[:n], c.p.y[:n], c.p.vx[:n], c.p.vy[:n]
	for _ in 0 ..< c.passes {
		#no_bounds_check for i in 0 ..< n {
			xs[i] += vxs[i] * DT
			ys[i] += vys[i] * DT
		}
	}
}

// Split the #soa slice into `threads` disjoint chunks (whole multiples of 32 elements, so every column
// chunk is a multiple of 128 B; make_particles aligns each column to 128 B, so no two threads write the
// same cache-line pair).
step_parallel :: proc(p: #soa[]Particle, threads, passes: int) {
	chunk := ((len(p) + threads - 1) / threads + 31) &~ 31
	pool: [8]^thread.Thread
	k := 0
	for lo := 0; lo < len(p); lo += chunk {
		hi := min(lo + chunk, len(p))
		pool[k] = thread.create_and_start_with_poly_data(Chunk{p[lo:hi], passes}, worker)
		k += 1
	}
	thread.join_multiple(..pool[:k])
	for t in pool[:k] {
		thread.destroy(t)
	}
}
// ---- threads ----

Dot_Ctx :: struct {
	f:    proc(a, b: []f32) -> f32,
	a, b: []f32,
	reps: int,
}

run_dot :: proc(c: Dot_Ctx) -> u64 {
	c := c
	s: f32
	for _ in 0 ..< c.reps {
		a := intrinsics.volatile_load(&c.a) // opaque each rep: the kernel cannot be hoisted out of the loop
		s += c.f(a, c.b)
	}
	return u64(transmute(u32)s)
}

Mask_Ctx :: struct {
	f:    proc(a: []f32) -> Pos,
	a:    []f32,
	reps: int,
}

run_mask :: proc(c: Mask_Ctx) -> u64 {
	c := c
	n: u32
	for _ in 0 ..< c.reps {
		a := intrinsics.volatile_load(&c.a)
		r := c.f(a)
		n += r.count ~ transmute(u32)r.sum // keep both results, so neither half can be dropped
	}
	return u64(n)
}

Step_Ctx :: struct {
	p:               #soa[]Particle,
	threads, passes: int,
}

run_step :: proc(c: Step_Ctx) -> u64 {
	step_parallel(c.p, c.threads, c.passes)
	return u64(transmute(u32)c.p[0].x)
}

make_particles :: proc(n: int) -> #soa[]Particle {
	// make(#soa[]Particle, n) aligns the columns only to align_of(Particle) = 4; ask for 128 B.
	p := make_soa_aligned(#soa[]Particle, n, 128)
	for i in 0 ..< n {
		k := u32(4 * i)
		p[i] = {signed(hash(k)), signed(hash(k + 1)), signed(hash(k + 2)), signed(hash(k + 3))}
	}
	return p
}

bits_sum :: proc(v: []f32) -> (h: u64) {
	for x in v {
		h = bits.rotate_left64(h, 5) ~ u64(transmute(u32)x)
	}
	return
}

per_elem :: proc(d: time.Duration, n: int) -> f64 {
	return f64(i64(d)) / f64(n)
}

main :: proc() {
	args := parse_args()
	dram := 16 * args.n // DRAM control: 2 × 64 MiB of f32 at the default N
	L1 :: 4096 // 2 arrays × 16 KiB = 32 KiB  < 48 KiB L1d
	L2 :: 65536 // 2 arrays × 256 KiB = 512 KiB < 1.25 MiB L2
	has_avx2 = .avx2 in info.cpu_features()
	fmt.printfln("ch08 odin: N=%d quick=%v avx2=%v", args.n, args.quick, has_avx2)

	// ---- 1. dot product ----
	{
		n := max(dram, L2)
		a := make([]f32, n)
		defer delete(a)
		b := make([]f32, n)
		defer delete(b)
		for i in 0 ..< n {
			a[i] = signed(hash(u32(2 * i)))
			b[i] = signed(hash(u32(2 * i + 1)))
		}
		Variant :: struct {
			label: string,
			f:     proc(a, b: []f32) -> f32,
		}
		variants := [?]Variant {
			{"naive (1 accumulator)", dot_naive},
			{"8 accumulators", dot_acc8},
			{"explicit SIMD (4x8 lanes)", dot_simd},
			{"reassociation allowed", dot_reassoc},
		}
		Size :: struct {
			id: string,
			n:  int,
		}
		for sz in ([?]Size{{"ch08-dot-l1", L1}, {"ch08-dot-l2", L2}, {"ch08-dot-dram", dram}}) {
			ctx := Dot_Ctx{nil, a[:sz.n], b[:sz.n], max(dram / sz.n, 1)}
			exact, scale: f64
			for x, i in ctx.a {
				p := f64(x) * f64(ctx.b[i])
				exact += p
				scale += abs(p)
			}
			fmt.printfln("%s: %d floats x2 (%d KiB), %d reps, f64 reference %.6f", sz.id, sz.n, sz.n * 8 / 1024, ctx.reps, exact)
			for v in variants {
				r := v.f(ctx.a, ctx.b)
				err := abs(f64(r) - exact)
				assert(err <= 1e-3 * scale, "result too far from the f64 reference")
				ctx.f = v.f
				runs := bench_runs(run_dot, ctx)
				fmt.printfln(
					"  %-27s %7.3f ns/elem  result %14.6f (bits %08x, |err| %.2e)",
					v.label,
					per_elem(runs[RUNS / 2], sz.n * ctx.reps),
					r,
					transmute(u32)r,
					err,
				)
				emit_bench(sz.id, v.label, sz.n * ctx.reps, runs[:])
			}
			assert(transmute(u32)dot_avx2(ctx.a, ctx.b) == transmute(u32)dot_lanes(ctx.a, ctx.b))
		}
	}

	// ---- 2. masks ----
	{
		a := make([]f32, L2)
		defer delete(a)
		for &x, i in a {
			x = signed(hash(u32(i) ~ 0x5bd1e995))
		}
		r0, r1 := pos_branchy(a), pos_mask(a)
		assert(r0.count == r1.count, "counts must match exactly")
		assert(abs(r0.sum - r1.sum) <= 1e-3 * r0.sum, "sums too far apart")
		reps := max(dram / L2, 1)
		fmt.printfln("ch08-mask: %d floats, %d reps, count %d (both), sum branchy %.4f vs mask %.4f", L2, reps, r0.count, r0.sum, r1.sum)
		Mv :: struct {
			label: string,
			f:     proc(a: []f32) -> Pos,
		}
		for v in ([?]Mv{{"branchy scalar", pos_branchy}, {"8-lane mask", pos_mask}}) {
			runs := bench_runs(run_mask, Mask_Ctx{v.f, a, reps})
			fmt.printfln("  %-27s %7.3f ns/elem", v.label, per_elem(runs[RUNS / 2], L2 * reps))
			emit_bench("ch08-mask", v.label, L2 * reps, runs[:])
		}
	}

	// ---- 3. false sharing ----
	{
		iters: u64 = args.quick ? 1 << 14 : 1 << 24
		fmt.printfln("ch08-false-sharing: %d relaxed atomic adds per thread", iters)
		one: Pad128
		p: Packed
		q: [2]Pad64
		r: [2]Pad128
		Case :: struct {
			label: string,
			two:   Two,
			f:     proc(t: Two) -> u64,
			want:  u64,
		}
		cases := [?]Case {
			{"1 thread alone", {&one.c, &one.c, iters}, hammer_one, 8 * iters},
			{"2 threads, same line", {&p.c[0], &p.c[1], iters}, two_threads, 16 * iters},
			{"2 threads, padded 64 B", {&q[0].c, &q[1].c, iters}, two_threads, 16 * iters},
			{"2 threads, padded 128 B", {&r[0].c, &r[1].c, iters}, two_threads, 16 * iters},
		}
		for c in cases {
			runs := bench_runs(c.f, c.two)
			total := c.two.c0^ if c.f == hammer_one else c.two.c0^ + c.two.c1^
			assert(total == c.want, "lost increments")
			fmt.printfln("  %-27s %7.3f ns per increment (wall), total %d", c.label, per_elem(runs[RUNS / 2], int(iters)), total)
			emit_bench("ch08-false-sharing", c.label, int(iters), runs[:])
		}
	}

	// ---- 4. thread scaling ----
	{
		sums: [3]u64
		for threads, k in ([?]int{1, 2, 4}) {
			p := make_particles(L2)
			defer delete(p)
			step_parallel(p, threads, 3)
			sums[k] = bits_sum(p.x[:L2]) ~ bits_sum(p.y[:L2])
		}
		assert(sums[1] == sums[0] && sums[2] == sums[0], "thread count changed the result")
		fmt.printfln("ch08-threads: checksum %016x for 1, 2 and 4 threads (identical)", sums[0])
		Cfg :: struct {
			id:        string,
			n, passes: int,
		}
		for cfg in ([?]Cfg{{"ch08-threads-l2", L2, max(dram / L2, 1)}, {"ch08-threads-dram", max(dram / 2, L2), 1}}) {
			p := make_particles(cfg.n)
			defer delete(p)
			fmt.printfln("%s: %d particles (%d KiB of SoA), %d passes", cfg.id, cfg.n, cfg.n * 16 / 1024, cfg.passes)
			for threads in ([?]int{1, 2, 4}) {
				runs := bench_runs(run_step, Step_Ctx{p, threads, cfg.passes})
				label := threads == 1 ? "1 thread" : fmt.tprintf("%d threads", threads)
				fmt.printfln("  %-27s %7.3f ns/particle-step", label, per_elem(runs[RUNS / 2], cfg.n * cfg.passes))
				emit_bench(cfg.id, label, cfg.n * cfg.passes, runs[:])
			}
		}
	}
}
