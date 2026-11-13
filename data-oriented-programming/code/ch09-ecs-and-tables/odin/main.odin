// Chapter 9: ECS and Thinking in Tables.
// A tiny ECS with generational entity ids (entity.odin) and two storages for the same data:
//   1. sparse sets, one per component type (sparse.odin), the EnTT layout;
//   2. one table per component combination (archetype.odin), the Unity/Bevy/flecs layout.
// The same world is built in both: N entities with Pos, every 2nd with Vel, every 4th with Hp.
// Benchmarks: add/remove churn (toggle Vel on N/16 random entities), then iteration of a
// 2-component query (Pos += Vel) and a 3-component query (Pos, Vel -> Hp). Checksums must match.
// Usage (from code/ch09-ecs-and-tables): odin run odin -o:speed -vet -strict-style -- [N] [--quick]
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

Pos :: struct {
	x, y: i32,
}
Vel :: struct {
	x, y: i32,
}
Hp :: struct {
	v: i32,
}

// splitmix64: the same sequence in all three languages (as in Chapter 5).
Rng :: struct {
	s: u64,
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	r.s += 0x9E37_79B9_7F4A_7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return int((z ~ (z >> 31)) % u64(n))
}
SEED :: 9

initial :: proc(i: int) -> (pos: Pos, vel: Maybe(Vel), hp: Maybe(Hp)) {
	pos = {i32(i), -i32(i)}
	if i % 2 == 0 {vel = Vel{i32(i % 7) - 3, 1}}
	if i % 4 == 0 {hp = Hp{100}}
	return
}

vel_for :: proc(e: Entity) -> Vel {
	return {i32(e.index % 5) - 2, -1}
}

bits :: #force_inline proc(x: i32) -> u64 {
	return u64(u32(x))
}

// Order-independent: wrapping sums commute, so both storages must agree whatever their row order.
mix :: proc(p: Maybe(Pos), v: Maybe(Vel), h: Maybe(Hp)) -> (s: u64) {
	if q, ok := p.?; ok {s += bits(q.x * 31 + q.y * 17)}
	if q, ok := v.?; ok {s += bits((q.x * 7) ~ q.y) + (1 << 32)}
	if q, ok := h.?; ok {s += bits(q.v * 3) + (1 << 40)}
	return
}

// ---- sparse-set systems ----
move_one :: proc(s: ^u64, p: ^Pos, v: ^Vel) {
	p.x += v.x
	p.y += v.y
	s^ += bits(p.x)
}

damage_one :: proc(s: ^u64, p: ^Pos, v: ^Vel, h: ^Hp) {
	h.v = h.v - (p.x & 15) + v.y
	s^ += bits(h.v)
}

sparse_move :: proc(w: ^Sparse_World) -> (s: u64) {
	query2(&w.pos, &w.vel, &s, move_one)
	return
}

sparse_damage :: proc(w: ^Sparse_World) -> (s: u64) {
	query3(&w.pos, &w.vel, &w.hp, &s, damage_one)
	return
}

// What a churn run needs: the world and the random stream.
Churn :: struct($W: typeid) {
	w:   ^W,
	rng: Rng,
	k:   int,
}

sparse_toggle :: proc(c: ^Churn(Sparse_World)) -> u64 {
	w := c.w
	for _ in 0 ..< c.k {
		e := entities_at(&w.entities, rng_below(&c.rng, len(w.entities.generations)))
		if _, removed := sparse_remove(&w.vel, e); !removed {
			sparse_insert(&w.vel, e, vel_for(e))
		}
	}
	return u64(len(w.vel.dense))
}

sparse_checksum :: proc(w: ^Sparse_World) -> (s: u64) {
	for i in 0 ..< len(w.entities.generations) {
		e := entities_at(&w.entities, i)
		if !entities_alive(&w.entities, e) {
			continue
		}
		p: Maybe(Pos)
		v: Maybe(Vel)
		h: Maybe(Hp)
		if x := sparse_get(&w.pos, e); x != nil {p = x^}
		if x := sparse_get(&w.vel, e); x != nil {v = x^}
		if x := sparse_get(&w.hp, e); x != nil {h = x^}
		s += mix(p, v, h)
	}
	return
}

// ---- archetype systems: a query is a loop over matching tables, then plain zipped columns ----
arch_move :: proc(w: ^Arch_World) -> (s: u64) {
	for &t in w.tables {
		if !({.Pos, .Vel} <= t.mask) {
			continue
		}
		pos, vel := t.pos[:], t.vel[:]
		for &p, i in pos {
			p.x += vel[i].x
			p.y += vel[i].y
			s += bits(p.x)
		}
	}
	return
}

arch_damage :: proc(w: ^Arch_World) -> (s: u64) {
	for &t in w.tables {
		if !({.Pos, .Vel, .Hp} <= t.mask) {
			continue
		}
		pos, vel, hp := t.pos[:], t.vel[:], t.hp[:]
		for &h, i in hp {
			h.v = h.v - (pos[i].x & 15) + vel[i].y
			s += bits(h.v)
		}
	}
	return
}

arch_toggle :: proc(c: ^Churn(Arch_World)) -> u64 {
	w := c.w
	for _ in 0 ..< c.k {
		e := entities_at(&w.entities, rng_below(&c.rng, len(w.entities.generations)))
		if arch_has(w, e, .Vel) {
			arch_remove_vel(w, e)
		} else {
			arch_add_vel(w, e, vel_for(e))
		}
	}
	return u64(arch_count_with(w, {.Vel}))
}

arch_checksum :: proc(w: ^Arch_World) -> (s: u64) {
	for i in 0 ..< len(w.entities.generations) {
		e := entities_at(&w.entities, i)
		if !entities_alive(&w.entities, e) {
			continue
		}
		r := arch_get(w, e)
		s += mix(r.pos, r.vel, r.hp)
	}
	return
}

// Generations at work: a despawned id must stop resolving in both storages, even after its
// index is reused.
stale_id_demo :: proc() {
	sw: Sparse_World
	defer sparse_world_destroy(&sw)
	aw := arch_world_make()
	defer arch_world_destroy(&aw)
	old_s, old_a: Entity
	for i in 0 ..< 4 {
		p, v, h := initial(i)
		a := sparse_world_spawn(&sw, p, v, h)
		b := arch_spawn(&aw, p, v, h)
		if i == 2 {
			old_s, old_a = a, b
		}
	}
	ensure(sparse_world_despawn(&sw, old_s) && arch_despawn(&aw, old_a))
	new_s := sparse_world_spawn(&sw, {7, 7}, nil, nil)
	new_a := arch_spawn(&aw, {7, 7}, nil, nil)
	ensure(new_s.index == old_s.index && new_s.generation == old_s.generation + 1 && new_a == new_s)
	ensure(sparse_get(&sw.pos, old_s) == nil && !arch_has(&aw, old_a, .Pos) && !sparse_world_despawn(&sw, old_s))
	ensure(sparse_get(&sw.pos, new_s).x == 7 && arch_get(&aw, new_a).pos.?.x == 7)
	fmt.printfln(
		"stale id check: despawned %dv%d, respawn reused it as %dv%d; the old id resolves to nothing in both storages",
		old_s.index,
		old_s.generation,
		new_s.index,
		new_s.generation,
	)
}

per :: proc(d: time.Duration, n: int) -> f64 {
	return f64(i64(d)) / f64(n)
}

main :: proc() {
	args := parse_args()
	n := args.n
	k := max(n / 16, 1)
	stale_id_demo()

	sw: Sparse_World
	defer sparse_world_destroy(&sw)
	aw := arch_world_make()
	defer arch_world_destroy(&aw)
	for i in 0 ..< n {
		p, v, h := initial(i)
		sparse_world_spawn(&sw, p, v, h)
		arch_spawn(&aw, p, v, h)
	}
	fmt.printfln(
		"%d entities: Pos %d, Vel %d, Hp %d; Entity = %d B, sparse slot = 4 B",
		n,
		len(sw.pos.dense),
		len(sw.vel.dense),
		len(sw.hp.dense),
		size_of(Entity),
	)

	// 1. structural churn: toggle Vel on k random entities per run (8 runs incl. warm-up)
	cs := Churn(Sparse_World){&sw, {SEED}, k}
	rs := bench_runs(sparse_toggle, &cs)
	emit_bench("ch09-churn", "sparse set: toggle Vel", k, rs[:])
	ca := Churn(Arch_World){&aw, {SEED}, k}
	ra := bench_runs(arch_toggle, &ca)
	emit_bench("ch09-churn", "archetype: toggle Vel", k, ra[:])
	fmt.printfln(
		"churn, %d toggles: sparse %.1f ns/op, archetype %.1f ns/op; Vel now on %d | %d entities",
		k,
		per(rs[RUNS / 2], k),
		per(ra[RUNS / 2], k),
		len(sw.vel.dense),
		arch_count_with(&aw, {.Vel}),
	)
	fmt.print("archetype table sizes by mask [-, P, V, PV, H, PH, VH, PVH]: [")
	for &t, m in aw.tables {
		fmt.printf("%s%d", m == 0 ? "" : ", ", len(t.entities))
	}
	fmt.println("]")

	// 2. iteration: the same two systems over both storages
	report :: proc(label: string, rs, ra: [RUNS]time.Duration, n: int) {
		rs, ra := rs, ra
		emit_bench("ch09-iterate", fmt.tprintf("sparse set: %s", label), n, rs[:])
		emit_bench("ch09-iterate", fmt.tprintf("archetype: %s", label), n, ra[:])
		fmt.printfln(
			"%-14s sparse %7.2f ns/entity  archetype %7.2f ns/entity  (%.1fx)",
			label,
			per(rs[RUNS / 2], n),
			per(ra[RUNS / 2], n),
			per(rs[RUNS / 2], 1) / per(ra[RUNS / 2], 1),
		)
	}
	report("move P+=V", bench_runs(sparse_move, &sw), bench_runs(arch_move, &aw), n)
	report("damage P,V->H", bench_runs(sparse_damage, &sw), bench_runs(arch_damage, &aw), n)

	c1, c2 := sparse_checksum(&sw), arch_checksum(&aw)
	fmt.printfln("checksum sparse 0x%016x archetype 0x%016x %s", c1, c2, c1 == c2 ? "(match)" : "MISMATCH")
	if c1 != c2 {
		os.exit(1)
	}
}
