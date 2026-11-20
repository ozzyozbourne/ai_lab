# 7. One layer on three simulators

The same kind of work, a dense matrix product, was run on a simulator of each machine. The
aim is not a race. The three simulators measure different things, and their cycle counts
cannot be compared with one another. The aim is to see what the same operation looks like
on each machine, and to be exact about what each number means.

All outputs are in [`experiments/results/`](experiments/results/), produced by the scripts
beside them.

## Groq: the whole layer is a handful of instructions

Workload: `y = relu(W·x + b)`, 8-bit weights and inputs, 32-bit result, on `sim_grok_1`.

| Size | Chip model | Cycles [measured] | Instructions issued [measured] | Matches NumPy |
|---|---|---|---|---|
| 12 inputs, 8 outputs | Toy chip, 16 lanes | 68 | 21 | yes |
| 320 inputs, 320 outputs | Published geometry, 320 lanes | 145 | 352 | yes |

Of each count, 35 cycles are the start-up synchronisation [vendor]. The counts are in the
time of the chip's bottom row of tiles; on the 320-lane chip an instruction takes 19 more
cycles to ripple up the 20 rows, which these counts leave out. The rest is: memory
slices put the weight rows on streams, the matrix unit installs them, the input vector
arrives, one `Abc` instruction produces all the dot products at once, the vector unit adds
the bias and applies ReLU, and a memory slice stores the result.

Going from 96 weights to 102,400 took the run from 68 cycles to 145. The matrix plane
handles a 320-wide vector in one instruction; a bigger layer mostly means more cycles spent
loading weights, 16 streams' worth per cycle.

**What the number means.** The structure is from the papers: unit order, streams, one hop
per cycle, the 35-cycle barrier. Every instruction's latency is an assumption [assumed],
because the 2020 paper says only "1 or more cycles". The model also has one stream
register per unit, where the real chip has 45 per direction. So 145 is exact for this
model and is not the real chip's figure.

## Cerebras: one small processor does it element by element

Workload: `y = A·x`, 32-bit floats, on **one** processing element, using the SDK's
`single-tile-matvec` benchmark on the WSE-3 target.

| Size | Cycles (run 1) | Cycles (run 2) | Verified |
|---|---|---|---|
| 16 × 16 | 325 | 325 | yes |
| 100 × 100 | 10,154 | 10,154 | yes |

The 100 × 100 product is 10,000 multiply-adds in 10,154 cycles: about one per cycle
[derived]. That is what one PE is: a small processor that multiplies a column of the matrix
by one element of the vector and accumulates, one column at a time. And 100 × 100 is nearly
all it can hold; the course finds the limit at 104 × 104 (chapter 3 of this series).

A real layer is never run this way. It is spread over a rectangle of PEs, each holding a
block of the matrix, with the vector broadcast along rows and the partial results reduced
along columns. The Cerebras course's lab on matrix multiply (chapter 14) builds the
matrix-matrix version on a square of PEs, with blocks of both matrices broadcast along rows
and columns. Its measurement is that with realistic block sizes the PEs spend nearly all
their time computing and only a few percent moving data, but reach only a third to a half
of one multiply-add per cycle, because every instruction has a start-up cost.

**What the number means.** This is Cerebras's own simulator, which one independent paper
calls "the cycle-accurate simulator, which models ideal conditions". Of the three counts
it is the closest to a hardware timing. It is still a simulation of a few PEs, and that
paper cites earlier work putting one latency (router to processor) at about 7 cycles where
the simulator shows 2 (Cerebras course, chapter 4).

## Tenstorrent: one core multiplies tiles

Workload: `C = A·B`, 640 × 640, bfloat16 (a 16-bit float), on **one** Tensix core, using
the workbench program `mm_fid` from the Tenstorrent course on ttsim (Wormhole). "Fidelity"
is the matrix engine's precision setting from chapter 2; HiFi4 is the most precise.

| Fidelity | ttsim clock at exit [measured] | Result hash | Passed |
|---|---|---|---|
| HiFi4, run 1 | 330,591 | `ef7abcd145720383` | yes |
| HiFi4, run 2 | 330,591 | `ef7abcd145720383` | yes |

A 640 × 640 matrix is 20 × 20 tiles of 32 × 32. The reader kernel fetches tiles from DRAM
over the on-chip network into circular buffers; the compute kernel multiplies pairs of
tiles on the matrix engine, 16 × 16 faces at a time, and accumulates; the writer sends
result tiles back to DRAM. The product needs 20 × 20 × 20 = 8,000 tile multiplies
[derived].

**What the number means.** Much less than it seems. ttsim is a functional model: it gets
every bit right and makes no attempt at timing. Its clock advances when the host program
asks it to step. The Tenstorrent course shows the consequence: the same multiply at the
*lowest* fidelity, which is the fastest setting on silicon, ends at clock 699,743, more
than double [measured, course lab B01]. A ttsim clock count orders events within one run and
confirms two runs did the same thing. It says nothing about speed.

## The three results together

| | Groq sim | Cerebras sim | ttsim |
|---|---|---|---|
| Workload run | 320 × 320 int8 layer | 100 × 100 f32 matrix-vector | 640 × 640 bf16 matrix-matrix |
| Count | 145 cycles | 10,154 cycles | 330,591 clocks |
| Hardware used | One matrix plane, one vector unit, memory slices | One PE of 900,000 | One Tensix core of the 72 on a Wormhole n150 card |
| Is the count a time? | For this model, yes; for the real chip, no (latencies assumed) | Approximately (vendor's cycle-level simulator) | No (functional model, host-driven clock) |
| Repeats exactly? | Yes | Yes | Yes |
| Result checked against | NumPy, bit for bit | NumPy, by the benchmark's own `--verify` | Host-computed result, by correlation (above 0.97), not bit for bit |

Do not divide one column's count by another's. The workloads differ in size and number
format, and only one of the three counts is close to a time.

## What the experiment does show

**The unit of work is visible in the counts.** Groq needed 352 instructions for a
320 × 320 layer because its instructions act on whole vectors. One Cerebras PE needed
about ten thousand cycles for a matrix with a tenth as many elements because it works an
element at a time; the machine's answer is to use hundreds of thousands of PEs at once. A
Tensix core sits between: its unit is a 32 × 32 tile, and its (larger, matrix-matrix)
workload took 8,000 tile multiplies.

**Each simulator is good for what its machine makes hard.** The Groq model is built to
check timing, because on that machine timing is correctness. The Cerebras simulator
reports cycles and memory use, because on that machine fitting in 48 KB and counting hops
is the job. ttsim checks bits and catches illegal operations, because on that machine the
hard part is getting five processors, a matrix engine and a network to agree.

**All three ran a real program to a checked result.** The mechanisms in chapters 3 to 6
were exercised on a simulator, here or in the three courses, with these exceptions: the
Groq model is this project's own reading of the papers, not Groq's software; nothing
multi-chip was run for Cerebras or Groq; and product figures come from vendor documents,
not from any simulator.
