# 10. What was checked, and what was not

The earlier chapters lean on three courses and three simulators. This chapter records how
far each was checked, so a reader can tell a confirmed statement from an unconfirmed one.

## How the checking was done

Each course was checked in two rounds. In each round a reviewer took a set of pages and did
three things:

1. compared every quoted figure and quotation with its primary source (paper, datasheet,
   vendor documentation or source file at the pinned commit);
2. re-ran every command the page shows on the simulator, and compared the output;
3. fixed errors and filled gaps in place, and listed what could not be confirmed.

The second round re-checked the first round's fixes, re-ran what the first round could not
run, and made the pages agree with each other where two pages had stated the same fact
differently. This series was written after that and then checked once by a separate
reviewer who had not written it.

## The simulators

| Simulator | Version | What ran |
|---|---|---|
| Cerebras SDK | 2.10.1, WSE-3 and WSE-2 targets | All 7 course programs pass on both targets; the experiments in this series |
| ttsim with tt-metal | ttsim v1.15.0 (`b3620244`), tt-metal `7aad8aac`, built from source | The tt-metal programming examples, the course's host programs and patches, Python TT-NN, one- and two-chip Wormhole builds, Blackhole |
| `sim_grok_1` | this repository | 370 tests pass, 2 skipped; the experiments in this series |

A simulator run confirms what the simulator does. It does not confirm what the hardware
does. Chapter 7 says what each simulator's cycle count means.

## Cerebras course

Both rounds are complete for all 18 chapters, the 5 appendices and the 7 programs.

Main corrections:

- Figures attributed to the wrong source or the wrong chip generation (WSE-2 details quoted
  as WSE-3, and the reverse).
- Fabric dimensions: a CS-2 fabric is 757 × 996 and the largest program rectangle is
  750 × 994; the course had a third pair of numbers.
- Queue depths were described as unpublished. The SDK reference gives them.
- The 2,314 tokens-per-second figure could not be traced to Cerebras; the pages now cite
  the vendor's own 2,500 and mark 2,314 as unverified.
- System power is 23 kW at launch and 27 kW in the datasheet; ratios that used one figure
  now say which.

Still open:

- Some tables in chapters 11 to 15 come from program variants that are not in the
  repository, so they could not be re-run.
- Several quotations in chapter 8 about the CS-4 (redundancy, power feeds) were not found
  in a primary source and are marked.
- Cycle counts that include the host loop vary from run to run. The pages say so; the
  counts measured on the device repeat exactly.
- A few links in the bibliography are dead.

## Tenstorrent course

Both rounds are complete for the 22 chapters (A01 to A22) and for labs B00 to B07. Labs
B08 to B11 have had the first round; the second is in progress.

Every command with a deterministic result was re-run on ttsim and now matches its page:
clock counts, hashes, error messages, correlation figures and tables. That covers the
C++ examples, the course's patched simulator builds (packet logs, performance counters,
Ethernet logs), the Python TT-NN scripts, the two-chip runs and Blackhole.

Main corrections:

- Several outputs came from scripts that were never in the repository, and two of them
  could not be reproduced. They were replaced with output from scripts that now ship
  (`a05_add.py`, `a09_shard.py`, `a19_oneop.py`, `mm_fid32.cpp`, `compute_pair.cpp`,
  `gridinfo.cpp`).
- The labs hard-coded a path from the machine they were written on. They now use one
  convention that a reader adjusts once.
- The description of the kernel cache was wrong: the cache directory is keyed on the
  kernel's path and build settings, and edits are caught by dependency hashes.
- Blackhole's processor count was 744 in places; it is 752 small RISC-V processors plus 16
  large ones.
- Two figures in lab B08 about how many results equal the exact value were wrong and
  contradicted the page's own argument. They were recomputed in exact arithmetic.
- Kernel hash directory names shown on the pages differ on every installation. The pages
  now say so.

What varies between runs, and is now marked on the pages:

- wall-clock times;
- clock counts when debug printing or the Watcher is on, because those poll from the host;
- clock counts of runs that end on a wall-clock timeout;
- one two-chip program, which ends at one of two clock counts.

Still open:

- Quotations from the Wormhole Galaxy product page, which has changed since they were
  taken.
- The summary lines of the `tt-perf-report` tool, which was not installed.
- The compiler stack above TT-NN (TT-MLIR, TT-Forge) is described from documentation only.
- In lab B00, the tt-metal build steps were not repeated from scratch; the transcripts are
  from the original build. A section on build problems met on Ubuntu 24.04 was added.
- Some figures in labs B08 to B11 that need hand-instrumented simulator builds.

## Groq simulator and notes

Both rounds are complete for the code, the tests, the README and the research notes.

Main corrections:

- The first round could not obtain the ISCA 2020 paper and marked the notes on it as
  unconfirmed. The second round obtained it and checked the quotations, page references
  and figure readings.
- The compiler accepted tensors and matrices larger than the chip model can hold. It now
  rejects them.
- The README and dossier overstated what the model covers; both now list what is left out.

Still open:

- Groq has not published instruction latencies or its compiler's algorithm. The latencies
  in `sim_grok_1` are assumptions and are labelled as such.
- Whether the 2020 paper's TSP and the 2026 paper's "LPUv1" are the same chip is an
  inference from matching process, memory size and port count.
- Two points of the papers can be read two ways (whether a memory write ends its stream,
  and how many instructions a unit accepts per cycle). The dossier records the choice made.
- The model covers one chip. Nothing about multi-chip timing in chapter 8 was simulated.

## This series

A separate reviewer checked chapters 1 to 9, the README and the experiment scripts against
the three courses and their sources, and re-ran the three experiments.

- The Groq and Tenstorrent outputs matched the saved results byte for byte.
- The Cerebras single-PE counts matched (325 and 10,154 cycles). The three whole-run counts
  differed by a few tens of cycles, as chapter 5 says they do.
- The review corrected about sixty statements. The most serious were a description of the
  Cerebras course's chapter 14 that said the opposite of what that chapter measures, a
  Groq timetable in chapter 6 read in the wrong direction, a claim that a Tenstorrent core
  on another chip is addressed like a local one, and several figures given for the wrong
  product or generation.

Not confirmed in this series:

- The Blackhole process node (TSMC 6 nm) was not found on the vendor page that was fetched.
- The 125 PFLOP/s figure for WSE-3 rests on a saved copy of the CS-3 datasheet; the vendor's
  site now advertises a larger figure, apparently for the newer wafer.
- The CS-4 figures (2.4 Tb/s, direct wafer links) come from the Cerebras course's table and
  were not traced further.
- That Groq's instruction set has no branch is read from the instruction table in the 2020
  paper. The paper does not state it.

## What is interpretation

Some of the series is argument, not fact, and no source can confirm it:

- chapter 9's three "bets", their prices, the spectrum from run time to compile time, and
  the advice on which machine to reach for;
- the "Why the difference" sections in chapters 4 and 8;
- chapter 6's account of where the removed hardware work went;
- chapter 1's description of a GPU's remedies as reactive.

These are marked as readings where they appear.
