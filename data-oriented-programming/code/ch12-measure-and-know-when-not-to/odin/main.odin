// Chapter 12, "Measure, and Know When Not To": three ways a benchmark lies to you, measured.
//   (a) ch12-deadcode  one sum of squares timed three ways: result discarded (the optimizer deletes it),
//                      input visible to the optimizer (the loop becomes a formula), and kept alive (honest)
//   (b) ch12-noise     a 16 KiB and a 16 MiB sum, each timed SAMPLES times; every sample is printed for bench-dist
//   (c) ch12-aa        an A/A test: the same kernel as "A" and "B", timed A-then-B and A,B,A,B
// Usage (from code/ch12-measure-and-know-when-not-to): odin run odin -o:speed -vet -strict-style -- [N] [--quick]
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

import "core:math"

// A layout guard: compilation fails if someone grows the hot record.
Particle :: struct {
	pos:   [3]f32,
	vel:   [3]f32,
	alive: bool,
	kind:  u8,
}
#assert(size_of(Particle) == 28)

// Timed runs per noise sample set (bench-dist draws every one of them).
SAMPLES :: 41
// Timed runs per side of the A/A test, and how many times the whole test is repeated.
AA :: 31
AA_ROUNDS :: 7

// Below this many ns per element, a loop over memory is not believable: at 2.6 GHz it would
// mean about 8 elements per clock cycle, more than this loop can sustain. The honest run takes about 0.4 ns.
MIN_PLAUSIBLE_NS_PER_ELEM :: 0.05

// The kernel for the dead-code demo: a wrapping sum of squares over a slice.
sum_squares :: proc(v: []u64) -> u64 {
	s: u64
	for x in v {
		s += x * x
	}
	return s
}

// The same sum with no input data: v[i] = i, so the loop only needs n.
sum_squares_range :: proc(n: u64) -> u64 {
	s: u64
	for i in 0 ..< n {
		s += i * i
	}
	return s
}

// Does nothing: timing it measures only the two clock reads.
empty :: proc(_: int) -> u64 {
	return 0
}

// A broken harness: identical to bench_runs, except that the result is thrown away.
bench_runs_discarding :: proc(f: proc(ctx: $C) -> u64, ctx: C) -> (t: [RUNS]time.Duration) {
	_ = f(ctx)
	for &d in t {
		t0 := time.tick_now()
		_ = f(ctx) // nothing reads this, so the optimizer may delete the call
		d = time.tick_since(t0)
	}
	slice.sort(t[:])
	return
}

// Two sanity checks every timing should pass before anyone looks at a ratio.
verdict :: proc(d, timer_floor: time.Duration, n: int) -> string {
	if d < 2 * timer_floor {
		return "<- SUSPICIOUS: no slower than timing nothing"
	}
	if f64(i64(d)) / f64(n) < MIN_PLAUSIBLE_NS_PER_ELEM {
		return "<- SUSPICIOUS: faster than the core can do the work"
	}
	return "plausible"
}

// The noise kernel: sum a slice of u32 into a u64.
sum_u32 :: proc(v: []u32) -> u64 {
	s: u64
	for x in v {
		s += u64(x)
	}
	return s
}

// Same input in all three languages: x[i] = i * 2654435761 (mod 2^32).
make_u32 :: proc(n: int) -> []u32 {
	x := make([]u32, n)
	for &e, i in x {
		e = u32(i) * 2654435761
	}
	return x
}

// bench_runs with K timed runs instead of RUNS: one warm-up, then K sorted timings.
sample_runs :: proc(f: proc(ctx: $C) -> u64, ctx: C, $K: int) -> (t: [K]time.Duration) {
	keep(f(ctx))
	for &d in t {
		t0 := time.tick_now()
		keep(f(ctx))
		d = time.tick_since(t0)
	}
	slice.sort(t[:])
	return
}

// Coefficient of variation: sample standard deviation divided by the mean.
cv :: proc(runs: []time.Duration) -> f64 {
	mean: f64
	for r in runs {
		mean += f64(i64(r))
	}
	mean /= f64(len(runs))
	v: f64
	for r in runs {
		v += (f64(i64(r)) - mean) * (f64(i64(r)) - mean)
	}
	v /= f64(len(runs) - 1)
	return math.sqrt(v) / mean
}

med :: proc(runs: []time.Duration) -> f64 {
	return f64(i64(runs[len(runs) / 2]))
}

Pair :: struct {
	a, b: [AA]time.Duration,
}

// A/A test, sequential: all AA runs of "A", then all AA runs of "B". Same code, different buffers.
aa_sequential :: proc(a, b: []u32) -> Pair {
	return {sample_runs(sum_u32, a, AA), sample_runs(sum_u32, b, AA)}
}

// A/A test, alternating: A, B, A, B, ... so slow drift hits both sides equally.
aa_alternating :: proc(a, b: []u32) -> (p: Pair) {
	keep(sum_u32(a))
	keep(sum_u32(b))
	for i in 0 ..< AA {
		t0 := time.tick_now()
		keep(sum_u32(a))
		p.a[i] = time.tick_since(t0)
		t0 = time.tick_now()
		keep(sum_u32(b))
		p.b[i] = time.tick_since(t0)
	}
	slice.sort(p.a[:])
	slice.sort(p.b[:])
	return
}

print_ratios :: proc(name: string, xs: []f64) {
	fmt.printf("    %-11s", name)
	d: [AA_ROUNDS]f64
	for r, i in xs {
		fmt.printf(" %.3f", r)
		d[i] = abs(r - 1)
	}
	slice.sort(d[:])
	fmt.printfln("  |B/A-1| median %.1f%%, worst %.1f%%", 100 * d[len(d) / 2], 100 * d[len(d) - 1])
}

Row :: struct {
	label: string,
	runs:  [RUNS]time.Duration,
}

main :: proc() {
	args := parse_args()
	n := args.n

	// ---- (a) dead code: the same work, timed three ways ----
	v := make([]u64, n)
	defer delete(v)
	for &x, i in v {
		x = u64(i)
	}
	rows := [?]Row {
		{"empty (timer only)", bench_runs(empty, 0)},
		{"result discarded", bench_runs_discarding(sum_squares, v)},
		{"input visible", bench_runs(sum_squares_range, u64(n))},
		{"kept alive", bench_runs(sum_squares, v)},
	}
	fmt.printfln("(a) sum of squares over %d u64, median of %d:", n, RUNS)
	floor := rows[0].runs[RUNS / 2]
	for &r, i in rows {
		m := r.runs[RUNS / 2]
		note := i == 0 ? "(the floor: two clock reads)" : verdict(m, floor, n)
		fmt.printfln("    %-17s %12d ns  %9.4f ns/elem  %s", r.label, i64(m), f64(i64(m)) / f64(n), note)
		emit_bench("ch12-deadcode", r.label, n, r.runs[:])
	}
	fmt.printfln("    checksum: kept alive %d, input visible %d", sum_squares(v), sum_squares_range(u64(n)))

	// ---- (b) noise: one kernel, many samples ----
	fmt.printfln("(b) noise, %d timed runs each:", SAMPLES)
	kernels := [?]struct {
		label: string,
		len:   int,
	}{{"16 KiB (L1)", 1 << 12}, {"16 MiB (L3/DRAM)", 1 << 22}}
	for k in kernels {
		x := make_u32(k.len)
		defer delete(x)
		runs := sample_runs(sum_u32, x, SAMPLES)
		fmt.printfln(
			"    %-17s min %10d ns  median %10d ns  max %10d ns  CV %5.1f%%  checksum %d",
			k.label,
			i64(runs[0]),
			i64(runs[SAMPLES / 2]),
			i64(runs[SAMPLES - 1]),
			100 * cv(runs[:]),
			sum_u32(x),
		)
		emit_bench("ch12-noise", k.label, k.len, runs[:])
	}

	// ---- (c) A/A test: sequential versus alternating ----
	LEN :: 1 << 16 // 256 KiB per buffer: both fit in L2 together
	a := make_u32(LEN)
	defer delete(a)
	b := make_u32(LEN)
	defer delete(b)
	fmt.printfln("(c) A/A test on 2 x 256 KiB, %d runs per side; B/A ratio of medians (truth: 1.000)", AA)
	seq, alt: [AA_ROUNDS]f64
	for round in 0 ..< AA_ROUNDS {
		s := aa_sequential(a, b)
		t := aa_alternating(a, b)
		seq[round] = med(s.b[:]) / med(s.a[:])
		alt[round] = med(t.b[:]) / med(t.a[:])
		if round == 0 {
			emit_bench("ch12-aa", "A, sequential", LEN, s.a[:])
			emit_bench("ch12-aa", "B, sequential", LEN, s.b[:])
			emit_bench("ch12-aa", "A, alternating", LEN, t.a[:])
			emit_bench("ch12-aa", "B, alternating", LEN, t.b[:])
		}
	}
	print_ratios("sequential", seq[:])
	print_ratios("alternating", alt[:])
	fmt.printfln("    checksum: A %d B %d", sum_u32(a), sum_u32(b))

	// ---- (d) layout guard: checked at compile time, printed for the reader ----
	fmt.printfln(
		"(d) Particle: %d B, align %d; pos @%d, vel @%d, alive @%d, kind @%d",
		size_of(Particle),
		align_of(Particle),
		offset_of(Particle, pos),
		offset_of(Particle, vel),
		offset_of(Particle, alive),
		offset_of(Particle, kind),
	)
}
