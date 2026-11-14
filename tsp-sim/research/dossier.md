# Research dossier: Groq TSP / LPU, for an educational cycle-level simulator

Compiled 2026-11-14 by the lead from four research reports, which stay in this
folder as the detailed evidence:

| Report | Focus |
|---|---|
| [01_tsp_isca2020.md](01_tsp_isca2020.md) | "Think Fast" (ISCA 2020), the single-chip TSP |
| [02_tsp_multiprocessor_isca2022.md](02_tsp_multiprocessor_isca2022.md) | "A Software-defined Tensor Streaming Multiprocessor" (ISCA 2022) |
| [03_recent_lpu.md](03_recent_lpu.md) | 2023-2026 material: NVIDIA Groq 3 LPX, Hot Chips 2026, SHIP, independent evaluations |
| [04_static_scheduling_background.md](04_static_scheduling_background.md) | VLIW, list / modulo scheduling, conflict resolution |

Rules used throughout:

- A claim marked with a source tag was read in a fetched document by the research agent.
- "(fig. reading)" means the value was read off a low-resolution figure and is less certain.
- "[derived]" means arithmetic or inference by us, not a statement in the source.
- Anything the simulator needs that no source gives is **ASSUMED** in the ledger (section 7), with the reasoning.

## 0. Sources and reachability

| Tag | Source | How it was read |
|---|---|---|
| **[TSP20]** | Abts et al., "Think Fast: A Tensor Streaming Processor (TSP) for Accelerating Deep Learning Workloads", ISCA 2020, DOI 10.1109/ISCA45697.2020.00023 | Full text. The Groq-hosted PDF now returns 404; read from the Wayback Machine capture `https://web.archive.org/web/2024id_/https://groq.com/wp-content/uploads/2024/02/2020-Isca.pdf`. Page numbers are proceedings pages 145-158. |
| **[TSP22]** | Abts et al., "A Software-defined Tensor Streaming Multiprocessor for Large-scale Machine Learning", ISCA 2022, DOI 10.1145/3470496.3527405 | Full text, from `https://cdn.sanity.io/files/chol0sk5/production/81d0c45ed70a10f1804bbd82f2d0076af1186ff0.pdf`. The PDF carries the ACM permission block and DOI, but who runs that CDN bucket is unconfirmed. ACM DL returned 403, Groq-hosted copies 404, Wayback 429. |
| **[HC22]** | Abts, Hot Chips 34 slides (2022), `https://hc34.hotchips.org/assets/program/conference/day2/Machine%20Learning/HotChips34%20-%20Groq%20-%20Abts%20-%20final.pdf` | Read. **Secondary** (a talk by the same first author). |
| **[NV-LPX]** | NVIDIA Technical Blog, "Inside NVIDIA Groq 3 LPX: The Low-Latency Inference Accelerator for the NVIDIA Vera Rubin Platform", 2026-03-16, `https://developer.nvidia.com/blog/inside-nvidia-groq-3-lpx-the-low-latency-inference-accelerator-for-the-nvidia-vera-rubin-platform/` | Read. Primary. Rack-level; little microarchitecture. |
| **[SHIP]** | Bitar et al. (Groq), "SHIP: SRAM-Based Huge Inference Pipelines for Fast LLM Serving", MLSys 2026, `https://proceedings.mlsys.org/paper_files/paper/2026/file/9c20f16b05f5e5e70fa07e2a4364b80e-Paper-Conference.pdf` | Read in full. Primary. An LPUv1 retrospective. |
| **[HC26-STH]** | ServeTheHome live blog of the Hot Chips 2026 talk "Think Fast: LPU Accelerator for Heterogeneous Compute", 2026-08-25, `https://www.servethehome.com/nvidias-groq-3-lpu-accelerators-for-heterogeneous-ai-compute-at-hot-chips-2026/` | Read. Independent, written live. |
| **[XPU]** | Golden et al., "The xPU-athalon: Quantifying the Competition of AI Acceleration", ISPASS 2026, `https://arxiv.org/abs/2604.10852` | Read in full. Independent; measured a 72-chip GroqRack. |
| **[GFLOW]** | GroqFlow user guide, `https://raw.githubusercontent.com/groq/groqflow/main/docs/user_guide.md` | Read. Primary. Repository archived 2025-07-31. |

**Unreachable, and therefore not used:**

- The Hot Chips 2026 slides themselves (paid registration only). The talk is known only through [HC26-STH].
- Tom's Hardware article bodies, SemiAnalysis and More Than Moore (paywalled or not retrievable).
- Groq's "Inside the LPU" blog (now redirects) and the GroqChip product brief (404).
- Groq patents (found in search results, not read).
- IEEE Xplore and ACM DL copies of the two ISCA papers (not needed for [TSP20]; 403 for [TSP22]).

## 1. The single-chip TSP [TSP20]

### 1.1 The idea

- The chip removes "all reactive elements in the hardware (e.g. arbiters, and caches)" ([TSP20] Abstract). Performance is "deterministic and precisely predictable from run-to-run" (Sec. IV-F).
- Scheduling moves to software: "it falls on the compiler to precisely schedule instructions" (Sec. II), and "the compiler's back-end can precisely track the position and time-of-use of any stream on-chip" (Sec. III).
- The compiler solves "a two-dimensional scheduling of instructions and data in both time and space" (Sec. III).
- There are no local register files or FIFOs (Sec. VI), and no producer/consumer synchronisation "except once at the beginning of the program" (Sec. VI).

### 1.2 Slices, tiles and lanes

- A functional slice is a column of 20 tiles. Each tile works on 16 lanes (a "superlane"), so the maximum vector length is 20 x 16 = 320 elements (Sec. II).
- Slice order, west to east (Fig. 2, Sec. II-B): **MXM | SXM | MEM43..MEM0 | VXM | MEM0..MEM43 | SXM | MXM**. MEM0 is nearest the VXM. C2C I/O sits with the SXM.
- There are 88 MEM slices (44 per hemisphere), 2 SXM instances, 4 MXM planes of 320x320 (2 per hemisphere) and one VXM with 16 ALUs per lane (Secs. II-B, III-C, III-D, III-E).
- All tiles of a slice run the same instruction stream. There are 144 instruction queues, split 6 + 14 + 44 + 16 + 44 + 14 + 6 across MXM, SXM, MEM, VXM, MEM, SXM, MXM (Sec. II; Fig. 2, fig. reading).

### 1.3 Streams

- Each lane has 64 logical streams: 32 eastward and 32 westward, identified by number 0..31 and direction (Sec. II).
- Each stream element is 1 byte. Wider types use several streams: int16 uses 2, int32 and fp32 use 4, aligned on groups such as SG4_0 = streams 0-3 (Sec. I-B).
- Streams are a chip-wide, architecturally visible stream register file (Sec. I-B).
- "On each tick of the core clock, the TSP propagates stream values by one stream register hop in the direction of flow" (Sec. V-c).
- Streams "simply flow (propagate) Eastward or Westward until they fall off the edge of the chip or are overwritten by a functional slice" (Sec. V-c). The hardware does not track origin or destination.
- A slice can overwrite a stream with its result instead of letting the old value propagate, and can choose the direction of its result, so a stream can be "turned around" at any slice (Secs. II-A, II-E).
- Fig. 4 shows 45 stream-register positions (SR0-SR44) per direction, with one register per group of 4 MEM slices (fig. reading, medium confidence). [HC22] slide 57 independently says "45 SRF stations across the superlane" (secondary).

### 1.4 Instruction set (Table I, [TSP20] p.149)

| Slice | Instructions |
|---|---|
| ICU | NOP N, Ifetch, Sync, Notify, Config, Repeat n,d |
| MEM | Read a,s; Write a,s; Gather s,map; Scatter s,map |
| VXM | unary op (e.g. mask, negate), binary op (e.g. add, mul, sub), type conversions, ReLU, TanH, Exp, RSqrt |
| MXM | LW (load weights to buffer), IW (install weights into the array), ABC (activation buffer control), ACC (accumulate int32 or fp32 result) |
| SXM | Shift up/down N, Permute map, Distribute map, Rotate stream, Transpose sg16 |
| C2C | Deskew, Send, Receive |

Other details: VXM has saturating and modulo variants of add and mul and produces no condition codes (Sec. III-C). No binary encoding is given apart from the 16-bit NOP repeat count (Sec. III-A1).

### 1.5 Timing

- Every instruction carries two parameters (Sec. III): **d_func**, "each instruction requires 1 or more cycles to produce its stream output", and **d_skew**, the relation between dispatch time and when the stream operands are needed.
- Eq. 4: **T = N + d_func + delta(j,i)**, where N is the number of tiles in the slice and delta(j,i) is the transit distance in cycles between stream registers j and i. With one hop per cycle, delta = |j - i| [derived].
- An instruction is issued to the southern tile and moves north one tile per cycle, so tile k executes k cycles later; data on the streams is staggered the same way (Sec. II-C, Fig. 6).
- NOP has a 16-bit repeat count; "Repeat n, d" repeats the previous instruction n times with d cycles between iterations (Table I, Sec. III-A1).
- A chip-wide Sync/Notify barrier takes 35 cycles (Sec. III-A2). Programs start with a preamble that ends in a Sync so that all slices share one logical time.
- **No numeric d_func or d_skew is given for any instruction.** This is the largest gap for a simulator.

### 1.6 Memory

- Each MEM slice has 13-bit addressing of 16-byte words per tile; a slice holds 2.5 MiB and the chip 220 MiB (Secs. II, II-B). An address therefore selects one 320-byte vector across the slice [derived].
- Each slice has pseudo-dual-port SRAM with 2 banks and can serve one read and one write in the same cycle if they target different banks (Sec. III-B).
- "Each instruction specifies the first hop direction (East or West)" (Sec. I-B).
- The compiler places concurrent operands in different MEM slices so that streams "pick up" operands en route to the MXM, and places weights so that transit to the MXM is short (Secs. IV-A, V-b).
- The common ResNet pattern is "Read -> Conv2D -> Requantize -> ReLU -> Write" (Sec. IV-C).
- SECDED ECC covers SRAM and stream registers (Sec. II-D).

### 1.7 MXM, VXM, SXM

- **MXM:** four independent 320x320 planes of multiply-accumulate cells. Weights are installed from streams, 16 streams per cycle per plane; all 409,600 weights load in under 40 cycles. With weights installed, "every cycle the MXM can generate a new int32 dot-product of input activations with installed weights". Inputs are int8 or fp16 (fp16 uses two byte-planes in tandem); results are int32 or fp32 (Secs. III-D, IV-D).
- [TSP22] Sec. 5.5 adds that MXM inputs are read from streams flowing outward and the output is written to streams flowing inward.
- **VXM:** a 4x4 mesh of vector ALUs per superlane, 16 ALUs per lane, 32-bit operands on SG4 groups. ALUs are stateless and can be chained "without committing the intermediate results to main memory" (Sec. III-C).
- **SXM:** lane shifters with a select, a bijective Permute of the 320 lanes, a Distribute that remaps or replicates the 16 lanes within each superlane, Rotate and Transpose (Sec. III-E).

### 1.8 Headline numbers

14 nm, 25x29 mm, 26.8B transistors, 900 MHz nominal (1 GHz used for the paper's arithmetic), 820 TeraOps/s peak, ResNet-50 at 20.4K images/s with batch size 1 ([TSP20] Abstract, Secs. II-B, V, VII). The paper quotes both 43 us and 49 us for ResNet-50 latency.

## 2. Multi-chip scaling [TSP22]

The simulator in this project is single-chip. This section records what a multi-chip extension would have to honour.

- **Topology:** 8 TSPs per node, fully connected; 9 nodes per rack; a Dragonfly variant up to 264 TSPs at 3 hops and 10,440 TSPs at 5 hops. Each TSP uses 7 local and 4 global links of 4 lanes at 25 Gb/s (Secs. 2.2, 2.3).
- **Vectors as flits:** one 320-byte vector is the unit of transfer, 328 bytes on the wire (Fig. 11).
- **Determinism across chips:** each TSP has its own clock. A Hardware Aligned Counter with a 252-cycle epoch is exchanged continuously; DESKEW pauses until the counter overflows; a Software Aligned Counter and RUNTIME_DESKEW compensate drift at run time (Sec. 3, Table 1, fn 4).
- **Measured link latency (intra-node):** min 209, mean about 216-217, max 228 cycles (Table 2).
- **Software-scheduled networking:** no hardware back-pressure, arbitration, virtual channels or link-layer retry. Routes and send times are fixed at compile time. Link errors use FEC, and an uncorrectable error triggers a software replay of the inference (Secs. 2.3, 4.4, 4.5).
- **Compiler's global role:** the model is partitioned across TSPs, one binary per TSP; communication is scheduled as a DAG of deadlines, and the compiler overlaps compute with communication to hide link latency. Its latency estimate was within 2% of measured for BERT (Secs. 3, 4.1, 5.1, 5.4).
- **The scheduling algorithm itself is not described** in the paper.
- Inconsistencies in the paper: counters exchanged "every 256 cycles" versus a 252-cycle epoch; 722 ns per hop in Sec. 5.6 versus about 241 ns implied by Table 2 [derived].

## 3. Recent material (2023-2026)

- **Corporate context:** Groq licensed its technology to NVIDIA (Groq press release, 2025-12-24). NVIDIA sells the second Groq silicon design, LP30, as "NVIDIA Groq 3" in LPX racks paired with Rubin GPUs ([NV-LPX]; details and URLs in report 03).
- **LPUv1** (the TSP of the ISCA papers): GlobalFoundries 14 nm, 230 MB SRAM, 235 GB/s chip-to-chip I/O over 11 logical ports, 300 ns per hop ([SHIP] Secs. 4.2, 7.1).
- **LP30:** Samsung 4 nm, 500 MB SRAM and 150 TB/s SRAM bandwidth per chip, 96 chip-to-chip links at 112 Gbps, 256 chips per rack ([NV-LPX] and the NVIDIA product page). Its clock, slice counts and instruction set changes are not public.
- **Same architecture:** [SHIP] Sec. 2.1 describes functional units as SIMD units "operating on 320-element vectors", each "issued one instruction per cycle", with "directional, arbitration-free buses that move data eastward and westward" and all instruction latencies "statically known".
- **Hot Chips 2026**, via [HC26-STH]: "This is a fully deterministic chip"; the compiler "schedules all resources, both processing and networking"; "There is no hardware flow control or virtual channels".

### Limitations reported

| Limitation | Evidence |
|---|---|
| Static shapes | [GFLOW]: the `inputs` argument "Dictates the maximum input size the model will support"; "pad your inference inputs to this expected input size". [SHIP] Sec. 7.2: dynamic context length and MoE routing are "mapped to static shapes with runtime-provided masks". |
| Batch size | [XPU]: "even simple batch size scaling is not supported" on the tested rack. [SHIP] Sec. 6: Bmax = ceil(number of KV caches that fit / pipeline depth). |
| Memory capacity | [SHIP]: capacity "typically requires partitioning across hundreds to thousands of chips". |
| Build time | [XPU]: build times "upwards of 4500 seconds", scaling linearly with chip count. |
| Operator coverage | [XPU]: "only a few hundred" PyTorch operators supported. |
| Peak throughput | [XPU]: "roughly 10x lower peak throughput than H100s" for LPUv1. |
| Determinism boundary | [SHIP] Sec. 7.2: host memory over PCIe is not deterministic and needs a resynchronisation instruction. |

The simulator inherits the first of these by construction: the toy compiler accepts only graphs with fixed shapes, and the transformer milestone uses a fixed sequence length.

## 4. Static scheduling background

Source tags in this section are defined in report 04, which lists each URL. "[S]" marks lecture notes (secondary).

### 4.1 Why the TSP is a VLIW-style contract

- VLIW machines expose resource timing to the compiler and let it choose what runs in parallel (Fisher, "Very Long Instruction Word Architectures and the ELI-512", ISCA 1983; Colwell et al., "A VLIW Architecture for a Trace Scheduling Compiler", ASPLOS 1987).
- Trace, superblock and hyperblock scheduling exist to schedule across branches (Colwell et al. 1987; Mahlke et al., MICRO 1992). A tensor graph with fixed shapes has no branches, so they are not needed here.

### 4.2 List scheduling with a reservation table

- ASAP start time is the longest path from the sources; ALAP is the mirror; slack is the difference ([S] Mahlke, EECS 583 lecture 11, slides 6-9).
- The standard list scheduler walks cycles forward, sorts ready operations by priority (commonly height, the distance to the exit) and places each one if a resource usage map shows its resources free ([S] Mahlke lecture 11, slides 12-15; [S] De Micheli, "Scheduling II").
- Resource-constrained scheduling is intractable in general, so heuristics are normal ([S] De Micheli; Lee et al. 1998 call space-time scheduling NP-complete, citing Sarkar 1989). Ullman 1975 is the usual citation, but its full text was unreachable.
- Graham's bound for list scheduling on n identical machines is 2 - 1/n (Graham, Bell System Technical Journal, 1966).

### 4.3 Conflict resolution techniques

- **Delay:** an operation whose resources are busy is tried in a later cycle ([S] Mahlke lecture 11). Groq expresses delays as explicit NOPs ([TSP20] Sec. III-A1).
- **Re-binding:** an operation may have several units that can run it; the scheduler tries another ([S] Mahlke lecture 13, slide 9; Nowatzki et al. 2013, eqs. 1-2).
- **Interval colouring:** the left-edge algorithm assigns lifetimes to registers and is optimal when the conflict graph is an interval graph ([S] Isshiki, Tokyo Tech HLS slides). Linear scan is the compiler analogue (Poletto and Sarkar, TOPLAS 1999).
- **Whole-path reservation:** the RAW compiler treats "a single-source, multiple-destination communication path as a single scheduling unit" and reserves contiguous time slots for it (Lee et al., ASPLOS 1998, Sec. 5).
- **Space-time routing graphs:** DRESC's modulo routing resource graph replicates the architecture along the time axis (Mei et al., DATE 2003); SPR does the same and pads the schedule when routing fails (Friedman et al., FPGA 2009); both borrow negotiated congestion from PathFinder (McMurchie and Ebeling, FPGA 1995).
- **Exact timing as an equation:** Nowatzki et al. (PLDI 2013) write T(src) + delay + hops + X = T(dst), where X is buffering. For the fully static PLUG architecture the mismatch is absorbed by NOP padding (their eq. 26). The TSP case is this equation with X = 0.

### 4.4 Modulo scheduling

- Modulo scheduling targets loops: it finds one schedule that repeats every II cycles using a modulo reservation table ([S] Mahlke lectures 12-13). Rau's 1994 paper was not readable, so its eviction step is unverified.
- It would matter for a TSP when the same step repeats, for example a matrix processed row by row using the ISA's Repeat. The milestones here are small straight-line graphs, so it is not used.

### 4.5 What Groq has published about its compiler

- [TSP20] states the problem (two-dimensional scheduling in time and space, Eq. 4) but not the algorithm.
- Patent US 11,868,908 (Groq; partly read) describes ordering instructions by a greedy algorithm or a SAT solver, then assigning relative delays implemented as NOPs, then binding to hardware.
- No source describes how stream numbers are allocated.

### 4.6 Synthesis used by this project (ours, not sourced)

- Use forward list scheduling over a single reservation table that covers units, MEM slices and stream cells in space and time.
- Treat exact arrival as an equality: consumer fire time = producer dispatch + d_func + transit.
- Reserve a value's whole path atomically, as RAW does.
- Park results in memory between tiles. A later MEM Read can be timed freely, so delaying a tile never breaks an earlier decision and the search always terminates.
- Two values in the same stream and direction can only collide if they are on the same diagonal (same t - x eastward, same t + x westward) and their position ranges overlap. This is our derivation and is checked by tests, not taken from a source.
- Make the compiler deterministic: no iteration over sets, sort keys ending in a unique integer, and a test that compiles under different `PYTHONHASHSEED` values.

## 5. Not found

Collected from the four reports. None of these is filled from memory.

- Numeric d_func and d_skew for any instruction; SRAM read latency; MXM pipeline depth; VXM per-operation latency ([TSP20]).
- Instruction encoding, queue depth, Ifetch latency ([TSP20]).
- Exact stream-register spacing: known only from a blurry Fig. 4 ([TSP20]) and one [HC22] slide.
- How VXM ALUs are wired for chaining within the 4x4 mesh ([TSP20]).
- How instructions that move data between superlanes (Permute, Shift) interact with the one-cycle-per-tile stagger ([TSP20]).
- The compiler's scheduling and stream-allocation algorithm ([TSP20], [TSP22]).
- Latencies of C2C send and receive instructions; clock-drift tolerance; FEC code ([TSP22]).
- LP30 microarchitecture: clock, slice and lane counts, instruction set ([NV-LPX], [HC26-STH]).
- The Hot Chips 2026 slides.

## 6. Design consequences for the simulator

1. **Every latency in the simulator is an assumption.** The sources give the form of the timing rule (Eq. 4) and the hop rate, not the per-instruction numbers.
2. **The topology and the instruction names can be sourced.** Slice order, stream counts and directions, instruction names and the ICU mechanism (NOP, Repeat, Sync, Notify) come from [TSP20].
3. **The toy chip is scaled down.** Counts such as MEM slices per hemisphere are reduced so a timeline is readable. Each reduction is an ASSUMED entry that names the sourced value it replaces.
4. **Multi-chip, C2C, ECC, Ifetch, Gather/Scatter and power are out of scope** and are documented as such.

## 7. ASSUMPTIONS LEDGER

Every parameter the simulator uses. "Sim value" is what the code uses in its default (toy) configuration. A second configuration with the sourced geometry (320 lanes, 44 MEM slices per hemisphere) is used by one test to show the code is parametric.

Status meanings:

- **SOURCED:** the sim value equals a value stated in a source.
- **ASSUMED:** no source gives the value, or the sim deliberately departs from the source. The reasoning says which.

### Geometry

| ID | Parameter | Sim value | Status | Source or reasoning |
|---|---|---|---|---|
| G1 | Lanes per superlane | 16 | SOURCED | [TSP20] Sec. II: "16-lane unit as a 'superlane'" |
| G2 | Tiles (superlanes) per slice | 1 | ASSUMED | Sourced value is 20 ([TSP20] Sec. II). Reduced so vectors have 16 elements and fit a readable trace. The sourced-geometry configuration uses 20. |
| G3 | Streams per direction | 32 | SOURCED | [TSP20] Sec. II: "32 streams Eastward, and 32 streams Westward" |
| G4 | Stream element width | 1 byte | SOURCED | [TSP20] Sec. I-B |
| G5 | Streams per value | int8: 1, fp16: 2, int32 and fp32: 4, on aligned groups | SOURCED for int16/int32/fp32 ([TSP20] Sec. I-B). ASSUMED for fp16 | fp16 as 2 streams follows from 1 byte per stream element [derived]. |
| G6 | Slice order west to east | MXM, SXM, MEM(k-1..0), VXM, MEM(0..k-1), SXM, MXM | SOURCED | [TSP20] Fig. 2, Sec. II-B |
| G7 | MEM slices per hemisphere | 8 | ASSUMED | Sourced value is 44 ([TSP20] Sec. II-B). Reduced for readability; 8 lets a 4-stream value occupy 4 distinct slices with room to spare. |
| G8 | Stream-register positions | one per slice (toy: 21 positions) | ASSUMED | Sourced reading is 45 positions with one per 4 MEM slices ([TSP20] Fig. 4, fig. reading). One per slice is simpler to explain and keeps "distance = number of slices". |
| G9 | Words per MEM slice | 8192 | SOURCED | [TSP20] Sec. II: "13-bits of physical addressing" |
| G10 | MXM planes per hemisphere | 1 | ASSUMED | Sourced value is 2 ([TSP20] Sec. III-D). Reduced for readability. |
| G11 | MXM plane size | lanes x lanes | SOURCED | [TSP20] Sec. III-D: 320x320 planes for 320 lanes. Scales with G1 x G2. |
| G12 | VXM ALUs per lane | 16 | SOURCED | [TSP20] Sec. III-C |
| G13 | SXM instances | 1 per hemisphere | SOURCED | [TSP20] Sec. III-E |
| G14 | Instruction queues | one per MEM slice, one per VXM ALU, one per MXM plane, one per SXM | SOURCED for MEM (44 queues for 44 slices) and VXM (16 for 16 ALUs), read from [TSP20] Fig. 2. ASSUMED for MXM and SXM | Fig. 2 shows 6 queues per MXM and 14 per SXM, but the paper does not say what each controls. |

### Timing

| ID | Parameter | Sim value | Status | Source or reasoning |
|---|---|---|---|---|
| T1 | Stream hop rate | 1 position per cycle | SOURCED | [TSP20] Sec. V-c |
| T2 | Transit time between positions i and j | abs(i - j) cycles | SOURCED (derived) | Eq. 4 with T1 |
| T3 | Where a result appears | on the next position in the chosen direction, d_func cycles after dispatch | ASSUMED | Based on [TSP20] Sec. II-A: a slice's result overwrites the value that would have propagated to the next slice. The paper does not define the exact cycle accounting. |
| T4 | When operands are sampled (d_skew) | on the dispatch cycle, for every instruction | ASSUMED | [TSP20] defines d_skew but gives no values. Zero skew is the simplest consistent choice. |
| T5 | Tile stagger | completion time adds (tiles - 1) cycles; the simulator runs in the logical time of tile 0 | SOURCED form, ASSUMED treatment | Eq. 4's N term. Instructions and data are staggered identically, so simulating tile 0's time and adding N - 1 at the end is equivalent for operations that stay within a superlane. |
| T6 | d_func, MEM Read | 2 | ASSUMED | Not in any source. One cycle of SRAM access plus one to drive the stream. |
| T7 | d_func, MEM Write | 1 (data readable by a Read dispatched 1 or more cycles later) | ASSUMED | Not in any source. |
| T8 | d_func, VXM add, sub, relu, neg, mask, cast | 1 | ASSUMED | Not in any source. Simple operations take the minimum the paper allows ("1 or more cycles"). |
| T9 | d_func, VXM mul | 2 | ASSUMED | Not in any source. Chosen to differ from T8 so mixed latencies are visible. |
| T10 | d_func, VXM exp, tanh, rsqrt | 4 | ASSUMED | Not in any source. Transcendentals are given a longer pipeline. |
| T11 | d_func, MXM IW | 1 (weights usable by an ABC dispatched 1 or more cycles later) | ASSUMED | Not in any source. |
| T12 | d_func, MXM ABC (activation in to result out) | 3 | ASSUMED | Not in any source. [HC22] slide 28's "20 cycle execution" matches the 20-tile stagger and is covered by T5. |
| T13 | d_func, SXM Distribute, Permute, Shift | 2 | ASSUMED | Not in any source. |
| T14 | NOP repeat count | 16 bits | SOURCED | [TSP20] Sec. III-A1 |
| T15 | Sync/Notify barrier | 35 cycles | SOURCED | [TSP20] Sec. III-A2 |
| T16 | Instructions per queue per cycle | 1 | SOURCED | [SHIP] Sec. 2.1: "Each FU is issued one instruction per cycle" |
| T17 | Core clock, used only to convert cycles to time in reports | 900 MHz | SOURCED | [TSP20] Abstract; [TSP22] Sec. 5.2 |

### Behaviour

| ID | Parameter | Sim value | Status | Source or reasoning |
|---|---|---|---|---|
| B1 | Stream fate | flows until it leaves the chip edge or is overwritten | SOURCED | [TSP20] Sec. V-c |
| B2 | Reading a stream | does not consume it; the value keeps flowing | SOURCED | [TSP20] Sec. II-A: the value is "accessed as operands" and then propagates |
| B3 | Result direction | chosen per instruction | SOURCED | [TSP20] Secs. I-B, II-E |
| B4 | MEM accesses per slice per cycle | 1 instruction (a Read or a Write) | ASSUMED | Sourced behaviour is 1 read plus 1 write if on different banks ([TSP20] Sec. III-B). Banks are not modelled. |
| B5 | MEM word | one address holds one vector of `lanes` bytes | SOURCED (derived) | [TSP20] Sec. II-B |
| B6 | MXM numeric types | int8 in, int32 out; fp16 in, fp32 out | SOURCED | [TSP20] Secs. III-D, IV-D |
| B7 | fp16 on one MXM plane | one plane handles `lanes` fp16 elements | ASSUMED | Sourced: fp16 uses "two 320x320 byte-planes in tandem" ([TSP20] Sec. III-D). With one plane per hemisphere (G10) the toy lets a single plane do it. |
| B8 | Weight install rate | up to 16 streams per IW per cycle | SOURCED | [TSP20] Sec. III-D: "16 streams each with 16 bytes ... on every cycle" |
| B9 | MXM instruction set | IW and ABC only; ABC emits the result directly | ASSUMED | LW and ACC exist in Table I. The toy folds the weight buffer into IW and the accumulator into ABC. |
| B10 | MXM stream directions | operands read from outward-flowing streams, result written inward | SOURCED | [TSP22] Sec. 5.5 |
| B11 | VXM operation set | add, sub, mul, neg, mask, relu, tanh, exp, rsqrt, cast | SOURCED names ([TSP20] Table I). ASSUMED: wrap-around integer arithmetic, and cast between fp32 and fp16 | Table I lists "type conversions" between fixed and floating point only. |
| B12 | VXM chaining | an ALU may take an operand from any other ALU's result on the cycle that result is produced | ASSUMED | Chaining is sourced ([TSP20] Sec. III-C); its wiring and timing are not. |
| B13 | SXM operations | Distribute, Permute, Shift | SOURCED names | [TSP20] Table I. Rotate and Transpose are omitted. |
| B14 | Program start | every queue begins with Sync; one queue issues Notify | SOURCED | [TSP20] Sec. III-A2 |
| B15 | Instruction fetch | queues are preloaded; Ifetch is not modelled | ASSUMED | Sourced behaviour: instructions are fetched from MEM via streams ([TSP20] Sec. III-A3). |
| B16 | Validity of stream registers | each register is either empty or holds a value with a debug name | ASSUMED | The hardware has no valid bit or names. These exist only so the simulator can check that operands arrive on time. |
| B17 | Not modelled | C2C links, ECC, Gather/Scatter, Config, power, MEM banks | ASSUMED (omission) | All are sourced features left out to keep the simulator small. |

### Compiler policy (all ASSUMED; the sources do not describe Groq's algorithm)

| ID | Parameter | Sim value | Reasoning |
|---|---|---|---|
| C1 | Scheduling algorithm | list scheduling of rigid tiles with reservation tables | See section 4. |
| C2 | Tile shape | Read -> op chain -> Write | Mirrors the sourced pattern "Read -> Conv2D -> Requantize -> ReLU -> Write" ([TSP20] Sec. IV-C). |
| C3 | Tie-breaking | topological index, then lowest unit index, then lowest stream number | Makes the compiler itself deterministic. |
