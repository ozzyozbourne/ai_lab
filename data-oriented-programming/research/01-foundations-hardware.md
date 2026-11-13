# Research slice 01 — Foundations & Hardware

For: book on performance-oriented Data-Oriented Design (Acton/Kelley lineage), examples in Rust, Zig, Odin.
Compiled 2026-11-13. Every URL in SOURCES was opened (O) or seen in search results (S). Anything I could
not confirm against a primary source is marked **[unverified]**.

---

## 1. Origins & philosophy — timeline

| Year | Event | Notes |
|---|---|---|
| 1975 | Fred Brooks, *Mythical Man-Month*: "Show me your flowcharts and conceal your tables…" | Proto-DOD quote; cited in the ACCU article (Teodorescu 2022). |
| Dec 1994 / Mar 1995 | Wulf & McKee, "Hitting the Memory Wall: Implications of the Obvious" | Coined "memory wall". CPU speed was improving about 80%/yr and DRAM about 7%/yr, so they projected the average cycles per memory access at 1.52 (2000), 8.25 (2005), 98.8 (2010). |
| 2007 | Ulrich Drepper, "What Every Programmer Should Know About Memory" (LWN serial Sept–Nov, 114-page PDF Nov 21) | The canonical hardware reference. |
| Sept 2008 | Llopis, "Managing Data Relationships" (Game Developer, Inner Product column) | Indices vs pointers. |
| Sept 2009 | **Noel Llopis, "Data-Oriented Design (Or Why You Might Be Shooting Yourself in The Foot With OOP)"**, Game Developer magazine; blog reprint Dec 4 2009 | The article that **named** DOD (Fabian credits it: "only officially given a name by Noel Llopis in his September 2009 article"). |
| 2009 (GCAP Australia, slides posted Dec 2009) | **Tony Albrecht, "Pitfalls of Object Oriented Programming"** (Sony CEE R&D) | PS3 scene-tree case study: 19.6 → 12.9 → 4.8 → 3.3 ms. |
| Sept 2010 / Jan 2011 | Llopis, "Data-Oriented Design Now And In The Future" (Game Developer; Intel-sponsored reprint on Gamasutra Apr 2011) | Follow-up responding to criticism. |
| 2013 (beta) / Oct 2018 (print) | **Richard Fabian, *Data-Oriented Design: Software Engineering for Limited Resources and Short Schedules*** (ISBN 978-1-138-03545-4); free reduced online version at dataorienteddesign.com | Connects DOD to relational normalization ("existential processing", tables). |
| Sept 30 2014 | **Mike Acton, "Data-Oriented Design and C++"**, CppCon 2014 keynote (Insomniac Games) | ~800k YouTube views; the "three big lies" talk. |
| 2017 | Albrecht, "Pitfalls of OOP – Revisited" (Riot Games) | Same scene tree, 55,000 objects; data layout still matters on modern x86. |
| 2018 | Stoyan Nikolov, "OOP is dead, long live Data-oriented design" (CppCon 2018) | Browser animation system: OOP 6.833 ms vs DoD 1.116 ms per animation tick. |
| 2019 | Jonathan Blow, "Preventing the Collapse of Civilization" (DevGAMM Moscow) | Argues software is in decline, partly because programmers no longer know how hardware works. |
| Nov 23 2021 | **Andrew Kelley, "A Practical Guide to Applying Data-Oriented Design"** (Handmade Seattle) | Zig compiler rework ("picks up where Mike Acton left off"). Kelley says he read Fabian's book. |
| Feb 28 2023 | **Casey Muratori, "'Clean' Code, Horrible Performance"** (Computer, Enhance! / Performance-Aware Programming) | Shapes benchmark: 1.5x, 10x, 15x, 20–25x (AVX). |

### 1.1 Noel Llopis (2009)
- Definition: "Data-oriented design shifts the perspective of programming from objects to the data itself: The type of the data, how it is laid out in memory, and how it will be read and processed in the game."
- The "never one" insight: "How many places in the code did you have only one of something? One enemy? One vehicle? One pathfinding node? One bullet? One particle? Never! **Where there's one, there are many.** OOP ignores that and deals with each object in isolation."
- Disambiguation he made himself: "data-oriented design does not imply that something is data-driven." Data-driven means behaviour is exposed as data/assets, which "is an orthogonal concept".
- Opening hook (good chapter opener): "Picture this: Toward the end of the development cycle, your game crawls, but you don't see any obvious hotspots in the profiler. The culprit? Random memory access patterns and constant cache misses."
- Claimed advantages: parallelization ("We have the input data, a small function to process it, and some output data"), cache utilization (instruction cache and data cache), higher-level optimizations, modularity ("very 'flat,' with lots of leaf functions"), testing ("Create some input data, call the transform function, and check that the output data is what we expect").
- Drawbacks he admits: "It requires turning our mental model of the program ninety degrees", and it is hard to interface with existing OOP code.
- In the 2010 follow-up: "Code is not something to focus on (like traditional Computer Science), but is something that is written to transform the input data into the output data in an efficient way. In modern hardware, that often means applying the same code to large, contiguous blocks of homogeneous memory."

### 1.2 Mike Acton, CppCon 2014
Principles, verbatim from his slides (numbering follows the ACCU recap):
1. "The purpose of all programs, and all parts of those programs, is to transform data from one form to another."
2. "If you don't understand the data you don't understand the problem."
3. "Conversely, understand the problem by understanding the data."
4. "Different problems require different solutions."
5. "If you have different data, you have a different problem."
6. "If you don't understand the cost of solving the problem, you don't understand the problem."
7. "If you don't understand the hardware, you can't reason about the cost of solving the problem."
8. "Everything is a data problem. Including usability, maintenance, debug-ability, etc. Everything."
9. "Solving problems you probably don't have creates more problems you definitely do."
10. "Latency and throughput are only the same in sequential systems."
- Rules of thumb: "Where there is one, there are many. Try looking on the time axis." / "The more context you have, the better you can make the solution. Don't throw away data you need." / "NUMA extends to I/O and pre-built data all the way back through time to original source creation."
- **"Software does not run in a magic fairy aether powered by the fevered dreams of CS PhDs."**
- **"Ignoring inconvenient facts is not engineering; It's dogma."**
- "Solve for the most common case first, Not the most generic."
- "Programmer's job is NOT to write code; Programmer's job is to solve (data transformation) problems"
- "The best code is code that doesn't need to exist. Do it offline. Do it once."
- "Compiler _cannot_ solve the most significant problems." The talk covers "The 90% of problem space we need to solve that the compiler cannot."
- On DOD's novelty: "…certainly not new ideas. …more of a reminder of first principles. …but it is a response to the culture of C++".
- **The Three Big Lies.** These are paraphrased from the ACCU recap and a community summary. Check the exact slide wording against the video or the CppCon2014 GitHub slides:
  1. *Software is a platform.* (The hardware is the platform.)
  2. *Code should be designed around a model of the world.* (This confuses the real-world IS-A with what the data needs.)
  3. *Code is more important than data.* (This contradicts principle 1.)
- Concrete numbers from the talk:
  - A 64-byte cache line holding one used `bool`: "Waste 60 bytes / 64 bytes, 90% waste!" ("Only 10% capacity used").
  - The dirty-flag example works out to "(~2 L2 misses each frame) x 10,000": 1,280,000 bytes fetched for about 915 bytes of real information.
  - His back-of-envelope estimate is "~200 cycles" per L2 miss.

### 1.3 Tony Albrecht, Pitfalls of OOP (2009, PS3)
- "1980: RAM latency ~ 1 cycle – 2009: RAM latency ~ 400+ cycles. What can _you_ do in 400 cycles?" (the chart comes from Hennessy & Patterson).
- 11,111 nodes in a tree 5 levels deep. "First object costs at least 7 cache misses"; "Subsequent objects cost at least 2 cache misses each."
- Profile: "Branch Mispredictions: 50,421 @ 23 cycles each ~= 0.36ms; L2 Cache misses: 36,345 @ 400 cycles each ~= 4.54ms". This makes a good visual of how small branches are compared with misses.
- Results: **19.6 ms → 12.9 ms ("35% faster just by moving things around in memory!") → 4.8 ms (linear traversal) → 3.3 ms (prefetch, `dcbt`)**.
- He also wrote "Excessive encapsulation is BAD" and "Data flow should be fundamental to your design (Data Oriented Design)".
- **2017 Revisited** (Riot, x86, 55,000 objects): "17.5ms -> 9.5ms — No functional code changes" from layout alone, then "9.5ms -> 6.2ms" with SIMD. His conclusion: "Measuring performance is not enough. You need to know *why* something is slow… For that, you must understand your hardware." He cites Agner Fog.

### 1.4 Richard Fabian, *Data-Oriented Design* (2018)
- Definition: "data-oriented design is the practice of designing software by developing transformations for well-formed data where the criteria for well-formed is guided by the target hardware and the patterns and types of transforms that need to operate on it."
- "The first principle: **Data is not the problem domain.**"
- "Data is all we have." / "Instructions are data too."
- On the timing: "The time was right in 2009. The hardware was ripe for a change in how to develop. Potentially very fast computers were hindered by a hardware ignorant programming paradigm."
- Against reducing DOD to caching: "A common misconception about data-oriented design is that it's all about cache misses… data-oriented design is about all aspects of the data."
- Against generic libraries: "You learn how to do data-oriented design, not how to add it to your project."
- He concedes where OOP wins: driver layers and APIs with large, stable objects (FILE handles, Vulkan/OpenGL objects).
- Quotes Joe Armstrong: "You wanted a banana but what you got was a gorilla holding the banana and the entire jungle."
- Book blurb: "inspired by high-performance computing techniques, database design, and functional programming values… Understand the goal, understand the data, understand the hardware, develop the solution."
- Distinctive content: relational normalization (1NF…5NF, "the key, the whole key, and nothing but the key"), existence-based processing (replacing `if` flags with table membership), and hierarchical level of detail.

### 1.5 Casey Muratori, "'Clean' Code, Horrible Performance" (2023)
- Rules tested: prefer polymorphism to if/switch; no knowledge of internals; small functions; do one thing; DRY.
- The shape-area loop:
  - Virtual calls: **~35 cycles/shape**.
  - Switch over a flat `shape_union`: **24 cycles, 1.5x faster**.
  - Coefficient-table lookup: **3.0–3.5 cycles, 10x faster**.
  - Adding a corner-count property: switch ~2x faster, table **~15x** faster.
  - Lightly optimized AVX: **20–25x**.
- Quotes:
  - "It's three or four years of hardware evolution _erased_ because somebody said to use polymorphism instead of switch statements."
  - "The first two rules of the 'clean code' concept wipe out _12 years_ of hardware evolution, all by themselves."
  - "Our job is to write programs that run well on the hardware that we are given."
  - "…'and your code will get 15 times slower or more when you do them.'"
- His Performance-Aware Programming prologue lists **"The Five Multipliers"**: Waste, IPC, SIMD, Caching, Multithreading. In "Python Revisited", a summation loop goes from 0.006 to 52 adds/cycle, "over 8,000 times faster". This is a strong organising frame for a hardware chapter.
- Note for fairness: his follow-up response to The New Stack says the video is about "the magnitude of the performance cost for each programming style choice". The New Stack measured ~1.44x for the first step.

### 1.6 Jonathan Blow
- "Preventing the Collapse of Civilization" (DevGAMM 2019): "my thesis for the rest of this talk is that software is actually in decline right now." The talk links this to lost low-level knowledge.
- Jai (since Sept 2014) has an `SOA` struct tag that lays memory out as structure-of-arrays while code is still written as array-of-structures. This inspired Zig issue #2634 and is a good bridge to Zig's `MultiArrayList` and Odin's `#soa`.
- **[unverified]** I found no single verbatim Blow quote on DOD that I could pin to a primary source. Don't attribute one without checking video timestamps.

### 1.7 Andrew Kelley (Handmade Seattle 2021). Brief; probably covered by another slice
- Strategy: "Identify where you have many objects in memory, and make the size of each object smaller." Also "CPUs are fast, but memory is slow" and "Calculate instead of store."
- Techniques: indices instead of pointers (4 B vs 8 B), store booleans out-of-band, struct-of-arrays (`MultiArrayList`) to remove padding, sparse data in hash maps, "encodings" instead of polymorphism.
- Result reported in a talk transcript: one change gave a "39% reduction of wall clock time" **[transcript, third-party]**.
- A TU Delft paper cites the Zig AST rework as a >30% speedup in type checking and IR generation.
- Mitchell Hashimoto's example: `struct {u32, bool}` takes 8 B, four of them 32 B; as SoA, four take 20 B, i.e. 37.5% less.

---

## 2. Naming collision: "Data-Oriented Programming" ≠ DOD

Write a sidebar so readers don't confuse three different things.

| | Data-Oriented **Design** (this book) | Data-Oriented **Programming** (Sharvit, Manning, July 2022, 424 pp, ISBN 9781617298578) | "Data-Oriented Programming in Java" (Brian Goetz, InfoQ, June 20 2022) |
|---|---|---|---|
| Goal | Performance on real hardware; reason about the cost of data transformations | Reduce complexity in information systems (web back ends and front ends) | Model data cleanly with records, sealed classes, pattern matching |
| Data shape | Specialized, tightly packed, often SoA arrays of POD; layout chosen for the access pattern | **Generic** maps and lists ("string maps"), JSON-like | Immutable records and sum types (ADTs) |
| Mutability | Mutation in place is normal (batch transforms) | **Immutable** data, persistent data structures | Immutable records |
| Schema | Static types, known sizes, alignment matters | Schema separate from data, **validated at runtime** | Compile-time types |
| Lineage | Games, HPC, Acton, Llopis, Fabian | Clojure / Rich Hickey | Java Project Amber (ML-style ADTs) |

- Sharvit's four principles, verbatim: "Principle #1: Separating code (behavior) from data. Principle #2: Representing data with generic data structures. Principle #3: Treating data as immutable. Principle #4: Separating data schema from data representation."
- Principle 1 overlaps with DOD (both separate code from data). Principles 2 and 3 run directly against performance DOD: hash maps of boxed values, plus extra allocation and indirection from persistent structures.
- Goetz: "Data-oriented programming encourages us to model data as (immutable) data, and keep the code that embodies the business logic of how we act on that data separately." It overlaps with Sharvit's #1 and #3, but uses static types.
- Also note: Milo Yip (Tencent, GDC China 2014) titled his talk "A Data-Oriented *Programming* Paradigm for Optimal Performance" while meaning performance DOD. The terms really are muddled, and some game people say "DOP" for DOD.
- Llopis's own disambiguation: data-oriented ≠ data-driven (see §1.1).

---

## 3. Hardware reality — key numbers

### 3.1 The latency ladder

**Classic table** (Norvig's "Teach Yourself Programming in Ten Years" answers, popularized by Jeff Dean; jboner gist labelled "~2012"):

| Op | Classic | Google SRE handout (current) | Bohsali 2026 |
|---|---|---|---|
| L1 reference | 0.5 ns | 1 ns | 1 ns (~32–48 KB/core) |
| Branch mispredict | 5 ns | 3 ns | 3 ns |
| L2 reference | 7 ns | 4 ns | 3 ns (~512 KB–2 MB) |
| L3 reference | — | — | 15 ns (tens of MB, shared) |
| Mutex lock/unlock (uncontended) | 25 ns | 17 ns | 20 ns |
| Main memory | 100 ns | 100 ns | 80 ns (DDR5) |
| Read 1 MB sequentially from memory | 250 µs | 10 µs | **[see note]** |

Note: the 1 MB sequential-read figure has changed the most. The SRE handout says sequential memory reads run at about 100 GB/s burst. Chips and Cheese reports a single Zen 4/5 core pulling over 50 GB/s from DRAM. The 250 µs figure is badly out of date.

**Measured, current-generation (Chips and Cheese, AMD/Intel docs, Apple via 7-cpu/jia.je):**

| | Zen 5 desktop (Ryzen 9 9900X/9950X) | Intel Lion Cove (Core Ultra 9 285K) | Apple M1 Firestorm (P-core) |
|---|---|---|---|
| L1D | 48 KB, 4 cycles (AMD SOG: 4–5 int, 7–8 FP load-to-use) | 48 KB, 4 cycles (+ 192 KB "L1.5" at 9 cycles) | 128 KB, 3 cycles |
| L2 | 1 MB, 14 cycles | 3 MB, 17 cycles | 12 MB shared per cluster, ~16–18 cycles |
| L3 / SLC | 32 MB, ~48 cycles | 36 MB, ~84 cycles | 8 MB SLC; 18 cycles + 10–15 ns |
| DRAM | "just over 70 ns" (DDR5-6000); 82–83 ns DDR5-5600 | — | ~96 ns (AnandTech, 128 MB random); 7-cpu: 18 cycles + 91 ns |
| Mobile | Strix Point (Zen 5 mobile, LPDDR5): ~128 ns | Core Ultra 7 155H: 148 ns | — |

- The key ratio: "70 ns of DRAM latency is nearly 400 cycles at 5.7 GHz, but only 210 cycles at 3 GHz" (Chips and Cheese). Albrecht's "~400 cycles" from 2009 still holds in cycles because clocks went up while DRAM ns barely moved.
- "With just over 70 ns of memory latency, the Ryzen 9 9950X with DDR5-6000 is just about able to match a Core i7-4770 with DDR3-1333" (Chips and Cheese). This shows DRAM latency is roughly flat across a decade.
- "Pointer chasing through a 1 GB array with 2 MB pages gives about 76 ns of latency on the Athlon II X4 651 [2011]… on the Ryzen AI 9 HX 370, you'll see over 128 ns" (Chips and Cheese). Mobile latency has even regressed.
- Under load, latency rises. Zen 4 measured >700 ns under heavy bandwidth contention; Zen 5 about 151 ns in a comparable CCD-level test.
- Historical anchors from Drepper 2007:
  - Pentium M: register ≤1, L1d ~3, L2 ~14, main memory ~240 cycles.
  - P4 sequential walk: prefetching hides L2 and DRAM, so ~9 cycles/element versus 200+ cycles raw.
  - Random walks reach 450+ cycles.
  - The multi-threaded random "Addnextlast" case hits "around 1,500 cycles to process a single list element in the extreme case."

### 3.2 Cache lines
- **x86-64: 64 B** everywhere. Drepper: "In early caches these lines were 32 bytes long; now the norm is 64 bytes." AMD's Zen 5 SOG: "The data cache natural alignment boundary is 64 bytes for loads. A misaligned load… suffers, at minimum, a one cycle penalty… if it spans a 64-byte boundary."
- **Apple M-series is nuanced. The book should get this exactly right:**
  - `sysctl hw.cachelinesize` returns **128** on M1, and macOS pages are **16 KB** (`hw.pagesize: 16384`).
  - Apple's own tech talk "Tune CPU job scheduling for Apple silicon games" says: "**On Apple silicon, a cache line is 128 bytes long.**" It says this in the context of false sharing.
  - The Apple Silicon CPU Optimization Guide, as quoted by jia.je, gives **L1D 128 KiB, 8-way, 64 B lines** (P-cores, M1–M4) and **L2 and SLC with 128 B lines**.
  - Wrenger et al. (2024, M1 Ultra under Asahi Linux): "sysctl on macOS reports a value of 128 B, while getconf and the CTR_EL0 register on Asahi Linux returns 64 B, which is also supported by our measurements."
  - **Book guidance:** treat 128 B as the coherence/false-sharing granularity on Apple Silicon. Treat 64 B as the L1 fill and alignment unit.
- **Rust `crossbeam_utils::CachePadded`** uses `#[repr(align(128))]` on x86-64, aarch64 and powerpc64. On arm/mips/sparc/hexagon it uses 32, on s390x 256, and 64 elsewhere. The source says: "Starting from Intel's Sandy Bridge, spatial prefetcher is now pulling pairs of 64-byte cache lines at a time, so we have to align to 128 bytes rather than 64." It also notes that the "big" cores of aarch64 big.LITTLE have 128-byte lines. Facebook folly also uses 128.
- monoid.github.io blog: reproduced spatial-prefetcher-induced false sharing at 64 B spacing on Skylake, but **not** on Ice Lake, and found no effect on M-series in their benchmark. Present 128 as a pessimistic but safe choice.

### 3.3 Hardware prefetching
- Intel Optimization Reference Manual (L1/L2 prefetchers):
  - **DCU (streaming) prefetcher**: "triggered by an ascending access to very recently loaded data… automatically fetches the next line."
  - **IP-based stride prefetcher**: "can prefetch forward or backward and can detect strides of up to 2K bytes."
  - **L2 Spatial prefetcher**: "strives to complete every cache line fetched to the L2 cache with the pair line that completes it to a 128-byte aligned chunk."
  - **L2 Streamer**: forward/backward streams. "Prefetched cache lines must be in the same 4K page."
  - The manual's own tip: "organize the data or instructions in blocks of 128 bytes, aligned on 128 bytes."
- Newer Intel E-cores (optimization-zone whitepaper) add a Next Page Prefetcher, an **Array-of-Pointers Prefetcher** that "tries to detect and prefetch pointer chasing", and LLC page prefetchers. Hardware is starting to target pointer chasing, but these features are not a reason to keep pointer-heavy layouts.
- Drepper: the TLB can't be prefetched by hardware across pages, because "the hardware could initiate page table walks that are invalid." Sequential streams are prefetched almost perfectly. "the L2 demand miss rate is basically zero" for sequential access, while random access shows significant DTLB misses that "set in before the L2 misses."
- Albrecht 2017: "How does the CPU prefetch? Linearly. Uniform stride/direction. Multiple streams can be active at once. But only a limited number of them."

### 3.4 TLB & pages
- **Zen 4**: L1 DTLB 72 entries, L2 DTLB 3072. Chips and Cheese: "caching address translations for 288 KB of memory with no latency overhead, or 12 MB with a slight 7-8 cycle penalty." Golden Cove has a 2048-entry L2 TLB.
- **Zen 5**: L1 DTLB **96** (fully associative), L2 DTLB **4096**, still +7 cycles for an L2 TLB hit. jia.je measured 4 cycles load-to-use on an L1 DTLB hit and 11 on an L2 DTLB hit. With 4 KB pages, the L2 DTLB covers 4096 × 4 KB = **16 MB**. Address bits are translated per page, so a 2 MB page gives one entry 512x the reach.
- **Apple Firestorm**: 16 KB pages. L1 ITLB 192 entries (3 MiB reach). A14/M1 L1 DTLB 256 pages and L2 TLB 3072 (AnandTech).
- Page walks: x86-64 uses 4-level paging, so a full walk can cost up to 4 extra dependent memory accesses (Chips and Cheese).
- Drepper's TLB experiment: a "huge spike starting when the working set size reaches 2¹³ bytes. This is when the TLB cache overflows," in a test that placed each element on its own page.

### 3.5 False sharing
- Drepper (4× P4; threads each increment their own variable 500M times). Overhead of one shared cache line versus separate lines: **390%, 734%, 1,147%** for 2, 3 and 4 threads. "The cache line is pulled from one processor's cache just after it has finished writing to the cache line."
- Drepper's rules: "Separate at least read-only (after initialization) and read-write variables… Group read-write variables which are used together into a structure… Move read-write variables which are often written to by different threads onto their own cache line."
- Apple: "avoid having multiple threads simultaneously write data located in the same cache line… Multiple reads from the same data structure is fine, but such competing writes lead to ping-ponging."
- Igor Ostrovsky's "Gallery of Processor Cache Effects", Example 6, gives a simple demo: four threads incrementing adjacent array slots.

### 3.6 Branch prediction
- Misprediction penalty in cycles:
  - Agner Fog, optimizing_cpp: "approximately 15 - 25 clock cycles, depending on the processor."
  - AMD Zen 4 SOG: 11–18, "common case penalty is 13 cycles."
  - AMD Zen 5 SOG: 12–18, "common case penalty is 15 cycles."
  - Agner, microarchitecture: Zen 1–3 ≈ 18; Zen 4 15–18; Zen 5 15–25. Sandy/Ivy Bridge "15 clock cycles or more". Golden Cove ~17 (secondary source).
- Agner: "The number of wasted clock cycles is approximately equal to the length of the pipeline." Also: "A branch instruction takes typically 0 - 2 clock cycles in the case that the microprocessor has made the right prediction."
- Agner on virtual calls: "The rules for prediction and misprediction of virtual function calls is the same as for switch statements." This ties back to Muratori's polymorphism-versus-switch comparison.
- **The famous demo**: Stack Overflow's highest-voted question of all time, "Why is processing a sorted array faster than processing an unsorted array?"
  - Sorting makes the `if (data[c] >= 128)` loop about 6x faster.
  - perf counters: 0.01% branch misses sorted versus a large fraction unsorted (11.8 s vs 28.9 s in one answer).
  - Caveat for the book: modern compilers auto-vectorize or use `cmov`, so "sorted or not doesn't matter" at -O3 with AVX2. One commenter measured Apple M1 at 17 s unsorted vs 7 s sorted.
  - Stroustrup on the same question (Stack Overflow blog, 2019) measured roughly a 5–6x gap for `std::sort` on sorted versus shuffled data.
- Zen 5 front end: "Zero-bubble conditional branches", a 16K-entry L1 BTB, a 52-entry return stack, and a 2-taken-per-cycle TAGE predictor (Hot Chips 2024).

### 3.7 SIMD widths
| ISA | Width | Notes |
|---|---|---|
| x86 SSE (…SSE4.2) | 128-bit (XMM) | 4×f32 |
| x86 AVX/AVX2 | 256-bit (YMM) | 8×f32; baseline for x86-64-v3 |
| x86 AVX-512 | 512-bit (ZMM), mask registers | Zen 4 double-pumps 256-bit units; **desktop Zen 5 has a full 512-bit datapath ("256b/512b" by variant), mobile Zen 5 a weaker AVX-512 implementation**; Zen 5 desktop does two 512-bit loads per cycle |
| Arm NEON (Advanced SIMD) | fixed 128-bit, 32 V registers | M1–M4 P-cores have 4 FP/SIMD pipes; Apple has no SVE |
| Arm SVE/SVE2 | "128 bits up to a maximum of 2048 bits, but must be a power of two" (vector-length agnostic) | Fujitsu A64FX 512, AWS Graviton3 256 |
| Arm SME | streaming VL 128–2048 bits; ZA tile SVL×SVL | Present on Apple M4 (xnu has SME support docs) |

- Albrecht 2017 shows SIMD gains only arrive *after* the data reorganization (9.5 → 6.2 ms). Muratori's AVX step is 20–25x. Both make the point that SoA layout is what enables SIMD.

### 3.8 Bandwidth vs latency ("Latency and throughput are only the same in sequential systems")
- Zen 5 desktop L1D: two 512-bit loads per cycle. L2 has 64 B/cycle read and write paths. A single core "can just about saturate its 32 byte per cycle interface to L3".
- One Zen 4/5 core can pull ">50 GB/s from DRAM, or well north of 100 GB/s from L3."
- Apple M1: one Firestorm core reads ~58 GB/s from memory; 68.25 GB/s peak (LPDDR4X-4266, 128-bit). M1 Max 409.6 GB/s, M1 Ultra 819.2 GB/s.
- Out-of-order windows hide L2/L3 but not DRAM. Zen 5 ROB is 448 entries, Redwood Cove 512, M1 ~630 (AnandTech). One M1 explainer: an 8-wide, 640-entry ROB covers L2 (~15 cycles) and SLC (~90 cycles) misses, but "when this 640-entry ROB machine misses to DRAM… eventually all the slots in the ROB will be filled". **[third-party explainer, plausible]**

---

## 4. Memorable quotes (exact, attributed)

1. "The purpose of all programs, and all parts of those programs, is to transform data from one form to another." — Mike Acton, CppCon 2014
2. "Software does not run in a magic fairy aether powered by the fevered dreams of CS PhDs." — Mike Acton, CppCon 2014
3. "Ignoring inconvenient facts is not engineering; It's dogma." — Mike Acton, CppCon 2014
4. "If you don't understand the hardware, you can't reason about the cost of solving the problem." — Mike Acton
5. "Solving problems you probably don't have creates more problems you definitely do." — Mike Acton
6. "Where there's one, there are many." — Noel Llopis, Game Developer, Sept 2009 (Acton: "Where there is one, there are many. Try looking on the time axis.")
7. "Data-oriented design shifts the perspective of programming from objects to the data itself" — Llopis 2009
8. "2009: RAM latency ~ 400+ cycles. What can _you_ do in 400 cycles?" — Tony Albrecht, 2009
9. "35% faster just by moving things around in memory!" — Tony Albrecht, 2009
10. "The time was right in 2009… Potentially very fast computers were hindered by a hardware ignorant programming paradigm." — Richard Fabian
11. "Data is not the problem domain." — Richard Fabian
12. "It's three or four years of hardware evolution _erased_ because somebody said to use polymorphism instead of switch statements." — Casey Muratori, 2023
13. "Our job is to write programs that run well on the hardware that we are given." — Casey Muratori, 2023
14. "As CPU cores become both faster and more numerous, the limiting factor for most programs is now, and will be for some time, memory access." — Ulrich Drepper, 2007 (abstract)
15. "The difference between diverging exponentials also grows exponentially." — Wulf & McKee, 1995
16. "Show me your flowcharts and conceal your tables, and I shall continue to be mystified. Show me your tables, and I won't usually need your flowcharts; they'll be obvious." — Fred Brooks, *Mythical Man-Month* (quoted via ACCU)
17. "On Apple silicon, a cache line is 128 bytes long." — Apple Developer tech talk
18. "my thesis for the rest of this talk is that software is actually in decline right now." — Jonathan Blow, 2019 (from a community transcript)
19. "You wanted a banana but what you got was a gorilla holding the banana and the entire jungle." — Joe Armstrong (quoted in Fabian)

---

## 5. Visualization ideas

1. **Human-scale latency ladder.** Scale 1 ns to 1 s: L1 ≈ 1 s, L2 ≈ 3–4 s, L3 ≈ 10–15 s, DRAM ≈ 1.3–1.7 min, NVMe ≈ hours, cross-ocean ≈ years. Use horizontal log bars with a toggle between "2012 classic" and "2026" values. The interactive version by philbogle.github.io, built on Colin Scott's, is a precedent.
2. **Memory-wall chart.** CPU vs DRAM performance from 1980 to 2025 on a log scale (Hennessy & Patterson style), plus Wulf & McKee's projected cycles per access (1.52, 8.25, 98.8) as dots. Overlay a flat "DRAM ns" line (~70–130 ns) against a rising "DRAM cycles" line.
3. **Cache-line "bus".** A 64-byte strip of 16 cells shows an AoS `struct {pos, vel, health, name*, flags…}` with only the `health` field highlighted, then the SoA version where every byte is used. Annotate with Acton's "Waste 60 bytes / 64 bytes".
4. **Working-set staircase.** Plot cycles per element against working-set size (2¹⁰…2²⁸). Show plateaus at L1 (48 KB), L2 (1 MB), L3 (32 MB) and DRAM, with sequential and random curves. This recreates Drepper Fig 3.15 using Zen 5 numbers. A Rust/Zig/Odin pointer-chase harness could generate real data.
5. **Ostrovsky stride plot.** Run time against stride K. It stays flat for K = 1…16 ints, then halves with each doubling. Teaches "you pay per line, not per byte".
6. **Albrecht waterfall.** 19.6 → 12.9 → 4.8 → 3.3 ms as stacked bars, and the 2017 version 17.5 → 9.5 → 6.2 ms.
7. **Muratori cycles-per-shape bars.** 35 / 24 / 3.0–3.5 / AVX, with a second axis for "years of hardware erased".
8. **Branch predictor demo.** An interactive slider for "% of data sorted / predictability" against simulated cycles. Use a train-at-junction metaphor, as in the Stack Overflow answer.
9. **False-sharing ping-pong animation.** Two cores and one cache line bounce between Modified and Invalid states. Add a toggle for 64 vs 128 B padding and the bar chart 1x / 3.9x / 7.3x / 11.5x (Drepper).
10. **TLB reach calculator.** Inputs: entries × page size (4 KB, 16 KB Apple, 2 MB huge). Output: reach (e.g. Zen 5's 4096 × 4 KB = 16 MB vs × 2 MB = 8 GB). Mark the working set on the same axis.
11. **SIMD lane diagram.** One row each for 128 (SSE/NEON), 256 (AVX2), 512 (AVX-512) and 128–2048 (SVE) bits, showing how many f32s fit, with SoA columns loading straight into lanes.
12. **Disambiguation Venn/table.** Data-Oriented Design vs Sharvit's DOP vs Goetz's Java DOP vs "data-driven", using the §2 table.
13. **"Five multipliers" radar** (Muratori): Waste, IPC, SIMD, Caching, Multithreading. Use it as a recurring map of which multiplier each chapter addresses.

---

## 6. Points to handle carefully in the book
- **Cache-line size is not a constant.** Use 64 B for x86 and Apple's L1; 128 B for Apple L2/SLC coherence and as a defensive padding choice (crossbeam, folly, Intel's spatial prefetcher). Show how to query it: Rust has no stable `hardware_destructive_interference_size`; C++17 has `std::hardware_destructive_interference_size`; macOS has `sysctl hw.cachelinesize`; Linux has `getconf LEVEL1_DCACHE_LINESIZE`.
- **"Latency numbers" tables drift.** Always give the source and year. DRAM ns has been stuck at about 70–130 ns for 15+ years, while bandwidth and core counts grew. So DOD matters *more* in cycle terms.
- **The sorted-array demo can fail on modern compilers** (vectorization/`cmov`). Use `-O1`, or inspect the asm.
- **DOD ≠ "just caches"** (Fabian), and **DOD ≠ data-driven** (Llopis).
- Acton's three lies: check the exact slide wording against the CppCon2014 GitHub slides PDF before printing quotation marks.

---

## SOURCES
(O = opened and read; S = seen in search results only)

### Origins & philosophy
- (O) Noel Llopis, "Data-Oriented Design (Or Why You Might Be Shooting Yourself in The Foot With OOP)", 2009 (Game Developer Sept 2009; blog Dec 4 2009). https://gamesfromwithin.com/data-oriented-design — the article that named DOD; "where there's one, there are many".
- (S) Noel Llopis, "Data-Oriented Design Now And In The Future", 2011 blog / Sept 2010 magazine. https://gamesfromwithin.com/data-oriented-design-now-and-in-the-future — follow-up; "Code is not something to focus on".
- (S) Noel Llopis, "Sponsored Feature: Data-Oriented Design – Now And In The Future", Game Developer/Gamasutra, Apr 13 2011. https://www.gamedeveloper.com/design/sponsored-feature-data-oriented-design-now-and-in-the-future — Intel-sponsored reprint.
- (S) Noel Llopis, "Managing Data Relationships", 2010 blog (Sept 2008 magazine). https://gamesfromwithin.com/managing-data-relationships — indices vs pointers.
- (S) Noel Llopis, "Great Presentation on Data-Oriented Design", Dec 20 2009. https://gamesfromwithin.com/great-presentation-on-data-oriented-design — links Albrecht's slides; credits Christer Ericson.
- (O) Mike Acton, "Data-Oriented Design and C++" slides, CppCon 2014 (mirror). https://neil3d.github.io/assets/img/ecs/DOD-Cpp.pdf — principles, "magic fairy aether", 90% cache-line waste.
- (S) CppCon 2014 video, Mike Acton, Sept 30 2014. https://youtu.be/rX0ItVEVjHc — ~800k views; slides at https://github.com/CppCon/CppCon2014 (S, not opened).
- (S) isocpp.org, "CppCon 2014 Data-Oriented Design and C++—Mike Acton", Jan 28 2015. https://isocpp.org/blog/2015/01/cppcon-2014-data-oriented-design-and-c-mike-acton — official abstract: "The transformation of data is the only purpose of any program."
- (S) CppCon, "Third Keynote" announcement, July 2014. https://cppcon.org/2014/07/ — Acton bio.
- (O) Lucian Radu Teodorescu, "Revisiting Data-Oriented Design", ACCU Overload 30(167), Feb 2022. https://www.accu.org/journals/overload/30/167/teodorescu — numbered Acton principles, three lies, Brooks quote.
- (S) Strumenta Community thread "Data-oriented design / jai language", 2020. https://d.strumenta.community/t/data-oriented-design-jai-language/211 — community paraphrase of the three lies.
- (O) Tony Albrecht, "Pitfalls of Object Oriented Programming", Sony CEE, 2009. https://www.gamedevs.org/uploads/pitfalls-of-object-oriented-programming.pdf — 400+ cycle RAM; 19.6→3.3 ms.
- (O) Tony Albrecht, "Pitfalls of Object Oriented Programming – Revisited", Riot Games, 2017 (slideserve transcript). https://www.slideserve.com/cheng/object-oriented-programming — 17.5→9.5→6.2 ms on modern HW.
- (S) Hacker News discussion of Pitfalls (2009), Dec 2023. https://news.ycombinator.com/item?id=38781277 — links the 2017 revisit and Stroustrup's vector vs list talk.
- (O) Richard Fabian, *Data-Oriented Design* (free online reduced version), 2018. https://www.dataorienteddesign.com/dodbook/node2.html — definition; "Data is not the problem domain"; "The time was right in 2009".
- (S) Richard Fabian, book contents page. https://www.dataorienteddesign.com/dodbook/dodmain.html — chapter list (existence, LOD, searching, sorting).
- (S) Richard Fabian, full PDF, Oct 8 2018. https://www.dataorienteddesign.com/dodbook.pdf — normalization chapter.
- (S) ACM DL record, Fabian, *Data-oriented design: software engineering for limited resources and short schedules*, Sept 2018, ISBN 978-1-138-03545-4. https://dl.acm.org/doi/10.5555/3299213 — blurb: "inspired by high-performance computing techniques, database design, and functional programming values".
- (S) Matt Hall, "Book Review: Data-Oriented Design", 2024. https://mattjhall.co.uk/posts/book-review-data-oriented-design.html — reader's view of the normalization chapter.
- (O) Casey Muratori, "'Clean' Code, Horrible Performance", Computer, Enhance!, Feb 28 2023. https://www.computerenhance.com/p/clean-code-horrible-performance — 35/24/3.5 cycles; 1.5x/10x/15x/20–25x.
- (S) Casey Muratori, "Response to a Reporter Regarding 'Clean Code, Horrible Performance'", Apr 7 2023. https://www.computerenhance.com/p/response-to-a-reporter-regarding — context and intent.
- (S) Casey Muratori, Performance-Aware Programming Table of Contents, 2023. https://www.computerenhance.com/p/table-of-contents — "The Five Multipliers".
- (S) Casey Muratori, "Python Revisited", Feb 18 2023. https://www.computerenhance.com/p/python-revisited — 0.006→52 adds/cycle, ">8,000 times faster".
- (S) David Cassel, "When 'Clean Code' Hampers Application Performance", The New Stack, Apr 16 2023. https://thenewstack.io/when-clean-code-hampers-application-performance/ — press coverage; reports 1.44x.
- (S) SE Radio 577, Casey Muratori with Giovanni Asproni, Aug 17 2023. https://se-radio.net/2023/08/se-radio-577-casey-muratori-on-clean-code-horrible-performance — debate on trade-offs.
- (S) Stoyan Nikolov, "OOP is dead, long live Data-oriented design", CppCon 2018 slides. https://neil3d.github.io/reading/assets/slides/oop_is_dead_long_live_dataoriented_design__stoyan_nikolov__cppcon_2018.pdf — OOP 6.833 ms vs DoD 1.116 ms.
- (S) Milo Yip, "A Data-Oriented Programming Paradigm for Optimal Performance", GDC China 2014. https://media.gdcvault.com/gdcchina14/presentations/833779_MiloYip_ADataOriented_EN.pdf — shows the DOP/DOD naming muddle; Unity vs DOD 250 ms→6.2 ms.
- (S) Jonathan Blow, "Preventing the Collapse of Civilization" transcript, DevGAMM 2019 (transcribed 2021). https://codigoyfika.github.io/site/preventing-collapse/ — "software is actually in decline right now".
- (S) Karl Voit, summary of Blow's talk, 2019. https://karl-voit.at/2019/06/12/backward-development — secondary summary.
- (S) Jai Primer (community, not by Blow), via Rust Internals thread, 2016. https://internals.rust-lang.org/t/jai-language-primer/3176 — Jai SOA/AOS feature; Blow disowns the primer's accuracy.
- (S) Zig issue #2634 "Explicit support for AoS/SoA", 2019. https://github.com/ziglang/zig/issues/2634 — Jai SOA as inspiration.
- (S) Jonathan Blow, "Jai Demo and Design Explanation" (LambdaConf 2025). https://www.youtube.com/watch?v=IdpD5QIVOKQ — recent Jai keynote.
- (S) Andrew Kelley, "A Practical Guide to Applying Data-Oriented Design", Handmade Seattle, Nov 23 2021. https://media.handmade-seattle.com/practical-data-oriented-design/ — Zig compiler DoD techniques (link seen via TMPDIR/Tildes posts).
- (S) TMPDIR forum notes on Kelley's talk, 2022. https://community.tmpdir.org/t/a-practical-guide-to-applying-data-oriented-design/560 — bullet list of techniques.
- (S) Kelley talk transcript (third-party). https://josherich.me/podcast/andrew-kelley-practical-data-oriented-design-dod — "39% reduction of wall clock time"; read Fabian's book.
- (S) Mitchell Hashimoto, "Zig Parser", Feb 11 2022. https://mitchellh.com/zig/parser — MultiArrayList 32 B → 20 B example.
- (S) Zig std `multi_array_list.zig`. https://github.com/ziglang/zig/blob/master/lib/std/multi_array_list.zig — SoA implementation.
- (S) TU Delft thesis "Memory Layout Optimisation on Abstract Syntax Trees". https://repository.tudelft.nl/file/File_5748302e-41df-4214-b489-32eca09e39bf?preview=1 — cites Zig AST rework >30% speedup.

### Naming collision
- (S) Yehonathan Sharvit, *Data-Oriented Programming*, Manning, July 2022, 424 pp, ISBN 9781617298578. https://www.manning.com/books/data-oriented-programming — generic immutable data structures.
- (S) Yehonathan Sharvit, "Principles of Data-Oriented Programming", June 22 2022. https://blog.klipse.tech/dop/2022/06/22/principles-of-dop.html — the four principles, verbatim.
- (S) Manning liveBook, DOP Appendix A. https://livebook.manning.com/book/data-oriented-programming/appendix-a — "In DOP, data is treated as a first-class citizen."
- (S) Changelog Interviews #522 with Sharvit, 2023. https://changelog.com/podcast/522 — schema validated at runtime; Clojure roots.
- (S) Brian Goetz, "Data Oriented Programming in Java", InfoQ, June 20 2022. https://www.infoq.com/articles/data-oriented-programming-java/ — records, sealed classes, pattern matching.

### Hardware: memory, caches, latency
- (S) Wulf & McKee, "Hitting the Memory Wall: Implications of the Obvious", ACM SIGARCH CAN 23(1), 1995. https://dl.acm.org/doi/10.1145/216585.216588 — coined "memory wall".
- (S) Same paper, PDF mirror. http://intranet.di.unisa.it/~vitsca/SC-2011/DesignPrinciplesMulticoreProcessors/Wulf1995.pdf — 1.52/8.25/98.8 cycles projection.
- (S) Patterson et al., "A Case for Intelligent RAM: IRAM", 1997. https://ece.northeastern.edu/courses/ece3391/papers/IRAM.pdf — CPU +60%/yr vs DRAM <10%/yr gap chart.
- (S) Ulrich Drepper, "What Every Programmer Should Know About Memory", Nov 21 2007, PDF. https://www.akkadia.org/drepper/cpumemory.pdf — full 114-page paper.
- (O) Drepper, "Memory part 2: CPU caches", LWN, Oct 1 2007. https://lwn.net/Articles/252125 — Pentium M 3/14/240 cycles; sequential vs random; TLB spike.
- (S) Drepper, "Memory part 3: Virtual Memory", LWN, Oct 9 2007. https://lwn.net/Articles/253361 — TLB; hardware can't prefetch across pages.
- (S) Drepper, "Memory part 5: What programmers can do", LWN, Oct 23 2007. https://lwn.net/Articles/255364 — sequential access, prefetching.
- (O) Drepper, "Memory part 6: More things programmers can do", LWN, Oct 31 2007. https://lwn.net/Articles/256433 — false sharing 390/734/1,147%.
- (S) Drepper, "Memory part 7: Memory performance tools", LWN, Nov 7 2007. https://lwn.net/Articles/257209 — sequential L2 demand miss ≈ 0.
- (S) LWN, "the PDF version", Nov 24 2007. https://lwn.net/Articles/259710 — publication note.
- (S) Peter Norvig, "Teach Yourself Programming in Ten Years" (answers section). https://www.norvig.com/21-days.html — original latency table.
- (S) Jonas Bonér gist, "Latency Numbers Every Programmer Should Know" (~2012, credits Jeff Dean). https://gist.github.com/jboner/2841832 — classic table.
- (S) Google SRE, "Latency Numbers Everyone Should Know" (handout PDF). https://sre.google/static/pdf/rule-of-thumb-latency-numbers-letter.pdf — 1/3/4/17/100 ns; ~100 GB/s memory.
- (S) Omar Bohsali, "Latency Numbers You Should Know in 2026", May 22 2026. https://omarish.com/latency-numbers-you-should-know — L1 1, L2 3, L3 15, DDR5 80 ns.
- (S) Phil Bogle, "Latency Numbers Every Programmer Should Know (1990–2026)" interactive. https://philbogle.github.io/interactive-latency-numbers — builds on Colin Scott's; visualization precedent.
- (S) Colin Scott, interactive latency page (2012). https://colin-scott.github.io/personal_website/research/interactive_latency.html — year-slider extrapolation (link seen in Bellevue course page; not opened).
- (S) Chester Lam, "AMD's Ryzen 9950X: Zen 5 on Desktop", Chips and Cheese, Aug 14 2024. https://chipsandcheese.com/p/amds-ryzen-9950x-zen-5-on-desktop — "just over 70 ns"; 512-bit loads.
- (S) Chester Lam, "AMD's Strix Point: Zen 5 Hits Mobile", Chips and Cheese, Aug 10 2024. https://chipsandcheese.com/p/amds-strix-point-zen-5-hits-mobile — L1D 48 KB 4 cycles; L2 14 cycles; ~128 ns DRAM; TLB table (old site mirror https://old.chipsandcheese.com/2024/08/10/amds-strix-point-zen-5-hits-mobile/).
- (S) Chester Lam, "Zen 5 Variants and More, Clock for Clock", Chips and Cheese, Aug 20 2024. https://chipsandcheese.com/p/zen-5-variants-and-more-clock-for-clock — 70 ns ≈ 400 cycles @5.7 GHz; Athlon II 76 ns vs HX 370 128 ns.
- (S) Chester Lam, "Analyzing Lion Cove's Memory Subsystem in Arrow Lake", Jan 5 2025. https://old.chipsandcheese.com/2025/01/05/analyzing-lion-coves-memory-subsystem-in-arrow-lake — Lion Cove vs Zen 5 cache table.
- (S) Chips and Cheese, "Pushing AMD's Infinity Fabric to its Limits", Nov 2024. https://chipsandcheese.com/p/pushing-amds-infinity-fabric-to-its — 82–83 ns idle; >700 ns loaded (Zen 4).
- (S) Chips and Cheese, "AMD's Zen 4, Part 2: Memory Subsystem and Conclusion", Nov 2022. https://chipsandcheese.com/p/amds-zen-4-part-2-memory-subsystem-and-conclusion — DTLB 72/3072; 288 KB / 12 MB reach.
- (S) Chips and Cheese, "Inside Nvidia GB10's Memory Subsystem", Dec 31 2025. https://chipsandcheese.com/p/inside-nvidia-gb10s-memory-subsystem — ">50 GB/s from DRAM… well north of 100 GB/s from L3" for one Zen core.
- (S) Chips and Cheese, "Hot Chips 2023: Characterizing Gaming Workloads on Zen 4". https://chipsandcheese.com/p/hot-chips-2023-characterizing-gaming-workloads-on-zen-4 — real-game DTLB MPKI.
- (S) jia.je, "AMD Zen 5 微架构评测", Nov 11 2024. https://jia.je/hardware/2024/11/11/amd-zen5 — measured DTLB 96/4096, 4→11 cycles.
- (S) Wikipedia, "Zen 5". https://en.wikipedia.org/wiki/Zen_5 — Zen 4 vs Zen 5 parameter table.
- (S) AMD, "Next Generation 'Zen 5' Core", Hot Chips 2024. https://hc2024.hotchips.org/assets/program/conference/day2/24_HC2024.AMD.Cohen.Subramony.final.pdf — official cache/TLB/branch specs.
- (S) Scott Meyers, "CPU Caches and Why You Care" (handout), code::dive 2014. https://neil3d.github.io/reading/assets/slides/codedive-CPUCachesHandouts.pdf — "Main memory latency is 107 cycles. 27 times slower than L1!" (Core i7).
- (S) Scott Meyers, same talk, video. https://www.youtube.com/watch?v=WDIkqP4JbkE
- (S) Igor Ostrovsky, "Gallery of Processor Cache Effects", 2010. https://igoro.com/archive/gallery-of-processor-cache-effects — stride, ILP, associativity, false-sharing demos.

### Hardware: cache lines, prefetch, false sharing
- (S) crossbeam-utils `cache_padded.rs` (source). https://github.com/crossbeam-rs/crossbeam/blob/master/crossbeam-utils/src/cache_padded.rs — 128 on x86-64/aarch64; Sandy Bridge spatial-prefetcher rationale.
- (S) docs.rs, `CachePadded` docs. https://docs.rs/crossbeam/latest/crossbeam/utils/struct.CachePadded.html — per-arch N table.
- (S) Monoidal Transformation blog, "False Sharing Alignment". https://monoid.github.io/posts/false-sharing-alignment — 64 vs 128 benchmark on Skylake, Ice Lake, M-series.
- (S) Intel, Optimization Reference Manual documentation-changes doc (248966 updates), 2023. https://cdrdv2-public.intel.com/814201/355308-Software-Optimization-Manual-048-Changes-Doc.pdf — DCU, IP-stride, spatial, streamer prefetchers; 4 KB page limit; "blocks of 128 bytes".
- (S) Intel optimization-zone, "Hardware Prefetch Controls for Intel E-Cores". https://intel.github.io/optimization-zone/hardware/HWPrefetchTuning — next-page and array-of-pointers prefetchers.
- (S) Intel Community, "Hardware prefetch and shared multi-core resources on Xeon". https://community.intel.com/t5/Intel-Moderncode-for-Parallel/Hardware-prefetch-and-shared-multi-core-resources-on-Xeon/td-p/1074003 — manual excerpt quoted.
- (S) abertschi.ch, "Battling the Prefetcher: Exploring Coffee Lake (Part 1)", 2022. https://abertschi.ch/blog/2022/prefetching — experimental confirmation of the 4 KB boundary.

### Hardware: Apple Silicon
- (S) Apple Developer tech talk, "Tune CPU job scheduling for Apple silicon games". https://developer.apple.com/videos/play/tech-talks/110147 — "On Apple silicon, a cache line is 128 bytes long."
- (S) Apple, "Apple Silicon CPU Optimization Guide" (landing page; full guide needs a developer login). https://developer.apple.com/documentation/apple-silicon/cpu-optimization-guide — official source; not read directly.
- (S) Apple, "Determining system capabilities" (sysctl keys). https://developer.apple.com/documentation/kernel/1387446-sysctlbyname/determining_system_capabilities — `hw.cachelinesize`, per-perflevel cache sizes.
- (S) Apple, "Addressing architectural differences in your macOS code". https://developer.apple.com/documentation/apple-silicon/addressing-architectural-differences-in-your-macos-code — "Cache line sizes are different… Virtual memory page sizes are different."
- (S) Jim Cownie, "More M1 fun: Hardware Information", CPU fun. https://cpufun.substack.com/p/more-m1-fun-hardware-information — `hw.cachelinesize: 128`, `hw.pagesize: 16384`.
- (S) Wrenger et al., "Analyzing the memory ordering models of the Apple M1", J. Systems Architecture, 2024. https://www.sciencedirect.com/science/article/pii/S1383762124000390 — sysctl 128 B vs CTR_EL0/measured 64 B.
- (S) jia.je, "Apple M1 (Firestorm & Icestorm) 微架构评测", Dec 2024. https://jia.je/hardware/2024/12/26/apple-m1 — quotes Apple guide: L1D 64 B lines; L1 3 cycles → 16.
- (S) jia.je, "Apple M2 (Avalanche & Blizzard) 微架构评测", 2026. https://jia.je/hardware/2026/07/06/apple-m2/index.md — quotes Apple guide: L2 and SLC 128 B lines, M1–M4 sizes.
- (S) 7-cpu.com, "Apple M1". https://7-cpu.com/cpu/Apple_M1.html — L1 3 cycles, L2 18, RAM 18 cycles + 91 ns.
- (S) Andrei Frumusanu, "The 2020 Mac Mini Unleashed: Putting Apple Silicon M1 To The Test", AnandTech, 2020. https://www.anandtech.com/show/16252/mac-mini-apple-m1-tested — 96 ns DRAM; ~58 GB/s per core.
- (S) AnandTech, "The iPhone 12 & 12 Pro Review" (A14 Firestorm page), Nov 30 2020. https://www.anandtech.com/show/16192/the-iphone-12-review/2 — ROB 630; DTLB 256; L2 TLB 3072.
- (S) Wikipedia, "Apple M1". https://en.wikipedia.org/wiki/Apple_M1 — cache sizes, memory bandwidths.
- (S) xnu docs, "sme.md". https://github.com/apple-oss-distributions/xnu/blob/main/doc/arm/sme.md — SME/SVL in Apple's kernel.

### Hardware: branch prediction, SIMD, optimization manuals
- (S) Agner Fog, "The microarchitecture of Intel, AMD, and VIA CPUs" (manual 3), updated 2026-05-23. https://www.agner.org/optimize/microarchitecture.pdf — mispredict penalties by microarchitecture (Zen 4 15–18, Zen 5 15–25).
- (S) Agner Fog, "Optimizing software in C++" (manual 1). https://www.agner.org/optimize/optimizing_cpp.pdf — "approximately 15 - 25 clock cycles"; virtual calls predicted like switch.
- (S) Agner Fog, "Optimizing subroutines in assembly language" (manual 2), 2025. https://www.agner.org/optimize/optimizing_assembly.pdf — series overview.
- (S) AMD, "Software Optimization Guide for the AMD Zen5 Microarchitecture" (58455 Rev 1.00), Aug 2024. https://docs.amd.com/api/khub/documents/RCLISlZoOyWkKA9SYwLLDQ/content — mispredict 12–18 (15 typical); L1D 4–5 cycles; 64-byte alignment.
- (S) AMD, "Software Optimization Guide for the AMD Zen4 Microarchitecture" (57647). https://www.numberworld.org/blogs/2024_8_7_zen5_avx512_teardown/57647_zen4_sog.pdf — mispredict 11–18 (13 typical).
- (S) Intel, Optimization Reference Manual documentation changes, Aug 2023. https://cdrdv2-public.intel.com/821613/355308-Software-Optimization-Manual-048-Changes-Doc-2.pdf — Golden Cove notes.
- (S) Stack Overflow, "Why is processing a sorted array faster than processing an unsorted array?" (2012). https://stackoverflow.com/questions/11227809 — #1 voted question; branch prediction demo; vectorization caveats.
- (S) Stack Overflow Blog, "C++ Creator Bjarne Stroustrup Answers Our Top Five C++ Questions", Oct 11 2019. https://stackoverflow.blog/2019/10/11/c-creator-bjarne-stroustrup-answers-our-top-five-c-questions — Stroustrup's measurements on the sorted-array question.
- (S) Arm, "Introducing SVE" (102476). https://developer.arm.com/documentation/102476/0101/Introducing-SVE — 128–2048-bit VLA; NEON fixed 128.
- (S) Arm Learning Paths, "Migrate SIMD code to the Arm architecture". https://learn.arm.com/learning-paths/cross-platform/vectorization-comparison/1-vectorization — SSE↔NEON, AVX↔SVE mapping.
- (S) Arm Community, "Arm Scalable Matrix Extension (SME) Introduction". https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/arm-scalable-matrix-extension-introduction — SVL 128–2048.
- (S) NVIDIA Technical Blog, "Accelerating NVIDIA HPC Software with SVE on AWS Graviton3", Sept 19 2022. https://developer.nvidia.com/blog/accelerating-nvidia-hpc-software-with-sve-on-aws-graviton3 — A64FX 512-bit, Graviton3 256-bit SVE.
- (S) Eclectic Light Co., "What's in an M1 chip", Aug 2021. https://eclecticlight.co/2021/08/24/whats-in-an-m1-chip-and-what-does-it-do-differently — NEON 128-bit, no SVE on M1, 4 FP/SIMD units.

### Marked unverified / not opened but referenced
- **[unverified]** Exact slide wording of Acton's "Three Big Lies". Taken from the ACCU and Strumenta paraphrases; check against https://github.com/CppCon/CppCon2014.
- **[unverified]** Golden Cove ~17-cycle mispredict penalty. From a secondary site (dranirbanchakraborty.com), not from Intel or Agner directly.
- **[unverified]** Any direct Jonathan Blow quote specifically about "data-oriented design".
- **[unverified]** M1 explainer ROB/DRAM reasoning (docdroid PDF, anonymous).
