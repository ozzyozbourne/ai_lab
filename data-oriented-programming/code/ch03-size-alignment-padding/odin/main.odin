// Chapter 3: Size, Alignment and Padding (Odin dev-2026-11).
// Part (a) prints sizes, alignments and offsets (layout.odin).
// Part (b) sweeps N from 10k to 10M monsters and times one pass over three layouts of the same data:
//   24 B: pointer-sized anim handle, u32 hp, u32 y, bool    (Kelley's "fat" monster)
//   16 B: u32 anim index instead of the pointer-sized handle
//   12 B: u32 anim index and y quantized to u16
// Every variant computes the same checksum. Usage: [N = largest size, default 10_000_000] [--quick]
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

// monsters
// 8 + 4 + 4 + 1 = 17 bytes of fields, padded to 24 (align 8).
Fat :: struct {
	anim:  uintptr, // stands in for a pointer: same size and alignment
	hp:    u32,
	y:     u32,
	alive: bool,
}
// 4 + 4 + 4 + 1 = 13 bytes of fields, padded to 16 (align 4).
Index :: struct {
	anim:  u32,
	hp:    u32,
	y:     u32,
	alive: bool,
}
// 4 + 4 + 2 + 1 = 11 bytes of fields, padded to 12 (align 4).
Small :: struct {
	anim:  u32,
	hp:    u32,
	y:     u16,
	alive: bool,
}

#assert(size_of(Fat) == 24)
#assert(size_of(Index) == 16)
#assert(size_of(Small) == 12)
// monsters

// score
// The per-monster work: read every field, sum the live ones. One instantiation per element type.
// Branch-free on purpose: `alive` is random, and a branch would measure mispredictions (Chapter 7).
total :: proc(ms: []$M) -> u64 {
	s: u64
	for m in ms {
		s += (u64(m.anim) + u64(m.hp) + u64(m.y)) * u64(m.alive)
	}
	return s
}
// score

// splitmix64 of i: a stateless hash, so all three languages generate the same monsters.
mix :: proc(i: u64) -> u64 {
	z := i + 0x9E37_79B9_7F4A_7C15
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

// Monster i in layout M: anim < 4096, hp < 1000, y < 65536, 75% alive.
make_monster :: proc($M: typeid, i: int) -> (m: M) {
	r := mix(u64(i))
	m.anim = type_of(m.anim)(r & 0xFFF)
	m.hp = u32((r >> 12) % 1000)
	m.y = type_of(m.y)(u16(r >> 24))
	m.alive = (r >> 40) & 3 != 0
	return
}

// Builds the monsters, times one pass, prints a line and a BENCH record. Returns the checksum.
run :: proc($M: typeid, label: string, n: int) -> u64 {
	ms := make([]M, n)
	defer delete(ms)
	for &m, i in ms {
		m = make_monster(M, i)
	}
	total_m: proc(ms: []M) -> u64 = total // pick the instantiation for M
	runs := bench_runs(total_m, ms)
	sum := total(ms)
	fmt.printfln(
		"  %-10s %3d B/elem  %11d B total  %6.3f ns/elem  checksum %d",
		label,
		size_of(M),
		size_of(M) * n,
		f64(i64(runs[RUNS / 2])) / f64(n),
		sum,
	)
	emit_bench("ch03-monsters", label, n, runs[:])
	return sum
}

main :: proc() {
	args := parse_args()
	print_layout()

	// The harness caps N at 4096 under --quick; this sweep has its own sizes.
	explicit_n := false
	for a in os.args[1:] {
		if a != "--quick" {
			explicit_n = true
		}
	}
	max_n := args.quick ? 100_000 : explicit_n ? args.n : 10_000_000
	sizes := [?]int{10_000, 30_000, 100_000, 300_000, 1_000_000, 3_000_000, 10_000_000}

	fmt.printfln("== padding-waste sweep (one pass, median of %d) ==", RUNS)
	for n in sizes {
		if n > max_n {
			break
		}
		fmt.printfln("N = %d", n)
		a := run(Fat, "24 B fat", n)
		b := run(Index, "16 B index", n)
		c := run(Small, "12 B small", n)
		if a != b || b != c {
			fmt.eprintfln("checksums differ: %d %d %d", a, b, c)
			os.exit(1)
		}
		fmt.println("  checksums match")
	}
}
