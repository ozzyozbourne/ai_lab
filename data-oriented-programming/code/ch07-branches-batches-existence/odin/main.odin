// Chapter 7: branches, batches and existence (Odin dev-2026-11). The same four sections as the
// Rust and Zig programs, with the same inputs, so all three print the same checksums.
//
// 1. Branches: a filter over L1/L2-resident data, branchy vs branchless, swept over predictability.
// 2. Existence: "alive" as a field, a bool array, a core:container/bit_array, or a #soa table.
// 3. Batches: one pipeline, three stages called through procedure values, batch size 1 .. N.
// 4. Lookup: classify bytes with comparisons vs a 256-entry table literal.
//
// Run (from code/ch07-branches-batches-existence): `odin run odin -o:speed -vet -strict-style -- [N] [--quick]`
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

import ba "core:container/bit_array"

// splitmix64. All three programs use it with the same seeds, so they build identical
// inputs and print identical checksums.
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

// Integer in 0..n (multiply-high, no division).
rng_below :: proc(r: ^Rng, n: u64) -> u64 {
	return u64((u128(rng_next(r)) * u128(n)) >> 64)
}

per_elem :: proc(d: time.Duration, n: int) -> f64 {
	return f64(i64(d)) / f64(n)
}

// Odin has no black_box. A volatile load of a slice header makes the optimizer forget what the
// slice is, so a loop of `reps` calls to a read-only procedure cannot collapse into one call.
opaque :: proc "contextless" (s: $T/[]$E) -> T {
	s := s
	return intrinsics.volatile_load(&s)
}

// =====================================================================================
// 1. Branches: a filter (stream compaction) with a predictable or unpredictable branch
// =====================================================================================

// Branchy: push `x` into the output only when it passes. The store itself is conditional,
// so the compiler cannot turn this into a conditional move: it must keep the jump.
filter_branchy :: #force_no_inline proc(input: []u32, t: u32, out: []u32) -> int {
	n := 0
	for x in input {
		if x < t {
			out[n] = x
			n += 1
		}
	}
	return n
}

// Branchless: always write, then advance the cursor by 0 or 1. `out` must be as long as
// `input`. Converting the bool to an int gives a number, not a jump.
filter_branchless :: #force_no_inline proc(input: []u32, t: u32, out: []u32) -> int {
	n := 0
	for x in input {
		out[n] = x
		n += int(x < t)
	}
	return n
}

// The famous sorted-array loop: sum the elements below `t`. No store depends on the
// condition, so the optimizer is free to make it branchless.
sum_if :: #force_no_inline proc(input: []u32, t: u32) -> u64 {
	s: u64
	for x in input {
		if x < t {
			s += u64(x)
		}
	}
	return s
}

// Values in 0..100. Keeping `x < p` keeps about p% of them, in random order.
random_values :: proc(n: int, rng: ^Rng) -> []u32 {
	v := make([]u32, n)
	for &x in v {
		x = u32(rng_below(rng, 100))
	}
	return v
}

// A pattern of `k` random keep/drop decisions, repeated. Keeping `x < 50` keeps half.
// Short periods are learnable by the predictor; long ones look random.
periodic_values :: proc(n, k: int, rng: ^Rng) -> []u32 {
	bits := make([]bool, k)
	defer delete(bits)
	for &b in bits {
		b = rng_next(rng) & 1 == 1
	}
	v := make([]u32, n)
	for &x, i in v {
		r := u32(rng_below(rng, 50))
		x = bits[i % k] ? r : 50 + r
	}
	return v
}

Filter_Proc :: proc(input: []u32, t: u32, out: []u32) -> int

Filter_Ctx :: struct {
	f:     Filter_Proc,
	input: []u32,
	t:     u32,
	reps:  int,
	out:   []u32,
}

// One timed run: `reps` passes of the filter over the same input.
repeated :: proc(c: Filter_Ctx) -> u64 {
	total := 0
	for _ in 0 ..< c.reps {
		total += c.f(opaque(c.input), c.t, c.out)
	}
	return u64(total)
}

// Runs both filters, checks they agree, emits two BENCH lines. The reported ns are the
// measured ns for `reps * len(input)` elements times `scale` (see the Rust version).
filter_pair :: proc(
	id: string,
	labels: [2]string,
	input: []u32,
	t: u32,
	reps: int,
	buf: []u32,
	x_n: int,
	scale: f64,
) -> (
	med: [2]time.Duration,
) {
	fs := [2]Filter_Proc{filter_branchy, filter_branchless}
	kept: [2]int
	sums: [2]u64
	for f, v in fs {
		runs := bench_runs(repeated, Filter_Ctx{f, input, t, reps, buf})
		kept[v] = f(input, t, buf)
		for x in buf[:kept[v]] {
			sums[v] += u64(x)
		}
		med[v] = runs[RUNS / 2]
		scaled: [RUNS]time.Duration
		for r, i in runs {
			scaled[i] = time.Duration(f64(i64(r)) * scale)
		}
		emit_bench(id, labels[v], x_n, scaled[:])
	}
	assert(kept[0] == kept[1] && sums[0] == sums[1], "filters disagree")
	return
}

Sum_Ctx :: struct {
	input: []u32,
	reps:  int,
}

repeated_sum :: proc(c: Sum_Ctx) -> u64 {
	s: u64
	for _ in 0 ..< c.reps {
		s += sum_if(opaque(c.input), 50)
	}
	return s
}

branches :: proc(quick: bool) {
	n := quick ? 1 << 12 : 1 << 16 // 16 KiB (L1) or 256 KiB (L2) of u32, same again for output
	reps := quick ? 16 : (1 << 20) / n
	total := n * reps
	buf := make([]u32, n)
	defer delete(buf)
	fmt.printfln("== branches: filter %d u32 values (%d KiB), %d passes per run", n, n * 4 / 1024, reps)

	// (a) random values, keep p% of them
	rng := Rng{7}
	vals := random_values(n, &rng)
	defer delete(vals)
	fmt.println("  keep%  branchy ns/elem  branchless ns/elem")
	for p := u32(0); p <= 100; p += 10 {
		// stack buffers, not tprintf: emit_bench calls free_all(context.temp_allocator)
		l0, l1: [32]u8
		labels := [2]string{fmt.bprintf(l0[:], "branchy %d%%", p), fmt.bprintf(l1[:], "branchless %d%%", p)}
		m := filter_pair("ch07-predict", labels, vals, p, reps, buf, total, 1.0)
		fmt.printfln("  %4d%%  %15.2f  %18.2f", p, per_elem(m[0], total), per_elem(m[1], total))
	}

	// (b) the same values sorted: the branch flips once
	sorted := slice.clone(vals)
	defer delete(sorted)
	slice.sort(sorted)
	r := filter_pair("ch07-patterns", {"branchy, random", "branchless, random"}, vals, 50, reps, buf, total, 1.0)
	s := filter_pair("ch07-patterns", {"branchy, sorted", "branchless, sorted"}, sorted, 50, reps, buf, total, 1.0)
	fmt.printfln(
		"  keep 50%%: branchy random %.2f / sorted %.2f ns/elem, branchless random %.2f / sorted %.2f",
		per_elem(r[0], total),
		per_elem(s[0], total),
		per_elem(r[1], total),
		per_elem(s[1], total),
	)

	// (c) the sorted-array demo itself: sum the elements below 50
	sums: [2]u64
	datas := [2][]u32{vals, sorted}
	names := [2]string{"if-sum, random", "if-sum, sorted"}
	for data, i in datas {
		runs := bench_runs(repeated_sum, Sum_Ctx{data, reps})
		sums[i] = sum_if(data, 50)
		emit_bench("ch07-patterns", names[i], total, runs[:])
		fmt.printfln("  %s: %.2f ns/elem", names[i], per_elem(runs[RUNS / 2], total))
	}
	assert(sums[0] == sums[1], "sum_if: sorting changed the sum")

	// (d) period-k patterns, keep 50%: where does the predictor stop learning?
	fmt.println("  period k  branchy ns/elem  branchless ns/elem")
	for k := 2; k <= n; k *= 4 {
		krng := Rng{11 + u64(k)}
		data := periodic_values(n, k, &krng)
		defer delete(data)
		// report time per period: n = k, ns scaled by k / total
		m := filter_pair("ch07-period", {"branchy", "branchless"}, data, 50, reps, buf, k, f64(k) / f64(total))
		fmt.printfln("  %8d  %15.2f  %18.2f", k, per_elem(m[0], total), per_elem(m[1], total))
	}
	fmt.println("  checksums: branchy == branchless for every pattern (asserted)")
}

// =====================================================================================
// 2. Existence: where does "alive" live?
// =====================================================================================

// Version 1: the flag is a field. 17 bytes of data, 20 with padding.
Entity :: struct {
	x, y, vx, vy: i32,
	alive:        bool,
}

// Versions 2-4: the same data without the flag. 16 bytes.
Body :: struct {
	x, y, vx, vy: i32,
}

#assert(size_of(Entity) == 20)
#assert(size_of(Body) == 16)

coord :: proc(rng: ^Rng) -> i32 {
	return i32(rng_below(rng, 2001)) - 1000
}

make_body :: proc(rng: ^Rng) -> (b: Body) {
	b.x = coord(rng)
	b.y = coord(rng)
	b.vx = coord(rng) / 100 // Odin integer division truncates toward zero, like Rust and @divTrunc
	b.vy = coord(rng) / 100
	return
}

// Does entity `id` die during setup? A hash, so all three programs agree.
dies :: proc(id: u32, dead_pct: u64) -> bool {
	r := Rng{u64(id) ~ 0xD1E}
	return rng_next(&r) % 100 < dead_pct
}

update_flag :: #force_no_inline proc(es: []Entity) -> u64 {
	for &e in es {
		if e.alive {
			e.x += e.vx
			e.y += e.vy
		}
	}
	return u64(len(es))
}

Bool_Ctx :: struct {
	bodies: []Body,
	alive:  []bool,
}

update_bool_array :: #force_no_inline proc(c: Bool_Ctx) -> u64 {
	bodies, alive := c.bodies, c.alive // hoist: reading them through `c` reloads them every pass
	for &b, i in bodies {
		if alive[i] {
			b.x += b.vx
			b.y += b.vy
		}
	}
	return u64(len(c.bodies))
}

Bits_Ctx :: struct {
	bodies: []Body,
	alive:  ^ba.Bit_Array,
}

// Out-of-band bits: core:container/bit_array's iterator visits only the set bits.
update_bitset :: #force_no_inline proc(c: Bits_Ctx) -> u64 {
	bodies := c.bodies
	it := ba.make_iterator(c.alive)
	for i in ba.iterate_by_set(&it) {
		b := &bodies[i]
		b.x += b.vx
		b.y += b.vy
	}
	return u64(len(c.bodies))
}

// A table per state: #soa stores `id` and `body` as two columns.
Row :: struct {
	id:   u32,
	body: Body,
}

// Changing state is moving a row from one table to another.
kill_where :: proc(alive, dead: ^#soa[dynamic]Row, dead_pct: u64) {
	row := 0
	for row < len(alive) {
		if dies(alive[row].id, dead_pct) {
			append(dead, alive[row])
			unordered_remove(alive, row) // the last row moves into the hole, in every column
			// do not advance: the row now holds what was the last element
		} else {
			row += 1
		}
	}
}

// Existence: no flag, no branch. Every row in this table is alive.
update_alive :: #force_no_inline proc(alive: []Body) -> u64 {
	for &b in alive {
		b.x += b.vx
		b.y += b.vy
	}
	return u64(len(alive))
}

mix :: proc(acc: u64, x, y: i32) -> u64 {
	return acc + u64(i64(x) * 3 + i64(y))
}

existence :: proc(n: int, dead_pct: u64, id: string) {
	rng := Rng{42}
	bodies := make([]Body, n)
	defer delete(bodies)
	for &b in bodies {
		b = make_body(&rng)
	}

	// 1. flag in the struct
	ents := make([]Entity, n)
	defer delete(ents)
	for &e, i in ents {
		b := bodies[i]
		e = {b.x, b.y, b.vx, b.vy, !dies(u32(i), dead_pct)}
	}
	// 2. out-of-band bool array
	b2 := slice.clone(bodies)
	defer delete(b2)
	alive2 := make([]bool, n)
	defer delete(alive2)
	for &a, i in alive2 {
		a = !dies(u32(i), dead_pct)
	}
	// 3. out-of-band bit set
	b3 := slice.clone(bodies)
	defer delete(b3)
	bits: ba.Bit_Array
	ba.init(&bits, n)
	defer ba.destroy(&bits)
	for i in 0 ..< n {
		if !dies(u32(i), dead_pct) {
			ba.set(&bits, i)
		}
	}
	// 4. one table per state, filled by moving rows with swap-and-pop
	alive := make(#soa[dynamic]Row, 0, n)
	defer delete(alive)
	dead: #soa[dynamic]Row
	defer delete(dead)
	for b, i in bodies {
		append(&alive, Row{u32(i), b})
	}
	kill_where(&alive, &dead, dead_pct)
	_, alive_bodies := soa_unzip(alive[:])

	live := len(alive)
	fmt.printfln(
		"== existence: %d entities, %d alive (%d%%), Entity %d B, Body %d B",
		n,
		live,
		100 - dead_pct,
		size_of(Entity),
		size_of(Body),
	)
	fmt.printfln(
		"  bytes read per update: flag %d | bool array %d | bitset %d + %d | table %d",
		n * size_of(Entity),
		n * (size_of(Body) + 1),
		live * size_of(Body),
		(n + 63) / 64 * 8,
		live * size_of(Body),
	)

	r1 := bench_runs(update_flag, ents)
	r2 := bench_runs(update_bool_array, Bool_Ctx{b2, alive2})
	r3 := bench_runs(update_bitset, Bits_Ctx{b3, &bits})
	r4 := bench_runs(update_alive, alive_bodies)

	// 8 updates each (1 warm-up + 7 timed). Same entities alive, so the same checksum.
	c: [4]u64
	for e in ents {
		if e.alive {
			c[0] = mix(c[0], e.x, e.y)
		}
	}
	for b, i in b2 {
		if alive2[i] {
			c[1] = mix(c[1], b.x, b.y)
		}
	}
	it := ba.make_iterator(&bits)
	for i in ba.iterate_by_set(&it) {
		c[2] = mix(c[2], b3[i].x, b3[i].y)
	}
	for b in alive_bodies {
		c[3] = mix(c[3], b.x, b.y)
	}
	labels := [4]string{"flag in struct + if", "bool array + if", "bitset, set bits only", "alive table, no branch"}
	runs := [4][RUNS]time.Duration{r1, r2, r3, r4}
	for label, i in labels {
		fmt.printfln("  %-24s %8.2f ns/entity  checksum 0x%016x", label, per_elem(runs[i][RUNS / 2], n), c[i])
		emit_bench(id, label, n, runs[i][:])
	}
	assert(c[0] == c[1] && c[1] == c[2] && c[2] == c[3], "existence: checksums differ")
	assert(len(dead) + live == n)
}

// A dirty list: remember *which* rows changed, once each, instead of a dirty flag per row
// that every consumer has to scan for.
Dirty_List :: struct {
	seen: ba.Bit_Array, // one bit per row: already listed?
	rows: [dynamic]u32,
}

dirty_mark :: proc(d: ^Dirty_List, row: u32) {
	if !ba.get(&d.seen, row) {
		ba.set(&d.seen, row)
		append(&d.rows, row)
	}
}

// Hand the dirty rows to the caller, then forget them. Cost: O(dirty), not O(rows).
// The returned slice is valid until the next `dirty_mark`.
dirty_drain :: proc(d: ^Dirty_List) -> []u32 {
	for row in d.rows {
		ba.unset(&d.seen, row)
	}
	defer clear(&d.rows)
	return d.rows[:]
}

dirty_demo :: proc(n: int) {
	rng := Rng{5}
	d: Dirty_List
	ba.init(&d.seen, n)
	defer ba.destroy(&d.seen)
	defer delete(d.rows)
	for _ in 0 ..< n / 8 {
		dirty_mark(&d, u32(rng_below(&rng, u64(n / 4)))) // repeats are common: listed once
	}
	count, sum: u64
	for row in dirty_drain(&d) {
		count += 1
		sum += u64(row)
	}
	fmt.printfln("== dirty list: %d marks over %d rows -> %d distinct dirty rows, row sum %d", n / 8, n / 4, count, sum)
}

// Several bools per entity, packed into one byte and kept out of band in their own column.
Flag :: enum u8 {
	Alive,
	Visible,
	Dirty,
	Selected,
}
Flags :: bit_set[Flag;u8]

flags_demo :: proc(n: int) {
	rng := Rng{9}
	flags := make([]Flags, n)
	defer delete(flags)
	for &f in flags {
		f = transmute(Flags)u8(rng_next(&rng) & 0xF)
	}
	want :: Flags{.Alive, .Visible}
	count := 0
	for f in flags {
		if want <= f && .Dirty not_in f {
			count += 1
		}
	}
	fmt.printfln(
		"== flags: %d entities x %d B of flags (4 separate bools: 4 B); alive, visible and clean: %d",
		n,
		size_of(Flags),
		count,
	)
}

// =====================================================================================
// 3. Batches: the same pipeline, items pushed through in batches of size B
// =====================================================================================

// One stage of a tiny vectorised interpreter (X100-style): a procedure value plus a
// parameter. It processes a whole batch per call.
Stage :: struct {
	k:   u64,
	run: proc(k, base: u64, inp, out: []u64),
}

gen :: proc(_, base: u64, _, out: []u64) {
	for &o, i in out {
		o = (base + u64(i)) * 0x9E37_79B9_7F4A_7C15
	}
}
mix_stage :: proc(_, _: u64, inp, out: []u64) {
	for &o, i in out {
		x := inp[i]
		o = x ~ (x >> 29)
	}
}
scale_stage :: proc(k, _: u64, inp, out: []u64) {
	for &o, i in out {
		o = inp[i] * k
	}
}

Pipe_Ctx :: struct {
	stages:       []Stage,
	total, batch: int,
	a, b:         []u64,
}

// Push `total` items through gen -> mix -> scale -> sum, `batch` at a time.
// Per batch: three indirect calls and a sum. Working set: two buffers of `batch` u64.
run_pipeline :: #force_no_inline proc(c: Pipe_Ctx) -> u64 {
	sum: u64
	s := c.stages
	for base := 0; base < c.total; base += c.batch {
		n := min(c.batch, c.total - base)
		a, b := c.a[:n], c.b[:n]
		s[0].run(s[0].k, u64(base), nil, a)
		s[1].run(s[1].k, u64(base), a, b)
		s[2].run(s[2].k, u64(base), b, a)
		for x in a {
			sum += x
		}
	}
	return sum
}

batches :: proc(quick: bool) {
	total := quick ? 1 << 16 : 1 << 22
	stages := [3]Stage{{0, gen}, {0, mix_stage}, {0xBF58_476D_1CE4_E5B9, scale_stage}}
	fmt.printfln("== batches: %d items through 3 stages; per item ns by batch size (working set = 16 B x batch)", total)
	first: Maybe(u64)
	for batch := 1; batch <= total; batch *= 4 {
		a := make([]u64, batch)
		defer delete(a)
		b := make([]u64, batch)
		defer delete(b)
		ctx := Pipe_Ctx{stages[:], total, batch, a, b}
		runs := bench_runs(run_pipeline, ctx)
		sum := run_pipeline(ctx)
		if first == nil {
			first = sum
		}
		assert(first.? == sum, "batch size changed the result")
		// n = batch size; ns = time per batch, so ns/n is time per item
		scaled: [RUNS]time.Duration
		for r, i in runs {
			scaled[i] = time.Duration(f64(i64(r)) * f64(batch) / f64(total))
		}
		emit_bench("ch07-batch", "pipeline", batch, scaled[:])
		fmt.printfln(
			"  batch %8d (%9d B): %6.2f ns/item  checksum 0x%016x",
			batch,
			16 * batch,
			per_elem(runs[RUNS / 2], total),
			sum,
		)
	}
}

// =====================================================================================
// 4. Lookup tables: classify bytes with comparisons or with a 256-entry table
// =====================================================================================

count_ident_branchy :: #force_no_inline proc(text: []u8) -> int {
	n := 0
	for c in text {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_':
			n += 1
		}
	}
	return n
}

// A table written as a literal with index ranges: 1 for [A-Za-z0-9_], else 0.
@(rodata)
IDENT := [256]u8 {
	'a' ..= 'z' = 1,
	'A' ..= 'Z' = 1,
	'0' ..= '9' = 1,
	'_'         = 1,
}

count_ident_lut :: #force_no_inline proc(text: []u8) -> int {
	n := 0
	for c in text {
		n += int(IDENT[c])
	}
	return n
}

Text_Ctx :: struct {
	text: []u8,
	reps: int,
}

repeat_branchy :: proc(c: Text_Ctx) -> u64 {
	s := 0
	for _ in 0 ..< c.reps {
		s += count_ident_branchy(opaque(c.text))
	}
	return u64(s)
}
repeat_lut :: proc(c: Text_Ctx) -> u64 {
	s := 0
	for _ in 0 ..< c.reps {
		s += count_ident_lut(opaque(c.text))
	}
	return u64(s)
}

lookup :: proc(quick: bool) {
	n := quick ? 1 << 12 : 1 << 16
	reps :: 16
	alphabet := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ (){}[];.,+-*/=<>\n\t\"'"
	rng := Rng{3}
	text := make([]u8, n)
	defer delete(text)
	for &c in text {
		c = alphabet[rng_below(&rng, u64(len(alphabet)))]
	}
	r1 := bench_runs(repeat_branchy, Text_Ctx{text, reps})
	r2 := bench_runs(repeat_lut, Text_Ctx{text, reps})
	c1 := count_ident_branchy(text)
	assert(c1 == count_ident_lut(text), "lookup: counts differ")
	total := n * reps
	fmt.printfln("== lookup: %d bytes, %d identifier bytes", n, c1)
	labels := [2]string{"comparisons", "256-entry table"}
	runs := [2][RUNS]time.Duration{r1, r2}
	for label, i in labels {
		fmt.printfln("  %-16s %.3f ns/byte", label, per_elem(runs[i][RUNS / 2], total))
		emit_bench("ch07-lut", label, total, runs[i][:])
	}
}

main :: proc() {
	args := parse_args()
	branches(args.quick)
	existence(args.n, 50, "ch07-exist")
	existence(args.n, 90, "ch07-exist-10")
	dirty_demo(args.n)
	flags_demo(args.n)
	batches(args.quick)
	lookup(args.quick)
}
