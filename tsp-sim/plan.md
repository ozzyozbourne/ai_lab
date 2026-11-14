# Plan: an educational cycle-level TSP simulator and toy scheduling compiler

This plan is written against `research/dossier.md`. Parameter IDs such as T6 or B12
refer to the ASSUMPTIONS LEDGER in section 7 of the dossier. The ledger is the only
place where a number is justified; this plan and the code refer to it by ID.

## 1. Scope

**In scope**

- A single TSP chip: MEM, VXM, MXM and SXM slices in the sourced west-to-east order (G6), east and west stream registers moving one position per cycle (T1), and one instruction queue per unit (G14).
- An instruction set using the sourced instruction names, with NOP, Repeat, Sync and Notify in the queues.
- A toy compiler from a fixed-shape compute graph to per-unit programs.
- Three milestones: (M1) `y = relu(W.x + b)`, (M2) a 2-layer MLP, (M3) one simplified transformer decode step with a fixed sequence length.
- A cycle trace, a trace validator and an HTML timeline per milestone.

**Out of scope** (B15, B17): multi-chip and C2C links, ECC, instruction fetch, Gather/Scatter, Config, power, MEM banks, convolution, and any dynamic shape.

**Two chip configurations**

- `ChipConfig.toy()`: the default. 16 lanes (G1, G2), 8 MEM slices per hemisphere (G7), 1 MXM plane per hemisphere (G10). All milestones run on it.
- `ChipConfig.isca2020()`: the sourced geometry (20 tiles, 320 lanes, 44 MEM slices per hemisphere, 2 MXM planes per hemisphere), with the same assumed latencies. One test runs M1 with a 320x320 layer on it to show the code is parametric. The compiler uses only plane 0 of each hemisphere.

## 2. Machine model

### 2.1 Positions and units

Positions are numbered west to east from 0. With k MEM slices per hemisphere there are P = 2k + 5 positions (G8):

| Position | Unit names at that position |
|---|---|
| 0 | `MXM_W0` (and `MXM_W1` ... if more planes) |
| 1 | `SXM_W` |
| 2 ... k+1 | `MEM_W{k-1}` ... `MEM_W0` |
| k+2 | `VXM_A0` ... `VXM_A15` (the 16 ALUs, G12) |
| k+3 ... 2k+2 | `MEM_E0` ... `MEM_E{k-1}` |
| 2k+3 | `SXM_E` |
| 2k+4 | `MXM_E0` ... |

A **unit** is one thing with one instruction queue (G14). Several units can share a position. `ChipConfig.units()` returns all unit names in the order of the table (west to east, then by index). This order is the canonical unit order everywhere.

### 2.2 Stream registers

- `SR[dir][s][x]` for `dir` in `E`, `W`; stream `s` in `0..31` (G3); position `x` in `0..P-1`.
- A register is empty or holds a `StreamVal`: a `numpy.uint8` vector of `lanes` bytes (G4), a value id `vid` and a debug tag (B16).
- A value of a wider type occupies consecutive streams starting at a base that is a multiple of its width (G5). Byte `j` of each element travels on stream `base + j` (little-endian). Each byte-stream is called a **plane**.

Data types and widths in streams: `int8` 1, `fp16` 2, `int32` 4, `fp32` 4.

### 2.3 The cycle

The simulator keeps one integer `cycle`, starting at 0. Each cycle runs these steps in this fixed order:

1. **Shift.** Every eastward value moves from `x` to `x+1`, every westward value from `x` to `x-1`. Values that leave the chip are dropped (B1).
2. **Emit.** Every result due this cycle is written into `SR[dir][s][x_unit]` at the producing unit's own position, replacing whatever shifted in (T3). Two results due in the same register on the same cycle is a `StreamCollisionError`.
3. **Dispatch.** Units are visited in canonical order. Each unit's queue yields at most one instruction (T16). The unit samples its stream operands from the registers at its own position as they stand after step 2 (T4, B2) and samples any internal state (memory word, installed weights). It computes the result and files it as due at `cycle + d_func`.
4. **Commit.** A MEM write dispatched at cycle `t` takes effect at the end of cycle `t + T7 - 1`, and a weight install at the end of cycle `t + T11 - 1`. With the ledger values (both 1) this is the end of the dispatch cycle, so the new contents are visible to instructions dispatched at `t + 1` or later.

Consequences that the compiler relies on:

- **Arrival rule.** A result dispatched at cycle `t` on a unit at position `xp` with latency `d` is readable at position `xc`, in the direction of emission, at exactly cycle `t + d + |xc - xp|` (T2, T3), provided `xc` lies in that direction from `xp` or equals it.
- A consumer at the same position reads the value on cycle `t + d`. This is how VXM ALUs chain (B12).
- Reading never removes a value; it keeps flowing (B2).
- Every unit is fully pipelined: a queue may dispatch on consecutive cycles whatever the latency (B18). One unit may therefore emit two results on the same cycle (for example a `mul` dispatched at `c` and an `add` at `c + 1`); this is legal as long as they go to different stream registers.
- All dispatches in a cycle see the same register contents, so the visiting order in step 3 never changes a result. It only fixes the order of trace records.

Sampling an empty register is an `EmptyOperandError`. If the instruction carries an expected tag and the sampled value's tag differs, it is an `OperandTagError`. These errors are what turn a timing mistake into a failure. The compiler always sets expected tags, and every tag it creates is unique to one emission (section 3.2).

**Zero-padding invariant (B19).** Every result-producing instruction except `Read` carries a length `n`. Result lanes at or above `n` are zero, and the operation is computed only on lanes below `n`. Constants and inputs are zero-padded when loaded (B22). So every value on the chip is zero at and above its length, and no operation ever sees junk, infinities or NaN from padding.

### 2.4 Tile stagger

The simulator runs in the logical time of tile 0 (T5). The reported wall-clock length of a run is `n_cycles + tiles - 1`. On the toy chip `tiles = 1` and the two are equal. The simulator does not model per-tile stagger of SXM operations that move data between superlanes; this is listed in the dossier's Not found section.

### 2.5 Units

| Unit | Instruction | Behaviour | d_func |
|---|---|---|---|
| MEM | `Read(addr, out)` | emit the word at `addr` on one stream `out` | T6 |
| MEM | `Write(addr, src)` | store the value on stream `src` at `addr` (commit step) | T7 |
| VXM ALU | `Vxm(op, dtype, a, b, out, n, ...)` | point-wise `op` on one or two operands of `dtype`, on lanes below `n` | T8, T9, T10 |
| MXM plane | `Iw(dtype, entries)` | install weight rows sampled from streams; at most 16 streams per instruction (B8) | T11 |
| MXM plane | `Abc(dtype, src, out, n_rows)` | `out[r] = sum_c W[r][c] * src[c]` for `r < n_rows`, zero elsewhere (B19) | T12 |
| SXM | `Distribute(width, src, out, map, n)` | within each superlane, lane `i` receives lane `map[i]` of that superlane (or zero if `map[i]` is -1) | T13 |
| SXM | `Permute(width, src, out, map, n)` | bijective remap of all lanes: `out[i] = in[map[i]]` | T13 |
| SXM | `Shift(width, src, out, shift, n)` | `out[i] = in[i - shift]`, zero fill | T13 |

Details:

- **MEM.** One address holds one vector of `lanes` bytes (B5). One instruction per slice per cycle (B4). Reading an address that was never written is an error.
- **VXM operations** (B11). Operands are `int32` or `fp32` only, matching the sourced 32-bit ALUs.
  - `add`, `sub`, `mul`, `neg`, `relu` keep the data type. Integer versions wrap around modulo 2^32.
  - `tanh`, `exp`, `rsqrt` are `fp32` only: `numpy.tanh`, `numpy.exp` and `float32(1) / numpy.sqrt(x)`, all evaluated on `float32` arrays.
  - `cast` converts `fp32 -> fp16` (NumPy `astype`, round to nearest even), `fp16 -> fp32` and `int32 -> fp32`. For `fp16 -> fp32` the operand occupies 2 streams; this is the only VXM operation with a non-32-bit operand.
  - `requant` maps `int32` to `int8`: arithmetic shift right by the immediate, then saturation to -128..127 (B20).
  - Floating-point `add`, `sub`, `mul` are single NumPy `float32` operations, which are IEEE-754 correctly rounded and therefore identical on every platform. `tanh` and `exp` depend on the NumPy build; results are reproducible on one installation, which is what the determinism checks need.
- **MXM.** Each plane holds `lanes x lanes` weights (G11), all zero at reset.
  - `int8`: weights and activation are widened to 64-bit integers, multiplied and summed, and the sum is wrapped to `int32` (B6).
  - `fp16`: weights and activation are converted to `float64`; the sum is accumulated in ascending lane order (`acc += W[:, c] * x[c]` for `c = 0, 1, ...`), and rounded once to `float32` (B6, B7). [TSP20] Sec. III-D says the sum is produced "with only a single rounding step". Fixing the order makes the result independent of any BLAS library. `Iw` and `Abc` on one plane are never dispatched on the same cycle because the plane has one queue. Operands are read from outward-flowing streams and the result is written inward (B10): for `MXM_W` operands flow west and the result flows east.
- **SXM.** `width` is the number of streams the value occupies; the same lane map is applied to every plane.

### 2.6 Instruction queues

One queue per unit. Queue instructions (T14, T15, T18, B14):

- `Sync`: park until the barrier is released.
- `Notify`: start the barrier. It is released `T15` cycles after the Notify is dispatched.
- `Nop(n)`: occupy `n` cycles, `1 <= n <= 65535`.
- `Repeat(n, d)`: after a data instruction dispatched at cycle `c`, dispatch it again at `c + d, c + 2d, ..., c + n*d`, with `n >= 1` and `d >= 1`.

**Queue timing.** A queue is consumed strictly in order and each element occupies a number of consecutive cycles:

| Element | Cycles occupied | Dispatches |
|---|---|---|
| `Sync` or `Notify` (first element only) | cycles `0 .. T15 - 1` | none |
| data instruction | 1 | on that cycle |
| `Nop(n)` | `n` | none |
| `Repeat(n, d)` | `n * d` | the previous data instruction, on the last cycle of each block of `d` |

Worked example with `T15 = 35`: `[Sync, Nop(3), Read, Repeat(2, 4), Vxm]` dispatches `Read` at cycles 38, 42 and 46 and `Vxm` at cycle 47. To separate two dispatches at cycles `a < b` the emitter inserts `Nop(b - a - 1)` and nothing if `b = a + 1`. A queue is done when its last element has used its last cycle.

Every program has exactly one queue that starts with `Notify` (always `VXM_A0`, B14); every other queue in the program starts with `Sync`. `Notify` is dispatched at cycle 0, so the instruction after `Sync` or `Notify` is dispatched at cycle `T15` in every queue. **Program time** is `tau = cycle - T15`. The compiler works in program time; the simulator and trace use cycles.

The run ends after the first cycle in which every queue is exhausted and no result is pending (B21). `n_cycles` is the number of cycles executed.

## 3. Interfaces between modules

These are the contracts. The lead writes the files in section 3 marked "lead" before the build starts; build agents import them and do not edit them.

### 3.1 `tsp/params.py` (lead)

- One module-level constant per ledger entry that is a number, each with a `# ledger: ID` comment.
- `ChipConfig.latency` is the only latency table. Its keys are `read`, `write`, `iw`, `abc`, `distribute`, `permute`, `shift`, and one key per VXM operation name (`add`, `sub`, `mul`, `neg`, `relu`, `tanh`, `exp`, `rsqrt`, `cast`, `requant`). `isa.kind_of(instr)` returns the key for an instruction.
- `@dataclass(frozen=True) ChipConfig` with fields `lanes_per_superlane, tiles, streams_per_dir, mem_slices_per_hemi, mem_words, mxm_planes_per_hemi, vxm_alus, iw_max_streams, barrier_cycles, nop_max, clock_hz, max_schedule_cycles, latency`.
- Methods: `lanes`, `n_positions`, `vxm_pos`, `units() -> tuple[str, ...]`, `kind(unit)`, `pos(unit) -> int`, `mem_slices(hemi) -> tuple[str, ...]`, `to_dict()`, `from_dict()`.
- Class methods `toy()` and `isca2020()`.

### 3.2 `tsp/isa.py` (lead)

Frozen dataclasses, plain data only:

- `Dir` (`"E"`, `"W"`), `DType` (`"int8"`, `"fp16"`, `"int32"`, `"fp32"`), `width(dtype)`, `np_dtype(dtype)`.
- `StreamRef(dir, s)`: for a multi-stream value, `s` is the base stream.
- Queue control: `Sync`, `Notify`, `Nop(n)`, `Repeat(n, d)`.
- `Read(addr, out, tag)`, `Write(addr, src, expect)`.
- `Vxm(op, dtype, a, b, out, n, out_dtype, imm, tag, expect)`. For a node `op(a, a)` both operand fields hold the same `StreamRef`.
- `Iw(dtype, entries, expect)` where `entries` is a tuple of `(row, StreamRef)`.
- `Abc(dtype, src, out, n_rows, tag, expect)`.
- `Distribute(width, src, out, map, n, tag, expect)`, `Permute(width, src, out, map, n, tag, expect)`, `Shift(width, src, out, shift, n, tag, expect)`.
- `tag` is the debug name given to the result; `expect` is a tuple of the debug names expected on each operand, in operand order, or empty to skip the check. Plane `j` of a value named `v` has the tag `v#j` in the stream register, for every data type including `int8` (`v#0`). `Read` and `Write` handle one plane, so their `tag` and `expect` entries already include the `#j` suffix; all other instructions give names without the suffix.
- **Tags from the compiler are unique per emission:** the name is `<tensor name>@<tile index>`, where the tile is the one whose instruction emits the value. A tensor read from memory by two tiles therefore appears under two names. The compiler sets `expect` on every instruction.
- Helpers `to_planes(array, dtype) -> list of uint8 planes` and `from_planes(planes, dtype) -> array`, using explicit little-endian byte order.
- `kind_of(instr)` returns the latency-table key.

### 3.3 `tsp/program.py` (lead)

```python
@dataclass
class TensorLoc:      # where a named tensor lives in MEM
    name: str
    dtype: str
    n: int            # logical length; lanes >= n are padding
    planes: tuple[tuple[str, int], ...]   # (MEM unit name, address) per plane

@dataclass
class Program:
    config: ChipConfig
    queues: dict[str, list]               # unit name -> instructions; insertion order = canonical unit order
    mem_image: dict[tuple[str, int], bytes]   # constants, preloaded (B22)
    inputs: dict[str, TensorLoc]          # poked by the host before a run
    outputs: dict[str, TensorLoc]         # read by the host after a run
    schedule: list[dict]                  # compiler's planned routes, for cross-checking (section 5.6)
```

`Program.to_json()` and `from_json()` give a canonical, byte-stable form, implemented in `program.py`: queues are stored as an ordered list of `[unit, instructions]` so their order survives a round trip, `mem_image` as a sorted list of `[unit, address, hex]`, and instructions as dicts with a class name.

**Iteration rule.** Code that visits units always iterates `config.units()` and looks each one up; it never relies on the order of `Program.queues`.

### 3.4 `tsp/trace.py` (lead)

```python
@dataclass
class Trace:
    config: dict
    n_cycles: int
    dispatches: list[dict]   # {did, cycle, unit, pos, kind, text, reads: [{dir, s, pos, vid, tag}]}
    emissions: list[dict]    # {cycle, did, unit, dir, s, pos, vid, tag, overwrote}   overwrote = vid or None
    cells: list[list]        # [cycle, dir, s, pos, vid]  every occupied register, every cycle, after step 2
    mem_writes: list[dict]   # {cycle, did, unit, addr, tag}   cycle = commit cycle
    values: dict             # str(vid) -> {tag, unit, did, cycle}   cycle = emission cycle
    outputs: dict            # output name -> hex of the tensor's bytes in MEM at the end of the run
```

- `did` is the index of the dispatch in `dispatches`; `kind` is `isa.kind_of(instr)`; `text` is `asm.format_instr(instr)`.
- `vid` values are integers assigned in emission order, starting at 0. One `vid` per plane.
- Order within the lists: `dispatches` by cycle, then canonical unit order. `emissions` by cycle, then by `did`, then stream number. `cells` by cycle, then direction (`E` before `W`), then stream, then position.
- `Trace.to_json()` is canonical (sorted keys, no floats). `Trace.digest()` is the SHA-256 of that JSON. The digest covers every dispatch, emission, register occupancy and the final output bytes; it does not cover the bytes carried on streams in mid-run.
- `record_cells=False` leaves `cells` empty to save memory on large configurations. The validator and the visualiser require `cells`.

### 3.5 `tsp/graph.py` (lead)

A small graph IR with fixed shapes. All values are vectors of at most `lanes` elements; a matrix is a list of row vectors.

```python
g = Graph("m1")
x  = g.input("x", "int8", n)                    # vector supplied by the host
b  = g.const("b", array, "int32")               # vector constant
W  = g.const_matrix("W", array2d, "int8")       # one constant vector per row
M  = g.matrix("K", [row_tensor, ...])           # matrix from existing vectors (may be computed)
y  = g.matvec(W, x)                             # int8 -> int32, fp16 -> fp32
z  = g.add(a, b); g.sub(a, b); g.mul(a, b)
z  = g.neg(a); g.relu(a); g.tanh(a); g.exp(a); g.rsqrt(a)
z  = g.cast(a, "fp16"); g.requant(a, shift)
z  = g.broadcast(a, lane, n)                    # z[i] = a[lane] for i < n
g.output("y", z)
```

- Each call returns an integer tensor id; ids increase in creation order. Nodes are stored in a list in creation order, which is a topological order.
- The graph checks data types and lengths when a node is added and raises `GraphError` otherwise. There are no implicit casts.
- `matvec(M, x)` requires every row of `M` and `x` to have the same data type (`int8` or `fp16`), row length <= `lanes`, and at most `lanes` rows. The result length is the number of rows.
- Binary operations require both operands to have the same data type and length. `add`, `sub`, `mul`, `neg`, `relu` accept `int32` or `fp32`.
- An operation may use the same tensor for both operands, as in `mul(x, x)`.
- A tensor may be a row of a matrix and also a vector operand or an output.
- Lanes at or above a tensor's length are always zero (section 2.3).

### 3.6 `tsp/icu.py` (ISA agent)

```python
class InstructionQueue:
    def __init__(self, unit: str, instrs: list, config: ChipConfig): ...
    def step(self, cycle: int, barrier_release: int | None) -> object | None
        # Returns the data instruction to dispatch this cycle, or None.
        # barrier_release is the cycle at which the barrier opens, or None if no Notify has been dispatched yet.
    def notify_issued(self) -> bool     # True on the cycle this queue dispatched Notify
    def done(self) -> bool
```

`step` must be called exactly once per cycle with `cycle = 0, 1, 2, ...`. It never returns `Sync`, `Notify`, `Nop` or `Repeat`. `done()` is false while a `Repeat` still has dispatches left. The simulator calls `step` on every queue, collects `notify_issued()`, and passes `barrier_release = notify cycle + T15` from the next cycle on.

### 3.7 `tsp/asm.py` (ISA agent)

- `check_program(program) -> None`: raises `ProgramError` for any structural violation: unknown unit, instruction not allowed on that unit type, stream out of range, base stream not aligned to the width, more than 16 streams in an `Iw`, `Nop` count out of range, `Repeat` not preceded by a data instruction, address out of range, `Repeat` with `n < 1` or `d < 1`, a length `n` outside `1..lanes`, a queue that does not start with `Sync` or `Notify`, `Sync` or `Notify` anywhere but first, more or fewer than one `Notify`, MXM directions violating B10.
- `format_instr(instr) -> str`, `disassemble(program) -> str` and `assemble(text, config) -> dict of queues`, with `assemble(disassemble(p))` equal to `p.queues`.
- `dispatch_times(queue, config) -> list[(cycle, instr)]`: the static expansion of a queue into dispatch cycles using the table in section 2.6, used by the validator.

### 3.8 `tsp/hw/` (hardware agent)

```python
class Simulator:
    def __init__(self, program: Program, record_cells: bool = True): ...
    def poke(self, name: str, array) -> None        # write an input tensor into MEM before the run
    def run(self) -> Trace
    def peek(self, name: str) -> numpy.ndarray      # read an output tensor from MEM after the run, length n
```

`run` calls `asm.check_program` first. `poke` checks the array's length and data type against `program.inputs[name]` and pads with zeros to `lanes` (B22). An input that is never poked is an error when first read.

### 3.9 `tsp/compiler/` (compiler agent)

```python
def compile_graph(graph: Graph, config: ChipConfig) -> Program
```

Pure and deterministic: the same graph and configuration give a byte-identical `Program.to_json()`.

### 3.10 `tsp/validate.py` and `tsp/reference.py` (models agent)

```python
def validate(program: Program, trace: Trace) -> list[str]      # empty list = valid
def evaluate(graph: Graph, inputs: dict) -> dict               # NumPy interpretation of a Graph, same arithmetic as section 2.5
```

### 3.11 `tsp/viz/` (visualisation agent)

```python
def render_timeline(program: Program, trace: Trace, title: str, path: str) -> None
```

### 3.12 `tsp/run.py` (lead)

`python -m tsp.run m1|m2|m3|all [--out DIR]` builds the graph, compiles, simulates, validates, compares with the NumPy reference and writes `DIR/<m>_timeline.html`, `<m>_trace.json`, `<m>_program.asm`. It exits non-zero on any mismatch.

## 4. Compiler pipeline

`compile_graph` runs the stages below. Each stage is a pure function in its own file.

### 4.1 Graph to tiles (`tiling.py`)

A **tile** is a rigid group of instructions whose relative timing is fixed: MEM reads, a chain of one or more operations, and MEM writes of the final result. It mirrors the sourced pattern "Read -> Conv2D -> Requantize -> ReLU -> Write" (C2).

- Every graph node becomes one operation. Constants, inputs and matrices are not operations.
- Operation `B` is fused after operation `A` in the same tile when all of these hold:
  - `A`'s result has exactly one use in the whole graph, counting each operand slot and each matrix-row slot separately, and that use is an operand slot of `B`. So `mul(r, r)` uses `r` twice and is never fused with the producer of `r`.
  - `A`'s result is not a graph output.
  - `B` is not a `matvec`. A `matvec` always starts a tile, so its activation is always read from memory and a tile holds at most one `matvec`.
  - `(A, B)` is not in the `no_fuse` set (section 4.4).
- If both operands of `B` qualify, the first operand is fused and the producer of the second ends its own tile.
- When both operands of an operation are the same stored tensor, it is read once and both operand fields name the same streams.
- The fused operand is the **spine** of the tile. Every other operand is read from MEM.
- The final result of every tile is written to MEM. This is what lets later tiles be timed freely (dossier 4.6).
- For each `matvec`, the weight rows are grouped into **install slots**. Rows are taken in order and put in the earliest slot where they fit: a slot holds at most `iw_max_streams` streams (B8) and uses any MEM slice at most once. Each slot is its own small tile: reads of the row planes, then one `Iw`.

Operations in a tile are dispatched at strictly increasing times (every latency is at least 1), so a tile never needs an MXM plane, an SXM or one ALU twice on the same cycle. Only MEM reads can clash inside a tile.

Output: an ordered list of tiles (operation tiles in topological order of their first operation; each `matvec` tile is preceded by its install-slot tiles and depends on them) and the list of tensors that need a place in memory. Tiles are numbered in this order; the number is the tile index used in tags.

### 4.2 Placement (`placement.py`)

Assigns every stored tensor a list of `(MEM unit, address)`, one per plane.

- All planes of a tensor are on distinct slices of one hemisphere. This guarantees that all planes can reach any consumer from the same direction and that the reads or writes of one tensor never need the same slice twice.
- Addresses come from a per-slice counter starting at 0 and are never reused. Exceeding `mem_words` is a `CompileError`.
- **Interference.** Two tensors interfere if they are both read from MEM as operands of the same operation. Interfering tensors must not share a slice. Matrix rows are exempt: install slots (section 4.1) already keep rows that share a slice in different slots.
- **Matrix rows first.** A tensor that is a row of any matrix is placed by the matrix-row rule of the first matrix (in creation order) that contains it, whatever else it is used for. Matrix `i` goes to hemisphere W if `i` is even, E if odd. Its rows, in row order, take windows of `w` consecutive slices starting at the slice farthest from the VXM (nearest the MXM) and moving inward, wrapping round. A row already placed by an earlier matrix keeps its place.
- **Other tensors** are then placed in tensor-id order. Each tries candidate windows in a fixed order: hemisphere E then W for an even tensor id, W then E for an odd one; within a hemisphere, every window of `w` consecutive slices starting at slice 0, 1, 2, ... It takes the first window that shares no slice with an already placed interfering tensor. If none exists, `CompileError`.
- Placement is recomputed from scratch on every restart of the pipeline.

### 4.3 Unit assignment (`binding.py`)

- VXM operations go to the VXM position. The ALU index is chosen during scheduling.
- A `matvec` goes to the MXM plane 0 of the hemisphere that holds most of its weight-row planes (tie: W). This follows the sourced guidance to keep weights close to the MXM ([TSP20] Sec. V-b).
- A `broadcast` goes to an SXM, chosen by the first rule that applies: the SXM in the hemisphere of the previous operation in its tile if that is an MXM; the SXM in the hemisphere where its operand is stored if the operand is read from MEM; otherwise `SXM_W`. It is emitted as a `Distribute`. On a configuration with more than one tile per slice a `broadcast` raises `CompileError`, because `Distribute` cannot move data between superlanes.
- Direction of each result: toward the next consumer's position; if the consumer is at the same position, east. For the final result of a tile: toward the hemisphere where placement put the output tensor (MXM results always flow inward, B10, and pass every MEM slice).

### 4.4 Timetable (`timetable.py`)

For each tile, relative times with the first operation at 0, from the arrival rule in section 2.3:

- Next operation on the spine: `t_next = t_prev + d_prev + |x_next - x_prev|`.
- Read of plane on slice at `x_s` for a consumer at `x_c` firing at `t_c`: `t_read = t_c - T6 - |x_c - x_s|`, direction toward `x_c`.
- Write of plane `j` on slice at `x_j` of a result emitted at `x_l` at `t_l + d_l`: `t_write = t_l + d_l + |x_j - x_l|`.
- `Iw` in an install slot fires at 0; its reads are timed as above.

Then a **self-check**: within one tile, no MEM slice may be needed twice on the same relative cycle. If one is, the two reads belong to different operations of the chain (reads for one operation are on distinct slices: one tensor's planes are on distinct slices, two different operand tensors do not share a slice by the interference rule, and an operand used twice is read once). The fusion pair `(A, B)` where `B` is the later of those two operations is added to `no_fuse`, and compilation restarts from section 4.1, including placement. Each restart adds a new pair to a finite set, so the loop ends; a single-operation tile cannot fail the check.

### 4.5 Scheduling and conflict resolution (`schedule.py`, `reserve.py`)

One **reservation table** with three kinds of entries:

- `(unit, cycle)`: a dispatch.
- `(dir, s, x, cycle)`: a stream register holding a value that is still needed. A value reserves the cells from its emission to its last reader, and nothing after that. A value past its last reader may be overwritten (B1).
- Per MXM plane, `busy_until`: the cycle of the last `Abc` scheduled on that plane. Tiles that use a plane are scheduled one after another, never interleaved, because each `matvec` tile is scheduled directly after its own install slots.

Tiles are scheduled one at a time in a fixed order: by priority (longest path to a sink in the tile dependency graph, larger first), then by tile index. A tile becomes eligible only when all tiles it depends on are scheduled; install-slot tiles are scheduled immediately before their `matvec` tile.

For each tile, the scheduler finds the smallest start time `S >= lower_bound` at which the whole tile fits, trying `S, S+1, S+2, ...`:

- `lower_bound` is the smallest `S` such that every read of a computed tensor is dispatched at least `T7` cycles after that tensor's write, every `Iw` is dispatched after the plane's `busy_until`, and every `Abc` is dispatched at least `T11` cycles after the last `Iw` of its matrix. All of these are lower bounds on `S` only (the bounded instructions belong to the tile being placed and the bounding ones to tiles already placed), so they can always be met by a larger `S`. Program time starts at 0, so `S` also keeps every instruction of the tile at `tau >= 0`.
- At a candidate `S`, resources are claimed in a fixed order (operations in chain order; for each, its operand reads, then the operation, then its result), and conflicts are resolved in this order of preference:
  1. **Re-colour.** For each value, take the lowest base stream, aligned to the value's width, whose cells are free along the whole path. Streams are chosen per value, independently for each direction.
  2. **Re-bind.** For a VXM operation, take the lowest-numbered ALU that is free on that cycle.
  3. **Delay.** If any claim fails, release everything claimed for this tile at `S` and try `S + 1`.
- If `S` exceeds `max_schedule_cycles` (C4), raise `CompileError`.

Termination: the table holds finitely many entries and every other constraint is a lower bound on `S`, so beyond the last reserved cycle every claim of a tile that passed the self-check succeeds.

Determinism (C3): no iteration over sets or over dict views whose insertion order depends on hashing; every sort key ends in a unique integer; candidate lists are built in ascending order.

### 4.6 Emission (`emit.py`)

- For each unit with at least one instruction, sort its dispatches by cycle and build the queue: `Sync` (or `Notify` for `VXM_A0`), then for each instruction a `Nop(gap)` if there is a gap, then the instruction. Gaps longer than 65535 use several `Nop`s.
- The compiler does not emit `Repeat`: its instructions carry unique tags, so no two are equal. `Repeat` is part of the queue model and is exercised by the queue tests and by a hand-written program in the hardware tests.
- `VXM_A0` always gets a queue, so there is always a notifier.
- `Program.schedule` lists, for every emitted plane, `{tag, tile, unit, dir, s, x_from, t_emit, readers: [{unit, x, t}]}`. `tag` includes the plane suffix, `tile` is the tile index, `unit` is the producer, `t_emit` is the emission cycle and each reader's `t` is its dispatch cycle. All times are simulator cycles (program time plus `T15`). Entries are ordered by `t_emit`, then canonical unit order, then stream.
- `mem_image` holds every constant plane. `inputs` and `outputs` map names to locations.

## 5. Validation and tests

### 5.1 What the validator checks (`tsp/validate.py`)

It uses only the `Program` and the `Trace`.

1. **Stream exclusivity.** No two trace `cells` share `(cycle, dir, s, pos)`. For every emission with `overwrote` set, the overwritten `vid` has no read at that cycle or later. For every schedule entry and every position from `x_from` to its farthest reader, the trace cell at the expected cycle holds a value with that entry's tag: a planned value was never displaced on its way.
2. **Unit exclusivity.** No two dispatches share `(unit, cycle)`. The dispatches in the trace equal `asm.dispatch_times(queue, config)` for every queue, instruction by instruction.
3. **Exact arrival.** Every read in the trace has a `vid` (no empty reads), and for the value read, `read.cycle == emit.cycle + |read.pos - emit.pos|` with the read position on the correct side for the value's direction. Every reader listed in `Program.schedule` appears as a read in the trace at that cycle with that tag, and every read in the trace appears in the schedule.
4. **Latency.** For every emission, `emission.cycle - dispatches[emission.did].cycle` equals `config.latency[kind]` of that dispatch. Write and install latencies (T7, T11) are checked by the hardware unit tests, not by the validator.

The first parts of checks 1 and 2 hold by construction in a correct simulator; they are kept as cheap sanity checks on the trace format. The parts that can fail on a wrong schedule are the overwrite rule, the schedule-against-trace comparisons, exact arrival and latency.

### 5.2 Unit tests (each build agent, for its own module)

- **Hardware:** a hand-written program using `Repeat`; an operation with both operands on the same streams; two results from one unit on one cycle; shift and fall-off; overwrite; the arrival rule for each unit kind and each latency; MEM read and write; every VXM operation against NumPy for each data type; MXM `int8` and `fp16`; `Abc` row count; SXM maps; each error type.
- **ISA and queues:** `Nop` and `Repeat` timing; barrier release at `T15`; `check_program` rejects each violation; assemble and disassemble round-trip.
- **Compiler:** placement invariants; timetable equations; the reservation table; a brute-force test of the claim in dossier 4.6 that two values in one stream and direction collide only on the same diagonal with overlapping ranges; byte-identical output across two compilations and across `PYTHONHASHSEED` values 0, 1 and 2 (run in subprocesses); the `no_fuse` restart on a constructed graph.
- **Visualisation:** the HTML contains the trace digest and one cell per trace record; rendering in headless Chromium (Playwright, preinstalled in this environment; the test is skipped if it cannot be imported) yields the expected number of cells and no console errors.

### 5.3 End-to-end tests (models agent)

- For each milestone: compile, simulate, `validate` returns no errors, outputs equal the NumPy reference.
  - M1 and M2 are integer: exact equality.
  - M3 is floating point and is checked twice. Against `evaluate(graph, inputs)`, which follows the arithmetic of section 2.5 exactly: bit-for-bit equality. Against a reference written directly in NumPy with ordinary matrix products (not through `Graph` or `evaluate`) that applies the same `fp16` casts at the same points: `numpy.allclose(rtol=2e-3, atol=2e-3)`. The loose tolerance is deliberate: a last-bit difference in a `float32` sum can flip an `fp16` rounding at the next cast, which is a relative change of about 5e-4.
- For each milestone: two independent compile-and-run passes give byte-identical `Program.to_json()`, equal `Trace.digest()`, equal `n_cycles` and equal outputs. The same comparison is repeated across subprocesses with `PYTHONHASHSEED` 0, 1 and 2.
- Random small graphs (seeded, fixed list of seeds, including `op(a, a)` nodes, chains of several `matvec`s and computed matrix rows): simulator output equals `evaluate(graph, inputs)` bit for bit. The generator avoids `exp` of unbounded values and `rsqrt` of non-positive values.
- M1 with a 320x320 layer on `ChipConfig.isca2020()`.
- **Negative tests:** inserting one extra `Nop(1)` before an instruction of a compiled M1 program makes the simulator raise or the validator report an error, for each of several chosen instructions.
- **Traceability:** a test scans every `.py` file under `tsp/` except `params.py`. Any numeric literal other than 0, 1 and -1 must be on a line carrying `# ledger: <ID>` or `# not-a-parameter: <reason>`. Every ledger ID used in the code must exist in the dossier, and every numeric constant in `params.py` must carry a ledger ID that exists in the dossier.

## 6. Milestones

All on `ChipConfig.toy()` (16 lanes).

- **M1:** `y = relu(W.x + b)`. `x` is `int8` of length 12, `W` is 8x12 `int8`, `b` is `int32`, `y` is `int32` of length 8. One operation tile: `matvec -> add -> relu`, plus its install slot. `m1.build` takes optional `n_in`, `n_out` and `lanes` so the same model can be built at 320x320.
- **M2:** `h = requant(relu(W1.x + b1), shift)`, `y = W2.h + b2`, with sizes 12 -> 16 -> 8. Integer, exact.
- **M3:** one decode step of a single-head, pre-norm transformer block with `d_model = 8`, sequence length `T = 4`, hidden size 16 and vocabulary 16, in `fp32` with `fp16` MXM operands.
  - Inputs: the current token embedding `x`; the cached keys `K_0 .. K_{T-2}` (`fp16` vectors); the cached values stored transposed as `d` row vectors of length `T` (`fp16`) whose last element is zero.
  - RMS normalisation: `mean(x*x)` is `mul(x, x)`, a cast and one `matvec` with a single row of `1/d`; a small constant `eps` is added; the scalar is spread over `d` lanes with `broadcast`; then `rsqrt` and two `mul`s.
  - `q`, `k`, `v` are three `matvec`s. `k16 = cast(k, fp16)`. Scores are a `matvec` whose rows are the cached keys plus `k16`: the weight matrix is installed partly from a value computed in this step.
  - Softmax over the `T` scores: a `mul` by a constant scale, `exp`, a one-row `matvec` for the sum, `broadcast`, `r = rsqrt(sum)`, `mul(r, r)` to form the reciprocal, `mul`. There is no max-subtraction; the test inputs are scaled so `exp` stays well inside `float32` range, and this is a stated limit of the toy model.
  - Attention output: `matvec` with the transposed cached values, plus `broadcast(p, T-1) * v` for the current token.
  - Residual, second normalisation, feed-forward (`relu`), residual, and an un-embedding `matvec` to logits.
  - Outputs: `logits` (`fp32`), `k16` (`fp16`) and `v` (`fp32`). Updating the caches for the next step is left to the host; this is a stated simplification.
  - The fixed sequence length is a property of the compiled program, in line with the static-shape limitation in dossier section 3.

## 7. Visualisation

One self-contained HTML file per milestone (inline CSS and JavaScript, trace embedded as JSON, no network access needed).

- **Header:** title, cycle count, wall-clock estimate at the T17 clock, and a note that all latencies are assumed (linking the ledger IDs).
- **Gantt:** time runs left to right, one column per cycle. Rows, top to bottom:
  - one row per unit that has a queue, in canonical order, showing each dispatch as a cell labelled with the instruction mnemonic;
  - one row per stream lane `(dir, s)` that ever holds a value, showing for each cycle the tag and position of the values in that lane.
  - The barrier period (cycles 0 to `T15 - 1`) is drawn as one collapsed band.
- **Space-time view:** selecting a cycle shows the chip as a row of positions with the contents of every occupied stream register at that cycle; arrow keys step through cycles.
- **Colour:** one colour per tile, taken from the `tile` field of `Program.schedule` (matched to trace values by tag); values past their last reader are drawn faded.
- **Hover:** full instruction text, operands read and their tags.
- The file embeds `Trace.digest()`, so a test can confirm it matches the trace it was made from.

## 8. Module breakdown and file ownership

| Owner | Files |
|---|---|
| Lead | `tsp/__init__.py`, `tsp/params.py`, `tsp/isa.py`, `tsp/program.py`, `tsp/trace.py`, `tsp/graph.py`, `tsp/errors.py`, `tsp/run.py`, `README.md`, `plan.md`, `plan-review.md`, `research/` |
| Hardware agent | `tsp/hw/__init__.py`, `tsp/hw/streams.py`, `tsp/hw/mem.py`, `tsp/hw/vxm.py`, `tsp/hw/mxm.py`, `tsp/hw/sxm.py`, `tsp/hw/simulator.py`, `tests/test_hw_*.py` |
| ISA agent | `tsp/icu.py`, `tsp/asm.py`, `tests/test_icu.py`, `tests/test_asm.py` |
| Compiler agent | `tsp/compiler/__init__.py`, `tiling.py`, `placement.py`, `binding.py`, `timetable.py`, `reserve.py`, `schedule.py`, `emit.py`, `tests/test_compiler_*.py` |
| Visualisation agent | `tsp/viz/__init__.py`, `tsp/viz/timeline.py`, `tsp/viz/template.html`, `tests/test_viz.py` |
| Models agent | `tsp/models/__init__.py`, `m1.py`, `m2.py`, `m3.py`, `tsp/reference.py`, `tsp/validate.py`, `tests/test_e2e_*.py`, `tests/test_determinism.py`, `tests/test_traceability.py`, `tests/test_validate.py` |

Each model file exposes `build(seed=0, ...) -> (Graph, inputs: dict)` and `reference(seed=0, ...) -> dict` of expected outputs; `reference` regenerates the same constants and inputs from the seed with its own code and does not touch `Graph`.

Agents build in parallel against the lead's contract files. An agent that needs a module owned by another agent codes against the interface in section 3 and uses a small local stand-in inside its own tests where necessary. The lead integrates.

## 9. Order of work

1. Lead writes the contract files (section 3.1 to 3.5).
2. Five build agents in parallel.
3. Lead integrates: M1 end to end, then M2, then M3; writes `tsp/run.py`; generates the timelines.
4. Independent verification (Phase 5).
