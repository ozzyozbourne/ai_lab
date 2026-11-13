// Chapter 2, "The Machine": what the memory hierarchy costs, measured four ways.
//   (a) ch02-list    sum 4·N nodes as an array, as a list linked in memory order, and as a shuffled list
//   (b) ch02-sweep   a dependent random chase (Sattolo single cycle, one load per 64 B line) from 4 KiB to 512 MiB
//   (c) ch02-access  the same 16·N u32s read sequentially, at a 64 B stride, at a 4 KiB stride, in random order,
//                    and in random order with a software prefetch
//   (d) ch02-mlp     the same chase split into 1, 2, 4 or 8 independent chains (memory-level parallelism)
// N defaults to 2^20, so (a), (c) and (d) each touch 64 MiB, more than this orb's 54 MiB L3.
// Run (from code/ch02-the-machine): odin run odin -o:speed -vet -strict-style -- --quick
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

// splitmix64. The Rust and Zig versions use the same generator and seeds, so all three
// programs build identical permutations and print identical checksums.
Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

// Uniform-enough integer in 0..<n (multiply-high, no division).
rng_below :: proc(r: ^Rng, n: int) -> int {
	return int((u128(rng_next(r)) * u128(n)) >> 64)
}

identity :: proc(n: int) -> []u32 {
	p := make([]u32, n)
	for &x, i in p {
		x = u32(i)
	}
	return p
}

// Fisher-Yates: a uniformly random permutation of 0..<n.
shuffled :: proc(n: int, r: ^Rng) -> []u32 {
	p := identity(n)
	for i := n - 1; i > 0; i -= 1 {
		slice.swap(p, i, rng_below(r, i + 1))
	}
	return p
}

// Sattolo's algorithm: like Fisher-Yates but j < i, never j == i. The result, read as
// "next = p[i]", is ONE cycle through all n elements, so a chase can never get stuck in a short loop.
sattolo :: proc(n: int, r: ^Rng) -> []u32 {
	p := identity(n)
	for i := n - 1; i > 0; i -= 1 {
		slice.swap(p, i, rng_below(r, i))
	}
	return p
}

// ---- (a) array vs linked list ----

END :: max(u32)

// 16 bytes: 8 value + 4 next + 4 padding, so four nodes share a 64-byte line.
Node :: struct {
	value: u64,
	next:  u32,
}

List :: struct {
	nodes: []Node,
	head:  u32,
}

// Links the nodes in `order`: order[0] is the head and each node points to the next one in `order`.
link :: proc(order: []u32) -> List {
	nodes := make([]Node, len(order))
	for i, k in order {
		nodes[i] = {u64(i), k + 1 < len(order) ? order[k + 1] : END}
	}
	return {nodes, order[0]}
}

sum_array :: proc(l: List) -> (s: u64) {
	for n in l.nodes {
		s += n.value
	}
	return
}

sum_list :: proc(l: List) -> (s: u64) {
	i := l.head
	for i != END {
		n := l.nodes[i]
		s += n.value
		i = n.next // the next address is only known when this load returns
	}
	return
}

// ---- (b) and (d) dependent chase, one u32 per 64-byte line ----

LINE_U32 :: 64 / 4

// `bytes` of memory with one live u32 per 64-byte line: buf[16·k] = 16·next(k), next a Sattolo cycle.
chase_buffer :: proc(bytes: int, r: ^Rng) -> []u32 {
	lines := bytes / 64
	cyc := sattolo(lines, r)
	defer delete(cyc)
	buf := make([]u32, lines * LINE_U32) // make zeroes the memory
	for nx, k in cyc {
		buf[k * LINE_U32] = nx * LINE_U32
	}
	return buf
}

Chase :: struct {
	buf:  []u32,
	hops: int,
}

chase :: proc(c: Chase) -> (s: u64) {
	i := 0
	for _ in 0 ..< c.hops {
		i = int(c.buf[i]) // each load needs the previous one's result
		s += u64(i)
	}
	return
}

// One full trip around a cycle of `lines` lines visits every line once: sum of 16·k for k < lines.
trip_sum :: proc(lines: int) -> u64 {
	return u64(LINE_U32 * lines * (lines - 1) / 2)
}

Chains :: struct {
	buf:       []u32,
	starts:    []int,
	hops_each: int,
}

// K cursors spread evenly around the same cycle, advanced in lockstep. The K loads in one
// round do not depend on each other, so the core can have K misses in flight at once.
chase_k :: proc(c: Chains, $K: int) -> (s: u64) {
	cur: [K]int
	copy(cur[:], c.starts)
	for _ in 0 ..< c.hops_each {
		#unroll for j in 0 ..< K {
			cur[j] = int(c.buf[cur[j]])
			s += u64(cur[j])
		}
	}
	return
}

// The harness takes proc(ctx) -> u64, so each K gets a tiny wrapper.
chase_1 :: proc(c: Chains) -> u64 {return chase_k(c, 1)}
chase_2 :: proc(c: Chains) -> u64 {return chase_k(c, 2)}
chase_4 :: proc(c: Chains) -> u64 {return chase_k(c, 4)}
chase_8 :: proc(c: Chains) -> u64 {return chase_k(c, 8)}

starts :: proc(buf: []u32, lines: int, out: []int) {
	i := 0
	for &slot, k in out {
		slot = i
		if k + 1 < len(out) {
			for _ in 0 ..< lines / len(out) {
				i = int(buf[i])
			}
		}
	}
}

// ---- (c) access patterns over the same bytes ----

Gather :: struct {
	a:   []u32,
	idx: []u32,
}

Strided :: struct {
	a:      []u32,
	stride: int,
}

sum_seq :: proc(a: []u32) -> (s: u64) {
	for x in a {
		s += u64(x)
	}
	return
}

// Visits every element exactly once: `stride` passes, each touching every stride-th element.
sum_strided :: proc(c: Strided) -> (s: u64) {
	for off in 0 ..< c.stride {
		for i := off; i < len(c.a); i += c.stride {
			s += u64(c.a[i])
		}
	}
	return
}

sum_gather :: proc(g: Gather) -> (s: u64) {
	for i in g.idx {
		s += u64(g.a[i])
	}
	return
}

PREFETCH_AHEAD :: 16

sum_gather_prefetch :: proc(g: Gather) -> (s: u64) {
	for i, k in g.idx {
		if k + PREFETCH_AHEAD < len(g.idx) {
			// ask for a line we will need 16 iterations from now (locality 3 = keep in all levels)
			intrinsics.prefetch_read_data(&g.a[g.idx[k + PREFETCH_AHEAD]], 3)
		}
		s += u64(g.a[i])
	}
	return
}

ns_per :: proc(d: time.Duration, n: int) -> f64 {
	return f64(i64(d)) / f64(n)
}

ok_text :: proc(ok: bool) -> string {
	return ok ? "all match" : "MISMATCH"
}

Case :: struct {
	label: string,
	runs:  [RUNS]time.Duration,
}

main :: proc() {
	args := parse_args()
	n := args.n
	all_ok := true
	fmt.printfln("ch02 the machine: N = %d, quick = %v", n, args.quick)

	// (a) array vs linked list over 4·N 16-byte nodes
	{
		count := 4 * n
		r := Rng{1}
		ident := identity(count)
		defer delete(ident)
		perm := shuffled(count, &r)
		defer delete(perm)
		in_order := link(ident)
		defer delete(in_order.nodes)
		scattered := link(perm)
		defer delete(scattered.nodes)

		want := u64(count * (count - 1) / 2)
		ok := sum_array(scattered) == want && sum_list(in_order) == want && sum_list(scattered) == want
		all_ok &&= ok
		fmt.printfln("(a) %d nodes x 16 B = %d KiB, checksum %d (%s)", count, count * 16 / 1024, want, ok_text(ok))
		cases := [?]Case {
			{"array", bench_runs(sum_array, scattered)},
			{"list, in order", bench_runs(sum_list, in_order)},
			{"list, shuffled", bench_runs(sum_list, scattered)},
		}
		for &c in cases {
			fmt.printfln("    %-16s %7.2f ns/node", c.label, ns_per(c.runs[RUNS / 2], count))
			emit_bench("ch02-list", c.label, count, c.runs[:])
		}
	}

	// (b) working-set sweep: 4 KiB .. 512 MiB (2 MiB with --quick), powers of two and 1.5x midpoints
	{
		max_bytes := args.quick ? 2 << 20 : 512 << 20
		min_hops := args.quick ? 1 << 16 : 1 << 21
		fmt.printfln("(b) dependent random chase, one load per 64 B line, >= %d loads per size", min_hops)
		r := Rng{2}
		ok := true
		for b := 4 << 10; b <= max_bytes; b *= 2 {
			for bytes in ([2]int{b, b * 3 / 2}) {
				if bytes > max_bytes {
					continue
				}
				buf := chase_buffer(bytes, &r)
				defer delete(buf)
				lines := bytes / 64
				rounds := max(min_hops / lines, 1)
				c := Chase{buf, rounds * lines}
				ok &&= chase(c) == u64(rounds) * trip_sum(lines)
				runs := bench_runs(chase, c)
				// one sample = one trip around the cycle, so ns/n is the latency of one load
				for &d in runs {
					d /= time.Duration(rounds)
				}
				fmt.printfln("    %8d KiB  %7.2f ns/load", bytes >> 10, ns_per(runs[RUNS / 2], lines))
				emit_bench("ch02-sweep", "random chase", lines, runs[:])
			}
		}
		all_ok &&= ok
		fmt.printfln("    every trip visited every line once: %s", ok ? "yes" : "NO")
	}

	// (c) sequential vs strided vs random over the same 16·N u32s
	{
		m := 16 * n
		r := Rng{3}
		a := make([]u32, m)
		defer delete(a)
		for &x, i in a {
			x = u32(i) * 2_654_435_761
		}
		idx := shuffled(m, &r)
		defer delete(idx)
		g := Gather{a, idx}

		want := sum_seq(a)
		ok :=
			sum_strided({a, 16}) == want &&
			sum_strided({a, 1024}) == want &&
			sum_gather(g) == want &&
			sum_gather_prefetch(g) == want
		all_ok &&= ok
		fmt.printfln("(c) %d u32 = %d KiB, checksum %d (%s)", m, m * 4 / 1024, want, ok_text(ok))
		cases := [?]Case {
			{"sequential", bench_runs(sum_seq, a)},
			{"stride 64 B", bench_runs(sum_strided, Strided{a, 16})},
			{"stride 4 KiB", bench_runs(sum_strided, Strided{a, 1024})},
			{"random", bench_runs(sum_gather, g)},
			{"random + prefetch", bench_runs(sum_gather_prefetch, g)},
		}
		for &c in cases {
			fmt.printfln("    %-18s %7.2f ns/elem", c.label, ns_per(c.runs[RUNS / 2], m))
			emit_bench("ch02-access", c.label, m, c.runs[:])
		}
	}

	// (d) memory-level parallelism: the same N-line cycle walked by 1, 2, 4 or 8 chains
	{
		lines := n / 8 * 8
		r := Rng{4}
		buf := chase_buffer(lines * 64, &r)
		defer delete(buf)
		want := trip_sum(lines)
		s1: [1]int
		s2: [2]int
		s4: [4]int
		s8: [8]int
		starts(buf, lines, s1[:])
		starts(buf, lines, s2[:])
		starts(buf, lines, s4[:])
		starts(buf, lines, s8[:])
		c1, c2 := Chains{buf, s1[:], lines}, Chains{buf, s2[:], lines / 2}
		c4, c8 := Chains{buf, s4[:], lines / 4}, Chains{buf, s8[:], lines / 8}
		ok := chase_1(c1) == want && chase_2(c2) == want && chase_4(c4) == want && chase_8(c8) == want
		all_ok &&= ok
		fmt.printfln("(d) %d lines = %d KiB, checksum %d (%s)", lines, lines * 64 / 1024, want, ok_text(ok))
		cases := [?]Case {
			{"1 chain", bench_runs(chase_1, c1)},
			{"2 chains", bench_runs(chase_2, c2)},
			{"4 chains", bench_runs(chase_4, c4)},
			{"8 chains", bench_runs(chase_8, c8)},
		}
		for &c in cases {
			fmt.printfln("    %-9s %7.2f ns/load", c.label, ns_per(c.runs[RUNS / 2], lines))
			emit_bench("ch02-mlp", c.label, lines, c.runs[:])
		}
	}

	if !all_ok {
		fmt.eprintln("checksum mismatch")
		os.exit(1)
	}
}
