// Chapter 6: allocation strategies. Same workloads as ../rust/src/main.rs and ../zig/main.zig.
//   1. frame: every tick builds many short-lived byte strings, uses them, throws them away.
//      heap per object (context.allocator) vs a frame arena (mem.Arena, free_all once per tick),
//      plus context.temp_allocator, Odin's built-in per-frame arena.
//   2. pool: projectiles with individual lifetimes. new per object vs a hand-written pool allocator.
//   3. the arena + growing [dynamic] pitfall, and 4. reserve-then-commit with core:mem/virtual.
// Run (from code/ch06-allocation-strategies): odin run odin -o:speed -vet -strict-style -- [N] [--quick]
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

import "base:runtime"
import "core:mem"
import vmem "core:mem/virtual"

TICKS :: 16 // frames per benchmark run
MAX_MSG :: 71 // longest message in bytes
POOL_TICKS :: 64
MAX_TTL :: 16

// A splitmix64-style mix of (tick, i). Every language computes the same numbers.
mix :: proc(tick, i: u64) -> u64 {
	h := (i * 0x9E37_79B9_7F4A_7C15) ~ (tick * 0xBF58_476D_1CE4_E5B9)
	h ~= h >> 31
	h *= 0x94D0_49BB_1331_11EB
	return h ~ (h >> 29)
}

// ---- 1. frame workload ----

// One frame: build `count` short-lived messages (8..=71 bytes), use them, drop them.
// Everything comes from context.allocator, so the caller decides where the frame lives.
tick :: proc(t: u64, count: int, free_each: bool) -> u64 {
	msgs := make([dynamic][]u8, 0, count)
	for i in 0 ..< count {
		h := mix(t, u64(i))
		m := non_zero_make([]u8, 8 + int(h >> 58))
		for &b, j in m {
			b = u8(h) + u8(j)
		}
		append(&msgs, m)
	}
	sum: u64
	for m in msgs {
		bytes: u64
		for b in m {
			bytes += u64(b)
		}
		sum += bytes ~ (u64(len(m)) << 32)
	}
	if free_each {
		for m in msgs {
			delete(m)
		}
		delete(msgs)
	}
	return sum
}

Frame :: struct {
	arena: ^mem.Arena,
	count: int,
}

frames_heap :: proc(f: ^Frame) -> u64 {
	acc: u64
	for t in 0 ..< u64(TICKS) {
		acc += tick(t, f.count, true)
	}
	return acc
}

frames_arena :: proc(f: ^Frame) -> u64 {
	context.allocator = mem.arena_allocator(f.arena) // every make/append below now bumps
	acc: u64
	for t in 0 ..< u64(TICKS) {
		acc += tick(t, f.count, false)
		free_all(context.allocator) // offset = 0
	}
	return acc
}

frames_temp :: proc(f: ^Frame) -> u64 {
	context.allocator = context.temp_allocator
	acc: u64
	for t in 0 ..< u64(TICKS) {
		acc += tick(t, f.count, false)
		free_all(context.temp_allocator)
	}
	return acc
}

// ---- 2. pool workload ----

Projectile :: struct {
	x, y, vx, vy: i32,
	ttl, id:      u32,
}
#assert(size_of(Projectile) == 24)

score :: proc(p: ^Projectile) -> u64 {
	return u64(u32(p.x)) ~ (u64(u32(p.y)) << 20) ~ (u64(p.id) << 40)
}

// A fixed-capacity pool of equal-size chunks, as an Odin Allocator. A free chunk stores a
// pointer to the next free chunk, so the free list costs no memory of its own.
Pool :: struct {
	buf:       []byte,
	chunk:     int,
	align:     int,
	free_head: ^Free_Chunk,
}

Free_Chunk :: struct {
	next: ^Free_Chunk,
}

pool_init :: proc(p: ^Pool, $T: typeid, count: int, backing := context.allocator) -> mem.Allocator_Error {
	p.align = max(align_of(T), align_of(Free_Chunk))
	p.chunk = mem.align_forward_int(max(size_of(T), size_of(Free_Chunk)), p.align)
	p.buf = mem.alloc_bytes_non_zeroed(p.chunk * count, p.align, backing) or_return
	pool_free_all(p)
	return nil
}

// Threads the free list through every chunk, lowest address first.
pool_free_all :: proc(p: ^Pool) {
	p.free_head = nil
	for i := len(p.buf) / p.chunk - 1; i >= 0; i -= 1 {
		c := (^Free_Chunk)(&p.buf[i * p.chunk])
		c.next = p.free_head
		p.free_head = c
	}
}

pool_allocator :: proc(p: ^Pool) -> mem.Allocator {
	return {procedure = pool_allocator_proc, data = p}
}

pool_allocator_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	p := (^Pool)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size > p.chunk || alignment > p.align {
			return nil, .Invalid_Argument
		}
		c := p.free_head
		if c == nil {
			return nil, .Out_Of_Memory
		}
		p.free_head = c.next
		bytes := ([^]byte)(c)[:size]
		if mode == .Alloc {
			mem.zero_slice(bytes)
		}
		return bytes, nil
	case .Free:
		if old_memory != nil {
			c := (^Free_Chunk)(old_memory)
			c.next = p.free_head
			p.free_head = c
		}
	case .Free_All:
		pool_free_all(p)
	case .Resize, .Resize_Non_Zeroed, .Query_Info:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		if set := (^mem.Allocator_Mode_Set)(old_memory); set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Free_All, .Query_Features}
		}
	}
	return nil, nil
}

// Spawn `spawn` projectiles per tick, move them, despawn each when its ttl runs out.
// Every projectile is its own allocation with its own lifetime.
simulate :: proc(alloc: mem.Allocator, spawn: int) -> u64 {
	live: [dynamic]^Projectile
	defer delete(live)
	sum: u64
	for t in 0 ..< POOL_TICKS {
		for i in 0 ..< spawn {
			h := mix(u64(t) + 1000, u64(i))
			p := new_clone(
				Projectile {
					x = i32(h & 0xFFFF),
					y = i32((h >> 16) & 0xFFFF),
					vx = i32((h >> 32) & 15) - 8,
					vy = i32((h >> 36) & 15) - 8,
					ttl = 1 + u32((h >> 40) % MAX_TTL),
					id = u32(t * spawn + i),
				},
				alloc,
			)
			append(&live, p)
		}
		k := 0
		for k < len(live) {
			p := live[k]
			p.x += p.vx
			p.y += p.vy
			p.ttl -= 1
			if p.ttl == 0 {
				sum += score(p)
				free(p, alloc) // libc free, or a push onto the pool's free list
				unordered_remove(&live, k)
			} else {
				k += 1
			}
		}
	}
	for p in live {
		sum += score(p)
		free(p, alloc)
	}
	return sum
}

Sim :: struct {
	pool:  ^Pool,
	spawn: int,
}

sim_heap :: proc(s: ^Sim) -> u64 {
	return simulate(context.allocator, s.spawn)
}

sim_pool :: proc(s: ^Sim) -> u64 {
	return simulate(pool_allocator(s.pool), s.spawn)
}

// ---- 4. reserve, then commit ----

// Resident set size in bytes, from /proc/self/statm (Linux only; 0 if unreadable).
rss_bytes :: proc() -> int {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD() // rewinds the temp arena when this proc returns
	data, err := os.read_entire_file("/proc/self/statm", context.temp_allocator)
	if err != nil {
		return 0
	}
	fields := strings.fields(string(data), context.temp_allocator)
	pages, _ := strconv.parse_int(fields[1] if len(fields) > 1 else "0")
	return pages * 4096
}

main :: proc() {
	when ODIN_DEBUG {
		// Debug builds: wrap the heap in a tracking allocator and report leaks at exit.
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			for _, entry in track.allocation_map {
				fmt.eprintf("%v leaked %v bytes\n", entry.location, entry.size)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	args := parse_args()
	per_tick := max(args.n / TICKS, 1)
	n := per_tick * TICKS
	fmt.printfln("ch06 frame workload: %d ticks x %d messages (8..=%d B), quick=%v", TICKS, per_tick, MAX_MSG, args.quick)

	// Worst case per tick: one slice header and MAX_MSG bytes per message (TigerStyle: size it once).
	backing := make([]byte, per_tick * (size_of([]u8) + MAX_MSG) + 64)
	defer delete(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)
	frame := Frame{&arena, per_tick}

	{
		context.allocator = mem.arena_allocator(&arena)
		keep(tick(0, per_tick, false))
		fmt.printfln(
			"  one tick: %d allocations, arena high-water mark %d of %d B (%.1f B/message)",
			per_tick + 1,
			arena.offset,
			len(arena.data),
			f64(arena.offset) / f64(per_tick),
		)
		free_all(context.allocator)
	}

	heap_sum := frames_heap(&frame)
	arena_sum := frames_arena(&frame)
	temp_sum := frames_temp(&frame)
	fmt.printfln("  checksum heap=0x%016x arena=0x%016x temp=0x%016x match=%v", heap_sum, arena_sum, temp_sum, heap_sum == arena_sum && arena_sum == temp_sum)
	assert(heap_sum == arena_sum && arena_sum == temp_sum)
	temp := (^runtime.Default_Temp_Allocator)(context.temp_allocator.data)
	fmt.printfln("  temp_allocator after free_all: %d B in its first block", temp.arena.total_capacity)

	heap := bench_runs(frames_heap, &frame)
	arena_t := bench_runs(frames_arena, &frame)
	temp_t := bench_runs(frames_temp, &frame)
	ns :: proc(d: time.Duration, n: int) -> f64 {return f64(i64(d)) / f64(n)}
	h_ns := ns(heap[RUNS / 2], n)
	fmt.printfln("  heap per object: %.1f ns/message", h_ns)
	fmt.printfln("  frame arena:     %.1f ns/message (%.1fx)", ns(arena_t[RUNS / 2], n), h_ns / ns(arena_t[RUNS / 2], n))
	fmt.printfln("  temp_allocator:  %.1f ns/message (%.1fx)", ns(temp_t[RUNS / 2], n), h_ns / ns(temp_t[RUNS / 2], n))
	emit_bench("ch06-frame", "heap per object", n, heap[:])
	emit_bench("ch06-frame", "frame arena", n, arena_t[:])
	emit_bench("ch06-frame", "temp_allocator", n, temp_t[:])

	// ---- 2. pool ----
	spawn := max(args.n / POOL_TICKS / 4, 1)
	total := spawn * POOL_TICKS
	pool: Pool
	if err := pool_init(&pool, Projectile, spawn * MAX_TTL); err != nil {
		fmt.panicf("pool_init: %v", err)
	}
	defer delete(pool.buf)
	sim := Sim{&pool, spawn}
	fmt.printfln("ch06 pool workload: %d ticks x %d spawns, 24 B projectiles, ttl 1..=%d", POOL_TICKS, spawn, MAX_TTL)
	heap_p := sim_heap(&sim)
	pool_p := sim_pool(&sim)
	fmt.printfln("  checksum heap=0x%016x pool=0x%016x match=%v", heap_p, pool_p, heap_p == pool_p)
	assert(heap_p == pool_p)
	ph := bench_runs(sim_heap, &sim)
	pp := bench_runs(sim_pool, &sim)
	fmt.printfln("  new per object:  %.1f ns/projectile", ns(ph[RUNS / 2], total))
	fmt.printfln("  pool:            %.1f ns/projectile (%.1fx)", ns(pp[RUNS / 2], total), ns(ph[RUNS / 2], total) / ns(pp[RUNS / 2], total))
	emit_bench("ch06-pool", "heap per object", total, ph[:])
	emit_bench("ch06-pool", "pool", total, pp[:])

	// ---- 3. pitfall: growing [dynamic] arrays inside an arena leave dead copies behind ----
	{
		scratch_buf: [1 << 16]byte
		scratch: mem.Arena
		mem.arena_init(&scratch, scratch_buf[:])
		context.allocator = mem.arena_allocator(&scratch)
		a, b: [dynamic]u32
		for i in 0 ..< u32(1000) {
			append(&a, i) // the two arrays take turns at the end of the arena, so
			append(&b, i) // neither can grow in place: every regrow copies and abandons the old block
		}
		live := (cap(a) + cap(b)) * 4
		fmt.printfln("arena + growing [dynamic]: 2 x 1000 u32, live %d B, arena used %d B (%.1fx)", live, scratch.offset, f64(scratch.offset) / f64(live))

		// The fix: size both arrays once, then make any further growth a loud error.
		free_all(context.allocator)
		c := make([dynamic]u32, 0, 1000)
		d := make([dynamic]u32, 0, 1000)
		c.allocator = mem.panic_allocator()
		d.allocator = mem.panic_allocator()
		for i in 0 ..< u32(1000) {
			append(&c, i)
			append(&d, i)
		}
		fmt.printfln("  pre-sized with a panic_allocator guard: live %d B, arena used %d B", (cap(c) + cap(d)) * 4, scratch.offset)
	}

	// ---- 4. reserve, then commit ----
	// arena_init_static reserves address space (mmap PROT_NONE on Linux) and commits it in
	// steps (mprotect) as the arena fills. Only pages that are written take RAM.
	before := rss_bytes()
	big: vmem.Arena
	if err := vmem.arena_init_static(&big, reserved = 1 << 30); err != nil {
		fmt.panicf("arena_init_static: %v", err)
	}
	defer vmem.arena_destroy(&big)
	reserved := rss_bytes()
	used := non_zero_make([]u8, 16 << 20, vmem.arena_allocator(&big))
	for off := 0; off < len(used); off += 4096 {
		used[off] = 1
	}
	touched := rss_bytes()
	MIB :: 1024.0 * 1024.0
	fmt.printfln(
		"1 GiB virtual arena: reserved %d MiB, committed %d MiB; RSS +%.1f MiB after reserve, +%.1f MiB after touching 16 MiB",
		big.total_reserved >> 20,
		big.curr_block.committed >> 20,
		f64(max(reserved - before, 0)) / MIB,
		f64(max(touched - before, 0)) / MIB,
	)
	free_all(context.temp_allocator)
}
