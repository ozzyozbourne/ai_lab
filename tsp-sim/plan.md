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
`config.timing`, a dict `key → OpTiming(d_skew, d_func)` (L-T2..L-T9).

`WRITE` and `IW` drive nothing. Their `d_func` is the delay until the stored
word or row can be used: it is seen by a Read or MATVEC whose **sample** cycle is
`≥ t_s + d_func` (L-T4, L-T7). An earlier or same-cycle Read or MATVEC sees the
previous content.

### 2.4 Data types on streams

| dtype | bytes | streams | alignment of base stream |
|---|---|---|---|
| `I8` | 1 | 1 | any |
| `F16` | 2 | 2 | even (L-G7, L-G8) |
| `I32`, `F32` | 4 | 4 | multiple of 4 (L-G6, L-G8) |

A vector of `lanes` elements with `k` bytes each is carried as `k` **byte
planes**: plane `j` (little-endian byte `j` of every element) travels on stream
`base + j`. Plane `j` of value `v` has tag `f"{v}#{j}"`. The width of an `SRef` is
`len(tags)`.

**Padding lanes.** A stored or computed vector has `n ≤ tile_len ≤ lanes`
meaningful elements in lanes `0..n−1`. Lanes `≥ n` are *don't-care*: leaves are
zero there, computed values may hold anything (for example `exp(0) = 1`, or
`inf`). The machine keeps the invariant that lanes `< n` of any result never
depend on lanes `≥ n` of an operand: VXM operations are lane-wise, `MATVEC` reads
only `a[0..k−1]`, and graph-level `shift` only moves data toward higher lanes.
Hosts read back only lanes `< n`. All floating-point kernels canonicalise NaN and
suppress NumPy warnings (`tsp/numerics.py`).

### 2.5 Faults

The simulator raises `SimFault` when any of the following happens. The exception
carries the cycle, the unit, a message and the partial `Trace` up to that cycle.
1. an instruction samples an empty cell;
2. two instructions drive the same cell with the same visible cycle;
3. a MEM slice gets more than one Read or more than one Write with the same sample cycle, or a Read and a Write on the same bank with the same sample cycle (L-M4, L-M5);
4. a Read addresses a word that was never written or initialised;
5. a `MATVEC` uses a weight row that is not installed, or whose dtype differs, or `len(expect_rows) != k`;
6. an fp16 MXM rule is broken (2.8);
7. a queue entry holds more instructions than its unit allows (L-I2), or an instruction is issued on the wrong kind of unit;
8. an operand or result reference breaks alignment, range, width or direction rules (L-G8, L-X6);
9. a queue contains `Nop(n)` with `n` outside `1..nop_max`.

A tag mismatch is **not** a fault. The hardware cannot know what a value means;
tag mismatches are recorded in the trace and caught by the validator (section 7).

### 2.6 MEM (L-M1..L-M6)

Each slice has 2 banks × `words_per_bank` addresses; one address holds one
plane (`lanes` bytes) and its tag.

- `Read(bank, addr, out)` — at `t_s` reads the word (2.3); drives stream `out` at `t_v = t_s + d_func(READ)`. The driven cell carries the **stored** tag. `out.tags[0]` is the tag the compiler expects; the `mem_read` event records both (`tag` = stored, `expect` = `out.tags[0]`).
- `Write(bank, addr, src)` — at `t_s` samples stream `src` at the slice position and stores the bytes and the tag actually seen. `src.tags[0]` is the expected tag, recorded in the `sample` event.

A MEM queue entry may hold one Read and one Write (L-I2).

### 2.7 VXM (L-V1..L-V7)

Sixteen ALUs at one position. Each is stateless and accepts one instruction per
cycle. `VOp(op, a, b, out, imm)`:

All arithmetic is defined by `tsp/numerics.py` (`numerics.vop`), which the
simulator and the bit-exact reference both call. The table describes it.

| op | operand dtype(s) | result dtype | semantics |
|---|---|---|---|
| `ADD`, `SUB`, `MUL` | I32, I32 | I32 | wrap modulo 2³² (L-V7) |
| `ADD`, `SUB`, `MUL` | F32, F32 | F32 | `np.float32` arithmetic |
| `RELU` | I32 or F32 | same | `np.maximum(a, 0)` |
| `REQUANT` | I32 | I8 | `np.clip(a >> imm, −128, 127)` (L-V5) |
| `CAST` | I8→I32, F32→F16, F16→F32 | — | sign-extend; `astype(np.float16)`; exact (L-V6) |
| `EXP`, `TANH` | F32 | F32 | `math.exp` / `math.tanh` per element in float64, rounded to F32 |
| `RSQRT` | F32 | F32 | `1 / sqrt(a)` in float64, rounded to F32; 0 → inf, negative → NaN |

Operands may come from either direction (L-G15); the result goes to either
direction (L-G14). An ALU's result is visible at the VXM position at `t_v`, so
another ALU can sample it there in that same cycle (L-V3). Both operand slots of
one instruction may name the same stream group (`r * r`). A produced value's
cells carry `out.tags`.

### 2.8 MXM (L-X1..L-X8)

Two planes per hemisphere. A plane has a weight buffer of `lanes` rows; a row is
one vector over lanes plus its dtype and tag.

- `IW(dtype, rows)` — `rows` is a tuple of `(row_index, SRef)`, each `SRef` as wide as `dtype`. At `t_s` samples every listed stream group and stores it as that row, with the tag seen on its first stream. At most `iw_max_streams` streams in total (L-X3). Usable from `t_s + d_func(IW)` (2.3, L-T7). There is no separate staging buffer (L-X5).
- `MATVEC(dtype, k, a, out, expect_rows)` — at `t_s` samples the activation `a`; computes `out[l] = Σ_{r<k} a[r] · row_r[l]` for every lane `l`; drives the result at `t_v`.
  - `I8`: `a` is one stream, `k ≤ lanes`; exact integer result as I32.
  - `F16`: `a` is a stream pair, `k ≤ lanes/2`, elements `a[0..k−1]` (L-X8); every product is exact in float64, each lane's sum is the correctly rounded sum (`math.fsum`, so order does not matter), rounded once to F32 (L-X4). Defined by `numerics.matvec`.
  - `len(expect_rows) == k`; `expect_rows[r]` is the full tag of the row's first plane, e.g. `"W.c3#0"`.
- `a` and every `IW` row must be on outward-flowing streams and `out` on an inward-flowing group (L-X6): West MXM reads `W`, writes `E`; East MXM reads `E`, writes `W`.
- **fp16 uses both planes of a hemisphere as one unit** (L-X9). F16 instructions are legal only on plane `.0`. While plane `.0` holds any F16 row, any instruction issued to plane `.1` of that hemisphere is a fault; an F16 `IW` on plane `.0` clears plane `.1`; an I8 `IW` on plane `.0` clears its F16 rows. All weight-buffer changes, including these clears, take effect at `t_s + d_func(IW)`; whether plane `.1` may issue is judged against the buffer state at its issue cycle.

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

These six files (the five below plus `tsp/numerics.py`, described in 2.7 and
2.8) are the only coupling between build agents. The files themselves, not the
excerpts below, are authoritative. Agents import
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
    max_schedule_cycles: int        # compiler gives up beyond this (L-K7)

    lanes, n_positions, vxm_pos                 # derived properties
    def pos(self, unit: str) -> int             # position of any unit or slice name
    def slice_names(self) -> list[str]          # West to East; index == position
    def unit_names(self) -> list[str]           # every queue, West to East, fixed order
    def kind(self, unit: str) -> str            # "MEM" | "VXM" | "MXM" | "SXM"
    def hemi(self, unit: str) -> str | None     # "W" | "E" | None (VXM)
    def issue_width(self, unit: str) -> int     # L-I2
    def fingerprint(self) -> str                # hash of all parameters including timing
    def toy() / paper()                         # presets
    def with_timing(self, **overrides)          # copy with changed latencies (tests)
```

`VARITH` covers ADD SUB MUL RELU REQUANT CAST; `VTRANS` covers EXP RSQRT TANH;
`SXM` covers Shift Permute Distribute. Every literal in this file carries its
ledger ID in a comment; issue widths (L-I2) and the SXM unit list (L-S2) are
also defined here. `planes_per_mxm` is per hemisphere. No other source file may
contain a machine parameter, except `DType.nbytes` in `tsp/isa.py` (L-G6, L-G7).
A `ChipConfig` is not hashable (it holds a mapping); do not use it as a dict key.

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
| `matvec_cols(cols, x)` | `Σ_{r < len(cols)} x[r] · cols[r]`; `len(cols) ≤ len(x)`, later elements of `x` are ignored; each `cols[r]` is a vector Value (leaf or computed) of equal length | as matvec |
| `add`, `sub`, `mul` | elementwise, equal length | I32 or F32 |
| `relu`, `exp`, `rsqrt`, `tanh` | elementwise | as 2.7 |
| `requant(a, shift)`, `cast(a, dtype)` | as 2.7 | as 2.7 |
| `shift(a, n)` | `out[i] = a[i − n]` if `i ≥ n` else 0; `n ≥ 0` only | any |
| `output(name, v)` | marks a result to be written to memory | — |

Nodes are stored in creation order with integer ids; that order is the
tie-break everywhere. `Graph` only records structure and validates dtypes and
shapes. It does not evaluate anything.

Read API used by the compiler and the reference: `graph.nodes` (list of
`Node(id, kind, name, dtype, n, inputs, matrix, imm)`; kind strings are the
builder names, leaves are `"vector"`; `inputs` are node ids, for `matvec_cols`
`(x, col_0, …)`; `imm` holds the requant shift or the shift distance; the cast
target is `node.dtype`), `graph.matrices` (name → `Matrix(name, dtype, m, n)`),
`graph.constants` (leaf or matrix name → array), `graph.outputs` (name → node
id), `graph.input_names()`, `graph.consumers(id)`. Node names are unique, never
contain `#`, and are the tag prefixes.

**Multi-tile matvec semantics.** For `matvec(W, x)` with more than `tile_len`
columns, the value is defined as the left-to-right F32 (or I32) sum of the
per-input-tile products, each rounded to F32 on its own. This is what the chip
computes, and the bit-exact reference follows it (`tile_len` is an argument of
`reference.evaluate`).

Restrictions (compile errors): a graph may not contain both I8 and F16 matvecs
(L-X9); `shift` operands must fit in one tile; `matvec_cols` needs
`len(cols) ≤ tile_len`.

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

@dataclass(frozen=True)
class MemInit: slice: str; bank: int; addr: int; data: np.ndarray; tag: str   # data: uint8[lanes]

@dataclass
class Program:
    name: str
    config_name: str
    config_fingerprint: str                     # ChipConfig.fingerprint(); run_program refuses a mismatch
    tile_len: int
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
- Tags are unique per stored vector: a vector tile is tagged `f"{name}.t{i}"`, a matrix column `f"{name}.o{out_tile}.c{column}"`, and every tile-level intermediate gets its own unique prefix derived from its node name and tile index. The same value read twice carries the same tag both times; the validator's geometric replay (section 7, check B) covers what tags cannot distinguish.

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
    issue_cycle: int | None = None     # every kind: when the instruction behind the event was issued
    sample_cycle: int | None = None    # issue events: t_s
    visible_cycle: int | None = None   # issue events: t_s + d_func

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

Event meaning: `issue` at `t_i`, **one per instruction** (a MEM entry with a
Read and a Write gives two); `sample` at `t_s`, one per sampled stream;
`drive` at `t_v`, one per driven stream; `mem_read`/`mem_write` at `t_s`
(`mem_read` carries `tag` = stored tag and `expect`);
`iw_row` at `t_s`, one per installed row; `matvec_row` at `t_s`, one per row
used (`tag` = tag in the buffer, `expect` = `expect_rows[r]`).

## 4. Module breakdown and ownership

| Module | Owner | Files (exclusive) | Public interface |
|---|---|---|---|
| Contracts | lead | `tsp/__init__.py`, `tsp/config.py`, `tsp/isa.py`, `tsp/numerics.py`, `tsp/graph.py`, `tsp/program.py`, `tsp/trace.py` | section 3 |
| Hardware model | agent HW | `tsp/hw/**`, `tests/hw/**` | `tsp.hw.Chip(config).run(queues, mem_image) -> (Trace, Memory)`; `tsp.hw.run_program(program, feeds, config) -> RunResult(trace, outputs)`; `SimFault` |
| Compiler | agent COMP | `tsp/compiler/**`, `tests/compiler/**` | `tsp.compiler.compile(graph, config) -> Program`; `CompileError` |
| Visualisation | agent VIZ | `tsp/viz/**`, `tests/viz/**` | `tsp.viz.render_timeline(trace, config, title) -> str`; `write_timeline(path, trace, config, title)` |
| Checking and models | agent CHECK | `tsp/validate.py`, `tsp/reference.py`, `tsp/models/**`, `tests/check/**` | `validate(program, trace, config) -> Report`; `reference.evaluate(graph, feeds, tile_len) -> dict` (bit-exact, uses `tsp/numerics.py`); `reference.evaluate_plain(graph, feeds) -> dict` (independent float64 NumPy, no shared kernels); `models.m1(n_in=20, n_out=24)`, `models.m2()`, `models.m3()` `-> (Graph, feeds)` |
| Integration | lead | `run_milestones.py`, `tests/test_e2e.py`, `README.md`, `out/**` | CLI |

`Memory` exposes `read(slice, bank, addr) -> (np.ndarray uint8[lanes], tag)`.
`RunResult.outputs` comes from `program.read_outputs`. `run_program` raises
`ValueError` if `program.config_fingerprint != config.fingerprint()`.

`Report` is `Report(checks: list[Check])` with `Check(name: str, passed: bool,
checked: int, failures: list[str])`, plus `Report.ok` (all passed) and
`Report.summary()` (text).

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
- Planes of one stored vector go to distinct slices of one hemisphere (L-K4).
- Install rows of one weight tile (matrix columns, and leaf columns of a `matvec_cols`) are spread round-robin over the `min(M, iw_max_streams)` slices nearest the MXM that will use them (L-K5), so that up to `iw_max_streams` streams can be read in one wave.
- Other leaf vectors go to the hemisphere of their first consumer's unit (West if that is the VXM), on slices taken from a per-hemisphere rotating cursor that starts next to the VXM.
- **Co-read rule.** Two planes that one operation reads from memory for the same sample cycle must not be in the same slice: they would be equidistant, need Reads in the same cycle, and a slice has one read port (L-M4, L-M5). So for every operation with two memory-sourced operands, the slices of the two operands must be disjoint. Placement enforces this between leaves; parking (5.6) enforces it for intermediates. A violation that cannot be avoided is an immediate `CompileError`, never a search.
- Addresses are bump-allocated per (slice, bank). Running out is a `CompileError`.

### 5.3 Unit assignment
- I8 `MATVEC`s take planes in the fixed rotation `MXM_W.0, MXM_E.0, MXM_W.1, MXM_E.1`; F16 `MATVEC`s alternate `MXM_W.0, MXM_E.0`. Placement (5.2) uses this assignment, so 5.3 runs before 5.2 in code; they are listed in the order of the brief.
- `SHIFT` goes to the SXM of the hemisphere where its operand is produced or stored (West if the operand is produced at the VXM).
- VXM operations go to the VXM; the ALU index is chosen in 5.6.

### 5.4 Chain formation
A **chain** is a list of tile-level operations executed as one rigid pattern in
which each result flows on a stream directly into the next operation. Rules:
1. A `MATVEC` always starts a chain; its activation is read from memory.
2. Any other operation looks at its computed operands in operand order and joins the chain of the first one whose producer's value has exactly one consumer **node**, is not a graph output, is not used as a `matvec_cols` column, and is the current end of its chain. If none qualifies it starts a new chain. An operation that uses the same value in both operand slots (`r * r`) counts as one consumer and samples the same stream group twice.
3. Every other operand of a chain member is read from memory (a leaf, or a value parked by an earlier chain).
4. A chain ends with Writes that park its final value if that value has any consumer outside the chain or is a graph output. Every value consumed by more than one node, or by a node in another chain, is therefore parked exactly once and read back once per consumer.

Chain **predecessors** of a chain are the chains that park any value it reads:
operands and, for `matvec_cols`, computed columns. Chains are scheduled in an
order that respects this relation.

This is the paper's memory-to-memory pattern (L-K3). Memory is the only place a
value waits (dossier section 5), so delay matching is done by parking.

### 5.5 Ideal timetable
For each chain, compute the offset of every instruction relative to the chain's
anchor `t0`, defined as the **sample cycle of the chain's first operation**, from
`config.timing` and position distances alone. A link between two VXM operations
uses an eastward stream group and has distance 0. Offsets:
- an operation at position `x_c` sampling at `t_s` needs each direct operand produced at `x_p` to be visible there at `t_s − |x_c − x_p|`;
- a Read at slice position `x_m` feeding it must have `t_v = t_s − |x_c − x_m|`, so it is issued at `t_s − |x_c − x_m| − d_func(READ) − d_skew(READ)`; the `k` planes of a value are read from `k` slices at `k` different cycles and merge into one aligned group;
- a parking Write at a slice the result passes samples at `t_v + distance`.

Then compute, ignoring resources, each chain's earliest anchor (ASAP: every
issue cycle ≥ 0; every Read of a parked plane samples at or after that plane's
Write sample cycle + `d_func(WRITE)`; every weight row installed at least
`d_func(IW)` before the MATVEC samples) and each chain's **height** (longest
path in cycles to any output).

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
1. If it starts with a `MATVEC`: schedule the weight install first. Rows are packed greedily, in row order, into waves such that a wave has at most `iw_max_streams` streams and no two planes in the same slice (same slice ⇒ same Read cycle ⇒ port conflict). Each wave is one `IW`; its Reads are timed so all its planes reach the plane position in the IW's sample cycle. Waves are scheduled one after another, each at the earliest sample cycle that is after the plane's last lock end, after every computed row's Write (2.3), and at which all cells, ports and queue slots are free. The search for each wave is bounded by `max_schedule_cycles`.
2. Search anchors `t0 = lower bound, lower bound + 1, …`. For each `t0`, reserve what the chain needs in this fixed order; the three kinds of alternative are the rungs of the conflict ladder:
   - **units (rung: another unit)**: for each VXM operation in chain order, the lowest-numbered ALU whose queue slot is free at its issue cycle;
   - **parking slices (rung: another slice)**: for each plane of the final value, in plane order, the nearest slice in the direction of flow, beyond the slices already taken by lower planes, that is not excluded by the co-read rule (5.2: slices holding planes of any value that shares a memory-reading consumer with this one) and whose write port, bank-1 address and queue slot are free at the pass cycle. This fixes every flight's live interval;
   - **streams (rung: another stream)**: for each flight, in the order operand reads (operation order, operand order), links (chain order), final value: the lowest-numbered correctly aligned stream group whose cells are free over the live interval, together with the Read ports and queue slots of operand reads;
   - **delay (last rung)**: if any need cannot be met, release this attempt's reservations and try `t0 + 1`.
3. If `t0` exceeds `config.max_schedule_cycles`, raise `CompileError` naming the chain and the resource that failed last (L-K6, L-K7).

There is no backtracking over earlier chains: every operand of a chain other
than its internal links comes from memory and can be re-read at any later cycle.
A later anchor is feasible once earlier reservations have drained, **provided**
the chain has no conflict with itself. Self-conflicts are pairs of the chain's
own memory accesses that land in one slice in one cycle at every anchor: two
equidistant Reads (the co-read rule, 5.2), two Reads for consumers at different
positions whose offsets happen to coincide, or a parking Write and a Read on the
same bank. (The last two were found during the build; the first draft of this
plan listed only the first.) Placement and parking avoid all three by tracking
each chain's (slice, read offset) marks, wave packing (step 1) avoids them for
installs, and before searching the compiler tries each chain once on empty
tables and raises `CompileError` if it conflicts with itself.
`Program.report` records, per chain: ideal anchor, actual anchor, and the number
of rejected candidates of each kind (ALUs, slices, stream groups, anchors).

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

All run on `ChipConfig.toy()` (32 lanes), with weights and inputs from a
fixed-seed generator (described below).

| | Model | Shapes | Exercises |
|---|---|---|---|
| M1 | `y = relu(W·x + b)` | x I8[20], W I8[24×20], b I32[24], y I32[24] | one chain: read, install, matvec, add, relu, write |
| M2 | `h = requant(relu(W1·x + b1), 6)`; `y = W2·h + b2` | x I8[48], W1 I8[40×48], b1 I32[40], h I8[40], W2 I8[10×40], b2 I32[10], y I32[10] | tiling in both dimensions, partial-sum adds, parking, several planes in use |
| M3 | one decoder step, single head, position T−1 of a fixed length T = 8 | d = 16, FFN width 32, vocabulary 32, F16 weights, F32 arithmetic | fp16 tandem MXM, casts, exp/rsqrt, SXM shift, dynamic weight rows |

M1 is also compiled and run on `ChipConfig.paper()` with `models.m1(n_in=320,
n_out=320)` (x I8[320], W I8[320×320], b I32[320]) as a scale test.

Data comes from a small integer generator written in `tsp/models` (a 64-bit
LCG), not from NumPy's distributions, so it is identical on every NumPy version.
Ranges: I8 inputs in −128..127; I8 weights in −16..15; I32 biases in
−1000..1000; F16 weights uniform multiples of 1/256 in [−0.25, 0.25]; F32
inputs multiples of 1/64 in [−1, 1]. With these ranges M3's scores stay within
±16, so `exp` stays far inside F16 range.

**M3 definition** (all vectors length d unless noted; `c16(v)` = cast F32→F16):

```
inputs:  x F32[16]; Kc F16[16×16] (cached keys in rows 0..6, rows 7..15 zero); V0..V6 F16[16] (cached values)
consts:  Wq, Wk, Wv, Wo F16[16×16]; W1 F16[32×16]; W2 F16[16×32]; Wu F16[32×16];
         b1 F32[32]; b2 F32[16]; SUM0 F16[16×16] (row 0 ones, other rows zero); ONES F16[16×16] (all ones);
         scale F32[16] (1/sqrt(d)); mask F32[16] (0 for lanes < 8, −1e4 otherwise)
x16 = c16(x)
q = Wq·x16;  k = Wk·x16;  v = Wv·x16
s_cache = Kc · c16(q)                       # scores against cached keys, lanes 0..6
s_self  = shift( SUM0 · c16(q * k), 7 )     # q·k summed into lane 0, moved to lane 7 by the SXM
e   = exp( (s_cache + s_self) * scale + mask )
S   = ONES · c16(e)                         # sum of e broadcast to every lane
r   = rsqrt(S);  a = e * (r * r)            # softmax weights (1/S via rsqrt²)
o   = matvec_cols([V0..V6, c16(v)], c16(a)) # attention output: 8 columns, uses a[0..7]
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
| **A. exact arrival** | every `sample`, `mem_read` and `matvec_row` event has `tag == expect`, and `tag` is not empty |
| **B. stream replay** | independently of the simulator's stream code: group `drive` events by (dir, stream, diagonal); for each `sample`, the tag it should see is that of the nearest drive upstream of or at the sampler on its diagonal (eastward: greatest position ≤ the sampler's; westward: smallest position ≥ the sampler's); compare with `expect`. Also: no two drives on the same cell and cycle. This proves no live value was overwritten and no two values shared a lane position in a cycle |
| **C. units** | recompute every entry's issue cycle from the queues; per queue at most its issue width per cycle; per MEM slice per sample cycle at most one read and one write, on different banks; for each `MATVEC` sampling at `t`, each row it uses was last installed by an `iw_row` event at a cycle `≤ t − d_func(IW)` whose tag equals `expect_rows[r]`; F16 unit rule (L-X9) |
| **D. program/trace agreement** | the multiset of `issue` events equals the queue contents with recomputed cycles |
| **E. occupancy replay** | rebuild per-cycle occupancy from `drive` events and the shift rule; it must equal `trace.occupancy` |

Numerical checks and determinism checks live in the tests (section 9), because
they need the reference and two runs.

## 8. Visualisation (`tsp/viz`)

`render_timeline(trace, config, title)` returns one self-contained HTML file: no
network requests, the trace embedded as JSON in a `<script type="application/json" id="trace">`
element, rendering done by inline JavaScript from that JSON only.

- **Gantt view.** Time (cycles) on the horizontal axis. One row per unit queue, grouped by slice in West→East order: a block at each `issue` cycle, labelled with the opcode, tooltip = instruction text, sample and visible cycles. One row per stream lane that is ever used (`E0..E31`, `W0..W31`): for each drive, a bar from its visible cycle to the cycle of its last sample (live), continued in a lighter shade to where it is overwritten or leaves the chip (dead tail). Flights that overlap in time on one lane (at different positions) are stacked in sub-rows so no two bars overlap. Colour identifies the value (tag without the plane suffix).
- **Chip view.** A cycle slider (and step buttons). For the selected cycle: the row of slices, and a grid of stream × position cells filled from `trace.occupancy[cycle]`, so a value can be watched moving one position per cycle.
- Hovering a value highlights the same value in both views. Rows with no activity are collapsed by default, with a toggle.
- Light and dark colour schemes; usable at 1280 px width; horizontal scrolling inside the Gantt only.

Testable properties, checked in pytest without a browser: the embedded JSON
parses and equals `trace.to_json()`; the HTML contains no `http://`, `https://`
or `//` resource reference; a Python-side function `viz.summarise(trace)`
(blocks per unit row, flights per lane) agrees with counts computed directly
from the events. Checked in Phase 5 with the headless Chromium already
installed in the build environment (not a project dependency): the page loads
with no console errors and the number of rendered issue blocks equals the number
of `issue` events.

## 9. Test strategy

| Level | Owner | What |
|---|---|---|
| Unit, hardware | HW | each fault of 2.5 has a test that triggers it; stream shift, overwrite, fall-off; MEM port rules; each VXM/SXM op against NumPy; MXM I8 and F16 against NumPy; d_skew ≠ 0; hand-written program for `relu(Wx+b)` with hand-computed cycles |
| Unit, compiler | COMP | tiling shapes; placement rules; chain formation on small graphs; reservation-table overlap logic; emission (Nop splitting); compile determinism; `CompileError` on over-capacity |
| Unit, checking | CHECK | reference against hand-computed cases; validator passes a hand-built good trace and **fails** hand-built bad ones (wrong tag, clobbered flight, double-booked port) — one negative test per check A–E |
| Unit, viz | VIZ | properties listed in section 8, on a hand-built trace |
| End to end | lead | for M1, M2, M3 (toy) and M1 (paper): outputs equal `reference.evaluate` **bit for bit** (integers and floats); outputs agree with the independent `reference.evaluate_plain` exactly for the integer models and within `rtol = 2e-2, atol = 2e-2` for M3 (the gap is the F16 rounding the plain reference does not model; the maximum difference is reported); `validate` passes all checks; a run with perturbed latencies (`with_timing`, including nonzero `d_skew`) still validates and matches the reference |
| Determinism | lead | compile and run each milestone in two **separate Python processes** with different `PYTHONHASHSEED` values: the program listings, `Trace.digest()` and `n_cycles` must be equal; a graph with the same shapes but different constant values compiles to equal queues, showing the schedule is data-independent; golden trace digests for M1 and M2 (integer-only) are committed and compared. M3's digest is compared across processes only, because `exp` goes through the C library and may differ in the last bit between platforms (2.7) |
| Ledger | CHECK | every `L-…` id in `tsp/config.py`, `tsp/isa.py` and `tsp/numerics.py` exists in the dossier ledger; every line of `tsp/config.py` holding a numeric literal carries an `L-…` id or a `not a machine parameter:` comment (AST-based); in `tsp/hw` and `tsp/compiler`, any numeric literal other than −1, 0, 1, 2 must be on a line with an `L-…` id or a `not a machine parameter:` comment |

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
