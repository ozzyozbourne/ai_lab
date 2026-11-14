# Research dossier — Groq TSP / LPU simulator

Compiled 2026-11-14 by the lead engineer from four research reports. The full
reports, with verbatim quotes and per-claim citations, are in `research/raw/`:

| Tag | Report | Focus |
|---|---|---|
| **[R1]** | `raw/01-tsp-isca2020.md` | Abts et al., "Think Fast: A Tensor Streaming Processor (TSP)…", ISCA 2020 |
| **[R2]** | `raw/02-tsp-multiprocessor-isca2022.md` | Abts et al., "A Software-defined Tensor Streaming Multiprocessor…", ISCA 2022 |
| **[R3]** | `raw/03-recent-lpu.md` | 2023–2026 material: NVIDIA Groq 3 LPX blog, Hot Chips 2026 coverage, independent evaluations |
| **[R4]** | `raw/04-vliw-static-scheduling.md` | VLIW, list/modulo scheduling, reservation tables, routing-aware scheduling |

Citation style in this file: `[R1 §2.4]` means section 2.4 of report R1, which
in turn cites the page, figure or table of the primary source. Three labels are
used for the status of a statement:

- **SOURCED** — stated in a source that a research agent opened and read in this project.
- **INFERRED** — arithmetic or a reading of a figure, derived from sourced statements.
- **ASSUMED** — chosen by us because no source gives it. Section 7 (the ledger) lists every such choice.

---

## 1. What could and could not be read

| Source | Status |
|---|---|
| ISCA 2020 TSP paper (primary) | **Read in full** (10 pages, text and figures) from a CDN copy; the groq.com, Wayback and mirror copies were unreachable [R1 §1] |
| ISC 2020 ML-hardware workshop slides (Abts) | Read; secondary [R1 §1] |
| ISCA 2022 multiprocessor paper (primary) | **Read in full** (14 pages) [R2 §1] |
| Hot Chips 34 (2022) slides (Abts) | Text layer only; secondary [R2 §1] |
| NVIDIA blog "Inside NVIDIA Groq 3 LPX" (16 Mar 2026) | **Read in full** [R3 §1] |
| NVIDIA follow-up benchmark blog (24 Aug 2026), LPX product page | Read [R3 §1] |
| Hot Chips 2026 talk "Think Fast: LPU Accelerator for Heterogeneous Compute" | On the programme, but the **slide PDF returned HTTP 401**. Content known only through press live-blogs (ServeTheHome, Tom's Hardware) [R3 §2.3] |
| "xPU-athalon" (Harvard, arXiv:2604.10852), independent evaluation on a 72-chip GroqRack | Groq sections read [R3 §1] |
| GroqFlow user guide (GitHub) | Read [R3 §1] |
| SemiAnalysis Feb 2024 | Free portion only; rest paywalled [R3 §1] |
| Groq compiler patent US12222894B2 | Read (first ~75%) [R4 §1] |
| Scheduling literature (Fisher 1983, superblock/hyperblock, DRESC, EMS, SPR, Raw, SDC, course notes) | Read [R4 §1] |
| Rau 1994 (iterative modulo scheduling) full text, Leiserson–Saxe PDF, Kogge/Davidson pipeline theory | **Not reachable**; known from abstracts, course notes or not at all [R4 §1, §4] |
| Groq "Inside the LPU" blog (2025), TruePoint material, Artificial Analysis primary pages, Argonne evaluations, EE Times, Chips and Cheese | **Not read** [R3 §5] |

---

## 2. The single chip (ISCA 2020)

### 2.1 Organisation

- The chip is organised by **function, in vertical slices**, not as a grid of
  identical cores. Slice types: MEM (SRAM), VXM (vector ALUs), MXM (matrix
  multiply), SXM (switch: shift/permute/transpose), C2C (chip-to-chip), each
  driven by instruction control units (ICUs) [R1 §2.3, §2.6]. SOURCED.
- One row, West→East: `MXM | SXM | MEM ×44 | VXM | MEM ×44 | SXM | MXM`,
  with the VXM at the centre [R1 §2.3]. SOURCED (Fig. 2).
- Every slice is a stack of **20 tiles**; each tile handles **16 lanes** (a
  "superlane"), so a full vector is **320 one-byte elements** [R1 §2.3]. SOURCED.
- **144 instruction queues**, split 6/14/44/16/44/14/6 across the slice groups
  [R1 §2.3]. The total is SOURCED; the split is read from Fig. 2. A slide deck
  shows 3 more per C2C block (150) — an unresolved conflict [R1 §4].

### 2.2 Streams

- **32 streams eastward and 32 westward**, each one byte per lane. Wider types
  span aligned stream groups: int16 = 2 streams, int32 and fp32 = 4 [R1 §2.4]. SOURCED.
- A value moves **one stream-register hop per clock** in its direction of flow,
  with no routing or flow control, "until they fall off the edge of the chip or
  are overwritten by a functional slice" [R1 §2.4]. SOURCED.
- Any slice a value passes can read it; a slice that produces a result
  overwrites the stream at its own position; a slice chooses the direction of
  its result, so a value can be "turned around" [R1 §2.4]. SOURCED.
- Stream registers are numbered 0..44 per direction in Fig. 4, with one register
  stage per *quad* of MEM slices. This is a reading of a small figure (medium
  confidence). A full crossing therefore takes about 45 cycles — INFERRED, never
  stated in the paper [R1 §2.3].
- There are no local register files or FIFOs: the only place a value can wait is
  memory [R1 §2.4].

### 2.3 Timing model

- An instruction is issued to the bottom tile of its slice and moves north one
  tile per cycle; superlane *k* of a vector lags superlane *k−1* by one cycle
  (a diagonal wavefront) [R1 §2.4, §2.5]. SOURCED.
- The paper's timing equation: **T = N + d_func + δ(j, i)** — N tiles in the
  slice, d_func the instruction's functional delay, δ the stream transit between
  producer and consumer positions [R1 §2.5]. SOURCED.
- `d_func` ("1 or more cycles") and `d_skew` (dispatch-to-operand offset) are
  defined, but **no per-instruction values are published anywhere we could
  read** [R1 §4 item 1]. The simulator must assume all of them.
- ICU instructions: `NOP N` (16-bit repeat count), `Repeat n,d`, `Ifetch`
  (640 bytes of program text from a stream), `Sync`/`Notify` (chip-wide barrier,
  35 cycles), `Config` [R1 §2.5]. SOURCED.

### 2.4 Memory

- 88 MEM slices, 2.5 MiB each, 220 MiB total; 13-bit addressing of 16-byte
  words per tile, so one address yields a full 320-byte vector [R1 §2.7]. SOURCED.
- Two banks per slice; a slice serves **one read and one write per cycle if
  they target different banks** (pseudo-dual-port) [R1 §2.7]. SOURCED. Whether
  two reads in one cycle are possible is not stated.
- Whether the bank bit is inside the 13-bit address is unresolved: the paper's
  capacity implies it is, a slide implies it is not [R1 §4 item 5].
- The compiler places operands that must be on streams at the same time in
  **separate MEM slices**; streams "pick up" operands en route [R1 §2.7]. SOURCED.
- Compiler-placed weights near the MXM (MEM43) beat hand placement mid-memory
  (MEM22) because of transit delay [R1 §2.7]. SOURCED.

### 2.5 Compute slices

- **MXM**: four 320×320 planes of multiply-accumulate cells (two per
  hemisphere, at the edges). Weights are installed from 16 streams at a time;
  all 409,600 weights load "in less than 40 cycles". int8 inputs accumulate to
  int32; fp16 uses two byte-planes in tandem and accumulates to fp32 "with only
  a single rounding step at the end" [R1 §2.8]. SOURCED. The 2022 paper states
  the unit operation as `[1×K]×[K×320]` with K=320 for int8 and K=160 for fp16
  [R2 §7]. SOURCED. MXM inputs arrive on outward-flowing streams and results
  leave on inward-flowing streams [R2 §7].
- **VXM**: 16 ALUs per lane (4×4 mesh per superlane), 5,120 total, 32-bit
  operands on aligned 4-stream groups, stateless, chainable. Ops: unary, binary
  (add/sub/mul with saturating and modulo variants), type conversion, ReLU,
  TanH, Exp, RSqrt [R1 §2.6, §2.9]. SOURCED.
- **SXM**: shift lanes up/down by N with select, permute (320-lane bijection),
  distribute (within a 16-lane superlane), rotate, transpose [R1 §2.6]. SOURCED.
- Typical layer pattern: "Read → Conv2D → Requantize → ReLU → Write" [R1 §2.5]. SOURCED.

### 2.6 Determinism and the compiler

- "guaranteeing determinism by eliminating all reactive elements in the
  hardware (e.g. arbiters, and caches)" [R1 §2.11]. SOURCED.
- "the compiler is solving a two-dimensional scheduling of instructions and data
  in both time and space"; it tracks 144 program queues cycle by cycle, inserts
  NOPs, manages banks, and allocates all memory [R1 §2.10]. SOURCED.
- **No source describes the scheduling algorithm Groq's compiler uses**
  [R1 §4, R2 §9, R4 §2.8]. Ours is our own design (section 5).

### 2.7 Chip-level numbers (context only; the simulator counts cycles)

14 nm, 25×29 mm, 26.8 B transistors, 900 MHz nominal clock (but the paper's
peak figures are computed at 1 GHz), 20.4 K images/s ResNet-50 at batch 1
[R1 §2.1, §2.2]. The paper is internally inconsistent on ResNet-50 latency
(43 µs vs 49 µs) and gives no absolute power [R1 §4].

---

## 3. Many chips (ISCA 2022) — recorded, not simulated

The simulator models **one chip**. The multi-chip material is summarised here
because it shows how far the same idea extends; none of these numbers enter the
code.

- 8 TSPs per node, each with 7 local + 4 global links (4 lanes × 25 Gbps per
  link); 264 TSPs within 3 hops; design limit 10,440 TSPs within 5 hops
  [R2 §2]. The largest *measured* system in the paper is 300 TSPs [R2 §9].
- Chips have separate clocks. Each keeps an 8-bit **hardware aligned counter**
  (epoch 252 cycles) that is exchanged with neighbours over a spanning tree;
  link latency is measured as half a round trip (Table 2: mean ≈217, units not
  printed). `DESKEW`, `TRANSMIT`, `RUNTIME_DESKEW` align program start and
  cancel drift [R2 §3].
- The network is **scheduled, not routed**: no back-pressure, no arbitration,
  no virtual channels; the flit is one 320-byte vector (328 bytes on the wire);
  errors are handled by forward error correction plus a software replay of the
  inference, never a link-level retry, because a retry would change arrival
  times [R2 §4].
- The compiler partitions the model, emits one binary per chip, and its latency
  estimate was within 2% of measurement for BERT-Large on 4 TSPs (24,240 runs,
  all within 1300 µs) [R2 §5, §6].

## 4. Recent material (2023–2026)

- **NVIDIA Groq 3 LPU ("LP30")**, per NVIDIA's March 2026 blog: 500 MB of SRAM
  per chip, the same MXM/VXM/SXM/MEM unit names, "320-byte vectors as the unit
  of work", 96 chip-to-chip links at 112 Gbps, 256 chips per rack, a compiler
  that schedules "down-to-the-clock cycle" [R3 §2.1]. Vendor statements.
- **Not public for LP30**: clock, slice and lane counts, stream organisation,
  instruction set, per-instruction latencies [R3 §5]. The simulator's
  architecture is therefore based on the 2020 paper, not on LP30.
- The process node ("Samsung 4 nm") is press-sourced only [R3 §2.1].
- **Limitations seen by others**, which the simulator mirrors as design rules:
  - *Static shapes.* GroqFlow compiles against a fixed input shape and tells
    users to pad to it [R3 §2.7].
  - *Batch.* The design target is batch 1 or very small batches; an independent
    study could not get batch scaling to work on its hardware [R3 §2.6].
  - *Capacity.* 220–230 MB (gen 1) or 500 MB (LP30) per chip, so large models
    need tens to thousands of chips [R3 §2.5].
  - *Compile cost.* Build times "upwards of 4500 seconds" on a GroqRack [R3 §2.7].
  - *Operator coverage.* A few hundred PyTorch operators, no fused attention
    op on gen-1 hardware [R3 §2.7].
- Benchmarks (3,431 tokens/s on Gemma 4 31B via Artificial Analysis, under
  conditions chosen by NVIDIA) are recorded in [R3 §2.4] and are not used here.

## 5. Static scheduling background and what we borrow

| Idea | Source | Use in this project |
|---|---|---|
| VLIW: the compiler, not the hardware, guarantees that operations issued together do not conflict; "No arbitration is necessary, since the paths of the addresses will never cross" (Fisher 1983, on predicting memory banks) | [R4 §2.1] | The hardware model has no arbiter; a conflict is a compile error or a simulator fault, never a stall |
| Trace/superblock/hyperblock scheduling exist to schedule across branches | [R4 §2.2] | Not needed: a forward pass is a DAG with no control flow |
| Resource-constrained scheduling is NP-hard; list scheduling with height (critical-path) priority is the standard heuristic; "original order" as last tie-break | [R4 §2.3] | Operation-driven list scheduling, priority = height, ties by node id |
| Reservation tables: compare an instruction's resource vector with the composite of everything already scheduled (Proebsting & Fraser 1994) | [R4 §2.5] | Separate reservation tables for unit issue slots, memory ports, MXM planes and stream cells |
| Time-expanded networks: a stream lane is a path with transit 1 and **no holdover arcs** | [R4 §2.6] | A flight on a stream is a diagonal in (position, cycle); the reservation key is the diagonal id |
| Raw space-time scheduling: treat each communication path as one scheduling unit with its consumer | [R4 §2.6] | An operation is placed together with all its operand routes, atomically |
| Delay matching by adding storage on the early branch (Nowatzki 2018; Cascade 2024) | [R4 §2.7] | The early operand is parked in MEM and re-read; MEM is the only buffer |
| Conflict resolution by alternative resource, delay, buffering, re-placement | [R4 §2.5] | The compiler's ladder: other stream → other ALU / other parking slice → delay |
| Modulo scheduling (MII = max(ResMII, RecMII), modulo reservation table) | [R4 §2.4] | Not used. In single-sequence decode each token depends on the previous one, so iterations cannot overlap. This is the research agent's reasoning, not a cited result |

Unverified items the reports flag: the original pipeline-collision theory
(Davidson; Kogge's textbook) and "Hu's algorithm is optimal highest-level-first"
are recollections, not read sources [R4 §4]. We do not rely on them.

## 6. Open conflicts between sources

| Topic | Conflict | How the simulator handles it |
|---|---|---|
| Clock | 900 MHz nominal vs 1 GHz in bandwidth math [R1 §2.1] | Counts cycles; converts to time at 900 MHz for display only (L-C1) |
| Instruction queues | 144 (paper) vs 150 (slides) [R1 §4] | Does not reproduce either count; see L-I1 |
| Bank addressing | bank bit inside or outside the 13-bit address [R1 §4] | Inside (L-M2), which matches the paper's capacity |
| SRAM per chip, gen 1 | 220 MiB (papers) vs 230 MB (SemiAnalysis) [R1 §2.7, R3 §2.5] | Uses the paper's organisation |
| HAC period | 252 cycles vs "every 256 cycles" [R2 §3] | Not simulated |
| C2C links | 16 (2020 paper) vs 11 used per TSP (2022) [R1 §2.1, R2 §2] | Not simulated |

---

## 7. ASSUMPTIONS LEDGER

Every parameter the simulator needs. `tsp/config.py` carries each ledger ID next
to the constant it governs, and a test checks that every ID used in the code
exists in this table.

Two presets exist. **paper** uses the published organisation where one exists.
**toy** is a scaled-down chip that keeps the timelines readable; every toy
value that differs from paper is, by definition, ASSUMED.

Status key: **SOURCED** (citation), **INFERRED** (derived from a sourced
statement), **ASSUMED** (our choice, with the reasoning).

### 7.1 Geometry and streams

| ID | Parameter | paper preset | toy preset | Status | Source / reasoning |
|---|---|---|---|---|---|
| L-G1 | Lanes per superlane | 16 | 16 | SOURCED | [R1 §2.3] |
| L-G2 | Superlanes = tiles per slice | 20 | 2 | SOURCED (20); toy ASSUMED | [R1 §2.3]. Toy: smallest size that fits a 16-wide fp16 matrix-vector product (see L-X2) |
| L-G3 | Vector length in lanes (= G1 × G2) | 320 | 32 | SOURCED (320); toy follows G2 | [R1 §2.3] |
| L-G4 | Stream element width | 1 byte per lane | same | SOURCED | [R1 §2.4] |
| L-G5 | Streams per direction | 32 | 32 | SOURCED | [R1 §2.4] |
| L-G6 | Streams per element type | int8 1, int32 4, fp32 4 | same | SOURCED | [R1 §2.4] |
| L-G7 | Streams for fp16 | 2 | 2 | ASSUMED | The paper says int16 uses 2 streams and that fp16 uses "two byte-planes in tandem" in the MXM [R1 §2.8]; fp16 on a stream pair is the natural reading but is not stated |
| L-G8 | Stream-group alignment (pairs on even ids, quads on multiples of 4) | yes | yes | SOURCED | [R1 §2.4] |
| L-G9 | Slice order West→East: MXM, SXM, MEM×M, VXM, MEM×M, SXM, MXM | yes | yes | SOURCED | [R1 §2.3] |
| L-G10 | MEM slices per hemisphere (M) | 44 | 16 | SOURCED (44); toy ASSUMED | [R1 §2.7]. Toy: 16 lets one install wave read 16 weight streams from distinct slices (L-X3, L-M4) |
| L-G11 | Stream-register positions | one per slice: 2M+5 (93) | 2M+5 (37) | ASSUMED | The paper's Fig. 4 shows one register stage per quad of MEM slices and ≈45 positions [R1 §2.3]; that mapping comes from a small figure. One position per slice is simpler and makes every slice individually addressable in space. Consequence: our paper preset takes 92 hops to cross, about twice the inferred real figure |
| L-G12 | Hop rate | 1 position per cycle | same | SOURCED | [R1 §2.4] |
| L-G13 | A value flows until overwritten or off the edge; passing slices can read it without consuming it | yes | yes | SOURCED | [R1 §2.4] |
| L-G14 | A producing slice chooses its result direction | yes | yes | SOURCED | [R1 §2.4] |
| L-G15 | A unit may read operands from either direction at its position | yes | yes | ASSUMED | Not stated in general. MXM is restricted by L-X6 |
| L-G16 | Tile stagger: superlane k runs k cycles after superlane 0 | simulated as superlane 0 only | same | SOURCED mechanism, ASSUMED abstraction | [R1 §2.5]. All superlanes do the same thing k cycles later, so we simulate one wavefront and report `cycles + (tiles − 1)` as the completion time of the last superlane |

### 7.2 Timing

All cycle counts below are **ASSUMED**: the paper defines d_func as "1 or more
cycles" and publishes no values [R1 §4 item 1]. We chose small values, and made
them differ between unit types so that the timelines show the delay-matching
problem. Changing any of them changes cycle counts but not correctness; a test
re-runs a milestone with different latencies to show this.

| ID | Parameter | Value | Status | Source / reasoning |
|---|---|---|---|---|
| L-T1 | Timing rule: an instruction issued at cycle t samples its operands at t + d_skew and its result is on the stream at its own position at t + d_skew + d_func; a consumer δ positions away sees it δ cycles later | — | SOURCED form | Paper's T = N + d_func + δ [R1 §2.5], minus N (see L-G16), plus d_skew as defined in the paper |
| L-T2 | d_skew, every instruction | 0 | ASSUMED | Concept sourced, values not published. Kept as a per-instruction field |
| L-T3 | d_func, MEM Read | 2 | ASSUMED | One cycle of SRAM access plus one to drive the stream register |
| L-T4 | d_func, MEM Write: a word written with sample cycle t is seen by a Read whose sample cycle is ≥ t + d_func | 1 | ASSUMED | Minimal |
| L-T5 | d_func, VXM arithmetic (add, sub, mul, relu, requant, casts) | 1 | ASSUMED | Minimum allowed by the paper |
| L-T6 | d_func, VXM transcendental (exp, rsqrt, tanh) | 3 | ASSUMED | Longer than arithmetic, to make latencies heterogeneous |
| L-T7 | d_func, MXM weight install: a row installed with sample cycle t is used by a matvec whose sample cycle is ≥ t + d_func | 1 | ASSUMED | Minimal |
| L-T8 | d_func, MXM matrix-vector product | 3 | ASSUMED | Capture, multiply, accumulate-and-round |
| L-T9 | d_func, SXM shift / permute / distribute | 1 | ASSUMED | Minimum allowed |
| L-T10 | NOP repeat count | 16 bits (max 65,535) | SOURCED | [R1 §2.5] |
| L-C1 | Clock used to convert cycles to time for display | 900 MHz | SOURCED (nominal) | [R1 §2.1]; display only |

### 7.3 Instruction control

| ID | Parameter | Value | Status | Source / reasoning |
|---|---|---|---|---|
| L-I1 | Instruction queues | one per MEM slice, per VXM ALU, per MXM plane, per SXM unit | ASSUMED | The paper has 144 queues split 6/14/44/16/44/14/6 [R1 §2.3] but does not say what each MXM or SXM queue drives. MEM (1 per slice) matches the paper; VXM (16) matches the count; MXM and SXM do not |
| L-I2 | Instructions issued per queue per cycle | MEM 2 (one read + one write), others 1 | ASSUMED | Paper: "each can issue one or more instructions per cycle" [R1 §2.5] |
| L-I3 | Program start: all queues aligned at cycle 0 | — | ASSUMED abstraction | Real programs start with a Sync/Notify barrier (35 cycles, [R1 §2.5]) that we do not simulate |
| L-I4 | Queues are preloaded with the whole program | — | ASSUMED abstraction | Real queues are refilled with Ifetch [R1 §2.5]; not modelled |
| L-I5 | Not modelled: Repeat, Config, Gather, Scatter, Rotate, Transpose, C2C | — | scope | Listed in [R1 §2.6] |

### 7.4 Memory

| ID | Parameter | paper | toy | Status | Source / reasoning |
|---|---|---|---|---|---|
| L-M1 | Banks per MEM slice | 2 | 2 | SOURCED | [R1 §2.7] |
| L-M2 | Addresses per bank | 4096 | 64 | INFERRED (paper); toy ASSUMED | 13-bit address including the bank bit reproduces the paper's 2.5 MiB per slice; a slide contradicts this [R1 §4 item 5] |
| L-M3 | One address holds one byte per lane; a Read puts a full vector on one stream | yes | yes | SOURCED | [R1 §2.7] |
| L-M4 | Ports per slice per cycle: at most one read and one write, on different banks | yes | yes | SOURCED | [R1 §2.7] |
| L-M5 | Two reads (or two writes) in one slice in one cycle | forbidden | forbidden | ASSUMED | Not stated; conservative |
| L-M6 | The host places weights and inputs in memory before cycle 0 and reads outputs after the last cycle | yes | yes | SOURCED for the model; ASSUMED for inputs and outputs | The paper describes a PCIe DMA engine that emplaces a model in memory [R1 §2.1]; it does not describe how inputs and results are exchanged, so we use the same path |

### 7.5 VXM

| ID | Parameter | Value | Status | Source / reasoning |
|---|---|---|---|---|
| L-V1 | ALUs | 16 | SOURCED count | [R1 §2.9]: 16 ALUs per lane. One queue per ALU is INFERRED from the 16 VXM queues |
| L-V2 | Each ALU accepts a new instruction every cycle (fully pipelined) | yes | ASSUMED | Not stated |
| L-V3 | ALU-to-ALU chaining goes through the streams at zero transit, not through a private mesh | yes | ASSUMED | The paper says ALUs can be chained [R1 §2.6] but not how |
| L-V4 | Operations: add, sub, mul, relu, exp, rsqrt, tanh, type conversion | — | SOURCED | [R1 §2.6] |
| L-V5 | `requant`: arithmetic right shift of int32, then saturate to int8 | — | ASSUMED semantics | "Requantize" is named [R1 §2.5]; its definition is not |
| L-V6 | `cast` fp32→fp16 (round to nearest even) and int8→int32 | — | ASSUMED semantics | "type conversions" are named [R1 §2.6]; these particular ones are not |
| L-V7 | int32 add/sub/mul wrap modulo 2³² | — | SOURCED variant | `add_mod`, `mul_mod` [R1 §2.6] |

### 7.6 MXM

| ID | Parameter | paper | toy | Status | Source / reasoning |
|---|---|---|---|---|---|
| L-X1 | Planes | 4 (2 per hemisphere; `planes_per_mxm = 2`) | same | SOURCED | [R1 §2.8] |
| L-X2 | Unit operation `[1×K]×[K×lanes]`; K ≤ lanes for int8, K ≤ lanes/2 for fp16 | 320 / 160 | 32 / 16 | SOURCED (paper); toy follows L-G3 | [R2 §7] |
| L-X3 | Weight streams sampled per install cycle | ≤ 16 | ≤ 16 | SOURCED | [R1 §2.8]: 16 streams per plane per cycle. So ≤16 int8 rows or ≤8 fp16 rows per cycle |
| L-X4 | Numerics: int8×int8 → int32; fp16×fp16 summed exactly, rounded once to fp32 | — | — | SOURCED | [R1 §2.8]. We accumulate in float64 and round once |
| L-X5 | One `MATVEC` instruction stands for the paper's ABC + ACC pair; `IW` installs rows straight from streams into the plane (the paper's separate LW staging buffer is not modelled); no accumulation across instructions | — | — | ASSUMED simplification | Instructions named in [R1 §2.6] without timing detail |
| L-X6 | MXM reads outward-flowing streams and writes inward-flowing streams | yes | yes | SOURCED | [R2 §7] |
| L-X7 | Both planes of a hemisphere sit at the same position; one queue per plane | yes | yes | ASSUMED | Positions not published |
| L-X8 | A fp16 activation vector occupies lanes 0..lanes/2−1 of its stream pair | yes | yes | ASSUMED | Follows from K = lanes/2 but the lane mapping is not stated |
| L-X9 | An fp16 matvec uses **both planes of a hemisphere as one unit**: fp16 instructions go to plane `.0` only, and plane `.1` must stay idle while plane `.0` holds fp16 rows | yes | yes | INFERRED capacity, ASSUMED mechanism | The 2022 paper says a TSP runs "two FP16 or four int8 sub-operations each cycle" [R2 §7], i.e. one fp16 operation per hemisphere against two int8 ones; the 2020 paper says fp16 uses "two 320×320 byte-planes in tandem" [R1 §2.8]. How the pairing is controlled is not published; the idle-plane rule is ours |

### 7.7 SXM

| ID | Parameter | Value | Status | Source / reasoning |
|---|---|---|---|---|
| L-S1 | One SXM per hemisphere, between MEM and MXM | — | SOURCED | [R1 §2.3] |
| L-S2 | Units modelled per SXM: shift, permute, distribute — one queue each | 3 | ASSUMED subset | The paper lists five functions and 14 queues per SXM [R1 §2.3, §2.6] |
| L-S3 | Shift by N lanes fills vacated lanes with zero | — | ASSUMED | The paper pairs shifters with a select between north- and south-shifted vectors [R1 §2.6]; zero fill is the simplest equivalent |
| L-S4 | Permute is a bijection on all lanes; distribute maps within one 16-lane superlane | — | SOURCED | [R1 §2.6] |

### 7.8 Compiler policy

| ID | Policy | Status | Source / reasoning |
|---|---|---|---|
| L-K1 | Shapes and batch size (1) are fixed at compile time | SOURCED motivation | Batch 1 [R1 §2.2]; fixed shapes [R3 §2.7] |
| L-K2 | Scheduling algorithm (list scheduling over rigid chains, reservation tables, conflict ladder) | ASSUMED | No source describes Groq's algorithm (section 2.6). Built from the literature in section 5 |
| L-K3 | Computation is organised as memory-to-memory chains (read → compute → write) | SOURCED motivation | "Read → Conv2D → Requantize → ReLU → Write" [R1 §2.5] |
| L-K4 | Operands needed on streams in the same cycle are stored in different MEM slices | SOURCED | [R1 §2.7] |
| L-K5 | Weights are placed in the MEM slices nearest the MXM that uses them | SOURCED motivation | [R1 §2.7] |
| L-K6 | Any resource conflict the compiler cannot resolve is a compile error; nothing stalls at run time | SOURCED principle | [R1 §2.11], [R2 §4] |
| L-K7 | The compiler abandons a schedule search past cycle 100,000 | ASSUMED | A bound so that a search that cannot succeed terminates. About 100× the expected length of the largest milestone |

### 7.9 Recorded but unused (not simulator parameters)

Clock-domain and network figures from [R2] (links, HAC epoch, link latency,
722 ns per hop), LP30 figures from [R3] (500 MB SRAM, 96×112 Gbps links,
350 ns chip-to-chip latency), and all throughput benchmarks. They are in the raw
reports and in sections 3–4 for context.

---

## 8. Not found

- Per-instruction latencies (d_func, d_skew), SRAM read latency, MXM/SXM/VXM pipeline depths [R1 §4].
- A worked example with cycle numbers (the paper's listings and Fig. 11 have none) [R1 §4].
- The exact stream-register map and chip-crossing time, other than our reading of Fig. 4 [R1 §4].
- Whether a MEM slice can do two reads in a cycle; Gather/Scatter map format [R1 §4].
- Absolute power for the gen-1 chip [R1 §4].
- Groq's scheduling algorithm, in any generation [R2 §9, R4 §2.8].
- Units of the 2022 paper's link-latency table; breakdown of the 722 ns hop; clock tolerance and deskew frequency [R2 §9].
- Hot Chips 2026 slide content (HTTP 401); LP30 clock, slice/lane counts, instruction set, compile times, use of tray DRAM; a primary source for the 4 nm node; TruePoint details [R3 §5].
- Full text of Rau 1994 and Leiserson–Saxe; primary sources for pipeline collision vectors [R4 §4].
