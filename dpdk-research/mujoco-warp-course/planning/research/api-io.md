# Research notes: api-io (public API, data model, host <-> device I/O)

Source: `mujoco_warp` at commit 8f5b9f1 (Nov 2026). Installed: mujoco-warp 4.0.1, warp-lang 1.19.0, mujoco-core 4.0.1.
All paths are relative to the repo root (`mujoco_warp/...`).
Experiments live in `scratchpad/experiments/api-io/exp1.py ... exp7.py` and ran on **CPU** (`wp.get_device()` -> `cpu`).
Snippets marked **[RAN]** were executed and the printed output is quoted. **[SRC]** means taken from source/tests and not run here.

---

## 0. One-paragraph mental model

MJWarp is MuJoCo re-implemented as Warp kernels. You never write MJCF for MJWarp: you compile MJCF with ordinary
MuJoCo (`mujoco.MjModel.from_xml_string`), then **copy** the compiled host model to device with `mjw.put_model`, and
allocate a device state for **N parallel worlds** with `mjw.make_data` (fresh) or `mjw.put_data` (copy of an
existing `mujoco.MjData`). Every Data array has a leading `nworld` dimension; many Model arrays have a leading
"batch" dimension (default size 1) that is broadcast to worlds with `worldid % shape[0]`. You call
`mjw.step(m, d)` to advance all worlds, and `mjw.get_data_into(mjd, mjm, d, world_id)` to copy one world back
to a `mujoco.MjData` (e.g. for the classic MuJoCo renderer). Contacts live in one big pool shared by all worlds
(`naconmax`); constraints are per-world (`njmax`). Overflows do not crash: they set bits in `d.overflow` and
print a warning from inside the kernel.

```
MJCF XML --mujoco.MjModel.from_xml_string--> mjm (host, float64, numpy)
                                              |                    \
                                   mjw.put_model(mjm)        mujoco.MjData(mjm) = mjd (host)
                                              |                      |
                                   m : mjw.Model (device,        mjw.put_data(mjm, mjd, nworld)  or
                                   float32 warp arrays)          mjw.make_data(mjm, nworld)
                                              \                      |
                                               \-----> mjw.step(m, d) <---- d : mjw.Data (device, nworld x ...)
                                                              |
                                        mjw.get_data_into(mjd, mjm, d, world_id)  -> host MjData (one world)
```

---

## 1. Concepts, simple -> deep (with source locations)

### 1.1 The public surface: `mujoco_warp/__init__.py`
- Users import `import mujoco_warp as mjw`. Everything public is re-exported from `_src/*`.
- Groups of exports (exact names, from `__init__.py`):
  - **I/O** (`_src/io.py`): `put_model`, `put_data`, `make_data`, `get_data_into`, `reset_data`, `reset_data_keyframe`.
  - **Top-level pipeline** (`_src/forward.py`): `step`, `step1`, `step2`, `forward`, `fwd_position`, `fwd_velocity`,
    `fwd_actuation`, `fwd_acceleration`, `fwd_kinematics`, integrators `euler`, `implicit`, `rungekutta4`, `discrete`.
  - **Smooth dynamics** (`_src/smooth.py`): `kinematics`, `com_pos`, `camlight`, `crb`, `factor_m`, `solve_m`, `rne`,
    `rne_postconstraint`, `com_vel`, `subtree_vel`, `tendon`, `transmission`, `flex`.
  - **Collision**: `collision`, `nxn_broadphase`, `sap_broadphase`, `primitive_narrowphase`, `sdf_narrowphase`.
  - **Constraint / solver**: `make_constraint`, `solve`; `island`; `passive`; `inverse`; `deriv_smooth_vel`.
  - **Sensors**: `sensor_pos`, `sensor_vel`, `sensor_acc`, `energy_pos`, `energy_vel`.
  - **Support** (`_src/support.py`): `jac`, `mul_m`, `xfrc_accumulate`, `contact_force`, `get_state`, `set_state`.
  - **Constants** (`_src/set_const.py`): `set_const`, `set_length_range` (`set_const_0`, `set_const_fixed` are marked TODO-remove).
  - **History (delays)**: `init_ctrl_history`, `init_sensor_history`, `read_ctrl`, `read_sensor`, `reset_history`.
  - **Ray / render**: `ray`, `rays`, `render`, `create_render_context`, `get_rgb`, `get_depth`, `get_segmentation`, `refit_bvh`, `refit_splat_bvh`.
  - **Types/enums** (`_src/types.py`): `Model`, `Data`, `Option`, `Contact`, `Constraint`, `Callback`, `RenderContext`,
    `State`, `OverflowType`, `DeterminismType`, `BroadphaseType`, `BroadphaseFilter`, `DisableBit`, `EnableBit`,
    `IntegratorType`, `SolverType`, `ConeType`, `GeomType`, `JointType`, `TrnType`, `DynType`, `GainType`, `BiasType`,
    `CtrlInput`, `CtrlChart`, `ObjType`, `ConDataField`, `RayDataField`, `SetConstGroup`.
- Last line: `_differentiable(locals())` (`_src/diff.py::differentiable`) **wraps every public function** so it can
  participate in a `wp.Tape` with registered adjoint rules. Consequence: `mjw.step` is a wrapper; the original is at
  `mjw.step.__wrapped__` **[RAN]**. README still says Warp differentiability is "not yet available" (issue #500) — treat
  gradients as experimental; do not teach as supported.
- Not exported but useful: `mujoco_warp._src.io.override_model` (string overrides like `"opt.iterations=5"`, used by
  `testspeed`/viewer CLIs), `find_keys`, `make_trajectory`, `load_trajectory`.
- CLIs (pyproject `[project.scripts]`): `mjwarp-testspeed` (`testspeed.py`), `mjwarp-viewer`, `mjwarp-record`
  (need `pip install "mujoco-warp[viewer]"`).
- Runtime deps (pyproject): `absl-py`, `etils[epath]`, `mujoco-core>=4.0.0`, `numpy`, `warp-lang>=1.15`.

### 1.2 Model vs Data vs Option (`_src/types.py`)
- `Model` (`@dataclasses.dataclass class Model`, types.py ~L1226): static description. Mirrors `mujoco.MjModel`
  field names (`nq`, `nv`, `body_mass`, `geom_size`, ...) plus many **warp-only precomputed fields** (e.g.
  `body_tree` = tuple of per-depth body id arrays for level-parallel kinematics, `nxn_geom_pair`, `qLD_*` factorization
  schedules, `block_dim` launch sizes, `has_*` feature flags used to statically prune kernels).
  Size fields (`nq`, `nv`, ...) are plain Python `int`; arrays are `wp.array`.
- `Option` (types.py L1052): physics options. MuJoCo fields (`timestep`, `gravity`, `integrator`, `solver`,
  `iterations`, `ls_iterations`, `disableflags`, `enableflags`, ...) plus **warp-only** fields:
  `impratio_invsqrt`, `broadphase` (NXN / SAP_TILE / SAP_SEGMENTED), `broadphase_filter` (PLANE|SPHERE|AABB|OBB),
  `graph_conditional`, `run_collision_detection`, `run_rne_postconstraint`, `run_qacc_smooth`,
  `contact_sensor_maxmatch`, `warn_overflow`, `deterministic`.
  - Continuous options (`timestep`, `gravity`, `wind`, `magnetic`, `density`, `viscosity`, tolerances,
    `impratio_invsqrt`) are **batched arrays** of shape `(1,)`; discrete ones (`integrator`, `solver`,
    `iterations`...) are Python ints. **[RAN]** `m.opt.timestep -> [0.01] (1,) float32`, `m.opt.gravity.shape -> (1,)` vec3.
  - Discrete options are baked into kernels at launch/compile time (via `wp.static` / `cache_kernel`), so they are
    the same across worlds. Only array options can vary per world.
- `Data` (types.py L2560): dynamic state + all intermediate outputs, every field with leading `nworld`
  (except the contact pool and a few counters). Sub-structs: `d.contact: Contact`, `d.efc: Constraint`.
  Warp-only Data fields: `nworld`, `naconmax`, `naccdmax`, `njmax`, `nvmax`, `nvmax_pad`, `njmax_pad`, `njmax_nnz`,
  `nacon (1,)`, `ncollision (1,)`, `overflow (nworld,)`, flex AABBs, etc.
- `types.array(*dims, dtype)` (types.py L1037) is a **type annotation helper**: dims are ints, size names
  (`"nq"`, `"nworld"`, `"naconmax"`) or `"*"` (= batch dimension, "any nonzero size"). `io._create_array` reads these
  specs to allocate arrays generically — so the docstring shapes in `types.py` are literally the allocation recipe.

### 1.3 put_model (`_src/io.py::put_model`, L619)
Signature: `put_model(mjm: mujoco.MjModel, batch_sizes: dict[str, int] | None = None) -> types.Model`.
Steps, in order:
1. `warp_util.check_toolkit_driver()` — on CUDA, warns if conditional graphs are unsupported (CUDA < 12.4) and tells
   you to set `Model.opt.graph_conditional = False`.
2. Validates `batch_sizes` keys: must be a Model array field whose spec starts with `"*"`, size >= 1
   (else `ValueError("... is not a batched array field.")` / `"must be positive"`; see `io_test.py::test_put_model_batch_sizes_errors`).
3. **Feature checks** — every enum-typed MjModel array is checked against the Warp enum (`TrnType`, `DynType`,
   `GainType`, `BiasType`, `EqType`, `GeomType`, `SensorType`, `WrapType`, `SleepPolicy`); missing values ->
   `NotImplementedError("[names] not supported.")`. Same for `opt.integrator`, `opt.cone`, `opt.solver`
   (`"mjSOL_PGS is unsupported."` **[RAN]**) and disable/enable flag bits.
4. Other hard errors: noslip with discrete integrator; any body/actuator/sensor plugin; flex+contact-sensor linvel/angvel;
   quadratic flex interpolation; **dense jacobian with nv > 60** (`ValueError("Dense is unsupported for nv > 60")` **[RAN]**);
   sleeping requires Newton (`ValueError("sleeping requires the Newton solver (got solver=CG)")` **[RAN]**); several flex combos.
5. Warnings: friction below `MJ_MINMU` with condim >= 3 ("may cause NaN"); bending damping for interpolated shells; `mjNPOLY != 2`.
6. Builds `Option`; **clamps `opt.tolerance = max(tolerance, 1e-6)`** because C MuJoCo's tolerance assumes float64
   (**[RAN]** `1e-10 -> [1e-6]`). Sets warp-only defaults: `broadphase=NXN`, `broadphase_filter=PLANE|SPHERE|OBB`,
   `graph_conditional=True`, `run_collision_detection=True`, `warn_overflow=OverflowType.ALL` (=4095 **[RAN]**),
   `deterministic=NONE`, `run_rne_postconstraint=False`, `run_qacc_smooth=True`,
   `contact_sensor_maxmatch=64` (or from a `<numeric name="contact_sensor_maxmatch">` in the MJCF).
7. Copies every same-named MjModel field, then computes dozens of warp-only derived fields (tree levels `body_tree`,
   `body_subtreenum`, branch lists, `nmaxcondim`, `nmaxpyramid = max(1, 2*(nmaxcondim-1))`, `is_sparse`, `has_fluid`,
   `block_dim` sized from nv, flex/EFM metadata, ...).
8. Allocation: for each array field, `_create_array(value, spec, sizes, batch_size=batch_sizes.get(name, 1))`.
   For batched specs the host value is broadcast to `(batch_size, ...)` (`np.broadcast_to(...).copy()`).
9. `warp_util.mark_batched(m)` sets `arr._is_batched = True` on arrays whose spec starts with `"*"`/`"nworld"`.

`is_sparse(mjm)` (io.py L548): `opt.jacobian == AUTO` -> sparse iff `nv > 32`; else follows `mj_isSparse`.
**[RAN]** nv=13 -> dense; nv=66 auto -> sparse. (C MuJoCo's AUTO threshold differs; MJWarp uses 32.)

### 1.4 make_data / put_data and the sizing parameters (`io.py::make_data` L2638, `put_data` L2856)
Signatures (identical keyword set; `put_data` takes `mjd` too):
```python
mjw.make_data(mjm, nworld=1, nconmax=None, nccdmax=None, njmax=None, njmax_nnz=None,
              naconmax=None, naccdmax=None, nvmax=None) -> mjw.Data
mjw.put_data(mjm, mjd, nworld=1, nconmax=None, nccdmax=None, njmax=None, njmax_nnz=None,
             naconmax=None, naccdmax=None, nvmax=None) -> mjw.Data
```
Meaning (docstrings):
- `nworld`: number of parallel worlds (>= 1, else `ValueError("nworld must be >= 1")` **[RAN]**).
- `nconmax`: contacts **per world** — but only used to size the shared pool: `naconmax = nconmax * nworld`
  (`_resolve_batch_size`). "one world may have more than nconmax contacts".
- `naconmax`: total contacts for all worlds; **overrides** `nconmax`. **[RAN]** `nconmax=10, nworld=4 -> naconmax=40`;
  `naconmax=7 -> 7`.
- `nccdmax` / `naccdmax`: budget for CCD (GJK/EPA convex) contacts; defaults to the contact budget; must be <=.
  **[RAN]** `make_data(nconmax=4, nccdmax=8)` -> `ValueError: naccdmax (8) must be <= naconmax (4)`.
- `njmax`: constraint rows **per world** (hard per-world cap; "no world may have more than njmax constraints").
- `njmax_nnz`: non-zeros in sparse constraint Jacobian; default `_default_njmax_nnz` heuristic when sparse,
  else `njmax * nv`.
- `nvmax`: capacity for compacted active DOFs per world (sleeping/islands); default `nv`; must be in `[0, nv]`.

Default heuristics (`_default_nconmax`, `_default_njmax`, io.py L1969/L1984). Values are rounded up to the
"valid sizes" ladder 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, ... 8192 **[RAN]**:
```
nconmax = max(nv*0.35*(nhfield>0)*10 + 45, 256*has_flex, 64*has_sdf, mjd.ncon if mjd else 0)
njmax   = max(nv*2.26*(nhfield>0)*18 + 53, 512*has_flex, 256*has_sdf, mjd.nefc if mjd else 0)
```
So with no heightfield the defaults are tiny: **nconmax=48, njmax=64** for any rigid model **[RAN]**.
`put_data` additionally takes the max with the host `mjd.ncon` / `mjd.nefc` — which only helps if `mjd` has had
`mj_forward`/`mj_step` run on it (a fresh `MjData` has ncon=0).

Padding (`_get_padded_sizes`): `njmax_pad = round_up(njmax, 16)`; `nv_pad = round_up(nv, 4)` if `nv <= 48` (one-tile
Cholesky), else rounded to the 16-tile with +1 augmented row for Newton. Dense `d.efc.J` is `(nworld, njmax_pad, nv_pad)`
**[RAN]** `(4, 64, 16)` for nv=13.

What `make_data` does beyond allocation:
- `qpos` tiled from `mjm.qpos0`; runs `mujoco.mj_kinematics` once on a temporary MjData to seed `xquat`, `xiquat`,
  and **static geom poses `geom_xpos/geom_xquat`** (comment: static geoms are never updated by the physics loop, so this is
  the only place they are set). `mocap_pos/quat` from `body_pos/quat`; `eq_active` from `eq_active0`.
- Other outputs (e.g. `xpos`) are zero until you call `forward`/`step` **[RAN]** (`xpos[0,1] == [0,0,0]` after make_data).

What `put_data` does differently:
- Validates that the host state fits: `ValueError("nconmax overflow (nconmax must be >= 24)")`,
  `"njmax overflow (njmax must be >= 96)"` **[RAN]**.
- **Mutates the host `mjd`**: it calls `mujoco.mj_kinematics(mjm, mjd)` and, if `mjd.M` is all zero, also
  `mj_comPos, mj_camlight, mj_tendon, mj_crb, mj_factorM`. **[RAN]** `mjd.xpos[1]` was `[0,0,0]` before and `[0,0,1]` after `put_data`.
- Tiles every host field (including contacts and efc rows) across `nworld` and pads contacts to `naconmax`.

### 1.5 Array shapes — the "nworld-first" layout ([RAN] exp1, model nq=15 nv=13 nu=1 nbody=4 ngeom=4, nworld=4)
| field | shape | dtype |
|---|---|---|
| `d.qpos` | (4, 15) | float32 |
| `d.qvel` | (4, 13) | float32 |
| `d.ctrl` | (4, 1) | float32 |
| `d.xpos` | (4, 4) | vec3f -> `.numpy()` gives (4,4,3) |
| `d.xquat` | (4, 4) | quatf (w,x,y,z order as MuJoCo) |
| `d.xfrc_applied` | (4, 4) | spatial_vectorf (6) |
| `d.mocap_pos` | (4, 0) | vec3f (no mocap) |
| `d.sensordata` | (4, 1) | float32 |
| `d.time` | (4,) | float32 |
| `d.nefc`, `d.overflow` | (4,) | int32 |
| `d.nacon` | **(1,)** | int32 — global count across all worlds |
| `d.contact.pos` | **(naconmax,) = (192,)** | vec3f — flat pool, `d.contact.worldid` says which world |
| `d.contact.efc_address` | (192, nmaxpyramid=4) | int |
| `d.efc.J` (dense) | (4, njmax_pad=64, nv_pad=16) | float32 |
| `d.efc.force` | (4, 64) | float32 |
| `m.body_mass` | **(1, 4)** | batched |
| `m.qpos0` | (1, 15) | batched |
| `m.geom_size` | (1, 4) vec3 | batched |
| `m.geom_type` | (4,) | NOT batched (structure) |
| `m.nq` | Python int | |

Key observations to teach:
- Warp arrays use vector dtypes (vec3, quat, mat33, spatial_vector); the numpy view appends the vector dims.
- Everything is **float32** on device (host MuJoCo is float64). `d.time` after 11 steps of 0.01 = `0.10999998` **[RAN]**.
- Structural/integer topology (`geom_type`, `body_parentid`, `jnt_qposadr`, ...) is never batched: all worlds share
  topology. Only numeric parameters (156 fields with `"*"` specs in types.py — inertia, geometry sizes/poses, friction,
  solref/solimp, gains, gear, ranges, camera/light/material params, opt.* arrays) can vary per world.

### 1.6 Per-world model variation (domain randomization)
Mechanism: in kernels, a batched model field is indexed as `field[worldid % field.shape[0], ...]`.
Examples in source: `forward.py::_next_time` uses `opt_timestep[worldid % opt_timestep.shape[0]]`;
`io.py::reset_data.reset_nworld` uses `qpos0[worldid % qpos0.shape[0]]`; `reset_plastic` uses
`qpos_spring[worldid % ...]`.
- Consequence: a batch of size B is applied **round-robin**, not in contiguous blocks. The tutorial notebook says
  "distributes the field's values evenly across worlds" and assigns `model.opt.gravity = wp.array([gravity, -gravity])`
  to "half of the worlds" — **[RAN]** with nworld=4 the per-world ball `qvel_z` after one step is
  `[-0.0981, 0.0981, -0.0981, 0.0981]` (alternating), i.e. even worlds get +g, odd worlds -g.
- Two ways to batch:
  1. Replace the array: `m.opt.gravity = wp.array([...], dtype=wp.vec3)` with any leading size B (B=nworld for
     one-per-world). Test `io_test.py::test_model_batched_fields` does this for every batched field with B=nworld.
  2. Allocate at put time: `mjw.put_model(mjm, batch_sizes={"body_mass": nworld})`, then edit in place with
     `.numpy()` + `.assign(...)` or `wp.copy`. **[RAN]** shape `(4, 4)`. `test_put_model_batch_sizes` shows
     `batch_sizes={"mat_texid": 3, "geom_size": 2, "mat_rgba": 4}`.
- **Derived fields don't update themselves.** After changing mass/inertia/geom size/qpos0/etc call
  `mjw.set_const(m, d, groups=SetConstGroup...)` (`_src/set_const.py::set_const`, docstring has a table of which
  group each field needs: body_mass -> ALL, geom_size -> FIXED, cam/light/eq_data -> KIN0, body_inertia/dof_armature -> INERT0,
  qpos0 -> KIN0|INERT0).
  **Pitfall [RAN]**: if the *output* fields (`body_subtreemass`, `dof_invweight0`, `actuator_acc0`, ...) are still
  batch size 1, `set_const` writes only one value (`body_subtreemass` stayed shape (1,4)). Allocate those derived fields
  with the same batch size too: with `batch_sizes={"body_mass":4,"body_inertia":4,"body_subtreemass":4,"body_invweight0":4,"dof_invweight0":4,"actuator_acc0":4}`
  the result was per-world: `subtreemass[:,3] = [1.53, 3.05, 6.11, 12.21]`, `actuator_acc0 = [7.52, 3.76, 1.88, 0.94]`.
- Mesh swapping per world: `geom_dataid` is batched; `io_test.py::per_world_mesh` (a **test helper**, not public API)
  shows a full recipe using MjSpec tuples, padding bodies to max geom count, compiling variants and filling
  `geom_dataid`, `geom_size`, `geom_rbound`, `geom_aabb`, `body_mass`, ... per world.

### 1.7 Stepping and the pipeline entry points
- `mjw.step(m, d)` = full step for all worlds (`forward.py`). `mjw.forward(m, d)` computes everything except integration
  (time unchanged) **[RAN]** (after `reset_data`, `xpos` is stale; after `forward` it's `[0,0,1]`, time `[0,0]`).
- `step1` / `step2` split the step for control-in-the-loop (same as MuJoCo).
- On CPU: first `step` took ~8.7 s (kernel compile; cached in `~/.cache/warp/<ver>`), then 10 steps of 4 worlds
  took 0.04 s **[RAN]**.
- Accuracy vs C MuJoCo **[RAN]**: 60 steps of the test scene (ball+box on floor, hinge arm): world 2 `qpos` differs
  from `mujoco.mj_step` by max `7.4e-7`; both have `ncon=5`, MJWarp `nefc=20`.

### 1.8 Resetting (`io.py::reset_data` L3484, `reset_data_keyframe` L3921)
- `reset_data(m, d, reset=None)`: `reset` is an optional per-world mask (`wp.array` of bool or int, shape
  `(nworld,)`); wrong shape -> `ValueError("reset array must have shape (4,), got (2,).")` **[RAN]**.
  Resets: `qpos <- qpos0[w % B]`, zero `qvel/act/ctrl/qacc/qacc_warmstart/qfrc_applied/xfrc_applied/sensordata/userdata`,
  `time = 0`, counters `ne/nf/nl/nefc = 0`, `nacon = 0` (world 0 thread), `overflow = 0`, `eq_active <- eq_active0`,
  mocap from body pose, contact reset kernel, history, plastic, and `sleep.update_sleep` if sleeping.
  It does **not** recompute kinematics: derived fields (`xpos`, ...) keep stale values until `forward`/`step` **[RAN]**.
  **[RAN]** mask `[T,F,T,F]` after 5 steps -> `time = [0, 0.05, 0, 0.05]`, ball z `[1.0, 0.985, 1.0, 0.985]`.
- `reset_data_keyframe(m, d, key)`: `key` int (all worlds; must be in `[0, nkey)`) or `wp.array` of ints per world,
  where out-of-range entries (e.g. -1) mean "leave this world untouched". **[RAN]**.
- This is the RL "auto-reset done envs" primitive: compute a done mask on device, pass it in, no host sync needed.

### 1.9 Getting data back (`io.py::get_data_into` L3190)
`get_data_into(result: mujoco.MjData, mjm, d, world_id=0)` copies one world into an existing `MjData`.
- Filters the global contact pool to `contact.worldid == world_id` and contact types CONSTRAINT|PASSIVE (sensor-only
  contacts are dropped), clamps `nacon` to `naconmax` and `nefc` to `njmax` (overflowed rows are not emitted).
- Reorders efc rows so contacts are contiguous after equality/friction/limit rows (MuJoCo convention), reallocates
  `result`'s contact/efc buffers via `mujoco._functions._realloc_con_efc` when counts differ.
- Copies kinematics, sensors, island and sleep arrays, discrete-integrator extras.
- Expensive: it calls `.numpy()` on many device arrays (each is a device->host copy + sync). Fine for rendering a
  video of world 0; do not call it inside a training loop.
- For bulk access just use `d.qpos.numpy()` (whole batch) — cheaper and keeps the batch dimension.

### 1.10 State vectors (`support.py::get_state` L1489, `set_state` L1652)
`get_state(m, d, state: wp.array2d, sig: int, active=None)` / `set_state(...)` pack/unpack MuJoCo `mjtState`
components (`mjw.State.TIME|QPOS|QVEL|ACT|HISTORY|PLASTIC|WARMSTART|CTRL|QFRC_APPLIED|XFRC_APPLIED|EQ_ACTIVE|MOCAP_POS|MOCAP_QUAT|USERDATA`,
combos `PHYSICS`, `FULLPHYSICS`, `USER`, `INTEGRATION`). Size via `mujoco.mj_stateSize(mjm, sig)`. `PLUGIN` unsupported.
**[RAN]** `sig = QPOS|QVEL` -> size 28 (= nq 15 + nv 13), state array `(nworld, 28)`; set_state after reset restored hinge angles.
`active` = per-world mask. Great for snapshot/restore and for MPC rollouts.

### 1.11 Other support utilities (`_src/support.py`)
- `jac(m, d, jacp, jacr, point: wp.array[vec3], body: wp.array[int])` — point Jacobians per world, outputs `(nworld, 3, nv)`-style 3D arrays (either may be None).
- `mul_m(m, d, res, vec, skip=None, M=None)` — `res = M @ vec` per world using the CSR `d.M` (`m.M_mulm_rowadr/entry`) or a dense compact block.
- `xfrc_accumulate(m, d, qfrc)` — maps `d.xfrc_applied` body wrenches to joint space and accumulates.
- `contact_force(m, d, contact_ids, to_world_frame, force)` — 6D force per contact in contact or world frame (decodes pyramidal cone).
- Many `@wp.func` helpers (rods/flex interpolation) are internal.
- `_src/util_misc.py` is all `@wp.func` device helpers used by kernels, not a user API: tendon wrapping
  (`wrap`, `wrap_circle`, `wrap_inside`), muscle curves (`muscle_gain`, `muscle_bias`, `muscle_dynamics`),
  DC-motor helpers, `halton`, `inside_geom`, polynomial springs/dampers, armature/damping totals. Mention only as
  "where the actuator math lives".

### 1.12 Overflow handling (sizing is the #1 practical problem)
- `OverflowType` bitmask (types.py L175): NEFC, NJMAX_NNZ, BROADPHASE, NARROWPHASE, CCD, HFIELD, CONTACT_MATCH, NVMAX,
  EPA_HORIZON, ITERATIONS, LS_ITERATIONS, TACTILE, ALL.
- Detected in kernels, e.g. `forward.py::_next_time_builder` (end of step): `nefc > njmax` -> NEFC per world;
  `ncollision > naconmax` -> BROADPHASE; `nacon > naconmax` -> NARROWPHASE. Also in `collision_convex.py` (CCD, HFIELD),
  `collision_gjk.py` (EPA_HORIZON), `constraint.py::_efc_nnz_overflow` (NJMAX_NNZ), `solver.py` (iterations).
- Behaviour: `wp.printf` a warning (from device, printed asynchronously, e.g. "narrowphase overflow - please increase
  nconmax beyond 4 or naconmax beyond 8"), and `d.overflow[world] |= bit`. Extra contacts/rows are dropped — the
  simulation continues but is **wrong** (missing contacts -> objects sink).
- Bits are **sticky** until `reset_data`. Silence prints with `m.opt.warn_overflow = 0` or
  `m.opt.warn_overflow &= ~mjw.OverflowType.NEFC` (the setter also accepts bool) — bits are still recorded **[RAN]**.
- **[RAN] Starvation demo**: 6 resting boxes, `nworld=2, nconmax=4, njmax=8` -> `naconmax=8`;
  after 3 steps `nacon=[32]`, `ncollision=[12]`, `nefc=[32, 0]`, overflow `[NEFC|BROADPHASE|NARROWPHASE, BROADPHASE|NARROWPHASE]`.
  World 1 got **zero** constraints because the shared pool was exhausted by world 0 — a vivid lesson that contacts are
  shared and per-world fairness is not guaranteed.
- **[RAN] Defaults can overflow**: same 6-box scene with defaults (`nconmax=48 -> naconmax=96`, `njmax=64`):
  `nacon=48` OK but `nefc=[96,96] > 64` -> NEFC overflow. Reason: pyramidal cone, condim 3 -> 4 rows per contact,
  4 contacts per box x 6 boxes = 96 rows.
- Sizing recipe to teach: run the scene in C MuJoCo (or `mjw` with large budgets) to its worst case, read `ncon`/`nefc`,
  add margin; or `put_data` from a representative settled `mjd` (defaults then cover `mjd.ncon/nefc`). Check
  `d.overflow.numpy().any()` periodically. `mjwarp-testspeed --measure_alloc` prints contacts/constraints per step.
- Too-large budgets cost memory and time (kernels launched over `naconmax`/`njmax`), so tune both ways
  (docstring of `_default_nconmax`: "may need to be manually raised ... or lowered in order to get the very best performance").

### 1.13 CUDA graphs and performance model (from notebook + source)
- Notebook cell 13 explains: (1) Warp JIT-compiles kernels on first call (cached across processes);
  (2) `mjw.step` dispatches hundreds of kernels; capture them once with `wp.ScopedCapture()` and replay with
  `wp.capture_launch(capture.graph)`.
- Graph capture freezes array pointers: if you replace `d` or reassign a field with a *new* `wp.array`
  (e.g. `m.opt.gravity = wp.array(...)`, `data.qpos = wp.array(...)`), re-capture. Prefer in-place `.assign()`,
  `wp.copy`, `.fill_()`. (In notebook cell 14 the graph is captured on the same `data` used afterwards — correct.)
- `opt.graph_conditional=True` uses CUDA conditional graph nodes (solver early-exit inside the graph); needs CUDA >= 12.4.
- **[RAN] On CPU in warp 1.19**, `wp.ScopedCapture` does not raise: capture records without executing
  (time stayed 0) and `wp.capture_launch` then runs it (time 0.01). So notebooks with capture code can be
  smoke-tested on CPU, but performance claims only hold on GPU.
- Option `deterministic` (`DeterminismType.CONTACTS|CONSTRAINT|ATOMICS|ALL`) trades speed for bitwise-reproducible results.

### 1.14 override_model (`io.py::override_model` L4065, not exported)
Parses `"opt.iterations=5"`, enum strings (`"opt.cone=elliptic"`, `"opt.broadphase=sap_tile"`,
`"opt.disableflags=contact|spring"`, negation `~`), booleans, vectors `"[0 0 -1]"`. Works on MjModel or mjw.Model and
skips fields that don't exist on that type. **[RAN]** -> `iterations 5, cone 1, broadphase 1, disableflags 48`.
`opt.ls_parallel` raises (removed in 3.9.1).

### 1.15 Tutorial notebook (`notebooks/tutorial.ipynb`) walkthrough
1. Install: `uv pip install "mujoco-warp[viewer] @ git+https://github.com/google-deepmind/mujoco_warp.git"`, `mediapy`; checks `nvidia-smi`;
   writes the NVIDIA EGL ICD json; `%env MUJOCO_GL=egl`; `wp.config.log_level = wp.LOG_WARNING`; validates with
   `mjw.put_model(mujoco.MjModel.from_xml_string('<mujoco/>'))`.
2. Defines a hinge "box_and_sphere" model (timestep 0.01666), simulates 180 steps in C MuJoCo with `mujoco.Renderer`.
3. `model = mjw.put_model(mj_model); data = mjw.put_data(mj_model, mj_data)`; prints `data.qpos` (warp array on `cuda:0`).
4. Same loop with `mjw.step` + `mjw.get_data_into` + renderer (slow first time: JIT + dispatch overhead).
5. `put_data(..., nworld=4096)`, capture `mjw.step` in `wp.ScopedCapture`, replay with `wp.capture_launch`, render world 0.
6. Batched model field: `model.opt.gravity = wp.array([gravity, -gravity], dtype=wp.vec3f)` (round-robin, see 1.6).
7. Batch rendering: `make_data(nworld=16)`, `create_render_context(mjm, nworld=16, cam_res=(128,128), render_rgb=True, render_depth=True, render_seg=True)`,
   randomize `qpos[:,0]`, `mjw.forward`, `mjw.refit_bvh(model, data, rc)`, `mjw.render(model, data, rc)`,
   `get_rgb(rc, camera_index=0, rgb_out=...)`, `get_depth(..., depth_scale=3.5, ...)`, `get_segmentation(...)`, tile into 4x4 grid.
   Note cell uses `data.qpos = wp.array(qpos, dtype=wp.float32)` (replacing the array: fine without graphs).
8. Pointers to Playground, Isaac Lab/Newton, mjlab.

---

## 2. Verified snippets

### 2.1 Hello MJWarp **[RAN]** (exp1/exp2)
```python
import numpy as np, warp as wp, mujoco, mujoco_warp as mjw

XML = """
<mujoco>
  <option timestep="0.01"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>"""
mjm = mujoco.MjModel.from_xml_string(XML)       # host compile
m = mjw.put_model(mjm)                            # device model
d = mjw.make_data(mjm, nworld=4)                  # 4 worlds
for _ in range(60):
    mjw.step(m, d)
print(d.time.numpy(), d.qpos.numpy()[:, 2])        # ball height per world
```

### 2.2 Compare against C MuJoCo **[RAN]**
```python
out = mujoco.MjData(mjm)
mjw.get_data_into(out, mjm, d, world_id=2)
ref = mujoco.MjData(mjm)
for _ in range(60): mujoco.mj_step(mjm, ref)
print(np.abs(ref.qpos - out.qpos).max())   # ~7e-7 (float32 vs float64)
```

### 2.3 Writing inputs in place **[RAN]**
```python
q = d.qpos.numpy(); q[:, 14] = np.linspace(0, 1, 4); d.qpos.assign(q)
wp.copy(d.ctrl, wp.array(np.ones((4, 1), dtype=np.float32)))
d.ctrl.fill_(1.0)
```

### 2.4 Per-world gravity **[RAN]**
```python
g = np.array([0, 0, -9.81], dtype=np.float32)
m.opt.gravity = wp.array([g, -g], dtype=wp.vec3)   # batch of 2, applied as worldid % 2
mjw.reset_data(m, d); mjw.step(m, d)
print(d.qvel.numpy()[:, 2])   # [-0.0981  0.0981 -0.0981  0.0981]
```

### 2.5 Per-world mass + set_const **[RAN]** (exp7)
```python
NW = 4
fields = ["body_mass", "body_inertia", "body_subtreemass", "body_invweight0", "dof_invweight0", "actuator_acc0"]
m = mjw.put_model(mjm, batch_sizes={k: NW for k in fields})
d = mjw.make_data(mjm, nworld=NW)
scale = np.array([1., 2., 4., 8.])
bm = m.body_mass.numpy();    bm[:, 3] *= scale;          m.body_mass.assign(bm)
bi = m.body_inertia.numpy(); bi[:, 3] *= scale[:, None]; m.body_inertia.assign(bi)
mjw.set_const(m, d)
print(m.body_subtreemass.numpy()[:, 3])   # [1.53 3.05 6.11 12.21]
```

### 2.6 Masked reset and keyframes **[RAN]**
```python
mjw.reset_data(m, d, reset=wp.array([True, False, True, False], dtype=bool))
mjw.reset_data_keyframe(m, d, 0)                                   # all worlds -> key 0
mjw.reset_data_keyframe(m, d, wp.array([0, -1, 0, -1], dtype=int)) # -1 = leave world untouched
```

### 2.7 Snapshot / restore **[RAN]**
```python
sig = int(mjw.State.QPOS | mjw.State.QVEL)
st = wp.zeros((d.nworld, mujoco.mj_stateSize(mjm, sig)), dtype=float)
mjw.get_state(m, d, st, sig)
mjw.reset_data(m, d)
mjw.set_state(m, d, st, sig)
```

### 2.8 Overflow demo **[RAN]** (exp3)
```python
boxes = "".join(f'<body pos="{0.25*i} 0 0.09"><freejoint/><geom type="box" size=".1 .1 .1"/></body>' for i in range(6))
mjm = mujoco.MjModel.from_xml_string(f'<mujoco><worldbody><geom type="plane" size="5 5 .1"/>{boxes}</worldbody></mujoco>')
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2, nconmax=4, njmax=8)
for _ in range(3): mjw.step(m, d)
print(d.nacon.numpy(), d.nefc.numpy(), [mjw.OverflowType(int(x)) for x in d.overflow.numpy()])
# [32] [32 0] [NEFC|BROADPHASE|NARROWPHASE, BROADPHASE|NARROWPHASE]
m.opt.warn_overflow = 0     # silence prints (bits still set)
```

### 2.9 CUDA graph capture (GPU idiom; also runs on CPU in warp 1.19) **[RAN on CPU]**
```python
with wp.ScopedCapture() as capture:
    mjw.step(m, d)
for _ in range(1000):
    wp.capture_launch(capture.graph)
```

### 2.10 Errors you will see **[RAN]**
```
solver="PGS"                       -> NotImplementedError: mjSOL_PGS is unsupported.
noslip_iterations + discrete       -> NotImplementedError: noslip solver not implemented for the discrete integrator.
jacobian="dense", nv=66            -> ValueError: Dense is unsupported for nv > 60 (nv = 66).
sleep enabled + CG                 -> ValueError: sleeping requires the Newton solver (got solver=CG)
make_data(nworld=0)                -> ValueError: nworld must be >= 1
put_data(nconmax=2) w/ 24 contacts -> ValueError: nconmax overflow (nconmax must be >= 24)
reset mask of wrong length         -> ValueError: reset array must have shape (4,), got (2,).
```

---

## 3. Data flow between stages
```
host:   MJCF -> MjModel (float64)  ---------------------------- MjData (float64)
              | put_model: validate, derive, float32, batch dim     | put_data: mj_kinematics on host, tile x nworld, pad
device: Model {sizes:int, arrays:(B,...) or (...)}                Data {(nworld,...) arrays, contact pool (naconmax,), efc (nworld,njmax[_pad],...)}
              \_____________________ step(m,d) _____________________/
                 fwd_position (kinematics, com, crb, factor_m, collision -> d.contact pool, make_constraint -> d.efc)
                 fwd_velocity -> fwd_actuation -> fwd_acceleration -> solve -> integrator -> _next_time (overflow check)
host back: get_data_into(one world) | arr.numpy() (all worlds) | get_state (packed vectors)
```
Indexing conventions inside kernels: `worldid = wp.tid()` (or first tid dim); model batch `field[worldid % field.shape[0]]`;
contacts iterate over `nacon[0]` entries of the pool and read `contact.worldid[i]`.

---

## 4. Diagram and animation ideas
1. **"The pipeline conveyor"**: XML file icon -> MuJoCo compiler gear -> MjModel box (CPU, labelled float64) ->
   arrow labelled `put_model` crossing a dashed "PCIe" line -> Model box on GPU (float32). Animate a packet sliding
   across; highlight the clamp `tolerance >= 1e-6` and the feature check as a "customs gate" that can reject PGS / plugins.
2. **Batch dimension stack**: draw `d.qpos` as a stack of N translucent rows (one per world) sliding in like cards; next to it
   `m.body_mass` as a single row with a `(1, nbody)` label. Hover a world row to show which model row it reads.
3. **Round-robin broadcast** (`worldid % B`): 8 world tiles in a line, 2 gravity arrows (down/up). Animate the arrows
   being dealt like cards: world0 down, world1 up, world2 down... Contrast with a crossed-out "first half / second half" picture.
   Slider for B (1..8) recolouring tiles.
4. **Shared contact pool**: one long horizontal bar of `naconmax` slots; worlds as coloured fountains dropping contacts into
   the next free slot (atomic counter `nacon`). When the bar fills, red "overflow" sparks, later worlds' contacts bounce off,
   and world 1's box sinks into the floor. Next to it, per-world `njmax` bars (one per world) filling up — illustrates the
   per-world vs global difference. Toggle "nconmax=4" vs "nconmax=48".
5. **Overflow bitmask panel**: 12 LEDs (NEFC ... TACTILE) per world, lighting up as the demo runs; "sticky" until a reset button clears them.
6. **put_data vs make_data**: split screen; make_data starts from qpos0 with blank xpos (grey), put_data copies a live MjData and
   shows the host MjData's `xpos` flipping from 0 to filled (mutation warning badge).
7. **reset mask**: row of worlds with timers; a boolean mask row slides under them; True worlds snap back to t=0 and qpos0, False keep running.
   Second variant for `reset_data_keyframe` with an int row (0/-1).
8. **get_data_into funnel**: global contact pool with mixed colours filtered by `worldid == k`, efc rows re-ordered so contacts are contiguous,
   poured into a single MjData box, then into `mujoco.Renderer`.
9. **Shape explorer** (interactive table): pick a field, see its spec (`array("nworld","nbody",wp.vec3)`), resolved shape for chosen
   nworld/model sizes, and numpy shape with vector tail dims.
10. **Kernel dispatch vs CUDA graph**: timeline of hundreds of small launch blocks with gaps (CPU launch overhead) collapsing into one solid
    graph block. Show first-call JIT compile as a long "compile" bar that disappears on the second run (cache).
11. **set_const dependency graph**: nodes body_mass/body_inertia/geom_size/qpos0 -> groups FIXED/KIN0/INERT0 -> derived fields
    (subtreemass, invweight0, acc0, aabb/rbound). Animate a change propagating; show the trap where the derived node has batch 1.

---

## 5. Pitfalls, unsupported features, GPU vs CPU
- **Unsupported** (README + put_model checks): PGS solver; noslip with discrete integrator; plugins (body/actuator/sensor);
  `IMPLICITFAST` midpoint feature; flex is experimental (many flex combos raise); dense Jacobian for nv > 60; sleep needs Newton;
  sensor data types AXIS/QUATERNION (types.py comment); State PLUGIN; SetConstGroup SPRING; any enum value missing from the Warp enums.
- **float32 everywhere** on device; expect ~1e-6..1e-7 deviation from C MuJoCo, tolerance clamped to 1e-6, `time` accumulates rounding.
- **Default nconmax/njmax are small** (48/64 for rigid scenes) and can overflow on modest scenes; always check `d.overflow`.
- **Contacts are a shared pool**: one busy world can starve others; `nconmax` is not a per-world guarantee.
- **Overflow is silent-ish**: only a device printf + sticky bits; simulation keeps running with dropped contacts/constraints.
- **put_data mutates the host MjData** (runs `mj_kinematics`, maybe `mj_crb/mj_factorM`).
- **reset_data doesn't recompute kinematics** — call `forward` before reading `xpos`, sensors, or rendering.
- **Static geoms** get their pose only at make_data/put_data; moving a static body via `body_pos` after the fact needs care
  (set_const says body_pos/quat "Unsafe for static bodies (invalidates BVH)").
- **Batched model fields are round-robin** (`worldid % B`), not contiguous blocks; notebook wording "evenly" can mislead.
- **Derived fields** need `set_const` *and* matching batch sizes.
- **Discrete options are global**: `integrator`, `solver`, `iterations`, flags cannot vary per world; changing them changes kernel
  specialization (new compile).
- **Graph capture**: replacing an array object (`m.opt.gravity = wp.array(...)`, `d.qpos = wp.array(...)`) after capture makes the graph
  use the old buffer — re-capture or write in place. Python-side branching on device values is impossible inside a graph.
- **`.numpy()` syncs** the device; avoid per-step host reads in hot loops; `get_data_into` performs dozens of them.
- **First call is slow**: kernel JIT (~9 s on this CPU for a small model; on GPU also seconds) cached under `~/.cache/warp/`.
  On Colab the cache disappears with the runtime.
- **CUDA version**: `check_toolkit_driver` warns if conditional graphs unavailable (CUDA < 12.4) -> set `m.opt.graph_conditional = False`.
- **CPU vs GPU**: everything runs on CPU for debugging (README: "supports CPU for development and debugging"); throughput comes only
  from GPU + many worlds + graphs. `wp.ScopedCapture` on CPU records without executing (warp 1.19).
- `opt.jacobian=AUTO` -> sparse when nv > 32 (MJWarp rule), affects `d.efc.J` layout (dense `(nworld, njmax_pad, nv_pad)` vs sparse
  `(nworld, 1, njmax_nnz)` + `J_rownnz/J_rowadr/J_colind`).
- Friction < `MJ_MINMU` with condim >= 3 triggers a NaN warning at put_model.
- `mjw.*` functions are wrapped by `diff.differentiable`; tracebacks pass through `diff.py::wrapper`.

---

## 6. Suggested chapters for this area (easy -> hard)
1. **What MJWarp is and setting up Colab** — GPU check, install, `mjw.__version__`, `wp.get_device()`, first put_model of `<mujoco/>`, JIT cache.
2. **From MJCF to device: put_model** — MjModel vs mjw.Model, float32, Option and warp-only options, feature validation and errors.
3. **Data, worlds and shapes: make_data / put_data** — nworld-first layout, vector dtypes, `.numpy()`/`.assign()`/`wp.copy`, put_data side effects.
4. **Your first batched simulation loop** — `step`, `forward`, `step1/step2`, comparing with `mujoco.mj_step`, `get_data_into` for rendering a video.
5. **Resets, keyframes and state vectors** — masked `reset_data`, `reset_data_keyframe`, `get_state`/`set_state`, RL auto-reset pattern.
6. **Contacts and constraints memory: nconmax, naconmax, njmax and overflow** — shared pool vs per-world, heuristics, overflow bits, sizing recipe, starvation demo.
7. **Domain randomization with batched Model fields** — round-robin rule, `batch_sizes`, replacing arrays, `set_const` and derived fields, per-world meshes (advanced).
8. **Performance: JIT, CUDA graphs and host-device traffic** — ScopedCapture/capture_launch, graph_conditional, avoiding `.numpy()` in loops, `mjwarp-testspeed`, determinism option.
9. (Bridge to other areas) **Support utilities** — `jac`, `mul_m`, `contact_force`, `xfrc_accumulate`, `override_model` and the CLI tools.
