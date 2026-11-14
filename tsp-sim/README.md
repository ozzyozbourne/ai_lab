# tsp-sim: an educational simulator of a Tensor Streaming Processor

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

Run one milestone, or choose the output folder:

```bash
python -m tsp.run m3 --out /some/folder
```

Run the tests:

```bash
python -m pytest -q tests
```

The browser test of the timeline needs the Python `playwright` package and a
Chromium it can launch; it is skipped otherwise.

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
- 32 streams in each direction, 1 byte per stream element, wider types on groups of streams.
- Streams move one register per cycle and flow until they leave the chip or are overwritten.
- 16 lanes per superlane, 16 ALUs per lane in the VXM, 13-bit memory addresses.
- The instruction names, `Nop` with a 16-bit count, `Repeat`, and the 35-cycle `Sync`/`Notify` barrier.
- One instruction per unit per cycle.
- MXM data types (int8 to int32, fp16 to fp32), 16 streams of weights installed per cycle, and a single rounding step in the sum.
- The 900 MHz clock, used only to turn cycles into nanoseconds.

**Assumed**

- **Every instruction latency** (ledger T6 to T13). The papers say only "1 or more cycles".
- When operands are sampled and exactly where and when a result appears (T3, T4).
- The toy geometry: 16 lanes instead of 320, 8 memory slices per hemisphere instead of 44, one MXM plane per hemisphere instead of two, one stream register per slice instead of one per group of four memory slices (G2, G7, G8, G10).
- How VXM ALUs chain, how `Repeat` is timed, the result-length field that keeps padding lanes zero, the requantise arithmetic, and how a program ends (B12, T18, B19, B20, B21).
- The whole compiler algorithm. Groq has not published theirs (C1 to C4).

**Left out:** multi-chip links, ECC, instruction fetch from memory, Gather and
Scatter, memory banks, power, and the per-tile stagger of instructions (the
simulator runs in the time of tile 0).

`ChipConfig.isca2020()` uses the published geometry (320 lanes, 44 memory slices
per hemisphere) with the same assumed latencies; one test runs M1 at 320x320 on
it.

### Sources that could not be reached

The Hot Chips 2026 slides are behind paid registration and are known here only
through a live blog. The Groq-hosted copies of both ISCA papers now return 404;
archived or mirrored copies were read instead. Details are in the dossier,
section 0.

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
