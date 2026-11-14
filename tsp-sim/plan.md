# Plan — educational TSP simulator and toy static compiler

Companion to `research/dossier.md`. Ledger IDs such as `L-T3` refer to the
ASSUMPTIONS LEDGER in section 7 of the dossier.

## 1. Goal and non-goals

**Goal.** A cycle-level Python simulator of one Groq-style Tensor Streaming
Processor, and a toy compiler that turns a small static compute graph into
per-queue instruction programs with exact cycle timing. The simulator has no
arbitration, no caches and no stalls: if the compiler gets a cycle wrong, the
run faults or produces a checkable error.

**Non-goals.**
- Fidelity to the real chip's latencies. They are unpublished; ours are assumed (ledger 7.2).
- Multiple chips and chip-to-chip links (dossier section 3). Out of scope.
- The 20-tile diagonal wavefront. We simulate superlane 0 and report the last superlane's completion as `cycles + tiles − 1` (L-G16).
- Ifetch, Sync/Notify, Repeat, Config, Gather/Scatter, Rotate, Transpose (L-I3, L-I4, L-I5).
- Dynamic shapes, batch > 1, control flow (L-K1).
- Performance. Plain Python and NumPy, readability first.

## 2. Machine model

### 2.1 Space

Positions are integers `x = 0 .. P−1`, `P = 2M + 5`, where `M` is the number of
MEM slices per hemisphere (L-G10, L-G11). East is `+1`, West is `−1`.

| x | Slice | Units (each has its own instruction queue, L-I1) |
|---|---|---|
| 0 | MXM_W | `MXM_W.0`, `MXM_W.1` |
| 1 | SXM_W | `SXM_W.shift`, `SXM_W.permute`, `SXM_W.distribute` |
| M+1−i | MEM_W*i*, i = 0..M−1 (MEM_W0 is next to the VXM) | `MEM_Wi` |
| M+2 | VXM | `VXM.0` .. `VXM.15` |
| M+3+i | MEM_E*i*, i = 0..M−1 (MEM_E0 is next to the VXM) | `MEM_Ei` |
| 2M+3 | SXM_E | `SXM_E.shift`, `SXM_E.permute`, `SXM_E.distribute` |
| 2M+4 | MXM_E | `MXM_E.0`, `MXM_E.1` |

Presets (`tsp/config.py`): `ChipConfig.toy()` has `M = 16`, 32 lanes;
`ChipConfig.paper()` has `M = 44`, 320 lanes. Everything else is shared.

### 2.2 Streams

There are 32 streams per direction (L-G5). A **cell** is `(dir, stream, x)`.
During any cycle a cell is empty or holds one `lanes`-byte vector plus a debug
**tag** (a string naming the value plane; tags never affect behaviour).

Let `C_t(d, s, x)` be the content of a cell during cycle `t`. `C_0` is empty.

```
C_{t+1}(E, s, x) = D                 if exactly one instruction drives (E, s, x) with visible cycle t+1
                 = C_t(E, s, x−1)    otherwise (empty when x = 0)
C_{t+1}(W, s, x) = D                 if driven
                 = C_t(W, s, x+1)    otherwise (empty when x = P−1)
```

So a value moves one position per cycle (L-G12), a producer overwrites whatever
would have arrived at its position (L-G13), and a value falls off the edge.
Reading does not consume.

### 2.3 Time (L-T1)

Each queue issues at most one **entry** per cycle. For an instruction issued at
cycle `t_i`:

- **sample cycle** `t_s = t_i + d_skew` — it reads `C_{t_s}` at its own position;
- **visible cycle** `t_v = t_s + d_func` — its result is `C_{t_v}` at its own position.

A consumer at distance `δ` in the direction of flow reads the result at
`t_v + δ`, and at no other cycle. `d_func ≥ 1` always. Latency values come from
`config.timing`, a dict `opcode → OpTiming(d_skew, d_func)` (L-T2..L-T9).

### 2.4 Data types on streams

| dtype | bytes | streams | alignment of base stream |
|---|---|---|---|
| `I8` | 1 | 1 | any |
| `F16` | 2 | 2 | even (L-G7, L-G8) |
| `I32`, `F32` | 4 | 4 | multiple of 4 (L-G6, L-G8) |

A vector of `lanes` elements with `k` bytes each is carried as `k` **byte
planes**: plane `j` (little-endian byte `j` of every element) travels on stream
`base + j`. Plane `j` of value `v` has tag `f"{v}#{j}"`.

### 2.5 Faults

The simulator raises `SimFault` (and records nothing further) when:
1. an instruction samples an empty cell;
2. two instructions drive the same cell with the same visible cycle;
3. a MEM slice gets more than one Read or more than one Write with the same sample cycle, or a Read and a Write on the same bank with the same sample cycle (L-M4, L-M5);
4. a Read addresses a word that was never written or initialised;
5. a `MATVEC` uses a weight row that is not installed, or whose dtype differs;
6. an fp16 MXM rule is broken (2.8);
7. a queue entry holds more instructions than its unit allows (L-I2), or an instruction is issued on the wrong kind of unit;
8. an operand or result reference breaks alignment, range, or direction rules (L-G8, L-X6).

A tag mismatch is **not** a fault. The hardware cannot know what a value means;
tag mismatches are recorded in the trace and caught by the validator (section 7).

### 2.6 MEM (L-M1..L-M6)

Each slice has 2 banks × `words_per_bank` addresses; one address holds one
plane (`lanes` bytes) and its tag.

- `Read(bank, addr, out)` — at `t_s` reads the word (as left by all Writes with an earlier sample cycle, or by the initial image); drives stream `out` at `t_v = t_s + d_func(READ)`.
- `Write(bank, addr, src)` — at `t_s` samples stream `src` at the slice position and stores bytes and tag. A Read sees it if the Read's sample cycle is later (L-T4).

A MEM queue entry may hold one Read and one Write (L-I2).

### 2.7 VXM (L-V1..L-V7)

Sixteen ALUs at one position. Each is stateless and accepts one instruction per
cycle. `VOp(op, a, b, out, imm)`:

| op | operand dtype(s) | result dtype | semantics (NumPy) |
|---|---|---|---|
| `ADD`, `SUB`, `MUL` | I32, I32 | I32 | wrap modulo 2³² (L-V7) |
| `ADD`, `SUB`, `MUL` | F32, F32 | F32 | `np.float32` arithmetic |
| `RELU` | I32 or F32 | same | `np.maximum(a, 0)` |
| `REQUANT` | I32 | I8 | `np.clip(a >> imm, −128, 127)` (L-V5) |
| `CAST` | I8→I32, F32→F16, F16→F32 | — | sign-extend; `astype(np.float16)`; exact (L-V6) |
| `EXP`, `TANH` | F32 | F32 | `np.exp`, `np.tanh` on float32 |
| `RSQRT` | F32 | F32 | `np.float32(1) / np.sqrt(a)` |

Operands may come from either direction (L-G15); the result goes to either
direction (L-G14). An ALU's result is visible at the VXM position at `t_v`, so
another ALU can sample it there in that same cycle (L-V3).

### 2.8 MXM (L-X1..L-X8)

Two planes per hemisphere. A plane has a weight buffer of `lanes` rows; a row is
one vector over lanes plus its dtype and tag.

- `IW(rows)` — `rows` is a tuple of `(row_index, SRef)`. At `t_s` samples every listed stream group and stores it as that row. At most 16 streams in total (L-X3). Usable by a `MATVEC` whose sample cycle is later (L-T7).
- `MATVEC(dtype, k, a, out, expect_rows)` — at `t_s` samples the activation `a`; computes `out[l] = Σ_{r<k} a[r] · row_r[l]` for every lane `l`; drives the result at `t_v`.
  - `I8`: `a` is one stream, `k ≤ lanes`; exact integer result as I32.
  - `F16`: `a` is a stream pair, `k ≤ lanes/2`, elements `a[0..k−1]` (L-X8); the sum is formed in float64 and rounded once to F32 (L-X4).
- `a` must be an outward-flowing stream and `out` an inward-flowing group (L-X6): West MXM reads `W`, writes `E`; East MXM reads `E`, writes `W`.
- **fp16 uses both planes of a hemisphere in tandem** (dossier 2.5). F16 instructions are legal only on plane `.0`. While plane `.0` holds any F16 row, any instruction issued to plane `.1` of that hemisphere is a fault; an F16 `IW` on plane `.0` clears plane `.1`.

### 2.9 SXM (L-S1..L-S4)

All three units act on bytes, identically on each stream of the group, so they
are dtype-agnostic.

- `Shift(n, a, out)` — `out[l] = a[l − n]` if `0 ≤ l − n < lanes`, else 0.
- `Permute(map, a, out)` — `out[l] = a[map[l]]`; `map` is a bijection on lanes.
- `Distribute(map, a, out)` — `map` has 16 entries in `−1..15`; for every superlane `j`: `out[16j + i] = a[16j + map[i]]`, or 0 when `map[i] = −1`.

### 2.10 Instruction queues

A queue is a list of entries: `Nop(n)` takes `n` cycles (1 ≤ n ≤ 65,535, L-T10);
`Issue(instrs)` takes one cycle and issues its instructions in that cycle. The
issue cycle of an entry is the sum of the durations before it. All queues start
at cycle 0 (L-I3). The run ends when every queue is empty and no result is
pending; `n_cycles` is one more than the last cycle in which anything was
sampled, driven or written.

## 3. Shared contracts (written by the lead before the build; frozen)

These five files are the only coupling between build agents. Agents import
them and must not edit them; change requests go to the lead.

### 3.1 `tsp/config.py`

```python
@dataclass(frozen=True)
class OpTiming:
    d_skew: int
    d_func: int

@dataclass(frozen=True)
class ChipConfig:
    name: str
    lanes_per_superlane: int        # L-G1
    superlanes: int                 # L-G2
    streams_per_dir: int            # L-G5
    mem_slices_per_hemi: int        # L-G10
    banks_per_slice: int            # L-M1
    words_per_bank: int             # L-M2
    n_alus: int                     # L-V1
    planes_per_mxm: int             # L-X1
    iw_max_streams: int             # L-X3
    nop_max: int                    # L-T10
    clock_hz: float                 # L-C1
    timing: Mapping[str, OpTiming]  # keys: READ WRITE VARITH VTRANS IW MATVEC SXM  (L-T2..T9)
    max_schedule_cycles: int        # compiler gives up beyond this (L-K6)

    lanes, n_positions                          # derived properties
    def pos(self, unit: str) -> int             # position of any unit or slice name
    def unit_names(self) -> list[str]           # every queue, West to East, fixed order
    def kind(self, unit: str) -> str            # "MEM" | "VXM" | "MXM" | "SXM"
    def toy() / paper()                         # presets
    def with_timing(self, **overrides)          # copy with changed latencies (tests)
```

`VARITH` covers ADD SUB MUL RELU REQUANT CAST; `VTRANS` covers EXP RSQRT TANH;
`SXM` covers Shift Permute Distribute. Every literal in this file carries its
ledger ID in a comment. No other source file may contain a machine parameter.

### 3.2 `tsp/isa.py`

```python
class DType(Enum): I8, F16, I32, F32          # .nbytes, .np (numpy dtype)

@dataclass(frozen=True)
class SRef:                  # a group of adjacent streams at the issuing unit's position
    dir: str                 # "E" | "W"  (direction of flow)
    base: int                # lowest stream id
    tags: tuple[str, ...]    # one tag per stream: expected (operand) or produced (result)

@dataclass(frozen=True) class Read:       bank: int; addr: int; out: SRef   # one stream
@dataclass(frozen=True) class Write:      bank: int; addr: int; src: SRef   # one stream
@dataclass(frozen=True) class VOp:        op: str; dtype: DType; a: SRef; b: SRef | None; out: SRef; imm: int = 0; to: DType | None = None
@dataclass(frozen=True) class IW:         dtype: DType; rows: tuple[tuple[int, SRef], ...]
@dataclass(frozen=True) class MatVec:     dtype: DType; k: int; a: SRef; out: SRef; expect_rows: tuple[str, ...]
@dataclass(frozen=True) class Shift:      n: int; a: SRef; out: SRef
@dataclass(frozen=True) class Permute:    map: tuple[int, ...]; a: SRef; out: SRef
@dataclass(frozen=True) class Distribute: map: tuple[int, ...]; a: SRef; out: SRef

@dataclass(frozen=True) class Nop:   n: int
@dataclass(frozen=True) class Issue: instrs: tuple[Instr, ...]

def timing_key(instr) -> str     # which config.timing entry applies
def to_bytes(values: np.ndarray, dtype, lanes) -> np.ndarray   # (nbytes, lanes) uint8 planes, zero padded
def from_bytes(planes: np.ndarray, dtype) -> np.ndarray        # inverse
def text(instr) -> str           # one-line assembly-like rendering
```

`VOp.dtype` is the operand dtype; `VOp.to` is the target dtype for `CAST`.
The tag of an installed weight row is the first tag of its `SRef`;
`MatVec.expect_rows[r]` is the tag expected in row `r`.

### 3.3 `tsp/graph.py` — compiler input

```python
g = Graph("m1")
x  = g.vector("x", DType.I8, n=20)                    # runtime input (no data)
b  = g.vector("b", DType.I32, n=24, data=b_np)        # constant
W  = g.matrix("W", DType.I8, m=24, n=20, data=W_np)   # constant matrix; data=None makes it a runtime input
y  = g.relu(g.add(g.matvec(W, x), b))
g.output("y", y)
```

Node kinds and semantics (whole-tensor, before tiling):

| builder | meaning | dtype rule |
|---|---|---|
| `vector`, `matrix` | leaf; constant if `data` given, else bound at load time | — |
| `matvec(W, x)` | `W @ x`, W is `m×n` | (I8, I8)→I32 or (F16, F16)→F32 |
| `matvec_cols(cols, x)` | `Σ_r x[r] · cols[r]`; each `cols[r]` is a vector Value (leaf or computed) of equal length | as matvec |
| `add`, `sub`, `mul` | elementwise, equal length | I32 or F32 |
| `relu`, `exp`, `rsqrt`, `tanh` | elementwise | as 2.7 |
| `requant(a, shift)`, `cast(a, dtype)` | as 2.7 | as 2.7 |
| `shift(a, n)` | `out[i] = a[i − n]` or 0, within the vector's tile | any |
| `output(name, v)` | marks a result to be written to memory | — |

Nodes are stored in creation order with integer ids; that order is the
tie-break everywhere. `Graph` only records structure and validates dtypes and
shapes. It does not evaluate anything.

Restrictions (compile errors): a graph may not contain both I8 and F16 matvecs
(2.8); `shift` operands must fit in one tile.

### 3.4 `tsp/program.py` — compiler output, simulator input

```python
@dataclass(frozen=True)
class PlaneLoc: slice: str; bank: int; addr: int           # one byte plane of one tile

@dataclass(frozen=True)
class TensorLayout:
    name: str; dtype: DType; shape: tuple[int, ...]
    kind: str                                   # "vector" | "matrix_cols"
    tiles: tuple[TileLayout, ...]

@dataclass(frozen=True)
class TileLayout:
    index: tuple[int, ...]                      # which elements this stored vector holds (see below)
    tag: str                                    # tag prefix; plane j is f"{tag}#{j}"
    planes: tuple[PlaneLoc, ...]

@dataclass
class Program:
    config_name: str
    queues: dict[str, list[Nop | Issue]]        # every unit name present, in config.unit_names() order
    constants: dict[str, np.ndarray]            # values of constant leaves
    inputs: dict[str, TensorLayout]             # where the host writes each leaf (constants and runtime inputs)
    outputs: dict[str, TensorLayout]            # where the host reads each output
    report: list[dict]                          # one record per scheduled chain (section 5.6); informational only

    def memory_image(self, feeds: dict[str, np.ndarray], config) -> list[MemInit]
    def read_outputs(self, memory, config) -> dict[str, np.ndarray]
```

Layout conventions, fixed here so the compiler and the host agree:
- A **vector** of `n` elements is cut into tiles of `tile_len` elements; tile `i` holds elements `i·tile_len ..`, zero padded, stored at lanes `0..`. `TileLayout.index = (i,)`.
- A **matrix** `m×n` is stored by columns, tiled both ways: `TileLayout.index = (out_tile, in_tile, r)` holds column `in_tile·tile_len + r` restricted to rows of output tile `out_tile` (one stored vector, the install row `r` of that weight tile).
- `tile_len = lanes` for a graph with no F16 value, else `lanes // 2`.

`memory_image` and `read_outputs` are implemented in this file by the lead from
the layouts alone; they contain no scheduling knowledge.

### 3.5 `tsp/trace.py` — simulator output

```python
@dataclass(frozen=True)
class Event:
    cycle: int
    kind: str      # "issue" | "sample" | "drive" | "mem_read" | "mem_write" | "iw_row" | "matvec_row"
    unit: str
    pos: int
    opcode: str
    dir: str | None = None       # sample / drive
    stream: int | None = None    # sample / drive
    tag: str | None = None       # tag actually seen (sample, mem_read, matvec_row) or produced (drive, mem_write, iw_row)
    expect: str | None = None    # tag the instruction expected (sample, matvec_row)
    bank: int | None = None; addr: int | None = None; row: int | None = None
    text: str | None = None      # issue: isa.text(instr)

@dataclass
class Trace:
    config_name: str
    n_cycles: int
    events: list[Event]                          # sorted by (cycle, unit order, emission order)
    occupancy: list[list[tuple[str, int, int, str]]]   # per cycle: (dir, stream, pos, tag) of non-empty cells, sorted
    digests: list[str]                           # per cycle: sha256 over all cell bytes and tags

    def to_json(self) -> str        # canonical: sorted keys, no whitespace variance
    def digest(self) -> str         # sha256 of to_json()
```

Event meaning: `issue` at `t_i`; `sample` at `t_s`, one per sampled stream;
`drive` at `t_v`, one per driven stream; `mem_read`/`mem_write` at `t_s`;
`iw_row` at `t_s`, one per installed row; `matvec_row` at `t_s`, one per row
used (`tag` = tag in the buffer, `expect` = `expect_rows[r]`).

## 4. Module breakdown and ownership

| Module | Owner | Files (exclusive) | Public interface |
|---|---|---|---|
| Contracts | lead | `tsp/__init__.py`, `tsp/config.py`, `tsp/isa.py`, `tsp/graph.py`, `tsp/program.py`, `tsp/trace.py` | section 3 |
| Hardware model | agent HW | `tsp/hw/**`, `tests/hw/**` | `tsp.hw.Chip(config).run(queues, mem_image) -> (Trace, Memory)`; `tsp.hw.run_program(program, feeds, config) -> RunResult(trace, outputs)`; `SimFault` |
| Compiler | agent COMP | `tsp/compiler/**`, `tests/compiler/**` | `tsp.compiler.compile(graph, config) -> Program`; `CompileError` |
| Visualisation | agent VIZ | `tsp/viz/**`, `tests/viz/**` | `tsp.viz.render_timeline(trace, config, title) -> str`; `write_timeline(path, trace, config, title)` |
| Checking and models | agent CHECK | `tsp/validate.py`, `tsp/reference.py`, `tsp/models/**`, `tests/check/**` | `validate(program, trace, config) -> Report`; `reference.evaluate(graph, feeds) -> dict`; `models.m1()/m2()/m3() -> (Graph, feeds)` |
| Integration | lead | `run_milestones.py`, `tests/test_e2e.py`, `README.md`, `out/**` | CLI |

`Memory` exposes `read(slice, bank, addr) -> (bytes, tag)`. `RunResult.outputs`
comes from `program.read_outputs`.

## 5. Compiler pipeline

`compile(graph, config)` runs seven passes. Each pass is a pure function of its
inputs; none reads tensor *values*, so the schedule cannot depend on data.

### 5.1 Tiling
Cut every vector into tiles of `tile_len` (3.4). Elementwise nodes become one
node per tile. `matvec(W, x)` with `W` of `m×n` becomes, for each output tile
`i`, the sum over input tiles `j` of `MATVEC(Wtile[i][j], x_j)`, combined with a
left-to-right chain of `ADD`s. `matvec_cols` requires `len(cols) ≤ k_max` (one
input tile) and is tiled over outputs only. Output: a tile-level DAG in
deterministic order (graph node id, then tile index).

### 5.2 Placement
Assign every leaf plane a `PlaneLoc`.
- Bank 0 holds leaves; bank 1 holds parked intermediates and outputs. So a slice can read a leaf and park a value in the same cycle (L-M4).
- Planes of one tile go to distinct, adjacent slices of one hemisphere (L-K4).
- Install rows of one weight tile are spread round-robin over the slices nearest the MXM that will use them (L-K5), so that up to `iw_max_streams` streams can be read in one wave.
- Addresses are bump-allocated per (slice, bank). Running out is a `CompileError`.

### 5.3 Unit assignment
- I8 `MATVEC`s take planes in the fixed rotation `MXM_W.0, MXM_E.0, MXM_W.1, MXM_E.1`; F16 `MATVEC`s alternate `MXM_W.0, MXM_E.0`. Placement (5.2) uses this assignment, so 5.3 runs before 5.2 in code; they are listed in the order of the brief.
- `SHIFT` goes to the SXM of the hemisphere where its operand is produced or stored.
- VXM operations go to the VXM; the ALU index is chosen in 5.6.

### 5.4 Chain formation
A **chain** is a list of tile-level operations executed as one rigid pattern in
which each result flows on a stream directly into the next operation. Rules:
1. A `MATVEC` always starts a chain; its activation is read from memory.
2. An operation joins the chain of the producer of its **first** computed operand if that producer's value has exactly one consumer, is not a graph output, and is the current end of its chain. Otherwise it starts a new chain.
3. Every other operand of a chain member is read from memory (a leaf, or a value parked by an earlier chain).
4. A chain ends with Writes that park its final value if that value has any consumer outside the chain or is a graph output. Every value consumed by more than one node, or by a node in another chain, is therefore parked exactly once and read back once per consumer.

This is the paper's memory-to-memory pattern (L-K3). Memory is the only place a
value waits (dossier section 5), so delay matching is done by parking.

### 5.5 Ideal timetable
For each chain, compute the offset of every instruction relative to the chain's
anchor cycle `t0`, from `config.timing` and position distances alone:
- an operation at position `x_c` sampling at `t_s` needs each direct operand produced at `x_p` to be visible there at `t_s − |x_c − x_p|`;
- a Read at slice position `x_m` feeding it must have `t_v = t_s − |x_c − x_m|`, so it is issued at `t_s − |x_c − x_m| − d_func(READ) − d_skew(READ)`; the `k` planes of a value are read from `k` slices at `k` different cycles and merge into one aligned group;
- a parking Write at a slice the result passes samples at `t_v + distance`.

Then compute, ignoring resources, each chain's earliest anchor (ASAP: all parked
operands written at least one cycle before their Read samples; the weight tile
installed) and each chain's **height** (longest path in cycles to any output).

### 5.6 Conflict resolution (L-K2)
Reservation tables:

| Table | Key | Holds |
|---|---|---|
| queue slots | (unit, issue cycle) | at most the unit's issue width; MEM: one Read and one Write |
| memory ports | (slice, sample cycle) | read bank, write bank |
| stream cells | (dir, stream, diagonal) with diagonal = `t − x` eastward, `t + x` westward | list of live position intervals `[x_first, x_last]` in flow order |
| MXM plane | plane | lock intervals `[first IW sample, MATVEC sample]`; tandem rule for F16 |
| memory words | (slice, bank) | bump pointer |

A flight is **live** from the position where it is driven to the position of its
last sampler, inclusive. Beyond that it is a dead tail that others may
overwrite. Two flights conflict if they share a (dir, stream, diagonal) and
their live intervals overlap.

Scheduling loop: repeatedly take, among chains whose predecessors are all
scheduled, the one with the greatest height (ties: lowest head node id). For it:
1. If it starts with a `MATVEC`: schedule the weight install first — Reads timed so rows arrive at the plane, grouped into `IW` instructions of at most `iw_max_streams` streams, at the earliest cycles ≥ the plane's last lock end at which all cells and ports are free.
2. Search anchors `t0 = lower bound, lower bound + 1, …`. For each `t0` try, in this fixed order, to reserve everything the chain needs:
   - **rung 1, another stream**: for each flight, the lowest-numbered correctly aligned stream group whose cells are free over the live interval;
   - **rung 2, another unit or slice**: for each VXM operation the lowest-numbered ALU whose queue slot is free; for each parked plane the nearest slice in the direction of flow whose write port, bank and queue slot are free at the pass cycle;
   - **rung 3, delay**: if any need cannot be met, release this attempt's reservations and try `t0 + 1`.
3. If `t0` exceeds `config.max_schedule_cycles`, raise `CompileError` naming the chain and the resource that failed last (L-K6).

There is no backtracking over earlier chains: every operand of a chain other
than its internal links comes from memory and can be re-read at any later cycle,
so a later anchor is always feasible once earlier reservations have drained.
`Program.report` records, per chain: ideal anchor, actual anchor, and how many
times each rung was used.

Parking direction: from the VXM, toward the hemisphere of the value's first
consumer in node order (West if that consumer is at the VXM or the value is only
an output); from an MXM or SXM, inward. All planes of one value are parked in
one hemisphere.

### 5.7 Emission
For each unit, sort its instructions by issue cycle, merge a MEM slice's Read
and Write of the same cycle into one `Issue`, and fill gaps with `Nop(n)`, split
at `nop_max`. Units with no work get an empty queue. Build `inputs` and
`outputs` layouts.

### 5.8 Determinism rules for the compiler
No `set` iteration, no `hash()`-ordered containers, no randomness, no
wall-clock or environment input. All candidate lists are built in a documented
order (ascending ids). `compile` called twice on equal inputs must return
`Program`s with equal `queues`.

## 6. Milestones

All run on `ChipConfig.toy()` (32 lanes), with weights and inputs from
`np.random.default_rng(seed)` with a fixed seed per model.

| | Model | Shapes | Exercises |
|---|---|---|---|
| M1 | `y = relu(W·x + b)` | x I8[20], W I8[24×20], b I32[24], y I32[24] | one chain: read, install, matvec, add, relu, write |
| M2 | `h = requant(relu(W1·x + b1), s)`; `y = W2·h + b2` | x I8[48], W1 I8[40×48], W2 I8[10×40] | tiling in both dimensions, partial-sum adds, parking, several planes in use |
| M3 | one decoder step, single head, position T−1 of a fixed length T = 8 | d = 16, FFN width 32, vocabulary 32, F16 weights, F32 arithmetic | fp16 tandem MXM, casts, exp/rsqrt, SXM shift, dynamic weight rows |

M1 is also compiled and run on `ChipConfig.paper()` with a 320×320 `W` as a
scale test.

**M3 definition** (all vectors length d unless noted; `c16(v)` = cast F32→F16):

```
inputs:  x F32[16]; Kc F16[8×16] (cached keys, row 7 zero); V0..V6 F16[16] (cached values)
consts:  Wq, Wk, Wv, Wo F16[16×16]; W1 F16[32×16]; W2 F16[16×32]; Wu F16[32×16];
         b1 F32[32]; b2 F32[16]; SUM0 F16[1×16] (ones → lane 0); ONES F16[16×16] (ones → every lane);
         scale F32[16] (1/sqrt(d)); mask F32[16] (0 for lanes < 8, −1e4 otherwise)
x16 = c16(x)
q = Wq·x16;  k = Wk·x16;  v = Wv·x16
s_cache = Kc · c16(q)                       # scores against cached keys, lanes 0..6
s_self  = shift( SUM0 · c16(q * k), 7 )     # q·k summed into lane 0, moved to lane 7 by the SXM
e   = exp( (s_cache + s_self) * scale + mask )
S   = ONES · c16(e)                         # sum of e broadcast to every lane
r   = rsqrt(S);  a = e * (r * r)            # softmax weights (1/S via rsqrt²)
o   = matvec_cols([V0..V6, c16(v)], c16(a)) # attention output
h   = x + Wo · c16(o)
f   = W2 · c16( relu( W1 · c16(h) + b1 ) ) + b2
y   = h + f
logits = Wu · c16(y)                        # two output tiles
outputs: logits F32[32], k F32[16], v F32[16]
```

Simplifications, stated in the README: no layer norm, one head, no argmax, the
embedding lookup is done by the host, and the host (not the chip) appends
`k`, `v` to the cache for the next step. `W2` has 32 inputs and needs two input
tiles (`tile_len = 16`).

## 7. Validation (`tsp/validate.py`)

`validate(program, trace, config)` uses only the program's queues and the trace.
It does not import the compiler or the simulator. It returns a `Report` with one
entry per check: name, pass/fail, counts, and up to 10 offending items.

| Check | Method |
|---|---|
| **A. exact arrival** | every `sample` and `matvec_row` event has `tag == expect`, and `tag` is not empty |
| **B. stream replay** | independently of the simulator's stream code: group `drive` events by (dir, stream, diagonal); for each `sample`, the tag it should see is that of the drive on its diagonal with the greatest position not past the sampler; compare with `expect`. Also: no two drives on the same cell and cycle. This proves no live value was overwritten and no two values shared a lane position in a cycle |
| **C. units** | recompute every entry's issue cycle from the queues; per queue at most its issue width per cycle; per MEM slice per sample cycle at most one read and one write, on different banks; each MXM plane's rows are not re-installed between an `IW` and the `MATVEC` that expects them; F16 tandem rule |
| **D. program/trace agreement** | the multiset of `issue` events equals the queue contents with recomputed cycles |
| **E. occupancy replay** | rebuild per-cycle occupancy from `drive` events and the shift rule; it must equal `trace.occupancy` |

Numerical checks and determinism checks live in the tests (section 9), because
they need the reference and two runs.

## 8. Visualisation (`tsp/viz`)

`render_timeline(trace, config, title)` returns one self-contained HTML file: no
network requests, the trace embedded as JSON in a `<script type="application/json" id="trace">`
element, rendering done by inline JavaScript from that JSON only.

- **Gantt view.** Time (cycles) on the horizontal axis. One row per unit queue, grouped by slice in West→East order: a block at each `issue` cycle, labelled with the opcode, tooltip = instruction text, sample and visible cycles. One row per stream lane that is ever used (`E0..E31`, `W0..W31`): for each drive, a bar from its visible cycle to the cycle of its last sample (live), continued in a lighter shade to where it is overwritten or leaves the chip (dead tail). Colour identifies the value (tag without the plane suffix).
- **Chip view.** A cycle slider (and step buttons). For the selected cycle: the row of slices, and a grid of stream × position cells filled from `trace.occupancy[cycle]`, so a value can be watched moving one position per cycle.
- Hovering a value highlights the same value in both views. Rows with no activity are collapsed by default, with a toggle.
- Light and dark colour schemes; usable at 1280 px width; horizontal scrolling inside the Gantt only.

Testable properties: the embedded JSON parses and equals `trace.to_json()`; the
number of issue blocks equals the number of `issue` events; the page makes no
external requests; a headless browser loads it without console errors.

## 9. Test strategy

| Level | Owner | What |
|---|---|---|
| Unit, hardware | HW | each fault of 2.5 has a test that triggers it; stream shift, overwrite, fall-off; MEM port rules; each VXM/SXM op against NumPy; MXM I8 and F16 against NumPy; d_skew ≠ 0; hand-written program for `relu(Wx+b)` with hand-computed cycles |
| Unit, compiler | COMP | tiling shapes; placement rules; chain formation on small graphs; reservation-table overlap logic; emission (Nop splitting); compile determinism; `CompileError` on over-capacity |
| Unit, checking | CHECK | reference against hand-computed cases; validator passes a hand-built good trace and **fails** hand-built bad ones (wrong tag, clobbered flight, double-booked port) — one negative test per check A–E |
| Unit, viz | VIZ | properties listed in section 8, on a hand-built trace |
| End to end | lead | for M1, M2, M3 (toy) and M1 (paper): outputs equal the reference — integers exactly, floats within `rtol = 1e-6, atol = 1e-6`, and the maximum difference is reported; `validate` passes all checks; two compiles give equal queues; two runs give equal `Trace.digest()` and `n_cycles`; different input values give identical `issue` events (timing is data-independent); a run with perturbed latencies (`with_timing`) still validates and matches the reference |
| Ledger | CHECK | every `L-…` id in `tsp/config.py` exists in the dossier ledger; no numeric literal other than 0, 1, 2 appears in `tsp/hw` or `tsp/compiler` outside comments, strings and array indexing, except through `config` or `DType` |

Tests run with `pytest` from the project root. The only dependencies are
Python ≥ 3.11, NumPy and pytest.

## 10. Integration and deliverables

`python run_milestones.py` compiles M1–M3, runs each twice, validates, compares
with the reference, prints cycle counts (and the equivalent time at
`clock_hz`, labelled as a conversion), and writes `out/m1_timeline.html`,
`out/m2_timeline.html`, `out/m3_timeline.html`, plus `out/*.program.txt`
(the per-queue listings) and `out/*.trace.json`.

Build order: the lead writes the section 3 files and their tests; then the four
agents work in parallel. HW, VIZ and CHECK need only the contracts. COMP needs
only the contracts to build, and is given the hardware model for end-to-end
tests as soon as it lands. The lead integrates and owns every cross-module fix.
