# 2. Three machines at a glance

## One sentence each

- **Cerebras WSE-3** is one chip the size of a whole silicon wafer: about 900,000 tiny
  processors, each with its own 48 KB of memory, joined by a mesh.
- **Tenstorrent Blackhole** is an ordinary-sized chip holding a grid of 140 larger cores,
  each a small cluster of RISC-V processors around a matrix engine, with ordinary DRAM at
  the edge and Ethernet ports to reach the next chip.
- **Groq's TSP** (sold as the LPU) is an ordinary-sized chip with no processors in the usual
  sense: columns of memory, vector and matrix units, and conveyor belts of data running
  between them on a schedule the compiler fixed in advance.

## The numbers

Each row compares like with like where the sources allow it. Where a machine has no such
thing, the cell says so. Labels are explained in the [README](README.md).

| | Cerebras WSE-3 | Tenstorrent Blackhole (p150) | Groq TSP (LPUv1) |
|---|---|---|---|
| Silicon | One wafer, 46,225 mm², TSMC 5 nm, 4 trillion transistors [vendor] | One die, 6 nm class; card sold with 120 of 140 cores enabled [vendor] | One die, 25 × 29 mm, 14 nm, 26.8 billion transistors [vendor] |
| Compute elements | 900,000 active processing elements (PEs) of 970,000 built [vendor] | 140 Tensix cores, each with 5 small RISC-V processors, a matrix engine and a vector engine; plus 16 large RISC-V cores [vendor] | 4 matrix planes of 320 × 320, one vector unit of 16 ALUs per lane, 2 switch units, 88 memory slices [vendor] |
| Width of one operation | 8 half-precision values per instruction on one PE [vendor] | A 32 × 32 tile, as four 16 × 16 faces [vendor] | A 320-element vector [vendor] |
| Fast memory beside compute | 48 KB SRAM per PE, 44 GB on the wafer [vendor] | 1,536 KiB SRAM ("L1") per core, about 180 MB on a 120-core card [vendor] | 220 MiB SRAM on the chip [vendor] |
| Bulk memory | None on the wafer; weights live in the PEs | 32 GB GDDR6 at 512 GB/s [vendor] | None on the chip; a model spans many chips |
| On-chip network | Mesh, 32-bit wavelets on 24 colors, routes fixed at load time [vendor] | Two 2-D torus networks carrying addressed packets [vendor] | 32 eastward and 32 westward streams per lane, one hop per cycle [vendor] |
| Off-chip links | 1.2 Tb/s Ethernet per system (CS-3) [vendor] | 10 × 400 GbE per chip [vendor] | 11 chip-to-chip ports, 235 GB/s in total [vendor] |
| Clock | Not published for WSE-3 (1.1 GHz for WSE-2) [vendor] | Up to 1.35 GHz [vendor] | 900 MHz nominal [vendor] |
| Peak arithmetic | 125 PFLOP/s, stated as sparse [vendor] | 664 TFLOP/s at 8-bit block float, lowest fidelity; 166 TFLOP/s at full-fidelity BF16 [vendor; derived] | About 750 TeraOps/s, int8 [vendor] |
| Timing of a run | Set by when data arrives | Set by when data arrives, with back-pressure | Fixed by the compiler before the run |
| Programmer writes | CSL, a language for one PE and a layout | C++ kernels for the processors in each core, or TT-NN in Python | A model; the compiler emits the schedule |

Sources for each cell are the three courses: Cerebras chapters 2 to 4, Tenstorrent chapters
A03 to A09, and the Groq dossier (`sim_grok_1/research/dossier.md`, sections 1 and 3).

## Three things the table shows

**The memory rows explain the rest.** Cerebras has 44 GB of single-cycle memory on one piece
of silicon. Groq has 220 MiB per chip and Tenstorrent about 180 MB of it per card. A
70-billion-parameter model at 16 bits is 140 GB. Cerebras fits it on four wafers [vendor:
Hot Chips 2024 describes four WSE-3 systems with 20 layers each]. Groq's own paper says
capacity "typically requires partitioning across hundreds to thousands of chips". Tenstorrent
keeps the weights in DRAM instead, 32 GB per chip, and accepts DRAM's lower bandwidth.

**The "width" row shows three different ideas of a unit of work.** A Cerebras PE is a small
scalar-plus-SIMD processor; the machine gets its speed from having 900,000 of them. A
Tenstorrent core multiplies whole 32 × 32 tiles. A Groq chip handles one 320-element vector
per cycle across the full height of the die. The same matrix product is therefore
thousands of tiny steps on one PE, a few dozen tile operations on one Tensix core, and a
single instruction on a Groq matrix plane (chapter 7 runs all three).

**Peak arithmetic is the least comparable row.** The three figures use different number
formats, and Cerebras's is a sparse figure. Chapter 1 explains why peak arithmetic rarely
decides token speed anyway.

## Newer generations

Each company has a successor that changes the numbers but not the architecture.

- Cerebras's WSE-3T (in the CS-4) has the same core and transistor counts as the WSE-3 and
  about twice the memory and fabric bandwidth [vendor].
- Tenstorrent's next chip, Quasar, is pre-silicon; ttsim ships a binary model of it.
- Groq's second design, LP30, sold by NVIDIA as "Groq 3" in LPX racks, has 500 MB of SRAM
  per chip, 96 chip-to-chip links and 256 chips per rack [vendor]. Its clock, slice counts
  and instruction set are not public, so the comparison here uses the first chip, which is
  the one the papers describe.
