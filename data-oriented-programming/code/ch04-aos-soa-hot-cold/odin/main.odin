// Chapter 4: one particle update in four layouts (AoS, hot/cold, SoA, AoSoA) plus three controls:
// read every field (AoS catches up), random whole-record reads (AoS wins), and 16 page-aligned
// columns versus staggered columns (cache-set aliasing). Every variant of one experiment must print
// the same checksum, in all three languages.
//
//   odin run odin -o:speed -vet -strict-style -- [N] [--quick]      (from code/ch04-aos-soa-hot-cold)
//
// Sizes: N/64, N and 4N particles (default N = 1 << 20; --quick caps N at 4096).
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

// A power of two, so `v * DT` is exact and fused or unfused multiply-add give the same bits.
DT :: f32(1.0 / 64.0)
// AoSoA block width: eight f32 lanes, one AVX2 register.
LANES :: 8

// ---- the data: a fat 64-byte particle ----
// Sixteen 4-byte fields. The update reads 6 of them (24 B) and writes 3.
// Odin keeps declaration order; #align(64) makes one particle exactly one cache line.
Particle :: struct #align (64) {
	px, py, pz:              f32, // hot: read and written every frame
	vx, vy, vz:              f32, // hot: read every frame
	mass, age, life, size:   f32, // cold from here on
	color, id, flags, seed:  u32,
	emitter, group:          u32,
}
#assert(size_of(Particle) == 64)

// lowbias32 (Chris Wellons): the same integer hash in all three languages, so the data is identical.
// Unsigned arithmetic wraps in Odin, so no special operators are needed.
hash :: proc "contextless" (x: u32) -> u32 {
	x := x
	x ~= x >> 16
	x *= 0x7feb352d
	x ~= x >> 15
	x *= 0x846ca68b
	return x ~ (x >> 16)
}

// 24 random bits as an exact f32 in [0, 1).
unit :: proc "contextless" (h: u32) -> f32 {
	return f32(h >> 8) / 16777216.0
}

particle :: proc "contextless" (index: int) -> Particle {
	i := u32(index)
	b := i * 16
	return Particle {
		px = unit(hash(b + 0)) * 128, py = unit(hash(b + 1)) * 128, pz = unit(hash(b + 2)) * 128,
		vx = unit(hash(b + 3)) - 0.5, vy = unit(hash(b + 4)) - 0.5, vz = unit(hash(b + 5)) - 0.5,
		mass = unit(hash(b + 6)) + 1, age = unit(hash(b + 7)), life = unit(hash(b + 8)) * 4, size = unit(hash(b + 9)),
		color = hash(b + 10), id = i, flags = hash(b + 12) & 0xff,
		seed = hash(b + 13), emitter = hash(b + 14) & 63, group = hash(b + 15) & 7,
	}
}

// The record checksum: the bit patterns of all 16 fields, summed as integers (exact, any order).
field_sum :: proc "contextless" (p: Particle) -> u64 {
	f :: proc "contextless" (x: f32) -> u64 { return u64(transmute(u32)x) }
	return(
		f(p.px) + f(p.py) + f(p.pz) + f(p.vx) + f(p.vy) + f(p.vz) + f(p.mass) + f(p.age) + f(p.life) + f(p.size) +
		u64(p.color) + u64(p.id) + u64(p.flags) + u64(p.seed) + u64(p.emitter) + u64(p.group) \
	)
}

pos_sum :: proc "contextless" (p: Particle) -> u64 {
	return u64(transmute(u32)p.px) + u64(transmute(u32)p.py) + u64(transmute(u32)p.pz)
}

// ---- 1. AoS ----
Aos :: struct {
	ps: []Particle,
}

aos_build :: proc(l: ^Aos, n: int) {
	l.ps = make([]Particle, n) // make uses align_of(Particle) = 64
	for &p, i in l.ps {
		p = particle(i)
	}
	return
}
aos_update :: proc(l: Aos) -> u64 {
	for &p in l.ps {
		p.px += p.vx * DT
		p.py += p.vy * DT
		p.pz += p.vz * DT
	}
	return 0
}
aos_get :: proc(l: Aos, i: int) -> Particle {return l.ps[i]}
aos_every :: proc(l: Aos) -> (s: u64) {
	for p in l.ps {
		s += field_sum(p)
	}
	return
}
aos_free :: proc(l: Aos) {delete(l.ps)}

// ---- 2. hot/cold split: two plain slices, zipped into one #soa view with soa_zip ----
Hot :: struct {
	px, py, pz, vx, vy, vz: f32,
}
Cold :: struct {
	mass, age, life, size:                   f32,
	color, id, flags, seed, emitter, group: u32,
}
#assert(size_of(Hot) == 24 && size_of(Cold) == 40)

Hot_Cold :: struct {
	hc: #soa[]struct {
		hot:  Hot,
		cold: Cold,
	},
}

hot_cold_build :: proc(l: ^Hot_Cold, n: int) {
	hot := make([]Hot, n)
	cold := make([]Cold, n)
	for i in 0 ..< n {
		p := particle(i)
		hot[i] = {p.px, p.py, p.pz, p.vx, p.vy, p.vz}
		cold[i] = {p.mass, p.age, p.life, p.size, p.color, p.id, p.flags, p.seed, p.emitter, p.group}
	}
	l.hc = soa_zip(hot = hot, cold = cold) // no copy: a #soa slice over the two existing arrays
	return
}
hot_cold_update :: proc(l: Hot_Cold) -> u64 {
	for &h in l.hc.hot[:len(l.hc)] {
		h.px += h.vx * DT
		h.py += h.vy * DT
		h.pz += h.vz * DT
	}
	return 0
}
// Glue one hot and one cold record back into a whole particle.
hot_cold_join :: proc "contextless" (h: Hot, c: Cold) -> Particle {
	return {
		h.px, h.py, h.pz, h.vx, h.vy, h.vz,
		c.mass, c.age, c.life, c.size, c.color, c.id, c.flags, c.seed, c.emitter, c.group,
	}
}
hot_cold_get :: proc(l: Hot_Cold, i: int) -> Particle {return hot_cold_join(l.hc[i].hot, l.hc[i].cold)}
hot_cold_every :: proc(l: Hot_Cold) -> (s: u64) {
	for r in l.hc { 	// one row of the zipped view, like soa_every's loop
		s += field_sum(hot_cold_join(r.hot, r.cold))
	}
	return
}
hot_cold_free :: proc(l: Hot_Cold) {
	hot, cold := soa_unzip(l.hc) // back to the two plain slices
	delete(hot)
	delete(cold)
}

// ---- 3. SoA: #soa[]Particle, one column per field in one allocation ----
Soa :: struct {
	ps: #soa[]Particle,
}

soa_build :: proc(l: ^Soa, n: int) {
	l.ps = make(#soa[]Particle, n)
	for i in 0 ..< n {
		l.ps[i] = particle(i) // same syntax as AoS
	}
	return
}
soa_update :: proc(l: Soa) -> u64 {
	for &p in l.ps { 	// p is an SOA proxy: p.px reads column px at this index
		p.px += p.vx * DT
		p.py += p.vy * DT
		p.pz += p.vz * DT
	}
	return 0
}
soa_get :: proc(l: Soa, i: int) -> Particle {return l.ps[i]} // gathers 16 columns
soa_every :: proc(l: Soa) -> (s: u64) {
	for p in l.ps {
		s += field_sum(p)
	}
	return
}
soa_free :: proc(l: Soa) {delete(l.ps)}

// ---- 4. AoSoA: a slice of fixed #soa[8]Particle blocks ----
// #soa[8]Particle is a struct of sixteen [8]f32/[8]u32 arrays: exactly one AoSoA block.
Block :: #soa[LANES]Particle
#assert(size_of(Block) == 16 * 4 * LANES)

Aosoa :: struct {
	blocks: []Block,
}

aosoa_build :: proc(l: ^Aosoa, n: int) {
	assert(n % LANES == 0)
	l.blocks = make_aligned([]Block, n / LANES, 64)
	for i in 0 ..< n {
		l.blocks[i / LANES][i % LANES] = particle(i)
	}
	return
}
aosoa_update :: proc(l: Aosoa) -> u64 {
	for &b in l.blocks {
		b.px += b.vx * DT // array programming: eight lanes per statement
		b.py += b.vy * DT
		b.pz += b.vz * DT
	}
	return 0
}
aosoa_get :: proc(l: Aosoa, i: int) -> Particle {return l.blocks[i / LANES][i % LANES]}
aosoa_every :: proc(l: Aosoa) -> (s: u64) {
	for &b in l.blocks {
		for j in 0 ..< LANES {
			s += field_sum(b[j])
		}
	}
	return
}
aosoa_free :: proc(l: Aosoa) {delete(l.blocks)}

// Explicit overload sets: the generic run() below picks the right one for each layout type.
build :: proc {
	aos_build,
	hot_cold_build,
	soa_build,
	aosoa_build,
}
update :: proc {
	aos_update,
	hot_cold_update,
	soa_update,
	aosoa_update,
}
get :: proc {
	aos_get,
	hot_cold_get,
	soa_get,
	aosoa_get,
}
every :: proc {
	aos_every,
	hot_cold_every,
	soa_every,
	aosoa_every,
}
destroy :: proc {
	aos_free,
	hot_cold_free,
	soa_free,
	aosoa_free,
}

// ---- the experiments ----
Random_Ctx :: struct($L: typeid) {
	l:   L,
	idx: []u32,
}

// Random whole-record reads: the access pattern where AoS wins.
random_reads :: proc(c: Random_Ctx($L)) -> (s: u64) {
	for i in c.idx {
		s += field_sum(get(c.l, int(i)))
	}
	return
}

Row :: struct {
	label: string,
	bytes: int,
	ns:    [3]time.Duration,
	sums:  [3]u64,
}

run :: proc($L: typeid, label: string, bytes, n: int, idx: []u32) -> Row {
	l: L
	build(&l, n)
	defer destroy(l)
	upd: proc(l: L) -> u64 = update // picks the overload for L
	evr: proc(l: L) -> u64 = every
	up := bench_runs(upd, l) // 1 warm-up + 7 timed = 8 updates
	pos: u64
	for i in 0 ..< n {
		pos += pos_sum(get(l, i))
	}
	ev := bench_runs(evr, l)
	rctx := Random_Ctx(L){l, idx}
	rnd_f: proc(c: Random_Ctx(L)) -> u64 = random_reads // a concrete instance of the polymorphic proc
	rnd := bench_runs(rnd_f, rctx)
	emit_bench("ch04-update", label, n, up[:])
	emit_bench("ch04-every", label, n, ev[:])
	emit_bench("ch04-random", label, n, rnd[:])
	return {label, bytes, {up[RUNS / 2], ev[RUNS / 2], rnd[RUNS / 2]}, {pos, every(l), random_reads(rctx)}}
}

// ---- 16 columns in one buffer: 4 KiB apart vs staggered by one cache line ----
COLS :: 16

sum_columns :: proc(cols: ^[COLS][]u32) -> (total: u64) {
	n := len(cols[0])
	for i in 0 ..< n {
		s: u64
		#unroll for k in 0 ..< COLS {
			s += u64(cols[k][i])
		}
		total += s
	}
	return
}

// Column k starts at k * stride elements. stride = n (n a power of two): every column start is a
// multiple of 4 KiB from the first, so element i of all 16 columns maps to the same L1 set.
alias_experiment :: proc(n: int) -> (sums: [2]u64) {
	SKEW :: 16 // 16 u32 = 64 B = one cache line
	buf := make_aligned([]u32, COLS * (n + SKEW), 64)
	defer delete(buf)
	Case :: struct {
		stride: int,
		label:  string,
	}
	cases := [2]Case{{n, "4 KiB-aligned columns"}, {n + SKEW, "staggered columns"}}
	for c, s in cases {
		cols: [COLS][]u32
		for &col, k in cols {
			col = buf[k * c.stride:][:n]
			for &x, i in col {
				x = hash(u32(i * COLS + k))
			}
		}
		runs := bench_runs(sum_columns, &cols)
		sums[s] = sum_columns(&cols)
		fmt.printfln(
			"  %-22s %8.3f ns/elem  checksum %016x  column starts mod 4096: %d, %d, %d, %d ...",
			c.label,
			per_elem(runs[RUNS / 2], n),
			sums[s],
			uintptr(raw_data(cols[0])) % 4096,
			uintptr(raw_data(cols[1])) % 4096,
			uintptr(raw_data(cols[2])) % 4096,
			uintptr(raw_data(cols[3])) % 4096,
		)
		emit_bench("ch04-alias", c.label, n, runs[:])
	}
	return
}

per_elem :: proc(d: time.Duration, n: int) -> f64 {
	return f64(i64(d)) / f64(n)
}

main :: proc() {
	args := parse_args()
	base := max(args.n, 64) / LANES * LANES
	fmt.printfln(
		"ch04 (odin): size_of Particle %d B, Hot %d B, Cold %d B, Block %d B; quick=%v",
		size_of(Particle),
		size_of(Hot),
		size_of(Cold),
		size_of(Block),
		args.quick,
	)
	{
		// Where #soa puts its columns: back to back in one allocation, in declaration order.
		probe := make(#soa[]Particle, 4096)
		defer delete(probe)
		p0 := uintptr(raw_data(probe.px[:1]))
		fmt.printfln(
			"#soa[]Particle, len 4096: px, vx, seed columns start at +%d, +%d, +%d B (mod 4096: %d, %d, %d); size_of(#soa[]Particle) = %d B",
			0,
			uintptr(raw_data(probe.vx[:1])) - p0,
			uintptr(raw_data(probe.seed[:1])) - p0,
			p0 % 4096,
			uintptr(raw_data(probe.vx[:1])) % 4096,
			uintptr(raw_data(probe.seed[:1])) % 4096,
			size_of(#soa[]Particle),
		)
	}

	ok := true
	for n0 in ([3]int{base / 64 / LANES * LANES, base, base * 4}) {
		n := max(n0, LANES)
		idx := make([]u32, n)
		defer delete(idx)
		for &x, k in idx {
			x = hash(u32(k) ~ 0x9e3779b9) % u32(n)
		}

		fmt.printfln("\nn = %d particles (%d KiB of AoS)", n, n * 64 / 1024)
		fmt.printfln(
			"  %-9s %7s %14s %14s %16s   checksums (update / every / random)",
			"layout",
			"B/p",
			"update ns/p",
			"every ns/p",
			"random ns/read",
		)
		rows := [4]Row {
			run(Aos, "AoS", 64, n, idx),
			run(Hot_Cold, "hot/cold", 24, n, idx),
			run(Soa, "SoA", 24, n, idx),
			run(Aosoa, "AoSoA", 24, n, idx),
		}
		for r in rows {
			fmt.printfln(
				"  %-9s %7d %14.3f %14.3f %16.3f   %016x / %016x / %016x",
				r.label,
				r.bytes,
				per_elem(r.ns[0], n),
				per_elem(r.ns[1], n),
				per_elem(r.ns[2], n),
				r.sums[0],
				r.sums[1],
				r.sums[2],
			)
			ok &&= r.sums == rows[0].sums
		}
		// Columns of n u32 are a multiple of 4 KiB apart only when n is a multiple of 1024.
		if n % 1024 == 0 {
			a := alias_experiment(n)
			ok &&= a[0] == a[1]
		} else {
			fmt.printfln("  (alias experiment skipped: %d u32 columns are not a multiple of 4 KiB)", n)
		}
	}
	fmt.printfln("\nchecksums match across layouts: %s", ok ? "yes" : "NO")
	if !ok {
		os.exit(1)
	}
}
