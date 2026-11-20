# sim_grok_1: an educational simulator of a Tensor Streaming Processor

A cycle-level Python simulator of a chip in the style of Groq's LPU / Tensor
Streaming Processor (TSP), plus a toy compiler that statically schedules a small
model onto it.

It shows how a deterministic, compiler-scheduled AI chip works:

- functional slices (MEM, VXM, MXM, SXM) laid out west to east;
- data flowing on numbered east and west streams, one position per cycle;
- one instruction queue per unit, firing on exact cycles;
- no caches, no arbitration, no stalls: if an operand is not where the compiler said it would be on the right cycle, the run fails.

**This is not a copy of the real chip.** The structure follows the published
papers, but every instruction latency is an assumption and the default chip is
scaled down. See "What is sourced and what is assumed" below.

## Run it

Requires Python 3.10 or later with NumPy, and pytest for the tests.

```bash
python -m tsp.run all
```

This compiles and simulates the three milestones, checks them, and writes the
results to `timelines/`:

| Milestone | What it computes | Cycles | Timeline |
|---|---|---|---|
| M1 | `y = relu(W.x + b)`, int8 weights, int32 result | 68 | [timelines/m1_timeline.html](timelines/m1_timeline.html) |
| M2 | a two-layer MLP with requantisation between layers | 96 | [timelines/m2_timeline.html](timelines/m2_timeline.html) |
| M3 | one simplified transformer decode step, sequence length 4 | 465 | [timelines/m3_timeline.html](timelines/m3_timeline.html) |

Cycle counts include the 35-cycle start-up barrier and depend on the assumed
latencies, so they say nothing about the real chip's speed.

Open a timeline in a browser. The upper rows are the units and the instructions
they dispatch; the lower rows are the stream lanes. Click a column, or use the
arrow keys, to see the whole chip on that cycle. Next to each timeline are the
trace (`*_trace.json`) and the per-unit program as text (`*_program.asm`).

All commands are run from this folder (`sim_grok_1/`); the package is not
installed, so `tsp` is found only from here.

Run one milestone, or choose the output folder:

```bash
python -m tsp.run m3 --out /some/folder
```

Run the tests:

```bash
python -m pytest -q tests
```

Expected result: `370 passed, 2 skipped`. The two skipped tests are the browser
tests of the timeline (`test_browser_render` and `test_real_m1_run` in
`tests/test_viz.py`). They need the Python `playwright` package and a Chromium
it can launch, and are skipped when the package cannot be imported.

### Compile your own graph

```python
import numpy as np
from tsp.graph import Graph
from tsp.params import ChipConfig
from tsp.compiler import compile_graph
from tsp.hw import Simulator

config = ChipConfig.toy()
g = Graph("demo", lanes=config.lanes)
x = g.input("x", "int8", 4)
W = g.const_matrix("W", np.array([[1, 2, 3, 4], [-1, 0, 1, 0]]), "int8")
b = g.const("b", np.array([10, -10]), "int32")
g.output("y", g.relu(g.add(g.matvec(W, x), b)))

program = compile_graph(g, config)
sim = Simulator(program)
sim.poke("x", np.array([1, 1, 1, 1], dtype=np.int8))
trace = sim.run()
print(sim.peek("y"), trace.n_cycles)
```

This prints `[20  0] 68`: the two outputs and the cycle count.

Shapes are fixed when the graph is built. To run a different size you compile a
different program, as on the real system (dossier section 3).

## How it works

### The machine

Positions run west to east: `MXM_W`, `SXM_W`, eight MEM slices, the VXM (16
ALUs), eight MEM slices, `SXM_E`, `MXM_E`. Each cycle the simulator:

1. shifts every stream value one position in its direction (values leave at the chip edges);
2. writes each result that is due into the stream register at its unit's position;
3. lets every unit's queue dispatch at most one instruction, which samples its operands from the registers at its own position;
4. commits memory writes and weight installs.

A result dispatched at cycle `t` with latency `d` at position `xp` can be read at
position `xc` at exactly cycle `t + d + |xc - xp|`. That one rule is what the
compiler schedules against.

A queue holds data instructions plus `Nop n` and `Repeat n,d` for timing, and
starts with `Sync` (or `Notify` in one queue), which aligns all queues before
the program proper begins.

The instruction queue and the hardware model implement more than the compiler
uses. Compiled programs contain only `Sync`/`Notify`, `Nop`, `Read`, `Write`,
`Vxm`, `Iw`, `Abc` and `Distribute`. `Repeat`, `Permute` and `Shift` are
exercised only by hand-written programs in the unit tests.

### The compiler

`compile_graph` takes a fixed-shape graph through these stages
(`tsp/compiler/`):

1. **Tiling.** Operations are fused into tiles of the form read, chain of operations, write. A tile is rigid: its internal timing is fixed.
2. **Placement.** Every stored value gets MEM slices and addresses. A 4-byte value occupies 4 streams, so its 4 byte-planes sit on 4 different slices.
3. **Unit assignment.** Each operation gets a unit and each result a direction.
4. **Timetable.** Relative times inside each tile follow from the arrival rule; memory reads are timed backwards from their consumer.
5. **Scheduling and conflict resolution.** Tiles are placed one at a time against a reservation table of unit dispatches and stream registers. A conflict is resolved by choosing another stream, then another ALU, then by delaying the tile one cycle.
6. **Emission.** Each unit's dispatch times become a queue padded with `Nop`s.

Results are parked in memory between tiles. A later read can be timed freely, so
delaying one tile never breaks an earlier decision.

### Checks

- `tsp/validate.py` checks a trace against the program: no planned value is overwritten before its last reader, dispatches match the queues, every operand arrives exactly when its consumer fires, and every result appears exactly the configured latency after its dispatch. The configured latencies are the program's own `config.latency`, which defaults to the ledger values.
- `tsp/reference.py` interprets a graph in NumPy with the simulator's arithmetic, for bit-for-bit comparison. Each model also has a separate NumPy reference that does not use the graph.
- The simulator itself raises an error if an instruction samples an empty register or a value with the wrong debug tag, or if a Read or Write uses an address the compiler assigned to a different tensor.
- These checks cover timing, routing and addressing. They cannot tell that an instruction does the wrong arithmetic (for example `add` where the graph said `sub`); only the comparison with the NumPy references catches that.

## What is sourced and what is assumed

The full list is the ASSUMPTIONS LEDGER in
[research/dossier.md](research/dossier.md), section 7. Every numeric parameter
in the code lives in `tsp/params.py` with its ledger ID, and a test fails if a
number appears elsewhere without one.

**Sourced from the ISCA 2020 and 2022 papers and Groq's 2026 SHIP paper**

- The slice types and their west-to-east order.
- 32 streams in each direction, 1 byte per stream element, wider types on groups of streams (the papers give int16, int32 and fp32; fp16 on 2 streams is derived from the 1-byte element, G5).
- Streams move one register per cycle and flow until they leave the chip or are overwritten.
- 16 lanes per superlane, 16 ALUs per lane in the VXM, 13-bit memory addresses.
- The instruction names (`Read`, `Write`, `Distribute`, `Permute`, `Shift`, the VXM operation names, and the paper's IW and ABC, written `Iw` and `Abc` here), `Nop` with a 16-bit count, `Repeat`, and the 35-cycle `Sync`/`Notify` barrier. The instruction fields are this project's own; the papers give no encoding.
- One instruction per unit per cycle (T16). The sources conflict here: Groq's SHIP paper and Hot Chips 2022 slides say one per cycle, which the simulator follows; the ISCA 2020 paper says a queue "can issue one or more instructions per cycle" without saying when.
- MXM data types (int8 to int32, fp16 to fp32), 16 streams of weights installed per cycle, and a single rounding step in the sum.
- The 900 MHz clock, used only to turn cycles into nanoseconds.

**Assumed**

- **Every instruction latency** (ledger T6 to T13). The papers say only "1 or more cycles".
- When operands are sampled and exactly where and when a result appears (T3, T4).
- The toy geometry: 16 lanes instead of 320, 8 memory slices per hemisphere instead of 44, one MXM plane per hemisphere instead of two, one stream register per slice instead of one per group of four memory slices (G2, G7, G8, G10).
- How VXM ALUs chain, how `Repeat` is timed, the result-length field that keeps padding lanes zero, the requantise arithmetic, and how a program ends (B12, T18, B19, B20, B21).
- The MXM reduced to two instructions: `Iw` installs rows straight from streams and `Abc` multiplies and emits the result, where the paper has separate `LW` and `ACC` steps (B9). An fp16 product runs on one plane instead of two byte-planes in tandem (B7).
- One Read or Write per MEM slice per cycle; the paper allows one of each on different banks (B4).
- Which queue issues `Notify` (always the first VXM ALU), and that constants and inputs are already in memory at cycle 0 (B14, B22).
- Integer VXM arithmetic wraps around; the paper's saturating variants are not offered (B11).
- A MEM `Write` stores the value and leaves it flowing on its stream (B2). The ISCA 2020 paper says only that a stream ends by leaving the chip or being overwritten, and the simulator follows that; one Hot Chips 2022 slide says "a write terminates a stream". Compiled programs never read a value after its `Write`, so their outputs and cycle counts are the same under either reading; a test checks this.
- One instruction queue per unit: per MEM slice, per VXM ALU, per MXM plane and per SXM (G14). Only the total of 144 queues and the per-group counts are published.
- Every unit accepts a new instruction every cycle whatever its latency (B18).
- Stream registers and memory words carry an empty/valid state and a debug name that the hardware does not have; they exist so that the simulator can detect a mistimed or misaddressed operand (B16).
- The whole compiler algorithm. Groq has not published theirs (C1 to C4).

**Left out:** multi-chip links and their `Send`, `Receive` and `Deskew`
instructions, ECC, `Config`, Gather and Scatter, memory banks and power (all
B17); instruction fetch from memory (B15); the SXM's Rotate and Transpose (B13);
the VXM's `mask` (B11); and the per-tile stagger of instructions (T5: the
simulator runs in the time of tile 0 and adds `tiles - 1` cycles to the reported
wall-clock time). Also left out are the MEM instructions `Countdown`, `Step` and
`Iterations`, which set up an address-generation loop (B17). They appear in the
instruction table of Groq's ISC 2020 and Hot Chips 2022 slides but not in the
ISCA 2020 paper's Table I; here every `Read` and `Write` carries one explicit
address.

`ChipConfig.isca2020()` uses the published slice counts (320 lanes, 44 memory
slices per hemisphere, 2 MXM planes per hemisphere) with the same assumed
latencies; tests run M1 at 320x320 on it. It is not a model of the real chip's
stream registers: it keeps one register position per slice (93 positions, where
the paper's Fig. 4 shows 45, G8). The compiler uses only MXM plane 0 of
each hemisphere, and it rejects `broadcast` on this configuration, because
`Distribute` cannot move data between superlanes.

### Sources that could not be reached

The Hot Chips 2026 slides are behind paid registration and are known here only
through a live blog. The Groq-hosted copies of both ISCA papers now return 404;
archived or mirrored copies were read instead. The ISCA 2020 paper was re-read
in full from a mirrored copy on 2026-11-20, and the quotations, page references,
instruction table and figure readings taken from it were confirmed
(`research/01_tsp_isca2020.md`). Details are in the dossier, section 0.

## Layout

| Path | Contents |
|---|---|
| `research/` | The four research reports and `dossier.md` with the assumptions ledger |
| `plan.md`, `plan-review.md` | The design, the independent review of it, and what changed |
| `tsp/params.py` | Every parameter, with ledger IDs |
| `tsp/isa.py`, `program.py`, `trace.py`, `graph.py` | Instruction set, program, trace and graph formats |
| `tsp/icu.py`, `tsp/asm.py` | Instruction queues; program checker and text format |
| `tsp/hw/` | Stream registers, MEM, VXM, MXM, SXM and the cycle loop |
| `tsp/compiler/` | The scheduling compiler, one file per stage |
| `tsp/models/` | The three milestone models and their NumPy references |
| `tsp/validate.py`, `tsp/reference.py` | Trace validator; graph interpreter |
| `tsp/viz/` | The HTML timeline |
| `tests/` | Unit, end-to-end, determinism and traceability tests |
| `timelines/` | Generated timelines, traces and programs for M1 to M3 |
| `verification.md` | Independent verification report |
