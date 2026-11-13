# 06 — Real-World Case Studies and Measured Results

Research slice for the DOD book (Rust / Zig / Odin). Each case covers **what changed**, the **layout before → after**, the **measured result**, and the **source**. All numbers come from pages I actually read (see SOURCES). Where a number comes from a secondary summary rather than the primary page, it is marked *(secondary)*. Where I could not check a claim, it is marked **[unverified]**.

Notes on how to use these numbers in the book:
- Most "speedups" are measured by the authors on their own machines and workloads. Quote them with their context (workload, machine, what was measured), not as universal constants.
- The strongest cases have instruction, cycle, cache-miss **and** wall-clock numbers together (Zig 0.8.0, Linux netdev, Ghostty PRs). Use those as the examples to imitate.

---

## Part A — Compilers

### A1. Zig self-hosted compiler: tokens, AST, ZIR (2021, Zig 0.8.0)

**What changed.** Andrew Kelley rewrote the memory layout of 3 of the 4 pipeline phases (`tokenize → parse → AstGen(ZIR) → Sema(AIR) → codegen`). He credits Richard Fabian's *Data-Oriented Design* book. Stated premise: *"using less memory will make things faster, because of fewer allocations and better cache utilization. Also using less memory is valuable in and of itself."*

**Layout before → after.**
- **Token:** 64 bytes → **5 bytes** (`tag: u8` + `start: u32` byte offset), stored SoA. There is no end offset: most token lengths follow from the tag, and string literals get re-scanned later in AstGen anyway, so re-tokenizing costs nothing.
- **AST node:** ~120 bytes (tagged union with pointers, a bool, line/column) → **13 bytes fixed** (`tag: u8`, `main_token: u32`, `data: {lhs: u32, rhs: u32}`), stored in a `MultiArrayList` so the 13 bytes are not padded to 16. Nodes that need more than two children use `lhs`/`rhs` as indices into one shared `extra_data: []u32` array. **Average 15.6 bytes/node** once `extra_data` is counted (from the talk).
- **"Encodings instead of polymorphism":** there is no single canonical tag per construct. For example `foo(bar)` → `call_one` (lhs = callee, rhs = arg), while `foo(a, b)` → `call` (rhs → `extra_data[start..end]`). Variable declarations have 3 encodings, `if` and `while` have 2 each. The tag is a u8, so there is a hard limit of 256 encodings.
- Key insight, quoted: *"The only purpose of an AST is to bring a tree structure to a list of tokens."* Nodes store only u32 indices. Everything else is found by looking left or right in the token-tags array, which is just an array of bytes.
- **ZIR instructions:** 54.0 → **20.3 bytes average** (talk). Source locations became u32 token or node offsets whose meaning depends on the encoding, references to other instructions became u32, and common constants (true/false) became reserved enum refs.
- `MultiArrayList` (SoA built with comptime) was added to std in the same release. Release-note example: the same struct appended 10,000 times uses **57%** of the memory of an ArrayList, because the padding after the 1-byte enum is gone.

**Measured.**
- Parser rewrite (PR #7920: 176 commits, +20,800/−16,573 lines): **15% fewer cache misses, 28% fewer instructions, 26% fewer cycles, 22% faster wall clock.**
- ZIR rewrite (PR #8266), on a contrived `print1mil.zig`: wall clock **0.93 s → 0.57 s (−39%)**, about 1.8 M lines/s; **peak memory 645 → 386 MiB (−40%)**; cache misses −53%, instructions −23%, cycles −41%.
- The flat-array output made the first three phases embarrassingly parallel and cacheable per file. ZIR serializes as just 4 arrays (u8 tags, u32×2 data, string bytes, u32 extra). AstGen over the whole std lib (292,458 lines), release build, cold cache: 33 ms → **8.9 M lines/s** on an 8-core i9-9980HK.
- `zig ast-check -t std/os.zig`: 238 KB source → 35,023 tokens (171 KB), 17,397 nodes (221 KB), ZIR 472 KB. Kelley found a consistent ratio of (source + tokens + AST) ≈ 1.3× ZIR, so loading cached ZIR reads *fewer* bytes than re-parsing would.

**Later outcome (whole compiler, Zig 0.10, 2022).** Building the compiler itself: peak RSS **9.6 GiB → 2.8 GiB (3.5× less)**, wall clock 43 s → 40 s (7%). Loris Cro attributes the memory gains "in good part" to DOD. Speed was still dominated by LLVM. Balanced lesson: DOD fixed memory, but the bottleneck moved to codegen. Later the self-hosted x86_64 backend (default for Debug in 0.15) cut debug compile times by about **5× vs LLVM**, and building the compiler went 13.8 s → 10.0 s from one follow-up change (0.15.1 notes).

**Sources:** Zig 0.8.0 release notes; Kelley "Practical DoD" transcript (josherich.me); Mitchell Hashimoto "Zig Parser"; Loris Cro "Zig Is Self-Hosted Now"; Zig 0.10.0 / 0.15.1 release notes.

**Teaching value:** this is the single best spine for the book. Every technique has a number attached: indices instead of pointers, SoA to kill padding, bools/sparse data out of band, encodings instead of polymorphism, recompute instead of store.

### A1b. Kelley's toy "monster" examples (same talk, good for Chapter 2-3 exercises)
- `struct {u32, u64, u32}` = 24 bytes because of alignment. Adding one bool to a 16-byte struct grows it to 24.
- 4 pointers: 32 bytes on 64-bit. Replace them with u32 indices → 16 bytes, and alignment drops 8 → 4.
- Monster `{ptr, u32, u32, bool alive}` = 24 B. Bool moved out of band (separate alive/dead arrays) → 16 B, plus indices → 12 B. 100 monsters: 2.4 KB → 1.2 KB. The "is dead" branch disappears from the hot loop.
- `{ptr, enum kind}` ×10,000: 160 KB AoS → **91 KB** with MultiArrayList ("a five-character fix").
- Sparse items (only 10% of monsters hold items) moved to a hash map: 366 KB → 198 KB.
- Tagged union (Human 20 B / Bee 1 B) = 32 B per element → encoding approach ≈ **17 B average**.

### A2. Carbon toolchain (Chandler Carruth, CppNow 2023; NDC Toronto 2026)

**What changed.** The design was data-oriented from day one, not retrofitted.
- Goals: **lex+parse 10 M lines/s, semantic analysis 1 M lines/s, lowering 0.1 M lines/s.** Turned into budgets that is about 100 ns per line to lex+parse, "about 200–300 cycles, maybe 500 instructions per line", and "only one main memory access per line (on average)". As a result, *"Can't allocate memory per token… Have to use every byte of every cache line accessed."*
- Core pattern: one dense homogeneous primary array, adjacency standing in for most edges, side arrays for secondary data, and **flyweight handles** (index wrappers) as the API.
- **Tokens:** a dense token buffer with side arrays for identifiers, strings and literals. *A 32-bit token ID is also the source location*, and line/column extents are computed on demand. Balanced delimiters are precomputed in the lexer, so the parser never sees unbalanced streams.
- **Parse tree:** linearized **postorder** array with a 1:1 correspondence to tokens. The common traversal is a linear walk, and hot edges are adjacency, which "breaks the dependency chain" so the CPU can pipeline loads. The parser uses an explicit stack (state machine) instead of recursion. There is no AST: Check walks the postorder parse tree in a single pass into SemIR.
- Contrast slide: a tiny 8-line C++ function produces **48 Clang AST nodes**.
- EuroLLVM 2024 (Richard Smith): parse node **12 bytes (maybe 8 soon), ~1 node per token**. SemIR has a fixed instruction size with two operands, **16 bytes/instruction**. Takeaway quoted: *"Data-oriented design is extra work, but often worth it."*
- NDC 2026 talk: good data structures are not enough; benchmarking turned up lexer wins from tail-call (`[[clang::musttail]]`) byte dispatch tables, SIMD newline/comment scanning, and guessed identifier counts for hash-table presizing.

**Measured.** The slides I read give targets and per-node sizes, **not** achieved lines/s. **[unverified]:** achieved throughput. Do not quote one.

**Sources:** chandlerc.blog slides 2023-cppnow-compiler and 2026-ndc-toronto; EuroLLVM 2024 SemIR slides; Carbon toolchain docs ("Distinct steps… better locality versus a callback approach").

### A3. Rust compiler (Nicholas Nethercote, 2016 → 2026)

Long-running "type shrinking" work. It is honest about diminishing returns, which makes it a good counterweight to Zig.
- `Token` 32 → 24 bytes (raw string `#` count `usize` → `u16`): small win. A further cut to 16 bytes gave a *negligible* speedup "and made the code uglier, so I abandoned it" (2018).
- LLVM inlines copies of ≤128 bytes and calls `memcpy` above that. `PredicateObligation` 136 → 112 B: up to 2.6% faster. Boxing a 176-byte `DiagnosticBuilder` so `PResult` went from ≥184 B to 16 B: up to 2.6% (2019). Over-boxing to shrink further was *slower* because of extra allocations.
- 2022: `FnAbi` 248 → 80 B, `ArgAbi` 208 → 56 B, `Attribute` 152 → 32 B (−5.13% max-rss on rustdoc). Explicitly cites the Zig work. Notes that `ast::Expr` 104 → 88 B "made little difference" and asks whether there are thresholds.
- 2023: `ast::Expr` **104 → 72 B (−30.8%)**: several sub-3% wall-time wins on primary benchmarks, up to 6% on stress tests. "Both of them were a pain, requiring multiple iterations."
- July 2026: `ast::Expr` **72 → 64 B** ("small enough to fit in a cache line"): >10% wall time on some AST-heavy benchmarks. A hot vector element 136 → 104 B (back under the memcpy threshold) plus avoiding 2/3 of moves gave **−40% wall time** on the two worst crates.
- Nov 2026: span representation/interning changes: >3% instruction reductions, metadata up to −37%, max-RSS up to −7%.

**Lesson:** in a big pointer-rich codebase, shrinking structs gives many 1–3% wins. Thresholds matter: the 128-byte memcpy line, the 64-byte cache line. Compare that with the 20–40% from designing the data layout up front (Zig, Carbon).

**Sources:** nnethercote blog 2016, 2018, 2019, Oct 2022, Mar 2023, Jul 2026, Nov 2026.

### A4. Roc compiler Rust → Zig rewrite (Richard Feldman, July 2026)
- Motivation included "struct-of-arrays layouts all over the place" and many arenas. He found Rust's ecosystem (including `soa_rs`) assumes one global allocator.
- All compiler data uses **32-bit indices instead of pointers**, often SoA. The data is written to disk as-is and loaded with only relocation fixups ("zero-parse deserialization", learned from Zig's compiler and confirmed by Casey Muratori as game-industry practice). With the disk cache warm, cache loads run at roughly memcpy speed.
- Build-time table (the language's own build, not DOD-of-output): Rust 354K LoC: 25.4 s cold / 3.4 s incremental. Zig 464K LoC: 32.1 s cold / **35 ms incremental**. Note: this measures the build of the compiler, not the effect of DOD on the compiler.

### A5. Smaller compiler case studies
- **Tweede Golf (Rust parser/compiler, DOD case study):** naive boxed tree vs index-based "dod" tree. Total heap 75.5 MB → 67.1 MB (~12% less). A boxed variant made ~400K allocations and was ~70% slower. A Rust-specific, small-scale, honest data point.
- **TU Delft thesis "Memory Layout Optimisation on ASTs":** applies Zig-style SoA to a teaching compiler. Base node 128 → 88 B by dropping token value fields, and up to **>12× AST memory reduction** on one input (zlib.tea). Cites Zig's >30% improvement.

---

## Part B — Systems software

### B1. TigerBeetle (financial OLTP DB, Zig)
- **Static allocation:** compute every bound at startup (connections, messages, batch sizes, replicas), allocate once, and never `malloc`/`free` afterwards. TIGER_STYLE: *"No memory may be dynamically allocated (or freed and reallocated) after initialization"*. A second-order effect they report: simpler designs that are easier to reason about.
- **Layout:** `Account` and `Transfer` are fixed **128 bytes = two cache lines**, cache-line aligned. 32 fit in a 4 KiB page. The struct goes over the wire as-is, with no serialization (Cap'n-Proto-inspired). The LSM "forest" uses many trees with fixed-size values (Transfer 128 B, id tree 32 B = u128 id + u64 ts + u64 pad).
- **Batching:** up to **8,190 transfers per request** (fits a 1 MiB message). Batches are homogeneous (all accounts or all transfers), which hoists the kind-branch out of the inner loop. *"Executing a batch of transfers is just one tight CPU loop."* Replication cost is paid once per batch.
- **Measured:** TigerBeetle's 2026 blog reports **454,518 transactions/s (909,162 transfers/s)** with large batches, and "a 100× improvement" from data modeling + autobatching + time-based IDs. A third-party test on an M4 Mac Mini (backend.how) measured 815K account creates/s. Counter-evidence (issue #2469): loading 1M transfers in 1,000 batches of 1,000 wrote **27 GB** per replica, and 1,000 one-transfer batches then wrote **17 GB** more (for about 10 KB of data). The fix, PR #2592, gave 4.25× TPS at 256 transfers per batch while writing 1/12 of the bytes. *(Corrected after review: an earlier version of this note said the 27 GB came from batch size 1.)* The design depends heavily on batching.
- **Sources:** ARCHITECTURE.md, TIGER_STYLE.md, tigerstyle.dev, "A Database Without Dynamic Memory Allocation" (Phil Eaton 2022), docs/concepts/performance, "High-Throughput OLTP in Three Simple Steps" (2026), GitHub issue #2469.

### B2. Ghostty terminal (Mitchell Hashimoto, Zig)
- **Layout:** `PageList` is a doubly-linked list of **page-aligned, page-multiple-sized** blocks. Each page is fully self-contained (cells, styles, graphemes, hyperlinks) and uses **offsets instead of pointers**, with a memory pool for standard-size pages and direct `mmap` for oversized pages. Styles are deduplicated in a ref-counted set per page.
- **Payoffs of that layout:**
  - 2024 devlog 006: precomputed 3-stage codepoint-width lookup table (profiling showed 30% of per-char time went to width) → cat ASCII a further 2.5× faster, Japanese 1.5×. Other changes made cat ASCII 2× faster.
  - PR #13220 (2026): profiling showed ~85% of plain-text time in per-character `Terminal.print` re-answering the same questions. Batching runs of codepoints into row fills with hoisted invariants ("where there is one there are many") took ASCII **128 → 725 MB/s (5.7×)**, ASCII lines 4.2×, mixed unicode 2.4×.
  - PR #13226: driven by a 2.6 GB real asciinema corpus. Bulk style-run fills, vectorized scans, and per-run (not per-cell) ref release raised throughput 276 → 342 MB/s on the real corpus.
  - PR #13264 / 1.4.0: because pages are page-aligned, idle scrollback pages can be compressed and `madvise`d away while virtual addresses stay reserved. **70–90% less resident memory**. On a 7.3 MB corpus: 49.56 MB raw → 3.03 MB encoded, ~100 µs/page, compression runs only when idle. Default scrollback went 10 → 50 MB. A new terminal uses ~16 KiB vs 128 KiB, and every page is 30% smaller (1.4.0 notes).
  - PR #15121: reusing dead IDs in the style set instead of cloning the page to rehash: 1.08–1.34× on styled/hyperlink streams.
- **Cautionary tale:** "Finding and Fixing Ghostty's Largest Memory Leak" (Jan 2026). Non-standard pages were resized only in metadata and then returned to the pool, which led to 37 GB after 10 days for one user. Custom allocators and pools bring their own class of bugs.

### B3. Linux kernel: networking struct cacheline reorganization (Coco Li, Google; merged for 6.8, 2024)
- **What changed:** fast-path fields of `tcp_sock`, `net_device`, `netns_ipv4`, `netdev_queue` were regrouped into read-mostly TX/RX groups (`__cacheline_group_begin/end`) with build-time `CACHELINE_ASSERT_GROUP_MEMBER` checks so they don't regress. The fields had previously been ordered "chronologically, logically and sometimes by cache line access."
- **Before/after table (commit 14006f1d8f docs):** `tcp_sock` was 2664 B / 42 cache lines, with fast path spread over 12 lines but only **396 fast-path bytes (≈8 lines)**. `net_device` 2240 B / 39 lines, fast path on 12 lines, 234 B (≈4 lines).
- **Measured (neper tcp_rr, efficiency = CPU-seconds/throughput):** AMD, 100 Gb/s NIC: **−35% to −44%** CPU per round trip (IPv4 and IPv6). Intel, 200 Gb/s: only **−1% to −5%, and +3.3% at 1k flows**. Good material for "hardware-dependent results".
- Related: Eric Dumazet's `tcp_sock` hole removal (holes 56 → 32 B, saving 24 B, found with `pahole`). His 2016 mlx4 patch rule: `ndo_start_xmit()` "should only dirty one cache line", with an `sp_` prefix for slow-path fields. `pahole --reorganize` on `task_struct` reports "saved 80 bytes and 1 cacheline" (Kernel Recipes slides).
- Tools for the book: `pahole` (C/Zig via DWARF), Rust `-Zprint-type-sizes`, Zig `@sizeOf/@offsetOf` tests, Odin `size_of/offset_of`.

### B4. Columnar / vectorized analytics
- **MonetDB/X100 (Boncz, Zukowski, Nes, CIDR 2005):** the origin of "vector-at-a-time". Volcano-style pipelining, but each `next()` passes ~1000-value column vectors that fit in cache. TPC-H Q1 vs vector size: at size 1 it performs like tuple-at-a-time RDBMSs, it improves by **about two orders of magnitude** as vectors grow, the best size is ~1000 (128–8K all good), and it degrades once vectors exceed cache (at 4M–6M it behaves like column-at-a-time MonetDB/MIL). Selection vectors avoid copying. Primitives are generated from templates, and fetch-joins run in under 2 cycles/tuple.
- **DuckDB:** `STANDARD_VECTOR_SIZE = 2048` is a compile-time constant (a power of two). 2048 × 8 B = 16 KB per vector, which keeps a DataChunk in L1/L2 between operators. A direct descendant of X100.
- **Apache Arrow / ClickHouse:** **[unverified]**. I did not read primary sources in this pass. Mention them only as further reading.
- **Book bridge:** X100's vector-size curve is the database version of "batch size": too small means you pay per-item overhead, too big means you spill out of cache. TigerBeetle batches and Ghostty runs show the same curve.

### B5. V8 hidden classes (Maps) — DOD inside a dynamic runtime
- V8 gives every object a Map (shape) that maps names to fixed offsets. Objects built with the same properties in the same order share a Map. Inline caches at each call site go monomorphic → polymorphic → megamorphic, and the megamorphic state falls back to generic lookup.
- Use it as an aside: even JS rewards "same shape, same order, homogeneous collections". No measured numbers collected. **[unverified]:** any specific speedup.

---

## Part C — Games and ECS

### C1. Mike Acton, "Data-Oriented Design and C++" (CppCon 2014, Insomniac)
- Principles: the purpose of every program is to transform data. If you don't understand the data, you don't understand the problem. "Where there is one, there are many." Solve the most common case first, not the most generic one.
- Worked example: a loop that reads 12 bytes out of a large object wastes most of each cache line. Packing the hot field contiguously lets every fetched line be used. The slide math (~5.33 loops per cache line, sqrt+math ≈ 40 cycles) concludes **"using cache line to capacity = 10× speedup"**. A secondary walkthrough computes ~90% of the cache lines as wasted and ~90% of time spent waiting on memory.
- "Bools in structs… extremely low information density." L2 misses/frame is the most significant metric. "Ignoring inconvenient facts is not engineering; it's dogma."
- The "Three Big Lies" (software is a platform, code designed around a model of the world, code is more important than data) are good for chapter framing.

### C2. Aras Pranckevičius
- **dod-playground (Unity internal lecture 2018):** a sprites "game" refactored from OOP GameObject/Component to ECS/DOD, which made it **10× faster, 5× faster to initialize, and saved 100 MB**. Small enough to port into a book chapter.
- **ToyPathTracer (2018):** C++ scalar → SoA spheres: 100 Mray/s. With SSE 4-wide HitSpheres on SoA data: 187 Mray/s (Threadripper 1950X). Fabian "ryg" Giesen's PR took the SIMD path from 107 → 187 Mray/s mostly by *not computing hit data until the end* (store t + index), plus `_mm_loadu_ps` and remembering which objects emit light. Unity Burst: 82 → 133 Mray/s with manual 4-wide SIMD over SoA. A Rust port by bitshifter reached nearly the C++ speed using SoA sphere data.
- **ToyMeshPathTracer:** shows the counterpoint. A BVH (algorithm) gave ~370× (18.9 → 6978 Krays/s), naive SIMD only another 1.28×. Layout work does not replace a better algorithm.

### C3. Unity DOTS (Lucas Meijer 2019; Megacity)
- Before: GameObjects and components were "heavy C++ objects", with a C# wrapper per object, a global id→pointer list behind a mutex, and objects anywhere in memory: "lots of cache misses".
- After: **archetypes** (entities with an identical component set) stored in **16 KiB chunks**, SoA per component within a chunk. Systems declare queries up front. Removal swaps the last entity in to fill the gap. Loading/streaming is "loading raw bytes from disk and using them as-is", which the blog gives as the reason Megacity loads in seconds on a phone.
- Megacity (2018–19): **4.5 M mesh renderers, 5,000 dynamic vehicles, 200,000 unique building objects, 100,000 audio sources**, built by a small team in about two months. Unity claims 60 fps (press summaries). These are capability numbers, not a before/after benchmark.
- V Rising (Stunlock): 160K+ interactable objects streamed, **1,600 ECS systems**. Unity case-study page, marketing source.
- Honest counterpoints: a CipSoft thesis evaluation found DOTS netcode "stable and fast" for several hundred users, but "ECS adds both performance and complexity", with poor docs. In the Unity roundtable, devs advise "don't overthink or overengineer… split up later."

### C4. Overwatch ECS (Timothy Ford, GDC 2017)
- Primary talk is behind the GDC Vault paywall. Details come from full translations (lfzxb.top, max2d.com, mo4tech).
- Entity = 32-bit ID. Components = data only (hundreds of subclasses; polymorphism used only for lifecycle). Systems = behavior with no state.
- The client had about **46 systems and 103 components**. The surprise: **~40% of all components were singletons** (input, etc.). System state that seemed private nearly always turned out to be shared, and shared behavior moved into "utility functions" with side effects funneled to a few call sites.
- Motivation was *managing complexity and determinism for netcode* (prediction/rollback), not raw speed. This is useful for a "DOD is about design, not only cache" chapter.

### C5. Bitsquid/Stingray and Our Machinery (Niklas Frykholm / Niklas Gray)
- **Bitsquid "Building a Data-Oriented Entity System" (2014):** an entity is just `{unsigned id}` with a generation for weak references. There is no component object. A `ComponentManager` per type owns the data and lays it out as SoA in **one allocation** with arrays pointing into it. Destruction GC scans a few random entities per frame ("costs almost nothing if no destroyed entities"). Transform hierarchy lives only in the TransformComponent. Resources compile into binary blobs that are used directly with no deserialization.
- **Our Machinery "Data Structures Part 1: Bulk Data" (Gray, 2019):** choices, not dogma:
  - Deletion: shift (preserves order, O(n)), **swap-and-pop** (dense, but moves objects so you need an ID→index table), or **holes + in-array free list** (stable indices, and worst case = full array = no holes).
  - Allocation: `std::vector` doubling causes stalls with huge arrays, up to 50% waste, and pointer invalidation bugs. Alternatives: fixed-size blocks (16 KiB), geometric blocks you keep, or one **huge virtual-memory reservation** (contiguous and stable).
  - Weak pointers = `{id, generation}`.
  - AoS vs SoA: SoA can make `tick()` touch 1/10 the memory (×10 if memory-bound), but you get ×10 **or** SIMD, not ×80. Pitfall: page-aligned SoA arrays alias to the same cache set (10 fields in an 8-way cache). Fix: **AoSoA groups of 8**.
  - His verdict: *"in most cases, the performance improvements are not worth the extra hassle"*. Default to AoS with holes and stable pointers. Use packed SoA/AoSoA only for SIMD-hot systems (culling, particles), or convert AoS → temporary SoA per 16 KiB block for one algorithm.
- **Molecular Matters (Stefan Reinalter, 2011–13):** mesh data split by usage. Skeletal hierarchy flattened into depth-first arrays so a parent comes before its children, which makes local→global a single linear loop with no recursion. IDs/handles for external references. Clear data **ownership** as a DOD enabler.

### C6. ECS libraries and benchmarks (EnTT, flecs, Bevy, hecs…)
- Two storage families: **archetype/table** (Unity, flecs, Bevy default, Unreal Mass) iterates fastest, while add/remove moves rows. **Sparse set** (EnTT, Bevy opt-in `#[component(storage = "SparseSet")]`) gives O(1) add/remove, and iteration slows when you intersect many sets.
- Peer-reviewed: Staffordshire 2025 "Run-time performance comparison of sparse-set and archetype ECSes" (Game of Life). There was no significant difference at 100 entities. Archetype was significantly faster at 10K–50K entities, and sparse set had cheaper modifications.
- Bench numbers (use with heavy caveats): SkyECS cross-library CI run, "prepared iteration 1M": Flecs 797 µs, hecs 850 µs, Bevy 954 µs, Shipyard 1.77 ms. abeimler/ecs_benchmark: EnTT, flecs, gaia, pico_ecs within ~2× of each other for 4K–16K entities. Every repo warns to benchmark your own use case.
- **EnTT pointer stability** (skypjack "ECS back and forth" 12–13): tombstones instead of swap-and-pop give stable pointers but add a check on every iteration. The trade-off is made explicit.
- **Rust specifics:** Catherine West (kyren), RustConf 2018 closing keynote: OOP-style game state fights the borrow checker. **Generational indices** + Vec storage lead naturally to an ECS. "Rust, by design, makes certain patterns more painful… This is a GOOD thing." This is the Rust justification chapter for the book.

---

## Part D — Languages that bake in DOD

| Language | Feature | Notes |
|---|---|---|
| **Zig** | `std.MultiArrayList(T)` (comptime SoA), `@sizeOf`, packed structs, arbitrary-width ints (`u5`, `u7`), allocator-per-call | Zig issue #2634 (Jai-style SoA) was closed as done via MultiArrayList. A 24-byte token AoS ×100 = 2400 B vs 1700 B in MultiArrayList (Hohmann). |
| **Odin** | `#soa[N]T`, `#soa[]T`, `#soa[dynamic]T`, `soa_zip`/`soa_unzip`. Same indexing syntax as AoS. | Runtime layout (core_builtin_soa.odin): fixed array = struct of `[N]Ti`. Slice = one pointer per field + len. Dynamic = pointers + len + cap + allocator, one allocation with per-field aligned offsets. Downside (forum): a `#soa[]` slice is N+1 words and random whole-record access touches N places. |
| **Jai** | `struct SOA` switches layout without changing code | From the community Jai primer. The language is still in closed beta. |
| **Rust** | No built-in SoA. `soa_rs` / derive crates, `Vec` + newtype indices, `-Zprint-type-sizes`, generational arenas | Feldman's complaint: the ecosystem assumes a global allocator. Bevy `Table` = "column-oriented structure-of-arrays storage". |
| **Carbon** | Toolchain is DOD; the language follows an "information accumulation" principle so one pass is enough | The language design helps the compiler's data layout. |
| **Mojo** | **[unverified]**, not researched | omit or flag |

---

## Part E — Critiques and limits (for the balanced chapter)

1. **The costs are real and documented by practitioners themselves.**
   - Gray (Our Machinery): SoA is "not worth the extra hassle" in most cases. Default to AoS.
   - Nethercote: AST shrinks were "a pain, requiring multiple iterations". He abandoned a token shrink that made code uglier for negligible gain.
   - Carbon/Richard Smith: "DOD is extra work, but often worth it."
   - Zig 0.8.0: the parser change was +20.8K/−16.6K lines over 176 commits. Encoded ASTs need tag-specific accessors (`fullCall`, `fullVarDecl`…), and "it's clever but can be confusing to implement from scratch" (secondary blog).
2. **Modifiability trade-off.** Lucian Radu Teodorescu (ACCU Overload 2022): "the more data-oriented a system becomes, the harder it is to make a change when the data needs to change." Counter-view from Noel Llopis (Games From Within, 2009): transform-focused code gives small functions with few dependencies, and the main drawback is unfamiliarity.
3. **SoA is not free.** Random whole-record access touches N arrays (Odin forum). Page-aligned SoA arrays can cause cache-set conflicts (Gray). SoA fights "holes" under SIMD. Sparse sets slow down multi-component iteration, and archetypes make add/remove expensive. Ghostty's pool/oversized-page split produced its biggest memory leak.
4. **ECS ≠ DOD.** Sebastian Schöner: "DOD is not just ECS and fewer cache misses"; ECS is *one* solution DOD might produce for certain requirements. Voxagon (Dennis Gustafsson, 2025): ECS adds complexity, is hard to debug, has scattered performance problems, and "performance can be better or worse depending on the implementation". A practical guide's rule of thumb: with 50–200 entities you almost certainly don't need ECS for performance. Overwatch adopted ECS for complexity/netcode, not speed.
5. **Algorithm first.** Aras's mesh path tracer: BVH ~370×, SIMD 1.28×. Zig 0.10: DOD cut memory 3.5× but sped the whole build up only 7% because LLVM dominated.
6. **Hardware dependence.** Linux netdev: −40% on AMD and ~−5% (or +3%) on Intel for the same patch.
7. **"Clean code" debate.** Casey Muratori (2023): on a shape-area loop, vtable ~35 cycles/shape → switch 24 (1.5×) → coefficient table 3–3.5 (**10×**). With a corner-count term the table is ~15×, and AVX versions reach 20–25×. His follow-up concedes the demo is microbenchmark-scale, says DOD proponents objected that he *didn't* show segregated arrays, and "I do not disagree with them at all." Critics of premature optimization (Knuth's line as commonly quoted, e.g. Better Programming article) argue that developer time often outweighs CPU time. Book position: measure, then design the data. Knuth's full quote is about the 97% vs 3%, and DOD is about knowing which 3% from the data's shape and volume.
8. **Batching shifts costs to latency or API shape.** TigerBeetle under low load wrote 17 GB per replica for 1,000 one-transfer batches (issue #2469, later mitigated by PR #2592). Its clients now autobatch to hide that.

---

## Part F — Capstone project: options and recommendation

### Candidates
| Option | DOD concepts exercised | Measurable? | Rust | Zig | Odin | Risk |
|---|---|---|---|---|---|---|
| **1. Mini tokenizer + parser + "AstGen" (Zig/Carbon-style)** | SoA tokens (u8 tag + u32 start), u32 node indices, `extra_data`, multiple encodings, postorder/flat tree, string interning, arena/ zero-parse cache to disk, parallel per-file | Excellent: bytes/token, bytes/node, lines/s, peak RSS, `perf stat` cache-misses, all with published reference numbers (5 B/token, 13→15.6 B/node, 8.9 M lines/s, Carbon 10 M lines/s goal) | Good (Vec per field, newtype indices; no built-in SoA → teaches the manual pattern; borrow checker loves indices) | Native (std.zig.Ast is the reference implementation to read) | Good (`#soa[dynamic]Token`, `#soa[dynamic]Node`) | Parsing theory can eat chapters; need a tiny grammar |
| **2. Particles/boids + spatial hash grid** | AoS vs SoA vs AoSoA, hot/cold split, SIMD, counting-sort spatial hash, swap-and-pop death, batching | Very good, and visual | Good (needs a SIMD crate or autovec) | Good (`@Vector`) | Excellent (`#soa`, built-in vector math, raylib vendored) | Graphics setup differs per language; the speedup mostly shows SIMD + one transform |
| **3. Tiny ECS** | Generational handles, sparse set vs archetype, queries, bulk-data allocation | Medium. Easy to produce misleading microbenchmarks | Very good (kyren's story) | Good | Good | Library design dominates; "ECS ≠ DOD" critique applies; easy to over-engineer |
| 4. Columnar mini query engine (X100-style) | Column vectors, selection vectors, vector-size sweep | Excellent curve (vector size vs time) | Good | Good | Good | Further from the book's game/compiler audience |

### Recommendation: **Option 1 as the main capstone, with Option 2 as the mid-book project.**

Why the tokenizer/parser works best across all three languages:
1. **It has a published baseline to reproduce.** Readers can compare their bytes/token and bytes/node with Zig's 64 → 5 and 120 → 15.6, and their lines/s with 8.9 M (Zig AstGen) and 10 M (Carbon target). No other option has primary-source numbers this precise.
2. **It uses every technique in the book in one program:** indices instead of pointers (u32 node/token IDs), SoA (token tags separate from starts), out-of-band data (`extra_data`, side tables), encodings over polymorphism (`call_one` vs `call`), recompute over store (token end/line/col computed lazily like Carbon's token-as-location), arena allocation, batch/flat output, and zero-copy serialization (Roc/Zig ZIR: 4 arrays → `writev`).
3. **It shows how each language differs, and that is a feature:** Zig `MultiArrayList` (comptime), Odin `#soa` (language built-in), Rust hand-written SoA + `NonZeroU32` newtypes + `static_assertions` on size (rustc's `static_assert_size!` habit). The borrow checker friction that pointer trees cause in Rust *goes away* with indices. That makes kyren's argument concretely.
4. **It is deterministic and needs no graphics.** Benchmarks are reproducible with `hyperfine` + `perf stat` (or `valgrind --tool=cachegrind`), and the input generator can be the Carbon-style "random source with parameterized distributions".
5. **It has a built-in naive baseline:** chapter N builds `Box<Node>`/`*Node`/`^Node` pointer trees first, so the measured before/after belongs to the reader (Tweede Golf showed even a small Rust version gives a visible 12% memory and 70% speed difference vs boxing).

Suggested scope: a JSON-like or tiny expression/`let`/`fn` language (~15 node kinds). Stages: (a) tokenizer → `Tokens{tag: []u8, start: []u32}`; (b) Pratt parser → `Nodes{tag, main_token, lhs, rhs}` + `extra: []u32`; (c) an evaluator or "AstGen" to a flat bytecode/IR; (d) multithreaded per-file + disk cache. Checkpoints: print `@sizeOf`/`size_of`/`mem::size_of` per type, nodes/token ratio, MB/s, RSS, cache misses, before and after each step.

Why boids is second: it is the best *visual* demonstration of AoS → SoA → AoSoA + SIMD + spatial hash, and Odin's `#soa` + vendored raylib make it trivial there. But its headline speedups mostly come from one hot loop. It also lacks the "structure (tree) as indices" lesson, which is the hardest and most important DOD idea for systems programmers.

Why ECS is not the capstone: it risks teaching "DOD = ECS" (Schöner, Voxagon critiques). It is better as a chapter sidebar showing sparse set vs archetype trade-offs, with generational handles reused from the Bulk Data chapter.

---

## SOURCES (all seen in this research pass)

| # | URL | Title | Author | Year | Note |
|---|---|---|---|---|---|
| 1 | https://ziglang.org/download/0.8.0/release-notes.html | Zig 0.8.0 Release Notes ("Reworked Memory Layout", MultiArrayList, Whole-File AST Lowering) | Andrew Kelley / Zig team | 2021 | Primary: token 5 B, node 13 B, parser −15% cache misses/−22% wall, ZIR −39% wall/−40% mem, 8.9 M lines/s |
| 2 | https://www.josherich.me/podcast/andrew-kelley-practical-data-oriented-design-dod | Andrew Kelley — Practical Data Oriented Design (transcript) | Andrew Kelley (talk, Handmade Seattle 2021) | ~2021 | Transcript: 64→5 B tokens, 120→15.6 B nodes, ZIR 54→20.3 B, monster examples |
| 3 | https://randomaccessmemory.cc/t/andrew-kelley-a-practical-guide-to-applying-data-o | RAM summary of Kelley talk | — | 2024 | Secondary summary; numbers match #2 |
| 4 | https://mitchellh.com/zig/parser | Zig Parser | Mitchell Hashimoto | 2022 | MultiArrayList usage in std.zig.Ast |
| 5 | https://kristoff.it/blog/zig-self-hosted-now-what | Zig Is Self-Hosted Now, What's Next? | Loris Cro | 2022 | 9.6 GB → 2.8 GB; 7% faster; LLVM dominates |
| 6 | https://ziglang.org/download/0.10.0/release-notes.html | Zig 0.10.0 Release Notes | Zig team | 2022 | Peak RSS 9.6→2.8 GiB, 43→40 s (excerpt) |
| 7 | https://github.com/ziglang/zig/wiki/Self-Hosted-Compiler-Upgrade-Guide/2d79eb24d2c03b98faaa6bf384e888d35c01a4e5 | Self Hosted Compiler Upgrade Guide | Andrew Kelley | 2022 | Earlier figures 9.1→2.7 GiB, 1.5× |
| 8 | https://ziglang.org/download/0.15.1/release-notes.html | Zig 0.15.1 Release Notes | Zig team | 2025 | x86 backend ~5× faster debug compile; 13.8→10.0 s (excerpt) |
| 9 | https://ziglang.org/devlog/2025 | Zig Devlog 2025 | Kelley, mlugg | 2025 | x86 backend default in Debug (excerpt) |
| 10 | https://andreashohmann.com/zig-struct-of-arrays | Zig structs of arrays | Andreas Hohmann | 2024 | MultiArrayList 2400→1700 B example |
| 11 | https://github.com/ziglang/zig/issues/2634 | Explicit support for AoS/SoA | HalosGhost (issue) | 2019 | Jai SOA reference; closed |
| 12 | https://chandlerc.blog/slides/2023-cppnow-compiler/index.html | Modernizing Compiler Design for Carbon's Toolchain | Chandler Carruth | 2023 | 10M/1M/0.1M lines/s goals, token=location, postorder parse tree, 48 Clang nodes |
| 13 | https://chandlerc.blog/slides/2026-ndc-toronto-carbon-benchmarking/index.html | Benchmarking & Optimizing the Carbon Compiler | Chandler Carruth | 2026 | musttail dispatch, SIMD newline scan; no achieved lines/s in what I read |
| 14 | https://llvm.org/devmtg/2024-04/slides/LightningTalks/Smith-Carbons-high-level-semanticIR.pdf | SemIR: Carbon's high-level semantic IR | Richard Smith | 2024 | 12 B/parse node, 16 B/inst, "DOD is extra work, but often worth it" |
| 15 | https://docs.carbon-lang.dev/toolchain/docs/ | Carbon Toolchain architecture | Carbon team | 2025 | Distinct steps, vectorized storage |
| 16 | https://nnethercote.github.io/2023/03/24/how-to-speed-up-the-rust-compiler-in-march-2023.html | How to speed up the Rust compiler in March 2023 | Nicholas Nethercote | 2023 | ast::Expr 104→72 B |
| 17 | https://nnethercote.github.io/2022/10/27/how-to-speed-up-the-rust-compiler-in-october-2022.html | … October 2022 | Nicholas Nethercote | 2022 | FnAbi/ArgAbi/Attribute shrinks; cites Zig |
| 18 | https://blog.mozilla.org/nnethercote/2019/10/11/how-to-speed-up-the-rust-compiler-some-more-in-2019 | … some more in 2019 | Nicholas Nethercote | 2019 | 128-byte memcpy threshold |
| 19 | https://blog.mozilla.org/nnethercote/2018/06/05/how-to-speed-up-the-rust-compiler-some-more-in-2018/ | … some more in 2018 | Nicholas Nethercote | 2018 | Token 32→24, abandoned 16 B |
| 20 | https://blog.mozilla.org/nnethercote/2016/11/23/how-to-speed-up-the-rust-compiler-some-more | … some more (2016) | Nicholas Nethercote | 2016 | Heap allocs; peak mem −9%/−10% |
| 21 | https://nnethercote.github.io/2026/07/31/how-to-speed-up-the-rust-compiler-in-july-2026.html | … July 2026 | Nicholas Nethercote | 2026 | Expr 72→64 B; 136→104 B −40% |
| 22 | https://nnethercote.github.io/2026/11/04/how-to-speed-up-the-rust-compiler-in-november-2026.html | … November 2026 | Nicholas Nethercote | 2026 | Span changes; max-RSS −7% |
| 23 | https://rtfeldman.com/rust-to-zig | How Our Rust-to-Zig Rewrite is Going | Richard Feldman | 2026 | Roc: u32 indices, SoA, zero-parse cache, 35 ms incremental |
| 24 | https://tweedegolf.nl/en/blog/88/data-oriented-design | Optimizing a parser/compiler with data-oriented design: a case study | Tweede Golf | ~2022 | Rust; −12% heap; boxed ~70% slower |
| 25 | https://repository.tudelft.nl/file/File_5748302e-41df-4214-b489-32eca09e39bf?preview=1 | Memory Layout Optimisation on Abstract Syntax Trees | TU Delft student thesis | ~2024 | >12× AST memory reduction on one input |
| 26 | https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md | TigerBeetle ARCHITECTURE.md | TigerBeetle | 2024+ | Static alloc, 128 B transfer, homogeneous batches |
| 27 | https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md | TIGER_STYLE.md | TigerBeetle | — | No allocation after init; 70-line functions |
| 28 | https://tigerstyle.dev/ | TigerStyle | TigerBeetle | — | "Use fixed-size cache line aligned structs" |
| 29 | https://tigerbeetle.com/blog/2022-10-12-a-database-without-dynamic-memory | A Database Without Dynamic Memory Allocation | Phil Eaton | 2022 | No serialization; fixed limits |
| 30 | https://docs.tigerbeetle.com/concepts/performance | Performance | TigerBeetle | — | 8,190 per batch, one tight loop |
| 31 | https://tigerbeetle.com/blog/2026-09-17-performant-use-of-tigerbeetle | High-Throughput OLTP in Three Simple Steps | Tobi, Maxi (TigerBeetle) | 2026 | 454,518 tx/s; 100× |
| 32 | https://github.com/tigerbeetle/tigerbeetle/issues/2469 | LSM performance poor when batches are small | gladkikhartem | 2024 | 27 GB for 1M transfers in batches of 1,000; +17 GB for 1,000 one-transfer batches; PR #2592 fix |
| 33 | https://backend.how/posts/1b-payments-per-day | 1B Payments/Day — TigerBeetle & PostgreSQL | backend.how | 2026 | Third-party M4 measurements (excerpt) |
| 34 | https://mitchellh.com/writing/ghostty-devlog-006 | Ghostty Devlog 006 | Mitchell Hashimoto | 2024 | Codepoint-width LUT, 2×/2.5× |
| 35 | https://github.com/ghostty-org/ghostty/pull/13220 | terminal: various VT processing optimizations (~1.5x to ~6x) | Mitchell Hashimoto | 2026 | 128→725 MB/s |
| 36 | https://github.com/ghostty-org/ghostty/pull/13226 | terminal: VT throughput optimizations from real-world dataset | Mitchell Hashimoto | 2026 | 276→342 MB/s real corpus |
| 37 | https://github.com/ghostty-org/ghostty/pull/13264 | terminal: scrollback page compression | Mitchell Hashimoto | 2026 | 93.9% savings on test corpus |
| 38 | https://github.com/ghostty-org/ghostty/pull/15121 | terminal: RefCountedSet reuses dead IDs | Mitchell Hashimoto | 2026 | 1.08–1.34× |
| 39 | https://ghostty.org/docs/install/release-notes/1-4-0 | Ghostty 1.4.0 Release Notes | Ghostty | 2026 | 16 KiB vs 128 KiB new terminal; pages −30% |
| 40 | https://mitchellh.com/writing/ghostty-memory-leak-fix | Finding and Fixing Ghostty's Largest Memory Leak | Mitchell Hashimoto | 2026 | PageList; pool bug cautionary tale |
| 41 | https://lwn.net/Articles/951321 | Analyze and Reorganize core Networking Structs to optimize cacheline consumption (v7) | Coco Li | 2023 | AMD −35..−44% CPU/op; Intel ~−1..−5% |
| 42 | https://upd.dev/kernel/linux/commit/14006f1d8fa2 | Documentations: Analyze heavily used Networking related structs | Coco Li | 2023 | tcp_sock 42 lines, 396 fast-path bytes |
| 43 | https://www.phoronix.com/news/Linux-6.8-Networking | Linux 6.8 Network Optimizations… ~40% | Michael Larabel | 2024 | Merge context |
| 44 | https://speakerdeck.com/ennael/assisted-reorganization-of-data-structures | Assisted reorganization of data structures (Kernel Recipes) | Kernel Recipes speaker (pahole author's talk; author not confirmed on page) | 2024 | pahole --reorganize, cacheline groups, Dumazet tcp_sock holes |
| 45 | http://www.mail-archive.com/netdev@vger.kernel.org/msg138751.html | mlx4: reorganize struct mlx4_en_tx_ring | Eric Dumazet | 2016 | "dirty only one cache line" |
| 46 | https://15721.courses.cs.cmu.edu/spring2024/papers/04-execution1/boncz-cidr2005.pdf | MonetDB/X100: Hyper-Pipelining Query Execution | Boncz, Zukowski, Nes | 2005 | Vector size ~1000 optimal |
| 47 | https://ir.cwi.nl/pub/11098/11098B.pdf | MonetDB/X100 — A DBMS In The CPU Cache | Zukowski, Boncz et al. | 2005 | Two orders of magnitude from vector size |
| 48 | https://yoichiozaki.github.io/en/blog/duckdb-internals | Inside DuckDB — Vectorized Execution… | Yoichi Ozaki | 2026 | STANDARD_VECTOR_SIZE 2048 = 16 KB |
| 49 | https://blobs.duckdb.org/slides/DiDi-07.pdf | Design and Implementation of DuckDB Internals: Vectorized Query Execution | Torsten Grust | 2026 | Vectors in L1, chunks in L2 |
| 50 | https://neil3d.github.io/assets/img/ecs/DOD-Cpp.pdf | Data-Oriented Design and C++ (slides) | Mike Acton | 2014 | 10× from using cache line to capacity; bools in structs |
| 51 | https://accu.org/journals/overload/30/167/teodorescu | Revisiting Data-Oriented Design | Lucian Radu Teodorescu | 2022 | Principles; modifiability trade-off |
| 52 | https://alessandrominali.github.io/data_oriented_design_canonical_example.html | Data-Oriented Design: Canonical Example (C) | Alessandro Minali | 2025 | Walkthrough of Acton's 90% waste math |
| 53 | https://github.com/aras-p/dod-playground | dod-playground | Aras Pranckevičius | 2018 | 10× faster, 5× init, −100 MB |
| 54 | https://github.com/aras-p/ToyPathTracer | ToyPathTracer | Aras Pranckevičius | 2018+ | Mray/s table SoA/SIMD |
| 55 | https://aras-p.info/blog/2018/04/13/Daily-Pathtracer-9-A-wild-ryg-appears/ | Daily Pathtracer 9: A wild ryg appears | Aras Pranckevičius | 2018 | 107→187 Mray/s |
| 56 | https://aras-p.info/blog/2018/10/29/Pathtracer-16-Burst-SIMD-Optimization | Pathtracer 16: Burst SIMD Optimization | Aras Pranckevičius | 2018 | 84→133 Mray/s |
| 57 | https://github.com/aras-p/ToyMeshPathTracer | ToyMeshPathTracer | Aras Pranckevičius | 2019 | BVH ≫ SIMD |
| 58 | https://bitshifter.github.io/2018/06/04/simd-path-tracing/ | Optimising path tracing with SIMD | Cameron Hart (bitshifter) | 2018 | Rust port, SoA spheres |
| 59 | https://blog.unity.com/technology/on-dots-entity-component-system | On DOTS: Entity Component System | Lucas Meijer | 2019 | Archetypes, 16 KiB chunks |
| 60 | https://www.dsogaming.com/news/unity-engine-megacity-tech-demo-is-now-available-for-download | Megacity tech demo available | John Papadopoulos | 2019 | 4.5M renderers, 5K vehicles, 100K audio |
| 61 | https://unity.com/releases/2019-2/programmer-tools | Unity 2019.2 programmer tools | Unity | 2019 | DSPGraph, 100K emitters in Megacity |
| 62 | https://activation.unity3d.com/vn/resources/stunlock-studios-v-rising | How Stunlock Studios Built V Rising | Unity | ~2024 | 1,600 ECS systems (marketing) |
| 63 | https://discussions.unity.com/t/700-concurrent-users-in-mmo-style-tech-demo-with-netcode-for-entities/951434 | 700 concurrent users… Netcode for Entities | bfelixx (CipSoft) | 2024 | "ECS adds both performance and complexity" |
| 64 | https://unity.com/blog/engine-platform/dots-webinar-roundtable-q-a | Data-oriented design roundtable | Fergus Baird (Unity) | 2024 | "don't overthink or overengineer" |
| 65 | https://www.lfzxb.top/ow-gdc-gameplay-architecture-and-netcode/index.html | 《守望先锋》架构设计和网络同步 (translation of Ford GDC 2017) | Timothy Ford (orig.), translator | 2017/2021 | 46 systems, 103 components, 40% singletons |
| 66 | https://www.mo4tech.com/overwatchs-architecture-is-designed-to-synchronize-with-the-web.html | Overwatch Gameplay Architecture and Netcode (English translation) | Timothy Ford (orig.) | 2017/2024 | Same figures in English |
| 67 | https://ruby0x1.github.io/machinery_blog_archive/post/data-structures-part-1-bulk-data/index.html | Data Structures Part 1: Bulk Data (archive) | Niklas Gray | 2019 | Holes vs swap-pop, VM reservation, AoSoA-8, "not worth the hassle" |
| 68 | https://bitsquid.blogspot.com/2014/08/building-data-oriented-entity-system.html | Building a Data-Oriented Entity System (part 1) | Niklas Frykholm | 2014 | Entity = id + generation |
| 69 | http://bitsquid.blogspot.com/2014/09/building-data-oriented-entity-system.html | … (Part 2: Components) | Niklas Frykholm | 2014 | SoA in single buffer |
| 70 | https://bitsquid.blogspot.com/2014/10/ | … (Part 4: Entity Resources) | Niklas Frykholm | 2014 | Blob resources, no deserialization |
| 71 | https://blog.molecular-matters.com/2013/02/22/adventures-in-data-oriented-design-part-2-hierarchical-data | Adventures in DOD Part 2: Hierarchical data | Stefan Reinalter | 2013 | Flattened skeleton |
| 72 | https://blog.molecular-matters.com/2013/07/24/adventures-in-data-oriented-design-part-3c-external-references | Adventures in DOD Part 3c: External References | Stefan Reinalter | 2013 | IDs vs handles |
| 73 | https://blog.molecular-matters.com/2013/05/02/adventures-in-data-oriented-design-part-3a-ownership | Adventures in DOD Part 3a: Ownership | Stefan Reinalter | 2013 | Ownership enables DOD |
| 74 | https://blog.molecular-matters.com/2011/11/03/adventures-in-data-oriented-design-part-1-mesh-data-3/ | Adventures in DOD Part 1: Mesh data | Stefan Reinalter | 2011 | DOD + OOP coexisting |
| 75 | https://github.com/abeimler/ecs_benchmark | ecs_benchmark | Andreas Beimler | 2023+ | C++ ECS comparisons |
| 76 | https://github.com/jz315/SkyECS/blob/main/benches/BENCHMARKS.md | SkyECS BENCHMARKS | jz315 | 2026 | Cross-lib 1M iteration numbers |
| 77 | https://eprints.staffs.ac.uk/9315/1/cgvc20251224.pdf | Run-time Performance Comparison of Sparse-set and Archetype ECSes | Staffordshire Univ. authors | 2025 | Peer-reviewed; archetype faster at ≥10K |
| 78 | https://skypjack.github.io/2021-08-29-ecs-baf-part-12 | ECS back and forth Part 12 | Michele Caini (skypjack) | 2021 | Pointer stability, tombstones |
| 79 | https://skypjack.github.io/2021-10-09-ecs-baf-part-13 | ECS back and forth Part 13 | Michele Caini (skypjack) | 2021 | Tombstone check cost |
| 80 | https://kyren.github.io/2018/09/14/rustconf-talk.html | My RustConf 2018 Closing Keynote | Catherine West | 2018 | Generational indices → ECS in Rust |
| 81 | https://docs.rs/bevy/latest/bevy/ecs/storage/struct.SparseSet.html | bevy::ecs::storage::SparseSet | Bevy | 2026 | Dense + sparse arrays |
| 82 | https://dev-docs.bevy.org/bevy/ecs/storage/index.html | bevy::ecs::storage | Bevy | 2026 | Tables = columnar SoA |
| 83 | https://bevy-cheatbook.github.io/patterns/component-storage.html | Component Storage (Table/Sparse-Set) | Bevy Cheat Book | ~2023 | Trade-offs |
| 84 | https://forum.odin-lang.org/t/how-soa-works-under-the-hood/383/2 | How SOA works under the hood? | Barinzaya (Odin forum) | 2024 | #soa layout pros/cons |
| 85 | https://github.com/odin-lang/Odin/blob/master/base/runtime/core_builtin_soa.odin | core_builtin_soa.odin | Odin | 2026 | Runtime SoA layout |
| 86 | http://www.odin-lang.org/ | Odin Programming Language | gingerBill | — | "The Data-Oriented Language…" |
| 87 | https://zylinski.se/posts/a-programming-language-for-me | Odin: A programming language made for me | Karl Zylinski | ~2024 | #soa in practice |
| 88 | https://github.com/BSVino/JaiPrimer/blob/master/JaiPrimer.md | Jai Primer | BSVino (community) | ~2015 | struct SOA |
| 89 | https://www.computerenhance.com/p/clean-code-horrible-performance | "Clean" Code, Horrible Performance | Casey Muratori | 2023 | 1.5× / 10× / 15× / 20–25× |
| 90 | https://www.computerenhance.com/p/response-to-a-reporter-regarding | Response to a Reporter Regarding "Clean Code, Horrible Performance" | Casey Muratori | 2023 | Concedes scope; agrees with DOD critique |
| 91 | https://blog.s-schoener.com/2019-06-09-data-oriented-design | Data Oriented Design — An Interpretation | Sebastian Schöner | 2019 | DOD ≠ ECS |
| 92 | https://blog.voxagon.se/2025/03/28/thoughts-on-ecs.html | Thoughts on ECS | Dennis Gustafsson (Voxagon) | 2025 | ECS cons |
| 93 | https://gamesfromwithin.com/data-oriented-design/ | Data-Oriented Design (Or Why You Might Be Shooting Yourself in The Foot With OOP) | Noel Llopis | 2009 | Benefits and drawbacks |
| 94 | https://mojolabs.nz/entity-component-system-for-humans-when-you-actually-need-it | ECS for Humans: When You Actually Need It | Mojo Labs | ~2025 | 50–200 entities rule of thumb |
| 95 | https://betterprogramming.pub/avoiding-premature-software-abstractions-8ba2e990930a | Avoiding Premature Software Abstractions | Jonas Tulstrup | ~2021 | Premature-optimization viewpoint |
| 96 | https://github.com/v8/v8/blob/main/docs/runtime/hidden-classes-and-ics.md | Hidden Classes and Inline Caches in V8 | V8 team | 2026 | Maps + IC states |
| 97 | https://mathiasbynens.be/notes/shapes-ics | JavaScript engine fundamentals: Shapes and Inline Caches | Mathias Bynens, Benedikt Meurer | 2018 | Shapes across engines |
| 98 | https://lwn.net/Articles/255364 | Memory part 5: What programmers can do | Ulrich Drepper | 2007 | Struct field ordering; 10× matmul example |
| 99 | https://aristeia.com/TalkNotes/codedive-CPUCachesHandouts.pdf | CPU Caches and Why You Care (handouts) | Scott Meyers | 2013 | Traversal order, false sharing |

Not verified in this pass (don't cite without checking): Apache Arrow format spec, ClickHouse docs, EnTT/flecs authors' own benchmark pages, Insomniac-specific measurements beyond Acton's slides, Mojo, Carbon achieved lines/s, the Megacity "60 fps" figure from a primary Unity source.
