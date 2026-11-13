// Chapter 1: the shapes benchmark (after Casey Muratori, "Clean" Code, Horrible Performance, 2023).
//
// The same job four ways: compute the area of every shape into an output array.
//   1. dynamic dispatch    []Shape, where Shape = {data: rawptr, vtable: ^Shape_VTable}
//   2. tagged union        []Shape_Union, a type switch per shape, no pointers
//   3. coefficient table   []Flat_Shape, COEF[kind] * width * height, no branch
//   4. per-kind arrays     one array per kind and one loop per array, no tag at all (preview of Chapter 7)
// plus two controls: versions 1 and 2 again on the same shapes sorted by kind, so every branch predicts.
//
// Run (from code/ch01-the-data-is-the-problem): `odin run odin -o:speed -vet -strict-style -- [N] [--quick]`
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

// ---- the shapes: plain structs, shared by every version ----
Square :: struct {
	side: f32,
}
Rectangle :: struct {
	width, height: f32,
}
Triangle :: struct {
	base, height: f32,
}
Circle :: struct {
	radius: f32,
}

square_area :: proc "contextless" (s: Square) -> f32 {return s.side * s.side}
rectangle_area :: proc "contextless" (r: Rectangle) -> f32 {return r.width * r.height}
triangle_area :: proc "contextless" (t: Triangle) -> f32 {return 0.5 * t.base * t.height}
circle_area :: proc "contextless" (c: Circle) -> f32 {return math.PI * c.radius * c.radius}

// An explicit overload set: `area(x)` picks the procedure by the argument's type at compile time.
area :: proc {
	square_area,
	rectangle_area,
	triangle_area,
	circle_area,
}

// ---- 1. dynamic dispatch: a type-erased pointer plus a pointer to a table of procedure pointers ----
Shape_VTable :: struct {
	area: proc "contextless" (data: rawptr) -> f32,
}

Shape :: struct {
	data:   rawptr,
	vtable: ^Shape_VTable,
}

// One vtable per type. Each entry casts the rawptr back to its concrete type.
square_vtable := Shape_VTable {
	area = proc "contextless" (data: rawptr) -> f32 {return area((^Square)(data)^)},
}
rectangle_vtable := Shape_VTable {
	area = proc "contextless" (data: rawptr) -> f32 {return area((^Rectangle)(data)^)},
}
triangle_vtable := Shape_VTable {
	area = proc "contextless" (data: rawptr) -> f32 {return area((^Triangle)(data)^)},
}
circle_vtable := Shape_VTable {
	area = proc "contextless" (data: rawptr) -> f32 {return area((^Circle)(data)^)},
}

areas_dyn :: proc "contextless" (shapes: []Shape, out: []f32) {
	for s, i in shapes {
		out[i] = s.vtable.area(s.data) // load proc pointer from the vtable, indirect call
	}
}

// ---- 2. tagged union: the same structs inside a union, dispatched by a type switch ----
Shape_Union :: union #no_nil {
	Square,
	Rectangle,
	Triangle,
	Circle,
}

areas_switch :: proc "contextless" (shapes: []Shape_Union, out: []f32) {
	for s, i in shapes {
		switch v in s {
		case Square:
			out[i] = area(v)
		case Rectangle:
			out[i] = area(v)
		case Triangle:
			out[i] = area(v)
		case Circle:
			out[i] = area(v)
		}
	}
}

// ---- 3. coefficient table: notice that every area is c * width * height ----
Kind :: enum u8 {
	Square,
	Rectangle,
	Triangle,
	Circle,
}

// Squares and circles store their one dimension twice (height = width), as in Muratori's version.
Flat_Shape :: struct {
	kind:          Kind,
	width, height: f32,
}

// An enumerated array: indexed by Kind directly, no casts.
COEF := [Kind]f32 {
	.Square    = 1.0,
	.Rectangle = 1.0,
	.Triangle  = 0.5,
	.Circle    = math.PI,
}

areas_table :: proc "contextless" (shapes: []Flat_Shape, out: []f32) {
	for s, i in shapes {
		out[i] = COEF[s.kind] * s.width * s.height // no branch: one load from a 16-byte table
	}
}

// ---- 4. per-kind arrays: the kind is which array a shape is in ----
Shapes_By_Kind :: struct {
	squares:    [dynamic]f32, // side
	rectangles: [dynamic][2]f32, // width, height
	triangles:  [dynamic][2]f32, // base, height
	circles:    [dynamic]f32, // radius
}

// Four tight loops with no dispatch. `out` is filled kind by kind, so its order differs from the other versions.
// Copy the slice headers into locals first: read through `s` inside the loops, LLVM must assume a store to
// `o[i]` might change `s.squares` itself, reloads it every iteration, and does not vectorize (much slower).
areas_by_kind :: proc(s: ^Shapes_By_Kind, out: []f32) {
	squares, rectangles, triangles, circles := s.squares[:], s.rectangles[:], s.triangles[:], s.circles[:]
	o := out
	for side, i in squares {
		o[i] = side * side
	}
	o = o[len(squares):]
	for r, i in rectangles {
		o[i] = r[0] * r[1]
	}
	o = o[len(rectangles):]
	for t, i in triangles {
		o[i] = 0.5 * t[0] * t[1]
	}
	o = o[len(triangles):]
	for r, i in circles {
		o[i] = math.PI * r * r
	}
}

// ---- data: the same seeded generator in Rust, Zig and Odin, so all three see the same shapes ----
Split_Mix64 :: struct {
	state: u64,
}

next :: proc(r: ^Split_Mix64) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15 // unsigned arithmetic wraps in Odin
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

// A dimension in [0.5, 16.5) with 12 fractional bits, so it is exact in f32.
dim :: proc(r: ^Split_Mix64) -> f32 {
	return f32(next(r) >> 48) / 4096.0 + 0.5
}

// n shapes in random kind order: (kind, width, height) with height == width for squares and circles.
generate :: proc(n: int) -> []Flat_Shape {
	flat := make([]Flat_Shape, n)
	rng := Split_Mix64{2023}
	for &s in flat {
		kind := Kind(next(&rng) >> 62)
		width := dim(&rng)
		height := kind == .Square || kind == .Circle ? width : dim(&rng)
		s = {kind, width, height}
	}
	return flat
}

to_boxed :: proc(flat: []Flat_Shape) -> []Shape {
	shapes := make([]Shape, len(flat))
	for s, i in flat {
		switch s.kind {
		case .Square:
			shapes[i] = {new_clone(Square{s.width}), &square_vtable}
		case .Rectangle:
			shapes[i] = {new_clone(Rectangle{s.width, s.height}), &rectangle_vtable}
		case .Triangle:
			shapes[i] = {new_clone(Triangle{s.width, s.height}), &triangle_vtable}
		case .Circle:
			shapes[i] = {new_clone(Circle{s.width}), &circle_vtable}
		}
	}
	return shapes
}

free_boxed :: proc(shapes: []Shape) {
	for s in shapes {
		free(s.data)
	}
	delete(shapes)
}

to_union :: proc(flat: []Flat_Shape) -> []Shape_Union {
	shapes := make([]Shape_Union, len(flat))
	for s, i in flat {
		switch s.kind {
		case .Square:
			shapes[i] = Square{s.width}
		case .Rectangle:
			shapes[i] = Rectangle{s.width, s.height}
		case .Triangle:
			shapes[i] = Triangle{s.width, s.height}
		case .Circle:
			shapes[i] = Circle{s.width}
		}
	}
	return shapes
}

// Order-independent checksum: wrapping sum of the f32 bit patterns. Equal iff every version produced the
// same multiset of areas, bit for bit.
checksum :: proc(out: []f32) -> (acc: u64) {
	for a in out {
		acc += u64(transmute(u32)a)
	}
	return
}

// Contexts for bench_runs: each returns the bits of the last area so the call has a result to keep alive.
Dyn_Ctx :: struct {
	shapes: []Shape,
	out:    []f32,
}
run_dyn :: proc(c: Dyn_Ctx) -> u64 {
	areas_dyn(c.shapes, c.out)
	return u64(transmute(u32)c.out[len(c.out) - 1])
}
Union_Ctx :: struct {
	shapes: []Shape_Union,
	out:    []f32,
}
run_switch :: proc(c: Union_Ctx) -> u64 {
	areas_switch(c.shapes, c.out)
	return u64(transmute(u32)c.out[len(c.out) - 1])
}
Flat_Ctx :: struct {
	shapes: []Flat_Shape,
	out:    []f32,
}
run_table :: proc(c: Flat_Ctx) -> u64 {
	areas_table(c.shapes, c.out)
	return u64(transmute(u32)c.out[len(c.out) - 1])
}
Kind_Ctx :: struct {
	shapes: ^Shapes_By_Kind,
	out:    []f32,
}
run_by_kind :: proc(c: Kind_Ctx) -> u64 {
	areas_by_kind(c.shapes, c.out)
	return u64(transmute(u32)c.out[len(c.out) - 1])
}

Report :: struct {
	n:    int,
	sums: [dynamic]u64,
}

report :: proc(r: ^Report, label: string, runs: [RUNS]time.Duration, out: []f32) {
	runs := runs
	sum := checksum(out)
	total: f64
	for a in out {
		total += f64(a)
	}
	ns := f64(i64(runs[RUNS / 2])) / f64(r.n)
	fmt.printfln("%-25s %7.3f ns/shape   checksum %#016x   total area %.1f", label, ns, sum, total)
	emit_bench("ch01-shapes", label, r.n, runs[:])
	append(&r.sums, sum)
}

main :: proc() {
	args := parse_args()
	n := args.n
	flat := generate(n)
	defer delete(flat)

	boxed := to_boxed(flat)
	defer free_boxed(boxed)
	unions := to_union(flat)
	defer delete(unions)
	by_kind: Shapes_By_Kind
	defer {
		delete(by_kind.squares)
		delete(by_kind.rectangles)
		delete(by_kind.triangles)
		delete(by_kind.circles)
	}
	for s in flat {
		switch s.kind {
		case .Square:
			append(&by_kind.squares, s.width)
		case .Rectangle:
			append(&by_kind.rectangles, [2]f32{s.width, s.height})
		case .Triangle:
			append(&by_kind.triangles, [2]f32{s.width, s.height})
		case .Circle:
			append(&by_kind.circles, s.width)
		}
	}

	// Machine-independent facts: how many bytes each representation reads per shape.
	gaps := make([]uintptr, max(n - 1, 0))
	defer delete(gaps)
	for &g, i in gaps {
		a, b := uintptr(boxed[i].data), uintptr(boxed[i + 1].data)
		g = max(a, b) - min(a, b)
	}
	slice.sort(gaps)
	heap_gap := len(gaps) > 0 ? gaps[len(gaps) / 2] : 0
	kind_bytes :=
		4 * (len(by_kind.squares) + len(by_kind.circles)) +
		8 * (len(by_kind.rectangles) + len(by_kind.triangles))
	fmt.printfln(
		"%d shapes: %d squares, %d rectangles, %d triangles, %d circles (random order)",
		n,
		len(by_kind.squares),
		len(by_kind.rectangles),
		len(by_kind.triangles),
		len(by_kind.circles),
	)
	fmt.printfln(
		"bytes per shape read: Shape %d + heap object (median %d B apart) | Shape_Union %d | Flat_Shape %d | per-kind %.1f avg",
		size_of(Shape),
		heap_gap,
		size_of(Shape_Union),
		size_of(Flat_Shape),
		f64(kind_bytes) / f64(n),
	)

	out := make([]f32, n)
	defer delete(out)
	rep := Report{n = n}
	defer delete(rep.sums)

	report(&rep, "dynamic dispatch", bench_runs(run_dyn, Dyn_Ctx{boxed, out}), out)
	report(&rep, "tagged union", bench_runs(run_switch, Union_Ctx{unions, out}), out)
	report(&rep, "coefficient table", bench_runs(run_table, Flat_Ctx{flat, out}), out)
	report(&rep, "per-kind arrays", bench_runs(run_by_kind, Kind_Ctx{&by_kind, out}), out)

	// Controls: the same shapes sorted by kind (stable), so every branch and call predicts well.
	// The objects are allocated in sorted order, so the heap is walked in order just like above.
	sorted := slice.clone(flat)
	defer delete(sorted)
	slice.stable_sort_by(sorted, proc(a, b: Flat_Shape) -> bool {return a.kind < b.kind})
	boxed_sorted := to_boxed(sorted)
	defer free_boxed(boxed_sorted)
	unions_sorted := to_union(sorted)
	defer delete(unions_sorted)
	report(&rep, "dynamic dispatch, sorted", bench_runs(run_dyn, Dyn_Ctx{boxed_sorted, out}), out)
	report(&rep, "tagged union, sorted", bench_runs(run_switch, Union_Ctx{unions_sorted, out}), out)

	for s in rep.sums[1:] {
		if s != rep.sums[0] {
			fmt.eprintfln("versions disagree: %x", rep.sums[:])
			os.exit(1)
		}
	}
	fmt.printfln("checksums: all %d runs match", len(rep.sums))
}
