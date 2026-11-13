// Chapter 10: one deterministic 2D boids step, six ways (Odin dev-2026-11). See rust/src/main.rs for
// the list of variants; this file is the same algorithm, sizes and seed.
//
//   odin run odin -o:speed -vet -strict-style -- [N] [--quick]     (from code/ch10-boids-spatial-hash)
//
// Boid state is a #soa[]Boid. The SIMD variant uses #simd[8]f32 explicitly.
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
import "core:simd"
import "core:thread"

// ---- the model: one step of Reynolds' three rules ----
NEIGHBOR_R2 :: f32(1.0) // neighbour radius 1.0 = one grid cell
SEPARATION_R2 :: f32(0.0625) // separation radius 0.25
COHESION :: f32(0.02)
ALIGNMENT :: f32(0.05)
SEPARATION :: f32(0.5)
MAX_SPEED :: f32(2.0)
DT :: f32(0.05)
BOIDS_PER_CELL :: 4 // average density; the world grows with N
LANES :: 8
THREADS :: 2
NAIVE_MAX :: 1 << 14
SEED :: u64(0x5EED_B01D)

// SplitMix64: the same generator, bit for bit, in all three languages.
Split_Mix64 :: struct {
	s: u64,
}

next_u64 :: proc(r: ^Split_Mix64) -> u64 {
	r.s += 0x9E37_79B9_7F4A_7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

// Uniform in [0, 1) from the top 24 bits, so every value is exact in f32.
unit :: proc(r: ^Split_Mix64) -> f32 {
	return f32(next_u64(r) >> 40) * (1.0 / 16777216.0)
}

// One boid. #soa[]Boid stores each field as its own column; `id` is the spawn index,
// which survives reordering.
Boid :: struct {
	x, y, vx, vy: f32,
	id:           u32,
}

// The column slices of a #soa slice, taken once (Odin pitfall: hoist them out of hot loops).
Cols :: struct {
	x, y, vx, vy: []f32,
	id:           []u32,
}

// n boids plus LANES zeroed spare elements at the end, so 8-wide loads never run off a column.
Boids :: struct {
	n:    int,
	soa:  #soa[]Boid,
	c:    Cols,
}

boids_make :: proc(n: int) -> (b: Boids) {
	b.n = n
	b.soa = make(#soa[]Boid, n + LANES) // zeroed
	m := n + LANES
	b.c = Cols{b.soa.x[:m], b.soa.y[:m], b.soa.vx[:m], b.soa.vy[:m], b.soa.id[:m]}
	return
}

boids_spawn :: proc(n: int, w: World) -> Boids {
	b := boids_make(n)
	rng := Split_Mix64{SEED}
	for i in 0 ..< n {
		b.c.x[i] = unit(&rng) * w.size
		b.c.y[i] = unit(&rng) * w.size
		b.c.vx[i] = unit(&rng) * 2 - 1
		b.c.vy[i] = unit(&rng) * 2 - 1
		b.c.id[i] = u32(i)
	}
	return b
}

// The reorder: copy every column into the order the grid sorted them (a gather).
gather_from :: proc(dst: ^Boids, src: ^Boids, order: []u32) {
	d, s := dst.c, src.c
	#no_bounds_check for j, k in order {
		d.x[k] = s.x[j]
		d.y[k] = s.y[j]
		d.vx[k] = s.vx[j]
		d.vy[k] = s.vy[j]
		d.id[k] = s.id[j]
	}
}

set_out :: #force_inline proc(out: Cols, k: int, s: [4]f32, id: u32) {
	out.x[k], out.y[k], out.vx[k], out.vy[k] = s[0], s[1], s[2], s[3]
	out.id[k] = id
}

// A square world of side × side unit cells. The cell size equals the neighbour radius,
// so every neighbour of a boid lies in its own cell or one of the eight around it.
World :: struct {
	side: u32,
	size: f32,
}

world_for_count :: proc(n: int) -> World {
	side := u32(max(1.0, math.round(math.sqrt(f64(n / BOIDS_PER_CELL)))))
	return {side, f32(side)}
}

cell_xy :: #force_inline proc(w: World, x, y: f32) -> (u32, u32) {
	return min(u32(x), w.side - 1), min(u32(y), w.side - 1)
}

// Row-major cell number: cells in one row are consecutive.
row_major :: proc(w: World, x, y: f32) -> u32 {
	cx, cy := cell_xy(w, x, y)
	return cy * w.side + cx
}

morton_key :: proc(w: World, x, y: f32) -> u32 {
	cx, cy := cell_xy(w, x, y)
	return morton(cx, cy)
}

// The 3×3 block around a cell, clipped at the walls: x0, x1, y0, y1, inclusive.
block :: #force_inline proc(w: World, x, y: f32) -> (x0, x1, y0, y1: u32) {
	cx, cy := cell_xy(w, x, y)
	return cx > 0 ? cx - 1 : 0, min(cx + 1, w.side - 1), cy > 0 ? cy - 1 : 0, min(cy + 1, w.side - 1)
}

// Cells needed by the Morton numbering: the side rounded up to a power of two, squared.
morton_cells :: proc(w: World) -> int {
	p := math.next_power_of_two(int(w.side))
	return p * p
}

// Interleaves the bits of x and y (x in the even bits): the Z-order curve.
morton :: #force_inline proc(cx, cy: u32) -> u32 {
	spread :: #force_inline proc(v0: u32) -> u32 {
		v := v0 & 0xFFFF
		v = (v | (v << 8)) & 0x00FF_00FF
		v = (v | (v << 4)) & 0x0F0F_0F0F
		v = (v | (v << 2)) & 0x3333_3333
		return (v | (v << 1)) & 0x5555_5555
	}
	return spread(cx) | (spread(cy) << 1)
}

// `v` when `c` holds, else 0, without a jump: AND the bits with an all-ones or all-zeros mask.
// Odin has no select hint, and `c ? v : 0` may compile to a branch that mispredicts here.
pick :: #force_inline proc "contextless" (c: bool, v: f32) -> f32 {
	return transmute(f32)(transmute(u32)v & -u32(c))
}

// What one boid accumulates over its neighbours (itself included, so n >= 1).
Acc :: struct {
	n:      u32,
	sx, sy: f32, // sum of offsets to neighbours (cohesion)
	ax, ay: f32, // sum of neighbour velocities (alignment)
	qx, qy: f32, // push away from very close neighbours (separation)
}

visit :: #force_inline proc(a: ^Acc, xi, yi, xj, yj, vxj, vyj: f32) {
	dx := xj - xi
	dy := yj - yi
	d2 := dx * dx + dy * dy
	near := d2 < NEIGHBOR_R2
	close := d2 < SEPARATION_R2
	a.n += u32(near)
	a.sx += pick(near, dx)
	a.sy += pick(near, dy)
	a.ax += pick(near, vxj)
	a.ay += pick(near, vyj)
	a.qx -= pick(close, dx)
	a.qy -= pick(close, dy)
}

// Steer, clamp the speed, move, and bounce off the walls. Returns x, y, vx, vy.
integrate :: #force_inline proc(a: Acc, w: World, x, y, vx, vy: f32) -> [4]f32 {
	inv := 1.0 / f32(a.n)
	nvx := vx + COHESION * (a.sx * inv) + ALIGNMENT * (a.ax * inv - vx) + SEPARATION * a.qx
	nvy := vy + COHESION * (a.sy * inv) + ALIGNMENT * (a.ay * inv - vy) + SEPARATION * a.qy
	s2 := nvx * nvx + nvy * nvy
	if s2 > MAX_SPEED * MAX_SPEED {
		k := MAX_SPEED / math.sqrt(s2)
		nvx *= k
		nvy *= k
	}
	bx, bvx := bounce(x + nvx * DT, nvx, w.size)
	by, bvy := bounce(y + nvy * DT, nvy, w.size)
	return {bx, by, bvx, bvy}
}

bounce :: #force_inline proc(p, v, size: f32) -> (f32, f32) {
	if p < 0 {
		return -p, -v
	} else if p > size {
		return size + size - p, -v
	}
	return p, v
}

// Visits a contiguous run of boids (all four columns read in lockstep).
visit_span :: #force_inline proc(a: ^Acc, b: Cols, lo, hi: int, xi, yi: f32) {
	#no_bounds_check for j in lo ..< hi {
		visit(a, xi, yi, b.x[j], b.y[j], b.vx[j], b.vy[j])
	}
}

// ---- the counting-sort grid ----

// `start[c]..start[c + 1]` is the slice of `order` holding the boids of cell c.
Grid :: struct {
	start: []u32, // cells + 1 entries
	cell:  []u32, // cell of each boid
	order: []u32, // boid indices sorted by cell
}

grid_make :: proc(cells, n: int) -> Grid {
	return {make([]u32, cells + 1), make([]u32, n), make([]u32, n)}
}

grid_delete :: proc(g: Grid) {
	delete(g.start)
	delete(g.cell)
	delete(g.order)
}

// Counting sort by cell key: count, prefix sum, scatter. O(n + cells), no allocation.
grid_build :: proc(g: ^Grid, w: World, xs, ys: []f32, key: proc(w: World, x, y: f32) -> u32) {
	start, cell, order := g.start, g.cell, g.order // hoisted out of the struct
	// 1. count: start[c] = boids in cell c
	for &s in start {
		s = 0
	}
	#no_bounds_check for &c, i in cell {
		c = key(w, xs[i], ys[i])
		start[c] += 1
	}
	// 2. inclusive prefix sum: start[c] = boids in cells 0..=c
	sum: u32
	for &s in start {
		sum += s
		s = sum
	}
	// 3. scatter back to front: each boid takes the last free slot of its cell, so start[c]
	//    ends at the first slot of cell c and boids keep their spawn order inside a cell.
	#no_bounds_check #reverse for c, i in cell {
		start[c] -= 1
		order[start[c]] = u32(i)
	}
}

// Positions in `order` of cells first..=last (consecutive cell numbers).
span :: #force_inline proc(g: ^Grid, first, last: u32) -> (int, int) {
	return int(g.start[first]), int(g.start[last + 1])
}

// ---- the variants. Each reads `cur`, writes `next` (double buffering) and returns total neighbours. ----

step_naive :: proc(w: World, cur, next: ^Boids) -> (total: u64) {
	n, c, out := cur.n, cur.c, next.c
	for i in 0 ..< n {
		acc: Acc
		visit_span(&acc, c, 0, n, c.x[i], c.y[i])
		total += u64(acc.n)
		set_out(out, i, integrate(acc, w, c.x[i], c.y[i], c.vx[i], c.vy[i]), c.id[i])
	}
	return
}

step_grid :: proc(w: World, g: ^Grid, cur, next: ^Boids) -> (total: u64) {
	n, c, out := cur.n, cur.c, next.c
	grid_build(g, w, c.x[:n], c.y[:n], row_major)
	order := g.order
	for i in 0 ..< n {
		xi, yi := c.x[i], c.y[i]
		x0, x1, y0, y1 := block(w, xi, yi)
		acc: Acc
		for row in y0 ..= y1 {
			// three cells of one row are consecutive in `order`, but the boids they name are anywhere
			lo, hi := span(g, row * w.side + x0, row * w.side + x1)
			#no_bounds_check for j in order[lo:hi] {
				visit(&acc, xi, yi, c.x[j], c.y[j], c.vx[j], c.vy[j])
			}
		}
		total += u64(acc.n)
		set_out(out, i, integrate(acc, w, xi, yi, c.vx[i], c.vy[i]), c.id[i])
	}
	return
}

step_sorted :: proc(w: World, g: ^Grid, cur, s, next: ^Boids) -> (total: u64) {
	n := cur.n
	grid_build(g, w, cur.c.x[:n], cur.c.y[:n], row_major)
	gather_from(s, cur, g.order) // now cell c is s[start[c]..start[c + 1]]
	c, out := s.c, next.c
	for k in 0 ..< n {
		xi, yi := c.x[k], c.y[k]
		x0, x1, y0, y1 := block(w, xi, yi)
		acc: Acc
		for row in y0 ..= y1 {
			lo, hi := span(g, row * w.side + x0, row * w.side + x1)
			visit_span(&acc, c, lo, hi, xi, yi)
		}
		total += u64(acc.n)
		set_out(out, k, integrate(acc, w, xi, yi, c.vx[k], c.vy[k]), c.id[k])
	}
	return
}

step_morton :: proc(w: World, g: ^Grid, cur, s, next: ^Boids) -> (total: u64) {
	n := cur.n
	grid_build(g, w, cur.c.x[:n], cur.c.y[:n], morton_key)
	gather_from(s, cur, g.order)
	c, out := s.c, next.c
	for k in 0 ..< n {
		xi, yi := c.x[k], c.y[k]
		x0, x1, y0, y1 := block(w, xi, yi)
		acc: Acc
		for row in y0 ..= y1 {
			for col in x0 ..= x1 {
				m := morton(col, row) // neighbouring cells are no longer consecutive: 9 spans
				lo, hi := span(g, m, m)
				visit_span(&acc, c, lo, hi, xi, yi)
			}
		}
		total += u64(acc.n)
		set_out(out, k, integrate(acc, w, xi, yi, c.vx[k], c.vy[k]), c.id[k])
	}
	return
}

V :: #simd[LANES]f32
U :: #simd[LANES]u32

// Eight independent accumulators: lane l sums elements l, l + 8, l + 16, ... of each span.
Acc8 :: struct {
	n:      U,
	sx, sy: V,
	ax, ay: V,
	qx, qy: V,
}

// Branch-free: every lane computes, and a mask decides what it adds. Lanes past the end of
// the span read real (or padding) boids that the index mask throws away.
visit_span8 :: #force_inline proc "contextless" (a: ^Acc8, b: Cols, lo, hi: int, xi, yi: f32) {
	zero: V
	lane := simd.indices(U)
	#no_bounds_check for j := lo; j < hi; j += LANES {
		// slice elements are only 4-byte aligned and #simd[8]f32 wants 32: unaligned loads
		x := intrinsics.unaligned_load((^V)(&b.x[j]))
		y := intrinsics.unaligned_load((^V)(&b.y[j]))
		vx := intrinsics.unaligned_load((^V)(&b.vx[j]))
		vy := intrinsics.unaligned_load((^V)(&b.vy[j]))
		dx := x - V(xi)
		dy := y - V(yi)
		d2 := dx * dx + dy * dy
		live := simd.lanes_lt(lane, U(u32(hi - j))) & simd.lanes_lt(d2, V(NEIGHBOR_R2)) // all-ones or 0
		close := live & simd.lanes_lt(d2, V(SEPARATION_R2))
		a.n += live & U(1)
		a.sx += simd.select(live, dx, zero)
		a.sy += simd.select(live, dy, zero)
		a.ax += simd.select(live, vx, zero)
		a.ay += simd.select(live, vy, zero)
		a.qx -= simd.select(close, dx, zero)
		a.qy -= simd.select(close, dy, zero)
	}
}

// Adds the lanes in order 0..8, the same order as Rust and Zig.
reduce8 :: proc "contextless" (a: Acc8) -> Acc {
	sum :: proc "contextless" (v: V) -> (t: f32) {
		for e in simd.to_array(v) {
			t += e
		}
		return
	}
	return {simd.reduce_add_ordered(a.n), sum(a.sx), sum(a.sy), sum(a.ax), sum(a.ay), sum(a.qx), sum(a.qy)}
}

// The neighbour pass of the SIMD variants for sorted boids k0..<k1.
simd_range :: proc(w: World, g: ^Grid, c, out: Cols, k0, k1: int) -> (total: u64) {
	for k in k0 ..< k1 {
		xi, yi := c.x[k], c.y[k]
		x0, x1, y0, y1 := block(w, xi, yi)
		acc8: Acc8
		for row in y0 ..= y1 {
			lo, hi := span(g, row * w.side + x0, row * w.side + x1)
			visit_span8(&acc8, c, lo, hi, xi, yi)
		}
		acc := reduce8(acc8)
		total += u64(acc.n)
		set_out(out, k, integrate(acc, w, xi, yi, c.vx[k], c.vy[k]), c.id[k])
	}
	return
}

step_simd :: proc(w: World, g: ^Grid, cur, s, next: ^Boids) -> u64 {
	n := cur.n
	grid_build(g, w, cur.c.x[:n], cur.c.y[:n], row_major)
	gather_from(s, cur, g.order)
	return simd_range(w, g, s.c, next.c, 0, n)
}

// One thread's share of the output. Aligned to 128 B so the two `total`s never share a line pair.
Job :: struct #align (128) {
	w:      World,
	g:      ^Grid,
	s, out: Cols,
	k0, k1: int,
	total:  u64,
}

run_job :: proc(j: ^Job) {
	j.total = simd_range(j.w, j.g, j.s, j.out, j.k0, j.k1)
}

// Build and gather stay serial; the neighbour pass is split into THREADS disjoint output ranges.
step_threads :: proc(w: World, g: ^Grid, cur, s, next: ^Boids) -> (total: u64) {
	n := cur.n
	grid_build(g, w, cur.c.x[:n], cur.c.y[:n], row_major)
	gather_from(s, cur, g.order)
	chunk := (n + THREADS - 1) / THREADS
	jobs: [THREADS]Job
	pool: [THREADS]^thread.Thread
	for &j, i in jobs {
		j = Job{w = w, g = g, s = s.c, out = next.c, k0 = min(i * chunk, n), k1 = min((i + 1) * chunk, n)}
		pool[i] = thread.create_and_start_with_poly_data(&j, run_job)
	}
	thread.join_multiple(..pool[:])
	for t, i in pool {
		thread.destroy(t)
		total += jobs[i].total // read only after the join
	}
	return
}

// ---- driver ----

LABELS :: [6]string{"naive", "grid", "sorted", "morton", "sorted simd", "simd 2 threads"}

// Everything one benchmark call needs; `variant` picks the step procedure.
Ctx :: struct {
	w:                           World,
	variant:                     int,
	spawned, in_rows, in_morton: ^Boids,
	g, gm:                       ^Grid,
	s, next:                     ^Boids,
}

run_step :: proc(c: ^Ctx) -> u64 {
	switch c.variant {
	case 0:
		return step_naive(c.w, c.spawned, c.next)
	case 1:
		return step_grid(c.w, c.g, c.spawned, c.next)
	case 2:
		return step_sorted(c.w, c.g, c.in_rows, c.s, c.next)
	case 3:
		return step_morton(c.w, c.gm, c.in_morton, c.s, c.next)
	case 4:
		return step_simd(c.w, c.g, c.in_rows, c.s, c.next)
	}
	return step_threads(c.w, c.g, c.in_rows, c.s, c.next)
}

// The state indexed by spawn id, so outputs stored in different orders can be compared.
by_id :: proc(b: ^Boids, v: [][4]f32) {
	c := b.c
	for k in 0 ..< b.n {
		v[c.id[k]] = {c.x[k], c.y[k], c.vx[k], c.vy[k]}
	}
}

// FNV-1a over the bits of the state in spawn order: equal only if every float is bit-identical.
checksum :: proc(v: [][4]f32) -> u64 {
	h := u64(0xCBF2_9CE4_8422_2325)
	for s in v {
		for f in s {
			h = (h ~ u64(transmute(u32)f)) * 0x100_0000_01B3
		}
	}
	return h
}

// Largest difference in any position or velocity component.
max_diff :: proc(a, b: [][4]f32) -> (m: f32) {
	for p, i in a {
		for u, k in p {
			m = max(m, abs(u - b[i][k]))
		}
	}
	return
}

// Distance checks per step: n² for naive, the sum of 3×3 block sizes for the grid.
grid_checks :: proc(w: World, g: ^Grid, b: ^Boids) -> (checks: u64) {
	for i in 0 ..< b.n {
		x0, x1, y0, y1 := block(w, b.c.x[i], b.c.y[i])
		for row in y0 ..= y1 {
			lo, hi := span(g, row * w.side + x0, row * w.side + x1)
			checks += u64(hi - lo)
		}
	}
	return
}

main :: proc() {
	args := parse_args()
	fmt.printfln("ch10 (odin): boids step, %d boids per unit cell on average, neighbour radius 1, %d threads; quick=%v", BOIDS_PER_CELL, THREADS, args.quick)
	ok := true
	for e := uint(10); e <= 20; e += 2 {
		n := 1 << e
		if n > args.n {
			break
		}
		w := world_for_count(n)
		spawned := boids_spawn(n, w)
		defer delete(spawned.soa)
		g := grid_make(int(w.side) * int(w.side), n)
		defer grid_delete(g)
		gm := grid_make(morton_cells(w), n)
		defer grid_delete(gm)
		grid_build(&g, w, spawned.c.x[:n], spawned.c.y[:n], row_major)
		checks := grid_checks(w, &g, &spawned)
		// Inputs as the previous frame would leave them: spawn order for naive and grid,
		// cell order for the variants that reorder every step.
		in_rows := boids_make(n)
		defer delete(in_rows.soa)
		gather_from(&in_rows, &spawned, g.order)
		grid_build(&gm, w, spawned.c.x[:n], spawned.c.y[:n], morton_key)
		in_morton := boids_make(n)
		defer delete(in_morton.soa)
		gather_from(&in_morton, &spawned, gm.order)

		fmt.printfln("\nN = %d: world %d×%d cells, distance checks per step: naive %d, grid %d (%.1f per boid)", n, w.side, w.side, u64(n) * u64(n), checks, f64(checks) / f64(n))
		fmt.printfln("  %-15s %12s %10s %12s %14s", "variant", "median us", "ns/boid", "neighbours", "max |diff|")
		s := boids_make(n)
		defer delete(s.soa)
		next := boids_make(n)
		defer delete(next.soa)
		ref_state := make([][4]f32, n)
		defer delete(ref_state)
		state := make([][4]f32, n)
		defer delete(state)
		ref_total: Maybe(u64)
		labels := LABELS
		for label, v in labels {
			if v == 0 && n > NAIVE_MAX {
				continue
			}
			ctx := Ctx{w, v, &spawned, &in_rows, &in_morton, &g, &gm, &s, &next}
			total := run_step(&ctx)
			by_id(&next, state)
			if ref_total == nil {
				ref_total = total
				copy(ref_state, state)
			}
			diff := max_diff(ref_state, state)
			good := total == ref_total.? && diff <= 1e-4
			ok = ok && good
			if v <= 1 {
				fmt.printfln("  (%s state checksum %016x)", label, checksum(state))
			}
			runs := bench_runs(run_step, &ctx)
			med := runs[RUNS / 2]
			fmt.printfln("  %-15s %12.1f %10.2f %12d %14.2e %s", label, f64(i64(med)) / 1000, f64(i64(med)) / f64(n), total, diff, good ? "ok" : "MISMATCH")
			emit_bench("ch10-boids", label, n, runs[:])
		}
	}
	fmt.printfln("\nall variants agree (neighbour counts exact, state within 1e-4): %s", ok ? "yes" : "NO")
	if !ok {
		os.exit(1)
	}
}
