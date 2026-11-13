# Research slice 05 — The Techniques Catalog (language-agnostic)

Status: written incrementally. Each technique uses the same template:
**What** / **Why it works (hardware)** / **When NOT to use** / **Canonical example** / **Visualization** / **Best sources**.
Source tags like [S3] refer to the SOURCES section at the end. "(opened)" = I read the page; "(search)" = seen only in search results.

Hardware numbers assumed throughout (see slice 01 for citations): 64-byte cache lines on x86 and most ARM (Apple M-series L2 uses 128-byte lines); L1 hit about 4 cycles, DRAM about 60–100 ns (hundreds of cycles); the hardware prefetcher detects sequential and constant-stride streams; branch mispredict costs about 15–20 cycles.

---

## T1. AoS vs SoA vs AoSoA (hybrid / tiled layouts)

**What.**
- *AoS* (array of structs): `[ {x,y,z,vx,vy,vz,mass,alive}, ... ]`. A record's fields sit together.
- *SoA* (struct of arrays): `{ x:[...], y:[...], ..., alive:[...] }`. Each field is its own contiguous array.
- *AoSoA* (tiled/hybrid): an array of fixed-width blocks, each block an SoA of N elements (N = SIMD width or a cache-line multiple, e.g. 8 or 16): `[ {x[8], y[8], z[8], ...}, ... ]`. ISPC calls this the "hybrid SoA" layout; Intel's SIMD Data Layout Templates (SDLT) supports it directly.

**Why it works (hardware).**
- The cache moves whole 64-byte lines. If a loop reads 2 of 8 fields, AoS wastes the rest of every line. SoA brings in only the bytes the loop needs, so effective bandwidth goes up by (record size / bytes touched).
- SoA streams are sequential with unit stride, which is ideal for the prefetcher and for SIMD loads: `x[i..i+8]` is one vector load, with no gathers or shuffles.
- SoA removes per-record padding (see T3). Zig's `MultiArrayList` docs say this directly: "memory savings if the struct or union has padding, and also improves cache usage if only some fields ... are needed" [S2].
- AoSoA keeps SoA's vector-friendliness but makes every field of element *i* sit within one small block, often within one or two pages. So random access to "all fields of entity i" touches about K nearby lines instead of K far-apart arrays. It also uses fewer simultaneous streams (each stream needs a prefetcher slot and TLB entries), and blocks can be allocated independently.

**When NOT to use.**
- When code accesses *all* fields of *one* record at random (e.g. lookup by key, then read everything). AoS gives one cache line; SoA gives K lines, one per field array.
- Many fields (dozens) in a loop that touches all of them: too many concurrent streams can thrash the prefetcher or TLB, or cause 4K-aliasing. Use AoSoA or group fields that are used together ("hot/cold", T2).
- Small N (e.g. < ~1000 elements that fit in L1/L2 anyway). The win shrinks and the code gets uglier.
- Insert or delete in the middle is K memmoves instead of one.
- AoSoA makes indexing awkward (`block = i / N; lane = i % N`) and needs tail handling. Use it only when profiling shows both a SIMD win and a random-access need.

**Canonical example.** Particle update `pos += vel * dt` over 1M–10M particles, where each particle also carries cold fields (color, lifetime, id, name pointer). AoS of 64-byte particles vs SoA (`px,py,pz,vx,vy,vz` as f32 arrays). Expect 2–5× on the scalar loop, more once SIMD kicks in. AoSoA variant: `struct Block { float px[8],py[8],pz[8],vx[8],vy[8],vz[8]; }`.

**Visualization.** Draw three memory strips of 64-byte cache lines, colour-coding the bytes the loop actually reads. AoS: confetti (low useful fraction). SoA: solid colour. AoSoA: striped blocks. Add a "useful bytes per line fetched" bar next to each.

**Best sources.** Kelley, *Practical DOD* (MultiArrayList) [S1]; Zig `multi_array_list.zig` [S2]; Intel, "Memory Layout Transformations" (AoS → SoA → AoSoA) [S20]; ISPC User Guide on hybrid SoA [S21]; Fabian ch. "Relational databases"/"Hierarchical level of detail" [S4]; Barry Revzin, *Implementing a Struct of Arrays* (C++26 reflection) [S8].

---

## T2. Hot/cold splitting

**What.** Divide a record by *access frequency*. Fields read every frame or loop ("hot") go in one dense array. Rarely used fields ("cold": debug name, creation time, editor metadata, error text) go in a parallel array or a side table keyed by the same index. It is a coarse-grained SoA: split by use, not by field.

**Why it works.** The hot array shrinks, so more elements fit per cache line, per L1/L2, and per TLB page. The loop's working set may drop into a faster cache level, which gives step-function speedups when you cross the L2 → L3 or L3 → DRAM boundary. Cold data still exists but is fetched only on the rare path.

**When NOT to use.** When "cold" fields are actually read on the same path as hot ones: then you pay an extra miss per element. When the record is already ≤ 1 cache line and the whole struct is used. When access patterns change per phase (what's hot in phase A is cold in B). Then consider full SoA instead.

**Canonical example.** `Monster { hp, pos, vel, ai_state }` is hot. `{ name: String, spawn_time, loot_table_id, debug_color }` is cold, moved to `monster_cold[i]`. Benchmark: iterate hot fields with and without cold padding fields (e.g. a 200-byte `name` buffer inline).

**Visualization.** A struct drawn as a bar where each field's width = size and colour intensity = access frequency (from a profiler or counter). Then "cut" the bar into hot and cold parts and show how many hot records now fit in a 32 KiB L1 box.

**Best sources.** Kelley [S1] (store sparse/rare data out of band, in hash maps); Fabian ch. on hierarchical level of detail and existence [S4]; Chilimbi et al., "Cache-conscious structure definition" (PLDI 1999) on structure splitting [S22].

---

## T3. Struct padding and field ordering

**What.** Compilers align each field to its natural alignment and round the struct size up to a multiple of its largest alignment. For example, `{u8 a; u64 b; u8 c;}` is 24 bytes on x86-64 (1+7 pad+8+1+7 pad), while `{u64 b; u8 a; u8 c;}` is 16. Ordering fields from largest to smallest alignment minimises padding. Some languages reorder fields automatically: Rust's default `repr(Rust)` may reorder, `repr(C)` keeps declaration order; Zig's plain `struct` has no guaranteed layout and can reorder, `extern struct` uses C layout; Odin structs follow C-like order, and `#packed` removes padding. Taking fields out of the struct into separate arrays (SoA) removes the padding entirely.

**Why it works.** Padding is wasted bytes that still travel through every cache level and use bandwidth. A 24 → 16 byte struct means 1.5× more elements per line. Kelley's talk is largely a series of "compute `@sizeOf` in your head" exercises showing these wins. Booleans are the classic waste: 1 bit of information padded to 8 bytes, so he recommends "store booleans out-of-band", as a separate array or by existence (T7) [S1][S7].

**When NOT to use.** `#packed`/`packed` structs with misaligned fields can be slower: unaligned loads may cross cache lines, and some architectures trap or split them. Atomics must be naturally aligned. Do not reorder fields whose order is part of an ABI, file format or wire format. Do not reorder against deliberate grouping, e.g. fields kept on separate lines to avoid false sharing (T18), or hot fields kept together on the first line.

**Canonical example.** `{bool alive; f64 x; bool visible; f64 y; u8 team;}` takes 40 bytes; reordered it takes 24; as SoA plus an existence list for `alive` it takes 16 + bitset. Print `sizeof`/`@sizeOf`/`size_of` for each variant.

**Visualization.** Byte grid (8 columns = one 8-byte word) with fields as coloured blocks and padding as hatched grey. Animate the reordering, then show the SoA version with no hatching. Andrew Kelley's slides use exactly this "guess the size" quiz format.

**Best sources.** Kelley talk [S1] and the community notes summary [S7]; Raymond Tana, *Memory Layout in Zig with Formulas* (2026) [S9]; Eric S. Raymond, *The Lost Art of Structure Packing* [S23].

---

## T4. Index-based references instead of pointers

**What.** Store a `u32` (or `u16`/`u8`) index into an array instead of a pointer to a heap object. Relationships become integers: `parent: u32`, `first_child: u32`, `token: u32`.

**Why it works.**
- *Size*: on 64-bit targets a pointer is 8 bytes; a `u32` index is 4, which "can effectively reduce the struct size ... by half" (Kelley) [S1][S5]. Smaller structs mean more per cache line. 32-bit arithmetic is as fast as 64-bit on x86-64/AArch64 (Kelley Q&A, via [S7]).
- *Locality*: indexed objects live in one contiguous array, often in creation order, instead of scattered across the heap.
- *Allocator cost*: one growable array instead of N mallocs. Freeing is one free.
- *Relocatability*: the array can grow by realloc or be memcpy'd, serialized to disk, or sent to another process or GPU unchanged, because indices are position-independent. Pointers into a growing vector become dangling on realloc; indices do not.
- *Borrow-checker friendliness* in Rust (Catherine West's keynote [S10]).

**When NOT to use.** More than 2^32 elements. Hot paths where the extra base + index add matters (rare; it is usually one fused addressing mode). When objects must be shared across many unrelated containers (a pointer is self-describing; an index needs to know which array it belongs to). Use typed index wrappers (`enum(u32)` in Zig, distinct types in Odin, newtypes in Rust) so a node index can't be passed as a token index. Indices don't solve use-after-free by themselves; see T5.

**Canonical example.** A binary tree or AST: `Node { tag: u8, lhs: u32, rhs: u32 }` = 12 bytes (or 9 packed / SoA) vs `Node { tag, *Node, *Node }` = 24 bytes. Benchmark: build 10M-node tree, sum via traversal, compare RSS and time.

**Visualization.** Two diagrams of the same tree: pointer version with arrows jumping all over a "heap" strip; index version as a table with integer columns and short arrows inside one strip. Show bytes per node beneath.

**Best sources.** Kelley [S1][S5]; Mitchell Hashimoto, *Zig Parser* (token and node indices) [S6]; Catherine West, RustConf 2018 keynote [S10]; floooh, *Handles are the better pointers* [S11].

---

## T5. Generational indices, handles and slot maps

**What.** A *handle* is an index plus a *generation* counter (e.g. 32-bit index + 32-bit generation packed in a u64, or 20 + 12 bits in a u32). The container keeps a generation per slot. On delete it bumps the slot's generation and pushes the slot onto a free list. On lookup it checks `slot.gen == handle.gen`; a stale handle gets "not found" instead of someone else's data. This solves the ABA problem.
- *Slot map* (Rust `slotmap` crate [S12], "stable vector", "slab") is the container that issues and checks these keys, with O(1) insert, remove and access. Variants: plain (values stored in slots, holes on iteration); *dense* slot map (values packed in a dense array, slots hold indirection, so iteration is contiguous); *hop* slot map (skip runs of holes when iterating). Secondary maps attach extra per-key data "without hashing — it's direct indexing under the hood" [S12].
- floooh's rules [S11]: keep items of a type in arrays owned by one system; give outsiders only handles; use spare handle bits for safety checks; convert handle → pointer only briefly and never store the pointer. He later added per-slot generation counters [S11].

**Why it works.** Same size and locality benefits as T4, plus memory safety (detecting dangling references) without reference counting and its scattered refcount writes, and without a GC. Lookup is an array index plus one compare, usually on a line that's already hot.

**When NOT to use.** When lifetimes are strictly nested or scoped (use an arena, T15, and plain indices or pointers). When every access is a hot inner-loop deref: then the extra check and indirection cost something, so iterate the dense array directly. When the generation counter can wrap within the lifetime of a stale handle. Retire the slot when the counter saturates, as floooh does, or use more bits.

**Canonical example.** Entity manager: `spawn() -> Handle`, `despawn(h)`, `get(h) -> ?*T`. Demo: despawn an entity, spawn a new one into the same slot, show the old handle returns null.

**Visualization.** Slot array with `[gen | value | next_free]` per slot; a handle drawn as `(index=3, gen=2)` with an arrow; animate a delete (gen 2→3, slot joins free list) and the stale handle failing its comparison.

**Best sources.** floooh 2018 [S11]; Catherine West RustConf 2018 [S10]; `slotmap` docs [S12]; root-11 *Intro to ECS & EBP in Rust* §10 [S13] (search).

---

## T6. Sparse sets

**What.** Two arrays: `dense` (the packed list of member ids, optionally with a parallel packed `values` array) and `sparse` (indexed by id, stores the position in `dense`). Membership test is `dense[sparse[id]] == id` (the original Briggs–Torczon trick even tolerates uninitialised `sparse` memory). Insert: `sparse[id] = dense.len; dense.push(id)`. Remove: swap-with-last and pop, fixing the moved element's `sparse` entry. All operations are O(1), and iteration is O(n) over dense memory, independent of the id universe size, and clear() is O(1) [S14][S15].
- EnTT uses one sparse set per component type, with *paged* sparse arrays so huge ids don't need huge allocations, and can sort a pool's dense array in another pool's order so multi-component iteration lines up [S14][S16].

**Why it works.** Iteration never visits holes, so the loop is a sequential scan. Random lookup is two dependent loads (sparse, then dense or value). Add and remove are cheap, unlike archetype moves. Paging the sparse array means memory follows the ids actually in use.

**When NOT to use.** When the id universe is small and dense (just use a plain array plus a bitset). When stable addresses or iteration order matter (swap-remove reorders). For multi-component joins over many components: each extra component is a random lookup per entity, so archetypes (T16) iterate faster. When memory for `sparse` (universe-sized, even paged) is unacceptable, use a hash map.

**Canonical example.** "Set of entity ids currently on fire": insert, remove, iterate each frame. Compare with `HashSet<u32>` and with `Vec<bool>` scanning for iteration speed and add/remove cost.

**Visualization.** The classic two-row diagram: sparse array above with arrows down into a packed dense array; animate swap-remove (last element moves into the hole, one arrow re-pointed). skypjack's posts have good diagrams to emulate [S14].

**Best sources.** skypjack, *ECS back and forth* parts 2, 2-insights, 5, 9 [S14][S16]; Sander Mertens, *Building an ECS #3: Storage in Pictures* (paged sparse sets, entity index) [S17]; Briggs & Torczon 1993 [S18] (search; not opened); ECS FAQ [S19].

---

## T7. Existence-based processing (Fabian: "existential processing")

**What.** Encode state by *which table a row is in* rather than by a flag or enum field inside the row. Instead of `if (e.isHurt && !e.isDead) regen(e)` over every entity, keep an `entityHealth` table that has a row **only** for hurt entities, and a `deadEntities` table. Then run `regen` over every row of `entityHealth`, with no condition. Fabian: "an entity has an implicit boolean hidden in the row existing in the table" [S4]. He generalises it to enums: "Any enum can be emulated with a variety of tables. All you need is one table per enumerable value. Setting the enumeration is an insert into a table or a migration from one table to another" [S4]. It also replaces virtual dispatch: "Instead of a polymorphic method call, we utilise existential processing", and the entity's "class" is the set of tables it belongs to, which can change at runtime [S4]. Fabian classifies the transforms as *mutation* (in == out), *filter* (in ≥ out), *emission* (out ≥ 0) and *generation* (no input) [S4]. Kelley's version: keep alive monsters and dead monsters in two arrays, so the `alive` bool disappears and the loop no longer loads it. That takes the struct from 24 → 16 bytes (12 with indices) [S1].

**Why it works.**
- No per-element branch, so no mispredicts on data-dependent flags that are hard to predict (e.g. 50/50 alive/dead in random order).
- The loop only touches rows it will actually process. The skipped entities never cost a cache line, whereas reading a flag to decide to skip costs a full line load (Kelley: "you were doing a memory load to see if they were alive. That could evict a cache line" [S1]).
- The loop body is homogeneous, so it is easy to vectorise and trivially parallel ("When there is no global state, no accumulator, it is proven to be parallelisable" [S4]).
- Work becomes visible: the table length *is* the to-do list, so you can budget or schedule it.

**When NOT to use.**
- State flips every frame for most rows: the cost of moving rows (copy + swap-remove + fixing up indices/handles) can exceed the branch you removed.
- "What state is entity X in?" becomes a search across several tables. Fabian concedes "finding out the value of an enum in an entity is difficult" [S4]. If that query is hot, keep a reverse map or the enum too.
- Ordering matters (moves reorder rows).
- The branch is already well-predicted (e.g. 99.9% of rows take one side) and the flag sits on a line you load anyway.

**Canonical example.** Fabian's health regen: `Entity{health, maxHealth, timeOfLastDamage, isDead}` vs tables `EntityDamaged{id, health, lastHit}`, `Dead{id}`. Regen loops over `EntityDamaged` only; a row leaves when health reaches max. Optional refinement from the book: keep pending-regen rows sorted by time and pop the ready ones into an active list [S4].

**Visualization.** Left: one long table with a `state` column and a cursor that stops at every row and "asks". Right: three short tables (Healthy / Hurt / Dead) with the cursor gliding through only "Hurt". Animate an entity taking damage as a row *moving* between tables.

**Best sources.** Fabian, *Data-Oriented Design*, ch. "Existential Processing" (online) [S4]; Kelley talk ("store booleans out of band") [S1][S5]; Mark Hansen's book notes [S24].

---

## T8. Tagged-union encoding with a separate payload array and "extra" arrays (Zig compiler style)

**What.** Represent a heterogeneous node or instruction set as SoA columns of *fixed* small size:
- `tags: []u8`, an enum of *encodings* (not just kinds);
- `data: []{lhs: u32, rhs: u32}` (8 bytes), plus often `main_token: []u32`;
- `extra_data: []u32`, a shared side array; variants that need more than 8 bytes store an index into it, and the tag determines how many u32s to read and how to interpret them;
- a string table (one byte buffer; strings referenced by offset).

Mitchell Hashimoto's walk through the Zig parser: `Node = {tag, main_token: TokenIndex, data: {lhs, rhs}}`, stored as `MultiArrayList(Node)`. For `fn_proto`, `lhs` is "an index into the `extra_data` field ... the starting index", and the tag says six u32 fields follow (`params_start, params_end, align_expr, addrspace_expr, section_expr, callconv_expr`); "**lhs/rhs may point to either nodes or extra data**" [S6]. Putting the extra data on the Node instead "makes the overall parser slower since it forces each Node to be much larger" [S6]. `addExtra(struct)` serialises a typed struct into `extra_data`; `extraData(idx, T)` reads it back [S6].

The key move is **multiple encodings per kind, chosen from the observed distribution**. Kelley: "A variable declaration is encoded in three different ways. An 'if' is encoded in two different ways"; booleans such as `strong/weak` or `has_braces` are folded into the tag instead of stored [S1]. In his Monster example, `Bee`, `HumanNaked`, `HumanClothed` and `HumanBracesClothed` are separate tags: common data stays fixed-size, and clothed humans put their clothing struct in `extra`. The average falls from 32 to 17 bytes per monster [S1][S5].

Reported results (Kelley, Handmade Seattle 2021, via transcript [S5]): tokens and AST nodes shrank (AST "from 120 bytes to 15.6 bytes on average"), giving a **22% wall-clock** parse improvement. ZIR instructions went "54.0 bytes ... to 20.3", giving a further **39% wall-clock** reduction. Parsing plus AstGen reached about 8.9M lines/s on his laptop. The output is "only four arrays: a tag, common data, an extra array, and a string table", which can be written to disk with `writev` and read back with `readv` [S5]. The Zig std lib generalises the tag/payload split in `MultiArrayList` for tagged unions: "split into two arrays: one for active tags and one for bare unions" [S2][S25].

**Why it works.** A naive tagged union is sized for its *largest* variant plus the tag plus padding, so every small node pays for the biggest one. Splitting the tag out (1 byte, dense, so 64 tags per cache line) and capping the payload at 8 bytes makes the common case small and fixed-stride, so it can be indexed without per-node pointers. Rare large variants pay their own way in `extra`. Passes that only need tags (e.g. counting, or finding all `fn_decl`) stream just the 1-byte array. Everything is u32 indices into a few arrays, so building the tree is a handful of amortised appends instead of thousands of mallocs, and freeing it is 4 frees.

**When NOT to use.** Mutation-heavy structures: `extra` is append-only in practice, and editing a node in place when its encoding changes leaves garbage or needs compaction. Safety: the meaning of `lhs/rhs` depends on the tag, so a wrong read is silent. Mitigate with typed accessors (`extraData(idx, T)`) and debug-mode checks. Readability and onboarding cost is real ("The only way you'd know this is reading the comments above the tag" [S6]). Don't do it for small collections, or for data that is not a bottleneck.

**Canonical example.** An expression AST for a calculator: `tags: []u8 {int_small, int_big, add, call_one, call_many}`, `data: [](u32,u32)`. `int_small` stores the value in `lhs`; `int_big` points `lhs` into `extra` (two u32s); `call_one` = callee + one arg inline; `call_many` = `lhs` → `extra[start..start+n]`. Measure bytes/node and parse+eval time against a `Box<enum>` / pointer-tree version.

**Visualization.** Four horizontal tapes (tags, main_token, data, extra) with a highlighted node; arrows from `data.lhs` into either the node tape or the extra tape, coloured by tag. Next to them, a histogram "bytes per node: pointer tree vs union-sized array vs encoding", using Kelley's 120 → 15.6 numbers.

**Best sources.** Kelley talk [S1] + transcript [S5]; Mitchell Hashimoto, *Zig Parser* [S6]; Zig `MultiArrayList` source [S2]; Zig issue #14496 (MultiArrayList for tagged unions) [S25]; hisham.hm commentary [S26].

---

## T9. Encoding and compression: bit packing, delta encoding, quantization

**What.** Store values in the *fewest bits that the observed data range needs*, and decode on the fly.
- *Narrow types*: `u8/u16/f16` instead of `u64/f64` when the range allows. Kelley: "Each level of memory is an order of magnitude slower ... CPUs are fast, but memory is slow. Calculate instead of store" [S7].
- *Bit packing*: N values of b bits each packed into words. Lemire & Boytsov's SIMD-BP128 packs blocks of 128 integers at the bit width of the largest one, in a "vertical" layout across SIMD lanes, and decodes about 2.3 billion ints/s (≈1.5 cycles/int, Core i7, SSE2) [S27].
- *Delta / differential coding*: store `x[i] - x[i-1]` (good for sorted ids, timestamps, positions along a path), then bit-pack the small deltas. Decoding is a prefix sum, which can be vectorised. Lemire uses deltas of distance 4 (`x[i] - x[i-4]`) so 4 SIMD lanes decode at once, which is "much faster" but makes deltas about 4× larger (≈+2 bits each) [S27]. *Zigzag* encoding maps signed deltas to small unsigned values (zeux) [S29]. *Frame-of-reference (FOR)* stores `value - block_min`.
- *Quantization*: map floats to normalised integers over a known range: positions to 16-bit relative to a bounding box or cluster anchor, normals to 3×8-bit or octahedral 2×8/2×16, UVs to unorm16. meshoptimizer: "it's common to quantize normals using 3 8-bit integers", and "it can be valuable to use bit counts that are not multiples of 8" [S28].
- *Fold flags into existing bits*: tag bits in low bits of aligned indices, an enum folded into the encoding tag (T8), NaN-boxing.

**Why it works.** In memory-bound loops the cost is bytes moved, not ALU ops. A 4× smaller column is 4× less DRAM traffic and 4× more per cache line, and decode ALU work (shifts, masks, adds) is almost free next to a cache miss. Smaller data also stays in a faster cache level. GPUs fetch vertex attributes as bandwidth, so quantized vertices draw faster.

**When NOT to use.** Compute-bound loops (decode then costs real time). Random access into variable-width encodings: delta and varint streams must be decoded from a block start, so keep block boundaries/skip indices. Data written frequently (re-encoding a block on every write). Precision-sensitive maths (physics integration in 16-bit fixed point will drift). Quantize *storage*, and compute in full precision.

**Canonical example.** Store 10M sorted u64 timestamps three ways: raw (80 MB), delta + u16 (20 MB) and delta + bit-packed (often < 10 MB). Benchmark "sum all values" and "count values in range". Second example: a particle position `f32×3` (12 B) vs `u16×3` relative to a grid cell (6 B).

**Visualization.** A "bit ruler": one row per value showing the 64 bits of a u64 with only the low 9 bits coloured. Then pack those 9-bit runs end to end. For delta encoding, a line chart of raw values (large and climbing) above a bar chart of the deltas (tiny).

**Best sources.** Lemire & Boytsov, *Decoding billions of integers per second through vectorization* (SPE 2015) [S27]; meshoptimizer README (vertex quantization) [S28]; zeux, *Zigzag decoding with AVX-512* (2026) [S29] (search); Kelley talk [S1].

---

## T10. Batch processing: "where there's one, there's many"

**What.** Design every function's API around a *collection* (`update_all(positions[], velocities[], n)`) rather than one object (`particle.update()`). Mike Acton, final *Inner Product* column: "**Where there is one, there are many.** That's more true today than it's ever been. And it's always been true" [S30]. He criticises designs where "dozens or even hundreds of routines are assigned to individual 'objects' which all 'act' independently and conspire to sabotage performance, maintainability, testability and good sense" [S30]. Fabian's transforms (mutation/filter/emission) are batch operations over tables [S4].

**Why it works.**
- *Amortisation*: function-call overhead, virtual dispatch, setup (loading constants, matrices, locks) and branch-predictor warm-up are paid once per batch, not per item.
- *I-cache*: one tight loop stays hot instead of jumping between N different `update()` bodies. (HN comment on Casey's article: Acton showed "merely reordering objects by types, *while keeping those virtual calls*, can help the instruction cache" [S32].)
- *Compiler visibility*: a loop over arrays can be vectorised, unrolled and given multiple accumulators. A per-object virtual call is opaque.
- *Parallelism*: a batch is the unit you can split across cores (T17).
- *Prefetch and MLP*: the CPU can have many outstanding loads in flight for independent iterations.

**When NOT to use.** Genuinely one-off operations (configuration, startup). Latency-critical single requests where waiting to fill a batch adds latency (choose a time-boxed batch size). Operations with strong per-item dependencies (each step needs the previous result), where batching gains little beyond the call overhead.

**Canonical example.** `fn update(p: &mut Particle)` called in a loop over `Vec<Box<dyn Entity>>` vs `fn integrate(px, py, vx, vy: &mut [f32], dt)`. Also batch API design: `transform_points(matrix, in: []Vec3, out: []Vec3)` instead of `transform_point(matrix, p)`.

**Visualization.** A timeline per item: [call][setup][work][return] repeated N times vs [setup] + [work work work ...]. Make the overhead bars red so the shrinkage is visible.

**Best sources.** Acton, *Last Inner Product* (Game Developer, 2014) [S30]; Acton CppCon 2014 (see slice 01); Fabian ch. Existential Processing [S4].

---

## T11. Sorting or bucketing by type to remove branches

**What.** Instead of one mixed array iterated with `switch(type)` or a virtual call per element, keep **one array per type** (or sort the mixed array by type once) and run one specialised loop per bucket. Casey Muratori in the comments of his response post: "if you have n different types, you keep them in n different arrays, and that way you don't have to use any dynamic dispatch - you just do n different loops, one over each array" [S33]. This is the same idea as Fabian's "one table per enum value" (T7) and as archetypes (T16).

**Why it works.**
- In a mixed, unordered stream the type branch (or indirect call target) is unpredictable, costing ≈15–20 cycles per mispredict. Within a bucket it is perfectly predictable, or gone.
- Each loop body is specialised (constants folded, no dispatch) and vectorisable.
- The data per type can be its exact size (no union padded to its largest variant).
- Classic demonstration: Stack Overflow's most famous question. Sorting the data before a loop containing `if (data[c] >= 128)` made it ≈6× faster (11.5 s → 1.9 s in one reported run), purely from branch prediction [S34][S35]. Algorithmica measures ≈14 cycles/element for a 50% unpredictable branch vs a bit over 4 once sorted [S36].
- Muratori's shapes benchmark: virtual-call loop ≈35 cycles/shape; switch on a type enum ≈24 cycles (1.5×); a table-driven version (`CTable[type] * w * h`) ≈3.0–3.5 cycles (≈10×); with a second property ≈15×; a lightly AVX-optimised version 20–25× [S31].

**When NOT to use.** When *processing order* across types is semantically required (e.g. draw order, event order). Then sort a lightweight key or index array, or accept the branch. When there are many types with few items each (the per-loop overhead dominates; a jump table may be fine). When types change constantly (bucket migration cost, as in T7). Don't sort *every frame* just to help the predictor: sorting costs O(n log n) and usually exceeds the branch cost (greyblake: "sorting the input is not a fix: sorting costs much more than the filtering itself" [S37]). Instead, keep data bucketed as it is produced.

**Canonical example.** Muratori's shapes: `square/rect/triangle/circle` with `Area()`. Four versions: `Vec<Box<dyn Shape>>`, `enum + match` mixed, `enum` sorted by type, four separate arrays. Report cycles/shape.

**Visualization.** A strip of coloured squares (one colour per type) in random order with a branch-predictor "guess" row underneath (✓/✗); then the same strip sorted into colour runs with almost all ✓. Plus Casey's bar chart of cycles per shape (35 / 24 / 3.5).

**Best sources.** Muratori, *"Clean" Code, Horrible Performance* (2023) [S31] and follow-up [S33]; Stack Overflow "sorted array" Q&A [S34][S35]; Algorithmica, *The Cost of Branching* [S36]; Fabian [S4].

---

## T12. Branchless code

**What.** Replace data-dependent control flow with data flow: arithmetic on comparison results, conditional moves (`cmov`/`csel`), min/max, masks, or lookup tables. Typical patterns:
- *Predication*: `s += (a[i] < 50) * a[i]` or a mask `& -(cond)`. Algorithmica's version `((a[i] - 50) >> 31 - 1) & a[i]` avoids the 3-cycle `imul` [S38].
- *Unconditional write + conditional advance* (stream compaction / filter): `out[n] = x; n += (x > t);`. greyblake reports a filter about 4× faster this way on shuffled input [S37].
- *Table lookup* instead of a switch (Muratori's `CTable`) [S31].
- *Branchless binary search*: Algorithmica's version is "~4x faster than the branchy std::lower_bound" on cache-resident arrays [S38].
- SIMD is branchless by nature: compute both sides and blend with a mask.

**Why it works.** A mispredicted branch flushes the pipeline (Algorithmica: Zen 2's pipeline is 19 stages deep; a 50/50 random branch costs ≈14 cycles/element vs ≈4 when predictable) [S36]. Branchless code turns a *control* dependency, which has to be guessed, into a *data* dependency, which only stalls for the operand latency: "you only need to wait for cmov to be resolved and not flush the entire pipeline" [S38]. It also enables vectorisation; compilers' "if-conversion" is a prerequisite for SIMD (Stack Overflow answer) [S35].

**When NOT to use.** When the branch is predictable. Algorithmica: "branchy code wins when the branch can be predicted with a probability of more than ~75%" (also a common compiler cmov heuristic) [S38]. Stack Overflow data: branchless was 2.7 s on both random and sorted input, while branchy sorted was 1.8 s, so branchless "suffer[s] a little bit when it is predictable" [S35]. When one side is expensive or has side effects (you'd compute it always). When the branch skips a memory load that would miss: a correctly predicted branch lets the CPU speculate past it, while cmov makes the dependent chain wait. Always check the generated assembly: compilers sometimes turn your branchless trick back into a branch, or the other way round.

**Canonical example.** Algorithmica's "sum elements < 50" over random 0..99 data: branchy vs predicated, across P = 0..100% (the classic U-shaped curve peaking near 50%) [S36]. Second: filter/compaction branchy vs branchless.

**Visualization.** Plot cycles/element against branch probability P for branchy (U-shaped, peaking at 50%) and branchless (a flat line). The crossover at ≈25% / 75% is the "when NOT" rule, drawn.

**Best sources.** Algorithmica, *Branchless Programming* and *The Cost of Branching* [S38][S36]; Stack Overflow sorted-array Q&A [S34][S35]; greyblake, *Branchless Rust* [S37]; BlockQuicksort (Edelkamp & Weiß, ESA 2016) for branchless partitioning [S39] (search).

---

## T13. SIMD-friendly layouts

**What.** Lay data out so that a SIMD register (4×f32 SSE/NEON, 8×f32 AVX2, 16×f32 AVX-512) is filled by **one contiguous aligned load of the same field across W elements**. That means SoA or AoSoA with block width W (T1). Supporting rules: align arrays to 32/64 bytes; pad lengths to a multiple of W (or use a masked tail); avoid gathers and scatters; avoid mixed types in a lane; keep values the same width (f32 with i32, not with i64); replace branches with masks (T12).

The classic AoS mistake (Intel's ISPC article): putting a triangle's three `xyz` vertices into SSE registers left lane 3 duplicating lane 0. Transposing to SoA ("vertex components from each triangle are transposed into unique arrays") lets four triangles be processed at once with every lane useful [S40]. ISPC's perf guide: AoS `pts[programIndex].x` needs "a 'gather' ... with a corresponding decrease in performance", while the `soa<8>` qualifier turns the type into hybrid SoA and does the two-stage `[i/8].x[i%8]` indexing automatically [S21][S41]. Intel's GDC slides: "Prefer SoA, or AoSoA memory layouts, these will generate vector loads/stores", and "transposing the data costs much less than the cost of gather and scatter instructions" [S42].

**Why it works.** A unit-stride vector load is one instruction, one or two cache lines, full lane use. A gather is roughly one load per lane plus merge overhead (latency close to W scalar loads on many cores), and it defeats the contiguous prefetch pattern. Horizontal operations (shuffles, dot products within a register) are slow and serialise. Vertical operations across SoA lanes are cheap.

**When NOT to use.** Where the algorithm is inherently "horizontal" on small fixed vectors (one 4×4 matrix multiply, one quaternion): `Vec4` AoS in a register can be fine. Very irregular, pointer-chasing data (trees, graphs) where SIMD needs gathers anyway; consider a different algorithm first. Tiny N. Don't hand-write intrinsics before checking whether the compiler already auto-vectorises the SoA loop.

**Canonical example.** Ray-vs-many-spheres or sphere-vs-sphere tests: AoS `Sphere{x,y,z,r}` with a scalar loop vs SoA `cx[],cy[],cz[],r[]` with a W-wide loop that tests 8 spheres per iteration. Or the particle update from T1 with explicit `@Vector(8, f32)` (Zig), `#simd[8]f32` (Odin), `std::simd::f32x8` (Rust nightly) or auto-vectorisation.

**Visualization.** Register-lane diagram: four AoS triangles mapped into SSE registers with a wasted, duplicated lane (red), next to the SoA mapping with every lane green, as in Intel's figures 3–7 [S40]. Then gather (eight arrows from scattered addresses) vs vector load (one wide arrow).

**Best sources.** Intel, *SIMD Made Easy with Intel ISPC* [S40]; ISPC User Guide and Performance Guide [S21][S41]; Pharr & Mark, *ispc: A SPMD Compiler* (InPar 2012, hybrid SoA figure) [S43]; Intel, *Memory Layout Transformations* [S20]; Intel GDC slides *Simple SIMD with ISPC* [S42].

---

## T14. Columnar and relational thinking: tables and normalization (Fabian)

**What.** Model program state as a relational database in memory: each concept is a **table** (an array of rows, usually SoA), each row has a **primary key** (an integer id or index), relationships are foreign-key columns or link tables, and you **normalise**: each fact stored once, no repeating groups (1NF), no attributes that depend on only part of a key (2NF), no attributes that depend on other non-key attributes (3NF). Fabian walks a game-level setup script (rooms, doors, pickups, keys) from a nested object graph into normalised tables, and recommends stealing database ideas: "sets, indices, joins, join ordering, query optimisers" (Hansen's summary) [S3][S24]. Optional data becomes a separate table, so there are no NULL columns. Many-to-many relations become link tables. "Classes" become sets of table memberships (T7).

**Why it works.**
- Normalised tables are *narrow* and *homogeneous*: each transform touches only the columns it needs (T1/T2) in a sequential scan.
- No duplicated facts means less memory and no update anomalies (fewer cache lines written, fewer invalidations).
- Stateless transforms of table → table are easy to test, parallelise (T17) and stream ("Stateless transforms of stateful data are highly robust and deeply parallelisable" [S4]).
- Joins on sorted integer keys are merge-joins: sequential, prefetchable and branch-predictable.
- Layout can change (hot/cold, SoA/AoS, sort order) without changing what the code means, because the code speaks in terms of tables and keys, not pointers.

**When NOT to use.** Fabian: "You certainly don't have to move your data to a database style to do data-oriented design" [S3]. Over-normalising data you always read together (e.g. `x, y, z`) just adds joins; *denormalise for the hot query*, as database people do. Graph-shaped problems with deep traversal (scene hierarchies, ASTs) are often better served by index-linked arrays in a specific order (T4/T8). Small programs where the indirection hurts readability more than it helps.

**Canonical example.** Fabian's dungeon: `Room{id, name}`, `Door{from_room, to_room, locked_by_key?}` normalised into `Doors{from,to}` + `LockedDoors{door_id, key_id}`, and `Pickups{room, item}`. Queries such as "all doors out of room 3" and "all locked doors whose key the player has" are written as loops over tables (joins).

**Visualization.** Before: an object graph with nested pointers (a "spaghetti" diagram). After: 4–5 small spreadsheet-like tables with key columns highlighted and thin lines showing FK → PK. Then animate one "query" as a highlighted scan down one column plus a join.

**Best sources.** Fabian, *Data-Oriented Design* ch. 2 "Relational Databases" (online) [S3] and ch. "Existential Processing" [S4]; Mark Hansen's book notes [S24]; Abadi et al. on column stores (for the database side) [S44].

---

## T15. Arena, linear, stack, pool and frame allocators

**What.** Allocate from a large pre-reserved block according to *lifetime*, rather than calling general malloc/free per object.
- *Linear / arena / region*: a pointer bump. "To allocate some memory from the arena, it is as simple as moving the offset (or pointer) forward ... O(1)"; there are no individual frees, and "The memory is usually freed all at once" (gingerBill) [S45].
- *Stack (LIFO)*: arena plus a per-allocation header, so the most recent allocation can be popped [S46].
- *Pool*: "splits the supplied backing buffer into *chunks* of equal size and keeps track of which of the chunks are free" (free list threaded *through* the free chunks), O(1) alloc and free in any order, little fragmentation; ideal for same-type objects with individual lifetimes [S47]. A slot map (T5) is a pool with generation checks.
- *Frame / scratch / temp arena*: an arena reset every frame, request or loop iteration. This is gingerBill's "Transient Allocation: memory that has a cycle-based lifetime" vs "Permanent Allocation" [S48]. His rough table: ~95% of allocations have known size *and* known lifetime [S48].
- Ryan Fleury's framing: lifetimes form a small number of *stacks*. Give each lifetime its own arena, and "solving each problem is trivial". Arenas compose (a pool can carve its chunks from an arena), and can grow via chained blocks or by reserving a huge virtual range (64-bit address space) and committing pages on demand [S49].

**Why it works.** Allocation is a few instructions (add, compare), with no locks, no size-class lookup and no metadata scattered across the heap. Objects allocated together sit *together*, in allocation order, which is usually access order, so you get locality and prefetching for free. Freeing N objects is O(1). Fewer page faults and less TLB pressure than a fragmented heap. It also removes whole classes of bugs (leaks and double frees inside a lifetime).

**When NOT to use.** Objects with unpredictable, individual lifetimes that outlive any scope (use a pool or slot map, or a general allocator). Long-running arenas that accumulate garbage because nothing can be freed individually. Pointers into a frame arena that escape the frame are use-after-free in disguise: debug builds should poison memory on reset. Data that must grow in place (vectors) can waste arena space on every regrow; use a separate growable array or reserve its capacity up front.

**Canonical example.** Parse a 100 MB JSON or source file: allocate each AST node with malloc vs bump-allocate from an arena vs SoA arrays (T8). Measure parse time, teardown time (malloc: walk and free each node; arena: one call) and peak RSS. Second: a per-frame string-formatting scratch arena.

**Visualization.** A long horizontal block with a moving "offset" arrow; colour-coded allocations accumulate; "reset" snaps the arrow back to 0. For pools: equal-width chunks with a free-list arrow chain drawn *through* the free chunks. Lifetime-stacks diagram à la Fleury: permanent / per-level / per-frame arenas as nested bars on a timeline.

**Best sources.** gingerBill, *Memory Allocation Strategies* parts 1–6 (2019–2021) [S48][S45][S46][S47]; Ryan Fleury, *Untangling Lifetimes: The Arena Allocator* (2022) [S49].

---

## T16. ECS: archetype vs sparse-set storage (EnTT, flecs, Bevy)

**What.** An Entity Component System separates *identity* (entity = an integer id, usually generational, T5), *data* (components = plain structs) and *behaviour* (systems = loops over all entities that have a given set of components). The defining choice is storage:
- **Archetype / table ("dense") ECS**: entities with *exactly the same component set* share a table; "components are columns and entities are rows. Archetype implementations are fast to query and iterate" (ECS FAQ). Used by flecs, Unity DOTS, Unreal Mass, Bevy, Legion, hecs [S19]. Mertens' *Building an ECS #1*: an archetype "stores all the entities that have the same components", so they share one component-id vector, and you keep "a set per component" of the archetypes that contain it, for fast queries [S50]. Part #3 shows the archetype graph (add/remove edges cached between tables), the entity index (entity → table + row + alive version, as a paged sparse set), and optional per-component sparse storage [S17].
- **Sparse-set ECS**: each component type has its own sparse set keyed by entity (T6). "Sparse set implementations allow for fast add/remove operations." Used by EnTT and Shipyard [S19]. A multi-component query "iterates all entities in one of the queried for components (usually the one with the least entities) and tests for each subsequent component if the entity has it" [S19]. EnTT *groups* sort several pools so that the matching entities sit at the front at the same indices, which allows plain-array iteration, with the limitation that "components can only appear in one group" (Mertens, flecs issue #3) [S51].
- **Hybrid**: Bevy defaults to table storage and lets you choose per component, e.g. `#[component(storage = "SparseSet")]` for frequently toggled markers. Adding or removing a table component "requires copying the data of all table components for the entity to a different location in memory" [S52]. Bevy maintainers have discussed removing sparse sets because of the cost of the dual code paths (discussion #19164) [S53].

**Why it works.** Both turn "for each object, call update" into dense array loops over exactly the data a system reads (T1, T7, T10). Archetypes make every query an iteration over a list of matching tables, each a set of contiguous SoA columns with aligned rows, so the access is linear, prefetchable and vectorisable. Sparse sets make structural changes O(1) without moving other components. A 2025 controlled comparison (Staffordshire, CGVC) found archetypes increasingly ahead as entity counts grew, attributing it to "the cache-coherent nature of archetypal storage" vs indirect access in sparse sets [S54].

**When NOT to use.** Archetypes: frequent add/remove of components (each change moves the entity's whole row to another table), or a combinatorial explosion of unique component sets (many tiny tables, which fragment iteration). Sparse sets: queries joining many components (a random lookup per extra component). Generally: small games or tools where a few plain arrays per entity type (T11) are simpler and just as fast. Don't build an ECS to get DOD; it is one *application* of these techniques.

**Canonical example.** 1M entities with `Position`, half with `Velocity`, 10% with `Burning` toggled every frame. Systems: move (Position+Velocity), burn (Position+Burning). Implement archetype vs sparse set; measure iteration time and per-frame toggle cost. This shows the trade-off on both sides.

**Visualization.** Archetype: a grid of tables labelled `{P,V}`, `{P}`, `{P,V,B}` with columns as coloured strips; adding `B` animates a row hopping between tables along a graph edge. Sparse set: one sparse/dense pair per component with query arrows from the smallest dense array probing the others. Mertens' "Storage in Pictures" is the model to emulate [S17].

**Best sources.** Sander Mertens, *Building an ECS* #1 (2022) [S50], #3 *Storage in Pictures* (2024) [S17], ECS FAQ [S19], flecs issue #3 [S51]; skypjack, *ECS back and forth* (2019–2020) [S14][S16]; Bevy Cheat Book, *Component Storage* [S52]; Bevy discussion #19164 [S53]; Staffordshire 2025 benchmark paper [S54]; Catherine West RustConf 2018 [S10].

---

## T17. Data-parallel job systems

**What.** A pool of worker threads (usually one per core), a job type (function pointer + data range), queues, and a dependency mechanism. The DOD-specific part: jobs are *batches over slices of arrays* ("parallel for" over [i, j) chunks), and dependencies are declared from which arrays each job reads and writes.
- Naughty Dog (Gyrling, GDC 2015): 6 worker threads "each one ... locked to a CPU core"; "a thread is the execution unit, the fiber is the context"; 160 fibers (128 × 64 KiB, 32 × 512 KiB stacks); 3 priority queues; "atomic counters used for synchronization"; *no* job stealing; frames pipelined so stages run independently [S55]. Waiting on a counter swaps the fiber instead of blocking the thread (Pastagames' write-up [S56]).
- Work stealing (Rayon, Unity): each worker has its own deque, and idle workers steal from others. `join(a, b)` pushes `b` for thieves while running `a`; Rayon's `par_iter` adaptively splits ranges [S57][S58].
- Unity's job system: `IJobParallelFor` gives "each worker thread ... an exclusive index", and dependency chains schedule jobs [S59].

**Why it works.** DOD data is already in homogeneous arrays with stateless transforms (T7, T14), so splitting an array into disjoint chunks makes each core process its own contiguous range: no locks, no shared writes, and each core streams its own cache lines. Fabian: no global state and no accumulator means "it is proven to be parallelisable" [S4]. Chunk sizes of a few KB to a few hundred KB amortise scheduling overhead while leaving enough chunks to balance load.

**When NOT to use.** Tiny workloads: scheduling overhead (~µs) exceeds the work. Memory-bandwidth-bound loops already saturating DRAM with one or two cores, where more threads give nothing. Reductions or writes to shared state (use per-thread partial results and merge them). Chunks that share cache lines at their boundaries (T18). Code that needs strict ordering.

**Canonical example.** The particle update (T1) over 10M particles: single-threaded vs `par_chunks_mut(16_384)` (Rayon) / `std.Thread.Pool` (Zig) / `core:thread` pool (Odin). Plot the speedup curve vs thread count and see it flatten at the memory-bandwidth limit. Compare AoS vs SoA under parallelism: SoA saturates bandwidth later.

**Visualization.** A timeline (Gantt) per core with coloured job blocks and dependency arrows; a work-stealing animation of an idle core grabbing half of another's deque. Plus a "speedup vs threads" chart with a dashed "bandwidth ceiling" line.

**Best sources.** Gyrling, *Parallelizing the Naughty Dog Engine Using Fibers* (GDC 2015) [S55]; Dangling Pointers, *Job System* [S56]; Rayon FAQ [S57]; Unity job system docs [S59]; The Data Quarry on Rayon [S58].

---

## T18. Avoiding false sharing

**What.** Two threads write *different* variables that happen to sit on the *same cache line*. The coherence protocol (MESI and variants) treats the line as the unit, so each write invalidates the other core's copy and the line bounces between cores, even though no data is logically shared. Fix: put independently written data on separate lines with alignment and padding, or restructure so each thread writes into its own contiguous region. Rust's `crossbeam_utils::CachePadded<T>` aligns to **128 bytes** on x86-64/aarch64/powerpc64, because "on modern Intel architectures, spatial prefetcher is pulling pairs of 64-byte cache lines at a time" (and 32 on some ARM/MIPS, 256 on s390x) [S60]. C++ offers `std::hardware_destructive_interference_size`; Zig has `std.atomic.cache_line`; Odin has `#align`.

**Why it works.** A write to a line in Shared state forces an invalidation round-trip (tens to ~100+ ns cross-core, more cross-socket) instead of an L1 hit (~1 ns). With padding each core keeps its line in Modified state locally and never sends coherence traffic. CS3214 summary: "caches have no notion of variables - they operate using cache lines" [S61].

**When NOT to use.** Read-mostly shared data: reads can be Shared in all caches, so padding just wastes memory and cache capacity. Huge arrays of per-element counters: padding each to 128 B multiplies memory 16–32×. Instead *partition*: each thread owns a contiguous chunk and only the chunk boundaries can share lines. Single-threaded code.

**Canonical example.** `counters: [N_THREADS]u64`, each thread incrementing `counters[tid]` 100M times, vs `[N_THREADS]CachePadded<u64>`, vs local accumulator + one final write. The first is typically several to 10×+ slower at 4–8 threads.

**Visualization.** One cache line drawn as 8 × u64 slots, two cores colour-coding "their" slot, and an arrow ping-ponging the whole line between the L1 boxes with a "invalidations: N" counter; then the padded layout with two lines and no arrows.

**Best sources.** crossbeam `CachePadded` docs [S60]; Virginia Tech CS3214 false-sharing note [S61]; slice 01 §3.5 for hardware detail.

---

## T19. Intrusive lists vs arrays

**What.** In a *non-intrusive* linked list each node is a separate allocation `{next, prev, *payload}` pointing at the object. In an *intrusive* list the link fields sit inside the object (Linux `struct list_head { next, prev }` embedded in the struct, with `container_of()` to get back to the containing struct) [S63][S73]. An *array* (vector) stores the elements themselves contiguously. A DOD middle ground is the **index-linked list**: `next: u32` columns inside an array or pool (free lists, per-cell particle chains, Zig AST child lists in `extra_data`).

**Why it works (and why lists usually lose).**
- Traversal: every `node = node->next` is a *dependent* load. The CPU can't issue the next load until the current one returns, so the prefetcher can't help and each hop can cost a full DRAM miss (~100 ns). An array traversal is a sequential stream: 16 × 4-byte ints per 64-byte line, and the prefetcher runs ahead (Stack Overflow summary of Stroustrup's argument [S64]). The Linux kernel's own docs: "due to their poor data locality, linked lists are a bad choice in situations where performance may be of consideration" [S63].
- Even insert/delete in the middle, the textbook list win, usually goes to arrays at realistic sizes, because *finding* the position is O(n) cache misses for a list, while the array's O(n) memmove is sequential (HN thread, "In defense of linked lists" [S72]; Stroustrup's GoingNative 2012 point, as reported in [S64]).
- Intrusive lists beat *non-intrusive* ones: one allocation instead of two, and no extra pointer hop to reach the payload [S62].

**When lists are right (when NOT to use arrays).** O(1) unlink of an element you already hold a pointer to, without moving other elements (LRU caches, scheduler run queues, timers). Objects that must sit in several lists at once without copying (the kernel puts one object on several lists) [S72]. Contexts where a growable array's reallocation is impossible or unsafe (kernel, interrupt handlers, lock-free structures, fixed pools) [S62]. Lists that are rarely traversed: one analysis found traversals were only about 6% of list operations in Linux [S62]. Even then, prefer *index* links inside a pool to pointer links (T4/T15).

**Canonical example.** Sum 10M `u64`s: `Vec<u64>` vs a linked list allocated in order (nodes happen to be nearly contiguous, so it looks deceptively OK) vs a linked list whose nodes were *shuffled* in memory (the realistic case after churn). Expect the shuffled list to be 10–100× slower than the array; the in-order list sits in between. This "allocate in order, then shuffle" control is what makes the benchmark honest.

**Visualization.** The same 8 elements drawn twice. Array: 8 boxes in one cache-line strip, with a single sweep arrow. List: boxes scattered across a large "RAM" rectangle, with numbered hop arrows and a stopwatch showing ~100 ns per hop. Add a timeline showing loads *serialised* (list) vs *overlapped* (array).

**Best sources.** Linux kernel docs, *Linked Lists in Linux* [S63]; *Data structures in practice: Intrusive linked lists* [S62]; LWN, *Toward a better list iterator for the kernel* (2022) [S73]; Stack Overflow "Bjarne Stroustrup says we must avoid linked lists" [S64]; HN discussion [S72].

---

## T20. Spatial partitioning (uniform grids and hash grids) as a data layout

**What.** For neighbour queries (collision, flocking, SPH fluids, picking), bin objects into cells of size h (usually the interaction radius, 2r for equal spheres), then test only the 3×3 (2D) or 3×3×3 = 27 (3D) neighbouring cells instead of all O(n²) pairs [S65]. The DOD version is not "a grid of `Vec<Entity>`" but a **flat, sorted layout** built in O(n) each frame:
1. compute each particle's cell (or hashed cell) index;
2. `count[cell]++`;
3. exclusive prefix sum over the counts gives `cellStart[cell]`;
4. scatter particle *indices* (or the particles themselves) into one dense array so that each cell's particles are a contiguous slice.

Müller's "dense" spatial hash is exactly two arrays (a count/start array and a particle-index array) [S65][S66]. For unbounded worlds, hash cell coordinates into a fixed-size table, e.g. `(xi*92837111) ^ (yi*689287499) ^ (zi*283923481)` mod table size. Collisions only add false candidates, which the distance test then rejects ("hash collision OK") [S65]. Freiburg's uniform-grid study does the same with a sort by cell index: "all primitives that lie within the same cell are contiguous ... spatially close and likely to intersect are also close in memory" [S67]. A related refinement: reorder the particle arrays themselves by cell (or by a Morton/Z-order key) every N frames, so neighbours in space are neighbours in memory.

**Why it works.** Algorithmically, it turns O(n²) into ~O(n) (Müller: 100,000 points means 10¹⁰ naive tests [S65]). At the hardware level, the counting-sort layout gives no per-cell allocations, no pointers and no `Vec` headers. A neighbour query reads a few contiguous slices, and once particles are reordered by cell, those slices are also the next cache lines. The build step is a few sequential passes, which parallelise well (per-thread counts plus a parallel prefix sum), and it works the same on the GPU.

**When NOT to use.** Very non-uniform densities (one cell holds thousands while most are empty): use a hierarchy (quadtree/octree, BVH) or multi-level grids. Objects of very different sizes: big ones span many cells; put them in a separate coarse grid or a BVH. Mostly static scenes queried by rays: BVHs/k-d trees win. A small n (say < a few hundred), where brute-force SIMD over SoA is simpler and often faster.

**Canonical example.** 100k–1M 2D circles of equal radius bouncing in a box. Versions: brute force O(n²) (small n only), `HashMap<Cell, Vec<u32>>`, a dense counting-sort grid, and the dense grid plus reordering the particle SoA by cell. Report build time and query time per frame.

**Visualization.** Grid overlay on particles, with one particle's 3×3 neighbourhood highlighted. Below it, the `cellStart` array and the dense index array, with brackets showing which slice belongs to which cell. Animate the three passes (count, prefix sum, scatter). Optional: colour particles by memory address before and after reordering to show spatial and memory locality lining up.

**Best sources.** Matthias Müller, *Ten Minute Physics #11: Blazing Fast Neighbor Search with Spatial Hashing* [S65]; Carmen Cincotti, *Spatial Hash Maps for XPBD* (2022) [S66]; Freiburg TR 263, uniform grids for collision handling (2011) [S67]; *zelll* cell lists in Rust (2026) [S74] (sparse-grid variant using counting sort).

---

## T21. String interning

**What.** Store each distinct string once, in a single big byte buffer or table, and refer to it everywhere by a small integer id (`u32`), or by (offset, len) into the buffer. Lookup on insert goes through a hash map from string to id. matklad: interning gives "less memory allocated to hold strings" and "comparison can be done in O(1) (instead of O(n))". His simple Rust interner is a `Vec` of strings plus a `HashMap<&str, u32>`, with the strings in a growing buffer that is never reallocated in place (new chunks of `next_power_of_two` size), so `&str` slices stay valid [S68]. Kelley's Zig pipeline ends in "a string table" as one of its four arrays [S5]. The technique generalises beyond strings: gendignoux interned arbitrary repeated values in a time-series database and reports it **2000× smaller** [S69].

**Why it works.** An id is 4 bytes instead of a 16–24 byte fat pointer or `String` header plus a separate heap allocation, so records referencing names shrink a lot (T3/T4). Equality and hashing become integer operations, and ids can index directly into side tables (symbol → type, symbol → definition) with no hashing. All string bytes sit in one contiguous buffer, so they are friendly to serialisation (`writev` the table) and to cache.

**When NOT to use.** Mostly unique strings (log messages, user text): the hash map costs you and you save nothing. Strings that need frequent mutation. Interners shared across threads become a contention point; shard them or build per-thread interners and merge. Ids are only meaningful relative to *their* interner (the same "which array?" issue as T4), so use a typed id. A global, never-freed interner can grow without bound in long-running processes.

**Canonical example.** Tokenise a large source file and build a symbol table: `HashMap<String, Info>` keyed by owned strings vs interned `u32` ids plus `Vec<Info>` indexed by id. Measure memory and the time to resolve all identifier references.

**Visualization.** Left: many arrows from records to duplicate "foo" boxes scattered around the heap. Right: one byte buffer `foo\0bar\0baz` with offsets, records holding small integers, and a hash-map box beside the buffer used only on insert.

**Best sources.** matklad, *Fast and Simple Rust Interner* (2020) [S68]; Guillaume Endignoux, *The power of interning* (2025) [S69]; Kelley talk transcript [S5].

---

## T22. Columnar storage in databases and Apache Arrow

**What.** The database world's name for SoA. A **column store** keeps each attribute of a table contiguous. Abadi, Madden & Hachem (SIGMOD 2008): column-stores "have been shown to perform more than an order of magnitude better than traditional row-oriented database systems ... on analytical workloads", and you *cannot* get that just by vertically partitioning or indexing a row store. The gains need column-specific compression, late materialisation and block/vectorised execution [S44]. A course write-up of the paper's numbers for SSBM query Q4: C-Store 2.09 s vs row store 722.90 s, or 21.76 s for the row store with materialised views [S75] (search; not checked against the paper).

**Apache Arrow** is a standard *in-memory* columnar format. Its stated key features: "Data adjacency for sequential access (scans)", "O(1) (constant-time) random access", "SIMD and vectorization-friendly", and "Relocatable without 'pointer swizzling', allowing for true zero-copy access in shared memory" [S70]. Each of these maps onto a technique in this catalog:
- **Validity bitmaps** (1 bit per slot, 1 = valid) instead of a sentinel value or a per-value `Option` tag: T7/T9, booleans stored out of band [S70].
- **Offsets buffers** for variable-length data: `length + 1` integers, where value j is `data[offsets[j]..offsets[j+1]]`. This is the same pattern as Zig's `extra_data` ranges and string tables (T8/T21) [S70].
- **Dictionary encoding** (integer indices into a dictionary): interning (T21). **Run-end encoding**: "each run is represented as a value and an integer giving the index in the array where the run ends", with random access by binary search, O(log n) [S70]. Both are T9.
- **Dense/sparse unions**: a `types` byte buffer plus an offsets buffer into per-type child arrays. This is T8's tag array plus T11's per-type buckets [S70].
- **Alignment and padding**: "prefer using 64-byte alignment and padding", chosen to match SIMD register width so loops need no tail checks, in effect loading "the entire 64-byte buffer into a 512-bit wide SIMD register" [S70]. That is T13.
- Offsets instead of pointers make buffers position-independent (T4), so the same bytes can be memory-mapped, shared between processes or sent over IPC without fix-ups [S70].

**Why it works.** The same reasons as T1/T9/T13, at scale: analytical queries touch a few columns of many rows; a homogeneous column compresses far better (similar values next to each other); and vectorised kernels run over primitive arrays without per-row interpretation.

**When NOT to use.** OLTP workloads that read or write whole rows one at a time (insert a customer, update an order): row stores win, because a tuple write in a column store touches every column file (Abadi's slides: "Easy to add a new record" for row stores; "Tuple writes might require multiple seeks" for column stores) [S44]. Constantly mutated data: Arrow arrays are designed to be immutable once built (use builders and batches). Small tables where per-column overhead dominates.

**Canonical example.** 10M-row "sales" table with 16 columns. Query `SELECT SUM(price) WHERE region = 3`. Run it over an AoS `Vec<Row>`, over SoA columns, and over SoA with `region` dictionary-encoded as `u8` and a bitmap filter. Optionally run the same query through an Arrow library (arrow-rs) for a reference point. Report bytes scanned and time.

**Visualization.** A table drawn as a spreadsheet, then "exploded" into column strips. Highlight the 2 columns the query touches, and grey out the 14 untouched ones in the row layout to show the bytes wasted. Show Arrow's buffers for one string column (validity bits, offsets, data bytes) in the spec's own table style.

**Best sources.** Apache Arrow, *Columnar Format* specification (opened) [S70]; Abadi, Madden & Hachem, *Column-Stores vs. Row-Stores: How Different Are They Really?* (SIGMOD 2008) paper and slides [S44]; Krish Patel's course notes on C-Store (2026) [S75] (search).

---

# Part B. Benchmark experiments that reliably show large speedups

General rules so results reproduce: use a working set much larger than the LLC (e.g. ≥ 256 MB) unless the point is cache-resident behaviour; warm up; take the median of ≥ 10 runs; print a checksum so the compiler can't delete the work; build with release flags; report **ns/element and GB/s**, not only seconds; pin threads for the multi-thread tests; report the CPU model. Also run each test at a small size (fits in L1/L2) so readers can see the speedup *appear* as the size crosses cache boundaries. Expected ranges below are typical and depend on the machine; they are not measured here.

| # | Experiment | Variants | What to report | Typical result |
|---|---|---|---|---|
| B1 | Particle update `p += v*dt` (T1/T13) | AoS 64-B particle; SoA; AoSoA-8; SoA + explicit SIMD | ns/particle across N = 1K…100M | 2–5× SoA vs AoS when memory-bound; more with SIMD |
| B2 | Linked list vs array sum (T19) | `Vec<u64>`; list allocated in order; list with nodes shuffled in memory | ns/element vs N | shuffled list 10–100× slower at DRAM sizes |
| B3 | Padding waste (T3) | `{bool,f64,bool,f64,u8}` (40 B) vs reordered (24 B) vs SoA | `sizeof`, MB for 10M, scan time | time roughly proportional to bytes; ~1.6× |
| B4 | Hot/cold split (T2) | struct with 200-B inline name vs hot array + cold side table | scan time over hot fields | several × once hot data fits a cache level |
| B5 | Pointers vs u32 indices (T4) | 10M-node binary tree, `Box`/pointers vs index arena | bytes/node, build + traversal time, teardown time | ~2× memory; faster build and near-instant teardown |
| B6 | Sorted vs unsorted branch (T11/T12) | `if (x >= 128) sum += x` on random vs sorted data; branchless version | cycles/element vs branch probability P | ≈3–6× random vs sorted; branchless flat |
| B7 | Virtual vs switch vs table vs per-type arrays (T11) | Muratori's shapes | cycles/shape | ≈1.5× / ≈10× / up to 20–25× with AVX [S31] |
| B8 | Existence-based vs flag check (T7) | 10M entities, 50% "alive" random flags vs alive-only array | time per update | about 2× fewer bytes, plus no mispredicts |
| B9 | False sharing (T18) | `[T]u64` counters vs 128-B padded vs local accumulator | time vs thread count | unpadded often several to 10×+ slower |
| B10 | Allocator (T15) | malloc per AST node vs arena vs SoA tagged encoding (T8) | parse time, teardown time, peak RSS | large teardown win; locality win on traversal |
| B11 | Sparse set vs archetype iteration (T6/T16) | 1M entities; 2- and 4-component queries; per-frame toggles | iteration ms; toggle ms | archetype faster to iterate, sparse set faster to toggle |
| B12 | Spatial grid (T20) | O(n²) vs `HashMap<cell,Vec>` vs dense counting-sort grid vs + reorder by cell | build + query ms/frame | orders of magnitude vs O(n²); 2–5× dense vs HashMap |
| B13 | Column scan (T22) | AoS rows vs SoA vs SoA + dictionary `u8` + bitmap | bytes scanned, ms | roughly proportional to bytes touched (5–10×) |
| B14 | Delta + bit packing (T9) | raw u64 vs delta u16 vs bit-packed | MB, sum time | memory-bound speedup close to the compression ratio |
| B15 | Parallel scaling (T17) | B1 with 1…N threads, AoS vs SoA | speedup curve | flattens at memory bandwidth; SoA reaches the ceiling with fewer threads but higher throughput |

Pitfalls to warn readers about: the "in-order linked list" looks fine (always include the shuffled control); compilers may auto-vectorise the AoS loop when the struct is small, which narrows the gap (state the struct size); branchless and branchy may compile to the same code (check the assembly, e.g. on Compiler Explorer); on Apple M-series, the 128-B L2 lines and large caches move the crossover points.

---

# Part C. Visualization ideas (summary index)

Each technique section above has its own idea; this is the list in one place, plus reusable visual elements.

Reusable visual elements:
1. **Cache-line ruler**: a strip of 64-B boxes; colour the bytes the loop uses, hatch the padding. Shows "useful bytes per line" (T1, T2, T3, T9, T22).
2. **Address-space scatter**: objects drawn as dots on a big RAM rectangle, with arrows for traversal order (T4, T19, T20).
3. **Branch strip**: an element strip with ✓/✗ predictor row below (T7, T11, T12).
4. **Tapes**: parallel horizontal arrays with arrows between them (T5, T6, T8, T20, T21, T22).
5. **Gantt per core** (T17, T18).
6. **"Size bar race"**: bytes/element bars as a struct is transformed step by step (Kelley's monster 24 → 16 → 12, and AST nodes 120 → 15.6) (T3, T4, T7, T8).

Per technique: T1 three layouts on a cache-line ruler; T2 field-heat bar cut into hot/cold; T3 byte grid with hatched padding and a reorder animation; T4 pointer tree vs index table; T5 slot array with gen counters and a stale handle failing; T6 sparse/dense arrows with swap-remove; T7 one table with a "questioning" cursor vs three state tables with rows migrating; T8 four tapes with lhs/rhs arrows into nodes or extra; T9 bit ruler and delta chart; T10 per-call overhead timeline; T11 shuffled vs sorted colour strip plus Casey's cycles chart; T12 U-curve vs flat line over P; T13 SIMD lanes AoS (wasted lane) vs SoA; T14 object graph → normalised tables; T15 bump pointer and pool free list; T16 archetype tables with a row hopping along graph edges; T17 Gantt + bandwidth ceiling; T18 cache line ping-pong; T19 sweep vs hop arrows; T20 grid + cellStart slices; T21 duplicates vs one buffer; T22 spreadsheet exploded into columns, Arrow buffers.

---

# SOURCES

Key: **(opened)** = I read the page with a fetch tool during this research; **(search)** = seen only as a search result snippet (title, URL and excerpt), not read in full. Years are as shown on the page or snippet; "n.d." if not visible.

| ID | Title | Author | Year | URL | Status | Note |
|---|---|---|---|---|---|---|
| S1 | A Practical Guide to Applying Data-Oriented Design (Handmade Seattle) | Andrew Kelley | 2021 | https://media.handmade-seattle.com/practical-data-oriented-design/ (video: https://www.youtube.com/watch?v=IroPQ150F6c) | search | The talk itself; content read via the transcript S5 |
| S2 | lib/std/multi_array_list.zig | Zig project | n.d. (master) | https://github.com/ziglang/zig/blob/master/lib/std/multi_array_list.zig | search | Doc comment: SoA saves padding, improves cache use; tagged-union support |
| S3 | Data-Oriented Design, ch. "Relational Databases" (online) | Richard Fabian | 2018 | http://www.dataorienteddesign.com/dodbook/node3.html (PDF: https://www.dataorienteddesign.com/dodbook.pdf) | search | Normalisation of game data into tables |
| S4 | Data-Oriented Design, ch. "Existential Processing" (online) | Richard Fabian | 2018 | https://www.dataorienteddesign.com/dodbook/node4.html | opened | Don't use booleans/enums; tables as state; mutation/filter/emission |
| S5 | Andrew Kelley Practical Data Oriented Design (DoD) — transcript | Josherich's Blog (transcript of S1) | 2025 | https://josherich.me/podcast/andrew-kelley-practical-data-oriented-design-dod | opened | Source of all Kelley numbers (24→16→12, 160→91 KB, 32→17, 120→15.6, 54→20.3, 22% and 39%) |
| S6 | Zig Parser | Mitchell Hashimoto | n.d. | https://mitchellh.com/zig/parser | opened | AST Node {tag, main_token, lhs, rhs}, extra_data, MultiArrayList |
| S7 | A Practical Guide to Applying Data-Oriented Design (forum notes) | cbrake, TMPDIR community | 2022 | https://community.tmpdir.org/t/a-practical-guide-to-applying-data-oriented-design/560 | search | Bullet summary of Kelley's lessons |
| S8 | Implementing a Struct of Arrays | Barry Revzin | 2025 | https://brevzin.github.io/c++/2025/05/02/soa | search | SoA in C++26 reflection, inspired by MultiArrayList |
| S9 | Memory Layout in Zig with Formulas | Raymond Tana | 2026 | https://raymondtana.github.io/math/programming/2026/01/23/zig-alignment-and-sizing.html | search | Size/alignment formulas, MultiArrayList buffer size |
| S10 | My RustConf 2018 Closing Keynote | Catherine West (kyren) | 2018 | https://kyren.github.io/2018/09/14/rustconf-talk.html | search | Generational indices, ECS in Rust |
| S11 | Handles are the better pointers | Andre Weissflog (floooh) | 2018 | https://floooh.github.io/2018/06/17/handles-vs-pointers.html | search | Index handles, per-slot generation counters |
| S12 | slotmap crate docs | Orson Peters | n.d. | https://docs.rs/slotmap | search | SlotMap, secondary maps, O(1) ops |
| S13 | Stable IDs and generations (An Introduction to Programming, using ECS & EBP in Rust) | root-11 | n.d. | https://root-11.github.io/intro-book/trunk/10_stable_ids_and_generations.html | search | Generational arena tutorial |
| S14 | ECS back and forth, Part 2 — Where are my entities? | Michele Caini (skypjack) | 2019 | https://skypjack.github.io/2019-03-07-ecs-baf-part-2 | search | Archetypes vs sparse sets |
| S15 | ECS back and forth, Part 9 — Sparse sets and EnTT | Michele Caini (skypjack) | 2020 | https://skypjack.github.io/2020-08-02-ecs-baf-part-9 | search | Sparse set ops; `dense[sparse[e]] == e` |
| S16 | ECS back and forth, Part 2 insights / Part 5 Sparse sets and sorting | Michele Caini (skypjack) | 2019 | https://skypjack.github.io/2019-03-21-ecs-baf-part-2-insights ; https://github.com/skypjack/skypjack.github.io/blob/master/_posts/2019-09-25-ecs-baf-part-5.md | search | Packed arrays, grouping, sorting pools |
| S17 | Building an ECS #3: Storage in Pictures | Sander Mertens | 2024 | https://ajmmertens.medium.com/building-an-ecs-storage-in-pictures-642b8bfd6e04 | search | Archetype graph, sparse components, paged entity index |
| S18 | An Efficient Representation for Sparse Sets | Preston Briggs, Linda Torczon | 1993 | (not located) | not opened, not in results | Cited as [BT93] in S54 and quoted by S15; listed for completeness only |
| S19 | Entity Component System FAQ | Sander Mertens | n.d. | https://github.com/SanderMertens/ecs-faq (also http://www.flecs.dev/ecs-faq) | search | Archetype vs sparse-set vs bitset ECS definitions |
| S20 | Memory Layout Transformations | Intel | n.d. | https://www.intel.com/content/www/us/en/developer/articles/technical/memory-layout-transformations.html | search | AoS→SoA to avoid gather/scatter |
| S21 | Intel ISPC User's Guide | Intel / ISPC project | n.d. | https://ispc.github.io/ispc.html | search | `soa<N>` qualifier, AoSoA |
| S22 | Cache-Conscious Structure Definition (PLDI '99) | Trishul Chilimbi, Bob Davidson, James Larus | 1999 | https://www.microsoft.com/en-us/research/publication/cache-conscious-structure-definition-2/ | search | Structure splitting: 10–27% fewer misses, 6–18% faster |
| S23 | The Lost Art of Structure Packing | Eric S. Raymond | n.d. | http://www.catb.org/esr/structure-packing | search | Padding rules; reorder by size but mind locality |
| S24 | Book Notes: Data Oriented Design | Mark Hansen | 2021 | https://www.markhansen.co.nz/book-data-oriented-design | search | Summary of Fabian: relational, existential processing |
| S25 | MultiArrayList for tagged unions (issue #14496) | hryx, Zig project | 2023 | https://github.com/ziglang/zig/issues/14496 | search | Tags array + bare-union payload array |
| S26 | Data Oriented Design, a.k.a. Lower Level Programming? | Hisham Muhammad | 2022 | https://hisham.hm/2022/02/19/data-oriented-design-aka-lower-level-programming | search | Commentary on Kelley's talk |
| S27 | Decoding billions of integers per second through vectorization | Daniel Lemire, Leonid Boytsov | 2015 | https://onlinelibrary.wiley.com/doi/10.1002/spe.2203 | search | SIMD-BP128, 2300M ints/s, vectorised delta |
| S28 | meshoptimizer (README: vertex quantization) | Arseny Kapoulkine (zeux) | n.d. | https://github.com/zeux/meshoptimizer | search | Quantizing normals/positions; non-multiple-of-8 bit counts |
| S29 | Zigzag decoding with AVX-512 | Arseny Kapoulkine (zeux) | 2026 | https://zeux.io/2026/06/17/zigzag-decoding-avx512 | search | Zigzag for signed deltas |
| S30 | Last Inner Product | Mike Acton | 2014 | https://www.gamedeveloper.com/production/last-inner-product | search | "Where there is one, there are many" |
| S31 | "Clean" Code, Horrible Performance | Casey Muratori | 2023 | https://www.computerenhance.com/p/clean-code-horrible-performance | opened | 35 → 24 → 3.5 cycles/shape; 15×; AVX 20–25× |
| S32 | "Clean" code, horrible performance (HN thread) | Hacker News | 2023 | https://news.ycombinator.com/item?id=34966137 | search | Comment on Acton's sort-by-type I-cache demo (second-hand) |
| S33 | Response to a Reporter Regarding "Clean Code, Horrible Performance" (+ comments) | Casey Muratori | 2023 | https://www.computerenhance.com/p/response-to-a-reporter-regarding (comments: /comments) | search | "n types → n arrays → n loops"; API transposition |
| S34 | Why is processing a sorted array faster than an unsorted array? | Stack Overflow (Mysticial et al.) | 2012 | https://stackoverflow.com/a/32742980 | search | ~6× from sorting; branch prediction |
| S35 | Revisions to the sorted-array answer / mirror | Stack Overflow; developerinsider.co | 2012 | https://stackoverflow.com/posts/11237235/revisions ; https://developerinsider.co/why-is-processing-a-sorted-array-faster-than-an-unsorted-array/ | search | Branchy vs branchless random/sorted timings |
| S36 | The Cost of Branching | Sergey Slotin (Algorithmica) | n.d. | https://en.algorithmica.org/hpc/pipelining/branching/ | search | 14 vs ~4 cycles/element; Zen 2 19-stage pipeline |
| S37 | Branchless Rust: Making a Filter 4x Faster by Removing an if | Serhii Potapov (greyblake) | n.d. | https://www.greyblake.com/blog/branchless-rust | search | 4.15 ms → 0.93 ms sorted; branchless compaction |
| S38 | Branchless Programming | Sergey Slotin (Algorithmica) | n.d. | https://en.algorithmica.org/hpc/pipelining/branchless | search | Predication, cmov, 75% rule, branchless lower_bound |
| S39 | BlockQuicksort: Avoiding Branch Mispredictions in Quicksort | Stefan Edelkamp, Armin Weiß | 2016 | https://drops.dagstuhl.de/storage/00lipics/lipics-vol057-esa2016/LIPIcs.ESA.2016.38/LIPIcs.ESA.2016.38.pdf | search | Branchless partitioning, faster than std::sort |
| S40 | SIMD Made Easy with Intel ISPC | Intel | n.d. | https://www.intel.com/content/www/us/en/developer/articles/technical/simd-made-easy-with-intel-ispc.html | search | AoS wasted lane; SoA triangle transposition |
| S41 | ISPC Performance Guide (perfguide.rst) | ISPC project | n.d. | https://github.com/ispc/ispc/blob/main/docs/perfguide.rst | search | AoS needs gather; `soa<8>` |
| S42 | Simple SIMD with ISPC (GDC slides) | Intel | n.d. | https://www.intel.com/content/dam/develop/external/us/en/documents/09-simple-simd-with-ispc.pdf | search | "Prefer SoA, or AoSoA"; transpose < gather |
| S43 | ispc: A SPMD Compiler for High-Performance CPU Programming (InPar) | Matt Pharr, William R. Mark | 2012 | https://ispc.github.io/papers/ispc_inpar_2012.pdf | search | Hybrid SoA figure |
| S44 | Column-Stores vs. Row-Stores: How Different Are They Really? (SIGMOD) | Daniel Abadi, Samuel Madden, Nabil Hachem | 2008 | https://www.cs.umd.edu/~abadi/papers/abadi-sigmod08.pdf (slides: https://www.cs.umd.edu/~abadi/talks/abadi-sigmod08-slides.pdf) | search | Row store can't simulate column store; compression + late materialisation |
| S45 | Memory Allocation Strategies Part 2: Linear/Arena Allocators | Ginger Bill | 2019 | https://www.gingerbill.org/article/2019/02/08/memory-allocation-strategies-002 | search | Bump allocator, free all at once |
| S46 | Memory Allocation Strategies Part 3: Stack Allocators | Ginger Bill | 2019 | https://www.gingerbill.org/article/2019/02/15/memory-allocation-strategies-003 | search | LIFO allocator with headers |
| S47 | Memory Allocation Strategies Part 4: Pool Allocators | Ginger Bill | 2019 | https://www.gingerbill.org/article/2019/02/16/memory-allocation-strategies-004 | search | Fixed-size chunks + free list |
| S48 | Memory Allocation Strategies Part 1: Thinking About Memory | Ginger Bill | 2019 | https://www.gingerbill.org/article/2019/02/01/memory-allocation-strategies-001 | search | Size/lifetime table (95%); permanent vs transient |
| S49 | Untangling Lifetimes: The Arena Allocator | Ryan Fleury | 2022 | https://www.rfleury.com/p/untangling-lifetimes-the-arena-allocator | search | Lifetimes as stacks; pool composed on arena; growth strategies |
| S50 | Building an ECS #1: Where are my Entities and Components | Sander Mertens | 2022 | https://ajmmertens.medium.com/building-an-ecs-1-where-are-my-entities-and-components-63d07c7da742 | search | Archetype data structure, set per component |
| S51 | How are components/entity stored in memory? (flecs issue #3) | Sander Mertens | n.d. (~2019) | https://github.com/SanderMertens/flecs/issues/3 | search | Archetype SoA vs EnTT sparse sets and groups |
| S52 | Component Storage (Table/Sparse-Set) — Unofficial Bevy Cheat Book | bevy-cheatbook | n.d. | https://bevy-cheatbook.github.io/patterns/component-storage.html | search | Table default; SparseSet for frequently toggled |
| S53 | Consider Removing Sparse Set Component Storage (discussion #19164) | Bevy contributors | 2025 | https://github.com/bevyengine/bevy/discussions/19164 | search | Cost of dual storage paths |
| S54 | Run-time Performance Comparison of Sparse-set and Archetype ECSes (CGVC) | Staffordshire University authors | 2025 | https://eprints.staffs.ac.uk/9315/1/cgvc20251224.pdf | search | Archetypes ahead as entity count grows |
| S55 | Parallelizing the Naughty Dog Engine Using Fibers (GDC) | Christian Gyrling | 2015 | https://media.gdcvault.com/gdc2015/presentations/Gyrling_Christian_Parallelizing_The_Naughty.pdf | search | 6 workers, 160 fibers, atomic counters, no stealing |
| S56 | Job System | Dangling Pointers (Pastagames) | n.d. | https://danglingpointers.com/post/job-system | search | Fiber job system in practice, counters |
| S57 | Rayon FAQ | Rayon project | n.d. | https://github.com/rayon-rs/rayon/blob/main/FAQ.md | search | Work stealing via join |
| S58 | Speeding up data analysis with Rayon and Rust | The Data Quarry (Prashanth Rao) | n.d. | https://thedataquarry.com/blog/intro-to-rayon | search | par_iter, adaptive splitting |
| S59 | Job system overview / Jobs overview (Unity 6) | Unity Technologies | n.d. | https://docs.unity.com/en-us/engine/6000.0/manual/scripting/optimization/job-system/overview | search | IJobParallelFor, work stealing, dependencies |
| S60 | CachePadded (crossbeam-utils) | crossbeam project | n.d. | https://docs.rs/crossbeam-utils/*/crossbeam_utils/struct.CachePadded.html | search | 128-B on x86-64/aarch64 because of adjacent-line prefetch |
| S61 | False sharing (CS3214 Computer Systems) | Godmar Back, Virginia Tech | 2022 | https://courses.cs.vt.edu/cs3214/spring2022/questions/falsesharing | search | Caches operate on lines, not variables |
| S62 | Intrusive linked lists | Data structures in practice | n.d. | https://www.data-structures-in-practice.com/intrusive-linked-lists | search | Fewer allocs; traversal is ~6% of Linux list ops |
| S63 | Linked Lists in Linux | Linux kernel documentation | n.d. | https://docs.kernel.org/core-api/list.html | search | "poor data locality ... bad choice" for performance |
| S64 | Bjarne Stroustrup says we must avoid linked lists | Stack Overflow | 2015 | https://stackoverflow.com/questions/34170566/bjarne-stroustrup-says-we-must-avoid-linked-lists/34171273 | search | Cache-line explanation of vector vs list |
| S65 | Blazing Fast Neighbor Search with Spatial Hashing (Ten Minute Physics #11) | Matthias Müller | n.d. | https://matthias-research.github.io/pages/tenMinutePhysics/11-hashing.pdf | search | Dense hash grid, h = 2r, hash function |
| S66 | How to Create Spatial Hash Maps for XPBD Self Collisions | Carmen Cincotti | 2022 | https://carmencincotti.com/2022-10-31/spatial-hash-maps-part-one | search | Count array + prefix sum + particle array |
| S67 | Uniform grids for collision handling (TR 263) | Univ. of Freiburg graphics group | 2011 | https://cg.informatik.uni-freiburg.de/publications/2011_TR263_uniformGrids.pdf | search | Sort by cell index; spatial = memory locality |
| S68 | Fast and Simple Rust Interner | Aleksey Kladov (matklad) | 2020 | https://matklad.github.io/2020/03/22/fast-simple-rust-interner.html | search | Vec + HashMap interner, O(1) compare |
| S69 | The power of interning: making a time series database 2000x smaller in Rust | Guillaume Endignoux | 2025 | https://gendignoux.com/blog/2025/03/03/rust-interning-2000x.html | search | Interning arbitrary types |
| S70 | Arrow Columnar Format | Apache Arrow project | n.d. (current) | https://arrow.apache.org/docs/format/Columnar.html | opened | Validity bitmaps, offsets, 64-B alignment, REE, unions, zero-copy |
| S71 | AoS and SoA | Wikipedia | n.d. | https://en.wikipedia.org/wiki/AoS_and_SoA | search | Definitions incl. AoSoA "tiled array of structs" (not cited inline; background) |
| S72 | In defense of linked lists (HN thread) | Hacker News | 2022 | https://news.ycombinator.com/item?id=33473497 | search | Cache-miss arithmetic for middle insert; multi-list membership |
| S73 | Toward a better list iterator for the kernel | LWN.net (Jonathan Corbet) | 2022 | https://lwn.net/Articles/887097/ | search | list_head, container_of |
| S74 | zelll: a fast, framework-free, and flexible implementation of the cell lists algorithm for Rust | Messow, Höner zu Siederdissen, Habeck | 2026 | https://pmc.ncbi.nlm.nih.gov/articles/PMC12910374 | search | Sparse cell lists via counting sort |
| S75 | Column stores: from C-Store to modern analytical databases | Krish Patel (Univ. of Waterloo notes) | 2026 | https://cs.uwaterloo.ca/~k587pate/notes/column-stores-c-store.html | search | Table of Q1–Q6 timings from Abadi 2008 (second-hand) |

Counts: 5 opened (S4, S5, S6, S31, S70), 69 seen in search results, 1 (S18) cited but not located.

## Open items / caveats for the book
- Kelley's numbers come from a third-party transcript (S5), not the slides; check them against the video or slides before printing.
- The Acton sort-by-type I-cache claim (T10) is second-hand, from an HN comment (S32).
- The C-Store vs row-store timings (T22) are second-hand (S75); check them against the paper's Table/figure.
- Expected speedups in Part B are typical ranges, not measured in this research; the book should measure on its own hardware.
