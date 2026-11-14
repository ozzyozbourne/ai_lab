# Groq TSP: "Think Fast" (ISCA 2020) research notes for the simulator

**Paper:** D. Abts, J. Ross, J. Sparling, et al., "Think Fast: A Tensor Streaming Processor (TSP) for Accelerating Deep Learning Workloads," *2020 ACM/IEEE 47th Annual International Symposium on Computer Architecture (ISCA)*, pp. 145–158, DOI 10.1109/ISCA45697.2020.00023.

## 0. Sources and how I accessed them

| ID | Source | Status |
|---|---|---|
| **[P]** | Groq-hosted PDF `https://groq.com/wp-content/uploads/2024/02/2020-Isca.pdf` | Live URL returns **HTTP 404** (2026-11-14). I read the **Wayback Machine capture**: `https://web.archive.org/web/2024id_/https://groq.com/wp-content/uploads/2024/02/2020-Isca.pdf` (14 pages, the full IEEE camera-ready). This is the primary source for everything below. |
| [P-alt] | `https://groq.com/wp-content/uploads/2020/06/ISCA-TSP.pdf` | Live URL 404. The Wayback capture `https://web.archive.org/web/2021id_/https://groq.com/wp-content/uploads/2020/06/ISCA-TSP.pdf` gives the same text. I used it only as a cross-check. |
| — | IEEE Xplore / ACM DL | Not fetched. Not needed because the full text was available from [P]. |
| — | Groq patents, Hot Chips 2020 talk, Groq ISCA 2022 paper | **Not consulted.** Nothing in this report comes from them. |

**Citation convention:** "p.N" is the printed proceedings page (145–158). PDF page = p − 144. Section numbers, figure numbers and table numbers are the paper's own. All quotes come from [P] unless marked otherwise. Figures are raster images. I read them from 400-dpi renders, and the small labels are blurry, so readings of figure labels are marked **(fig. reading)**.

---

## 1. Chip-level facts (process, die, clock, headline numbers)

- **Process and die:** "its 25×29 mm 14nm chip operating at a nominal clock frequency of **900 MHz**" (Abstract, p.145).
- **The paper uses 1 GHz for its arithmetic:** "For the sake of exposition, assume a 1 GHz operating frequency of the core clock" (Sec. II-B, p.150). Fig. 9 is captioned "(at 1 GHz core clock)" (p.155). The conclusion says "The first-generation Groq TSP (at 1 GHz) in 14nm ASIC ... yields a peak performance of **820 TeraOps/sec** from **26.8B transistors**" (Sec. VII, p.156).
  - Derived (my arithmetic): 4 planes × 320×320 MACC × 2 ops × 1 GHz = 819.2 TOps/s, which matches the 820 figure.
- **Compute density:** "more than 1 TeraOp/s per square mm of silicon" (Abstract, p.145).
- **Package:** "packaged as a PCIe CEM form factor" (Sec. VII, p.156). The host interface is PCIe Gen4 (Sec. II item 6, p.149).
- **ResNet-50:** "20.4K processed images per second (IPS) with a batch-size of one" (Abstract). The paper gives two latency figures:
  - "executing a sample image query in less than 49µs" (Sec. I-C, p.147);
  - "performing an inference query of the ResNet model in < 43µs, yielding a throughput of 20.4K images per second" (Sec. V, p.155);
  - "the TSP has an inference latency of only 49 µs for a single image sample" (Sec. V, p.155).
  - The 43 µs and 49 µs values are **inconsistent within the paper itself**.
- **ResNet projections:** ResNet101 at 14.3k IPS and ResNet152 at 10.7k IPS (Sec. IV-F, p.155).
- **Accuracy:** standard ResNet50 reaches 75.6% Top-1; a version with channels widened to 320 reaches 77.2% Top-1 (Sec. IV-E, p.154–155).
- **ResNet50 optimisation:** about 5,500 cycles of latency removed by memory/bank allocation (Sec. IV-C, p.154).
- **Quantization:** post-training, layer-based, symmetric int8. MXM accumulates int8→int32 and fp16→fp32, then the VXM requantizes (Sec. IV-D, p.154).
- **Power:** **no absolute watts are given.** Fig. 10 ("Power usage for ResNet50 layers", p.155) plots *relative* power (0–100%) over about 26,000 cycles for layers 14–40, split into comb, mem, leak, clock and flop components. The spikes are the four simultaneous conv2d operations (Sec. IV, p.153).
- **Schedule note:** silicon (A0) came back in July 2019 (Sec. V, p.155).
- **Instruction control area:** the ICU accounts for "less the 3% of the area" (Sec. II, p.147).

## 2. Slice layout

### 2.1 Slice types
- The ISA spans "**five different functional areas**" (Sec. II, p.148). Table I (p.149) lists **six** rows of instructions: ICU, MEM, VXM, MXM, SXM, C2C.
- Fig. 1(b) uses generic labels ICU, MEM, INT, FPU, NET (Sec. I-A, p.146). These are conceptual; the real chip uses VXM, MXM and SXM.

### 2.2 East and West hemispheres (Fig. 2, p.146; Fig. 5, p.148)
- Fig. 2 (fig. reading) shows the order of one row, west to east:
  - **MXM | SXM | MEM (44 slices) | VXM | MEM (44 slices) | SXM | MXM**
  - The VXM sits at the "on-chip bisection".
  - Box texts: MXM "320x320 array, int8 and fp16 numerics"; SXM "Transposer, Permuter & Shifters, PCIe & IO"; VXM "16 vector ALUs per lane".
- **ICU count per slice group (Fig. 2, fig. reading):** MXM 6 | SXM 14 | MEM 44 | VXM 16 | MEM 44 | SXM 14 | MXM 6. This totals **144**, which matches "144 independent instruction queues (ICUs) on-chip" (Sec. II, p.147).
- **MEM numbering:** "Memory is partitioned into two hemispheres (Figure 5), each having 44 slices numbered 0 to 43 with slice MEM0 closest to the VXM and MEM43 nearest to the SXM" (Sec. II-B, p.149).
- **SXM:** "There are two instances of the SXM on-chip, one in each hemisphere" (Sec. III-E, p.153).
- **MXM:** "four (4) independent 320×320 ... planes" (Sec. III-D, p.152). Two planes per hemisphere is implied by "both MXM planes simultaneously on both MXM hemispheres" (p.152). The die photo (Fig. 5) shows "MXM MXM" and "320×320 320×320" at each edge.
- **Die photo (Fig. 5, p.148, fig. reading):**
  - C2C ×4 blocks along the north and south edges; "PCIe Gen4" at the south-west.
  - "Instruction Control Units (ICUs)" as a strip along the **south** edge.
  - Superlanes 0 (south) to 19 (north).
  - "West MEM 44 independent memory banks/slices", "East MEM 44 ...", and "16 ALUs per lane" in the VXM.

### 2.3 Superlanes and tiles
- "each tile in the on-chip mesh operates on 16-lanes in a SIMD manner. We refer to this 16-lane unit as a 'superlane' ... minVL, of 16 elements ... the vertical composition of **20 tiles** to form a functional slice (Figure 5) produces a maximum vector length, maxVL, of 20×16=**320** elements" (Sec. II, p.147).
- "Each functional slice implements a **20-stage vector pipeline** that spans the tiles of each slice, with each tile producing 16 elements of the 320-element maximum vector length" (Sec. I-A, p.146).
- "Each row of the 2D on-chip mesh contains a cross section of all functional slices" (Sec. I-A, p.146).
- Low-power mode: Config can "power-down any unused superlane" so that VL "from 16 to 320 bytes in 16-lane steps" (Sec. II-F, p.151).

### 2.4 Physical ordering of sub-slices and stream-register positions (Fig. 4, p.148)
Everything in this subsection is **fig. reading at low resolution, medium confidence**. Fig. 4 is titled "Stream registers are numbered to show their locations between the functional slices within a superlane."

**Eastward-flow numbering**, from the West MXM to the East MXM. SR numbers 0..44 increase in the direction of flow.

```
MXM_W | SR0 SR1 SR2 [ACC] SR3 SR4 (shifter taps) SR5 [RX] SR6 SR7 SR8
      | MEM_W 43..40 | SR9 | ... | SR16 | ... | SR18 | MEM_W 3..0 | SR19
      | SR20 SR21 [VXM] SR22 SR23 SR24
      | MEM_E 0..3 | SR25 | ... | SR34 | MEM_E 40..43 | SR35
      | SR36 SR37 SR38 [TX] SR39 [DST] SR40 [TSP][PRM][SEL] SR41 SR42 SR43 [LWB][IW][ABC] SR44 | MXM_E
```

- **Westward flow is the mirror image.** SR0 is at the East MXM and SR44 is at the West MXM. In this direction the East MXM's ACC sits between SR2 and SR3. The order near the West MXM is ... TX, SR39, DST, SR40, TSP, PRM, SEL, SR41–43, LWB, IW, ABC, SR44.
- **Stream registers inside MEM:** the MEM regions are drawn as **11 "quads" of 4 MEM slices** (quad[0]=MEM0–3 ... quad[10]=MEM40–43). A stream register position sits between quads.
  - Each register is labelled with an eastward/westward number pair that sums to 43.
  - MEM East: 24/19, 25/18, ..., 35/8.
  - MEM West: 19/24 ... 8/35.
  - Interpretation (mine, unverified): one stream-register hop crosses one quad of 4 MEM slices. The full chip is 44 hops from MXM to MXM.
- **Legend colours:** MEM memory slice; VXM or MXM arithmetic slice; SXM data movement slice (DST, TSP, PRM, SEL, ACC drawn green); C2C chip-to-chip IO slice (TX, RX).
  - Interpretation: DST = distributor, TSP = transposer, PRM = permuter, SEL = shifter select.
  - LWB, IW and ABC are drawn in MXM colour. They correspond to the LW/IW/ABC instructions in Table I.

## 3. Streams

- **Count and direction:** "64 logical streams per lane ... with **32 streams Eastward, and 32 streams Westward**" (Sec. II, p.147).
- **Identifiers:** "Streams are designated by both an identifier 0..31 and direction, for instance, in(28) designates stream 28 inward, and out(24) is stream 24 toward the outward edge of the chip" (Sec. II, p.147). Footnote 1 says inward means "toward the chip bisection".
- **When a vector becomes a stream:** "When a vector is read from main memory it is given a stream identifier (0..31) and direction: eastward, or westward" (Sec. II-A, p.149).
- **Element width:** "Each element of a stream is **1-byte** with larger data types (e.g. int16, int32, and fp32) being constructed from several streams (2, 4, and 4 respectively)". Multi-byte types are "naturally stream-aligned" ("SG4_0 is stream 0-3, SG4_1 is streams 4-7"). "Data alignment is accomplished by the compiler" (Sec. I-B, p.146).
- **Stream width:** 1 byte × 320 lanes = 320-byte vector. C2C "exchanging 320-byte vectors" (Sec. II item 6, p.148). maxVL is "a 320 byte-sized element array" (Sec. II-F, p.151).
- **Hardware:** "Streams are implemented in hardware by a chip-wide streaming register file (SR). They are architecturally-visible" (Sec. I-B, p.147). "the TSP architecture does not have any local register files, or FIFOs" (Sec. VI, p.156).
- **Hop rate:** "on each tick of the core clock, the TSP propagates stream values by **one stream register hop** in the direction of flow as shown in Figure 4" (Sec. V-c, p.155).
- **No routing metadata:** "The TSP hardware does not track the origin or destination slice, instead streams simply flow (propagate) Eastward or Westward until they **fall off the edge of the chip or are overwritten** by a functional slice" (Sec. V-c, p.155).
- **Propagate or overwrite semantics** (Sec. II-A, p.149):
  > "at a given time t_i, the vector representing stream s1 at slice x1 can be accessed as operands by that slice. ... In the following cycle t_i+1, the value s1 either propagated to the functional slice at x2, or else it is overwritten with a result r1 produced by the slice at x1 at cycle t. Similarly, the stream value s0 that was present to be consumed by the functional unit at coordinate x0 at time t_i will be (absent x0 overwriting the value at time t_i) available in the next cycle t_i+1 to the slice at x1."
- **Turnaround:** "each functional slice can choose the direction of its result stream, so that streams can be logically 'turned around' ... at any slice" (Sec. II-E, p.151).
- **Memory instruction direction:** "Each instruction specifies the first hop direction (East or West), so memory instruction semantics have both an address and a dataflow direction" (Sec. I-B, p.146).
- **Routing model:** "X-dim mesh and Y-dim mesh of tiles with X-Y-X dimension order routing". X-dimension routing goes through MEM; Y-dimension routing goes through the SXM permuter and lane shifters (Sec. I-B, p.146).
- **Stream bandwidth (Eq. 1, Sec. II-B, p.150):** "B = 2 directions × 32 bytes/lane × 320 lanes = 20 TiB/s". The MEM "delivers 32 bytes per lane of stream bandwidth" (Sec. II, p.147).
- **Into the MXMs:** "MEM slices deliver 32 1-byte stream operands for each of the 320 parallel lanes, or 10 TiB/s of operand stream bandwidth into the MXMs" (Sec. V-b, p.155).
- **Stagger (Sec. II-C, p.150; Fig. 6):** "a single 320-byte vector, represented as 20 black squares, are moving eastward along a stream. The data for successive 16-element superlanes are lagging by **1 cycle**". This means superlane k's data trails superlane 0 by k cycles.

## 4. Instruction set (Table I, p.149, transcribed verbatim)

TABLE I: "Summary of instructions for each functional slice."

| Function | Instruction | Description (verbatim) |
|---|---|---|
| ICU | NOP N | No-operation, can be repeated N times to delay by N cycles |
| ICU | Ifetch | Fetch instructions from streams or local memory |
| ICU | Sync | Parks at the head of the instruction dispatch queue to await barrier notification |
| ICU | Notify | Releases the pending barrier operations causing instruction flow to resume |
| ICU | Config | Configure low-power mode |
| ICU | Repeat n, d | Repeat the previous instruction n times, with d cycles between iterations |
| MEM | Read a,s | Load vector at address a onto stream s |
| MEM | Write a,s | Store stream s register contents into main memory address a |
| MEM | Gather s, map | Indirectly read addresses pointed to by map putting onto stream s |
| MEM | Scatter s, map | Indirectly store stream s into address in the map stream |
| VXM | unary operation | z = op x point-wise operation on 1 operand, x, producing 1 result, z (eg. mask, negate) |
| VXM | binary operation | z = x op y point-wise operations with 2 operands x and y producing 1 result, z (e.g. add, mul, sub) |
| VXM | type conversions | Converting fixed point to floating point, and vice versa |
| VXM | ReLU | Rectified linear unit activation function max(0,x) |
| VXM | TanH | Hyperbolic tangent - activation function |
| VXM | Exp | exponentiation e^x |
| VXM | RSqrt | Reciprocal square root |
| MXM | LW | Load weights (LW) from streams to weight buffer |
| MXM | IW | Install weights (IW) from streams or LW buffer into the 320×320 array |
| MXM | ABC | Activation buffer control (ABC) to initiate and coordinate arriving activations |
| MXM | ACC | Accumulate (ACC) either INT32 or FP32 result from MXM |
| SXM | Shift up/down N | Lane-shift streams up/down by N lanes, and Select between North/South shifted vectors |
| SXM | Permute map | Bijective permute 320 inputs →(map) outputs |
| SXM | Distribute map | Rearrange or replicate data within a superlane (16 lanes) |
| SXM | Rotate stream | Rotate n × n input data to generate n² output streams with all possible rotations (n=3 or n=4) |
| SXM | Transpose sg16 | Transpose 16×16 elements producing 16 output streams with rows and columns interchanged |
| C2C | Deskew | Manage skew across plesiochronous links |
| C2C | Send | Send a 320-byte vector |
| C2C | Receive | Receive a 320-byte vector, emplacing it in main memory |

Other ISA details from the text:

- **VXM variants:** saturating and modulo variants `add_sat`, `add_mod`, `mul_sat`, `mul_mod` (Sec. III-C, p.152).
- **Code examples:**
  - Listing 1 (p.151): `x.read(stream='S_0')`, `y.read(stream='S_4')`, `g.add(x_strm, y_strm, stream='S_0')`, `z.write(out_addrs)`.
  - Listing 2 (p.154): `tensor.read(streams=range(16))`, `g.transpose16(...)`, `g.malloc(shape, layout=[64,16])`.
  - The Z=X+Y example: "Read S1,X and Read S2,Y are executed on two MEM slices and directed inward toward an INT slice to perform the Add S1,S2,S3 ... Write S3,Z" (Sec. I-B, p.147).
- **No binary encoding, opcode widths or field layouts are given** apart from the NOP's 16-bit repeat field.

## 5. Timing model

- **Temporal parameters on every instruction** (Sec. III, p.151):
  - "**d_func** functional delay — each instruction requires 1 or more cycles to produce its stream output. The d_func timing parameter allows the compiler to reason about when the output of an instruction will be available on the architecturally-visible stream registers."
  - "**d_skew** instruction-operand skew — the timing relationship between the instruction dispatch time relative to when its stream operands are required. The d_skew parameter on each instruction informs the compiler how to schedule the operand arrival times with the instruction dispatch time in order to get them to properly intersect in time and space."
- **Execution-time equation** (Eq. 4, Sec. III, p.151):
  > **T = N + d_func + δ(j, i)** — "where N is the number of tiles in the functional slice, and d_func is the functional delay of the instruction being executed (cycles) for the output stream to appear on the SR_i (stream register at location i in Figure 4) en route to the consumer at SR_j. The transit delay, δ(j, i) is the distance (in cycles) between SR_j and SR_i."
  - Combined with the one-hop-per-cycle rule (Sec. V-c), δ(j,i) = |j − i| stream-register positions (my inference).
- **2-D scheduling:** "the compiler is solving a two-dimensional scheduling of instructions and data in both time and space (ie. stream register location on-chip as shown in Figure 4)" (Sec. III, p.151).
- **Vertical instruction propagation** (Sec. II-C, p.150): "at the scheduled time t the instruction will be issued to the bottom-most tile of the slice ... In the subsequent cycle, the instruction will be propagated to the next tile northward". Elsewhere: "instructions flow Northward over the span of 20 cycles visiting each tile in the slice" (Sec. II-B, p.150).
  - So tile k (superlane k) executes at t + k.
- **Stagger example (Fig. 6, p.150, fig. reading):** "(1) Read" in West MEM at t0, data transit (solid line) to the MXM at t1, "(2) MatMul or Conv", results transit (dotted) back to East MEM, "(3) Write" at t2. The y-axis runs t=0..19.
- **NOP:** "A NOP has a repeat count **16-bit field** which allows 1 NOP to wait from 1 ns up to 65 µs for a 1GHz clock" (Sec. III-A1, p.151). "OpA NOP(N) OpB" gives N cycles of separation (Sec. II item 1, p.148). The NOP turns off clock enables when it lasts more than a few cycles, and the compiler inserts NOPs implicitly (p.152).
- **Repeat:** "Repeat n, d: Repeat the previous instruction n times, with d cycles between iterations" (Table I).
- **Barrier latency:** "A chip-wide barrier synchronization can be accomplished in **35 clock cycles**, from the time the Notify is issued to the time the Sync is satisfied and retired" (Sec. III-A2, p.152).
- **Weight load:** "read and MXM can install 400K weights into all four 320×320 arrays in less than **40 cycles** including SRAM and on-chip network transit delay" (Sec. II, p.147; repeated Sec. V-b, p.155).
- **Concrete d_func, d_skew or pipeline-depth values for individual instructions are NOT given** (see Not found).

## 6. SRAM / MEM

- **Organisation:** 2 hemispheres × 44 slices = **88 MEM slices**. Each slice has **20 tiles** "yielding a **2.5 MiByte** per-slice capacity, or 220 MiBytes for all 88 slices" (Sec. II-B, p.149–150).
- **Addressing:** "Each slice provides **13-bits of physical addressing of 16-byte memory words**, each byte maps to a lane" (Sec. II item 5, p.148).
  - Derived: 2^13 × 16 B = 128 KiB per tile; × 20 tiles = 2.5 MiB per slice. This is consistent.
- **Word layout:** "Slices of memory are partitioned into 16-byte words, each word spread across a superlane, and each byte of each word occupying a lane ... byte 0 is lane0, byte 1 is lane1" (Sec. II-B, p.150).
- **Capacity:** "220 MiBytes of globally shared SRAM" (Sec. II, p.147). The address space is "a partitioned global shared address space with the address space laid out uniformly across the 88 slices" (Sec. III-B, p.152).
- **Ports and banks:** "Each MEM slice contains **pseudo-dual-port SRAMs** that are capable of servicing a pair of read and write requests simultaneously assuming they are **not targeting the same bank**. As such, we expose the bank bit so that the compiler can manage the underlying SRAM ... up to **176-way** memory concurrency—88 slices each with **2 banks**" (Sec. III-B, p.152).
- **Same-slice read and write:** "simultaneously read operands from one bank and write results to the other bank in the same slice" (Sec. IV-A, p.153–154).
- **SRAM bandwidth (Eq. 2, p.150):** "M = 2 hem × 44 slices/hem × 2 banks/slice × 320 bytes/cycle = **55 TiB/s**", which is 27.5 TiB/s per hemisphere.
- **Instruction-fetch share:** "Instruction fetching ... consumes a maximum SRAM bandwidth of 144×16, or 2.25 TiB/s" (p.150). This leaves 25 TiB/s for the 20 TiB/s of stream traffic.
- **Addressing modes:** "Read and write use direct addressing ... Indirect addressing uses the contents of a stream, s, to specify an address map for a gather or scatter" (Sec. III-B, p.152).
- **ECC:** "9-bit ECC, 137-bits in total ... SECDED". Check bits are generated **only at the producer** and checked by the consuming slice, so they cover SRAM and stream registers. Corrected SEUs are logged to a CSR (Sec. II-D, p.150). Multi-bit errors may raise a host interrupt via PCIe (Sec. II item 6, p.149).
- **Instruction storage:** "the compiler reserves several MEM slices to serve as 'instruction dispatch' slices" (Sec. IV, p.153).
- **Placement guidance:** place weights "toward the middle of the chip in MEM slices ... so that data transit from memory slice MEM_i to MXM is minimized" (Sec. V-b, p.155). The Fig. 9 annotation says "Hand-generated code places tensors in MEM_22 (slice 22 which is in the middle of the MEM and has a few cycles of added transit delay)" (fig. reading, low confidence).

## 7. ICU and instruction issue

- **SIMD across tiles:** "All of a slice's tiles execute the same instruction stream (SIMD), so we can factor out the common instruction decode and dispatch logic into its own tile (ICU)" (Sec. I-A, p.146).
- **Queues:** "144 independent instruction queues (ICUs) on-chip, each can issue **one or more instructions per cycle** and the compiler has explicit control of the program order in each instruction queue" (Sec. II, p.147).
- **Ifetch:** "has a single stream operand which carries the text of the instructions in their program order, filling the IQ with **640-bytes (a pair of 320-byte vectors)** of instructions. All functional slices can fetch instructions simultaneously with normal instruction execution. The compiler performs omniscient prefetching ... It is imperative that IQs never go empty so that a precise notion of 'logical time' is maintained" (Sec. III-A3, p.152).
- **Flow directions:** "instructions flow Northward from the ICUs to the functional slices, while data ... flow East and West" (Sec. I-B, p.146). The ICUs sit at the south edge (Fig. 5).
- **Sync and Notify:** "One IQ is designated as the notifier and it issues a Notify instruction while all other IQs are parked on a Sync instruction — receipt of the Notify is broadcast to all the IQs" (Sec. III-A2, p.152).
- **Program start-up:** "This barrier synchronization is only required once after the chip resets. However, in practice, we start each program with a set of 'preamble' instructions which configure each tile then perform a Sync to ensure that all functional slices are aligned to the same logical time" (p.152).
- **Model loading:** the PCIe module "provides a lightweight DMA engine to emplace a model onto the TSP memory, and provides an entry point for bootstrapping the model execution" (Sec. II item 6, p.149).
- **Logical time:** "the compiler tracks the state of 144 independent program queues on a cycle-by-cycle basis" (p.152).

## 8. MXM

- **Planes:** "four (4) independent 320×320 ... planes of multiply-accumulate (MACC) units. Each 320×320 plane is comprised of 20 16×16 supercells that produce a partial-sum each cycle and pass it to the adjacent tile" (Sec. III-D, p.152).
  - The quote says "20" supercells. The geometry suggests 20 supercells per column (20×20 overall); this is my inference.
- **Weight install rate:** "It requires 16 streams each with 16 bytes to install 256 8-bit weights (IW) in each supercell on every cycle. Using all 32 streams in each direction allows us to emplace weights in both MXM planes simultaneously on both MXM hemispheres, loading all **409,600** weights on-chip in less than 40 cycles" (p.152).
- **Output rate:** "With weights installed, every cycle the MXM can generate a new int32 dot-product of input activations with installed weights. The features output from the MXM can be accumulated using the accumulators on each int32 or fp32 output stream" (p.152–153).
- **Numerics:** "8-bit integer, and 16-bit floating point by using two 320×320 byte-planes in tandem for 16-bit floating point ... The 320-element sum is produced for each output with only a single rounding step" (p.153). "The MXM accepts int8 or fp16 inputs and accumulates to int32 or fp32" (Sec. IV-D, p.154).
- **Fig. 7 (p.152, fig. reading):**
  - The array is drawn as "320 input channels" by "320 output features", with "Load data into array from side".
  - Each cell computes "a=a + b*c"; a "16 columns × 16 rows" supercell is shown.
  - The "antidiagonal of two-dimensional array" is highlighted.
  - The caption says: "activations and weights being loaded at the side of the array, and INT32 or FP32 results flow back from the inside edge."
- **Under-use with power-of-2 channels:** "256×256 dimensions of weights split across multiple passes under-utilizes the MXM" (Sec. IV-E, p.154).
- **Sub-units (Fig. 4):** LWB, IW, ABC on the input side and ACC on the output side.

## 9. VXM

- **ALUs:** "Each superlane implements a 4x4 mesh of vector ALUs capable of doing ×16-SIMD computations — **16 vector ALUs per lane**. Each of the ALU's 32-bit input operands are organized along naturally aligned quad-stream group (SG4)" (Sec. III-C, p.152). That gives 5,120 vector ALUs in total, "capable of 32-bit fixed and floating point operations" (Sec. VII, p.156).
- **No condition codes:** the ALUs "do not produce condition codes or status flags ... they are stateless". Saturating and modulo variants are provided instead (p.152).
- **Chaining:** "chaining together two or more vector ALUs within each lane, allowing multiple ALU operations to be performed without committing the intermediate results to main memory" (p.152).
- **Throughput:** the "VXM has fp32 capacity to stream at the same rate of output produced by the 4 MXM planes" (Sec. IV-D, p.154).

## 10. SXM

All of this is from Sec. III-E (p.153) and Fig. 8.

- **Lane shifters:** "two sets of lane shifters that execute shift instructions (Figure 8) both North and South ... usually allocated in pairs ... select which elements we want from either (i) North-shifted, (ii) South-shifted, or (iii) unshifted".
- **Fig. 8 select encoding (fig. reading):** "Selection stream specifies how the output vector is a composite of four sources: 00=unshifted data, 01=north-shifted, 10=south-shifted, or 11=old (prior) data".
  - The figure's example uses "Shift SOUTH 3" (lane i receives element i+3, and the top lanes are zero-filled) and "Shift NORTH 2" (lane i receives element i−2, and lanes 0–1 are zero-filled).
- **Permute:** "a programmed bijection to remap the 320 lanes on a set of similarly indexed streams, one per superlane."
- **Distributor:** "used to arbitrarily remap the 16 lanes within each superlane ... at full bandwidth, or zero-fill any or all of the 16 elements".
- **Transpose:** "256 elements organized as 16 streams each with 16 elements ... takes 16 incoming streams and produces 16 output streams". "Two instances of the SXM ... Each can issue two (2) transpose instructions, yielding a maximum of four (4) simultaneous transpose 16x16 operations."
- **Rotate:** n×n input gives n² output streams, with n = 3 or 4 (Table I). It is used in the 3x3 max-pool example (Fig. 11, p.156).

## 11. C2C

- **Links:** "sixteen (16) ×4 links operating at 30 Gbps each ... 16 ×4 ×30Gb/s ×2 directions = 3.84 Tb/s" (Sec. II item 6, p.148–149).
- **Instructions:** Send, Receive and Deskew ("plesiochronous links") (Table I). Fig. 4 shows TX and RX slices.

## 12. Determinism

- **No reactive hardware:** "eliminating all reactive elements in the hardware (e.g. arbiters, and caches)" (Abstract).
- **Motivation:** "caches, branch predictors, and prefetchers ... do not bound worst-case performance" (Sec. I, p.145).
- **Predictability:** "The TSP's hardware eliminates arbiters and other reactive elements in the data path, making performance deterministic and precisely predictable from run-to-run" (Sec. IV-F, p.155).
- **No flow control:** there is no packet routing, arbitration or flow control on chip (Sec. V-c).
- **No data-dependent optimisations:** the TSP avoids sparsity and pruning tricks "to maintain a strictly deterministic execution time and power profile" (Sec. VI, p.156).
- **Synchronization:** there is no explicit producer/consumer synchronization "except once at the beginning of the program" (Sec. VI).

## 13. The compiler's role

- **Scheduling is the compiler's job:** "pushing the complexities associated with scheduling into the compiler ... it falls on the compiler to precisely schedule instructions" (Sec. II, p.147).
- **Interception:** "The compiler precisely tracks the chip's architectural state and uses that knowledge to ensure that instructions correctly intercept its stream operand(s)" (Sec. I-B, p.147).
- **Software-defined hardware:** "the compiler's back-end can precisely track the position and time-of-use of any stream on-chip ... 'software-defined hardware'" (Sec. III, p.151).
- **Memory management:** the compiler manages memory for tensors and program text, and allocates concurrent stream operands into separate MEM slices "as streams propagate through the MEM system they 'pick up' operands from the MEM slices en route to the MXM". It explicitly schedules individual banks (Sec. IV-A, p.153).
- **Resource bottleneck:** "the most expensive resources ... the MXM's four (4) 320x320 MACC arrays and the MEM slices feeding them". The VXM was mostly balanced (Sec. IV-B, p.154).
- **Memory-slice contention:** this delayed the start of later pipelines. Changing allocation and bank interleaving saved about 5,500 cycles (Sec. IV-C).
- **Chaining:** "MEM(x) → SXM(y) → MXM(z)" (Eq. 3). The common ResNet pattern is "Read → Conv2D → Requantize → ReLU → Write" (Sec. IV-C).
- **No explicit stream-allocation algorithm is described.**

---

## Not found / unverified

**Searched in [P] but absent:**

- **Per-instruction d_func and d_skew values:** no numeric latency for any instruction (Read, Write, Add, MXM ops, Transpose, and so on). Only "1 or more cycles".
- **Explicit hop counts:** no explicit hop count per slice. The 45 stream-register positions and the one-hop-per-quad-of-4-MEM reading are my interpretation of Fig. 4 only.
- **ICU internals:** IQ depth in instructions, instruction encoding and size, and how "one or more instructions per cycle" are issued.
- **Ifetch latency:** no cycle cost for Ifetch, and no ICU-to-tile wiring delay beyond the "+1 cycle per tile northward" stagger.
- **MXM internals:**
  - pipeline depth through the 320×320 array;
  - LW buffer size;
  - fp16 supercell details;
  - exact accumulator count and depth;
  - activation buffer size.
- **VXM op list:** no full list of VXM ops or type conversions beyond Table I and `add_sat/mod`, `mul_sat/mod`. Per-op latencies and the exact chaining topology of the 4×4 mesh are not given.
- **SXM internals:** shift range limits, permute map storage and programming, and the number of lane-shifter units per SXM.
- **Power:** absolute power or TDP in watts. Only relative power appears (Fig. 10).
- **Clock:** 900 MHz nominal (Abstract) versus 1 GHz used for all arithmetic. The paper does not reconcile the two.
- **ResNet-50 latency:** given as both 43 µs and 49 µs in the paper.
- **SRAM timing:** SRAM read latency in cycles, and the gather/scatter map format.
- **Program termination:** how a program ends or signals the host.
- **Not consulted:** secondary sources (Groq patents, Hot Chips 2020, Groq ISCA 2022 "software-defined tensor streaming multiprocessor" paper, Linley talks). They may contain latency numbers but were not fetched, so nothing here comes from them.

**From memory, unverified (not used anywhere above):** I recall that later Groq material (ISCA 2022 / GroqChip docs) gives more precise per-functional-unit latencies and a slightly different C2C description. I did not verify this, and it must not be used without fetching those sources.

---

## Parameters for the simulator

| Parameter | Value | Source location | Confidence |
|---|---|---|---|
| Lanes (maxVL) | 320 | Sec. II p.147; Sec. II-F p.151 | High |
| Superlanes / tiles per slice | 20 | Sec. II p.147 | High |
| Lanes per superlane (minVL) | 16 | Sec. II p.147 | High |
| Element width per stream | 1 byte | Sec. I-B p.146 | High |
| Streams per direction | 32 (IDs 0..31), East and West | Sec. II p.147 | High |
| Multi-byte type packing | int16 = 2 streams, int32/fp32 = 4 (SG4 aligned) | Sec. I-B p.146 | High |
| Stream hop rate | 1 stream-register hop per cycle | Sec. V-c p.155 | High |
| Stream register positions per direction | 45 (SR0..SR44, MXM to MXM) | Fig. 4 p.148 (fig. reading) | Medium |
| MEM slices per SR hop | 4 (one SR per quad) | Fig. 4 (interpretation) | Low–Medium |
| Slice order (W→E) | MXM, SXM(+C2C), MEM43..0, VXM, MEM0..43, SXM(+C2C), MXM | Fig. 2 p.146; Sec. II-B p.149; Fig. 4 | High (coarse) / Medium (fine) |
| ICU queues | 144 (6+14+44+16+44+14+6) | Sec. II p.147; Fig. 2 | High (total) / Medium (split) |
| Instruction vertical stagger | +1 cycle per tile northward, 20 cycles total | Sec. II-B, II-C p.150 | High |
| Data stagger | superlane k lags by k cycles | Sec. II-C p.150, Fig. 6 | High |
| Timing equation | T = N + d_func + δ(j,i) | Eq. 4, Sec. III p.151 | High |
| d_func / d_skew values | not given; choose your own | — | n/a |
| NOP repeat field | 16 bits (up to 65,535 cycles) | Sec. III-A1 p.151 | High |
| Sync/Notify barrier latency | 35 cycles | Sec. III-A2 p.152 | High |
| Ifetch payload | 640 B (2 × 320-B vectors) per Ifetch | Sec. III-A3 p.152 | High |
| MEM slices | 88 (44 per hemisphere), MEM0 nearest VXM | Sec. II-B p.149 | High |
| Address bits per slice | 13 (8,192 words of 16 B per tile) | Sec. II item 5 p.148 | High |
| Capacity per slice | 2.5 MiB; total 220 MiB | Sec. II-B p.149–150 | High |
| Banks per slice | 2 (pseudo-dual-port: 1 read + 1 write per cycle if different banks) | Sec. III-B p.152 | High |
| SRAM bandwidth | 2 banks × 320 B/cycle per slice; 55 TiB/s total | Eq. 2 p.150 | High |
| ECC | SECDED, 9 check bits per 128-bit word (137 b) | Sec. II-D p.150 | High |
| MXM planes | 4 × 320×320 MACC (2 per hemisphere) | Sec. III-D p.152 | High |
| MXM dtypes | int8→int32, fp16→fp32 | Sec. III-D p.153; IV-D p.154 | High |
| MXM weight install | 16 streams × 16 B → 256 weights per supercell per cycle; all 409,600 weights in <40 cycles | Sec. III-D p.152 | High |
| VXM ALUs | 16 per lane (4×4 mesh), 5,120 total, 32-bit operands | Sec. III-C p.152; VII p.156 | High |
| SXM instances | 2 (1 per hemisphere); max 4 concurrent Transpose16 | Sec. III-E p.153 | High |
| SXM select encoding | 00 unshifted, 01 north, 10 south, 11 old | Fig. 8 p.153 (fig. reading) | Medium |
| Clock | 900 MHz nominal; 1 GHz used in calculations | Abstract; Sec. II-B p.150 | High (with caveat) |
| Peak | 820 TOps/s (int8 @1 GHz) | Sec. VII p.156 | High |
| C2C | 16 × x4 links @ 30 Gbps; 320-B Send/Receive | Sec. II item 6 p.148–149 | High |
| Die | 25×29 mm, 14 nm, 26.8B transistors | Abstract; Sec. VII | High |
| ResNet-50 | 20.4K IPS batch 1; latency <43 µs or 49 µs (inconsistent) | Abstract; Sec. I-C; Sec. V | High (inconsistency noted) |
