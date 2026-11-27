# Research notes: NVIDIA Warp fundamentals in MJWarp, and performance

Area: warp-perf. Source: `src/mujoco_warp` at commit 8f5b9f1. Installed: mujoco-warp 4.0.1, warp-lang 1.19.0, mujoco 4.0.1.
Paths below are relative to the repo root (`mujoco_warp/_src/...`, `benchmarks/...`, `contrib/...`).

Experiments that were actually run live in
`/tmp/claude-0/-home-user-ouramp/2cb48c5e-749c-5a1c-9549-b06105ff67b3/scratchpad/experiments/warp-perf/` (e1.py to e7.py), on CPU,
with Warp 1.19.0. Snippets are marked **[RAN on CPU]**, **[GPU only, not run]** or **[from source]**.

---

## 0. One-paragraph mental model (for the course intro to this area)

MJWarp is MuJoCo rewritten as a few hundred small NVIDIA Warp kernels. A `Model` (constants) and a `Data` (state) are Python
dataclasses whose fields are `wp.array`s on the device. Almost every `Data` array has a leading `nworld` axis, so one kernel
launch with `dim=(nworld, n_things)` advances thousands of independent simulations at once (one GPU thread per
(world, element) pair). Calling `mjw.step(m, d)` from Python issues about 100 kernel launches (measured: 95 `wp.launch` +
5 `wp.launch_tiled` for a toy model, 89 + 6 for the humanoid). Python dispatch overhead dominates for small models, so the
recommended pattern is to record one step into a CUDA graph (`wp.ScopedCapture`) once and then replay it with
`wp.capture_launch(graph)`. Python control flow on `m.opt.*` is "baked" at capture time; numbers inside arrays are not.

---

## 1. Warp basics as used in MJWarp (simple to deep)

### 1.1 `wp.array`, dtypes, and the batched layout

- Fields of `Model`/`Data` are declared with `types.array(*dims, dtype)` (`mujoco_warp/_src/types.py: array`). It creates an empty
  `wp.array(ndim=len(shape), dtype=dtype)` and overwrites `.shape` with symbolic names like `"nworld"`, `"nq"`, `"*"`. This
  is metadata for introspection (kernel analyzer, `put_model`, `mark_batched`, JAX bridges), not the real runtime shape.
- `"nworld"` leading dimension: one row per world (all `Data` state). Example from `types.py: Data` docstring:
  `qpos (nworld, nq)`, `qvel (nworld, nv)`, `ctrl (nworld, nu)`, `xpos (nworld, nbody, 3)`, `sensordata (nworld, nsensordata)`.
- `"*"` leading dimension on `Model` fields: "any nonzero size". By default it is 1 (shared by all worlds); it can be `nworld`
  for per-world randomization (domain randomization). Kernels index it with `worldid % arr.shape[0]` so both sizes work.
  The kernel analyzer enforces this (`MissingBatchModulo` in `contrib/kernel_analyzer/kernel_analyzer/ast_analyzer.py`).
- Vector dtypes: `xpos` is `wp.array2d[wp.vec3]`, so its numpy view is `(nworld, nbody, 3)` but its Warp shape is
  `(nworld, nbody)`. Custom vec/mat types are defined in `types.py` (`vec5f`, `vec6f`, `vec10f`, `mat33`, `mat63f`, ...).
- Contacts are NOT per-world rows: `Contact` arrays are pooled `(naconmax,)` across all worlds with a `worldid` column, and
  `d.nacon` is a single counter of shape `(1,)`. Constraints (`Constraint`, `d.efc`) ARE per-world: `(nworld, njmax)`, and
  `d.nefc` is `(nworld,)` (`types.py: Contact`, `Constraint`; `io.py: make_data` docstring: "Contacts exist in large
  heterogeneous arrays: one world may have more than nconmax contacts ... no world may have more than njmax constraints").

**[RAN on CPU]** (e1.py) shapes with `nworld=4` for a free ball + hinge pole + 1 motor + 1 framepos sensor:

```
nworld 4 naconmax 192 njmax 64
qpos (4, 8) float32     qvel (4, 7) float32     ctrl (4, 1) float32
xpos (4, 3) vec3f       xquat (4, 3) quatf      sensordata (4, 3) float32
time (4,) float32       nacon (1,) int32        nefc (4,) int32      overflow (4,) int32
opt.timestep (1,) [0.002]   opt.gravity (1,)    body_mass (1, 3)     geom_size (1, 3)
graph_conditional True      deterministic 0
```

Note: everything is float32 (MuJoCo CPU is float64). Quaternions are `(w, x, y, z)` in Model/Data (CONTRIBUTING.md).

### 1.2 `wp.kernel`, `wp.tid()`, `wp.launch`

Basic pattern in MJWarp: one thread per (world, element). Simplest real example, `forward.py: _next_velocity`:

```python
@cache_kernel
def _next_velocity(enable_sleep: bool = False):
  @wp.kernel(module="unique", enable_backward=False)
  def kernel(
    # Model:
    opt_timestep: wp.array[float],
    dof_treeid: wp.array[int],
    # Data in:
    qvel_in: wp.array2d[float],
    qacc_in: wp.array2d[float],
    tree_awake_in: wp.array2d[int],
    # In:
    qacc_scale_in: float,
    # Data out:
    qvel_out: wp.array2d[float],
  ):
    worldid, dofid = wp.tid()
    if wp.static(enable_sleep):
      treeid = dof_treeid[dofid]
      if treeid >= 0 and tree_awake_in[worldid, treeid] == 0:
        return
    timestep = opt_timestep[worldid % opt_timestep.shape[0]]
    qvel_out[worldid, dofid] = qvel_in[worldid, dofid] + qacc_scale_in * qacc_in[worldid, dofid] * timestep
  return kernel
```

Launched as `wp.launch(kernel, dim=(d.nworld, m.nv), inputs=[...], outputs=[...])`. `wp.tid()` unpacks the 2D index.

Teaching points from this one kernel:
- `wp.array[float]` / `wp.array2d[float]` bracket syntax (the analyzer flags `wp.array(dtype=...)` as `ParenthesizedArraySyntax`).
- Parameter grouping comments `# Model:`, `# Data in:`, `# In:`, `# Data out:`, `# Out:` and suffixes `_in`/`_out` on Data
  params; Model params have no suffix and must follow Model field order (CONTRIBUTING.md, analyzer `InvalidSuffix`,
  `InvalidParamOrder`, `MissingComment`).
- `worldid % opt_timestep.shape[0]` for a `"*"`-batched Model field.
- `wp.static(enable_sleep)`: compile-time branch; the `if` disappears from the generated code when False.
- No defaults, no `*args/**kwargs` in kernels (analyzer `DefaultForbidden`, `VarArgsForbidden`, `KwArgsForbidden`).

### 1.3 `wp.func`

Device functions that kernels call (inlined). Example `forward.py: _wrap_period` (decorated `@wp.func`), and most of
`math.py` (quaternion ops etc.). Same parameter-comment convention. A `wp.func` can return values; a kernel cannot.

### 1.4 Module options: `enable_backward=False`, `module="unique"`, `default_grid_stride`

- Many source files set module defaults at import, e.g. `constraint.py:34`:
  `wp.set_module_options({"enable_backward": False, "default_grid_stride": False})`. No adjoint code is generated, so
  compile is faster and binary smaller. Consequence: `wp.Tape` cannot differentiate MJWarp kernels (see section 8).
- `@wp.kernel(module="unique")`: the kernel gets its own Warp module. Required for kernels created inside factories
  (analyzer `MissingModuleUnique`) and for kernels launched with a custom `block_dim` (`SharedModuleCustomBlockDim`), and it lets
  each specialization carry its own module options (`deterministic`, `deterministic_max_records`). Seen in the CPU logs as
  module names like `_next_time_builder__locals___next_time_de44a9b2`.
- A count of `module="unique"` uses: smooth.py 29, derivative.py 35, constraint.py 23, passive.py 18, forward.py 11, sensor.py 10 ...
  and about 207 plain `@wp.kernel` across `_src`.

### 1.5 Kernel factories + `cache_kernel` (warp_util.py)

Pattern: a Python function takes compile-time parameters (bools, ints, enum values, a `TileSet`) and returns a freshly defined
kernel specialized for them using `wp.static`. `warp_util.cache_kernel` memoizes the factory:

```python
_KERNEL_CACHE = {}
def cache_kernel(func):
  # caching kernels to avoid crashes in graph_conditional code
  @functools.wraps(func)
  def wrapper(*args):
    def _hash_arg(a):
      if hasattr(a, "size"):   # TileSet/array-like: keyed by size
        return a.size
      if isinstance(a, list):
        return hash(tuple(a))
      return hash(a)
    key = tuple(_hash_arg(a) for a in args) + (func.__module__, func.__name__)
    if key not in _KERNEL_CACHE:
      _KERNEL_CACHE[key] = func(*args)
    return _KERNEL_CACHE[key]
  return wrapper
```

- Only positional args are part of the key (no `**kwargs` in `wrapper`), so factories are always called positionally.
- Why: creating a new kernel object (and thus potentially a new module load) inside `wp.capture_while` / `capture_if` bodies
  crashes or breaks capture; the cache guarantees the same kernel object is reused (the comment in the source says so).
- After one step of the toy model, `len(_KERNEL_CACHE) == 47` [RAN on CPU].

**[RAN on CPU]** (e5.py) a self-written factory using MJWarp's decorator:

```python
from mujoco_warp._src.warp_util import cache_kernel, _KERNEL_CACHE

@cache_kernel
def make_scale(power: int):
  @wp.kernel(module="unique", enable_backward=False)
  def k(x_in: wp.array[float], y_out: wp.array[float]):
    i = wp.tid()
    v = x_in[i]
    r = float(1.0)
    for _ in range(wp.static(power)):   # unrolled at compile time
      r *= v
    y_out[i] = r
  return k

a = make_scale(3); b = make_scale(3); c = make_scale(2)
# a is b -> True, a is c -> False
# cache keys: [(3, '__main__', 'make_scale'), (2, '__main__', 'make_scale')]
```

Note `_hash_arg(3) == hash(3) == 3`. `determinism_test.py` checks the same key form:
`(hash(False), "mujoco_warp._src.smooth", "_transmission") in warp_util._KERNEL_CACHE`.

### 1.6 Tiles (`wp.launch_tiled`, `wp.tile_*`) [cooperative block-level ops]

`wp.launch_tiled(kernel, dim=..., block_dim=B)` launches `B` threads per logical index; the threads in one block cooperate on
"tiles" (block-shared arrays). MJWarp uses this (369 `launch_tiled`/`wp.tile_` occurrences across bvh, collision_driver,
collision_flex, constraint, derivative, forward, island, ray, sensor, smooth, solver) for:
- Dense Cholesky of small per-world blocks: `smooth.py: _tile_cholesky_factorize_block` does
  `wp.tile_load` (indices) -> `wp.tile_load_indexed` (gather CSR values into a dense block) -> `wp.tile_reshape` ->
  `wp.tile_cholesky_inplace(L, fill_mode="upper")` -> `wp.tile_store`. `_tile_cholesky_solve_block` uses `wp.tile_cholesky_solve`.
- Block reductions: `smooth.py` fused sparse LDL uses `wp.tile_sum(wp.tile(partial))[0]` to sum a per-thread partial across
  the block; `_subtree_com_world_tiled` / `_cfrc_world_tiled` reduce over root bodies in chunks of `WORLD_SUM_CHUNK = 512`
  with `WORLD_SUM_BLOCK = 128` threads.
- Solver: `solver.py: _solve_init_search_cg_tiled` launched with `block_dim=m.block_dim.solve_init_search_cg`.
- Tile shapes must be compile-time constants, which is why tile kernels are factories keyed on `TileSet.size`
  (comment in `_tile_cholesky_factorize_block`: "Tile shapes must be compile-time constants, so the densify is inlined per kernel").
- Launch block sizes are configurable per kernel family through `types.py: BlockDim` (marked experimental), stored as
  `m.block_dim` (e.g. `cholesky_factorize=32`, `update_gradient_grad=256`, `contact_jac_sparse=128`, `render=64`).

**[RAN on CPU]** (e5.py) a per-world tile reduction, the pattern a learner can reuse for "sum over bodies per world":

```python
NW, N, TILE = 4, 64, 64
@wp.kernel
def per_world_sum(data: wp.array2d[float], out: wp.array[float]):
  worldid = wp.tid()
  t = wp.tile_load(data[worldid], shape=(TILE,))
  s = wp.tile_sum(t)
  wp.tile_store(out, s, offset=(worldid,))

arr = wp.array(np.arange(NW*N, dtype=np.float32).reshape(NW, N))
out = wp.zeros(NW, dtype=float)
wp.launch_tiled(per_world_sum, dim=[NW], inputs=[arr], outputs=[out], block_dim=32)
# out == [2016, 6112, 10208, 14304] == arr.sum(1)
```

Tiles work on CPU too (block_dim is effectively 1 thread on CPU), which is good for notebook debugging.

### 1.7 Streams: `side_stream` (warp_util.py)

```python
def side_stream(device) -> wp.Stream | None:
  """Returns a second stream while the device's stream is capturing a graph, else None."""
  if not device.is_cuda or not device.stream.is_capturing:
    return None
  key = (device.alias, device.stream.cuda_stream)
  ...
```

Used in `solver.py` (~line 1909): during capture, `J @ search` (`_mul_jac_vec`) runs under `wp.ScopedStream(jv_stream)` while
`M @ search` runs on the main stream, joined by `wp.wait_stream(jv_stream)`. Inside a CUDA graph this becomes two parallel
branches of the DAG. Outside capture it returns None, so `wp.ScopedStream(None)` is a no-op and everything is serial.
Also used at `solver.py:5141` (`h_stream`). Diagram idea: fork/join DAG of graph nodes.

### 1.8 `efc_threads_per_world` (warp_util.py): occupancy-based launch sizing

```python
def efc_threads_per_world(nworld, njmax, device, kernel, num_waves=6) -> int:
  if not device.is_cuda or njmax <= 32:
    return njmax
  block_size, min_grid_size = wp.get_suggested_block_size(kernel, device)
  warps = max(1, num_waves * block_size * min_grid_size // (32 * max(1, nworld)))
  return 32 * min(njmax // 32, warps)
```

Instead of one thread per constraint row (`njmax` per world), it launches a warp-aligned number of threads per world sized
to fill the GPU `num_waves` times; each thread then loops (strides) over rows. Test table (`warp_util_test.py`, with a mocked
occupancy of block 640, min grid 340): `(nworld=4096, njmax=384) -> 288`, `(8192, 384) -> 128`, `(8192, 384, waves=1) -> 32`,
`(1, 384) -> 384`. On CPU it returns `njmax`. Used in `solver.py` (lines ~1864, 2582, 2637) and `constraint.py:6398`.
Teaching point: more worlds => fewer threads per world, keeping the total thread count near what the hardware can hold.

### 1.9 `check_toolkit_driver` (warp_util.py)

Called by `io.py: put_model`. Calls `wp.init()`, and on CUDA warns if `wp.is_conditional_graph_supported()` is false
("CUDA version < 12.4 detected ... conditional graph nodes are not available ... Model.opt.graph_conditional should be set
to False"). Colab GPUs have recent drivers, so this normally is silent.

---

## 2. CUDA graph capture of `mjw.step`

### 2.1 Why

- JIT: the first call compiles (or loads from cache) every kernel. [RAN on CPU] (e1.py): first `mjw.step` 0.35 s (kernels
  already in disk cache; a cold cache took ~25 s here), second 0.005 s.
- Dispatch: ~100 launches per step from Python. Per-launch Python overhead is microseconds; for small models this overhead is
  larger than the GPU work. The tutorial notebook (`notebooks/tutorial.ipynb`) says the same: "mjw.step dispatches hundreds
  of Warp function calls to the GPU serially, each with a small dispatch overhead cost", and fixes it with `wp.ScopedCapture`.

### 2.2 The canonical pattern **[RAN on CPU; same code runs on Colab GPU]**

```python
import mujoco, warp as wp, mujoco_warp as mjw
mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=4096)

mjw.step(m, d)                      # optional warm-up: compile before capture
with wp.ScopedCapture() as capture:  # records, does not execute (time unchanged after capture)
  mjw.step(m, d)
graph = capture.graph

for _ in range(1000):
  wp.capture_launch(graph)           # replays all ~100 kernels as one graph launch
wp.synchronize()
```

Verified (e2.py): after warm-up step `time=0.002`; after capture still `0.002` (capture records only); after 5 replays `0.012`.

The same "unroll" is what `mjwarp-testspeed` does: `mujoco_warp/_src/cli.py: unroll` captures `fn(*args)` once inside
`wp.ScopedCapture`, measures `jit_duration` as the capture time, then for each step does `wp.capture_launch(graph)` +
`wp.synchronize()` and times it with `time.perf_counter()`. (OptiX render backend cannot be captured and runs directly.)

### 2.3 What is baked into the graph vs what stays live (key pitfall section)

- Baked (Python-time decisions): every `if m.opt.integrator == ...`, `if m.opt.solver == ...`, `m.opt.iterations` loop
  counts when `graph_conditional=False`, `m.opt.enableflags & SLEEP`, `m.opt.deterministic`, `m.opt.warn_overflow` (it is used
  in `wp.static` in `forward.py: _next_time_builder`), sizes like `m.nv`, `d.nworld`, kernel specializations, AND the array
  pointers. See `forward.py: step` which branches on `m.opt.integrator` in Python.
- Live (read from device memory at replay): the contents of arrays, e.g. `d.ctrl`, `d.qpos`, `m.opt.timestep`, `m.opt.gravity`,
  `m.body_mass`. Changing them with `.assign()`, `wp.copy()`, `.fill_()` or your own kernel is visible to the next replay.
- Replacing an array object breaks the link. [RAN on CPU] (e2.py): after capture, `d.qpos = wp.array(zeros)`, then a replay
  wrote to the OLD array ("old qpos changed [0. 0. 0.9989]") and left the new zeros untouched. The tutorial's rendering cell
  does `data.qpos = wp.array(qpos, ...)` before any capture, which is fine; after capture always use `d.qpos.assign(qpos)`.
- No host sync inside a step: CONTRIBUTING.md "Avoid CPU-GPU synchronization (`.numpy()`, `.item()`, D2H copies) during
  simulation steps". Calling `.numpy()` inside the captured function would fail on CUDA.
- Memory allocation inside the conditional bodies is not possible: `derivative.py` and `solver.py` comments say "inside
  wp.capture_while, where memory cannot be allocated", so scratch buffers are preallocated (e.g. `SolverContext` fields).

### 2.4 Conditional graph nodes: `wp.capture_while`, `wp.capture_if`, `opt.graph_conditional`

- `io.py:773` sets `opt.graph_conditional = True` by default.
- `solver.py` (~line 5575):

```python
if m.opt.iterations != 0 and m.opt.graph_conditional:
  # the iteration kernel (while_body) is repeatedly launched as long as condition is not zero.
  # nsolving is a warp array of size 1 that counts not-converged worlds; 0 when all converged.
  wp.capture_while(nsolving, while_body=_solver_iteration, m=m, d=d, ctx=ctx, nsolving=nsolving, compact=compact)
else:
  # mostly for JAX, which is not compatible with CUDA graph conditional
  for _ in range(m.opt.iterations):
    _solver_iteration(m, d, ctx, nsolving, compact=compact)
```

  So with graph_conditional the GPU itself decides how many solver iterations to run (early exit when every world converged),
  without returning to Python. Without it, the graph contains `iterations` copies of the iteration body (with per-world
  `done` masks skipping work), which costs time but is JAX-compatible.
- `wp.capture_if` is used for sleeping/wake logic in `forward.py` (lines ~1592, 2859, 2873, 2913, 2940): e.g.
  `wp.capture_if(woke, on_true=sleep.update_sleep, m=m, d=d)`.
- `derivative.py:5748` uses `wp.capture_while(efm_nsolving, while_body=_pcg_iteration)` for a PCG loop.
- Outside capture (eager mode), `capture_while` evaluates the condition on the host each iteration (a device->host sync);
  that is one more reason eager GPU stepping is slow.
- `solver.py:5821` forces `graph_conditional` off on CPU for the compact solve: `gc = m.opt.graph_conditional and wp.get_device().is_cuda`.
- Requires CUDA >= 12.4 for conditional nodes (`check_toolkit_driver`).

Diagram idea: a graph DAG with a "while" node whose body box loops; counter `nsolving` ticks down 4096 -> 1730 -> 12 -> 0 as
worlds converge; worlds rendered as dots turning green.

### 2.5 CPU vs GPU capture (new in Warp 1.19)

Warp 1.19 `wp.ScopedCapture` docstring: "Works on both CPU and CUDA devices" (APIC recording is used for CPU replay). So the
course notebooks can demonstrate capture even with no GPU. [RAN on CPU] (e5.py, toy model, ~100 launches):

```
nworld=   1 eager   12.48 ms/step  graph    0.03 ms/step
nworld=  16 eager    4.05 ms/step  graph    0.18 ms/step
nworld= 256 eager    6.99 ms/step  graph    2.56 ms/step   (~100k world-steps/s on 1 CPU core)
```

Shape of the lesson: eager time is roughly flat (Python dispatch bound), graph time grows with nworld (compute bound). On CPU
the compute grows linearly with nworld (CPU kernels loop over threads); on GPU it stays nearly flat until the GPU is full, which
is the whole point of batching. Ask learners to rerun this table on Colab with nworld = 1 .. 65536. Expected GPU numbers are not
measured here; do not invent them in the course, have the notebook print them.

`warp_util.EventTracer` does NOT work on CPU: [RAN on CPU] `RuntimeError: Device cpu is not a CUDA device` (it creates
`wp.Event(enable_timing=True)`). `mjwarp-testspeed` also refuses CPU: `ValueError: testspeed available for gpu only` [RAN].

---

## 3. Profiling: `event_scope` and `EventTracer` (warp_util.py)

- `@event_scope` wraps most public stages: `forward.py: step, forward, fwd_position, fwd_velocity, fwd_actuation,
  fwd_acceleration, euler, rungekutta4, implicit, step1, step2`, `smooth.py: factor_m, tendon_armature`, ...
- When no tracer is active (`_STACK is None`), the wrapper just calls the function: zero overhead apart from one check.
- With a tracer: it records a CUDA event before and after the call (`wp.record_event`), pushes a nested dict level so inner
  scopes nest under the outer one, and merges repeated calls of the same name into a tuple of event pairs.
- It skips recording if any caller frame is `capture_while` or `capture_if` (events cannot be recorded inside conditional bodies);
  this uses `inspect.stack()` so tracing has Python overhead, but only at capture time.
- Events recorded during graph capture become graph nodes; after each `capture_launch`, `tracer.trace()` reads the elapsed
  times. That is how `cli.unroll` reports per-stage times while running captured graphs.
- `trace()` returns `{name: (tuple_of_elapsed_ms, sub_trace_dict)}` recursively. Only one tracer at a time
  (`ValueError("only one EventTracer can run at a time")`).

Usage on Colab **[GPU only, not run]** (structure taken from `cli.unroll` and `testspeed._print_trace`):

```python
from mujoco_warp._src import warp_util   # private module: may change between versions
with warp_util.EventTracer() as tracer:
  with wp.ScopedCapture() as cap:
    mjw.step(m, d)
  wp.capture_launch(cap.graph); wp.synchronize()
  trace = tracer.trace()

def show(tr, indent=0):
  for name, (times, sub) in tr.items():
    print("  " * indent + f"{name}: " + ", ".join(f"{t*1e3:.1f} us" for t in times))  # wp.get_event_elapsed_time is ms
    show(sub, indent + 1)
show(trace)
```

`testspeed._print_trace` / `_flatten_trace` compute `1e6 * t / (nstep * nworld)` on the summed per-step times. Since
`wp.get_event_elapsed_time` returns milliseconds, that is **nanoseconds per world-step** for each stage (consistent with the
"Total time per step: ... ns" summary line). README example (`benchmarks/README.md`): `humanoid.step 364.29`,
`humanoid.step.forward 361.76`, `...fwd_position 89.70`, `...fwd_position.kinematics 16.33` (ns per world-step at nworld 8192).

Diagram/animation idea: a flame-graph / icicle chart built from the nested trace dict (step > forward > fwd_position >
kinematics, com_pos, crb, factor_m, collision; fwd_velocity; fwd_actuation; fwd_acceleration; solve > iterations...).
Hover reveals source function names. Animate bars growing as nworld increases.

---

## 4. `mjwarp-testspeed` (mujoco_warp/testspeed.py + _src/cli.py)

Entry point: `pyproject.toml [project.scripts] mjwarp-testspeed = "mujoco_warp.testspeed:main"` (also `mjwarp-viewer`,
`mjwarp-record`).

Flags (all defined in `cli.py` unless noted):
- `--nworld` (default 8192), `--nstep` (default 1000), `--nconmax`, `--njmax`, `--njmax_nnz`, `--nccdmax`, `--nvmax`
- `-o/--override "opt.solver=cg"` (multi; parsed by `io.py: override_model`, e.g. `opt.iterations=1`, `opt.cone=pyramidal`,
  `opt.disableflags=contact|spring`, `opt.warn_overflow=~ITERATIONS|~LS_ITERATIONS`)
- `--keyframe` (default 0), `--replay file.npz` (ctrl trajectory; sets nstep to its length), `--noise_std 0.01`,
  `--noise_rate 0.1` (Ornstein-Uhlenbeck ctrl noise kernel `cli._ctrl_noise` using `util_misc.halton`), `--init_asleep`,
  `--device`, `--event_trace`
- testspeed-only: `--function step` (any public `mjw` function with params exactly `{m, d}` or `{m, d, rc}`, e.g.
  `forward`, `fwd_position`, `collision`, `render`), `--clear_warp_cache` (clears kernel, LTO and `~/.nv/ComputeCache`),
  `--measure_alloc`, `--measure_solver`, `--num_buckets 10`, `--memory`, `--info`, `--format human|short|json`,
  `--overflow_behavior error|continue` (default error: exits with the world ids and overflow flags).
- render flags: `--render_width/--render_height` (multi), `--render_rgb/--render_depth/--render_seg`, `--camera_name`,
  `--render_textures`, `--render_shadows`, `--render_backend warp|optix`, ...

Output (human): Model sizes, Option summary, `Data nworld naconmax njmax`, then
"Total JIT time", "Total simulation time", "Total steps per second" (= nworld*nstep/runtime), "Total realtime factor",
"Total time per step" (ns), "Total converged worlds" (worlds without NaN in qpos). JSON keys: `jit_duration, run_time,
steps_per_second, converged_worlds, model_memory, data_memory, total_memory, ncon_mean, ncon_p95, nefc_mean, nefc_p95,
solver_niter_mean, solver_niter_p95` plus flattened trace keys.

Colab usage **[GPU only, not run]**. The model path falls back to the installed package (`cli.load_model`:
`epath.resource_path("mujoco_warp") / path`), and the package ships `test_data/humanoid/humanoid.xml`, so no clone needed:

```
!mjwarp-testspeed test_data/humanoid/humanoid.xml --nworld 4096 --nstep 500 --event_trace --measure_solver
!mjwarp-testspeed test_data/humanoid/humanoid.xml --nworld 4096 -o "opt.solver=cg" --format json
```

(For the full benchmark models clone the repo and use `benchmarks/humanoid/humanoid.xml`.)

---

## 5. Benchmarks suite (benchmarks/)

- Layout per benchmark (CONTRIBUTING.md): `benchmarks/<name>/__init__.py` defines `BENCHMARKS` (list of dicts) and optional
  `ASSETS` (pinned git repos), plus MJCF, optional `.npz` ctrl replay, `README.md` with a property table and a `.webp` rollout.
- Dict keys become testspeed flags (`run.py: _bm_flags`): `name`, `mjcf`, `nworld`, `nconmax`, `njmax`, `nccdmax`, `nvmax`,
  `nstep`, `replay`, `override`, `init_asleep`, `function`, `render_width`, ..., `assets`.
- Shipped benchmarks and their sizes (from the `__init__.py` files):

| name | nworld | nconmax | njmax | notes |
|---|---|---|---|---|
| humanoid | 8192 | 24 | 64 | |
| three_humanoids | 8192 | 100 | 192 | |
| franka_emika_panda | 32768 | 1 | 5 | menagerie asset |
| franka_threading | 8192 | 4096 | 4096 | nccdmax 512, replay, noise_std 0 |
| aloha_pot | 8192 | 24 | 128 | nccdmax 1, replay lift_pot.npz |
| aloha_sdf | 8192 | 32 | 226 | SDF plugin assets |
| aloha_cloth | 256 | 3600 | 6400 | flex cloth |
| aloha_clutter | 2048 | 256 | 384 | SLEEP enabled, init_asleep, nvmax 56 |
| cloth / cloth_render | 256 / 32 | 3600 | 3600 | render 64x64 |
| myoarm | 8192 | 16 | 48 | MyoSim muscles |
| primitives (render) | 8192 | 100 | 256 | function=render, nstep 100 |
| sharpa_wave | 8192 | 48 | 160 | hand grasping mug |
| unitree_g1_flat / _hfield / _hfield_render | 8192 | 48 | 192 | override warn_overflow=~ITERATIONS\|~LS_ITERATIONS |

  (`benchmarks/kitchen/` has no `__init__.py`, so it is not discovered.)
- `run.py`: discovers benchmarks (regex `-f`), assembles assets into `--assets_root /tmp/benchmark_assets` (shallow pinned
  clones via `common.ensure_pinned_clone`), runs `uv run mjwarp-testspeed ... --format=short --event_trace=true --memory=true
  --measure_solver=true --measure_alloc=true`, prints `<name>.<metric> <value>`. `--view` opens `mjwarp-viewer` with
  nworld=1. `--clear_warp_cache` defaults True (so JIT time is cold).
- `sweep.py forward|back [N|sha] [--daily] [--mock]`: checks out each commit, runs every benchmark with `--format=json`, appends
  to `nightly/<name>.jsonl` on the gh-pages branch and updates `commit_range.json` (crash-safe after each commit). `--mock`
  uses nworld=1 nstep=10. This is how the project tracks performance regressions over time (contrib/systemd has the nightly).
- Rules (CONTRIBUTING.md): benchmarks must run with zero overflow and `converged_worlds == nworld`; perf PRs must include
  before/after throughput with identical nworld.

Diagram idea: pipeline "commit -> checkout -> assemble assets -> testspeed json -> jsonl -> gh-pages chart", and a line chart of
steps/s across commits (illustrative, label it as such).

---

## 6. Sizing buffers: nconmax / njmax / overflow (performance-critical)

- All memory is preallocated in `make_data`/`put_data`: `naconmax = nconmax * nworld` (or explicit `naconmax`), `njmax` rows
  per world, `njmax_nnz` (sparse J, default `njmax * nv`), `nccdmax`/`naccdmax`, `nvmax` (island compaction). Defaults come from
  `_default_nconmax(mjm)` / `_default_njmax(mjm)`. The toy model got `naconmax 192` for nworld 4 (48/world) and `njmax 64`.
- Overflow is recorded per world in `d.overflow` (bitmask `types.OverflowType`: NEFC, NJMAX_NNZ, BROADPHASE, NARROWPHASE,
  CCD, HFIELD, CONTACT_MATCH, NVMAX, EPA_HORIZON, ITERATIONS, LS_ITERATIONS, TACTILE) and printed by `wp.printf` from the
  `_next_time` kernel when `m.opt.warn_overflow` has the bit (default `OverflowType.ALL`).
  [RAN on CPU] (e7.py) humanoid with `nconmax=2, njmax=4`: every step printed "nefc overflow - please increase njmax beyond 4",
  "broadphase overflow - please increase nconmax beyond 2 or naconmax beyond 4", "narrowphase overflow ..."; final
  `d.overflow == [13, 12]` -> flags NEFC|BROADPHASE|NARROWPHASE. With adequate sizes (24, 64): `nacon=[16]` total, `nefc=[32, 32]`.
- Trade-off: bigger buffers = more memory and more threads launched over empty rows (many kernels launch over `njmax` or
  `naconmax`), smaller = dropped contacts. Use `mjwarp-testspeed --measure_alloc` to see mean/p95 contacts and constraints and
  size to the p95 plus headroom.
- `warn_overflow` is compiled into the kernel via `wp.static`, so change it before capture.

Animation idea: a bucket per world filling with contact "balls"; the shared contact pool (naconmax) shown as one long bar where
worlds claim slots with an atomic counter; when the pool is full, new balls bounce off and the overflow bit lights up.

---

## 7. Determinism (determinism_test.py, types.DeterminismType)

- GPU atomics (`wp.atomic_add`) accumulate floats in a nondeterministic order, and contacts are appended to the pool in
  nondeterministic order, so by default two GPU runs can differ in the last bits (and then diverge chaotically).
- `m.opt.deterministic` bitmask (`types.DeterminismType`): `CONTACTS` (stable contact ordering via geometric radix sort,
  `collision_driver.collision(..., sort_contacts=True)` path at line ~1307), `CONSTRAINT` (canonical constraint row ordering,
  `constraint.py` ~6446), `ATOMICS` (invariant float atomic reductions), `ALL`. Default `NONE` (`io.py:776`).
- Setter (`types.py: Option.deterministic`): accepts bool (`True` -> ALL), int, or a complement like `~DeterminismType.CONTACTS`
  (masked to valid bits); rejects others. [RAN on CPU] (e7.py): `True -> 7`, `~CONTACTS -> 6`, `99 -> ValueError("deterministic
  must be a DeterminismType bitmask, got 99")`; 3 steps of the humanoid with ALL ran fine.
- How ATOMICS works: kernels containing atomics are factories with a `deterministic` argument; when true they set Warp module
  options `module_options["deterministic"] = wp.DeterministicMode.RUN_TO_RUN` and, for atomics inside dynamic loops,
  `deterministic_max_records` (e.g. `smooth.py: _tendon_armature(nM, enable_sleep, deterministic)` sets it to `nM`; then
  `tendon_armature` calls `_tendon_armature(m.nM if det_atomics else 0, enable_sleep, det_atomics)`). Warp then records atomic
  contributions and reduces them in a fixed order. The kernel analyzer enforces this: `MissingDeterministicFactory` ("contains
  atomic operations but is not enclosed in a kernel factory with a 'deterministic' argument") and
  `MissingDeterministicMaxRecords`.
- `determinism_test.py` discovers all such factories with `inspect`/`ast`, records every launch (patching `wp.launch` and
  `wp.launch_tiled`) to check each factory ran in RUN_TO_RUN mode, runs `_NSTEP = 3` steps `_NREPEAT = 2` times and compares
  every reachable array bitwise (`_bitwise_diff`), and for ATOMICS-only runs replays the first run's contact/constraint row order
  (`_Replay`) so only atomics are tested. `_PHYSICS_FIELDS` lists fields invariant to row order (qpos, qvel, qacc, qfrc_*, ...).
  Worlds are made heterogeneous with `_perturb` (world 1 gets different qvel/ctrl).
- Cost: determinism adds sorting and record buffers; measure it with testspeed `-o "opt.deterministic=ALL"` (override parser
  maps `opt.deterministic` to `DeterminismType`, `io.py:4082`). Do not claim a number.
- CPU runs are effectively deterministic already (serial); the feature matters on GPU (RL reproducibility, debugging).

Animation idea: two GPU "runs" side by side; threads add numbers into one accumulator in shuffled order, the low bits of the
sum flicker differently; switch ATOMICS on and the records are sorted before summing, both sums match.

---

## 8. Differentiability wrapper (diff.py) - perf-relevant facts only

- Module docstring: "MuJoCo Warp kernels are compiled with `enable_backward=False`, so recording API functions on a `wp.Tape`
  would produce wrong gradients". `mujoco_warp/__init__.py` ends with `_differentiable(locals())`, wrapping every public
  function: outside a tape it calls straight through; inside a tape, functions without a registered `AdjointRule` raise.
- In this commit no rules are registered in the library itself (only in `diff_test.py`), so:
  [RAN on CPU] (e4.py) `with wp.Tape(): mjw.step(m, d)` -> `NotImplementedError: Differentiation of 'step' is not supported.`
- `diff.register_adjoint(fn, backward, in_fields=..., out_fields=..., model_fields=..., array_args=..., supported=...)` is
  the extension point; `diff_test.py: test_graph_capture`, `test_finite_difference_jacobian` show capture-compatible usage.
  Probably covered in more depth by another research area; here just note: the wrapper skips the `supported` check while
  capturing (`wp.get_device().is_capturing`), and is a no-op cost-wise when no tape is active.

---

## 9. Writing your own kernel that reads `mjw.Data` (reward / observation / reset)

This is the most practical "build" section for RL-style learners.

**[RAN on CPU]** (e3.py) reward + accumulation captured into the same graph as the physics step:

```python
NW = 4
m = mjw.put_model(mjm); d = mjw.make_data(mjm, nworld=NW)
ball = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "ball")

@wp.kernel
def reward_kernel(
  # Model:
  opt_timestep: wp.array[float],
  # Data in:
  xpos_in: wp.array2d[wp.vec3],
  qvel_in: wp.array2d[float],
  ctrl_in: wp.array2d[float],
  # In:
  body_id: int,
  target: wp.vec3,
  nu: int,
  # Out:
  reward_out: wp.array[float],
):
  worldid = wp.tid()
  dt = opt_timestep[worldid % opt_timestep.shape[0]]   # "*"-batched Model field
  p = xpos_in[worldid, body_id]
  dist = wp.length(p - target)
  ctrl_cost = float(0.0)                               # typed so the loop variable is mutable
  for i in range(nu):
    c = ctrl_in[worldid, i]
    ctrl_cost += c * c
  reward_out[worldid] = (-dist - 0.01 * ctrl_cost) * dt

@wp.kernel
def accumulate(r: wp.array[float], tot: wp.array[float]):
  w = wp.tid()
  tot[w] += r[w]

reward = wp.zeros(NW, dtype=float)       # allocate BEFORE capture
total = wp.zeros(NW, dtype=float)
d.ctrl.assign(np.linspace(-1, 1, NW).reshape(NW, 1).astype(np.float32))   # per-world controls, same array object

def env_step():
  mjw.step(m, d)
  wp.launch(reward_kernel, dim=NW,
            inputs=[m.opt.timestep, d.xpos, d.qvel, d.ctrl, ball, wp.vec3(0.0, 0.0, 0.0), m.nu],
            outputs=[reward])
  wp.launch(accumulate, dim=NW, inputs=[reward, total])

env_step()                               # warm-up compile
with wp.ScopedCapture() as cap:
  env_step()
for _ in range(100):
  wp.capture_launch(cap.graph)
# output: hinge qpos per world [-0.056 -0.019 0.019 0.056] (controls -1..1 differ per world),
#         ball z 0.80 in all worlds, total reward ~ -0.19 per world
```

Guidelines distilled from the source:
- Index Data with `[worldid, element_id]`; index `"*"` Model fields with `worldid % field.shape[0]`.
- Hoist global reads into locals before loops; precompute reciprocals (CONTRIBUTING.md "Global memory traffic").
- Do not guard launches with `if n > 0`; `dim=0` launches are a safe no-op (CONTRIBUTING.md; [RAN] `dim=0` launch ok).
- Keep everything on device: no `.numpy()` inside the per-step function; write episode-done flags into a `wp.array[bool]` and
  use `mjw.reset_data(m, d, reset=mask)` (per-world mask, shape `(nworld,)`, bool or int). [RAN on CPU] (e4.py): mask
  `[True, False, True]` -> `time == [0, 0.1, 0]`.
- For per-world physics randomization: `mjw.put_model(mjm, batch_sizes={"body_mass": nworld})` gives `body_mass` shape
  `(nworld, nbody)` [RAN: `(3, 3)`]; only top-level `"*"` Model fields are accepted (`batch_sizes={"opt.timestep": n}` raised
  `ValueError: Model field 'opt.timestep' is not a batched array field.` [RAN]). For `opt.*` arrays replace the array before
  capture, as the tutorial does: `m.opt.gravity = wp.array([...per world...], dtype=wp.vec3)`. [RAN on CPU] (e4.py) three worlds
  with gravity earth/moon/zero after 50 steps: ball z `[0.952, 0.992, 1.0]`.
- Use `m.callback.control` etc. (`types.py: Callback`) if the custom code must run inside `step` between stages (e.g.
  `step1` calls `m.callback.control(m, d)`); otherwise just launch after `step`.
- For framework interop: `wp.to_torch(d.qpos)` / `wp.from_torch` share memory without copies (standard Warp API; not verified
  here); JAX via `wp.jax_callable(..., graph_mode=wp.JaxCallableGraphMode.WARP)` as in `contrib/jax_unroll.py`, which also sets
  `XLA_FLAGS=--xla_gpu_graph_min_graph_size=1`. `jax_test.py` tests both `graph_conditional=True/False`.

Diagram idea: a grid of worlds (rows) x bodies (columns) for `d.xpos`; the reward kernel highlights column `body_id`, each
thread (one per row) lights up, computes a distance arrow to the target, and drops a number into `reward[worldid]`.

---

## 10. Internal coding conventions (AGENTS.md, CONTRIBUTING.md, kernel_analyzer)

- AGENTS.md just points to CONTRIBUTING.md plus PR style. CONTRIBUTING.md (Code Style & Warp GPU Conventions):
  line length 128, docstrings 100; `_in`/`_out` suffixes; match Model/Data field order; avoid `# kernel_analyzer: off`;
  hoist global reads; precompute reciprocals; no launch guards; parenthesize bitwise/logical expressions in `wp.static`;
  quaternions `(w, x, y, z)` (convert for `wp.transform`); avoid CPU-GPU sync in steps.
- Testing conventions: `test_data.fixture(xml="""...""")`, pre-fill outputs with `wp.inf` / `-1`, parameterize `nworld` 1 and
  2 with heterogeneous worlds, compare against `mujoco.mj_*` with `rtol=atol=1e-5`.
- Kernel analyzer (`contrib/kernel_analyzer/kernel_analyzer/ast_analyzer.py`, CLI `cli.py`, LSP server `lsp_server.py`, VSCode
  `.vsix` up to 0.9.0): AST checks listed as Issue classes: DefaultForbidden, VarArgsForbidden, KwArgsForbidden, MissingType,
  TypeMismatch (against `types.py` field types), InvalidSuffix, InvalidParamOrder, MissingComment, InvalidWrite (writing a
  read-only param), MissingModuleUnique, SharedModuleCustomBlockDim, ParenthesizedArraySyntax, MissingBatchModulo,
  DirectWpArrayForbidden (Model/Data must use `array(...)`), AmbiguousPrecedence, BitwiseInversionInBoolean (`~x` as a
  condition), WarpCallInStatic (no `wp.*` inside `wp.static()`), MissingDeterministicFactory, MissingDeterministicMaxRecords.
  CLI: `python contrib/kernel_analyzer/kernel_analyzer/cli.py mujoco_warp/_src/*.py --types mujoco_warp/_src/types.py
  [--output=github]`. Runs in pre-commit and on PRs.
- `mark_batched(obj)` sets `arr._is_batched = True` on every array whose spec starts with `"*"` or `"nworld"`
  (called at the end of `put_model`, `make_data`, `put_data`, `create_render_context`); metadata for downstream batching
  frameworks (tested in `io_test.py: test_is_batched_metadata`, `io_jax_test.py`).

Course exercise: show the learner's reward kernel "before" (defaults, `wp.array(dtype=float)`, missing modulo) and "after"
(analyzer-clean), with each fix tagged by the Issue class name.

---

## 11. Pitfalls, unsupported things, GPU vs CPU

1. First call is slow (compile). Cold cache: tens of seconds; warm cache (`~/.cache/warp/<version>` on this machine; on Colab
   the same default path, lost when the runtime resets). Warm up before timing, and time with `wp.synchronize()` before stopping
   the clock (launches are asynchronous on GPU).
2. Time without capture measures Python, not the GPU.
3. Replacing arrays after capture silently desynchronizes (verified). Use `.assign`, `wp.copy`, kernels.
4. Changing `m.opt.<python scalar>` (integrator, solver, iterations, flags, deterministic, warn_overflow) after capture has no
   effect on the graph; recapture.
5. `.numpy()`, `print` of arrays, `.item()` inside the captured function: not allowed on CUDA (sync). `wp.printf` in kernels is OK.
6. No allocation inside `capture_while`/`capture_if` bodies; preallocate.
7. `graph_conditional` needs CUDA >= 12.4; JAX paths use `graph_conditional=False`.
8. EventTracer and `mjwarp-testspeed` are GPU-only (verified errors on CPU).
9. Overflow: undersized nconmax/njmax drops contacts/constraints; benchmarks must have zero overflow. testspeed's default
   `--overflow_behavior=error` exits on overflow.
10. float32 everywhere: compare to MuJoCo CPU with tolerances around 1e-5, not exact.
11. Nondeterminism on GPU by default; use `opt.deterministic` when reproducibility matters, at some cost.
12. `wp.Tape` over `mjw.*` raises NotImplementedError unless an adjoint rule is registered.
13. `cache_kernel` keys arrays/TileSets by `.size` only and ignores kwargs: if you write your own factories with it, pass
    scalars positionally.
14. CPU: kernels run serially, so CPU throughput scales linearly down with nworld; CPU is for debugging and for these notebooks'
    "it runs" checks, not for speed. Tiles and graph capture work on CPU in Warp 1.19.
15. Many kernels launch over capacity (`njmax`, `naconmax`), not the live count, and exit early; oversizing buffers costs time.
16. `side_stream` concurrency only exists inside capture; eager runs are serial.
17. README "MuJoCo API Compatibility": `IMPLICITFAST` midpoint not supported, `PGS` solver not supported, noslip not with
    discrete integrator; `put_model` raises NotImplementedError for body/actuator/sensor plugins (except SDF), etc.

---

## 12. Diagram and animation ideas (consolidated, specific)

1. **Thread grid**: a 2D grid, rows = worlds (0..nworld-1), columns = DOFs; `wp.tid()` returns (row, col); animate all cells
   updating `qvel += qacc*dt` simultaneously vs a CPU cursor walking cell by cell.
2. **Memory layout strip**: `d.qpos` as a row-major block `(nworld, nq)`; `m.body_mass` with leading dim 1 broadcasting to all
   rows via `worldid % 1`, then switching to leading dim nworld (randomized) with each row a different color.
3. **Contact pool**: one long `naconmax` bar, worlds append contacts with an atomic counter (`nacon`), color-coded by `worldid`;
   contrast with per-world `efc` rows `(nworld, njmax)`.
4. **Eager vs graph timeline**: top lane CPU (Python) issuing ~100 small launch boxes with gaps; bottom lane GPU busy only in
   thin slivers. Then graph mode: one launch box on CPU, GPU lane packed solid. Slider for nworld that widens GPU boxes.
5. **Capture = record, replay = play**: VCR metaphor; during capture `d.time` stays 0.002, after replays it ticks.
6. **Baked vs live**: graph drawn as a circuit; arrays are sockets (contents can change), Python ifs are soldered switches.
   Animate "assign new ctrl" (signal flows) vs "replace array" (plug pulled, graph still wired to the old socket).
7. **capture_while solver**: worlds as dots, convergence turns them green, counter nsolving decreasing, loop exits at 0.
8. **side_stream fork/join** DAG: `J@search` and `M@search` in parallel lanes merging at `wait_stream`.
9. **Tile cooperation**: 32 threads of a block loading a 64-element row into shared memory, tree reduction for `tile_sum`;
   Cholesky block densify via `tile_load_indexed` gather.
10. **efc_threads_per_world**: GPU drawn as SM slots; as nworld grows, threads per world shrink in steps of 32 so the total stays ~
    `num_waves * block * grid`.
11. **Event trace flame graph** from the nested dict (step > forward > fwd_position > ...).
12. **Overflow bucket** animation (section 6) and **determinism** two-run comparison (section 7).
13. **Throughput chart** the learner fills in: steps/s vs nworld (log-log) for eager and graph; produced live by the notebook.
14. **Benchmark CI pipeline** for sweep.py.

---

## 13. Suggested chapter breakdown (easy -> hard)

1. **Warp in 20 minutes for MJWarp readers**: `wp.array`, dtypes (vec3, quat), `wp.kernel`, `wp.tid`, `wp.launch`, CPU vs CUDA
   device, JIT + kernel cache. Exercise: a kernel that doubles `d.qvel`.
2. **The batched data layout**: nworld axis, `"*"` Model fields and the `% shape[0]` rule, pooled contacts vs per-world
   constraints, `batch_sizes`, per-world gravity. Exercise: domain-randomize body mass.
3. **Why `mjw.step` is ~100 kernels**: walk `forward.py: step/forward/fwd_*`, count launches with a `mock.patch` of `wp.launch`
   (e6.py), read one real kernel (`_next_velocity`) line by line.
4. **CUDA graphs**: `ScopedCapture`, `capture_launch`, baked vs live, the replace-array pitfall, measuring eager vs graph across
   nworld (with the CPU table and a Colab GPU run).
5. **Writing your own kernels against `mjw.Data`**: rewards, observations, done masks, `reset_data(reset=mask)`, all in one
   captured graph; conventions from CONTRIBUTING.md; torch/JAX interop pointers.
6. **Kernel factories, `wp.static`, `cache_kernel`, module options**: specialization, `module="unique"`, `enable_backward=False`.
7. **Tiles and cooperative kernels**: `launch_tiled`, `tile_load/_indexed`, `tile_sum`, `tile_cholesky`; `BlockDim`; build a
   per-world tile reduction.
8. **Conditional graphs and concurrency**: `capture_while` in the solver, `capture_if` for sleep, `graph_conditional`,
   `side_stream`, `efc_threads_per_world`.
9. **Profiling and benchmarking**: `event_scope`/`EventTracer`, `mjwarp-testspeed` flags and outputs, `--measure_alloc`,
   `--measure_solver`, `--memory`; the benchmarks suite, `run.py`, `sweep.py`; tuning nconmax/njmax, solver/iterations
   overrides; overflow flags.
10. **Determinism and code-quality tooling**: `DeterminismType`, RUN_TO_RUN atomics, sorted contacts; how determinism_test
    verifies it; kernel analyzer rules; `diff.py` tape guard. (Can be split into two chapters if the course has room.)

Each chapter's notebook should print its own measured numbers on the Colab GPU rather than quoting fixed throughput figures.
