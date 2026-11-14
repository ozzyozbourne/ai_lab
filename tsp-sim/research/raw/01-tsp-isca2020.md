# 01 — "Think Fast: A Tensor Streaming Processor (TSP) for Accelerating Deep Learning Workloads" (Abts et al., ISCA 2020)

Research date: 2026-11-14. Labels used throughout:
- **[P]** = stated in the primary paper (ISCA 2020 text/figure I actually read this session)
- **[S]** = stated in a secondary source I actually read this session
- **[I]** = my own inference / arithmetic from [P] or [S] statements
- Page numbers are the proceedings page numbers printed on the paper (pp. 145–158).

---

## 1. Sources consulted (with reachability status)

| # | Source | URL | Status |
|---|---|---|---|
| P1 | **Primary paper**, full 10-page camera-ready PDF (PDF metadata: title as above, 31 Groq authors, created 2020-05-22). Text extracted with `pdftotext`; Figures 2, 4, 6, 7, 9, 10, 11 inspected as rendered page images. | https://cdn.sanity.io/files/chol0sk5/production/16e7e13197dfe5f52d3b0ed62e29620662c38743.pdf | **READ IN FULL** (HTTP 200, 1.75 MB, 10 pages) |
| — | Groq-hosted copy | https://groq.com/wp-content/uploads/2024/02/2020-Isca.pdf | HTTP 404 (Groq site reorganised) |
| — | Other guessed Groq paths (`groq.com/wp-content/uploads/2020/06/ISCA-TSP.pdf`, `wow.groq.com/...`, `groq.com/wp-content/uploads/2023/05/2020-Isca.pdf`) | — | all HTTP 404 |
| — | Wayback Machine copy | https://web.archive.org/web/20241014113400/https://groq.com/wp-content/uploads/2024/02/2020-Isca.pdf | Snapshot exists per Wayback API, but download **failed** (connection reset via proxy; WebFetch refuses web.archive.org) |
| — | groq.humain.ai mirror | https://groq.humain.ai/wp-content/uploads/2024/02/2020-Isca.pdf | **Unreachable** (proxy CONNECT 502) |
| — | Semantic Scholar API | DOI 10.1109/ISCA45697.2020.00023 | Reached; reports openAccessPdf = CLOSED. Used only to confirm DOI / identity (paperId 16e7e131… matches the sanity.io filename). |
| — | IEEE / ACM DL | https://dl.acm.org/doi/abs/10.1109/ISCA45697.2020.00023 | Not attempted for full text (paywalled publisher copy; not needed since P1 was obtained) |
| S1 | **Secondary**: Dennis Abts, "Groq's Tensor Streaming Processor", ISC 2020 ML Hardware Workshop slides (23 pages, "Released for ISC2020 ML HW Workshop") | https://mlhardware.github.io/2020/groq.pdf | **READ** (text extracted; slides 7–12 used) |
| — | ETH SAFARI seminar copy, ResearchGate, Scribd, arXiv 2206.11062 ("Answer Fast", BERT on TSP) | listed in search results | Not opened (P1 sufficed); arXiv 2206.11062 only seen as a search snippet ("88 independent on-chip memory blocks") — treat as unverified |

Not consulted (out of time/scope): Hot Chips 2020 talk, Linley/Microprocessor Report articles, Groq patents, ISCA 2022 "A Software-defined Tensor Streaming Multiprocessor" paper. Anything I believe from those is in Section 4 (unverified).

---

## 2. Findings by topic

### 2.1 Chip-level facts

- **Process / die / clock** [P, Abstract p.145]: "a computational density of more than 1 TeraOp/s per square mm of silicon for its 25×29 mm 14nm chip operating at a nominal clock frequency of 900 MHz."
- **Clock used for all bandwidth/peak math is 1 GHz, not 900 MHz** [P, §II-B p.150]: "For the sake of exposition, assume a 1 GHz operating frequency of the core clock." Fig. 9 caption: "arithmetic throughput (at 1 GHz core clock)". Conclusion p.156: "The first-generation Groq TSP (at 1 GHz) in 14nm ASIC and packaged as a PCIe CEM form factor, yields a peak performance of 820 TeraOps/sec from 26.8B transistors on-chip — 30K deep learning Ops/sec/transistor." → **Inconsistency inside the paper: nominal 900 MHz vs. 1 GHz used for peak numbers.**
  - [I] 820 TOps = 4 planes × 320 × 320 MACC × 2 ops × 1 GHz = 819.2 TOps. At 900 MHz this gives ≈737 TOps.
  - [S, S1 slide 7] "~750 Tops (Int8Acc32) peak" and "> 1 TeraOps/sec per mm2" — consistent with ~900 MHz [I].
- **Transistors** [P, §VII p.156]: 26.8B transistors.
- **Die area** [I]: 25 × 29 mm = 725 mm².
- **Silicon timeline** [P, §V p.155]: "we received silicon back from the fab in July of 2019"; results are on "A0 silicon".
- **Power**: the paper gives **no absolute watts**. Fig. 10 ("Power usage for ResNet50 layers", p.155) plots *relative* power (0–100%) over ~26,000 cycles for layers 14–40, broken into comb/mem/leak/clock/flop; clock power ≈20%, leakage ≈5% (read off the plot [P, Fig. 10]; approximate). Peaks correspond to "four (4) simultaneous conv2d operations" [P, §IV p.153].
- **Host / off-chip** [P, §II item 6 p.148–149]: C2C "Send and Receive primitives for exchanging 320-byte vectors between a pair of chips"; "sixteen (16) ×4 links operating at 30 Gbps each"; "16 ×4 ×30Gb/s ×2 directions = 3.84 Tb/s of off-chip pin bandwidth"; PCIe Gen4 host interface with "a lightweight DMA engine to emplace a model onto the TSP memory". [S, S1 slide 7]: "Device ringed with 480 GB/s off chip bandwidth" (= 3.84 Tb/s / 8 [I]).
- **ICU area**: "accounting for less the [sic] 3% of the area" [P, §I-B p.147].

### 2.2 Performance claims (ResNet-50)

- [P, Abstract] "20.4K processed images per second (IPS) with a batch-size of one".
- Latency — **the paper gives two different figures**:
  - [P, §I-C contributions p.147]: "executing a sample image query in less than 49μs, yielding 20.4K IPS of batch-size1 inference throughput".
  - [P, §V p.155]: "performing an inference query of the ResNet model in < 43μs, yielding a throughput of 20.4K images per second ... (ie. batch size of 1)" and, in the same paragraph, "the TSP has an inference latency of only 49 μs for a single image sample". [I] Plausibly 43 µs is on-chip compute time and 49 µs end-to-end incl. host; the paper does not say so explicitly.
  - [I] 1 / 20.4K IPS ≈ 49 µs, i.e., throughput is consistent with one image every ~49 µs.
- Comparisons [P, §V]: "2.5× speedup relative to the Google TPU v3 large batch inference"; "nearly a 5× reduction in end-to-end latency compared to Intel/Habana's Goya ... 240 μs".
- Projected [P, §IV-F p.155]: ResNet101 14.3k IPS, ResNet152 10.7k IPS ("project the performance ... to the cycle").
- Optimisation reduced latency "by approximately 5,500 cycles" [P, §IV-C p.154].
- Quantisation: "post-training layer-based symmetric int8 quantization", "quantization loss of 0.5%" [P, §IV-D p.154].
- Accuracy: standard ResNet50 75.6% Top-1/92.8% Top-5; widened 320-channel variant 77.2%/93.6% [P, §IV-E p.154–155].
- Fig. 10 x-axis: layers 14–40 span ≈26,000 cycles (read from plot) [P].

### 2.3 Slice layout / floorplan

- **Functional slice types** [P, §II p.148, Table I]: ICU, MEM, VXM, MXM, SXM, C2C.
- **East/West arrangement of one superlane (row)** [P, Fig. 2 p.146]: West → East:
  `MXM | SXM | MEM (44 slices) | VXM | MEM (44 slices) | SXM | MXM`
  with the VXM at the "on-chip bisection". SXM boxes are labelled "Transposer, Permutor & Shifters, PCIe & IO". [S, S1 slide 8] adds C2C at both outer edges: `C2C 16x4 | MXM | SXM | MEM | VXM | MEM | SXM | MXM | C2C`.
- **ICU (instruction queue) counts per slice group** [P, Fig. 2 p.146, read from figure]: MXM 6 | SXM 14 | MEM 44 | VXM 16 | MEM 44 | SXM 14 | MXM 6 → total **144**, matching "144 independent instruction queues (ICUs) on-chip" [P, §I-B p.147].
  - [S, S1 slide 8] shows the same plus "C2C ICU 3" at each edge (= 150 total) — **conflicts with 144** in the paper. Unresolved.
- **Superlanes / tiles** [P, §I-B p.147]: "each tile in the on-chip mesh operates on 16-lanes in a SIMD manner. We refer to this 16-lane unit as a 'superlane'... minimum vector length, minVL, of 16 elements. Likewise, the vertical composition of 20 tiles to form a functional slice (Figure 5) produces a maximum vector length, maxVL, of 20×16=320 elements." → **20 superlanes, 20 tiles per slice, 16 lanes per superlane, 320 lanes total.**
  - Die photo Fig. 5 labels "SUPERLANE 0" (bottom, next to ICUs) through "SUPERLANE 19" (top) [P, Fig. 5].
- **Vector element = 1 byte**: "Each element of a stream is 1-byte" [P, §I-B p.146]; "minVL, is 16 bytes and maxVL is a 320 byte-sized element array" [P, §II-F p.151].
- **Pipeline depth**: "Each functional slice implements a 20-stage vector pipeline that spans the tiles of each slice, with each tile producing 16 elements of the 320-element maximum vector length." [P, §I p.146].
- **Low-power mode / variable VL**: "we provide instructions to configure each tile for a low-power mode to effectively power-down any unused superlane" (Config) [P, §II-F p.151].
- **Stream-register / slice positions within a superlane** [P, Fig. 4 p.148] — my reading of the figure (medium confidence, figure is small):
  - MEM slices are grouped in **quads** of 4 (quad[0]..quad[10] = 11 quads = 44 slices per hemisphere); a stream-register stage sits between successive quads (and at the ends).
  - MEM0 is adjacent to the VXM, MEM43 nearest the SXM — also stated in text: "slice MEM0 closest to the VXM and MEM43 nearest to the SXM" [P, §II-B p.149].
  - Stream register positions are numbered **0..44 in the direction of flow** across the whole chip for each direction. Eastward: SR0 at the West MXM, SR ~21 adjacent to the VXM (West side), SR22 on the East side of the VXM, SR44 at the East MXM. Westward is mirrored (SR0 at East MXM ... SR44 at West MXM).
  - In the West hemisphere, read outward (westward) from the MEM: SR35 | SR36 | SR37 | SR38 | **TX** (C2C) | SR39 | **DST** (SXM distributor) | SR40 | **TSP** (transposer) | **PRM** (permuter) | **SEL** (shift-select) | SR41 | SR42 | SR43 | **LWB** | **IW** | **ABC** (MXM) | SR44 | MXM. On the inward (eastward) lane from the MXM: SR0 | SR1 | SR2 | **ACC** (MXM accumulators) | SR3 | SR4 | (SXM results merge in here) | SR5 | **RX** (C2C) | SR6 | SR7 | SR8 | MEM43..MEM40 | SR9 | ... | SR18 | MEM3..MEM0 | SR19 | SR20 | SR21 | VXM. The East hemisphere is the mirror image.
  - [I] Consequence: in each hemisphere the *outward*-flowing streams feed MXM weight/activation inputs (LWB/IW/ABC), the SXM units and C2C TX; the MXM ACC outputs, SXM outputs and C2C RX are produced onto *inward*-flowing streams. The arrows in Fig. 4 show SEL and TSP outputs feeding the inward lane between SR4 and SR5.
  - [I] So a stream crosses the full chip in roughly 45 stream-register hops ≈ 45 cycles at 1 hop/cycle (see 2.4). This is an inference from Fig. 4 + the "one hop per tick" sentence; the paper never states a chip-crossing cycle count.

### 2.4 Stream mechanics

- **Number / width** [P, §I-B p.147]: "64 logical streams per lane for moving operands or results on-chip with 32 streams Eastward, and 32 streams Westward". Each stream element is 1 byte per lane, so one stream = a 320-byte vector (16 B per superlane) [P, §I-B p.146].
- **Naming**: "Streams are designated by both an identifier 0..31 and direction, for instance, in(28) designates stream 28 inward, and out(24) is stream 24 toward the outward edge of the chip" [P, §I-B p.147]; footnote 1 defines inward = toward the chip bisection, outward = toward the edge.
- **Multi-byte types** [P, §I-B p.146]: "larger data types (e.g. int16, int32, and fp32) being constructed from several streams (2, 4, and 4 respectively). Multi-byte data types are always naturally stream-aligned ... int16 is aligned on a stream pair, and int32 is aligned on a quad-stream (e.g. SG4_0 is stream 0-3, SG4_1 is streams 4-7, and so forth)."
- **Implementation**: "Streams are implemented in hardware by a chip-wide streaming register file (SR). They are architecturally-visible" [P, §I-B p.147]. "the TSP architecture does not have any local register files, or FIFOs for communicating" [P, §VI p.156].
- **Propagation rule** [P, §IV-F(c) p.155]: "on each tick of the core clock, the TSP propagates stream values by one stream register hop in the direction of flow as shown in Figure 4. The TSP hardware does not track the origin or destination slice, instead streams simply flow (propagate) Eastward or Westward until they fall off the edge of the chip or are overwritten by a functional slice."
- **Read / overwrite semantics** [P, §II-A p.149]: "Given spatially-adjacent functional slices at coordinates x0, x1, x2 (where the spatial coordinate increases in the direction of flow), then at a given time t_i, the vector representing stream s1 at slice x1 can be accessed as operands by that slice. ... In the following cycle t_i+1, the value s1 either propagated to the functional slice at x2, or else it is overwritten with a result r1 produced by the slice at x1 at cycle t." Values are thus non-destructively readable by any slice they pass; a producing slice overwrites the stream value at its position.
- **Turn-around**: "each functional slice can choose the direction of its result stream, so that streams can be logically 'turned around' (ie. reverse their direction of flow from East-to-West, or vice versa) at any slice" [P, §II-E p.151].
- **Direction on memory instructions**: "Each instruction specifies the first hop direction (East or West), so memory instruction semantics have both an address and a dataflow direction" [P, §I-B p.146].
- **Routing**: "X-dim mesh and Y-dim mesh of tiles with X-Y-X dimension order routing"; X-dimension via MEM stream registers, Y-dimension via SXM permuter/lane-shifters [P, §I-B p.146].
- **Stream bandwidth** [P, Eq. 1 p.150]: B = 2 directions × 32 bytes/lane × 320 lanes = "20 TiB/s" (at 1 GHz). [I] 2×32×320 = 20,480 B/cycle; the paper's "TiB/s" here equals 1024 GB/s units (20,480 GB/s ≈ 18.6 TiB/s strictly) — treat the paper's TiB as loose.
- **Stagger** [P, §II-C p.150, Fig. 6]: "a single 320-byte vector, represented as 20 black squares, are moving eastward along a stream. The data for successive 16-element superlanes are lagging by 1 cycle to accommodate the pipelined execution of an MXM instruction issued to the southern-most tile". I.e., superlane k of a vector is 1 cycle behind superlane k−1 on the same stream (diagonal wavefront).
- **ECC on streams** [P, §II-D p.150]: 128-bit word + 9-bit SECDED = 137 bits; ECC generated at producer, checked by consumer.

### 2.5 Instruction issue, propagation and timing model

- **Vertical instruction flow** [P, §II-C p.150]: "at the scheduled time t the instruction will be issued to the bottom-most tile of the slice, (corresponding to the first 16-element superlane of operand/result vectors). In the subsequent cycle, the instruction will be propagated to the next tile northward in the slice ... This process continues cycle-by-cycle until it has traversed all 20 tiles in the slice." Also §II-B p.150: "instructions flow Northward over the span of 20 cycles visiting each tile in the slice." → 1 tile per cycle north; superlane k executes at t + k.
- **Temporal ISA parameters** [P, §III p.151]:
  - "d_func functional delay — each instruction requires 1 or more cycles to produce its stream output."
  - "d_skew instruction-operand skew — the timing relationship between the instruction dispatch time relative to when its stream operands are required."
- **Timing equation** [P, Eq. 4 p.151]: **T = N + d_func + δ(j, i)**, "where N is the number of tiles in the functional slice, and d_func is the functional delay of the instruction being executed (cycles) for the output stream to appear on the SR_i (stream register at location i in Figure 4) en route to the consumer at SR_j. The transit delay, δ(j, i) is the distance (in cycles) between SR_j and SR_i."
- "Conceptually, the compiler is solving a two-dimensional scheduling of instructions and data in both time and space (ie. stream register location on-chip as shown in Figure 4)." [P, §II-E p.151]
- **No per-instruction d_func / d_skew values are given anywhere in the paper.** (See Section 4.)
- **ICU instructions** [P, Table I p.149, §III-A p.151–152]:
  - `NOP N` — "No-operation, can be repeated N times to delay by N cycles"; "A NOP has a repeat count 16-bit field which allows 1 NOP to wait from 1 ns up to 65 μs for a 1GHz clock"; NOP lets the slice gate clocks for longer waits; inserted implicitly by the compiler.
  - `Ifetch` — "Fetch instructions from streams or local memory"; "has a single stream operand which carries the text of the instructions in their program order, filling the IQ with 640-bytes (a pair of 320-byte vectors) of instructions. All functional slices can fetch instructions simultaneously with normal instruction execution." "It is imperative that IQs never go empty" [§III-A3 p.152]. Compiler reserves some MEM slices as "instruction dispatch" slices [§IV p.153]. Max instruction-fetch SRAM bandwidth "144×16, or 2.25 TiB/s" [§II-B p.150].
  - `Sync` / `Notify` — chip-wide barrier across all 144 IQs; one IQ is notifier. "A chip-wide barrier synchronization can be accomplished in 35 clock cycles, from the time the Notify is issued to the time the Sync is satisfied and retired" [§III-A2 p.152]. Required once after reset; in practice each program starts with a preamble then Sync.
  - `Config` — "Configure low-power mode".
  - `Repeat n, d` — "Repeat the previous instruction n times, with d cycles between iterations".
  - "144 independent instruction queues (ICUs) on-chip, each can issue one or more instructions per cycle" [§I-B p.147].
- **Listing 1** (p.151) — Groq API streaming add (no cycle numbers):
  ```
  x_strm = x.read(stream='S_0'); y_strm = y.read(stream='S_4')
  z = g.add(x_strm, y_strm, stream='S_0'); z.write(out_addrs)
  ```
  (shapes [1024, 320], Int8). Prose example: "Read S1,X and Read S2,Y are executed on two MEM slices and directed inward toward an INT slice to perform the Add S1,S2,S3. Lastly ... Write S3,Z" [§I-B p.147].
- **Listing 2** (p.154) — transpose: `tensor.read(streams=range(16))` → `g.transpose16` → `write`, with `layout=[64, 16]` and malloc "across 16 memory slices, one for each concurrent stream". No cycle numbers.
- **Fig. 11** (p.156) — instruction schedule for 3×3 max pool (Read/Write on MEM, Transpose16 and Rotate on SXM, maxPool_1x3 / maxPool_3x1 = max(max(a,b),c) on VXMs). Time runs downward, but **no cycle numbers are printed**.
- **No ReLU worked listing with cycle numbers exists in this paper.** ReLU appears only in Table I and in the "Read → Conv2D → Requantize → ReLU → Write" pattern [§IV-C p.154].

### 2.6 Per-slice instruction sets (Table I, p.149 [P])

| Slice | Instruction | Description (verbatim from Table I) |
|---|---|---|
| ICU | NOP N, Ifetch, Sync, Notify, Config, Repeat n,d | see 2.5 |
| MEM | Read a,s | Load vector at address a onto stream s |
| MEM | Write a,s | Store stream s register contents into main memory address a |
| MEM | Gather s, map | Indirectly read addresses pointed to by map putting onto stream s |
| MEM | Scatter s, map | Indirectly store stream s into address in the map stream |
| VXM | unary operation | z = op x ... (eg. mask, negate) |
| VXM | binary operation | z = x op y ... (e.g. add, mul, sub) |
| VXM | type conversions | Converting fixed point to floating point, and vice versa |
| VXM | ReLU, TanH, Exp, RSqrt | max(0,x); tanh; e^x; reciprocal square root |
| MXM | LW | Load weights (LW) from streams to weight buffer |
| MXM | IW | Install weights (IW) from streams or LW buffer into the 320×320 array |
| MXM | ABC | Activation buffer control (ABC) to initiate and coordinate arriving activations |
| MXM | ACC | Accumulate (ACC) either INT32 or FP32 result from MXM |
| SXM | Shift up/down N | Lane-shift streams up/down by N lanes, and Select between North/South shifted vectors |
| SXM | Permute map | Bijective permute 320 inputs → outputs |
| SXM | Distribute map | Rearrange or replicate data within a superlane (16 lanes) |
| SXM | Rotate stream | Rotate n × n input data to generate n² output streams with all possible rotations (n=3 or n=4) |
| SXM | Transpose sg16 | Transpose 16×16 elements producing 16 output streams with rows and columns interchanged |
| C2C | Deskew | Manage skew across plesiochronous links |
| C2C | Send / Receive | Send a 320-byte vector / Receive a 320-byte vector, emplacing it in main memory |

[S, S1 slide 9] lists additional MEM instructions not in the paper's Table I: "Countdown d — Set the delay d in cycles between loop iterations", "Step a — Set the stride a between subsequent generated memory addresses", "Iterations n — Set the loop bounds for address generation".

Other ISA details [P]:
- VXM ALUs are stateless (no condition codes); saturating and modulo variants `add_sat, add_mod, mul_sat, mul_mod` [§III-C p.152].
- VXM ALUs can be chained within a lane without writing intermediates to memory [§III-C].
- SXM: two instances (one per hemisphere); "Each can issue two (2) transpose instructions, yielding a maximum of four (4) simultaneous transpose 16x16 operations" [§III-E p.153]. Lane shifters "usually allocated in pairs"; distributor can "zero-fill any or all of the 16 elements" at full bandwidth [§III-E].

### 2.7 Memory (MEM)

- **Count / arrangement**: 2 hemispheres × 44 slices = 88 slices; "each having 44 slices numbered 0 to 43 with slice MEM0 closest to the VXM and MEM43 nearest to the SXM" [P, §II-B p.149].
- **Capacity**: "Each MEM slice comprises 20 tiles, arranged in a vertical stack, yielding a 2.5 Mibyte per-slice capacity, or 220 MiBytes for all 88 slices on-chip" [P, §II-B p.149–150].
- **Word / addressing**: "Each slice provides 13-bits of physical addressing of 16-byte memory words, each byte maps to a lane" [P, §II item 5 p.148]. "Slices of memory are partitioned into 16-byte words, each word spread across a superlane ... byte 0 is lane0, byte 1 is lane1" [P, §II-B p.150].
  - [I] 20 tiles × 2^13 words × 16 B = 2,621,440 B = 2.5 MiB per slice; × 88 = 220 MiB. So the 13-bit address = 8192 16-byte words **per tile**, and a Read of one address returns 20 × 16 B = 320 B (one full vector).
- **Banks**: "88 slices each with 2 banks"; "up to 176-way memory concurrency" [P, §III-B p.152]. Eq. 2 uses "2 banks/slice".
  - [I] With 8192 words total per tile per slice, each bank would hold 4096 words per tile (1.25 MiB per bank per slice) **if** the 13-bit address includes the bank bit.
  - [S, S1 slide 12] gives PGAS fields `[device, hem, memory slice, bank, address offset]` with "Bank within the slice (0 or 1)" and "Address offset (0..8191) -- each SRAM stores 8K 16-byte words". Taken literally (bank × 8192) that would double the capacity to 440 MiB, which **conflicts with the paper's 2.5 MiB/slice**. Unresolved; the simulator should pick one interpretation and mark it ASSUMED.
- **Pseudo-dual-port** [P, §III-B p.152]: "Each MEM slice contains pseudo-dual-port SRAMs that are capable of servicing a pair of read and write requests simultaneously assuming they are not targeting the same bank. As such, we expose the bank bit so that the compiler can manage the underlying SRAM". [P, §IV-A p.153–154]: "dual read/write access per slice with a read of inputs from one bank and a write of the results to the opposite bank".
  - [I] Per slice per cycle: at most 1 read + 1 write, and they must target different banks. Whether two reads to different banks in the same cycle are allowed is **not stated** (Eq. 2 suggests each bank contributes 320 B/cycle of SRAM bandwidth).
- **SRAM bandwidth** [P, Eq. 2 p.150]: M = 2 hem × 44 slices/hem × 2 banks/slice × 320 bytes/cycle = "55 TiB/s", "or 27.5 TiB/s of SRAM bandwidth in each hemisphere". [I] = 56,320 B/cycle; again loose TiB.
- **Addressing modes** [P, §III-B]: Read/Write direct (address in instruction); Gather/Scatter stream-indirect ("the physical address comes from the stream value").
- **Concurrency use**: "The 88 slices provide the needed memory concurrency to supply 32 operands per lane, every cycle" [P, §II-B]. "the compiler allocates memory for a tensor's concurrent stream operands into separate MEM slices — as streams propagate through the MEM system they 'pick up' operands from the MEM slices en route to the MXM" [P, §IV-A p.153].
- **Weight placement**: compiler-generated code placing weights in MEM43 (closest to MXM) beats hand code using MEM22 ("slice 22 which is in the middle of the MEM and has a few cycles of added transit delay") [P, Fig. 9 annotations p.155].
- **No caches**: memory is a flat software-managed PGAS [P, §IV, §IV-A].

### 2.8 MXM

- "four (4) independent 320×320 ... planes of multiply-accumulate (MACC) units. Each 320×320 plane is comprised of 20 16×16 supercells that produce a partial-sum each cycle and pass it to the adjacent tile for use in its computation." [P, §III-D p.152]
- Arrangement [I from Fig. 2/Fig. 5]: two MXM planes per hemisphere at the outer edges (Fig. 5 die photo shows "320 x 320" twice on each side).
- [I] MACC count = 4 × 320 × 320 = 409,600 = number of weights (paper: "loading all 409,600 weights on-chip").
- **Weight install**: "It requires 16 streams each with 16 bytes to install 256 8-bit weights (IW) in each supercell on every cycle. Using all 32 streams in each direction allows us to emplace weights in both MXM planes simultaneously on both MXM hemispheres, loading all 409,600 weights on-chip in less than 40 cycles." [P, §III-D]. Also §I-B: "the MEM can read and MXM can install 400K weights into all four 320×320 arrays in less than 40 cycles including SRAM and on-chip network transit delay." [I] 320 rows of weights / 16 rows per cycle per plane = 20 cycles of install per plane, + transit ⇒ <40 cycles.
- Weight bandwidth: "32 1-byte stream operands for each of the 320 parallel lanes, or 10 TiB/s of operand stream bandwidth into the MXMs" [P, §IV-F(b) p.155].
- **Compute**: "With weights installed, every cycle the MXM can generate a new int32 dot-product of input activations with installed weights." [P, §III-D]. Fig. 7: activations and weights loaded at the side; "INT32 or FP32 results flow back from the inside edge"; 320 input channels × 320 output features.
- **Numerics**: "The MXM supports numerics for both 8-bit integer, and 16-bit floating point by using two 320×320 byte-planes in tandem for 16-bit floating point results. The 320-element sum is produced for each output with only a single rounding step at the end to convert to int32 or fp32 results." [P, §III-D p.153]. "The MXM accepts int8 or fp16 inputs and accumulates to int32 or fp32 respectively" [P, §IV-D p.154]. [I] So fp16 throughput is half of int8 (two planes per fp16 operation).
- **Accumulate**: "features output from the MXM can be accumulated using the accumulators on each int32 or fp32 output stream" [P, §III-D]; ACC instruction (Table I).
- MXM sub-units seen in Fig. 4 [P]: LWB (load-weight buffer), IW, ABC on the outward lane; ACC on the inward lane.
- MXM instruction latency (d_func) and the activation-to-result pipeline depth: **not given**.

### 2.9 VXM

- "Each superlane implements a 4x4 mesh of vector ALUs capable of doing ×16-SIMD computations — 16 vector ALUs per lane. Each of the ALU's 32-bit input operands are organized along naturally aligned quad-stream group (SG4)." [P, §III-C p.152]
- "a total of 5,120 vector ALUs on-chip, capable of 32-bit fixed and floating point operations" [P, §VII p.156]. [S, S1 slide 7]: "up to 5,120 total 32-bit computations per cycle (or 20k INT8 operations per cycle)".
- Single VXM slice group at the chip centre (Fig. 2); Fig. 2 shows 16 ICUs for VXM [P]. [I] Likely one ICU per vector ALU position in the 4×4 mesh (16 ALUs per lane ↔ 16 instruction queues), but the paper does not say so.
- "The VXM has fp32 capacity to stream at the same rate of output produced by the 4 MXM planes" [P, §IV-D].

### 2.10 Compiler / scheduling statements

- Compiler "precisely tracks the chip's architectural state and uses that knowledge to ensure that instructions correctly intercept its stream operand(s)" [P, §I-B p.147].
- "the compiler keeps track of a logical program time ... the compiler tracks the state of 144 independent program queues on a cycle-by-cycle basis" [P, §III-A2 p.152].
- "the compiler's back-end can precisely track the position and time-of-use of any stream on-chip" [P, §II-E p.151]; two-dimensional time × space scheduling (see 2.5).
- Compiler inserts NOPs implicitly; performs "omniscient prefetching" via Ifetch [P, §III-A].
- Compiler manages banks explicitly, distributes concurrent operands across separate MEM slices, interleaves banks so the next layer can read before the previous finishes writing [P, §IV-A, §IV-C].
- Compiler is responsible for memory management of weights, activations and program text [P, §IV].

### 2.11 Determinism claims

- "guaranteeing determinism by eliminating all reactive elements in the hardware (e.g. arbiters, and caches)" [P, Abstract].
- Intro motivates against "caches, branch predictors, and prefetchers" which "do not bound worst-case performance" [P, §I p.145]. (The paper does not explicitly say "the TSP has no branch predictor", but it has no branching instructions in Table I [I].)
- "The TSP's hardware eliminates arbiters and other reactive elements in the data path, making performance deterministic and precisely predictable from run-to-run execution" [P, §IV-F p.155].
- On-chip network has no routing/arbitration/flow-control; streams flow 1 hop/cycle [P, §IV-F(c)].
- "our stream programming model does not require explicit synchronization of producer and consumers, except once at the beginning of the program" [P, §VI].
- The TSP avoids sparsity/compression optimisations "to maintain a strictly deterministic execution time and power profile" [P, §VI].

---

## 3. Parameters useful for a simulator

Confidence: H = verbatim number in the paper; M = read from a figure or a simple derivation from verbatim numbers; L = inference with gaps.

| Parameter | Value | Source | Conf. |
|---|---|---|---|
| Lanes per superlane | 16 | [P] §I-B p.147 | H |
| Superlanes (rows) | 20 | [P] §I-B p.147; Fig. 5 | H |
| Tiles per functional slice | 20 | [P] §I-B p.147, §II-B p.149 | H |
| Total vector length (maxVL) | 320 elements × 1 B = 320 B | [P] §I-B, §II-F | H |
| minVL | 16 B (one superlane) | [P] §II-F | H |
| Stream element width | 1 byte per lane | [P] §I-B p.146 | H |
| Streams per direction | 32 (ids 0..31), 64 total | [P] §I-B p.147 | H |
| Multi-byte types | int16 = 2 streams; int32/fp32 = 4 streams (SG4, aligned) | [P] §I-B p.146 | H |
| Stream propagation | 1 stream-register hop per clock, in the direction of flow | [P] §IV-F(c) p.155 | H |
| Stream end behaviour | falls off the chip edge or is overwritten by a producing slice | [P] §IV-F(c) | H |
| Stream-register positions per direction | 0..44 (≈45 SR stages chip-wide), one per MEM quad + several in SXM/MXM/C2C/VXM regions | [P] Fig. 4 (read from figure) | M |
| Chip-crossing transit | ≈45 cycles | [I] from Fig. 4 + 1 hop/cycle | L |
| Superlane stagger | superlane k lags superlane k−1 by 1 cycle | [P] §II-C, Fig. 6 | H |
| Instruction vertical propagation | 1 tile north per cycle; 20 cycles to traverse a slice | [P] §II-B, §II-C | H |
| Timing model | T = N + d_func + δ(j,i) | [P] Eq. 4 p.151 | H |
| d_func per instruction | ≥1 cycle; specific values NOT given | [P] §III | — |
| d_skew per instruction | concept defined; values NOT given | [P] §III | — |
| Slice order (one row, W→E) | MXM, SXM, MEM×44, VXM, MEM×44, SXM, MXM (C2C at edges per S1) | [P] Fig. 2; [S] S1 slide 8 | H |
| ICUs / instruction queues | 144 total: MXM 6+6, SXM 14+14, MEM 44+44, VXM 16 | [P] §I-B; Fig. 2 | H (total) / M (split) |
| ICU issue width | "one or more instructions per cycle" per queue | [P] §I-B | H (vague) |
| NOP repeat field | 16 bits (1 .. 65,535 cycles) | [P] §III-A1 | H |
| Repeat instruction | Repeat n, d (n repeats, d cycles apart) | [P] Table I | H |
| Barrier (Notify→Sync retire) | 35 cycles | [P] §III-A2 | H |
| Ifetch payload | 640 B (two 320-B vectors) per Ifetch | [P] §III-A3 | H |
| MEM slices | 88 (44 per hemisphere), numbered 0..43, MEM0 next to VXM | [P] §II-B | H |
| MEM tiles per slice | 20 | [P] §II-B | H |
| MEM word | 16 B per tile (128 bits + 9 ECC = 137 bits) | [P] §II item 5; §II-D | H |
| MEM address bits | 13 (8192 words) per slice-tile | [P] §II item 5 | H |
| Capacity per slice | 2.5 MiB | [P] §II-B | H |
| Total SRAM | 220 MiB | [P] §I-B, §II-B | H |
| Banks per slice | 2 | [P] §III-B; Eq. 2 | H |
| Bank size | 4096 words/tile (1.25 MiB/slice) if bank bit is inside the 13-bit address | [I]; conflicts with [S] S1 slide 12 | L |
| MEM ports | pseudo-dual-port: 1 read + 1 write per cycle, different banks | [P] §III-B, §IV-A | H |
| SRAM bandwidth | 320 B/cycle per bank; 56,320 B/cycle chip ("55 TiB/s") | [P] Eq. 2 | H |
| Stream bandwidth | 2 × 32 × 320 = 20,480 B/cycle ("20 TiB/s") | [P] Eq. 1 | H |
| MEM instructions | Read a,s; Write a,s; Gather s,map; Scatter s,map (+ Countdown/Step/Iterations per S1) | [P] Table I; [S] S1 slide 9 | H / M |
| MXM planes | 4 × (320×320), two per hemisphere at chip edges | [P] §III-D; Fig. 2, Fig. 5 | H |
| MXM supercell | 16×16; 20 supercells per plane (one per tile) | [P] §III-D | H |
| MACC cells | 409,600 | [P] §III-D (weights) / [I] | H |
| Weight install rate | 16 streams × 16 B → 256 int8 weights per supercell per cycle | [P] §III-D | H |
| Full weight load | all 409,600 weights in < 40 cycles (incl. SRAM + transit) | [P] §I-B, §III-D, §IV-F | H |
| MXM numerics | int8 → int32 acc; fp16 (two byte-planes in tandem) → fp32 acc | [P] §III-D, §IV-D | H |
| MXM output | new int32 dot-product every cycle once weights installed | [P] §III-D | H |
| MXM instructions | LW, IW, ABC, ACC | [P] Table I | H |
| VXM ALUs | 16 per lane (4×4 mesh), 5,120 total, 32-bit operands on SG4 | [P] §III-C, §VII | H |
| VXM ops | unary, binary (add/mul/sub, _sat/_mod), type conv, ReLU, TanH, Exp, RSqrt | [P] Table I, §III-C | H |
| SXM | 2 instances; each up to 2 transposes ⇒ 4 simultaneous 16×16 transposes; shift, permute (320-lane bijection), distribute (16-lane), rotate (n=3,4) | [P] §III-E, Table I | H |
| C2C | 16 × x4 links @ 30 Gbps; 3.84 Tb/s bidirectional; Send/Receive 320-B vectors; Deskew | [P] §II item 6 | H |
| Clock | 900 MHz nominal; 1 GHz used for peak/bandwidth math | [P] Abstract; §II-B; §VII | H (inconsistent) |
| Peak | 820 TOps at 1 GHz (int8); ~750 TOps per S1 | [P] §VII; [S] S1 slide 7 | H |
| Process / die | 14 nm; 25 × 29 mm; 26.8B transistors | [P] Abstract; §VII | H |
| ResNet-50 | 20.4K IPS at batch 1; latency < 43 µs (§V) / < 49 µs (§I-C, §V) | [P] | H (inconsistent) |
| Power | no absolute value; only relative (Fig. 10) | [P] Fig. 10 | — |

---

## 4. Not found / unverified

Not in the primary paper (searched the full text and figures):
1. **Per-instruction d_func and d_skew values** (e.g., Read latency, VXM add latency, MXM pipeline depth, SXM transpose latency). Only the symbols and Eq. 4 are given. → simulator must ASSUME these.
2. **SRAM read latency** in cycles (address issue to data on stream). Only folded into "< 40 cycles" for a full weight load.
3. **Exact stream-register count per direction and exact SR-to-slice mapping.** Only Fig. 4 shows it; my 0..44 reading is from a small figure (medium confidence). No text states the chip-crossing time in cycles.
4. **Whether a MEM slice can do two reads (or two writes) in one cycle on different banks.** The paper only states one read + one write on different banks.
5. **Bank-bit placement / bank size.** Paper: 13-bit word address, 2.5 MiB/slice, 2 banks. S1 slide 12: separate bank field plus offset 0..8191. These conflict (factor 2). Unresolved.
6. **Absolute power / TDP.** Not in the paper. I have an unverified recollection of figures around ~300 W from Groq/Linley material; **NOT verified this session; do not cite.**
7. **ICU count conflict**: paper Fig. 2 shows 144 (no C2C ICUs); S1 slide 8 shows 3 extra ICUs per C2C side (150). Unresolved.
8. **Latency conflict**: < 43 µs vs < 49 µs / 49 µs for ResNet-50 batch-1. The paper does not explain the difference.
9. **Clock conflict**: 900 MHz nominal vs 1 GHz in all bandwidth/peak calculations.
10. **No worked ReLU program with cycle numbers** exists in this paper. Listings 1–2 are Groq-API Python with no cycle annotations; Fig. 11 (max-pool schedule) has no numeric time axis. If another source (e.g., the ISCA 2022 multi-chip paper, Groq patents, Hot Chips talk) has a ReLU example with cycle numbers, I did not verify it here.
11. **VXM 16-ICU ↔ 16-ALU correspondence**, the ALU-chaining latency, and how VXM ALUs in the 4×4 mesh connect to streams: not specified.
12. **MXM internals**: activation-buffer depth, LW buffer size, whether IW from the LW buffer is faster than from streams, accumulator count/depth: not specified.
13. **SXM latencies** and whether the shifters/permuter/distributor/transposer are separate slices with their own ICUs (Fig. 4 shows SEL, PRM, TSP, DST as separate positions; 14 ICUs per SXM in Fig. 2): not described in text.
14. **Gather/Scatter map format** (one address per lane? per superlane?): not specified.
15. Hot Chips 2020, Linley/MPR, the ISCA 2022 "Software-defined Tensor Streaming Multiprocessor" paper, and Groq patents were **not consulted** in this session; anything from them is unverified here.
16. arXiv 2206.11062 ("Answer Fast", BERT on TSP) was seen only as a search-result snippet ("88 independent on-chip memory blocks"); not opened.
