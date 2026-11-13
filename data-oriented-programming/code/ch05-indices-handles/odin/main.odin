// Chapter 5: Indices, Handles and Generations.
//   1. A hand-rolled generational pool (pool.odin), and core:container/handle_map doing the same.
//   2. The same binary search tree built two ways: individually allocated nodes linked by
//      pointers (new), and one [dynamic] array of nodes linked by distinct u32 indices.
//   3. What the generation check costs: random lookups through plain indices vs pool handles.
// Usage (from code/ch05-indices-handles): odin run odin -o:speed -vet -strict-style -- [N] [--quick]
package main

import hm "core:container/handle_map"

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

// Memory figures are not times: "ns" is 0 and "value" carries bytes per node.
emit_memory :: proc(label: string, n: int, bytes_per_node: f64) {
	fmt.printfln(
		`BENCH {{"id":"ch05-memory","label":"%s","lang":"odin","n":%d,"ns":0,"value":%.2f,"unit":"B/node"}}`,
		label,
		n,
		bytes_per_node,
	)
}

// splitmix64: the same key sequence in all three languages.
Rng :: struct {
	s: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.s += 0x9E37_79B9_7F4A_7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

// ---------------------------------------------------------------------------
// Pointer tree: every node is its own heap allocation (new = calloc on Linux).
// ---------------------------------------------------------------------------
PNode :: struct {
	key:   u32,
	left:  ^PNode, // 8 bytes; nil means "no child"
	right: ^PNode,
}
#assert(size_of(PNode) == 24) // declaration order: 4 + 4 padding + 8 + 8, align 8

// Inserts `key` and returns the depth it landed at (the sum of depths is our build checksum).
ptr_insert :: proc(root: ^^PNode, key: u32) -> (depth: u64) {
	link := root
	for link^ != nil {
		link = key < link^.key ? &link^.left : &link^.right
		depth += 1
	}
	link^ = new_clone(PNode{key = key})
	return
}

ptr_destroy :: proc(n: ^PNode) {
	if n == nil {
		return
	}
	ptr_destroy(n.left)
	ptr_destroy(n.right)
	free(n)
}

// In-order walk folding the keys into an order-sensitive hash.
ptr_walk :: proc(n: ^PNode, h0: u64) -> u64 {
	if n == nil {
		return h0
	}
	h := ptr_walk(n.left, h0)
	h = h * 31 + u64(n.key)
	return ptr_walk(n.right, h)
}

ptr_span :: proc(n: ^PNode, lo, hi: ^uintptr) {
	if n == nil {
		return
	}
	a := uintptr(n)
	lo^ = min(lo^, a)
	hi^ = max(hi^, a + size_of(PNode))
	ptr_span(n.left, lo, hi)
	ptr_span(n.right, lo, hi)
}

// ---------------------------------------------------------------------------
// Index tree: one [dynamic] array, links are distinct u32 indices.
// ---------------------------------------------------------------------------
// `distinct` makes a new type with u32's representation: a Node_Id will not silently
// convert to or from u32 or any other distinct id; you must write Node_Id(i) or u32(id).
Node_Id :: distinct u32
NO_NODE :: Node_Id(max(u32))

INode :: struct {
	key:   u32,
	left:  Node_Id,
	right: Node_Id,
}
#assert(size_of(Node_Id) == 4)
#assert(size_of(INode) == 12 && align_of(INode) == 4)

Tree :: struct {
	nodes: [dynamic]INode,
	root:  Node_Id,
}

tree_insert :: proc(t: ^Tree, key: u32) -> u64 {
	id := Node_Id(len(t.nodes))
	append(&t.nodes, INode{key, NO_NODE, NO_NODE})
	if t.root == NO_NODE {
		t.root = id
		return 0
	}
	at := t.root
	for depth: u64 = 1;; depth += 1 {
		n := &t.nodes[at]
		link := key < n.key ? &n.left : &n.right
		if link^ == NO_NODE {
			link^ = id
			return depth
		}
		at = link^
	}
}

tree_walk :: proc(t: ^Tree, id: Node_Id, h0: u64) -> u64 {
	if id == NO_NODE {
		return h0
	}
	n := t.nodes[id]
	h := tree_walk(t, n.left, h0)
	h = h * 31 + u64(n.key)
	return tree_walk(t, n.right, h)
}

// Indices are positions, not addresses, so we can move every node and fix the links:
// copy the tree in pre-order (a node, then its left subtree, then its right subtree).
tree_relayout_preorder :: proc(t: ^Tree) -> (out: Tree) {
	out.nodes = make([dynamic]INode, 0, len(t.nodes))
	out.root = copy_preorder(t, t.root, &out)
	return
}

copy_preorder :: proc(t: ^Tree, id: Node_Id, out: ^Tree) -> Node_Id {
	if id == NO_NODE {
		return NO_NODE
	}
	n := t.nodes[id]
	me := Node_Id(len(out.nodes))
	append(&out.nodes, INode{n.key, NO_NODE, NO_NODE})
	l := copy_preorder(t, n.left, out)
	r := copy_preorder(t, n.right, out)
	out.nodes[me].left, out.nodes[me].right = l, r
	return me
}

// ---- benchmark bodies: one ctx each, so bench_runs can call f(ctx) ----
walk_ptr :: proc(root: ^PNode) -> u64 {return ptr_walk(root, 0)}
walk_idx :: proc(t: ^Tree) -> u64 {return tree_walk(t, t.root, 0)}

build_ptr :: proc(keys: []u32) -> (depth_sum: u64) {
	root: ^PNode
	defer ptr_destroy(root) // freeing is part of the timing
	for k in keys {
		depth_sum += ptr_insert(&root, k)
	}
	return
}

build_idx :: proc(keys: []u32) -> (depth_sum: u64) {
	t := Tree{root = NO_NODE}
	defer delete(t.nodes)
	for k in keys {
		depth_sum += tree_insert(&t, k)
	}
	return
}

Lookup_Plain :: struct {
	values: []u64,
	order:  []u32,
}

lookup_plain :: proc(c: Lookup_Plain) -> (s: u64) {
	for j in c.order {
		s += c.values[j]
	}
	return
}

Lookup_Pool :: struct {
	pool:   ^Pool(u64),
	picked: []Handle(u64),
}

lookup_pool :: proc(c: Lookup_Pool) -> (s: u64) {
	for h in c.picked {
		if v, ok := pool_get(c.pool, h); ok {
			s += v^
		}
	}
	return
}

Monster :: struct {
	hp: int,
}

pool_demo :: proc() {
	pool := pool_make(Monster)
	defer pool_destroy(&pool)
	orc := pool_insert(&pool, Monster{10})
	elf := pool_insert(&pool, Monster{20})
	pool_remove(&pool, orc)
	goblin := pool_insert(&pool, Monster{30}) // reuses slot 0, generation 2
	fmt.printfln("pool: orc=%dv%d elf=%dv%d goblin=%dv%d (goblin reused orc's slot)", orc.index, orc.gen, elf.index, elf.gen, goblin.index, goblin.gen)
	_, orc_ok := pool_get(&pool, orc)
	fmt.printfln("pool: get(orc) ok = %v  <- stale handle detected", orc_ok)
	fmt.printfln("pool: get(goblin).hp = %d", pool_get(&pool, goblin).hp)
	assert(!orc_ok && goblin.index == orc.index && goblin.gen == orc.gen + 1)
	fmt.printfln("pool: size_of(Handle) = %d B, live = %d, slots = %d", size_of(Handle(Monster)), pool.len, len(pool.slots))
}

// The same story with core:container/handle_map. The item must carry its own handle.
Entity :: struct {
	handle: hm.Handle64, // {idx: u32, gen: u32}
	hp:     int,
}

handle_map_demo :: proc() {
	ents: hm.Dynamic_Handle_Map(Entity, hm.Handle64)
	hm.dynamic_init(&ents, context.allocator)
	defer hm.dynamic_destroy(&ents)
	orc := hm.add(&ents, Entity{hp = 10})
	elf := hm.add(&ents, Entity{hp = 20})
	hm.remove(&ents, orc)
	goblin := hm.add(&ents, Entity{hp = 30}) // reuses orc's slot with gen + 1
	fmt.printfln("handle_map: orc=%v goblin=%v valid(orc)=%v valid(goblin)=%v len=%d", orc, goblin, hm.is_valid(&ents, orc), hm.is_valid(&ents, goblin), hm.len(ents))
	if e, ok := hm.get(&ents, elf); ok {
		e.hp -= 5
	}
	assert(!hm.is_valid(&ents, orc) && goblin.idx == orc.idx && goblin.gen == orc.gen + 1)
	assert(orc.idx == 1) // index 0 is a reserved "no handle" sentinel
}

main :: proc() {
	args := parse_args()
	n := args.n
	pool_demo()
	handle_map_demo()

	// ---- build both trees from the same keys ----
	keys := make([]u32, n)
	defer delete(keys)
	rng := Rng{42}
	for &k in keys {
		k = u32(rng_next(&rng) >> 32)
	}

	proot: ^PNode
	defer ptr_destroy(proot)
	itree := Tree{root = NO_NODE}
	defer delete(itree.nodes)
	pdepth, idepth: u64
	for k in keys {
		pdepth += ptr_insert(&proot, k)
	}
	for k in keys {
		idepth += tree_insert(&itree, k)
	}
	dtree := tree_relayout_preorder(&itree)
	defer delete(dtree.nodes)
	assert(pdepth == idepth, "both trees must have the same shape")

	lo, hi: uintptr = max(uintptr), 0
	ptr_span(proot, &lo, &hi)
	nf := f64(n)
	span_per_node := f64(hi - lo) / nf
	cap_per_node := f64(cap(itree.nodes) * size_of(INode)) / nf
	fmt.printfln(
		"tree: n=%d average depth %.1f; pointer node %d B (heap span %.1f B/node), index node %d B ([dynamic] capacity %.1f B/node)",
		n,
		f64(pdepth) / nf,
		size_of(PNode),
		span_per_node,
		size_of(INode),
		cap_per_node,
	)
	emit_memory("pointers: node size", n, f64(size_of(PNode)))
	emit_memory("pointers: heap span", n, span_per_node)
	emit_memory("indices: node size", n, f64(size_of(INode)))
	emit_memory("indices: array capacity", n, cap_per_node)

	// ---- traversal: the same in-order walk, three memory layouts ----
	p := bench_runs(walk_ptr, proot)
	i := bench_runs(walk_idx, &itree)
	d := bench_runs(walk_idx, &dtree)
	hp, hi_, hd := ptr_walk(proot, 0), tree_walk(&itree, itree.root, 0), tree_walk(&dtree, dtree.root, 0)
	fmt.printfln("traverse checksum: pointers %#16x  indices %#16x  indices/DFS %#16x", hp, hi_, hd)
	assert(hp == hi_ && hi_ == hd, "checksums differ")
	Labeled :: struct {
		label: string,
		runs:  [RUNS]time.Duration,
	}
	for &w in ([]Labeled{{"pointer nodes", p}, {"u32 indices", i}, {"u32 indices, DFS order", d}}) {
		med := w.runs[RUNS / 2]
		fmt.printfln("traverse %-24s %10d ns  (%.2f ns/node)", w.label, i64(med), f64(i64(med)) / nf)
		emit_bench("ch05-traverse", w.label, n, w.runs[:])
	}

	// ---- build + free: n allocations vs one growing [dynamic] array ----
	pb := bench_runs(build_ptr, keys)
	ib := bench_runs(build_idx, keys)
	fmt.printfln("build+free checksum (sum of depths): pointers %d  indices %d", pdepth, idepth)
	for &b in ([]Labeled{{"pointer nodes", pb}, {"u32 indices", ib}}) {
		fmt.printfln("build+free %-22s %10d ns", b.label, i64(b.runs[RUNS / 2]))
		emit_bench("ch05-build", b.label, n, b.runs[:])
	}

	// ---- what does the generation check cost? n random lookups ----
	pool := pool_make(u64)
	defer pool_destroy(&pool)
	plain := make([]u64, n)
	defer delete(plain)
	handles := make([]Handle(u64), n)
	defer delete(handles)
	for j in 0 ..< n {
		plain[j] = u64(j)
		handles[j] = pool_insert(&pool, u64(j))
	}
	order := make([]u32, n)
	defer delete(order)
	picked := make([]Handle(u64), n)
	defer delete(picked)
	r2 := Rng{7}
	for j in 0 ..< n {
		order[j] = u32(rng_next(&r2) % u64(n))
		picked[j] = handles[order[j]]
	}
	lctx := Lookup_Plain{plain, order}
	pctx := Lookup_Pool{&pool, picked}
	lv := bench_runs(lookup_plain, lctx)
	lp := bench_runs(lookup_pool, pctx)
	cv, cp := lookup_plain(lctx), lookup_pool(pctx)
	fmt.printfln("lookup checksum: plain %d  pool %d", cv, cp)
	assert(cv == cp, "checksums differ")
	for &l in ([]Labeled{{"array[index]", lv}, {"pool.get(handle)", lp}}) {
		med := l.runs[RUNS / 2]
		fmt.printfln("lookup %-22s %10d ns  (%.2f ns/lookup)", l.label, i64(med), f64(i64(med)) / nf)
		emit_bench("ch05-lookup", l.label, n, l.runs[:])
	}
}
