# MuJoCo Warp from Zero to Expert: Course Plan

Version 3 (architect, after critic round 2; see "Revision log round 2" at the end; "Revision log round 1" uses the
v2 numbering). Source of truth for every chapter author. Library source: `mujoco_warp` at commit 8f5b9f1 (dev tree,
Nov 2026). Installed and verified: `mujoco-warp 4.0.1`, `warp-lang 1.19.0`, `mujoco-core 4.0.1`. Research notes this
plan is built on: `planning/research/{api-io,pipeline,collision,constraint-solver,warp-perf,render-integrations}.md`.
Each chapter names the research note sections it draws from; authors must read those sections before writing.
**Research notes were partly written from the dev tree.** Where this plan and a research note disagree, this plan wins,
and every `_src` name must still be checked against the 4.0.1 wheel (rule W1 below). Numbers quoted as "verified" in
this plan were measured by the critics or the architect on CPU with the 4.0.1 wheel; authors still re-run them and copy
their own output into "Expected output".

---

## Part 0. Course-level design

### 0.1 Audience

- Python programmers who know NumPy. No prior MuJoCo, physics-engine, GPU or CUDA knowledge is assumed in Part I
  (Ch 3 is a from-scratch rigid-body physics primer).
- Robotics / RL practitioners who know classic MuJoCo and want thousands of parallel worlds (they can skim Ch 2-4).
- Simulation engineers who want to understand or extend the internals (dynamics, collision, solver, kernels):
  Parts III-VI. Each Part ends with a non-RL checkpoint project so this audience also synthesizes the material.
- The learner runs everything on **Google Colab Pro with an NVIDIA GPU**. Every example must also run on CPU (Warp's
  CPU device) with small `nworld`; that is how the course is verified. GPU-only examples are guarded (0.4 rule G).

### 0.2 Overall arc (30 chapters in 6 parts)

The user asked for 10-30 chapters. Round 2 uses all 30: it adds a physics primer (Ch 3) and splits the three most
overloaded chapters (islands/sleep vs determinism; CUDA graphs vs profiling/tuning; interop vs gradients/system ID),
and moves soft bodies after the solver chapters.

| Part | Chapters | Level | Theme | Checkpoint project (last section of the Part's last chapter) |
|---|---|---|---|---|
| I. Foundations | 1-7 | beginner (1-6), intermediate (7) | What MJWarp is, MuJoCo basics, rigid-body physics primer, Warp and the GPU, first simulation and seeing it, the batched layout, the pipeline map | "10k bouncing balls dashboard" (Ch 7) |
| II. Driving simulations | 8-10 | intermediate | Resets/state/control/mocap, contacts and buffer sizing, domain randomization | "Robust slide": DR study with buffer sizing (Ch 10) |
| III. Inside the dynamics | 11-14 | advanced | Equations of motion, kinematics and the mass matrix; forces, actuators and springs; integrators; sensors, delays and inverse dynamics | "Inverse-dynamics trajectory tracking for the humanoid arm" (Ch 14) |
| IV. Collision | 15-18 | advanced (15-16), expert (17-18) | Geometry toolkit and broadphase, primitive colliders, GJK/EPA, heightfields and SDFs | "Falling clutter": profile rigid collision paths and fix overflow (Ch 18) |
| V. Constraints, solver and soft bodies | 19-23 | expert | Constraints as optimization (+ math toolkit), CG/Newton, islands and sleep, determinism and reproducibility, flex soft bodies and the discrete integrator | "Cloth on a box stack under a throughput budget" (Ch 23) |
| VI. Performance, extension, integration | 24-30 | expert | CUDA graphs, profiling/benchmarking/tuning, custom kernels, rays and batch rendering, torch/JAX interop, gradients and system ID, RL capstone | Ch 29 ends with the non-RL capstone (parallel system identification); Ch 30 is the RL capstone (cartpole warm-up track + contact-rich humanoid track) |

Dependency spine (prerequisites are always lower-numbered chapters):
1 → 2 → 3; 2 → 4; (3, 4) → 5 → 6 → 7; 7 → 8, 9; (8, 9) → 10; (3, 7) → 11 → 12 → 13 → 14; (9, 11) → 15 → 16 → 17
→ 18; (9, 12) → 19 → 20 → 21; (19, 20) → 22; (13, 16, 19, 20) → 23; (6, 7) → 24 → 25; (4, 24) → 26; (15, 24) → 27;
(24, 26) → 28; (10, 24, 26) → 29; (8, 10, 24, 26, 28 §1-§3) → 30. Ch 29 is optional for the RL track: Ch 30 needs only the torch part of Ch 28.

### 0.3 Deliverables per chapter (file layout)

All paths are under `/home/user/ouramp/dpdk-research/mujoco-warp-course/`.

| Artifact | Path | Notes |
|---|---|---|
| Chapter page | `chapters/NN-slug.html` | One self-contained HTML file (inline CSS/JS/SVG). |
| Example scripts | `examples/NN-slug/exK_short_name.py` | One file per numbered code example; each runs standalone with `python exK_*.py`. Examples that must run in a fresh process (Ch 18 SDF patching) say so in their docstring. |
| Colab notebook | `notebooks/NN-slug.ipynb` | Same examples as cells, plus setup cell, exercises and solutions (collapsed). **Self-contained:** runs top to bottom in a fresh Colab runtime with no other files (see 0.10 for how helper modules are embedded). |
| Running project | `examples/project/my_env.py` (snapshots per chapter: `examples/NN-slug/my_env_stepNN.py`) | A growing helper module that Ch 6, 8, 9, 10, 14, 24, 26 and 30 extend (0.10). |
| Reference pages | `reference/{api-at-a-glance,repo-tour,cheatsheet-part1..6,glossary,troubleshooting,course-map,math-toolkit}.html` | Written by the integrator from the material listed in 0.8-0.10. Chapters link to them. |
| Shared components | `planning/shared-components.html` | Appendix A markup (breadcrumb, pool bar, efc strip, palette, stepper, atlas, replay player, mini3d, world grid). |
| Course home | `index.html` (integrator) | Lists the chapters from `planning/course-plan.json`, links reference pages. |

### 0.4 Coding conventions (all code in pages, scripts and notebooks)

- Imports, always in this order and spelling, with the Warp log level set **right after** `import warp` and before
  the first kernel compile (Warp 1.19 defaults to INFO and prints one "Module ... load" line per module, hundreds per
  first `mjw.step`; `wp.config.quiet` does not exist in 1.19; `record.py` does the same):
  ```python
  import mujoco
  import numpy as np
  import warp as wp
  wp.config.log_level = wp.LOG_WARNING
  import mujoco_warp as mjw
  ```
  Optional extras imported only where used: `mediapy as media`, `matplotlib.pyplot as plt`, `torch`, `jax`. Every
  "Expected output" is captured with the log level set. Ch 4 shows the INFO output once, to explain JIT and caching.
- **Public API first.** Course code calls only names exported by `mujoco_warp/__init__.py` in the **pip 4.0.1** wheel
  (that list includes `fwd_kinematics`, `island`, `flex`, `nxn_broadphase`, `sap_broadphase`, `primitive_narrowphase`,
  `sdf_narrowphase`, `set_const`, `SetConstGroup`, `set_length_range`, `refit_splat_bvh`, `RayDataField`,
  `ConDataField`, `CtrlInput`, `CtrlChart`). `set_const_fixed` and `set_const_0` are exported but deprecated (they emit
  a `DeprecationWarning` and carry `# TODO(team): remove in future version` in `__init__.py`): course code always
  calls `mjw.set_const(m, d, groups=mjw.SetConstGroup.FIXED)` (or `KIN0 | INERT0`) and mentions the aliases only in a
  `.version` note (Ch 10). When an example must touch internals, the page shows a "private API" badge and a one-line
  note that the name may change. Allowed internals (all grepped in the 4.0.1 wheel):
  `_src.io.{override_model, find_keys, make_trajectory, load_trajectory}`,
  `_src.warp_util.{EventTracer, cache_kernel, event_scope, check_toolkit_driver}`,
  `_src.types.{vec6, vec5, Stage, ContactType, EqType, SensorType, Data, Model}`,
  `_src.collision_driver.{MJ_COLLISION_TABLE, MJ_FLEX_COLLISION_TABLE}`,
  `_src.collision_primitive_core.{plane_sphere, sphere_sphere, sphere_capsule, capsule_capsule, plane_capsule, ...}`,
  `_src.collision_sdf.{user_sdf, user_sdf_grad}` (monkeypatch targets only),
  `_src.math.{rot_vec_quat, quat_to_mat, mul_quat, axis_angle_to_quat, quat_integrate}`,
  `_src.diff.{register_adjoint, _wrap, AdjointRule, RULES}`, and the shipped test helpers
  `mujoco_warp.test_data.fixture` and `mujoco_warp.test_data.collision_sdf.utils.register_sdf_plugins`.
- **Rule W1 (wheel grep).** Every `_src` name that an example calls, and every `file.py::name` in a page's Source map,
  must be grepped in the wheel at `scratchpad/venv/lib/python3.13/site-packages/mujoco_warp/`. Names that exist only in
  the dev tree get a `.version` callout ("dev tree only, not in 4.0.1") and are never called. Known dev-only names:
  `warp_util.side_stream`, `warp_util.efc_threads_per_world`, `smooth.kinematics1/kinematics2`,
  `collision_convex.prepare_convex_context`, `collision_driver.prepare_collision_context`,
  `collision_sdf.prepare_sdf_context`, `collision_sdf._sdf_candidates`, `passive.flex_passive_contact`, `sort.py`,
  `render(backend=...)`/OptiX, `mujoco.studio`-based viewer, PID actuators. Known wheel spellings: `smooth.kinematics`
  (launches `_kinematics_branch`), `io.put_model` local variable `nxn_pairid_contact` (not a function), EPA scratch
  allocated inline in `collision_convex.py`, `collision_driver._sort_contacts` and `constraint._sort_constraints` are
  `pass` stubs.
- **Dev tree vs wheel.** Internals may be *read* from the dev tree for explanation, but where the wheel differs the page
  shows a `.version` callout. Never print a snippet that only works on the dev tree without saying so.
- **Standard setup cell (rule S, identical in every notebook; scripts use the same logic in `setup_env()`).** The driver
  is checked *before* installing, so the right Warp build is installed first time and no restart is needed (warp is not
  imported until step 5). Versions are pinned, because `mujoco-warp` only requires `warp-lang>=1.15` and
  `mujoco-core>=4.0.0`:
  ```python
  # 1. Rendering backend must be chosen BEFORE mujoco is imported (rendering notebooks only).
  import os; os.environ.setdefault("MUJOCO_GL", "egl")
  # 2. Driver check: pip warp-lang 1.19.0 is built with CUDA 13.4 and needs an R580+ driver.
  import subprocess
  q = subprocess.run(["nvidia-smi", "--query-gpu=driver_version,name", "--format=csv,noheader"],
                     capture_output=True, text=True)
  print(q.stdout.strip() or "No NVIDIA GPU visible")
  major = int(q.stdout.split(".")[0]) if q.stdout.strip() else 0
  # 3. Pick the Warp build: PyPI (CUDA 13) for R580+, else the verified +cu12 release wheel.
  WARP = ("warp-lang==1.19.0" if major >= 580 else
          "https://github.com/NVIDIA/warp/releases/download/v1.19.0/"
          "warp_lang-1.19.0+cu12-py3-none-manylinux_2_28_x86_64.whl")
  # 4. Install pinned versions ([viewer] pulls glfw + pyopengl + pillow via mujoco-core[rendering]).
  !pip install -q "mujoco-warp[viewer]==4.0.1" "mujoco-core[rendering]==4.0.1" {WARP} mediapy matplotlib
  # 5. Import, quiet the JIT log, verify that Warp itself sees the GPU (otherwise it silently uses CPU).
  import importlib.metadata as md, warp as wp
  wp.config.log_level = wp.LOG_WARNING
  import mujoco, mujoco_warp as mjw
  wp.init()
  ON_GPU = wp.get_cuda_device_count() > 0
  if not ON_GPU:
      print("WARNING: Warp sees no GPU. Runtime > Change runtime type > GPU. Using small CPU budgets.")
  print("device:", wp.get_device(), "| warp", wp.__version__, "| mujoco-core", md.version("mujoco-core"),
        "| mujoco-warp", md.version("mujoco-warp"))
  GRAPH_COND = ON_GPU and wp.is_conditional_graph_supported()
  print("conditional graphs supported:", GRAPH_COND)
  ```
  Pitfalls the setup section of Ch 1 explains: the distribution is `mujoco-core` (not `mujoco`; `md.version("mujoco")`
  raises `PackageNotFoundError`), the import name is still `mujoco`; never also `pip install mujoco` on top (both
  provide the `mujoco` package); if `mujoco` was imported before `MUJOCO_GL` was set, restart the runtime. Rendering
  notebooks additionally write the EGL ICD file from `notebooks/tutorial.ipynb` cell 2 right after step 1. The `+cu12`
  URL was verified to exist (HTTP 302 to release assets, 165,076,358 bytes).
- **Budget block** at the top of every script, so the same file runs fast on CPU and big on GPU:
  ```python
  ON_GPU = wp.get_device().is_cuda
  NWORLD = 4096 if ON_GPU else 8
  NSTEP = 1000 if ON_GPU else 50
  ```
- **Rule G (GPU-only guards).** These fail on CPU and must be guarded, printing a one-line "skipped on CPU: ..."
  message:
  - `warp_util.EventTracer`: construction and an empty block succeed on CPU, but the first `event_scope` inside (for
    example `mjw.step`) raises `RuntimeError: Device cpu is not a CUDA device`. Idiom (the one `_src/cli.py` uses):
    `with EventTracer(enabled=ON_GPU) as t:` (empty trace on CPU) plus a printed skip note.
  - `mjwarp-testspeed` (ValueError "testspeed available for gpu only").
  - `mjwarp-record`: `cli.unroll` runs `with wp.ScopedStream(wp.get_stream())`, which raises `RuntimeError: Device cpu
    is not a CUDA device` on CPU. CPU fallback is the manual render loop (Ch 5 ex11).
  - anything using `wp.get_device().total_memory` (0 on CPU), `capture_while`/`capture_if` timing claims, JAX GPU
    cells (`jax.default_backend() == "gpu"`).
  - **Graph-conditional fallback:** on CUDA < 12.4 (for example the `+cu12` wheel on an old driver)
    `warp_util.check_toolkit_driver` only *warns* and `opt.graph_conditional` stays `True` (io.py). Every capture
    example and `my_env.capture_step` does, before capturing:
    `if wp.get_device().is_cuda and not wp.is_conditional_graph_supported(): m.opt.graph_conditional = False` and
    prints a note.
- **Rule O (optional libraries).** `matplotlib.use("Agg")` in scripts; every optional import (`matplotlib`, `mediapy`,
  `PIL`, `torch`, `jax`) is wrapped in try/except with a printed "skipped: <lib> not installed"; numeric results are
  printed *before* any plotting so "Expected output" never depends on a plot. `mujoco.Renderer` examples use
  `try: r = mujoco.Renderer(...) except Exception as e:` (without PyOpenGL, or with `MUJOCO_GL=egl` and no EGL,
  construction raises `ImportError`, not `RuntimeError`), print the exception class in the skip note, and fall back to
  the MJWarp batch renderer at a small resolution (works on Warp CPU). Pages label output that comes from Colab
  (Renderer, JAX, torch GPU) as "from Colab, not CPU-verified".
- **Verification venv (first integrator step, before any author runs examples).** Install into the course venv:
  `pip install "mujoco-warp[viewer]==4.0.1" matplotlib mediapy pillow` (resolves: matplotlib 3.11.2, mediapy 1.2.7,
  pillow 13.0.0, glfw 2.11.0, PyOpenGL 3.1.10) and **CPU torch**
  `pip install torch --index-url https://download.pytorch.org/whl/cpu` (resolves torch 2.15.0+cpu). Re-run all examples
  after the install so Expected outputs include the plot/save lines. There is no EGL/OSMesa library on the box, so
  Renderer examples use the fallback above when verified.
- **Keyword arguments for long signatures.** `create_render_context`, `make_data`, `put_data` and `register_adjoint`
  are always called with keyword arguments after `mjm` (the repo's own `contrib/render.py` passes `_USE_SHADOWS.value`
  positionally into the `use_fast_math` slot; Ch 27 shows this as a pitfall).
- Sizes: always pass explicit `nconmax`/`njmax` when a scene has contacts, and check `d.overflow.numpy().any()` at the
  end of the example (print "overflow: none" or the decoded `mjw.OverflowType` via `my_env.describe_overflow`).
  `nconmax` is **per world**; `naconmax` is the total over all worlds (io.py docstrings).
- **State buffers:** `mjw.get_state` does not check the size of the destination array; an undersized array is written
  out of bounds silently. Always allocate `wp.zeros((d.nworld, mujoco.mj_stateSize(mjm, sig)), dtype=float)` and assert
  the shape in helpers.
- **Contacts written by user kernels:** never write `d.contact.flex/elem/vert` unless `m.nflex > 0` (they have shape
  `(0,)` otherwise; an out-of-bounds write segfaults the CPU process and silently corrupts GPU memory). While developing
  custom kernels, `wp.config.mode = "debug"` gives bounds checking.
- Timing: warm up once (JIT), call `wp.synchronize()` before reading the clock, report world-steps/s. Never hard-code GPU
  numbers in prose; notebooks print the learner's own numbers. CPU numbers may be quoted only as "on a CPU dev box".
- Never call `.numpy()` inside a hot loop except where the example is about exactly that cost.
- No NaN guard in MJWarp: there is no equivalent of C MuJoCo's `mj_checkPos/Vel/Acc` and no auto-reset
  (`DisableBit` comment: "unsupported: MIDPHASE, AUTORESET"). Long-running examples that can blow up use the
  non-finite reset kernel from Ch 8 ex10.
- Style: 4-space indentation, line length <= 100, f-strings, `np.set_printoptions(precision=4, suppress=True)` at the
  top of scripts that print arrays.
- Each example ends by printing something concrete; the page shows that output in an "Expected output" block, copied
  from an actual CPU run, with a note where GPU output differs (e.g. contact order, timings).
- Never invent API names. If unsure, grep the 4.0.1 wheel and run it.
- `override_model(m, overrides)` mutates in place and returns `None`; it is `mujoco_warp._src.io.override_model`, not
  `mjw.override_model`. It accepts a list of `"opt.x=y"` strings or a dict, and an `mjw.Model` or `mujoco.MjModel`.
- `warn_overflow` is read through `wp.static` inside kernels: changing `m.opt.warn_overflow` after the first launch
  recompiles (knob board, Ch 24).

### 0.5 HTML page conventions (shared skeleton every author follows)

- One file, `<!doctype html>`, `<title>` = "Ch NN · Title", inline `<style>` and `<script>`, no build step.
  Optional CDN libraries, exact versions only: highlight.js 11.9.0 and KaTeX 0.16.9 from cdnjs, Chart.js 4.4.1 from
  cdnjs. Pages must still be readable if CDNs fail (code stays in `<pre><code>`, charts fall back to an inline SVG or
  table).
- Design tokens on `:root` (light) and dark overrides under `@media (prefers-color-scheme: dark)` with
  `:root:not([data-theme="light"])` and `:root[data-theme="dark"]`:
  `--bg, --surface, --text, --muted, --border, --accent, --accent-2, --warn, --danger, --code-bg, --world-0 ...
  --world-7`. Body gets an explicit background. Exact hex values are fixed in Appendix A.4.
- Layout: sticky top bar (course name, "Ch NN of 30", prev/next links `NN-slug.html`, theme toggle); left TOC on wide
  screens, collapsible on phones; content column max 860px; works at 360px width with 16px gutters and no horizontal
  page scroll (wide code and tables scroll inside their own box).
- Required blocks, in order:
  1. hero (title, level badge, prerequisites as links, "you will learn" list, est. time);
  2. **"Before you start: recap"** (3-6 bullets, each linking to the chapter and section that owns the concept, 0.9);
  3. the shared pipeline breadcrumb (Appendix A.1) for Ch 7-23, with the chapter's station(s) highlighted;
  4. sections from the outline, each concept with a figure where listed;
  5. code examples (numbered "Example N.K" with a copy button, a "Run in Colab" note naming the notebook cell, and an
     expandable "Expected output");
  6. callouts (`.note`, `.pitfall`, `.source` with file path and function name, `.version` for wheel/dev differences,
     `.recall` "Recall from Ch N" box when reusing a concept owned elsewhere, `.deeper` collapsible "Going deeper"
     block for expert-only material inside beginner/intermediate chapters);
  7. "Check yourself" quiz widget (multiple choice with instant feedback, at least 6 questions);
  8. exercises: at least 2 auto-checked coding exercises (assert-based, CPU-runnable, increasing difficulty) and one
     open "stretch" exercise;
  9. summary, ending with a "Stuck?" link to `reference/troubleshooting.html` and to `reference/course-map.html`;
  10. "Source map" table (concept → file → function, every row W1-checked).
- Glossary terms are wrapped in `<abbr class="gl" title="one-line definition">` on first use in each chapter (hover
  tooltip, tap on phones) and link to `reference/glossary.html#term`.
- Visual budget per chapter: **at least 4 inline SVG diagrams, at least 2 animations (CSS keyframes or JS/canvas),
  and at least 2 interactive widgets** (sliders, toggles, drag, hover). Animations respect
  `prefers-reduced-motion` (pause by default, play button). All diagrams have `<title>`/`aria-label`.
- **Rule I (input parity).** Every hover interaction also responds to tap (a toggle that pins the readout) and to
  keyboard focus (`tabindex="0"` plus arrow-key navigation on grids and ribbons). Readouts appear in a fixed caption
  line under the figure, not a floating tooltip. Large matrices and mosaics (NXN matrix, output-buffer mosaic, address
  ribbon) get a "focus row" / zoom mode below 640px. The stepper (A.5) stacks figure, controls, pseudo-code and
  variable table vertically below 640px.
- **Rule A (algorithm animations use the stepper).** Any animation of an algorithm (GJK, EPA, SAP, DSU, linesearch,
  Cholesky, ring buffer, RNE sweeps, CSR fill, clipping, solver iterations) uses the shared stepper widget
  (Appendix A.5): Prev / Step / Play / Reset, a scrub slider, a pseudo-code panel whose current line is highlighted and
  named after the real function, and a small variable table. Ambient loops are allowed only for non-algorithmic
  illustration.
- **Rule D (data-driven figures).** A figure that plots numbers "from exN" embeds them as
  `<script type="application/json" id="data-chNN-exK">` written by that example's `--dump-json PATH` flag (every
  example that feeds a figure supports the flag). This includes **trajectory replays** (decimated frames for the world
  replay player, A.7, rounded to 3 decimals, under ~300 KB per figure) and **images**: examples that render write small
  PNGs (`--dump-png DIR`) that the page embeds as base64 data URIs (under 100 KB per chapter). The caption names the
  script, "mujoco-warp 4.0.1, CPU run" and the nworld/nstep. Anything else is labelled "illustrative". JS physics is
  allowed only where interactivity needs it, and is labelled illustrative.
- **Rule 3D.** Every 3-D figure uses the shared `mini3d` helper (A.8) and has a default view that reads well as a
  static image. Per-world tile grids use the shared world grid (A.9).
- Colors: use the `--world-k` palette whenever several worlds appear; green = converged/ok, red = overflow/error.

### 0.6 Shared example models (MJCF)

Every chapter reuses these. They were compiled with mujoco 4.0.1 and stepped with mujoco-warp 4.0.1 on CPU by the
architect (sizes below are measured). Authors paste the ones they need at the top of each script (scripts must stay
standalone). Where a chapter builds a model programmatically it uses `mujoco.MjSpec` (taught in Ch 2).

**M1 `BALL_DROP`** (nq 7, nv 6, ngeom 2) - the "hello world".
```xml
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
```

**M2 `PENDULUM`** (double pendulum; nq 2, nv 2, nu 1, energy enabled, a site, 3 sensors, keyframe).
```xml
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
```

**M3 `PLAYGROUND`** (api-io test scene; nq 15, nv 13, nu 1, ngeom 4; after settling C MuJoCo has ncon 5, nefc 20).
```xml
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <camera name="overview" pos="0.5 -3 1.5" xyaxes="1 0 0 0 0.45 0.9"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/><geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>
```

**M4 `box_stack(n=5, size=0.1)`** (Python function; n=5 gives nv 30, C MuJoCo settles at ncon 20, nefc 80, which
overflows the default njmax=64: the canonical overflow/solver scene).
```python
def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')
```
Ch 2 also shows the equivalent `mujoco.MjSpec` builder `box_stack_spec(n)`; both produce identical sizes.

**M5 `CARTPOLE`** (nq 2, nv 2, nu 1, no contacts, implicitfast; RL capstone warm-up track and control chapters).
```xml
<mujoco model="cartpole">
  <option timestep="0.01" integrator="implicitfast"/>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="front" pos="0 -4 1" xyaxes="1 0 0 0 0 1"/>
    <geom name="rail" type="capsule" fromto="-2 0 1 2 0 1" size=".02" contype="0" conaffinity="0"/>
    <body name="cart" pos="0 0 1">
      <joint name="slider" type="slide" axis="1 0 0" range="-1.8 1.8" limited="true" damping="0.1"/>
      <geom name="cart" type="box" size=".2 .1 .05" mass="1" contype="0" conaffinity="0"/>
      <body name="pole">
        <joint name="hinge" type="hinge" axis="0 1 0" damping="0.01"/>
        <geom name="pole" type="capsule" fromto="0 0 0 0 0 .6" size=".03" mass="0.1"
              contype="0" conaffinity="0"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="slider" gear="10" ctrlrange="-1 1" ctrllimited="true"/></actuator>
  <sensor>
    <jointpos joint="slider"/><jointpos joint="hinge"/>
    <jointvel joint="slider"/><jointvel joint="hinge"/>
  </sensor>
</mujoco>
```
(qpos 0 = pole upright, since the pole points along +z. Swing-up tasks start from `hinge = pi`.)

**M6 `RENDER_SCENE`** (the tutorial's box-and-sphere with a camera, a directional light and a floor).
```xml
<mujoco model="render_scene">
  <option timestep="0.01666"/>
  <worldbody>
    <light name="top" pos="0 0 2" dir="0 0 -1" directional="true"/>
    <camera name="camera" pos="0 2 0" quat="0 0 1 1" resolution="128 128"/>
    <geom name="floor" type="plane" pos="0 0 -.5" size="2 2 .1" rgba=".9 .9 .9 1"/>
    <body name="box_and_sphere" euler="0 0 -30">
      <joint name="swing" type="hinge" axis="1 -1 0" pos="-.2 -.2 -.2"/>
      <geom name="red_box" type="box" size=".2 .2 .2" rgba="1 0 0 1"/>
      <geom name="green_sphere" pos="-.2 -.2 -.2" size=".1" rgba="0 1 0 1"/>
    </body>
  </worldbody>
</mujoco>
```

**M7 `TERRAIN`** (heightfield + sphere, ellipsoid, cylinder, mesh; exercises PRIMITIVE, CONVEX and HFIELD paths;
nv 24; runs in MJWarp with `nconmax=32, njmax=128`, 10 contacts over 2 worlds after 100 steps, no overflow).
**Never combine with a flex:** `put_model` raises `NotImplementedError("Flex-HField collision is not implemented.")`
for any model with a flex and an hfield geom, even with contype=conaffinity=0 (verified).
```xml
<mujoco model="terrain">
  <option timestep="0.005"/>
  <asset>
    <hfield name="bumps" nrow="5" ncol="5" size="1 1 .2 .1"
      elevation="0 0 0 0 0  0 .5 1 .5 0  0 1 0 1 0  0 .5 1 .5 0  0 0 0 0 0"/>
    <mesh name="tetra" vertex="0 0 0  .2 0 0  0 .2 0  0 0 .2"/>
  </asset>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="ground" type="hfield" hfield="bumps"/>
    <body name="ball" pos="0.2 0.1 .6"><freejoint/><geom type="sphere" size=".08"/></body>
    <body name="ellipsoid" pos="-0.3 0.2 .6"><freejoint/><geom type="ellipsoid" size=".1 .07 .05"/></body>
    <body name="cyl" pos="0.3 -0.3 .6"><freejoint/><geom type="cylinder" size=".06 .05"/></body>
    <body name="tetra" pos="-0.3 -0.3 .6"><freejoint/><geom type="mesh" mesh="tetra"/></body>
  </worldbody>
</mujoco>
```

**M8 `HUMANOID`** (shipped with the wheel; nq 28, nv 27, nbody 17, nu 21, nbranch 5, 3 cameras). Load without cloning:
```python
from etils import epath
HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
mjm = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
```
Other shipped test models authors may load the same way (verified present in the wheel):
`test_data/actuation/{actuators,muscle,position,slidercrank,adhesion}.xml`, `test_data/tendon/*.xml`,
`test_data/flex/{rope,floppy,multiflex,moving_base_strain,scene}.xml`, `test_data/hfield/hfield.xml`,
`test_data/collision_sdf/{nutbolt,cow,mesh,scene,tactile}.xml` (**never `torus.xml`**: `torus.obj` is missing from the
wheel), `test_data/convex_collision/box100.xml`, `test_data/primitives.xml`, `test_data/ray.xml`,
`test_data/pendula.xml`, `test_data/collision.xml`, `test_data/constraints.xml`. The repo's `benchmarks/` directory is
**not** in the wheel.

**M9 `scatter(n, seed=0)`** (Python function: n free spheres and capsules dropped in a 4x4 m box over a plane; used for
broadphase scaling in Ch 15 and Ch 25). Written once in Ch 15 (owner) and verified to compile; sizes 0.05-0.1 and
spacing so the scene starts without overlap.

**M10 `MOCAP_TARGET`** (owner Ch 8): a mocap body `target` plus a free box welded to it by
`<equality><weld body1="box" body2="target" solref="0.02 1"/></equality>` over a floor. Used for per-world mocap
targets and per-world `eq_active` toggling (Ch 8, Ch 19). The author compiles it and records nmocap 1, neq 1.

**M11 `cloth(n=6, z=0.3)`** (new; owner Ch 23): a Python function returning a plane, a small `box_stack(2)` and an
`n x n` `<flexcomp type="grid" dim="2">` cloth started ~0.05 above the top box; **no hfield and no SDF geoms** (see
M7). The author compiles it, records nflex 1, nflexvert, and the `nconmax/njmax` that avoid overflow for 300 steps.

### 0.7 Notation and recurring visual metaphors

- "World k" is always drawn in `--world-k` color. Launch geometry is NOT always `nworld x element`: the
  "launch-shape atlas" (Appendix A.6, owner Ch 7) has eight layouts. Ch 7 introduces layouts 1, 2, 6, 7 and 8 (the
  ones the pipeline tour shows); later chapters add theirs when their algorithm is taught (Ch 15: SAP work packages,
  Ch 17: CCD grid-stride, Ch 27: rays), and every chapter that launches a kernel names which layout it uses.
- The **pipeline breadcrumb** (Appendix A.1, introduced as the conveyor belt in Ch 7) appears at the top of Ch 7-23.
- The **shared contact pool bar** (Appendix A.2, owner Ch 9) reappears in Ch 15-18 and 23; the **efc row strip**
  (Appendix A.3, owner Ch 19) in Ch 20-23.
- The **world replay player** (A.7), **mini3d** (A.8) and **world grid** (A.9) are shared components; authors never
  write their own variants.

### 0.8 Glossary (grouped; each term gets a one-line definition in `reference/glossary.html` and a hover `abbr`)

- **MuJoCo:** MuJoCo, MJCF, MjModel, MjData, MjSpec, body, geom, site, joint, DOF, generalized coordinates, qpos/qvel/
  qacc, ctrl, act, mocap body, equality constraint (connect/weld/joint/tendon/flex/flexstrain), keyframe, default class,
  joint limit, solref, solimp, xfrc_applied, qfrc_* family (qfrc_spring, qfrc_damper, qfrc_gravcomp, qfrc_fluid),
  set_const, userdata, geom group, camera mode (fixed, track, trackcom, targetbody, targetbodycom).
- **Physics (primer, Ch 3):** point mass, Newton's second law, explicit Euler, semi-implicit (symplectic) Euler,
  rigid body, 6-DOF state, orientation quaternion, angular velocity, inertia tensor, principal axes, gyroscopic term,
  reduced (joint) coordinates, maximal coordinates, constraint, penetration.
- **Physics (dynamics, Ch 11-14):** equation of motion, mass matrix M, bias force c, spatial vector (rot, trans), com
  frame, cdof, cinert, cvel, crb, RNE, gravity trick, transmission, moment arm, sparse actuator moment, actuator
  dyn/gain/bias, DC motor, polynomial stiffness, actuator damping, plasticity (plastic reference), tendon, wrap, passive
  force, gravcomp, fluid model (inertia box / ellipsoid), integrator (Euler, RK4, implicit, implicitfast, discrete),
  quaternion integration, effective metric, inverse dynamics.
- **Math toolkit (Ch 19-20):** quadratic form, SPD matrix, Cholesky / LDL, convexity, gradient descent, Newton's
  method, conjugate gradient, preconditioner, linesearch, piecewise quadratic, CSR.
- **Warp / GPU:** Warp, kernel, `wp.func`, `wp.tid`, launch dim, SIMT, warp (32 lanes), block, grid, SM, divergence,
  coalescing, shared memory, occupancy, JIT, kernel cache, log level, device, `wp.array`, vec3/quat/mat33/
  spatial_vector, tile, `launch_tiled`, atomics, CUDA graph, `ScopedCapture`, `capture_launch`, conditional node
  (`capture_while`, `capture_if`), `graph_conditional`, grid-stride loop, debug mode.
- **Batching:** world, `nworld`, batched field (`"*"` spec), round-robin batching (`worldid % B`), `put_model`,
  `make_data`, `put_data`, `get_data_into`, state signature (`mjw.State`, PHYSICS, INTEGRATION, WARMSTART), contact
  pool, `nacon`, `naconmax`, `nconmax`, `ncollision`, `naccdmax`, `njmax`, `njmax_nnz`, `nvmax`, overflow bitmask,
  domain randomization.
- **Collision:** broadphase, narrowphase, NXN, SAP, AABB/OBB/bounding sphere, separating axis, contype/conaffinity,
  margin, gap, condim, ContactType, surface velocity, friction cone (pyramidal, elliptic), GeomType, collision table,
  primitive collider, CCD, support function, Minkowski difference, GJK, EPA, horizon, multiccd, heightfield prism, SDF,
  octree SDF, user SDF plugin, Halton sequence, flex, flexcomp, rod.
- **Solver:** efc row, Jacobian J (dense / CSR), `efc.D`, `aref`, impedance, refsafe, impratio, frictionloss, Gauss
  principle, primal solver, CG, Newton, Hager-Zhang, linesearch, warmstart, noslip, ConstraintState, island, DSU, sleep,
  sleep policy, determinism (CONTACTS/CONSTRAINT/ATOMICS), replay testing.
- **Perf / tools / integration:** event_scope, EventTracer, `mjwarp-testspeed`, ctrl noise (`--noise_std`),
  `mjwarp-viewer`, `mjwarp-record`, benchmark suite, render context, BVH, refit, megakernel, planar depth,
  segmentation, Gaussian splat, `wp.to_torch`, `wp.jax_callable`, forward-mode / reverse-mode autodiff, `wp.Tape`,
  adjoint rule, finite differences, CEM, MDP, policy, advantage, PPO.

### 0.9 Concept owners (one home chapter per topic; later chapters use a `.recall` box and extend)

Authors must not re-teach an owned concept or repeat its widget; they use a `.recall` box with the one-line text given
here (or a link) and add only what is new.

| Topic | Owner | Reused (extend, do not re-derive) in | Recall line |
|---|---|---|---|
| Rigid-body state, F=ma, time stepping, inertia tensor | 3 | 10, 11, 13 | "A rigid body has 6 DOF: position + orientation (quat), linear + angular velocity; Ch 3." |
| Quaternion convention (w,x,y,z) | 2 (concept + widget) | 3 (integration), 4 (only the `wp.quat` storage pitfall), 6 (`.recall` only), 13 | "MuJoCo quats are (w,x,y,z); Ch 2 §3." |
| solref/solimp | 2 (intuition) | 10 (DR of solref, `.recall`), 19 (derivation) | "solref = (timeconst, dampratio) of a spring-damper; solimp shapes impedance; Ch 2 §4." |
| Friction cone | 9 (intuition box + SVG) | 19 (math + widget) | "Contact force must lie inside a cone of half-angle atan(mu); Ch 9 §5." |
| Atomics and float nondeterminism | 4 (teaser) | 19 (one-line forward link), 22 (full treatment) | "Float atomics sum in arbitrary order, so low bits can change; Ch 4 §9." |
| GPU execution model (SIMT, warps, blocks, divergence, coalescing) | 4 | 6, 16, 20, 24, 27 | "32 lanes run in lockstep; branches serialize; contiguous reads coalesce; Ch 4 §4." |
| Tiles (`launch_tiled`, `tile_load`, `tile_sum`) | 26 (owner; Ch 4 only a `.deeper` preview) | 11 (`.deeper` tile Cholesky), 20 | "A tiled launch gives each logical index a block of threads that share memory; Ch 26 §6." |
| CUDA graph basics (record/replay, device-side loops) | 7 (teaser) → 24 (owner) | 20 (`capture_while`), 21 (`capture_if`), 25, 26, 27, 30 | "A CUDA graph records launches once and replays them; conditional nodes loop on device; Ch 7 §10." |
| `get_data_into` cost | 5 | 8, 27 | |
| Replace vs assign | 6 | 24 (graph consequence only) | |
| Pipeline stages, breadcrumb, launch-shape atlas | 7 | 8-27 | |
| EventTracer tree | 7 (structure only, guarded) | 25 (profiling workflow) | |
| Control callbacks, step1/step2 | 8 | 26 (callback catalogue; only new callbacks get new examples) | |
| State signatures (PHYSICS, WARMSTART, ...) | 8 | 29 (MPC/CEM snapshots), 30 | "Use State.PHYSICS (+ WARMSTART for bitwise replays); Ch 8 §4." |
| Done-kernel auto-reset | 8 | 26 (captured in a graph), 30 (inside the env) | |
| Parallel-rollout MPC on CARTPOLE | 8 | 29 (CEM extends it) | |
| Mocap and `eq_active` | 8 | 19 (rows appear/disappear; only the efc-strip view is new) | |
| Contact pool, sizing, overflow | 9 | 15-18, 21, 23, 25 | |
| Derived constants and set_const | 10 (plain-language table) | 11-12 (what the quantities mean), 29 | |
| Equations of motion, spatial vectors | 11 | 12, 14, 19, 20 | |
| Mass-matrix factorization, qLD, stale factor | 11 | 7 (one-line pitfall), 13, 20 | "factor_m writes qLD; solving with an old qLD gives wrong qacc; Ch 11 §9." |
| Discrete integrator / effective metric | 23 | 13 (overview + forward link), 19 (regularization, forward link), 20 (best-of-two, forward link) | "DISCRETE solves with an effective metric built from passive stiffness (eff_build/eff_solve); Ch 23 §7." |
| Rays (`mjw.ray`, `mjw.rays`, filters) | 27 | 14 (rangefinder uses `rays` as a black box + forward link) | |
| Math toolkit (GD, Newton, CG, SPD, linesearch) | 19 §2 (section) + `reference/math-toolkit.html` | 20 | |
| reverse-mode autodiff, `wp.Tape` | 29 | 30 (not needed) | |
| torch zero-copy | 28 | 30 (env wrapper owner) | |
| Determinism | 22 | 25 (cost row in the tuning table), 26 (in your kernels) | |

### 0.10 Running project and reference pages

- `my_env.py` grows across the course: Ch 6 adds `make_worlds(xml, nworld)`; Ch 8 adds `reset_done(m, d, done)`,
  `nonfinite_reset` and `snapshot/restore` (State.PHYSICS | WARMSTART, with the size assert); Ch 9 adds
  `describe_overflow(d)`; Ch 10 adds `randomize(m, seed)`; Ch 14 adds `sensor_slices(mjm)` (name → (adr, dim)) used by
  the obs kernels; Ch 24 adds `capture_step(m, d, nsub)` (with the graph-conditional fallback); Ch 26 adds obs/reward
  kernels; Ch 30 turns it into `CartpoleEnv` / `HumanoidStandEnv`.
- **Notebook self-containment.** Colab opens notebooks in an empty `/content`. Every notebook that uses `my_env.py`
  (or Ch 30's `ppo_reference.py`) has an early cell `%%writefile my_env.py` holding the full snapshot for that chapter.
  The integrator generates these cells from `examples/NN-slug/my_env_stepNN.py` (and `ppo_reference.py`) so the two
  cannot drift. Optionally the cell first tries a raw-GitHub download and falls back to the embedded copy.
- Per-Part cheat sheets (integrator assembles from chapter summaries): Part I shape rules and the four calls; Part II
  sizing-parameter ladder and overflow bits; Part III stage → Data map and actuator formula; Part IV collision
  dispatch table and filters; Part V solver knobs, sleep requirements, determinism matrix; Part VI graph
  baked/live table and tuning checklist.
- `reference/api-at-a-glance.html`: the grouped public names listing (moved out of Ch 1), the enum diff and
  "supported?" explorer (moved out of Ch 1, ex7 JSON), the CLI flag tables (`mjwarp-record`, `mjwarp-viewer`,
  `mjwarp-testspeed`).
- `reference/repo-tour.html`: the detailed repository tour (moved out of Ch 1), including `contrib/systemd`
  (nightly benchmark service + timer), `contrib/xml` (Apollo scene), `contrib/render.py`, `contrib/jax_unroll.py` (with
  its stale-code callout), `benchmarks/kitchen/populate_scene.py`, and the `_src/*.py` treemap with line counts
  (`wc -l` at 8f5b9f1 embedded as JSON).
- `reference/troubleshooting.html` (new): organized symptom → cause → fix → owning chapter. Built from the Ch 5 error
  gallery, the Ch 9 overflow decode, the Ch 8 non-finite guard, the Ch 24 knob board and the 0.4 pitfalls: overflow and
  silent dropping; NaN blow-ups without `mj_checkPos`; recompiles when changing ints/static options (incl.
  `warn_overflow`, `ls_iterations`); graph recapture; slow first call; float32 mismatch vs C; Warp silently on CPU;
  `MUJOCO_GL`/EGL order and the `ImportError` from Renderer; driver < 580; CUDA < 12.4 and `graph_conditional`;
  `mjwarp-record` on CPU; SDF plugins registered too late; flex + hfield; `nconmax` per world vs total; undersized state
  arrays; module-load log spam.
- `reference/course-map.html` (new): an interactive pipeline breadcrumb (A.1) where each station links to its owning
  chapter, research file and source files, a Part-by-Part concept map, and a 30-question cumulative quiz that mixes
  Parts. Each Part's last chapter also ends with a "Part review" quiz block (6 questions).
- `reference/math-toolkit.html` (new): CSR storage, Cholesky/LDL, SPD and convexity, gradient descent, Newton, CG,
  linesearch, quaternion algebra, with the NumPy snippets from Ch 3, Ch 11 and Ch 19 §2.

---
## Part I. Foundations

### Chapter 1 - `01-what-is-mujoco-warp` - What Is MuJoCo Warp?

- **Level:** beginner. **Prerequisites:** none. **Research:** api-io §0, §1.1, §1.15; warp-perf §0; render-integrations
  §2.10; README.md ("MuJoCo API Compatibility"); pyproject.toml.
- **Learning objectives**
  1. Describe what a physics simulator does (state in, state out) and where MuJoCo fits.
  2. Explain why GPUs help: many independent worlds simulated by one launch.
  3. Say what NVIDIA Warp is (Python-authored kernels JIT-compiled to CUDA/CPU) and what MJWarp is (MuJoCo rewritten as
     Warp kernels, part of the Newton project, by Google DeepMind and NVIDIA).
  4. Set up Colab correctly: install with the `[viewer]` extra, check the driver, confirm Warp sees the GPU.
  5. Run a first simulation in 1 and 1024 worlds and know where the rest of the course goes.
  6. Name the main unsupported features in plain language (PGS solver, NaN checks/auto-reset, float64, PID actuators,
     some plugins) and know where the full, code-derived list lives (`reference/api-at-a-glance.html`).
- **Outline**
  1. Physics simulation in one picture: state `(qpos, qvel, act, time)` → `step` → next state. (MuJoCo docs overview.)
  2. MuJoCo in 5 minutes: MJCF → compiler → `MjModel` (constants) + `MjData` (state), one world per `MjData`, float64.
  3. Why GPUs: throughput vs latency, batching worlds is embarrassingly parallel (the detailed GPU model is Ch 4).
  4. Warp and MJWarp in one paragraph each; `mjw.step` ≈ 100 kernel launches (warp-perf §0).
  5. Colab setup, the standard setup cell line by line (0.4 rule S): check the GPU first, install pinned versions,
     `[viewer]` extra and why, `wp.config.log_level = wp.LOG_WARNING`, `wp.get_cuda_device_count()`, first-call
     compile cost. Pitfalls: `mujoco-core` distribution name; do not `pip install mujoco` on top. A collapsed
     "Driver troubleshooting" block holds the detail: driver ≥ 580 vs the `+cu12` wheel URL, how to read the
     `nvidia-smi` line, what "Warp sees no GPU" means, the kernel cache directory.
  6. Hello world: `BALL_DROP` in C MuJoCo, then in MJWarp with 1 and then 1024 worlds.
  7. What is not supported, in plain language: the PGS solver (`io.py::put_model` raises
     `NotImplementedError("mjSOL_PGS is unsupported.")`), NaN checks and auto-reset, float64 (float32 only), PID and
     SO3 ball-joint actuators, actuator/sensor/passive plugins (SDF geom plugins work once Warp SDF functions are
     registered, Ch 18), some flex combinations, gradients experimental. One sentence on how this is known: `put_model`
     compares MuJoCo's enums with MJWarp's (types.py comments "unsupported: ..."). The full enum diff is a `.deeper`
     block (ex7) and the searchable explorer lives on `reference/api-at-a-glance.html`.
  8. A short course map (one card per Part) with links to `reference/repo-tour.html` and
     `reference/api-at-a-glance.html`. Version note: dev tree vs pip 4.0.1 and how this course handles it.
- **Code examples**
  1. `ex1_env_check.py` - print `mujoco.__version__`, `md.version("mujoco-core")`, `wp.__version__`,
     `md.version("mujoco-warp")`, `wp.get_device()`, `wp.get_cuda_device_count()`. Prints versions and "cpu" or "cuda:0".
  2. `ex2_empty_model.py` - `mjw.put_model(mujoco.MjModel.from_xml_string("<mujoco/>"))` (tutorial validation trick);
     prints `m.nq, m.nv, m.opt.timestep.numpy()`.
  3. `ex3_ball_c.py` - `BALL_DROP` with `mujoco.mj_step` for 1 s; prints ball z every 0.1 s.
  4. `ex4_ball_mjw.py` - same with `put_model`/`make_data(nworld=1)`/`mjw.step`; prints z and the max difference from
     ex3 (~1e-6, float32).
  5. `ex5_ball_1024.py` - `NWORLD` worlds with random initial heights written via `d.qpos.assign`; prints min/max
     final z and `d.qpos.shape`.
  5b. `ex5b_pendulum_grid.py` - 256 `PENDULUM` worlds (CPU too: 60 decimated frames of 300 steps) with initial angles
     spread over 0.1 rad; prints the angle spread at t = 3 s; `--dump-json` feeds the hero replay.
  6. `ex6_jit_timing.py` - time the first vs second `mjw.step`; prints both times and `wp.config.kernel_cache_dir`.
  7. `ex7_unsupported_enums.py` (`.deeper`; its JSON also feeds the reference-page explorer) - diff
     `mujoco.mjtEnableBit`, `mjtDisableBit`, `mjtDyn`, `mjtGain`, `mjtBias`, `mjtTrn`, `mjtSleepPolicy` member names
     against `mjw.EnableBit`, `DisableBit`, `DynType`, `GainType`, `BiasType`, `TrnType`, `SleepPolicy`; prints the
     unsupported members (e.g. enable: DIAGEXACT, FWDINV, IPC, OVERRIDE, SPECULATIVE; disable: AUTORESET, MIDPHASE;
     dyn/gain: PID; trn: SO3; sleep policy: NEVER, ALLOWED, INIT).
  8. `ex8_unsupported_pgs.py` - `solver="PGS"` in MJCF; catch and print `NotImplementedError: mjSOL_PGS is unsupported.`
- **Visuals**
  - Hero animation (world replay player, A.7): one pendulum swinging on the left; on the right a 16x16 grid of tiny
    pendulums with slightly different initial angles all advancing on the same tick ("one launch, many worlds"). The
    frames are **real MJWarp output**: ex5b dumps 256 `PENDULUM` worlds x 60 frames of hinge angles (Rule D).
  - SVG stack diagram: MJCF file → MuJoCo compiler → MjModel/MjData (CPU, float64) → `put_model`/`make_data` across a
    dashed PCIe line → Model/Data (GPU, float32) → Warp kernels → CUDA. Hover each box for a one-line definition.
  - CPU vs GPU animation: 4 wide cores processing world cards one at a time vs 1024 thin lanes processing all cards in
    one sweep; a speed toggle.
  - Install-stack SVG: `mujoco-warp[viewer]` → `mujoco-core[rendering]` (glfw, pyopengl) + pillow + `warp-lang` (CUDA
    13.4, driver ≥ 580); a red branch "driver < 580 → +cu12 wheel".
  - Ecosystem hub-and-spoke SVG (MJWarp center; MJX/JAX, Playground, Isaac Lab via Newton, mjlab, PyTorch).
  - "What works today" card grid (plain language: solvers, integrators, actuators, plugins, precision), each card
    linking to the reference-page explorer generated from ex7's JSON.
- **Exercises / quiz**: quiz on Model vs Data, float32, what `nworld` means, why the `[viewer]` extra; auto-checked:
  (1) change the ball radius and timestep and assert the predicted landing time within 5%; (2) predict which of 4 MJCF snippets
  `put_model` accepts (PGS solver, RK4 integrator, a PID actuator, an elliptic cone) and assert with try/except; stretch: run ex5 with 65536 worlds on Colab.
- **Notebook**: standard setup cell (with explanation); ex1-ex8; course-map cell linking the reference pages;
  closing cell that prints the learner's environment summary (using `md.version("mujoco-core")`).

### Chapter 2 - `02-mujoco-essentials` - MuJoCo Essentials for MJWarp Users

- **Level:** beginner. **Prerequisites:** 1. **Research:** pipeline §1.1, §3; api-io §1.2; collision §1.2;
  MuJoCo docs (Modeling, Computation overview, Python bindings, MjSpec).
- **Learning objectives**
  1. Read and write MJCF: worldbody, body, joint (free, ball, slide, hinge), geom types, site, actuator, sensor,
     keyframe, option, default classes, joint limits, equality constraints, mocap bodies.
  2. Build the same model programmatically with `mujoco.MjSpec` and compile it.
  3. Map MJCF to `MjModel` sizes (`nq, nv, nu, nactuator` hint, `na, nbody, ngeom, nsite, nmocap, neq, nsensordata`) and
     `jnt_qposadr/jnt_dofadr`.
  4. Explain qpos vs qvel dimensions (free 7/6, ball 4/3, hinge/slide 1/1) and the (w,x,y,z) quaternion convention.
  5. Understand contacts and limits as soft, slightly penetrating constraints governed by solref/solimp (intuition only).
  6. Run `mj_step`/`mj_forward`, reset to keyframes, set `ctrl`, read sensors and body poses; render a frame.
- **Outline**
  1. The two structs: `MjModel` (constant) vs `MjData` (state + derived). MJWarp keeps the same field names.
  2. MJCF anatomy with `PLAYGROUND`: kinematic tree, bodies vs geoms, names and `mj_name2id`, `<default>` classes.
  3. Joints and coordinates: generalized coordinates, `jnt_type` (`mjw.JointType` mirrors `mjtJoint`), qpos/qvel
     address tables, quaternions (w,x,y,z), joint `range`/`limited`.
  4. Geoms and contact basics: `GeomType`, contype/conaffinity, friction, condim, margin; contacts are soft: a small
     penetration is normal, solref (timeconst, dampratio) and solimp at an intuitive level (owner of the intuition;
     the derivation is Ch 19). The physics of *why* contacts are constraints is Ch 3 §8.
  5. Equality constraints: connect, weld, joint, tendon (and flex/flexstrain, Ch 23); `eq_active0`.
  6. Mocap bodies: `mocap="true"` bodies are positioned by `mjd.mocap_pos/mocap_quat`, not by physics; a teleoperated
     target.
  7. Actuators and controls: `ctrl`, gear, ctrlrange; motor vs position actuator; MuJoCo 4 note: `nu` counts control
     inputs, `nactuator` counts actuators (they can differ with multi-input actuators, Ch 12); sensors and
     `sensordata` addressing.
  8. Options: timestep, gravity, integrator, solver, cone, iterations, disable/enable flags.
  9. Simulation loop: `mj_step` = `mj_forward` + integrate; `mj_resetData`, `mj_resetDataKeyframe`.
  10. Derived quantities: `xpos`, `xquat`, `geom_xpos`, `site_xpos`, `subtree_com`, mass matrix via
      `mujoco.mj_fullM(m, d, dst)` (MuJoCo 4: the field is `mjd.M`, not `qM`).
  11. `MjSpec`: `spec = mujoco.MjSpec()`, `spec.worldbody.add_body(...)`, `add_geom`, `add_freejoint`, `spec.compile()`.
  12. Seeing a frame with `mujoco.Renderer` (needs the `[viewer]` extra and `MUJOCO_GL=egl` before import; Rule O
      fallback).
- **Code examples**
  1. `ex1_sizes.py` - load `PLAYGROUND`; print `nq nv nu nbody ngeom nsensordata` (15 13 1 4 4 1) and `nmocap neq`.
  2. `ex2_joint_table.py` - table of joints: name, type, qposadr, dofadr, range; prints the 3-row table.
  3. `ex3_trajectory.py` - step `PLAYGROUND` 200 times, record ball z and box z; prints settle heights (~0.1), then
     saves a PNG plot (Rule O).
  4. `ex4_keyframe.py` - `mj_resetDataKeyframe(mjm, mjd, 0)`; prints qpos before/after.
  5. `ex5_ctrl_sensor.py` - `PENDULUM` with constant `ctrl=2`; prints `sensordata` (q1, v1, tip_pos) every 0.5 s.
  6. `ex6_quaternions.py` - free body orientation: print `xquat`, convert with `mujoco.mju_quat2Mat`, show w-first.
  7. `ex7_contacts_soft.py` - after settling `BALL_DROP`, print `mjd.ncon`, geom pair, `dist` (small negative:
     penetration), normal; then halve the solref timeconst and print the new penetration.
  8. `ex8_limits_defaults.py` - an inline MJCF with a `<default class="limb">` and a limited hinge pushed past its
     range; print qpos (just beyond the limit) and `mjd.nefc`.
  9. `ex9_equality_mocap.py` - `MOCAP_TARGET` (M10): move `mjd.mocap_pos` in a circle for 2 s, the welded box follows;
     print target vs box positions every 0.5 s; then set `mjd.eq_active[0]=0` and print the box falling.
  10. `ex10_mjspec.py` - build `box_stack_spec(3)` with `MjSpec`, compile, compare sizes with the XML `box_stack(3)`;
      prints both size tuples (equal) and `spec.to_xml()[:200]`.
  11. `ex11_mass_matrix.py` - `mujoco.mj_fullM(mjm, mjd, M)` for `PENDULUM`; prints the 2x2 M (used again in Ch 11).
  12. `ex12_render.py` - render `PLAYGROUND` from camera "overview" with `mujoco.Renderer`; saves PNG/GIF and prints
      the image shape; falls back per Rule O.
- **Visuals**
  - Interactive MJCF ↔ tree: XML on the left, body tree SVG on the right; hovering a line highlights the body/geom
    and vice versa (mocap body drawn dashed, equality drawn as a spring link).
  - Joint-type widget: pick free/ball/slide/hinge; an animated body moves along that DOF and shows the qpos/qvel slot
    counts (7/6, 4/3, 1/1); a range slider shows the limit.
  - qpos/qvel strip diagram for `PLAYGROUND` colored by joint, with address arrows from `jnt_qposadr`.
  - Soft-contact SVG: ball slightly sinking into the floor, the penetration exaggerated, a spring-damper icon labelled
    solref (timeconst, dampratio); a slider changes timeconst and the sink depth.
  - Animated `mj_step` loop: forward → integrate → time += dt, with state chips flowing.
  - Mocap replay (A.7 player, Rule D from ex9): the real MJWarp trajectory of the target circling and the welded box
    trailing it; the scrub bar has a marker where `eq_active[0]` is set to 0 and the box falls. An optional
    "drag the target" mode is a JS spring labelled illustrative.
  - **Quaternion card (owner of the convention widget):** (w,x,y,z) with a rotating cube (mini3d, A.8) driven by an
    axis and angle slider; a toggle reinterprets the same four numbers as (x,y,z,w) to show the wrong rotation. Later
    chapters link here instead of drawing their own quaternion widget.
- **Exercises / quiz**: quiz on qpos vs qvel sizes, quaternion order, what `mj_forward` does not do (integrate), mocap
  vs free bodies; auto-checked: (1) compute nq/nv for 2 free bodies + 3 hinges and assert against a compiled model;
  (2) build a 2-link arm with `MjSpec` that the checker compiles and asserts `nq == 2, nu == 1, nsensordata == 3`;
  stretch: add a connect equality that closes a 4-bar linkage.
- **Notebook**: setup (+EGL); ex1-ex12; "build your own model" exercise with the checker.

### Chapter 3 - `03-rigid-body-physics-primer` - Rigid-Body Physics from Scratch: Particles, Rigid Bodies, Joints and Contacts

- **Level:** beginner. **Prerequisites:** 1, 2. **Research:** pipeline §1.4-§1.6 (only the vocabulary); MuJoCo docs
  "Computation" (overview, equations of motion), "Modeling" (joints, contacts); `forward.py::_next_velocity`,
  `_next_position`, `math.py::quat_integrate` (read only, as forward links).
- **Learning objectives**
  1. State Newton's second law for a point mass and simulate a bouncing ball by hand in NumPy with explicit vs
     semi-implicit Euler; see energy drift and why the step order matters.
  2. Describe the 6-DOF rigid-body state: position, orientation (unit quaternion), linear and angular velocity; know why
     the orientation needs 4 numbers but the angular velocity only 3 (the qpos 7 / qvel 6 rule of Ch 2).
  3. Explain mass, center of mass, the inertia tensor and its principal axes (MuJoCo's `body_inertia` diagonal +
     `body_iquat` rotation), and the gyroscopic term `ω × (I ω)`.
  4. Integrate an orientation correctly (quaternion exponential) and see why "add ω·dt to the quaternion" drifts.
  5. Explain joints as *reduced coordinates* (a hinge leaves 1 DOF of 6) vs *maximal coordinates* plus constraints, and
     why MuJoCo uses reduced coordinates for joints but constraints for contacts, limits and equalities.
  6. Explain contacts and limits as constraints that push back when violated, with a little penetration (soft
     contacts), and preview how Part III and Part V turn these ideas into `M qacc + c = tau + J^T f`.
- **Outline**
  1. A point mass: state (x, v), force, F = m a, gravity. Time stepping as "state in, state out" (`.recall` Ch 1 §1).
  2. Explicit vs semi-implicit Euler: the update order `v += a dt; x += v dt` is what MuJoCo's Euler integrator does
     (forward link: `forward.py::_next_velocity`/`_next_position`, Ch 13); energy drift plots; timestep stability.
  3. A bouncing ball with a penalty spring floor (k, b) in NumPy: the spring-damper view of a soft contact
     (`.recall` Ch 2 §4 solref intuition: timeconst ≈ how stiff, dampratio ≈ how bouncy).
  4. A rigid body: 6 DOF; orientation as a unit quaternion (w,x,y,z) (`.recall` Ch 2 §3 for the convention); angular
     velocity ω in world vs body frame; why qpos has 7 entries and qvel 6 for a free joint.
  5. Mass properties: center of mass, inertia tensor, principal axes (`mjm.body_inertia`, `mjm.body_iquat`,
     `mjm.body_ipos`); Euler's rotation equation `I ω̇ + ω × (I ω) = τ` and the gyroscopic term; the intermediate-axis
     (tennis-racket) instability as an illustration.
  6. Integrating orientation: `q ← q ⊗ exp(ω dt / 2)` (MJWarp: `math.quat_integrate`, used by `_next_position` for
     free and ball joints; owner of the widget is Ch 13) vs naive addition + renormalize.
  7. Joints and reduced coordinates: a pendulum written in Cartesian coordinates with a rod constraint vs in one angle;
     joint types and their DOFs (`.recall` Ch 2 §3); bodies in a tree.
  8. Constraints: contacts (one-sided, with friction), joint limits (one-sided), equalities (two-sided); "soft"
     constraints allow a small violation; what Ch 9 (contacts), Ch 11 (equation of motion) and Ch 19 (constraint
     solver) will add.
  9. Bridge to MuJoCo: the same quantities in `MjModel`/`MjData` (`body_mass`, `body_inertia`, `xpos`, `xquat`,
     `cvel`, `qvel`), and the generalized-coordinates preview `M(q) qacc + c(q, qvel) = tau + J^T f` (owner Ch 11).
- **Code examples**
  1. `ex1_point_mass.py` - NumPy point mass under gravity, explicit vs semi-implicit Euler for 2 s at dt 0.01; print
     final height vs the analytic `z0 - g t^2 / 2` and the energy error of each method.
  2. `ex2_spring_oscillator.py` - 1-D mass-spring with dt in {0.01, 0.05, 0.2}; print the max energy ratio for explicit
     and semi-implicit Euler (explicit grows, semi-implicit stays bounded); `--dump-json` feeds the phase-portrait
     figure.
  3. `ex3_bouncing_ball_numpy.py` - ball on a penalty floor (k, b chosen from a timeconst and dampratio); print bounce
     heights and the max penetration; then the same `BALL_DROP` in C MuJoCo and MJWarp (1 world) and print their max
     penetration next to the NumPy value (same order of magnitude, different model).
  4. `ex4_rigid_body_state.py` - a free box in MuJoCo: print `nq`, `nv`, `qpos[3:7]` (unit quaternion), `qvel[3:6]`,
     `mjm.body_mass`, `body_inertia`, `body_iquat`; verify `body_inertia` for a box against `m(b²+c²)/12` etc.
  5. `ex5_inertia_tensor.py` - build the full 3x3 inertia tensor of an L-shaped two-geom body by hand (parallel-axis
     theorem), diagonalize it with NumPy, and compare eigenvalues/axes with `mjm.body_inertia`/`body_iquat`; print both.
  6. `ex6_quat_integrate.py` - spin a quaternion with constant ω for 1000 steps: exact exponential update vs "add and
     renormalize"; print the angle error of each and the norm before renormalization.
  7. `ex7_tennis_racket.py` - a free box with three different principal moments spun about the intermediate axis,
     gravity off, in MJWarp (8 worlds with slightly different spins); print the time of the first flip per world and
     the conserved kinetic energy; `--dump-json` feeds the replay figure.
  8. `ex8_pendulum_two_ways.py` - a pendulum as (a) a point mass with a stiff rod spring in Cartesian NumPy and (b) a
     1-DOF hinge in MuJoCo; print the period from both and the rod-length drift in (a).
  9. `ex9_contact_as_constraint.py` - `BALL_DROP` settled in MJWarp: print `d.qfrc_bias[2]` (gravity), the contact
     normal force from `mjw.contact_force`, their balance, and the small penetration `contact.dist` (link to Ch 9).
  10. `ex10_preview_eom.py` - `PENDULUM` in C MuJoCo: print `M` (via `mj_fullM`), `qfrc_bias`, `qfrc_actuator`, `qacc`
      and the residual of `M qacc + c - tau` (≈ 0 without contacts); the page labels this "you will derive this in
      Ch 11".
- **Visuals**
  - Free-body diagram builder (interactive SVG): a block with draggable force arrows (gravity, push, normal); the
    resulting acceleration arrow updates (F = m a).
  - Phase-portrait animation (canvas, Rule D from ex2): explicit Euler spirals out, semi-implicit stays on a closed
    loop; dt slider switches between the dumped runs.
  - Bouncing-ball "penalty spring" animation: the floor drawn as a spring-damper under the ball, compressing on
    impact; sliders for timeconst and dampratio (JS, labelled illustrative) next to the real NumPy trace from ex3.
  - Rigid-body state card: a cube (mini3d, A.8) with its body frame, the 7 qpos and 6 qvel slots below it; hovering a
    slot highlights what it moves.
  - Inertia ellipsoid widget (mini3d): sliders for the three principal moments and the body rotation; the ellipsoid
    and principal axes rotate with the body; readouts of `body_inertia` and `body_iquat`.
  - Tennis-racket replay (A.7 player, Rule D from ex7): 8 worlds of the spinning box flipping at different times.
  - Quaternion drift chart (SVG, Rule D from ex6): angle error vs step for exact vs naive update.
  - Reduced vs maximal coordinates diagram: a pendulum drawn twice, "x, y + rod constraint" vs "θ", with DOF counters.
  - Constraint gallery SVG: contact (one-sided + friction cone sketch), joint limit (one-sided stop), weld (two-sided),
    each with "what happens when violated" arrows.
- **Exercises / quiz**: quiz on qpos/qvel sizes for a free body, why semi-implicit Euler is preferred, what the
  gyroscopic term does, which constraints are one-sided; auto-checked: (1) implement semi-implicit Euler for a
  projectile with drag and assert the landing distance within 2% of a fine-dt reference; (2) compute the inertia
  tensor of a solid cylinder about its center and assert it against `mjm.body_inertia` of a compiled model; stretch:
  add a second ball and a ball-ball penalty contact to the NumPy simulator.
- **Notebook**: setup; ex1-ex10; interactive matplotlib phase portraits; a "your own physics engine in 40 lines" cell
  that is compared with MJWarp in the last cell.

### Chapter 4 - `04-warp-and-the-gpu` - NVIDIA Warp and How a GPU Runs Your Kernel

- **Level:** beginner (est. 2.5 h; tiles and factories are optional `.deeper` blocks). **Prerequisites:** 1, 2. **Research:** warp-perf §1.1-§1.6, §2.5, §9; api-io §1.5; CUDA
  programming-model concepts (SIMT).
- **Learning objectives**
  1. Create and move `wp.array`s (dtype, shape, device), convert to/from NumPy, and understand vector dtypes
     (`wp.vec3`, `wp.quat`, `wp.mat33`, `wp.spatial_vector`) and their trailing NumPy dims.
  2. Write `@wp.kernel`s and `@wp.func`s, use `wp.tid()` in 1D and 2D, and launch with `dim=(nworld, n)`.
  3. Explain the GPU execution model: thread → warp of 32 lanes (SIMT) → block → grid, SMs, divergence, memory
     coalescing, shared memory, occupancy; and what changes on Warp's CPU device.
  4. Understand JIT compilation and caching (and why the course sets `wp.config.log_level`); `wp.static`
     compile-time branches as a short preview.
  5. Use atomics and know (teaser) why float atomics are order-dependent.
  6. Time GPU code correctly (`wp.synchronize`, `wp.ScopedTimer`).
  7. (`.deeper`, optional) Preview tiles with `wp.launch_tiled`; the owner is Ch 26.
  8. Read a real MJWarp kernel (`forward.py::_next_velocity`) line by line.
- **Outline**
  1. Devices: `wp.get_device()`, `"cpu"` vs `"cuda:0"`, `wp.ScopedDevice`.
  2. Arrays: `wp.zeros/ones/empty/array`, `.numpy()` (a copy + sync), `.assign`, `wp.copy`, `.fill_`, `.zero_`,
     shapes of vector dtypes (warp-perf §1.1).
  3. Kernels and threads: `@wp.kernel`, typed params, `wp.tid()`, `wp.launch(kernel, dim, inputs, outputs)`;
     `dim=0` is a safe no-op (warp-perf §9).
  4. **How a GPU runs your kernel:** SIMT warps of 32 lanes, blocks and grids, SMs and waves, divergence (both branch
     sides execute with lanes masked), coalesced vs strided access (why MJWarp is nworld-first), shared memory,
     occupancy; CPU device runs threads in a loop and MJWarp forces `block_dim` 1 there (smooth.py `BLOCK_DIM` per
     device). Forward links: per-type-pair kernels (Ch 16), nworld-first layout (Ch 6), solver thread sizing (Ch 20).
  5. Device functions: `@wp.func`, returning values, MJWarp's `math.py` helpers.
  6. Quaternion storage pitfall only (`.recall` Ch 2 §3 for the convention itself): Warp's `wp.quat` storage vs
     MuJoCo (w,x,y,z); MJWarp stores (w,x,y,z) in `wp.quat`
     slots and uses its own `math.rot_vec_quat`/`quat_to_mat` (CONTRIBUTING.md). Pitfall callout.
  7. Compile-time specialization: `wp.static(...)` in one short example; kernel factories, `module="unique"` and
     `enable_backward=False` are a `.deeper` block that forward-links to Ch 26 (owner of `cache_kernel`).
  8. JIT and caching: module hashing, kernel cache dir, first-call cost. The one place the course shows Warp's INFO
     log ("Module ... load on device 'cpu' took ... (cached)") and then sets `wp.config.log_level = wp.LOG_WARNING`
     (0.4).
  9. Atomics: `wp.atomic_add`; teaser that float sums depend on order (full treatment Ch 22).
  10. Timing: asynchronous launches, `wp.synchronize()`, `wp.ScopedTimer`.
  11. `.deeper` "Tiles preview": `wp.launch_tiled` launches `block_dim` threads per logical index that cooperate
      through shared memory; `wp.tile_load`, `wp.tile_sum`, `wp.tile_store` (warp-perf §1.6). Owner: Ch 26 §6.
  12. Reading MJWarp: `_next_velocity` with the `# Model: / # Data in: / # Out:` conventions and
      `opt_timestep[worldid % opt_timestep.shape[0]]`.
- **Code examples**
  1. `ex1_arrays.py` - create float and vec3 arrays; print `.shape`, `.dtype`, `.numpy().shape` ((4,3) vs (4,3,3)).
  2. `ex2_saxpy.py` - first kernel `y = a*x + y` on 1M elements; prints first 3 values and the max error vs NumPy.
  3. `ex3_grid_2d.py` - 2D kernel over `(nworld, ndof)` writing `worldid*100 + dofid`; prints the array.
  4. `ex4_func.py` - `@wp.func` that rotates a vec3 by a quaternion using `mujoco_warp._src.math.rot_vec_quat`
     (private badge) vs `mujoco.mju_rotVecQuat`; prints both results (equal).
  5. `ex5_quat_pitfall.py` - the same quaternion passed to `wp.quat_rotate` with MuJoCo ordering gives a different
     answer; prints both and explains.
  6. `ex6_divergence.py` - a branchy kernel (8 cases selected by `tid % 8`) vs 8 specialized launches; prints times
     (GPU shows the cost; CPU prints both and notes that divergence is a GPU effect).
  7. `ex7_coalescing.py` - sum over a `(nworld, n)` array with consecutive threads on the contiguous axis (coalesced)
     vs on the strided axis; prints both times on GPU (CPU: prints and explains cache effects instead).
  8. `ex8_static.py` - kernel factory with `wp.static(flag)`; prints results for both specializations and the number of
     modules compiled.
  9. `ex9_atomics.py` - parallel sum via `wp.atomic_add` vs NumPy sum in float32; prints both and the difference (on GPU
     rerun twice to see last-bit changes).
  10. `ex10_timing.py` - time a kernel without and with `wp.synchronize()`; prints both.
  11. `ex11_tile_sum.py` (`.deeper`) - per-world tile reduction (warp-perf §1.6 snippet); prints
      `[2016, 6112, 10208, 14304]`.
  12. `ex12_jit_log.py` - the same tiny kernel run with the default INFO log level and then with `wp.LOG_WARNING`;
      prints the number of "Module" log lines captured in each case (many vs 0).
- **Visuals**
  - Thread-grid animation: rows = worlds, columns = DOFs; "launch" lights all cells at once vs a CPU cursor walking
    cell by cell; hovering a cell shows `wp.tid() -> (worldid, dofid)`.
  - **GPU anatomy SVG:** SMs as boxes, each with warps of 32 lanes and a shared-memory tile area; registers per lane.
  - **Block scheduling widget:** sliders for `block_dim` and `nworld`; blocks are assigned to 8 SMs in waves (animated);
    a CPU-mode toggle shows `block_dim` forced to 1 and one thread at a time.
  - **Divergence animation (stepper, Rule A):** a warp of 32 lanes hits an if/else; lanes for the other branch grey out
    while one side runs, then swap; counter of wasted lane-cycles; toggle "specialized kernels" removes the waste.
  - **Coalescing ribbon:** 32 lanes reading addresses from a byte strip, contiguous (one transaction) vs strided (many),
    hover-linked to ex7.
  - JIT pipeline animation: Python function → AST → generated C++/CUDA → compiler (NVRTC/LLVM) → cached binary;
    second call jumps straight to the cache.
  - Atomic race animation: 8 threads adding into one accumulator in shuffled orders; low bits flicker between runs.
  - Quaternion storage strip (static SVG, not a second convention widget): the four `wp.quat` slots labelled with
    what Warp's own `wp.quat_rotate` expects vs what MJWarp stores, with a link to the Ch 2 quaternion card.
  - Annotated code figure of `_next_velocity` with hover callouts.
- **Exercises / quiz**: quiz on `wp.tid()` shapes, `.numpy()` cost, why `wp.static`, what a warp is, why divergence
  costs; auto-checked: (1) kernel that clamps a `(nworld, nu)` ctrl array to [-1, 1]; (2) kernel computing per-world
  kinetic energy of point masses, asserted vs NumPy; stretch: a tiled per-world max (after reading the `.deeper` tiles preview).
- **Notebook**: setup; ex1-ex12; exercises with asserts; "GPU vs CPU" cell that reruns ex2/ex6/ex7 on both devices when
  CUDA is available.

### Chapter 5 - `05-first-simulation` - Your First MJWarp Simulation (and How to See It)

- **Level:** beginner. **Prerequisites:** 3, 4. **Research:** api-io §1.3, §1.4, §1.7, §1.9, §2.1-§2.2, §2.10, §5;
  pipeline §0; render-integrations §0, §1.1, §1.12, §2.1, §5.
- **Learning objectives**
  1. Use `put_model`, `make_data`, `put_data`, `step`, `forward`, `get_data_into` correctly.
  2. Explain conceptually what `put_model` does: convert to float32 GPU arrays, validate features, add warp-only options.
  3. Know the side effects: `put_data` mutates the host `MjData`; `make_data` leaves derived fields zero until
     `forward`.
  4. Compare MJWarp with C MuJoCo and interpret float32 differences and chaotic divergence.
  5. Read and change `m.opt` (array vs int fields).
  6. See one world: `get_data_into` → `mujoco.Renderer` frames and videos (or the batch renderer fallback), and know the
     viewer/record CLIs.
- **Outline**
  1. The four-call workflow diagram (api-io §0).
  2. `put_model` in one picture: MjModel in → checks → float32 arrays + derived fields + warp-only `Option` out.
     `.deeper` block: the step list of `io.py::put_model` (toolkit check, `batch_sizes`, enum checks, tolerance clamp,
     `mark_batched`).
  3. `Option`: MuJoCo fields vs warp-only fields; continuous options are arrays of shape (1,), discrete ones Python ints
     (full table in ex1; deep dives in Ch 15, 20, 21).
  4. `make_data` vs `put_data`: what each fills; static geom poses set only here.
  5. `step` vs `forward`.
  6. Getting one world back: `get_data_into` (filters contacts by world, reorders efc rows) and why it is slow (owner of
     this cost).
  7. Accuracy: float32 vs float64, `d.time` accumulation (0.10999998), long-horizon divergence in chaotic systems.
  8. Seeing it: two render paths (CPU OpenGL via `get_data_into` + `mujoco.Renderer` vs the batch ray tracer, Ch 27);
     one-world video; tiled frames of several worlds.
  9. CLIs: `mjwarp-viewer` in 4.0.1 opens the native `mujoco.viewer.launch_passive` window (space pauses, `.` single-
     steps; needs glfw, which only the `[viewer]` extra installs: `viewer.py` imports `mujoco.viewer`, which raises
     "mujoco.viewer requires glfw" otherwise) or `--viewer viser` (browser-based; needs only
     `pip install "mjviser>=0.0.13"`, not the `dev` extra; via a Colab tunnel it stays labelled "unverified"),
     `--engine warp|c` (C engine for a float64 comparison); `.version`: the dev tree moved the viewer to MuJoCo Studio.
     `mjwarp-record` (`record.py`): **GPU only** (`cli.unroll` opens `wp.ScopedStream(wp.get_stream())`, which raises
     `RuntimeError: Device cpu is not a CUDA device` on CPU); imports PIL; writes `.gif`/`.webp` only (`raise
     ValueError("Unsupported video format")` otherwise); the only output flag is `--output` (pitfall callout: the
     module docstring's `--video humanoid.mp4` usage line is wrong); `--nworld` defaults to 8192 so pass `--nworld 1`;
     `--render_mode warp` avoids EGL and needs `mjm.ncam > 0`; flags `--channel rgb|depth|segmentation` (segmentation
     colorized with a fixed palette by `_colorize_segmentation`), `--cam_index` (warp mode), `--fps`, `--quality`,
     and the python-mode free camera `--cam_distance`, `--cam_lookat_z`, `--cam_azimuth_speed` (orbiting). The full
     flag table goes to `reference/api-at-a-glance.html`.
  10. `.deeper` block: an error gallery (api-io §2.10) and `override_model` (private, returns None). The gallery is
      also copied into `reference/troubleshooting.html`.
- **Code examples**
  1. `ex1_option_table.py` - `PLAYGROUND`; iterate `dataclasses.fields(m.opt)` and print each name, kind (array shape or
     int/bool), value, and "warp-only" for names missing from `mujoco.MjOption` (`broadphase`, `graph_conditional`,
     `run_collision_detection`, `run_qacc_smooth`, `deterministic`, ...), plus
     `sleep_tolerance`, `magnetic`, `noslip_tolerance`; finally prints the AttributeError from `m.opt.ls_parallel`
     ("ls_parallel was removed in MuJoCo Warp 3.9.1.").
  2. `ex2_make_data_blank.py` - `make_data(nworld=4)`; print `d.xpos.numpy()[0,1]` (zeros) then after `mjw.forward`
     (`[0,0,1]`).
  3. `ex3_step_compare.py` - 60 steps in MJWarp vs `mj_step`; print max |qpos diff| for world 2 (~7e-7) and ncon/nefc.
  4. `ex4_put_data_mutates.py` - show `mjd.xpos[1]` before/after `put_data` (zeros → `[0,0,1]`).
  5. `ex5_time_float32.py` - 11 steps of dt 0.01; print `d.time` (0.10999998) vs Python float.
  6. `ex6_tolerance_clamp.py` - set `mjm.opt.tolerance = 1e-10`; print `m.opt.tolerance.numpy()` (`[1e-6]`).
  7. `ex7_chaos.py` - double pendulum from `horizontal` keyframe, 2000 steps in MJWarp and C; prints the step where
     |Δq| > 1e-2, then plots |Δq| on a log axis (`--dump-json` feeds the page chart).
  8. `ex8_get_data_into.py` - copy world 3 into a fresh `MjData`; print `ncon`, `nefc`, `qpos`, and time per call vs
     `d.qpos.numpy()`.
  9. `ex9_one_frame.py` - `PLAYGROUND` world 0 after 50 steps; Renderer (Rule O fallback: `create_render_context` at
     64x64 on CPU); save PNG; print image shape.
  10. `ex10_video_tiled.py` - 9 worlds with different initial ball velocities; a 3-second video of world 0 and a 3x3
      tiled frame; print frame count and tile shape.
  11. `ex11_record.py` - on GPU (Rule G `ON_GPU` guard plus `shutil.which("mjwarp-record")` and
      `importlib.util.find_spec("PIL")`): run `mjwarp-record <humanoid> --nworld 1 --nstep 100 --output humanoid.gif
      --render_mode warp`, then a second invocation `--channel depth --render_mode warp --output depth.gif`; print the
      output paths. **CPU fallback** (the same loop record.py runs, by hand): `create_render_context(mjm, nworld=1,
      cam_res=(64, 64))` → per frame `mjw.step`, `mjw.refit_bvh`, `mjw.render`, `mjw.get_rgb` → PIL
      `frames[0].save("out.gif", save_all=True, append_images=frames[1:])`; print frame count and image shape (verified
      on CPU: rendering `PLAYGROUND` at 64x64 gives a `(2, 64, 64, 3)` image for 2 worlds, ~4.4 s incl. context
      creation). `--dump-png` writes 3 frames for the page.
- **Visuals**
  - "Customs gate" animation: an MjModel package travels toward the GPU; a gate inspects it (feature checks), stamps
    float32, clamps tolerance, rejects a PGS package in red.
  - Split-screen SVG: `make_data` (qpos0 tiled, xpos blank) vs `put_data` (copies MjData, host xpos flips to filled
    with a "mutation" badge).
  - Interactive float32 vs float64 widget: type a number, see both bit patterns and the rounding error; a slider for
    number of additions showing accumulated time error.
  - Chaos divergence chart (inline SVG, Rule D data from ex7) with two pendulum ghosts drifting apart.
  - Two-path animated diagram: left lane GPU → PCIe copy (bottleneck icon) → CPU MjData → OpenGL (1 frame); right lane
    GPU → BVH → megakernel → many frames, all on GPU.
  - Interactive tiled-worlds widget: choose grid size; shows which world id lands in which tile.
  - Colab vs local capability matrix: batch render yes (CPU too); `mujoco.Renderer` yes with EGL; `mjwarp-record`
    "GPU only (CLI); CPU: manual loop", `.gif`/`.webp` only; native viewer no (needs a display); viser viewer
    "maybe via tunnel (unverified)", needs `mjviser`.
  - **"Your first rendered worlds" strip (Rule D images):** the real 64x64 PNGs written by ex9/ex10 (`--dump-png`),
    base64-embedded: world 0 at t = 0, 0.25, 0.5 s and a 3x3 tile of 9 worlds, captioned "mujoco-warp 4.0.1, CPU
    run, batch renderer".
- **Exercises / quiz**: which calls mutate host data; what `forward` does not update (time); why not call
  `get_data_into` in training loops; auto-checked: (1) build `put_data` from a settled `MjData` and assert
  `d.nacon` > 0; (2) assert that 100 MJWarp steps of `BALL_DROP` match C within 1e-4; stretch: find a model MJWarp
  refuses and explain the message.
- **Notebook**: setup (+EGL); ex1-ex11 with inline media; exercises.

### Chapter 6 - `06-batched-data-layout` - Many Worlds: The Batched Data Layout

- **Level:** beginner. **Prerequisites:** 5. **Research:** api-io §1.5, §1.6 (first half), §2.3-§2.4; warp-perf §1.1,
  §2.3; pipeline §0.
- **Learning objectives**
  1. Predict the shape of any Data field (`(nworld, ...)`) and Model field (batched `(B, ...)` vs structural).
  2. Read and write per-world inputs in place (`assign`, `wp.copy`, `fill_`) and know when replacing an array is bad.
  3. Explain round-robin batching `field[worldid % B]` and demonstrate it with per-world gravity.
  4. Know that some arrays are pooled across worlds and tagged with `worldid` (intuition only; sizing in Ch 9).
  5. Map shapes to linear memory and explain why nworld-first gives coalesced access.
  6. Know the cost of `.numpy()` and batch host reads; plot batched results.
- **Outline**
  1. The nworld-first rule and the shape table (api-io §1.5).
  2. Vector dtypes and their NumPy views; quaternions are a `.recall` of Ch 2 §3 (no new widget).
  3. Linear memory: the address of `d.xpos[w, b][k]` is `((w*nbody + b)*3 + k)*4` bytes; adjacent worlds' threads read
     adjacent rows (recall Ch 4 coalescing).
  4. Writing inputs: `d.qpos.assign`, `d.ctrl.fill_`, `wp.copy`; identity vs replacement (`d.qpos = wp.array(...)`)
     (owner of this pitfall; graph consequence in Ch 24).
  5. Model batch dimension: `"*"` specs in `types.py`, `worldid % shape[0]`, structural fields never batched.
  6. Round robin, not blocks: per-world gravity demo (api-io §1.6, §2.4).
  7. Pooled arrays in one picture: `d.contact.*` is one list shared by all worlds with a `worldid` tag; per-world arrays
     like `d.efc.*` have an nworld dimension (no sizing here; forward link Ch 9).
  8. The spec strings (`types.py::array`) and `warp_util.mark_batched` (`_is_batched`).
  9. Host reads: `.numpy()` = copy + sync; batch them; plotting many worlds (trajectories, phase portraits).
  10. When is the GPU actually faster? World-steps/s vs nworld (eager) next to C MuJoCo's single-world speed: one world
      on the GPU is slower than C (launch overhead: ~100 launches per step, recall Ch 4), throughput grows with nworld
      until the GPU is full (occupancy); forward link to Ch 24 (graphs remove the launch overhead).
- **Code examples**
  1. `ex1_shape_table.py` - iterate `dataclasses.fields(d)` and print name, shape, dtype for arrays (top 25 rows).
  2. `ex2_model_batched.py` - print `m.body_mass.shape` (1, nbody), `m.geom_type.shape` (ngeom,), and how many Model
     arrays have `_is_batched` True (count ~156).
  3. `ex3_per_world_qpos.py` - set hinge angle per world with `linspace` via `.assign`; `forward`; print arm tip `xpos`.
  4. `ex4_per_world_ctrl.py` - per-world ctrl in [-1, 1]; 100 steps; print hinge qpos per world (spread).
  5. `ex5_fill_copy_zero.py` - `fill_`, `zero_`, `wp.copy` round trips; print results.
  6. `ex6_replace_vs_assign.py` - keep `old = d.qpos`, then replace `d.qpos`; print `old is d.qpos` (False) and explain.
  7. `ex7_gravity_round_robin.py` - `m.opt.gravity = wp.array([g, -g], dtype=wp.vec3)` with 4 worlds; print qvel z
     `[-0.0981, 0.0981, -0.0981, 0.0981]`.
  8. `ex8_addresses.py` - compute byte offsets of `d.xpos[w, b]` from `d.xpos.strides` and compare with the formula;
     print a small table.
  9. `ex9_numpy_cost.py` - time 100 steps with a `.numpy()` read each step vs one read at the end; prints both.
  10. `ex10_batched_plots.py` - 64 worlds of `BALL_DROP` with random heights and 256 `PENDULUM` worlds with random q1;
      print mean bounce time, then save z(t) small multiples and a (q1, v1) phase portrait.
  11. `ex11_docstring_specs.py` - parse `mujoco_warp._src.types.Data.__doc__` for a few fields and print their symbolic
      shapes next to the resolved shapes. Also adds `make_worlds(xml, nworld)` to `my_env.py`.
  12. `ex12_throughput_vs_nworld.py` - `BALL_DROP` eager stepping for nworld in {1, 16, 256, 4096} (CPU: {1, 4, 16,
      64}) and `mujoco.mj_step` single-world speed; print a table of world-steps/s and the ratio to C; `--dump-json`
      feeds the throughput figure. The page shows the learner's Colab table as the main result and labels CPU numbers
      "on a CPU dev box".
- **Visuals**
  - Interactive shape explorer: pick a field and set nworld/model sizes; shows spec string, resolved Warp shape, NumPy
    shape (with vector tail dims) and a block drawing.
  - **Address ribbon:** a flat byte strip of `d.xpos` (nworld, nbody, vec3) colored by world; hovering cell (w, b, k)
    highlights its offset; second ribbon for `m.body_mass` with B rows and arrows from each world's thread to row
    `w % B`; toggle "warp of 32 threads" overlays which addresses one instruction touches.
  - Animated card stack: `d.qpos` as N translucent world rows; `m.body_mass` as a single row broadcasting down; then B=N.
  - Round-robin dealing animation with slider for B (1..8): gravity arrows dealt to 8 world tiles; a crossed-out
    "blocks" alternative.
  - Pool vs per-world picture: one long bar with colored entries vs a stack of per-world strips (intuition only).
  - "Replace vs assign" circuit diagram: assign keeps the socket wired; replace leaves the old socket wired.
  - Small multiples (world replay player, A.7, Rule D from ex10): 64 real `BALL_DROP` worlds bouncing in a grid of
    small canvases, with hover/tap highlighting one world and a scrub bar.
  - Throughput curve (Rule D from ex12): world-steps/s vs nworld on log-log axes with C MuJoCo's line; an annotation
    marks where MJWarp overtakes C on the learner's GPU (notebook) and "launch-overhead regime" / "GPU full" bands.
- **Exercises / quiz**: quiz on round robin with B=3 and nworld=8, shapes, replace vs assign; auto-checked: (1) predict 6
  shapes (checker compares); (2) implement per-world wind via `m.opt.wind` and assert the drift direction per world;
  stretch: a kernel that writes per-world qpos from a seed.
- **Notebook**: setup; ex1-ex12; shape-prediction quiz cell that checks the learner's answers.

### Chapter 7 - `07-pipeline-tour` - A Guided Tour of `step` and `forward`

- **Level:** intermediate. **Prerequisites:** 6. **Research:** pipeline §0-§1.3, §2 B-C, §2 K, §5; warp-perf §0, §3.
- **Learning objectives**
  1. Recite the stage order of `forward` and which Data fields each stage writes.
  2. Call the stages by hand and reproduce `forward` exactly (with the right factorize pairing).
  3. Audit the force budget `qfrc_smooth = qfrc_passive - qfrc_bias + qfrc_actuator + qfrc_applied (+ J^T xfrc)` as an
     identity (its physics meaning is Ch 11).
  4. Count and name the kernels a step launches and recognize the pipeline-wide launch shapes (atlas layouts 1, 2,
     6, 7, 8; algorithm-specific layouts are added in Ch 15, 17 and 27).
  5. Use disable flags to switch stages off and observe effects.
  6. Know how `@event_scope` and `EventTracer` expose per-stage time (GPU only).
  7. Know in one picture what a CUDA graph is (record once, replay; device-side loops), as a teaser for Ch 24.
- **Outline**
  1. `step` = `forward` + integrator (`forward.py::step`).
  2. `_forward` stage list, read from the 4.0.1 wheel (`forward.py::_forward`, `fwd_position`): [sleep only:
     `sleep.wake`, `update_sleep`] → `fwd_position(factorize=False)` = `fwd_kinematics` (kinematics, com_pos,
     camlight, flex, tendon) → `smooth.crb`, `tendon_armature` (→ `factor_m` only if you call
     `fwd_position(factorize=True)`) → `collision_driver.collision` → `constraint.make_constraint` → [sleep only:
     `island.island`] → `smooth.transmission`; sensor_pos; `fwd_velocity` (com_vel, passive, rne, tendon_bias);
     sensor_vel; control callback; `fwd_actuation`; `fwd_acceleration(factorize=True)` (qfrc_smooth and
     `factor_solve_i`: the factorization happens here inside `_forward`); `solver.solve`; `rne_postconstraint` (when
     requested); sensor_acc. The **pipeline breadcrumb** with fixed station ids (Appendix A.1) is introduced here.
  3. One-line pitfall: the public `fwd_position`/`fwd_acceleration` defaults (`factorize=True`) differ from what
     `_forward` passes; calling stages by hand needs one factorization per qpos. The full story and the stale-`qLD`
     experiment belong to Ch 11 §9 (owner of the factorization).
  4. Stage → Data cheat sheet (pipeline §1.3).
  5. Force bookkeeping identity (`forward.py::_qfrc_smooth`, `passive.py`).
  6. The constraint solve as the last big stage (preview Ch 19-20).
  7. Disable flags (`mjw.DisableBit`: CONTACT, GRAVITY, ACTUATION, SPRING, DAMPER, CONSTRAINT, ...).
  8. How many kernels and why (warp-perf §0, `wp.launch` patch count); the **launch-shape atlas** (Appendix A.6), the
     pipeline-wide layouts only: (1) (world, element) grids (smooth.py `dim=(nworld, nbody)`); (2) flat pool slots
     (`collision_primitive.py` narrowphase `dim=d.naconmax` with `if tid >= ncollision_in[0]: return`); (6) tiled
     block-per-world launches (`wp.launch_tiled(dim=d.nworld, block_dim=...)` with `for efcid in range(tid, nefc,
     wp.block_dim())`, e.g. `solver.py::_linesearch_iterative`, `_cholesky_factorize_solve`; `smooth.py::_factor_blocks`
     `dim=(nworld, tile.adr.size)`); (7) 3-D grids (`solver.py::_linesearch` `dim=(d.nworld, d.njmax,
     threads_per_efc)`, `smooth.py` `dim=(d.nworld, m.ntendon, m.max_ten_J_rownnz)`); (8) row-per-contact
     (`constraint.py` contact rows `dim=d.naconmax`). The selector lists the real launch lines with the `dim` values
     recorded by ex5 (Rule D). SAP work packages (3), CCD grid-stride (4) and rays (5) appear greyed with "added in
     Ch 15 / 17 / 27".
  9. Instrumentation: `warp_util.event_scope`, `EventTracer` (CUDA only; owner of the structure, workflow in Ch 25).
     Guard idiom: `EventTracer(enabled=ON_GPU)` (0.4 rule G).
  10. CUDA graph teaser: ~100 launches per step cost CPU time each; a CUDA graph records them once and replays them
      with one call; conditional nodes let the GPU loop (the solver's per-world iterations) without the CPU. No code
      here; Ch 20/21 recall this and Ch 24 owns it.
  11. Part I checkpoint project: "10k bouncing balls dashboard".
- **Code examples**
  1. `ex1_manual_stages.py` - `fwd_position`, `fwd_velocity`, `fwd_actuation`, `fwd_acceleration`, `solve` vs
     `forward`; print max |qacc diff| (0).
  2. `ex2_stage_outputs.py` - after each stage print the newly filled fields for `PLAYGROUND` (xpos, M nnz, cvel,
     qfrc_bias, actuator_force, qacc_smooth, qacc).
  3. `ex3_stage_fields.py` - for `PLAYGROUND`, zero a set of Data fields, run one stage at a time and print which
     fields changed (a measured version of the stage → Data cheat sheet; `--dump-json` feeds the interactive sheet).
  4. `ex4_force_budget.py` - verify the qfrc_smooth identity per world; print residual (~1e-6) and a per-dof table.
  5. `ex5_count_launches.py` - patch `wp.launch`/`wp.launch_tiled` with `unittest.mock` to count calls in one
     `mjw.step` for `PLAYGROUND` and `HUMANOID`; print counts (~100) and the `dim` of each launch grouped by atlas
     layout (`--dump-json` feeds the atlas selector).
  6. `ex6_kernel_names.py` - record kernel keys in order and print the first 40 (shows stage order).
  7. `ex7_disable_flags.py` - disable GRAVITY / CONTACT / ACTUATION in turn; print ball z and hinge qpos after 100 steps.
  8. `ex8_stage_timing.py` - time each stage by hand with `wp.synchronize()` around it (CPU and GPU); print the
     fraction of step time per stage (feeds a bar chart; GPU numbers only in the notebook).
  9. `ex9_xfrc_push.py` - push the box with `d.xfrc_applied`; print qfrc_smooth on its dofs and resulting velocity.
  10. `ex10_event_trace.py` - `with EventTracer(enabled=ON_GPU) as t: mjw.step(m, d)`; on GPU print the nested
      per-stage timing tree; on CPU print "EventTracer needs CUDA (empty trace)" and a bundled example tree labelled
      "example structure".
  11. `ex11_checkpoint_dashboard.py` - Part I project: NWORLD balls with random heights/velocities, 2 s; print a
      summary (bounces per world, final z histogram counts, steps/s) and save a 4-panel figure.
- **Visuals**
  - Hero conveyor belt animation: stations exactly as Appendix A.1; a state packet moves; output chips drop on a Data
    shelf; sensor taps flash after pos/vel/acc; RK4 toggle loops 4x.
  - Interactive cheat sheet: click a stage to highlight the Data fields it reads (blue) and writes (green).
  - **Factorize socket** on the breadcrumb: a dashed ghost `factor_m` socket after `crb` labelled "only when you call
    `fwd_position(factorize=True)`", and a solid "factor happens here inside `_forward`" marker on the acceleration
    station (the full stale-qLD timeline is in Ch 11).
  - CUDA graph teaser (SVG): a CPU lane of ~100 launch boxes vs one "replay" box; a loop arrow inside the GPU lane
    labelled "conditional node: iterate until converged" (static, links to Ch 24).
  - Force budget stacked bars per DOF (Rule D from ex4).
  - Kernel launch timeline (from ex6 names): ~100 blocks colored by stage; hover shows kernel name and file.
  - **Launch-shape atlas** (interactive, Appendix A.6, layouts 1, 2, 6, 7, 8): pick a stage, see its thread layout,
    the source launch line and the recorded `dim`; layout 6 animates a stride cursor over efc rows (with the "on CPU
    block_dim collapses to 1 lane" note).
- **Exercises / quiz**: order these 8 functions; which stage writes `cdof`, `qfrc_bias`, `efc.J`; auto-checked:
  (1) reproduce `forward` with manual calls and assert equal qacc; (2) count launches with CONTACT disabled and assert
  fewer than default; stretch: explain why the stage fractions from ex8 differ between CPU and the Colab GPU.
- **Notebook**: setup; ex1-ex11; trace pretty-printer and an icicle chart of the GPU trace; checkpoint dashboard.

---
## Part II. Driving simulations

### Chapter 8 - `08-resets-state-and-control` - Resets, State, Mocap and Control Loops

- **Level:** intermediate. **Prerequisites:** 7. **Research:** api-io §1.8, §1.10, §2.6-§2.7; pipeline §1.2
  (step1/step2), §1.8 (ctrl clamp), §2 C; warp-perf §9; `types.py::Callback`, `types.py::State`.
- **Learning objectives**
  1. Reset all or some worlds (`reset_data(reset=mask)`), reset to keyframes per world (`-1` = untouched).
  2. Remember that resets do not recompute kinematics; call `forward`.
  3. Snapshot and restore state with `get_state`/`set_state` and `mjw.State` signatures: the single bits (TIME, QPOS,
     QVEL, ACT, HISTORY, PLASTIC, WARMSTART, CTRL, QFRC_APPLIED, XFRC_APPLIED, EQ_ACTIVE, MOCAP_POS, MOCAP_QUAT,
     USERDATA; PLUGIN unsupported) and the composites PHYSICS (= TIME|QPOS|QVEL|ACT|HISTORY|PLASTIC), FULLPHYSICS,
     USER, INTEGRATION; know that bitwise replays with contacts need WARMSTART too (owner of state signatures).
  4. Drive per-world mocap targets and toggle equality constraints per world (`d.eq_active`).
  5. Put a controller in the loop with `step1`/`step2` (RK4 falls back to Euler in `step2`) or `m.callback.control`
     (owner of control callbacks).
  6. Build device-side auto-reset (owner): a done-mask kernel, plus a non-finite guard since MJWarp has no NaN checks.
  7. Use worlds as parallel rollouts for sampling-based control (owner of MPC).
- **Outline**
  1. `reset_data` (`io.py::reset_data`): what it zeroes and restores (qpos0, mocap from `body_pos[mocap_body]`,
     `eq_active0`); per-world mask shape rules.
  2. `reset_data_keyframe` (`io.py::reset_data_keyframe`): int vs per-world array, out-of-range = skip.
  3. Stale derived data after reset → `forward`.
  4. State signatures (`types.py::State` docstring and its `# unsupported: PLUGIN` comment,
     `support.py::get_state/set_state(m, d, state, sig, active=None)`), `mujoco.mj_stateSize`, `active` mask. Why a
     QPOS|QVEL snapshot is "almost but not bitwise" once constraints are active: the solver warmstart
     (`d.qacc_warmstart`, State.WARMSTART) and TIME are not restored. Rules: MPC snapshots use `State.PHYSICS` (it
     includes HISTORY for delays and PLASTIC for plasticity), plus `WARMSTART` for exact replays; `INTEGRATION` takes
     everything. Pitfall box: `get_state` does not check the destination size; always allocate
     `wp.zeros((d.nworld, mujoco.mj_stateSize(mjm, sig)), dtype=float)` and assert the shape.
  5. Mocap bodies in batch: `d.mocap_pos (nworld, nmocap, vec3)`, `d.mocap_quat`; kinematics reads them
     (`smooth.py::_kinematics_branch` `mocap_pos_in[worldid, mocapid]`); writing targets by `assign` or kernel.
  6. Per-world equality toggling: `d.eq_active (nworld, neq)` initialized from `m.eq_active0`; grasp-by-weld and
     attach/detach; `sleep.wake_equality` is called when `neq > 0` (forward.py).
  7. Control in the loop: `step1` / user policy / `step2` (`forward.py::step1/step2`); the RK4 caveat.
  8. Callbacks (`types.py::Callback`: passive, control, act_dyn, act_gain, act_bias, sensor, contactfilter); where each
     is invoked. This chapter demonstrates `control`; Ch 26 owns the rest.
  9. ctrl clamping happens on read (`forward.py::_actuator_force`); `d.ctrl` is not modified.
  10. Auto-reset pattern: done kernel → `reset_data(m, d, reset=done)` → `forward`, all on device (graph-friendly).
      Non-finite guard: a kernel sets `done[w]` when any `qpos/qvel` is not finite (no `mj_checkPos` equivalent).
  11. Parallel rollouts for MPC: snapshot, perturb per world, roll out, choose, restore.
- **Code examples**
  1. `ex1_masked_reset.py` - 4 worlds, 5 steps, mask `[T,F,T,F]`; print `d.time` and ball z (api-io §1.8 numbers).
  2. `ex2_keyframe_reset.py` - `reset_data_keyframe(m, d, 0)` and with `[0,-1,0,-1]`; print qpos[:, 2].
  3. `ex3_forward_after_reset.py` - print `xpos` after reset (stale) and after `forward` (fresh).
  4. `ex4_snapshot_restore.py` - two free boxes on a plane, 150 steps, snapshot, 30 steps, restore, 30 steps; once
     with `sig = State.QPOS | State.QVEL` and once with `State.PHYSICS | State.WARMSTART`; print both max |Δqpos|
     (verified on CPU: 2.98e-08 vs 0.0) and both `mj_stateSize` values. Adds `snapshot(m, d, sig)` /
     `restore(m, d, buf, sig)` with the shape assert to `my_env.py`.
  5. `ex5_mocap_targets.py` - `MOCAP_TARGET` with NWORLD worlds: a kernel writes a per-world circular target into
     `d.mocap_pos` each step (radius varies by world); print box-target distance per world after 2 s.
  6. `ex6_eq_toggle.py` - same model, set `d.eq_active` False for odd worlds; 100 steps; print box z per world (odd
     worlds fall) and `d.nefc` per world (fewer rows when the weld is off).
  7. `ex7_step1_step2_pd.py` - PD controller on `PENDULUM` hinge1 reading `d.sensordata` between step1 and step2;
     print tracking error over time.
  8. `ex8_ctrl_clamp.py` - `ctrlrange="-5 5"`, set ctrl 10; print `d.ctrl` (10) and `d.actuator_force` (5).
  9. `ex9_control_callback.py` - `m.callback.control = fn(m, d)` that launches a kernel writing ctrl; print hinge
     angle after N steps vs without callback.
  10. `ex10_auto_reset.py` - `BALL_DROP` with random initial velocities; done when z < 0.15, t > 1, or non-finite;
      done kernel + masked reset each step; print episodes finished per world. Adds `reset_done` and
      `nonfinite_reset` to `my_env.py`.
  11. `ex11_mpc_rollouts.py` - `CARTPOLE`: from one state, NWORLD random action sequences for 50 steps, score upright
      reward on device, pick best first action, apply, repeat 20 times; snapshots use `my_env.snapshot` with
      `State.PHYSICS` (HISTORY/PLASTIC included, so models with delays or plasticity restore correctly); print pole
      angle trajectory.
- **Visuals**
  - Reset-mask animation (world grid A.9 driven by the replay player A.7, Rule D from ex1/ex2): world tiles with
    running clocks; a boolean mask slides underneath; True tiles flash "reset" and snap to t=0; second mode for
    keyframe ids with -1 tiles untouched.
  - State-vector packing widget: checkboxes for every State bit (TIME, QPOS, QVEL, ACT, HISTORY, PLASTIC, WARMSTART,
    CTRL, QFRC_APPLIED, XFRC_APPLIED, EQ_ACTIVE, MOCAP_POS, MOCAP_QUAT, USERDATA) plus composite buttons (PHYSICS,
    FULLPHYSICS, USER, INTEGRATION) build the packed layout bar with sizes for `MOCAP_TARGET`/`PLAYGROUND` (sizes
    dumped by ex4 via `mj_stateSize`); PLUGIN shown struck through ("unsupported"); a badge says "bitwise replay?"
    and turns green only when WARMSTART and TIME are included.
  - Mocap ghost-target replay (world grid A.9 + replay player A.7, Rule D from ex5/ex6): 8 world tiles, each a
    dashed target orbiting at its own radius with the welded box trailing it; odd tiles show the eq_active=False run
    with the box falling.
  - step1/step2 timeline SVG with the policy gap; RK4 warning badge.
  - Callback insertion map on the pipeline breadcrumb (Appendix A.1) with sockets where each callback is called.
  - ctrl clamp two-gauge widget: a ctrl slider beyond ctrlrange; the "d.ctrl" gauge shows the raw value while the
    "effective ctrl inside `_actuator_force`" gauge saturates.
  - MPC fan animation (canvas): rollouts fan out, the best turns bold, the system advances one step, repeat.
- **Exercises / quiz**: quiz on what `reset_data` zeroes, mocap vs free, what `eq_active` changes; auto-checked:
  (1) "reset only worlds whose box tipped over" (assert the mask); (2) a kernel that attaches the weld when the box is
  within 5 cm of the target (assert eq_active flips); stretch: compare step1/step2 vs callback timing.
- **Notebook**: setup; ex1-ex11; an interactive MPC demo cell with a rendered video of the chosen trajectory.

### Chapter 9 - `09-contacts-and-buffer-sizing` - Contacts, Constraint Budgets and Overflow

- **Level:** intermediate. **Prerequisites:** 7. **Research:** api-io §1.4, §1.12, §2.8; collision §1.1, §1.13,
  §2.1-§2.2, §2.6; constraint-solver §2.2, §3 (memory); warp-perf §6.
- **Learning objectives**
  1. Read `d.contact` (dist, pos midpoint, frame/normal row 0, geom pair order, worldid, dim, friction, solref,
     solreffriction, solimp, type bits, surfacevel, efc_address, and flex/elem/vert fields) and group contacts per world.
  2. Explain `nconmax`, `naconmax`, `nccdmax`/`naccdmax`, `njmax`, `njmax_nnz`, `nvmax` and their defaults ladder.
  3. Detect and decode overflow (`d.overflow`, `mjw.OverflowType`) and understand silent dropping and starvation.
  4. Size buffers from measurements and estimate memory.
  5. Compute contact forces with `mjw.contact_force`.
- **Outline**
  1. Where contacts come from (recall the breadcrumb, Ch 7): `fwd_position` → `collision` → `make_constraint`.
  2. The `Contact` struct (`types.py::Contact`) and the flat world-interleaved pool (owner of the pool bar,
     Appendix A.2); `nacon` can exceed capacity.
  3. Normal convention: `frame[0]` from `geom[0]` to `geom[1]`, `geom[0]` is the lower GeomType.
  4. `ContactType` bits (`types.py::ContactType`: CONSTRAINT=1, SENSOR=2, PASSIVE=4): SENSOR contacts come from
     collision sensors and produce no constraint rows; `surfacevel` (tangent1, tangent2, spin) from `geom_surfacevel`
     (`collision_driver.py::_contact_surfacevel`; example in Ch 16).
  5. "What is a friction cone" box (intuitive) and constraint rows per contact as a black-box formula: pyramidal
     `2(condim-1)`, elliptic `condim` (derivation in Ch 19).
  6. Sizing parameters and defaults (`io.py::_default_nconmax`, `_default_njmax`, `_resolve_batch_size`,
     `_get_padded_sizes`), valid-size ladder.
  7. Overflow detection (`forward.py::_next_time_builder`, CCD/EPA/solver bits), sticky bits, `warn_overflow`. The
     catalogue is generated from `mjw.OverflowType` members, never hand-listed: NEFC, NJMAX_NNZ, BROADPHASE,
     NARROWPHASE, CCD, HFIELD, CONTACT_MATCH, NVMAX, EPA_HORIZON, ITERATIONS, LS_ITERATIONS (1<<10, linesearch limit;
     printf "linesearch iterations limit reached - please increase ls_iterations"; shown in Ch 20), TACTILE (1<<11).
     `warn_overflow` is read through `wp.static` inside kernels, so changing it after the first launch recompiles
     (knob board, Ch 24).
  8. Starvation: a shared pool is not fair (api-io §1.12 demo).
  9. Sizing recipe: measure worst case, add margin, check periodically; `mjwarp-testspeed --measure_alloc` (Ch 25).
  10. Memory and time cost of oversizing (narrowphase kernels launch over capacity, recall the atlas).
  11. `contact_force` (`support.py::contact_force`) and `get_data_into` contact filtering.
- **Code examples**
  1. `ex1_read_contacts.py` - collision.md §2.1 scene, 4 worlds; print a contact table (world, geoms, dist, normal,
     dim, type bits decoded with `ContactType`).
  2. `ex2_per_world.py` - bincount contacts per world and deepest penetration per world.
  3. `ex3_normal_direction.py` - sphere listed before plane in XML; print `geom` order and normal (+z, plane first).
  4. `ex4_contact_force.py` - `PLAYGROUND` settled; `mjw.contact_force` in world frame; print total normal force on the
     ball (~9.81 N).
  5. `ex5_overflow_starvation.py` - 6 boxes, `nworld=2, nconmax=4, njmax=8`; print `nacon`, `ncollision`, `nefc`,
     decoded overflow per world.
  6. `ex6_default_overflow.py` - `box_stack(6)` with defaults → NEFC; then with `njmax=128`; print both.
  7. `ex7_decode_overflow.py` - helper `describe_overflow(d)` that loops over `mjw.OverflowType` members (no hand
     list); prints names per world (added to `my_env.py`).
  8. `ex8_size_from_rollout.py` - run `box_stack(5)` with big budgets for 300 steps, track max per-world nacon (from
     `contact.worldid`) and max nefc; print recommended `nconmax`, `njmax` with 25% margin.
  9. `ex9_memory_estimate.py` - estimate bytes of `efc.J`, contacts and `h` for given nworld/njmax/nv; compare with the
     sum of `.nbytes` over Data arrays; print table for nworld 1k/8k/32k.
  10. `ex10_warn_mask.py` - silence only NEFC prints with `m.opt.warn_overflow &= ~mjw.OverflowType.NEFC`; show bits
      still set.
  11. `ex11_sensor_contacts.py` - add a `<distance>` collision sensor between two geoms; print contacts whose type has
      the SENSOR bit and show that `nefc` does not count them.
- **Visuals**
  - Shared contact pool animation (Appendix A.2 bar): colored world "fountains" drop contacts into the next free slot via
    an atomic counter; when full, red sparks, later contacts bounce off; toggle nconmax 4 vs 48. Next to it the
    **real** sink: the world replay player (A.7, Rule D from ex5) shows box heights in world 1 penetrating the floor
    with `nconmax=4` vs settling with 48.
  - Overflow LED panel (Rule D from ex5/ex6 `--dump-json`: per-world `d.overflow` ints at every step of an undersized
    run): one LED per `OverflowType` member (generated from the enum) per world, a step scrubber, sticky bits shown
    staying lit; under the panel the exact warning string printed by `forward.py` for the lit bit and the silencing
    line `m.opt.warn_overflow &= ~mjw.OverflowType.NEFC` (with a "recompiles" badge).
  - Interactive contact card: hover fields of one contact (frame rows normal/t1/t2, friction 5-vector, dim, type bits,
    surfacevel, efc_address arrows to rows).
  - Sizing calculator widget: inputs nworld, nconmax, njmax, nv, condim, cone; outputs naconmax, njmax_pad, nv_pad,
    estimated memory for J, contacts, Hessian.
  - Normal-direction SVG: plane/sphere/box pairs with arrows from geom[0] to geom[1].
  - Friction-cone intuition SVG (owner of the intuition; the math widget is Ch 19): a block on a slope with the
    force inside/outside a cone (pyramid vs round).
- **Exercises / quiz**: quiz on nacon global vs nefc per world, pyramidal row count, SENSOR contacts; auto-checked:
  (1) size a 10-box scene for 8192 worlds (assert within the ladder); (2) a per-world contact-count kernel asserted vs
  NumPy bincount; stretch: find the smallest nconmax with no overflow for `TERRAIN`.
- **Notebook**: setup; ex1-ex11; the sizing calculator as a Python function (optional ipywidgets slider).

### Chapter 10 - `10-domain-randomization` - Domain Randomization with Batched Model Fields

- **Level:** intermediate. **Prerequisites:** 8, 9. **Research:** api-io §1.6, §2.5; pipeline §1.13; warp-perf §9;
  collision §1.7 (batched geom params), §2.10; render-integrations §1.7.
- **Learning objectives**
  1. Make any `"*"` Model field per-world, by replacing the array or via `put_model(batch_sizes=...)`.
  2. Know which fields can vary (numeric parameters) and which cannot (topology, discrete options).
  3. Know, in plain language, what each derived constant means, and recompute derived constants with `set_const` and
     the right `SetConstGroup`, batching the derived outputs too.
  4. Randomize mass, friction, geometry size, actuator gains, timestep, gravity and colors.
  5. Re-randomize on device between episodes without breaking graph capture.
- **Outline**
  1. Why DR for sim-to-real; physics vs visual DR.
  2. The batching rule recap (`.recall` Ch 6) and two methods (api-io §1.6).
  3. Simple DR first (no derived constants): gravity, timestep, friction, colors.
  4. What is batchable: `_is_batched` list; structural ints and discrete `opt` values are global and compile-time.
  5. Derived constants in plain language (one line each, forward links to Ch 11/12): `body_subtreemass` (mass of a body
     plus everything below it), `body_invweight0`/`dof_invweight0` (how easily a body/DOF accelerates at qpos0),
     `actuator_acc0` (acceleration a unit actuator force produces), `geom_rbound`/`geom_aabb` (bounding sphere/box of a
     geom), `tendon_length0` (tendon length at qpos0).
  6. `set_const(m, d, groups=SetConstGroup.ALL, restore=True)` (`set_const.py::set_const`): the page reproduces both
     docstring tables verbatim. (a) "Model fields that can be modified safely" with their notes: `body_pos/body_quat`
     unsafe for static bodies (invalidates the BVH); `actuator_armature/actuator_gear` not when changing from/to zero
     (`jnt_actuatorid`/`tendon_actuatorid` are set by `put_model`); `tendon_stiffness/tendon_damping` note; cam, light,
     eq_data, geom_size, hfield_size. (b) The groups table: body_mass → ALL, geom_size → FIXED (or ALL if a tendon
     wraps the geom), cam/light/eq_data → KIN0, body_inertia/dof_armature → INERT0, qpos0 → KIN0|INERT0. `restore=True`
     puts back the `qpos`, mocap and `nacon` that set_const saves before its internal kinematics pass (set_const.py
     `wp.copy` lines); `restore=False` leaves Data at qpos0. `.version`: `set_const_fixed` and `set_const_0` are
     deprecated aliases (DeprecationWarning, `# TODO(team): remove in future version`); the page shows the warning
     once and never uses them.
  6b. `set_length_range(m, d, index=-1)`: copies `jnt_range`/`tendon_range` × gear into `actuator_lengthrange` for
     joint and tendon transmissions with limits; other actuators keep (0, 0); no simulation-based path in 4.0.1. Needed
     after DR of gear or ranges for muscles (whose force-length curve uses lengthrange; Ch 12).
  7. The derived-field pitfall and the fix (batch the outputs too).
  8. `opt.*` arrays (timestep, gravity, wind, density, viscosity, magnetic, tolerance) can only be replaced, not
     batch_sized (`ValueError ... not a batched array field.`).
  9. Contact materials per world (`geom_friction`, `geom_solref`, ...) read with `worldid % B` in
     `collision_core.py::contact_params`.
  10. In-place re-randomization by kernel for graph-friendly episode resets.
  11. Per-world geometry variants built with `MjSpec` (`io_test.py::per_world_mesh` test helper, `geom_dataid` batched).
  12. Part II checkpoint project: "Robust slide" (DR study with sizing).
- **Code examples**
  1. `ex1_list_batchable.py` - list Model fields with `_is_batched` True grouped by prefix; prints counts.
  2. `ex2_density_worlds.py` - `.recall` Ch 6 ex7 (per-world gravity) and use a field Ch 6 did not: per-world
     `m.opt.density` (0, 1.2, 1000) on a light ball (fluid buoyancy and drag, inertia-box model); 100 steps; print ball
     z per world (the water world floats or sinks slowly).
  3. `ex3_timestep_worlds.py` - `m.opt.timestep = wp.array([0.001, 0.01, 0.02])`; 10 steps; print `d.time`.
  4. `ex4_friction_slide.py` - box on a tilted plane (inline MJCF variant of M3), `geom_friction` per world in
     [0.1, 1.0]; 200 steps; print slide distance per world (monotone decreasing).
  5. `ex5_mass_set_const.py` - per-world box mass with `batch_sizes` incl. derived fields; `set_const`; print
     `body_subtreemass` and `actuator_acc0` per world.
  6. `ex6_derived_pitfall.py` - same without batching derived fields; print the shared single row and explain.
  7. `ex7_size_fixed.py` - per-world ball radius via `geom_size` + `geom_rbound`/`geom_aabb` batched +
     `mjw.set_const(m, d, groups=mjw.SetConstGroup.FIXED)`; print `geom_rbound` per world and resting heights
     (verified: rbound [.05, .1, .2], rest z [.0496, .0996, .1996]). A second cell calls the deprecated
     `set_const_fixed` once under `warnings.catch_warnings(record=True)` and prints the DeprecationWarning text.
  8. `ex8_actuator_gain.py` - randomize `actuator_gear` or `actuator_gainprm` for `CARTPOLE`; print cart accelerations
     for the same ctrl.
  9. `ex9_rerandomize_kernel.py` - kernel that writes new frictions into `m.geom_friction` in place from a per-world seed
     (`wp.rand_init`, `wp.randf`) at episode reset; print values before/after two resets. Adds `randomize(m, seed)` to
     `my_env.py`.
  10. `ex10_batch_size_errors.py` - `batch_sizes={"opt.timestep": 4}` and `{"geom_type": 4}` errors; print messages.
  11. `ex11_checkpoint_robust_slide.py` - Part II project: 1024 (CPU 16) worlds with randomized friction, mass and
      slope; size `nconmax/njmax` from a measurement rollout (Ch 9 recipe), run, print the fraction that slid more than
      0.5 m per friction bin and "overflow: none".
  12. `ex12_length_range.py` - `test_data/actuation/muscle.xml`: print `actuator_lengthrange` before and after
      doubling `actuator_gear` (batched per world) and calling `mjw.set_length_range(m, d)`; also print a non-limited
      actuator staying at (0, 0).
- **Visuals**
  - set_const dependency graph (SVG, animated): edits (body_mass, body_inertia, geom_size, qpos0) → groups
    (FIXED, KIN0, INERT0) → derived nodes; a "batch size 1" derived node glows red to show the trap; hovering a derived
    node shows its plain-language meaning.
  - DR mosaic (world grid A.9 + replay player A.7, Rule D from ex4): 16 tiles, each the real trajectory of a box
    sliding down a slope with its own friction, labelled with mu, sorted by distance on toggle.
  - Batchable vs structural chart: two-column infographic of field families.
  - Slider widget: B and nworld, showing which worlds share each parameter value (round robin).
  - Episode re-randomization timeline: episodes as colored segments per world with parameter values changing at resets.
- **Exercises / quiz**: quiz on which set_const group each edit needs, what `actuator_acc0` means; auto-checked:
  (1) write `randomize(m, seed)` returning the batch_sizes dict (assert keys and shapes); (2) randomize floor friction
  and assert slide distance ordering; stretch: randomize solref (`.recall` Ch 2 §4 intuition) and measure bounce
  height per world.
- **Notebook**: setup; `%%writefile my_env.py` (Ch 9 snapshot); ex1-ex12; a "robustness histogram" cell plotting slide distances across 4096 worlds.

---
## Part III. Inside the dynamics

### Chapter 11 - `11-equations-of-motion-kinematics-mass-matrix` - Equations of Motion, Kinematics and the Mass Matrix

- **Level:** advanced. **Prerequisites:** 3, 7. **Research:** pipeline §1.4-§1.6, §2 G, §3; constraint-solver §1.3
  (sparse vs dense); api-io §1.11; warp-perf §1.6; MuJoCo docs "Computation" (equations of motion, spatial notation).
- **Learning objectives**
  1. State the equation of motion `M(q) qacc + c(q, qvel) = tau + J^T f` in generalized coordinates (owner), building
     on the Cartesian rigid-body primer of Ch 3.
  2. Use 6D spatial vectors in MJWarp's (rotation, translation) order, tell motion from force vectors, and explain the
     com-based frame used by `cdof`, `cinert`, `cvel`; read the 10-number `cinert`.
  3. Explain the mass matrix as kinetic energy (`0.5 qvel^T M qvel`) and derive M and c for a 2-link arm in NumPy.
  4. Explain branch-parallel forward kinematics (`smooth.py::kinematics` launching `_kinematics_branch` over
     `body_branches`, `nbranch`) and why redundant recomputation beats per-level synchronization.
  5. Use the contiguous-subtree trick (`body_subtreenum`) for com, crb and RNE backward passes.
  6. Read the CSR mass matrix (`M_rownnz`, `M_rowadr`, `d.M`), convert it to dense and compare with `mj_fullM`; use
     `factor_m`, `solve_m`, `mul_m`, `jac`.
  7. (Expert deep dive, `.deeper`) Describe the per-tree factorization families (`m.M_tiles`: compact, scalar Cholesky,
     tile Cholesky, sparse LDL) and the `qLD` layout.
- **Outline**
  1. From Ch 3 to generalized coordinates (`.recall` Ch 3: 6-DOF bodies, inertia tensor, joints as reduced
     coordinates): the manipulator equation; what M (inertia), c (Coriolis, centrifugal, gravity = `qfrc_bias`),
     tau (`qfrc_passive + qfrc_actuator + qfrc_applied`) and `J^T f` (`qfrc_constraint`) are; this turns Ch 7's force
     budget from an identity into physics (`.recall` Ch 7).
  2. Generalized coordinates vs Cartesian; DOFs vs bodies; why tree algorithms (recursive, O(n)) exist.
  3. Spatial algebra: 6-vectors (rot, trans) (`types.py` `spatial_vector`), motion vs force vectors, the com frame
     ("c" quantities centered at `subtree_com` of the root), `cinert` as 10 numbers (`smooth.py::_cinert`).
  4. Joint math in kinematics: free, ball, slide, hinge, off-center anchors (`xpos = xanchor - R jnt_pos`).
     **Kinematics outputs table** (what learners read constantly, `types.py::Data`): `xpos/xquat/xmat` (body frames),
     `xipos/ximat` (inertial frames, where `body_inertia` is diagonal; `.recall` Ch 3 §5), `geom_xpos/geom_xmat`,
     `site_xpos/site_xmat`, `cam_xpos/cam_xmat` and `light_xpos/light_xdir` (written by `camlight`), `xanchor/xaxis`,
     and later-stage outputs with their stage: `subtree_com`, `cdof`, `cinert` (com_pos), `cvel` (com_vel),
     `actuator_velocity`, `ten_velocity` (velocity stage), `act_dot` (actuation), `cacc/cfrc_int/cfrc_ext`
     (`rne_postconstraint`), `subtree_linvel/subtree_angmom` (`subtree_vel`).
  5. Parallel over branches: `smooth.py::kinematics` → `_kinematics_branch` (one thread per (world, branch), walking
     root to leaf), then per-geom/site poses. `.version`: the dev tree splits this into `kinematics1/kinematics2`.
  6. Subtrees as contiguous ranges (`_subtree_com`, `_crb_subtree`, `_cfrc_subtree`; world body tiled kernel
     `_subtree_com_world`).
  7. `com_pos`: `subtree_com`, `cinert`, `cdof` (`_cdof`); `cdof` is the column of the Jacobian, the key ingredient of
     M and RNE; `camlight`.
  8. `crb` and `_M`: CSR lower triangle with ancestors; armature on the diagonal.
  9. `factor_m`, `solve_m`, `mul_m` (`smooth.py`, `support.py`); Jacobians `support.py::jac`, dense vs sparse
     (`io.py::is_sparse`, nv > 32 with auto). **The factorize subtlety (owner; recalled from Ch 7 §3):** `_forward`
     calls `fwd_position(factorize=False)` then `fwd_acceleration(factorize=True)` (`factor_solve_i`); the public
     defaults are `factorize=True` for both; calling `fwd_position(factorize=False)` + `fwd_acceleration(factorize=False)`
     after changing qpos solves with a stale `qLD`. **Block router overview:** `factor_m` sends each block of M to one
     of four paths: compact blocks (reciprocal diagonals), small full blocks (`_small_cholesky_factorize_block`),
     larger dense blocks (`_tile_cholesky_factorize_block` via `launch_tiled`), oversized blocks (sparse LDL with the
     level schedule `m.qLD_updates`, launched once per level in reverse order, `_factor_i_sparse`).
  10. `.deeper` Factorization families per tree (`m.M_tiles`, `TileSet`), `qLD` layout, `qLD_block_total`,
      `_tile_cholesky_factorize_block` (`wp.tile_load_indexed` then `wp.tile_cholesky_inplace`), block_dim 1 on CPU
      (`.recall` Ch 26 §6 for tiles; the `.deeper` box carries a one-paragraph tile primer for readers who have not
      reached Ch 26).
- **Code examples**
  1. `ex1_two_link_numpy.py` - derive M(q) and c(q, qdot) for the planar 2-link `PENDULUM` by hand in NumPy (Lagrange);
     compare with `mujoco.mj_fullM` and `mjd.qfrc_bias` at 3 random states; print max errors (~1e-12).
  2. `ex2_kinetic_energy.py` - `0.5 qvel^T M qvel` vs `d.energy[:, 1]` in MJWarp (energy enabled) per world; print both.
  3. `ex3_spatial_vectors.py` - print `d.cvel[0, b]` for the pendulum and split into (angular, linear); verify linear
     part = angular × (point - com) relation for one body; print residual.
  4. `ex4_branches.py` - `HUMANOID`: print `m.nbranch`, `body_branches` split per branch, `body_subtreenum`.
  5. `ex5_kinematics_only.py` - random qpos per world → `mjw.kinematics`; compare `xpos`/`xquat` with
     `mujoco.mj_kinematics` per world; print max error.
  6. `ex6_subtree_ranges.py` - compute `subtree_com` in NumPy from contiguous ranges and compare with `mjw.com_pos`
     output; print max error.
  7. `ex7_cdof_vs_jac.py` - `cdof` vs `mujoco.mj_jacBody`-derived columns for a hinge chain; print agreement.
  8. `ex8_csr_to_dense.py` - `PENDULUM` `d.M` with `M_rownnz/M_rowadr` (from `mjm`), densify and compare with
     `mj_fullM`; print both matrices (CSR values ~[0.669, 0.209, 0.090]).
  9. `ex9_solve_mul.py` - `factor_m`, `solve_m(ones)`, `mul_m` round trip on `BALL_DROP` (`[1,1,1,250,250,250]`).
  10. `ex10_site_jacobian.py` - `mjw.jac` for the pendulum tip vs `mujoco.mj_jacSite`; print max error.
  11. `ex11_my_fk_kernel.py` - write a Warp kernel for planar 2-link FK over NWORLD worlds; compare with
      `mjw.kinematics` site positions; print max error and timing.
  12. `ex12_m_tiles.py` (`.deeper`) - print `m.M_tiles` and `qLD_block_total` for `PENDULUM`, `HUMANOID` (one 27x27
      tile, 729), `box_stack(5)` (5 compact 6x6 blocks), and `box_stack(6)` `is_sparse`/`d.efc.J.shape`.
  13. `ex13_stale_factor.py` - the bad mix `fwd_position(factorize=False)` + `fwd_acceleration(factorize=False)` after
      changing qpos vs the correct pairing; print the qacc_smooth error of each (moved here from the pipeline tour).
- **Visuals**
  - Manipulator-equation builder: each term of `M qacc + c = tau + J^T f` is a colored card; hovering a card shows the
    MJWarp field and the stage that computes it (link to the breadcrumb).
  - 2-link arm SVG with sliders for q1, q2: live M (2x2 heat cells) and the kinetic-energy ellipse `qdot^T M qdot = 1`.
  - Spatial vector card: a 6-slot bar (3 rot, 3 trans) with motion/force variants; the com frame drawn at the subtree com.
  - Branch-walk animation (stepper, Rule A): 5 colored threads on the humanoid tree walk their branches in parallel; the
    torso pulses 5 times (redundant work); alternate mode shows level-by-level with barriers.
  - Joint-type interactive SVG: sliders for hinge angle, slide distance, ball axis-angle; shows `xanchor`, `xaxis`, and
    the off-center correction.
  - Contiguous subtree strip: body array in DFS order with the subtree of body 3 highlighted; animated mass summation.
  - **Block router** (interactive SVG, Rule D from ex12): the block-diagonal structure of M for pendulum / HUMANOID /
    box_stack(5) (dumped from `m.M_tiles` and `qLD_block_adr`), each block colored by the factorization path it takes
    (compact / small Cholesky / tile Cholesky / sparse LDL); clicking a block opens the matching stepper. The sparse-LDL
    stepper has a level-schedule frame showing all rows of one `qLD_updates` level updating in parallel.
  - **CSR → tile → factor figure** (stepper): CSR values of the pendulum gather into a dense 2x2 tile, Cholesky runs
    column by column, the factor is written into the qLD ribbon at its block offset; toggle humanoid (structure only).
  - **Factorize timeline** (moved from Ch 7): two rows ("inside `_forward`" vs "calling stages yourself") with a qLD
    chip that turns from fresh to stale; a red third row shows the bad mix (Rule D from ex13).
  - Kinematics-outputs map: a body with its body frame, inertial frame, a geom frame, a site and a camera drawn with
    mini3d (A.8); hovering a frame names the Data field (`xpos`, `xipos`, `geom_xpos`, `site_xpos`, `cam_xpos`).
  - Jacobian column arrows: cdof as spatial axes drawn on a 3-link arm, hover to see the column.
- **Exercises / quiz**: quiz on what c contains, (rot, trans) order, why branches not levels; auto-checked: (1) compute
  `c(q, qdot)` for the pendulum with your own NumPy RNE (two sweeps over 2 links) and assert vs `d.qfrc_bias` per world
  (ex2 already covers the kinetic-energy identity); (2) predict `nbranch` for a 3-arm star robot
  and assert; stretch: predict `M_tiles` for 3 free bodies + a 7-dof arm.
- **Notebook**: setup; ex1-ex13; interactive matplotlib spy plot of M sparsity.

### Chapter 12 - `12-forces-actuators-tendons` - Forces: Passive, Springs, Bias, Actuators and Tendons

- **Level:** advanced. **Prerequisites:** 11. **Research:** pipeline §1.7-§1.8, §2 I, §5; api-io §1.11
  (`util_misc` actuator math); `passive.py`, `smooth.py::rne/tendon/transmission`, `forward.py::_actuator_force`.
- **Learning objectives**
  1. Decompose `qfrc_passive` by name: `qfrc_spring + qfrc_damper + qfrc_gravcomp + qfrc_fluid` (+ adhesion and
     flex terms), and verify each term, including the MuJoCo 4 springs: polynomial stiffness and damping, actuator-added
     damping, and plastic spring references.
  2. Explain RNE's two sweeps and the gravity trick; know `cacc`/`cfrc_ext` are only real after `rne_postconstraint`.
  3. Model actuators as dynamics (`DynType`) + gain (`GainType`) + bias (`BiasType`) through a transmission (`TrnType`),
     with ctrl clamping and forcerange; know the moment arm of each transmission type.
  4. Use MuJoCo 4 actuators in 4.0.1: `nu` controls vs `nactuator` actuators (`actuator_ctrladr`, `actuator_ctrlnum`,
     `actuator_ctrlspec`, `CtrlInput` POS|VEL|FF|VOLTAGE), the DC motor model, `actuator_actearly`; know which
     MuJoCo 4 actuators `put_model` rejects in 4.0.1: PID (`NotImplementedError: ['mjGAIN_PID'] not supported.`) and
     the SO3 ball-joint actuator (it compiles in MuJoCo with transmission `mjTRN_SO3`, which `mjw.TrnType` lacks:
     `NotImplementedError: ['mjTRN_SO3'] not supported`). `GainType.SO3`, `BiasType.SO3` and `CtrlChart` exist in
     `mjw` but no MJCF reachable on 4.0.1 can use them.
  5. Use tendons (fixed and spatial, wrapping) and read `ten_length`, `ten_J`.
  6. Use both fluid models (inertia box and ellipsoid) and wind, and randomize fluid parameters per world.
- **Outline**
  1. Passive forces (`passive.py::passive`, `_spring_damper_dof_passive`, `_gravity_force`, fluid kernels), disable
     flags; the named components `qfrc_spring`, `qfrc_damper`, `qfrc_gravcomp`, `qfrc_fluid` summed into
     `qfrc_passive`. **MuJoCo 4 springs:** polynomial stiffness (`jnt_stiffnesspoly`, `tendon_stiffnesspoly`,
     evaluated with `util_misc._poly_force`), actuator-added damping (`actuator_damping`, `actuator_dampingpoly`
     via `util_misc.actuator_target_damping`, feeding `qfrc_damper`), plastic spring references (the spring reference
     is read from `d.plastic` when `jnt_plasticadr[jntid] >= 0`; `tendon_plasticadr`, `flex_plasticadr`,
     `key_plastic`, `State.PLASTIC`; the reference evolves in `_advance` through `forward.py::_next_plastic_joint`,
     `_next_plastic_tendon`, `_next_plastic_flex_*`, which read `jnt_springyield`/`tendon_springyield`). `.version`
     note: parity of the yield/plastic update with C MuJoCo is verified by the author on CPU before any claim.
  2. Fluid models: inertia-box (body inertia) vs ellipsoid (`geom_semiaxes`, `ellipsoid_max_moment`, geom
     `fluidshape="ellipsoid"`/`fluidcoef`, `m.geom_fluid`), `opt.wind`, `opt.density`, `opt.viscosity`.
  3. RNE as MJWarp runs it (`smooth.py::rne`): forward pass `_rne_cacc_world` then `_cacc_branch` launched
     `dim=(d.nworld, m.nbranch)` (branches walk root → leaf, `.recall` Ch 11 §5); backward pass is *not* a serial
     leaves → root walk: `_cfrc` (all bodies at once), `_cfrc_subtree` (each (world, body) thread sums the contiguous
     range [b, b + body_subtreenum[b]) in one launch, `.recall` Ch 11 §6), `_cfrc_world`; then `_qfrc_bias` projects
     onto cdof. The textbook serial algorithm (as in MuJoCo C) is shown only as a comparison.
  4. Post-constraint quantities (`smooth.py::rne_postconstraint`, `m.opt.run_rne_postconstraint`).
  5. Transmission (`smooth.py::transmission`): JOINT, JOINTINPARENT, SLIDERCRANK, TENDON, SITE, BODY (no SO3 in
     4.0.1); the **sparse actuator moment** layout `d.actuator_moment` with `d.moment_rownnz`, `moment_rowadr`,
     `moment_colind` (a densify snippet: `dense[i, colind[adr:adr+nnz]] = moment[adr:adr+nnz]`) and
     `forward.py::_qfrc_actuator`.
  6. Actuator force pipeline (`forward.py::fwd_actuation`, `_actuator_force`): clamp, dyn, gain, bias, forcerange,
     gravcomp via actuators, `jnt_actfrcrange`; the act_dyn/act_gain/act_bias callbacks run *after* `_actuator_force`
     and overwrite `act_dot`/`actuator_force` (semantics owned by Ch 26 §3).
  7. Actuators in MuJoCo 4: `nu` vs `nactuator`; the ctrl layout read through `actuator_ctrladr/ctrlnum/ctrlspec`;
     `DynType/GainType/BiasType.DCMOTOR` (`util_misc.dcmotor_*`, `dcmotor_slots`) with a VOLTAGE input;
     `actuator_actearly`. Rejected in 4.0.1 (both `.version` callouts): PID (`<pid>` compiles in MuJoCo 4.0.1;
     `mjw.DynType` is NONE, INTEGRATOR, FILTER, FILTEREXACT, MUSCLE, USER, DCMOTOR and `put_model` rejects the gain
     type) and the SO3 ball-joint actuator (`io.py::put_model` TrnType `isin` check rejects `mjTRN_SO3`; the compiler
     also rejects a `ctrlchart` attribute on `<general>`).
  8. Muscles (`util_misc.muscle_gain/muscle_bias/muscle_dynamics`).
  9. Tendons (`smooth.py::tendon`, `util_misc.wrap*`), tendon armature and bias.
  10. External forces `xfrc_applied` → `support.xfrc_accumulate`.
- **Code examples**
  1. `ex1_qfrc_bias_gravity.py` - free ball: `qfrc_bias[z] = m g` (4.905 for 0.5 kg); print it.
  2. `ex2_spring_damper.py` - hinge with `stiffness`/`damping`/`springref`; compare `qfrc_spring`, `qfrc_damper` with
     formulas; then the same hinge with polynomial stiffness (the author takes the MJCF attribute for
     `jnt_stiffnesspoly` from `passive_test.py`) and print `qfrc_spring` against the polynomial formula evaluated in
     NumPy at 3 angles; finally print `qfrc_passive - (qfrc_spring + qfrc_damper + qfrc_gravcomp + qfrc_fluid)` (≈ 0
     without adhesion or flex).
  3. `ex3_actuator_types.py` - motor, position (kp), velocity (kv) actuators on one joint (inline MJCF);
     print `actuator_force` for given ctrl/qpos/qvel (e.g. position kp=20, ctrl=0.5 → 10.0).
  4. `ex4_filter_dynamics.py` - `dyntype="filter"` actuator; print `act` at t = tau, 2 tau, 3 tau vs `1 - e^{-k}`.
  5. `ex5_transmissions.py` - `test_data/actuation/slidercrank.xml` plus an inline site actuator; print
     `actuator_length` and the moment row per actuator at 3 joint angles, densified from `d.actuator_moment` with
     `moment_rownnz/moment_rowadr/moment_colind`.
  6. `ex6_mujoco4_actuators.py` - (a) the verified DC motor:
     `<dcmotor name="dcmotor" joint="joint" input="voltage" motorconst="0.05" resistance="2.0"/>` on a hinge `joint`;
     print `m.nu` (1), `m.nactuator`, `actuator_ctrladr` ([0]), `actuator_ctrlnum` ([1]) and `actuator_force` for
     ctrl 1 (0.025, verified). (b) a "rejected in 4.0.1" demo like ex7: a ball joint `b` with
     `<general joint="b" gaintype="so3" biastype="so3" gainprm="10" biasprm="0 -10 -1"/>` compiles in MuJoCo (print
     `mjm.actuator_trntype` [6], `nu` 3, `nactuator` 1) and `mjw.put_model` raises; print
     `NotImplementedError: ['mjTRN_SO3'] not supported`.
  7. `ex7_pid_rejected.py` - `<actuator><pid joint="j" kp="1"/></actuator>` compiles in mujoco 4.0.1; `put_model`
     raises; print `NotImplementedError: ['mjGAIN_PID'] not supported.` and the `mjw.DynType` members (no PID).
  7b. `ex7b_actuator_damping.py` - an actuator with `actuator_damping` set (author takes the MJCF attribute from
     `passive_test.py`/`derivative_test.py`); print `qfrc_damper` with and without the actuator damping and compare
     with `actuator_target_damping` evaluated by hand.
  8. `ex8_muscle.py` - load `test_data/actuation/muscle.xml`; sweep length; print force at 5 lengths, plot the
     force-length curve.
  9. `ex9_tendons.py` - fixed and spatial tendon (`test_data/tendon/fixed.xml`, `site.xml`); compare `ten_length` with
     C MuJoCo; print values.
  10. `ex10_postconstraint.py` - resting sphere: `cfrc_ext`/`cacc` with flag False then True (0/9.81 vs 9.791).
  11. `ex11_gravcomp_subtree_vel.py` - `gravcomp="1"` body floats (print z drift with/without); `subtree_linvel` zero
      until `mjw.subtree_vel` (print before/after).
  12. `ex12_fluid_models.py` - falling sphere with per-world `opt.density`/`viscosity`, then the same body with the
      inertia-box vs ellipsoid model, then with `opt.wind`; print terminal velocities and the drift under wind.
- **Visuals**
  - **RNE stepper in three phases, named after the real kernels (Rule A):** phase 1 `_cacc_branch`: the Ch 11 branch
    walkers on the 5 HUMANOID branches (from `body_branches`) carry cvel/cacc root → leaf ("world accelerates up by g"
    badge); phase 2 `_cfrc`: all bodies light at once; phase 3 `_cfrc_subtree`: on the DFS-ordered body strip every
    body thread lights its own contiguous range [b, b + subtreenum) at the same time, with a counter of redundant
    additions; then `_cfrc_world` (root sum) and `_qfrc_bias` (projection onto cdof). A greyed toggle "textbook /
    MuJoCo C" shows the serial leaves → root walk for comparison.
  - qfrc_passive decomposition bars (Rule D from ex2): stacked bars per DOF of spring / damper / gravcomp / fluid, with
    the total marker equal to `qfrc_passive`.
  - Actuator pipeline diagram (interactive): ctrl (via `ctrladr`) → clamp → dynamics (act) → gain·ctrl + bias →
    forcerange clamp → moment^T → qfrc_actuator; selecting DynType/GainType/BiasType (incl. DCMOTOR) updates the
    formula shown; SO3 and PID appear greyed with the badge "compiles in MuJoCo, rejected by MJWarp 4.0.1
    (`mjTRN_SO3` / `mjGAIN_PID`)"; a dashed socket after `_actuator_force` marks where act_dyn/act_gain/act_bias
    callbacks overwrite the result (link Ch 26).
  - **Transmission gallery** (type selector): gear on a hinge, slider-crank linkage with an angle slider, site-based
    thrust arrow, tendon; each shows its live moment-arm vector and a strip of the sparse moment row over the dofs.
  - nu vs nactuator diagram: control slots mapped to actuators through `actuator_ctrladr/ctrlnum` arrows.
  - Muscle force-length-velocity interactive curve with sliders (shape from `util_misc.muscle_gain`).
  - Tendon wrap animation: a spatial tendon over a cylinder; length readout as the joint moves.
  - Fluid model comparison SVG: inertia box vs ellipsoid around the same body, with a wind arrow slider.
- **Exercises / quiz**: quiz on when cfrc_ext is zero, nu vs nactuator, which transmission uses a site; auto-checked:
  (1) build a PD servo from a general actuator (gainprm/biasprm) and assert the force formula; (2) assert the
  slider-crank moment arm by finite differences of `actuator_length`; stretch: custom passive drag via
  `m.callback.passive` (recall Ch 8; catalogue in Ch 26).
- **Notebook**: setup; ex1-ex12; plots; parameter-sweep widgets.

### Chapter 13 - `13-integrators` - Time Integration: Euler, RK4, Implicit and Discrete

- **Level:** advanced. **Prerequisites:** 12. **Research:** pipeline §1.9, §1.12, §2 D-E, §4 (9-11), §5.
- **Learning objectives**
  1. Explain `_advance` (activation, velocity, position, time, warmstart) and semi-implicit Euler.
  2. Describe each integrator's math and cost: EULER (implicit damping), RK4 (4 forwards + RKMK), IMPLICITFAST
     (`deriv_smooth_vel`, symmetric, factor with `M - dt*D`), IMPLICIT (RNE derivative, LU), DISCRETE (overview; the
     effective-metric path is owned by Ch 23).
  3. Measure energy behaviour and accuracy; choose an integrator for a task.
  4. Run convergence studies across timesteps in one batched launch.
  5. Know that changing the integrator requires graph recapture and that `step2` with RK4 runs Euler.
- **Outline**
  1. `_advance` in order (`forward.py::_next_activation`, `_next_velocity`, `_next_position` (with
     `math.quat_integrate` for free/ball joints), then, when `m.nplastic > 0`, `_next_rod_twist` and the plastic
     return-mapping kernels `_next_plastic_joint/_tendon/_flex_*` (`.recall` Ch 12 §1), `_next_time_builder`).
  2. Semi-implicit Euler and implicit damping (`euler`, `_compute_damping_deriv`, `_euler_damp_qfrc`, EULERDAMP flag).
  3. RK4 (`rungekutta4`, tableau, `_rk_perturb_state`, `_rk_correct_velocity`, sensors from step start).
  4. IMPLICITFAST (`implicit`, `derivative.deriv_smooth_vel`, `factor_solve_i`; recall the mass matrix, Ch 11).
     README: the IMPLICITFAST midpoint feature is not supported.
  5. IMPLICIT (`implicit_qlu`, `deriv_rne_vel`, `factor_solve_lu`) and its memory cost.
  6. DISCRETE (`discrete`, `check_discrete`) in one section, using exactly the owner's recall line (0.9): "DISCRETE
     solves with an effective metric built from passive stiffness (eff_build/eff_solve); Ch 23 §7".
  7. Per-world timestep and convergence studies.
  8. Choosing: decision guide; costs (pipeline §1.9 table).
- **Code examples**
  1. `ex1_switch.py` - set integrator via XML and via `m.opt.integrator = mjw.IntegratorType.RK4`; print qpos after
     100 steps for each.
  2. `ex2_parity.py` - each integrator vs `mujoco.mj_step` (300 steps, damping 0 and 5); print max |Δqpos| table.
  3. `ex3_energy_race.py` - undamped `PENDULUM` from q=(1.2, 0), dt 0.02, 6 s; print total energy for Euler, RK4,
     implicit, implicitfast (pipeline §1.9 numbers); `--dump-json` feeds the chart.
  4. `ex4_damping_stability.py` - very stiff damping with Euler vs Euler with EULERDAMP disabled; print qvel growth.
  5. `ex5_cost_table.py` - per-integrator time per step for `HUMANOID` (CPU small nworld, GPU big); print table.
  6. `ex6_rk4_sensors.py` - sensordata under RK4 equals start-of-step values; print comparison.
  7. `ex7_deriv_smooth_vel.py` - damped model; allocate `out = wp.empty((d.nworld, m.nC), dtype=float)` (MuJoCo's
     sparse M structure, `forward.py` allocates it this way), call `mjw.deriv_smooth_vel(m, d, out)`, densify with
     `mujoco.mju_sym2dense` using `mjm.M_rownnz`, `M_rowadr`, `M_colind`; compare with `M - dt*D` built from
     `mujoco.mj_fullM` (MuJoCo 4 has no `mjd.qM`); print both matrices.
  8. `ex8_step2_rk4.py` - RK4 model with step1/step2 vs step; print the difference (step2 runs Euler).
  9. `ex9_dt_sweep.py` - per-world timesteps [0.0005 ... 0.02] in one launch; error vs a fine reference; print the
     estimated convergence order per integrator, then a log-log plot.
  10. `ex10_quat_integrate.py` - a free box spinning with gravity off: compare MJWarp's `qpos[3:7]` after 500 steps
      with NumPy implementations of the exact quaternion update and the naive update; print the angle errors and the
      quaternion norm (feeds the quaternion-integrate widget, Rule D).
- **Visuals**
  - Phase portrait extended (`.recall` the Ch 3 explicit vs semi-implicit figure): adds the implicit curve spiralling
    in and the RK4 curve, same dt slider and the same component, so learners compare four integrators on one plot.
  - Energy race chart (Rule D from ex3) plus the world replay player (A.7) showing the real Euler / RK4 / implicit /
    implicitfast pendulum trajectories from ex3 side by side, slowly desyncing.
  - **Quaternion-integrate widget (owner; mini3d, A.8):** a cube spins with an angular-velocity arrow; two ghosts
    compare the correct `math.quat_integrate(qpos_quat, qvel_ang, timestep)` path used by
    `forward.py::_next_position` for free and ball joints with naive "add omega*dt to xyz and renormalize"; a dt slider
    shows the naive ghost drifting. Paired with a strip mapping a free joint's `qpos[3:7]` to `qvel[3:6]`
    (`.recall` Ch 2 §3, Ch 3 §6).
  - RK4 stage diagram (stepper): four forward evaluations with weights 1/6, 1/3, 1/3, 1/6 along the time axis.
  - Damping stability slider: h·b/m; explicit update goes unstable above 2 while the (M + hD) solve stays stable.
  - Integrator decision tree SVG (contacts? stiff damping? flex? accuracy vs speed).
- **Exercises / quiz**: quiz on which integrator uses LU, why changing integrator recaptures; auto-checked: (1) estimate
  the convergence order from ex9 data and assert RK4 > 3; (2) find the largest stable dt for the cartpole per
  integrator with a batched sweep (assert ordering); stretch: implement semi-implicit Euler for a free body by hand.
- **Notebook**: setup; ex1-ex10; interactive energy plot.

### Chapter 14 - `14-sensors-delays-inverse-dynamics` - Sensors, Delays and Inverse Dynamics

- **Level:** advanced. **Prerequisites:** 12, 13. **Research:** pipeline §1.10, §1.11, §1.14, §2 E-F, §2 L;
  collision §1.14 (rays for rangefinder), §1.3 (collision sensors); `sensor.py`, `history.py`.
- **Learning objectives**
  1. Know which sensors are computed in `sensor_pos`, `sensor_vel`, `sensor_acc` and read `sensordata` by address.
  2. Use the full sensor catalogue generated from `SensorType` (incl. MAGNETOMETER with `opt.magnetic`,
     CAMPROJECTION, INSIDESITE, CLOCK, E_POTENTIAL/E_KINETIC, joint/tendon LIMITPOS/VEL/FRC, TACTILE, USER).
  3. Configure rangefinder outputs (`RayDataField` bitmask in `sensor_intprm`), contact sensor outputs
     (`ConDataField`), `sensor_cutoff` clamping and interval sampling (`sensor_interval` period/phase).
  4. Enable and read energy.
  5. Model actuator and sensor delays with history buffers and read delayed values.
  6. Compute inverse dynamics and check the `qfrc_inverse` identity; use it for trajectory torque computation.
- **Outline**
  1. Sensor stages and types (`sensor.py::sensor_pos/vel/acc`), `sensor_adr`, `sensor_dim`; `d.sensordata.zero_()`
     before `sensor_pos` (forward.py); disable SENSOR.
  2. The catalogue table generated from `mjw.SensorType` (`_src.types.SensorType` for the full list) with stage
     (`mjm.sensor_needstage`; `io.py::put_model` partitions sensors into pos/vel/acc lists) and dim.
  3. Acc-stage sensors and `rne_postconstraint` (recall Ch 12).
  4. Ray-based sensors: rangefinder (`ray.rays` used as a black box here; the ray algorithm, filters and BVH are owned
     by Ch 27, forward link), `_sensor_rangefinder` reads `sensor_intprm[sensorid, 0]` as a
     `RayDataField` mask: DIST/DIR/ORIGIN/POINT/NORMAL/DEPTH); collision sensors (GEOMDIST/NORMAL/FROMTO;
     `nxn_pairid[:,1]`); contact sensor with `ConDataField` outputs and `contact_sensor_maxmatch`; tactile
     (`_sensor_tactile`, `_mark_tactile_contacts`, `test_data/collision_sdf/tactile.xml`).
  5. Cutoff (`sensor_cutoff`) and interval sampling (`history.py` reads `sensor_interval`).
  6. Energy (`energy_pos/vel`, flag); RK4 sensor semantics.
  7. Delays (`history.py`): ring buffers, cursor, binary search, interpolation; `read_ctrl`, `read_sensor`,
     `init_*_history`, `reset_history`.
  8. Inverse dynamics (`inverse.py::inverse`), INVDISCRETE, `discrete_acc`; no `event_scope`.
  9. Part III checkpoint project: "Inverse-dynamics trajectory tracking for the humanoid arm".
- **Code examples**
  1. `ex1_sensor_catalogue.py` - iterate `SensorType` and print name, stage and dim for every sensor of a model that
     includes one of each supported kind (author builds the MJCF; types the 4.0.1 compiler rejects are listed as such).
  2. `ex2_imu_magnetometer.py` - accelerometer + gyro + magnetometer on a box resting then tumbling; print readings
     (+9.81 z at rest; magnetometer equals `opt.magnetic` rotated into the site frame).
  3. `ex3_sensordata_slices.py` - `PENDULUM` with per-world ctrl; slice `d.sensordata[:, adr:adr+dim]` per sensor;
     print the matrix. Adds `sensor_slices(mjm)` (name → (adr, dim)) to `my_env.py` (used by the Ch 26 obs kernels
     and Ch 30).
  4. `ex4_rangefinder_dataspec.py` - `<rangefinder site="..." data="dist point normal"/>` (string taken from the
     shipped `sensor_test.py`); per-world heights; print readings and the sensor dim (7).
  5. `ex5_geomdist.py` - `distance` (GEOMDIST) sensor between two geoms over time; print values.
  6. `ex6_contact_sensor.py` - touch sensor plus
     `<contact body1="..." num="4" reduce="maxforce" data="found force normal"/>` (string from `sensor_test.py`)
     under a resting box; print the found count and the force vs m g.
  7. `ex7_cutoff_interval.py` - a velocity sensor with `cutoff` and
     `<jointpos ... delay="0.02" interval="0.03 0" nsample="5"/>` (string from `history_test.py`); print 10 steps
     showing clamping and held values between samples.
  8. `ex8_actuator_delay.py` - `<motor joint="slide" delay="0.03" nsample="5"/>` at dt 0.01, ctrl 1 from step 0;
     print actuator_force over 6 steps: `[0, 0, 0, 1, 1, 1]` in MJWarp, identical to C (verified).
  9. `ex9_sensor_delay.py` - delayed vs fresh jointpos; print the 2-step lag; `read_sensor` at a past time.
  10. `ex10_inverse_identity.py` - `forward` then `inverse`; print max |qfrc_inverse - (qfrc_applied + qfrc_actuator)|.
  11. `ex11_inverse_trajectory.py` - pendulum sine trajectory: required torques with `inverse` for all timesteps in
      parallel (one world per time sample), then replay via `qfrc_applied`; print tracking error.
  12. `ex12_checkpoint_humanoid_arm.py` - Part III project: humanoid right-arm joints follow a smooth trajectory;
      compute torques with `inverse` (one world per sample), replay with gravity, print RMS tracking error and the
      peak torque per joint.
- **Visuals**
  - Sensor stage map: three columns (pos/vel/acc) of sensor chips; hover highlights the Data fields each reads.
  - **sensordata ribbon** for `PENDULUM`: slots [q1 | v1 | tip_pos x,y,z] colored by stage, nworld rows stacked; hovering
    a sensor line in the MJCF snippet highlights its slice and shows the NumPy indexing expression.
  - Rangefinder data-spec builder: checkboxes for DIST/DIR/ORIGIN/POINT/NORMAL/DEPTH build the output layout and dim.
  - Ring buffer stepper (Rule A), pseudo-code panel headed `_history_find_index` / `_history_read_scalar`: logical vs
    physical slots side by side with `physical = (cursor + logical) mod n` as in `history.py::_history_physical_index`;
    the cursor advances on `_history_insert_scalar`; the query time `t - delay` binary search and interpolation; a
    mini world x actuator grid (launches over `(nworld, nactuator)` in `read_ctrl_delayed`, `(nworld, nsensor)` in
    `apply_sensor_delay`) showing that each (world, actuator) thread has its own buffer.
  - IMU arrow widget: box orientation slider; accelerometer arrow shows specific force (+g at rest); magnetometer arrow.
  - Inverse vs forward dynamics diagram; "worlds as time samples" diagram for ex11.
- **Exercises / quiz**: quiz on which stage computes touch, what cutoff does, data spec dims; auto-checked: (1) decode a
  framequat sensor and assert unit norm; (2) assert the ex8 delay in steps; stretch: delayed PD controller, find the
  destabilizing delay with one world per delay.
- **Notebook**: setup; `%%writefile my_env.py` (Ch 14 snapshot); ex1-ex12; plots; "Part III review" quiz.

---
## Part IV. Collision

### Chapter 15 - `15-geometry-toolkit-and-broadphase` - Collision I: Geometry Toolkit, Pair Filtering and the Broadphase

- **Level:** advanced. **Prerequisites:** 9, 11. **Research:** collision §1.3-§1.6, §2.3, §3, §4 (1, 3, 4).
- **Learning objectives**
  1. Use the geometry toolkit the collision chapters rely on: bounding spheres, AABB, OBB, the separating-axis idea,
     closest points between segments, convex vs non-convex shapes.
  2. Explain the model-time pair pre-filter in `io.py::put_model` (the local array `nxn_pairid_contact`: contype/
     conaffinity, weld, dofless, parent-child, exclude, explicit pairs, collision sensors) and `upper_tri_index`.
  3. Describe the four bounding-volume filters and the default `PLANE|SPHERE|OBB`.
  4. Explain NXN (one thread per (world, filtered pair)) and SAP (project, sort, ranges, prefix-sum, sweep with work
     packages).
  5. Choose a broadphase (auto rule: < 250k pairs → NXN; ngeom < 1000 → SAP_TILE; else SAP_SEGMENTED) and benchmark.
  6. Write a broadphase-like filter kernel yourself.
- **Outline**
  1. Geometry toolkit (2D interactives): bounding sphere, AABB, OBB, separating axis theorem, segment-segment closest
     points, convexity and convex hulls (Minkowski sums are introduced in Ch 17).
  2. Two-stage funnel: broadphase candidates (`ctx.collision_pair`, `collision_worldid`, `d.ncollision`) →
     narrowphase contacts (recall the pool bar, Ch 9).
  3. Static pre-filtering in `put_model`: `nxn_pairid_contact` (-2 = never, -1 = default, >=0 = explicit pair id),
     `nxn_geom_pair_filtered`, the two `nxn_pairid` columns (contact, collision sensor), `upper_tri_index` packing.
  4. Filters (`collision_driver.py::_broadphase_filter`, `_plane_filter`, `_sphere_filter`, `_aabb_filter`,
     `_obb_filter`), margins and gaps.
  5. NXN (`_nxn_broadphase` launched `dim=(d.nworld, m.nxn_geom_pair_filtered.shape[0])`, `_add_geom_pair`, atomic
     slot).
  6. SAP (`sap_broadphase`: `_sap_project` on the fixed axis normalize(0.5935, 0.7790, 0.1235), planes get infinite
     intervals, `_segmented_sort` tile (one block per world, recall shared memory Ch 4) vs `wp.utils.segmented_sort_pairs`,
     `collision_core.sap_range`, `array_scan`, `_sap_broadphase` over `nsweep` work items with
     `sap_binary_search` mapping work id → (world, i, j)).
  7. Auto-selection and switching `m.opt.broadphase`, `m.opt.broadphase_filter` (recompiles).
  8. Sleeping and per-world missing meshes skip rules.
  9. Performance and graph considerations (SAP allocates scratch).
- **Code examples**
  1. `ex1_toolkit_numpy.py` - NumPy helpers: AABB overlap, OBB SAT test (2D, 4 axes) and segment-segment closest
     points; print results for 4 test configurations.
  2. `ex2_scatter.py` - defines `scatter(n, seed)` (M9 owner); compiles n=20; print all pairs, filtered pairs,
     `m.nxn_pairid` stats.
  3. `ex3_contype.py` - contype/conaffinity combinations; print which pairs remain.
  4. `ex4_exclude_parent.py` - `<exclude>` and parent-child filtering (FILTERPARENT flag); print pair lists.
  5. `ex5_upper_tri.py` - reproduce `upper_tri_index(ngeom, g1, g2)` in Python and print the packed index of each
     filtered pair next to `m.nxn_geom_pair_filtered`.
  6. `ex6_filters.py` - same scene with filters PLANE, PLANE|SPHERE, PLANE|SPHERE|OBB, PLANE|AABB; print
     `d.ncollision` and identical `nacon`.
  7. `ex7_switch_broadphase.py` - NXN, SAP_TILE, SAP_SEGMENTED; print `ncollision`, `nacon` (identical).
  8. `ex8_scaling.py` - time `mjw.collision` for scatter(n), n in [50, 200, 800, 2000] (CPU smaller) for each
     broadphase; print table, then plot.
  9. `ex9_sphere_filter_kernel.py` - own Warp kernel over `m.nxn_geom_pair_filtered` using `d.geom_xpos`,
     `m.geom_rbound`, margins; count passing pairs with atomics; compare with `ncollision` under filter SPHERE.
  10. `ex10_sap_numpy.py` - re-implement SAP projection/sort/range/prefix-sum in NumPy for one world; print candidate
      count vs MJWarp.
  11. `ex11_explicit_pair.py` - `<contact><pair geom1 geom2 friction=.../>`; print `nxn_pairid` entry and contact friction.
- **Visuals**
  - Geometry toolkit widgets: draggable 2D shapes with live bounding sphere / AABB / OBB; a SAT panel projecting two
    boxes onto candidate axes with overlap bars; two draggable segments with their closest points.
  - Two-stage funnel animation: N² dots for 3 worlds fall through a sieve; survivors queue; counters tick.
  - Filter gallery (4 SVG panels: plane band, sphere halos, AABB, OBB axes) with a rotation slider for box B.
  - **NXN upper-triangle matrix** (ngeom×ngeom): statically skipped pairs greyed (contype/conaffinity, same body, -2),
    others numbered by packed index; hovering cell shows `upper_tri_index(ngeom, g1, g2)` and the thread
    `(worldid, i)` that tests it; toggles for contype bits (this replaces the separate pair heatmap).
  - **SAP stepper (Rule A, pseudo-code headed `sap_broadphase` / `_sap_project` / `sap_range`):** frame 1 is a mini3d
    (A.8) view of the geoms' bounding spheres projected onto the fixed oblique direction
    normalize(0.5935, 0.7790, 0.1235) (a callout states the direction is a constant in the code), each interval radius
    `rbound + max(margin + gap, geom_pair_margin)`, planes (`rbound == 0`) mapped to `MJ_MAXVAL`; frame 2 a 2-world
    sorted array with colored per-world segments, so learners see that sorting never mixes worlds (SAP_TILE: one tile
    per world via `launch_tiled(_segmented_sort, dim=d.nworld)`; SAP_SEGMENTED: `wp.utils.segmented_sort_pairs` with
    `segmented_index`); frame 3 `sap_range` with the binary-search probe drawn on the sorted lower bounds (first lower
    bound greater than the element's upper bound); frame 4 `array_scan` over all worlds. Variable table: lower, upper,
    range. A toggle for the NaN-center / missing-mesh case sends that interval to the end of the axis
    ([MAXVAL, MAXVAL] or inverted).
  - **SAP work-package panel**: cumulative-sum bar of `range[]` across all worlds; nsweep thread markers pick work ids
    w, w+nsweep, ...; a binary-search arrow lands on the owning (world, i) and shows the decoded j. This panel adds
    **atlas layout 3** (work-package sweep, `nsweep = 5 * nworldgeom`) to the shared launch-shape atlas.
  - NXN matrix phone mode (Rule I): below 640px a "focus row" mode shows one geom's row at a time with arrow-key / tap
    navigation; readouts in the caption line.
  - Broadphase decision flowchart (pairs < 250k? ngeom < 1000?).
- **Exercises / quiz**: quiz on filter tradeoffs, what -2 means, SAP vs NXN; auto-checked: (1) contype/conaffinity bits
  for a robot that must not self-collide but must touch the floor (assert the filtered pair list); (2) the NumPy OBB SAT
  test vs `_obb_filter` outcome on 20 random poses; stretch: find the n where SAP beats NXN on your Colab GPU.
- **Notebook**: setup; ex1-ex11; benchmark plot.

### Chapter 16 - `16-primitive-narrowphase` - Collision II: Geom Types and Primitive Colliders

- **Level:** advanced. **Prerequisites:** 15. **Research:** collision §1.2, §1.7-§1.8, §2.5, §2.7, §2.9, §4 (5, 6).
- **Learning objectives**
  1. Read the dispatch table (`collision_driver.py::MJ_COLLISION_TABLE`, plus `MJ_FLEX_COLLISION_TABLE`) and predict
     PRIMITIVE vs CONVEX per pair, including box-box with NATIVECCD disabled.
  2. Explain the two-buffer handoff and the real dispatch model: broadphase candidates → (primitive path) **one fused
     kernel** launched over pool slots whose statically unrolled if-chain contains only the pair types present
     (`m.geom_pair_type_count[idx] > 0`), each thread taking its own branch (lanes in a warp can diverge, recall Ch 4),
     vs (convex path) one grid-stride kernel per present convex pair type → the contact pool; why removing a geom type
     changes the compiled kernel (`cache_kernel` key) rather than skipping a launch.
  3. Explain `write_contact` (strict `<` activation, atomic slot, `includemargin`, `geomcollisionid`) and material
     mixing (`contact_params`: priority, solmix, max friction, max condim, adhesion sum).
  4. Derive the primitive colliders, including box-box SAT + clipping.
  5. Use surface velocity (conveyor belts) and call pure core colliders from your own kernel (private API).
- **Outline**
  1. `GeomType` and the table, generated from `MJ_COLLISION_TABLE` itself: PRIMITIVE pairs incl. sphere-box,
     sphere-cylinder, capsule-box, plane-ellipsoid, plane-cylinder; missing pairs (plane-plane, plane-hfield,
     hfield-hfield); SDF and flex special paths.
  2. Pair ordering and normals (`_add_geom_pair` swap).
  3. The `Geom` struct and `geom_collision_pair` (`collision_core.py`).
  4. Dispatch: `_primitive_narrowphase` launched over pool slots (`dim=d.naconmax`, `tid >= ncollision` returns, worldid
     from `collision_worldid`), `for i in range(wp.static(len(primitive_collisions_func)))` comparing geom types with
     static types; the if-chain is built only from pair types with nonzero `geom_pair_type_count`
     (`collision_primitive.py::primitive_narrowphase`, single `wp.launch(_primitive_narrowphase(...), dim=d.naconmax)`);
     `collision_convex.py::convex_narrowphase` launches one specialized kernel per present convex pair type (grid-stride,
     `_ccd_grid_size`; Ch 17).
  5. `write_contact`, margins/gaps, adhesion; strict boundary difference from C.
  6. Material mixing (`contact_params`, `contact_margin_gap`, `contact_material_params`), per-world materials.
  7. Primitive colliders tour (`collision_primitive_core.py`, `collision_primitive.py`): plane_sphere, sphere_sphere,
     sphere_capsule, capsule_capsule (2 contacts), plane_capsule, plane_box (8 corners → 4), plane_cylinder,
     plane_ellipsoid, sphere_box, capsule_box, box_box (SAT + clipping), plane_convex (hill-climb + `_hull4`),
     `cylinder_triangle` (used by flex/mesh paths).
  8. Surface velocity: `geom_surfacevel` per world, `_contact_surfacevel`, the solver adds it to efc rows when
     `m.flg_surfacevel`.
- **Code examples**
  1. `ex1_collision_table.py` - print `MJ_COLLISION_TABLE` as a GeomType grid with function names per cell, the flex
     table's pairs, and the NATIVECCD effect on box-box (`--dump-json` feeds the heatmap).
  2. `ex2_plane_sphere.py` - sphere at heights z; compare `contact.dist` and `pos` (midpoint) with the formula.
  3. `ex3_capsule_capsule.py` - parallel capsules → 2 contacts; crossed → 1; print counts and positions.
  4. `ex4_plane_box.py` - resting box → 4 contacts; tilted 10 degrees → print count and `geomcollisionid`.
  5. `ex5_material_mixing.py` - two geoms with different friction/priority/solmix/condim; print the mixed contact
     params vs rules.
  6. `ex6_margin_gap.py` - spheres at distances around margin and margin+gap; print detected/active and the
     boundary-case difference vs C.
  7. `ex7_box_box_native.py` - stacked boxes with default (CONVEX, 8 contacts) vs NATIVECCD disabled (PRIMITIVE, 10)
     vs MuJoCo C (10); print counts.
  8. `ex8_type_pair_launches.py` - patch `wp.launch` to record narrowphase launches (kernel key and `dim`) for a scene
     with 3 primitive geom types plus one convex pair, then remove one type; print: one primitive launch in both cases
     (its kernel key changes), the convex launches per pair type, and `geom_pair_type_count` before/after
     (`--dump-json` feeds both dispatch panels).
  9. `ex9_conveyor.py` - a box resting on `<geom type="plane" surfacevel=".5 0 0  0 0 0"/>`; print the box x velocity
     over 300 steps converging to the belt speed (0.49999997, verified) and `contact.surfacevel`.
  10. `ex10_core_kernel.py` - custom kernel calling `collision_primitive_core.sphere_sphere` on 1M random pairs;
      print first results and throughput.
  11. `ex11_vs_mujoco_c.py` - mixed primitive scene: per-contact comparison of dist/pos/normal with `mj_forward` (match
      by geom pair); print max errors.
- **Visuals**
  - Dispatch heatmap generated from ex1 JSON: PRIMITIVE/CONVEX/none, function name per cell on hover, NATIVECCD toggle
    flips box-box; a third layer toggles the flex table.
  - **Dispatch figure, two panels (Rule D from ex8):** (a) Primitive: one kernel row over pool slots; each lit thread
    shows which static branch it took (colored by type pair) with a "warp divergence" overlay linking to the Ch 4
    divergence stepper; threads past `ncollision` greyed; a "remove geom type" toggle deletes a branch from the
    compiled if-chain and shows the `cache_kernel` key changing. (b) Convex: one grid-stride kernel per present pair
    type, T threads striding over the candidates (atlas layout 4, previewed here, owned by Ch 17). Contacts appended to
    the pool bar (A.2) with nacon ticking.
  - Draggable geometry explainers: plane-sphere (dist and midpoint), capsule-capsule closest points (drag to parallel
    to get 2 contacts), box on plane with 8 corners lighting within margin+gap.
  - **Box-box SAT + clipping widget** (2D, stepper): two draggable rotatable boxes, candidate axes with projected
    interval overlaps, the min-overlap axis highlighted, then clipping of the incident face against the reference face
    to up to 4 points; a note that 3D has 15 axes.
  - Material mixing calculator widget (priority, solmix, friction, condim inputs → mixed outputs).
  - Margin/gap band diagram: detected vs active zones along distance axis, strict-< boundary marker.
  - Conveyor animation: belt texture moving, box carried along, surfacevel vector in the contact frame.
- **Exercises / quiz**: predict contact counts for 6 scenes; quiz on normal direction and why per-pair kernels;
  auto-checked: (1) implement `plane_capsule` in your own kernel and assert against MJWarp contacts; (2) predict the
  mixed friction for 5 geom pairs and assert; stretch: implement sphere_box.
- **Notebook**: setup; ex1-ex11; interactive geometry plots with matplotlib.

### Chapter 17 - `17-convex-collision-gjk-epa` - Collision III: Convex Shapes with GJK, EPA and Multi-Contact

- **Level:** expert. **Prerequisites:** 16. **Research:** collision §1.9, §5 (CCD bullets), §4 (7-10, 13).
- **Learning objectives**
  1. Define support functions for each geom type and the Minkowski difference.
  2. Walk through GJK in 3D (signed-volume subdistance `_S1D/_S2D/_S3D` up to a tetrahedron, Frank-Wolfe duality gap
     stop, separation cutoff) and the core-shrink trick for spheres/capsules (`gjk_phase`, `_inflate`).
  3. Walk through EPA (initial polytope `_polytope2/3/4`, closest face, horizon via `_add_edge`, face bit packing,
     `MJ_MAX_EPAHORIZON`, termination) and witness points (`_epa_witness`).
  4. Explain multi-contact clipping (`multicontact`, `_polygon_clip`, `_polygon_quad`) and when it applies.
  5. Size CCD scratch (`naccdmax`), tune `ccd_iterations`/`ccd_tolerance`, read CCD/EPA_HORIZON overflow.
  6. Understand meshes are collided as convex hulls (hill-climbing support).
- **Outline**
  1. Why a general convex path; no MPR in this codebase.
  2. Support functions (`collision_gjk.py::support`), margin inflation by margin/2; Minkowski difference.
  3. GJK (`gjk`, `_gjk_support`, `_subdistance`, `_S1D/_S2D/_S3D`).
  4. `gjk_phase` shrink-and-inflate; deep penetration fallback.
  5. EPA (`epa_phase`, `_polytope2/3/4`, `_epa`, `_add_edge`, face bit packing, `_epa_witness`).
  6. Multi-contact (`multicontact`, `_feature_dim`, `FACE_TOL`, `EDGE_TOL`, `_polygon_clip`, `_polygon_quad`), MULTICCD
     flag, box-box always on.
  7. Kernel structure (`collision_convex.py::ccd_kernel_builder`, `eval_ccd_write_contact`, `_ccd_grid_size`
     grid-stride capped at naconmax, one kernel per convex type pair scanning all candidates; owner of **atlas layout
     4**, grid-stride) and scratch (EPA/multiccd
     arrays allocated inline in `collision_convex.py` in 4.0.1; `.version`: dev tree `prepare_convex_context`).
  8. Meshes: hill-climbing on `geom.graph`, convex hull semantics, non-convex meshes need decomposition.
- **Code examples**
  1. `ex1_convex_scene.py` - cylinder-box, ellipsoid-box, mesh-box pairs; print contacts per pair and `nacon`.
  2. `ex2_support_numpy.py` - NumPy support functions for box/sphere/capsule/ellipsoid; compare with analytic extremes.
  3. `ex3_gjk_2d.py` - teaching GJK in 2D NumPy mirroring the algorithm structure; print simplex per iteration and
     distance for separated and overlapping polygons.
  4. `ex4_gjk_3d.py` - teaching 3D GJK with a tetrahedron case (NumPy, signed-volume subdistance); print the active
     sub-simplex per iteration and compare the distance with MJWarp `contact.dist` for two separated boxes within
     margin.
  5. `ex5_epa_2d.py` - 2D EPA from the GJK simplex; print penetration depth and normal per iteration.
  6. `ex6_mjw_vs_teaching.py` - box-box penetration depth from MJWarp contact vs the teaching code for an axis-aligned
     case; print both.
  7. `ex7_ccd_iterations.py` - deep cylinder-box penetration with `ccd_iterations` 4/8/35 (`override_model(m, [...])`
     then print `m.opt.ccd_iterations`; it returns None); print depth error.
  8. `ex8_naccdmax_overflow.py` - many convex pairs with tiny `naccdmax`; print CCD overflow bit and dropped contacts;
     then print the per-slot scratch sizes `convex_narrowphase` allocates for this model (epa_iterations,
     `10 + 2*epa_iterations` vertices, `6 + MJ_MAX_EPAFACES*epa_iterations` faces, npolygonmax) computed by the same
     rules, times `naccdmax`, in bytes (`--dump-json` feeds the scratch calculator).
  9. `ex9_multiccd.py` - box on box and cylinder on box with and without `DisableBit.MULTICCD`; print contact counts.
  10. `ex10_nonconvex_mesh.py` - an L-shaped mesh acts like its convex hull (ball rests on the hull); print ball z vs the
      expected hull height.
- **Visuals**
  - Interactive GJK canvas labelled "2D analogue": two draggable 2D convex polygons, live Minkowski difference, stepper
    over the simplex (point → segment → triangle) with support direction arrow and duality-gap bar.
  - **CCD scratch calculator** (interactive stacked bars): bytes per CCD slot × `naccdmax`, following
    `collision_convex.py::convex_narrowphase`: `epa_iterations = 16` when every convex pair is box-box, else
    `ccd_iterations`; per slot `10 + 2*epa_iterations` vertices (`epa_vert`, `epa_vert_index`),
    `6 + MJ_MAX_EPAFACES*epa_iterations` faces (`epa_face`, `epa_pr`, `epa_norm2`), `MJ_MAX_EPAHORIZON` horizon
    entries, `npolygonmax` 4 for boxes and ≥ 16 with cylinders/meshes; toggles box-box only / + cylinder / + mesh and a
    `ccd_iterations` slider; Rule D numbers from ex8 shown as markers.
  - **3D GJK view** (mini3d, A.8; drag or arrow keys rotate): a tetrahedron simplex with the active
    sub-simplex (vertex/edge/face/interior region chosen by `_S3D`) highlighted; pseudo-code panel names `_S3D`.
  - **3D EPA step view** (stepper, mini3d): visible faces removed, the horizon loop in orange, the new fan of faces;
    a final frame where the horizon exceeds `MJ_MAX_EPAHORIZON`: the loop turns red and the EPA_HORIZON LED from the
    Ch 9 overflow panel lights; thumbnails
    for `_polytope2/3/4` ("GJK ended with 2/3/4 points").
  - Support function widget: rotate a direction arrow around a shape; support point tracks (box corner jumps, sphere
    smooth, capsule).
  - Shrink-and-inflate animation for capsules (radius fades into a halo, GJK on the segment, inflate back).
  - Multi-contact clipping animation (stepper; Sutherland-Hodgman against side planes, reduce to 4 points by area).
  - Mesh hill-climb on a vertex graph with a rotating direction.
- **Exercises / quiz**: quiz on when EPA runs, what the horizon is; auto-checked: (1) extend the 2D GJK to return witness
  points, asserted on 3 cases; (2) NumPy support function for a cylinder asserted on 8 directions; stretch: measure CCD
  cost by timing `mjw.collision` for convex vs primitive scenes on Colab.
- **Notebook**: setup; ex1-ex10; interactive matplotlib GJK stepping.

### Chapter 18 - `18-heightfields-and-sdfs` - Collision IV: Heightfields, SDFs and User SDF Plugins

- **Level:** expert. **Prerequisites:** 17. **Research:** collision §1.10, §1.11, §2.8; `collision_sdf.py`,
  `test_data/collision_sdf/utils.py`, `collision_driver_test.py` (SDF registration).
- **Learning objectives**
  1. Explain heightfield collision: sub-grid selection, two prisms per cell, GJK per prism, the 4-contact selection.
  2. Explain SDF collision: Halton starts, two-phase gradient descent, `sdf_initpoints`/`sdf_iterations`, many contacts.
  3. Use MuJoCo SDF geom plugins in MJWarp by registering Warp implementations (`register_sdf_plugins`), and write a
     custom analytic SDF.
  4. Build heightfields programmatically with `MjSpec` and size buffers for terrain.
  5. Know the process-level rule for SDF plugins: the `user_sdf` monkeypatch must happen before the first
     collision-kernel compile in the process.
  6. Synthesize Part IV in the checkpoint project (rigid collision paths only; flex collision is Ch 23).
- **Outline**
  1. Heightfields (`collision_convex.py::ccd_hfield_kernel_builder`, `_hfield_filter`), MJ_MAXCONPAIR, HFIELD overflow,
     differences from C (4 vs 6 contacts).
  2. Default buffer heuristics with hfields (`_default_nconmax` term).
  3. SDF narrowphase (`collision_sdf.py::sdf_narrowphase`, `_sdf_narrowphase`, `gradient_descent`, analytic SDFs,
     mesh SDFs, octree volumes). `.version`: dev tree `_sdf_candidates`/`prepare_sdf_context`.
  4. User SDF plugins: `user_sdf(p, attr, sdf_type)` / `user_sdf_grad` are placeholders that print "ERROR: user_sdf
     function must be implemented by user code"; `register_sdf_plugins(mjw)` monkeypatches them with Warp versions of
     `mujoco.sdf.*` plugins (nut, bolt, gear, torus); attributes in `vec_pluginattr`; `io.py` keeps only geom plugins
     (`geom_plugin_index`); `cli.py::load_model` registers them automatically. `torus.xml` cannot be used (asset missing
     in the wheel). io.py: "Flex-SDF collision is not implemented".
     **Pitfall box (verified):** registering after an unregistered run *in the same process* has no effect: kernels
     that already compiled keep the stub (`test_data/collision_sdf/utils.py` assigns
     `mjwarp._src.collision_sdf.user_sdf = user_sdf`), so a later `put_model`/`forward` still gives nacon 0. Patch at
     the top of a fresh process, before any `mjw.put_model`/`forward`/`step`. Also: no SDF or hfield geom in a model
     that has a flex (Ch 23).
  5. Writing your own analytic SDF as a `@wp.func` pair (value, gradient) dispatched by `sdf_type`.
  6. Mesh and volume SDFs are sampled, not analytic: `collision_sdf.py::find_oct` descends an octree to a leaf,
     `sample_volume_sdf`/`sample_volume_grad` interpolate from the leaf corners, `box_project` handles points outside
     the volume; this explains accuracy and cost differences vs analytic SDFs.
  7. Part IV checkpoint project: "Falling clutter" on rigid geometry.
- **Code examples**
  1. `ex1_terrain.py` - `TERRAIN` model 2 worlds 100 steps; print contacts per body and per collision path.
  2. `ex2_hfield_spec.py` - generate a 32x32 random-noise hfield with `MjSpec`, drop 16 balls per world; print final
     heights histogram counts and overflow status.
  3. `ex3_hfield_vs_c.py` - sphere on hfield contact count MJWarp (4) vs C (6); print positions.
  4. `ex4_hfield_overflow.py` - increase hfield resolution until the HFIELD overflow bit appears; print bits and the
     fix.
  5. `ex5_sdf_unregistered.py` - **runs as a subprocess** in the notebook
     (`!python ex5_sdf_unregistered.py 2>&1 | sort | uniq -c | head`): `test_data/collision_sdf/nutbolt.xml` without
     registration; print C ncon (6) vs MJWarp nacon (0) and the count of "ERROR: user_sdf function must be implemented
     by user code" device-printf lines (~800, verified) instead of the lines themselves.
  6. `ex6_sdf_registered.py` - a **fresh process** (separate script, run via `!python` in the notebook) that calls
     `register_sdf_plugins(mjw)` (private badge) at the top, before any mjw call; print MJWarp nacon (4, verified) vs C
     ncon (6), and `m.opt.sdf_initpoints`, `sdf_iterations`.
  7. `ex7_sdf_iterations.py` - sweep `sdf_initpoints`/`sdf_iterations`; print contact count and min dist.
  8. `ex8_custom_sdf.py` - a **fresh process** that first patches a rounded-box SDF written as `@wp.func`
     value/gradient into `mujoco_warp._src.collision_sdf.user_sdf/user_sdf_grad` the same way the helper does, then
     builds a model with a plugin geom (the author reuses the attribute layout of one of the `mujoco.sdf` plugins in
     `register_sdf_plugins` and records which); print contacts of a sphere resting on it.
  9. `ex9_checkpoint_clutter.py` - Part IV project: `TERRAIN` + `scatter(30)` (PRIMITIVE, CONVEX and HFIELD paths, no
     flex, no SDF); measure contacts per collision path (patching launches by kernel name, recall Ch 16 ex8), find the
     first overflow with small budgets (`describe_overflow`), fix `nconmax`/`njmax`/`naccdmax`, print the per-path
     contact table and "overflow: none".
- **Visuals**
  - Heightfield prism animation (stepper): top-down grid, AABB selects sub-grid, cells split into 2 triangles extruded
    into prisms, GJK per prism, 4-point selection (min, farthest, farthest from line, farthest from edge).
  - SDF descent particles: 2D level sets of two shapes, 40 Halton points flowing along the gradient to the contact
    region; slider for iterations.
  - Halton sequence widget: points appear one by one in 2D vs uniform random, showing better coverage.
  - Plugin registration diagram: MJCF `<plugin instance>` → `geom_plugin_index` → `user_sdf` placeholder → patched Warp
    function; red path when unregistered (0 contacts).
  - Custom SDF builder: sliders for box half-sizes and rounding radius; live 2D level-set contour.
  - Octree sampling figure ("2-D quadtree analogue of `find_oct`", labelled as an analogue): a query point descends
    the tree to a leaf, the SDF value is bilinearly interpolated from the leaf corners; a toggle compares it with the
    analytic SDF along a line, with a small error plot showing where sampling loses accuracy.
  - "Fresh process" diagram: two process timelines; in one the stub compiles first and the patch is ignored (0
    contacts), in the other the patch comes first (4 contacts).
- **Exercises / quiz**: quiz on why SDF needs many contacts, what happens unregistered; auto-checked: (1) tune hfield
  resolution to avoid HFIELD overflow (assert no overflow); (2) a sphere SDF via the user hook asserted against the
  analytic sphere contact distance; stretch: a torus SDF.
- **Notebook**: setup; ex1-ex4 in-kernel; ex5, ex6 and ex8 run as `!python exK.py` subprocesses (a markdown cell
  explains why, with a "Runtime > Restart" alternative); ex9 checkpoint; level-set plots; "Part IV review" quiz.

---
## Part V. Constraints, solver and soft bodies

### Chapter 19 - `19-constraints-as-optimization` - Constraints as Convex Optimization

- **Level:** expert. **Prerequisites:** 9, 12. **Research:** constraint-solver §0-§1.5, §2.1, §2.6, §2.9, §3, §4 (1-5).
- **Learning objectives**
  1. Solve a 1-D ball-on-floor toy by hand (Gauss cost + one soft contact row), then state MuJoCo's primal problem
     (Gauss term + soft constraint costs) and why it is convex, not an LCP (rigid vs soft contact).
  2. Read the efc arrays: row layout eq | friction | limit | contact, `ConstraintType`, `ConstraintState`, J (dense
     or CSR), D, aref, pos, vel, frictionloss, force, `contact.efc_address`.
  3. Derive k, b, imp from solref/solimp (`_contact_kbimp`), and D, aref (`_efc_row`), refsafe, `impratio_invsqrt`
     (users set `impratio`; MJWarp stores the inverse square root).
  4. Compare pyramidal vs elliptic cones and condim 1/3/4/6 row counts (derives the Ch 9 black-box formula).
  5. Use all six equality types (CONNECT, WELD, JOINT, TENDON, FLEX, FLEXSTRAIN) with `eq_solref`/`eq_solimp`, and
     toggle them per world.
  6. Verify optimality numerically from MJWarp outputs.
  7. Use the math toolkit the solver chapter needs: minimizing a quadratic, SPD matrices and Cholesky (`.recall`
     Ch 11), convexity, gradient descent vs Newton vs CG on a plain SPD system, and why a linesearch is needed.
- **Outline**
  1. Why contacts are hard: rigid contact as complementarity (LCP) vs MuJoCo's soft convex formulation; the 1-D toy:
     cost `0.5 m (a - a0)^2 + 0.5 D (J a - aref)^2` for an active row, closed-form optimum, then solref/solimp turning it
     into a spring-damper.
  2. **Math toolkit** (owner; mirrored in `reference/math-toolkit.html`): a NumPy 2-D quadratic
     `f(x) = 0.5 x^T A x - b^T x` minimized with gradient descent, Newton and CG side by side (iterate plots); SPD and
     Cholesky recalled from Ch 11; convexity (one minimum, any local minimum is global); a smooth function vs a
     piecewise quadratic (kinks where constraint rows switch state), and why an exact 1-D linesearch on a piecewise
     quadratic is cheap. Each piece is then mapped onto the MJWarp kernels Ch 20 teaches.
  2b. The Gauss principle and soft constraints in general (constraint-solver §1.1); `.recall` Ch 11 (M, qacc_smooth).
  3. Row types and the efc layout (`types.py::Constraint`, `ConstraintType`, `ConstraintState`) and the efc strip
     (owner, Appendix A.3).
  4. `make_constraint` (`constraint.py::make_constraint`): equality kernels, friction loss, limits, contacts
     (`_efc_contact_init`, `_efc_contact_jac_dense/_sparse`, `_efc_contact_update`); row blocks reserved by
     `wp.atomic_add(nefc_out, worldid, k)` per contact, so row order varies between GPU runs (one-line forward link to
     Ch 22; `_sort_constraints` is a stub in 4.0.1).
  5. Sparse CSR Jacobian and the nv > 32 rule, nv > 60 dense refusal. Storage: dense `efc.J` has shape
     `(nworld, njmax_pad, nv_pad)` padded to the 16-wide tile (`TILE_SIZE_JTDAJ_DENSE = 16`); sparse `efc.J` has shape
     `(nworld, 1, njmax_nnz)` with `J_rownnz`/`J_rowadr`/`J_colind` of shape `(nworld, njmax)` and its own
     `OverflowType.NJMAX_NNZ` (types.py `Constraint`).
  6. Softness: `_contact_kbimp`, impedance sigmoid, `_efc_row`, `_efc_D`, refsafe, `impratio_invsqrt`.
  7. Friction: pyramidal rows `J_n ± mu J_t`, elliptic zones (`_eval_constraint`, `_eval_elliptic_middle`), friction
     loss Huber.
  8. Limits and equalities: the six `EqType`s and what each constrains (CONNECT: a point, 3 rows; WELD: a frame, 6
     rows; JOINT: a polynomial joint relation; TENDON: tendon length relation; FLEX: flex edge lengths; FLEXSTRAIN:
     interpolated-flex strain), `eq_solref`/`eq_solimp`, per-world `d.eq_active` (recall Ch 8), `sleep.wake_equality`.
  9. Discrete-integrator regularization difference (`regularize_constraint`), as one paragraph with the owner's recall
     line (0.9) and a forward link to Ch 23 §7.
- **Code examples**
  1. `ex1_toy_1d.py` - NumPy: 1-D ball on floor, one row; closed-form optimal acceleration and force for several
     penetrations; then the same through MJWarp (`BALL_DROP` pressed into the floor); print both forces.
  2. `ex2_inspect_efc.py` - box on plane + hinge with frictionloss (constraint-solver exp1); print ne/nf/nl/nefc,
     types, states, forces vs MuJoCo C.
  3. `ex3_rebuild_cost.py` - rebuild cost and forces in NumPy from `efc.J, D, aref, qacc_smooth, M`; print force match
     and the `M(qacc - qacc_smooth) = J^T f` residual.
  4. `ex4_impedance.py` - implement `imp(x)` from solimp in NumPy; print D for a contact vs `d.efc.D`; plot the curve.
  5. `ex5_solref_sweep.py` - per-world `geom_solref` (timeconst 0.005..0.1) ball drop; print max penetration per world;
     plot penetration over time.
  6. `ex6_cones_condim.py` - pyramidal vs elliptic and condim 1/3/4/6: print rows per contact and forces.
  7. `ex7_frictionloss.py` - joint frictionloss; push with increasing torque; print state transitions
     (QUADRATIC → LINEARPOS).
  8. `ex8_equalities.py` - one model with CONNECT, WELD, JOINT and TENDON equalities (inline MJCF, author compiles);
     print `eq_type`, rows per equality and `pos` violations; FLEX/FLEXSTRAIN rows are shown in Ch 23 ex7.
  9. `ex9_eq_active_worlds.py` - `.recall` Ch 8 ex6 (same toggle, nefc per world) and add only what is new: the
     row-block positions of the weld rows in the efc strip per world and how `contact.efc_address` shifts when the weld
     block disappears; print both tables (`--dump-json` feeds the efc strip).
  10. `ex10_sparse_j.py` - 6 free boxes (nv 36): print `J_rownnz`, `J_rowadr`, `J_colind` and descending columns,
      `d.efc.J.shape` for sparse vs the forced-dense variant (`jacobian="dense"`), and the bytes of each
      (`--dump-json` feeds the J-layout figure).
  11. `ex11_by_hand.py` - `make_constraint` + `solve` after `forward`; print qacc diff (0).
  12. `ex12_math_toolkit.py` - NumPy only: the 2-D SPD quadratic minimized by gradient descent (fixed step), Newton (1
      step) and CG (2 steps); print iterates and final errors; then a 1-D piecewise quadratic with 3 kinks and its exact
      minimizer (`--dump-json` feeds the toolkit figure).
- **Visuals**
  - 1-D toy widget: a ball and floor; sliders for penetration and velocity; live parabola of the cost in `a` with the
    unconstrained and constrained minima.
  - Soft-constraint spring animation: ball sinking into floor; sliders for timeconst and dampratio; live plot of
    `aref = -b vel - k imp pos`.
  - Impedance curve SVG with draggable handles (dmin, dmax, width, mid, power), clamps marked.
  - **efc row strip per world (Appendix A.3, stepper):** blocks eq | friction | limit | contact; each contact thread
    reserves a contiguous block (width = rows for its condim and cone) with a per-world counter; `efc_address` arrows
    from the contact card to its block; red njmax line; a "rerun" button reshuffles the block order while per-row
    contents stay identical.
  - Friction cone math widget (owner of the math; `.recall` the Ch 9 intuition SVG, not redrawn): pyramid (4 edges
    n ± mu t) vs circular cone in mini3d (A.8); drag a force vector; elliptic zones colored.
  - **J layout figure** (dense/sparse toggle, Rule D from ex10): dense mode is a heat-grid of rows × `nv_pad` columns
    with the padding hatched; sparse mode packs the same rows into one value ribbon with `rowadr` arrows and `colind`
    labels; clicking a contact block in the efc strip (A.3) highlights its rows in both layouts; a byte counter for
    each mode linked to the Ch 9 sizing calculator.
  - Math-toolkit figure (Rule D from ex12): contours of the 2-D quadratic with the GD zigzag, the one-step Newton jump
    and the two-step CG path; a second panel shows the piecewise quadratic with its kinks and the exact minimizer.
  - Equality gallery: six small SVG mechanisms (point pin, welded frames, coupled joints, coupled tendons, flex edges,
    strained cell) with their row counts.
  - Cost landscape for a 2-dof toy (contours of the Gauss term plus active half-planes).
- **Exercises / quiz**: quiz on what makes contacts soft, rows per equality type, why row order varies; auto-checked:
  (1) compute rows for a scene and assert vs `d.nefc`; (2) verify force > 0 only when the pyramidal row is active,
  asserted on ex3 data; stretch: add the elliptic cone to the NumPy cost.
- **Notebook**: setup; ex12 (math toolkit) first, then ex1-ex11; the NumPy cost verification as the centerpiece.

### Chapter 20 - `20-solvers-cg-newton` - The Primal Solvers: CG, Newton and the Exact Linesearch

- **Level:** expert. **Prerequisites:** 19. **Research:** constraint-solver §1.6-§1.7, §2.3-§2.5, §2.7, §4 (5-9), §5;
  warp-perf §2.4 (read §1.7-§1.8 knowing they describe the dev tree).
- **Learning objectives**
  1. Trace `solver.solve`: warmstart, `init_context`, iterations, termination, `qfrc_constraint`.
  2. Explain CG (M-preconditioned, Hager-Zhang with beta >= 0) and Newton (H = M + J^T D J, Cholesky variants by nv,
     incremental Hessian, stable fast path).
  3. Explain the exact linesearch on a piecewise-quadratic ray cost with three probe alphas per round.
  4. Set iterations, tolerance (per world), ls_iterations (compile-time), read `solver_niter` and ITERATIONS overflow.
  5. Explain per-world convergence on GPU: the solver loop is a `capture_while` conditional node (`.recall` the Ch 7
     CUDA-graph teaser; Ch 24 owns graphs), and how solver threads map to efc rows (atlas layouts 6 and 7, Ch 7).
  6. Use noslip, and try the experimental `run_qacc_smooth=False` warmstarted-Newton mode.
- **Outline**
  0. `.recall` Ch 19 §2 math toolkit (GD vs Newton vs CG, linesearch on a piecewise quadratic); each section below
     names which toolkit piece it implements.
  1. `solve` and `_solve` flow (`solver.py::solve`, `_solve`, `_solve_init_dof`, `init_context`).
  2. Gradient `grad = Ma - qfrc_smooth - qfrc_constraint`.
  3. CG (`_solve_init_search_cg_tiled`, `_solve_search_update_cg_tiled`).
  4. Newton (`_update_gradient_JTDAJ_dense_tiled`, `_JTDACJ_sparse`, `_cholesky_factorize_solve`, `H_ONE_TILE_MAX=48`,
     `_SPARSE_BLOCK_CHOLESKY_DIM=96`, `block_cholesky.py`, sparse tiles, `_use_incremental`,
     `_update_gradient_h_incremental`). Author W1-checks each name.
  5. Linesearch (`_linesearch_iterative_kernel`, `_eval_pt_direct_3alphas`), `ls_tolerance`.
  6. Termination (`_solve_done`, four conditions), `inertia_scale`, float32 noise floor (`_ALPHA_NOISE_EPS`).
  7. GPU scale: `capture_while(nsolving, ...)` (`.recall` Ch 7 §10; forward link Ch 24 for capture and the CUDA ≥ 12.4
     requirement), `graph_conditional`; how the wheel sizes efc threads per world (author
     reads the 4.0.1 `solver.py` launch dims and documents them). `.version`: the dev tree adds
     `warp_util.side_stream` (J·search ∥ M·search) and `warp_util.efc_threads_per_world` (occupancy-based); neither is
     in 4.0.1.
  8. Warmstart (`qacc_warmstart` set only by `step`), DISCRETE best-of-two (one sentence + the owner's recall line,
     forward link Ch 23 §7); `opt.run_qacc_smooth` (experimental: if
     False, Newton starts every world from `qacc_warmstart` and the step skips `qacc_smooth` and the M factorization;
     `forward_test.py::test_run_qacc_smooth`).
  9. noslip (`solver.py::noslip`): PGS over friction rows, `noslip_tolerance`, memory, DISCRETE unsupported.
- **Code examples**
  1. `ex1_niter.py` - `box_stack(5)` with `njmax=128`, NWORLD worlds with different initial velocities; Newton vs CG x
     pyramidal vs elliptic; print mean/max `solver_niter`.
  2. `ex2_tolerance_per_world.py` - `m.opt.tolerance = wp.array([1e-2,1e-4,1e-6,1e-8])`; print `solver_niter`.
  3. `ex3_iteration_cap.py` - CG with iterations 1/5/20; print niter, ITERATIONS bit and a qacc component; then
     `ls_iterations=1` and print the LS_ITERATIONS bit (1<<10) and the printed warning "linesearch iterations limit
     reached - please increase ls_iterations".
  4. `ex4_convergence_log.py` - for iterations = 1..N rerun one solve from the same state and log the scaled gradient
     norm and improvement for CG and Newton; print the table (`--dump-json` feeds the convergence chart) and a per-world
     niter histogram.
  5. `ex5_numpy_newton.py` - reference primal Newton in NumPy on the Ch 19 ex3 problem (pyramidal), with an exact
     1-D linesearch; print iterates' cost and final qacc vs `d.qacc`.
  6. `ex6_linesearch_plot.py` - evaluate the ray cost along MJWarp's first search direction (NumPy); print the
     minimizing alpha; plot the piecewise quadratic with kinks.
  7. `ex7_warmstart.py` - disable WARMSTART; print niter distribution change.
  8. `ex8_run_qacc_smooth.py` - labelled experimental: `m.opt.run_qacc_smooth = False` with Newton on `box_stack(5)`;
     print time per step and max |Δqpos| vs the default after 200 steps.
  9. `ex9_noslip.py` - box on slope with soft friction creeping; with `noslip_iterations=10`; print drift after 2 s.
  10. `ex10_solver_timing.py` - eager timing for iterations {1,5,20,50} and ls_iterations {5,20}; print table (CPU:
      small table). The graph_conditional on/off comparison moved to Ch 24 (owner of graphs).
  11. `ex11_cholesky_path.py` - print which Newton Cholesky path applies for nv in {13, 30, 60, 120} from the thresholds
      (with model sizes), and time each on GPU.
  12. `ex12_state_flips.py` - `box_stack(5)`: from one state, call the solve with `opt.iterations = 1..k` and dump
      `d.efc.state` per iteration; print a table of how many rows changed `ConstraintState` per iteration (feeds the
      state-flip strip).
- **Visuals**
  - **Solver-iteration stepper (Rule A)**: pseudo-code panel headed `_solver_iteration` with the lines
    update_constraint / update_gradient / linesearch; variable table qacc, cost, alpha, grad norm; drawn on the 2-dof
    cost-landscape contour; driven by a NumPy 2-dof toy that reuses Ch 19's cost and dumps its iterates (Rule D,
    labelled "NumPy teaching solver"); a Newton / CG toggle.
  - **State-flip strip** (Rule D from ex12): one row of efc cells per iteration, colored by `ConstraintState`
    (QUADRATIC / SATISFIED / LINEARNEG / LINEARPOS / CONE); flipped cells, which trigger a rank-1 Hessian update in
    `_update_gradient_h_incremental*`, are outlined.
  - **Convergence chart** (Rule D from ex4): log10 scaled gradient norm and improvement vs iteration, CG vs Newton,
    with a horizontal tolerance line; a per-world niter histogram; the `_solve_done` condition that fired is labelled.
  - Linesearch animation (stepper): piecewise quadratic curve with kinks, three probes per round (lo Newton, hi Newton,
    mid), bracket shrinking; variable table alpha_lo/alpha_hi; pseudo-code names `_linesearch_iterative_kernel`.
  - Hessian assembly + blocked Cholesky tiles (16x16) sweep (stepper); zero tiles grey for the sparse-tiles path.
  - Per-world convergence grid (world grid A.9, Rule D: real `d.solver_niter` per world from ex1/ex4): 64 tiles turn
    green at their own iteration with niter in the corner label; `nsolving` counter ticks down; the `capture_while`
    loop exits at 0 (recall Ch 7 teaser); compare with a fixed loop.
  - Incremental update diagram: only flipped rows add rank-1 updates; other worlds take the fast path.
  - Solver thread-mapping panel (atlas layouts 6 and 7, `.recall` Ch 7) filled with the 4.0.1 launch dims; a
    `.version` inset sketches the dev tree's occupancy-based variant.
- **Exercises / quiz**: quiz on why ls_iterations recompiles, which termination test fired; auto-checked: (1) pick
  solver settings for a stiff grasp so that mean niter < 10 with no ITERATIONS bit (assert); (2) assert the NumPy Newton
  matches `d.qacc` within 1e-4; stretch: extend the NumPy Newton to elliptic cones.
- **Notebook**: setup; ex1-ex12; convergence plots.

### Chapter 21 - `21-islands-and-sleep` - Islands and Sleeping

- **Level:** expert. **Prerequisites:** 20. **Research:** constraint-solver §1.8-§1.9; collision §1.1 (two-pass
  collision with sleep); `island.py`, `sleep.py`, `io.py::put_model/make_data` sleep checks, `_src/cli.py`
  (`--init_asleep`), `island_test.py`, `sleep_test.py`.
- **Learning objectives**
  1. Explain islands and the GPU disjoint-set union (`island.py::_island_dsu`, `_dsu_union`, `_dsu_find`); know that
     `forward` runs island discovery only when sleep is enabled, and that the public `mjw.island(m, d)` can be called
     directly.
  2. Explain sleeping: countdown, cycles, wake triggers, `solver.smooth_solve_compact` and `solver.solve_compact`,
     `nvmax`.
  3. Know every sleep requirement that `put_model`/`make_data` enforce in 4.0.1, and the workaround for
     "start asleep".
  4. Use sleep to make resting scenes cheap and size `nvmax` (NVMAX overflow only fires on the sleep path).
- **Outline**
  1. Islands: definition, DSU on GPU, `compute_island_mapping`; `forward.py::fwd_position` calls `island.island(m, d)`
     only when sleep is enabled; calling `mjw.island` directly fills `nisland`, `tree_island` (author checks which Data
     arrays `make_data` allocates for islands and documents the requirement).
  2. **Sleep requirements table** (all from the 4.0.1 wheel): enable with `<flag sleep="enable"/>` (EnableBit.SLEEP);
     `make_data` computes `sleep_enabled = SLEEP and not DSBL_ISLAND`, so `DisableBit.ISLAND` turns sleeping off even
     when SLEEP is set; Newton only (`ValueError: sleeping requires the Newton solver (got solver=CG)`);
     `SleepPolicy` supports only AUTO, AUTO_NEVER, AUTO_ALLOWED (`types.py`: "unsupported: NEVER, ALLOWED, INIT"),
     so body `sleep="never|allowed|init"` raises `NotImplementedError` in `put_model`; flex equality constraints are
     not supported with sleep (`io.py`: "Flex equality constraints are not supported with sleeping enabled.");
     `nv <= nvmax` for the compacted solve (`io.py` comment near the Newton check).
  3. Sleep (`sleep.py`): `tree_asleep` encoding (initialized to `-(1 + MJ_MINAWAKE)`), `_tree_can_sleep`,
     `opt.sleep_tolerance`, `_build_cycles`, wake functions (incl. `wake_equality`, `wake_collision`), `update_sleep`;
     `_forward` calls `sleep.wake` and `update_sleep` first when sleep is enabled.
  4. Starting asleep without `sleep="init"`: the `_src/cli.py` `--init_asleep` pattern writes
     `mjd.tree_asleep[:] = np.arange(mjm.ntree)` on the host before `put_data` (each tree in a cycle of itself), so
     every world starts asleep; the author reads `cli.py` lines ~167-180 and `io.py::put_data` (which copies the host
     `tree_asleep` before `mj_kinematics` resets it).
  5. Compacted solves (`island.update_active_dofs`, `solver.smooth_solve_compact`, `solver.solve_compact`): gather M
     and J into `nvmax_pad` buffers, dense Newton, scatter back; NVMAX overflow is set only in `island.py` on this
     path, so with sleep disabled a too-small `nvmax` raises no bit.
  6. Collision with sleep: two passes (collision §1.1), `capture_if` usage (`.recall` the Ch 7 CUDA-graph teaser;
     Ch 24 owns graphs); SAP cannot sit inside the conditional.
  7. When sleep helps: many resting objects, clutter, warehouses; when it does not (always-moving robots).
- **Code examples**
  1. `ex1_islands.py` - 6 separated boxes with sleep enabled (Newton); print `nisland`, `tree_island` after forward;
     then sleep disabled + direct `mjw.island(m, d)`; print the same fields.
  2. `ex2_fall_asleep.py` - step until all asleep (CPU: fewer boxes and relaxed `sleep_tolerance`); print
     `tree_asleep`, `ntree_awake`, `nefc` over time (`--dump-json` feeds the sleep replay).
  3. `ex3_wake.py` - push one box with `xfrc_applied`; print which trees wake.
  4. `ex4_nvmax.py` - on the sleep-enabled Newton scene from ex1-ex2: `make_data(nvmax=...)` too small; print the NVMAX
     overflow bit; then the correct size. Second half: the same small nvmax with sleep disabled prints overflow `[0]`
     (verified on a 20-body model with nvmax 6), stating that nvmax only matters with SLEEP enabled.
  5. `ex5_sleep_cost.py` - time per step for an awake vs asleep clutter scene; print ratio.
  6. `ex6_sleep_errors.py` - an error gallery: (a) body `sleep="init"` → `NotImplementedError` from `put_model`; (b)
     sleep with `solver="CG"` → `ValueError`; (c) a flex equality with sleep → `NotImplementedError`; (d) SLEEP plus
     `<flag island="disable"/>` → no error but `tree_asleep` never changes; print each message/result.
  7. `ex7_init_asleep.py` - the `--init_asleep` workaround: set `mjd.tree_asleep[:] = np.arange(mjm.ntree)` before
     `put_data`; print `tree_asleep` and `ntree_awake` after one step (all asleep) and after a push (one tree awake).
  8. `ex8_islands_vs_contacts.py` - a box stack next to separate boxes: print `tree_island` and show that stacked boxes
     share one island while separate ones get their own; then `mjw.island` timing vs nworld (GPU table).
- **Visuals**
  - DSU animation (stepper): trees as nodes; contacts/equalities appear as edges; `atomic_min` hooks merge sets into
    colored islands; variable table shows `parent[]`; pseudo-code names `_dsu_union`, `_dsu_find`.
  - Sleep cycle animation: countdown bars per tree reach 0, trees link into a circular list (t0→t2→t5→t0) and fade to
    grey; a push wakes the whole cycle.
  - Sleep replay (world grid A.9 + replay player A.7, Rule D from ex2): one tile per tree with state fill running /
    asleep=grey and the countdown in the corner label, synced to the box heights.
  - **Gather / solve / scatter animation:** awake dofs slide into a compact `nvmax_pad` buffer, a small dense H is
    factored, results slide back while sleeping dofs stay at 0; an NVMAX overflow state in red.
  - Collision-with-sleep flow SVG: two passes with the `capture_if` diamond.
  - Sleep requirements checklist widget: toggles for solver, island flag, sleep policy, flex equality, nvmax; the
    verdict line shows the exact `put_model`/`make_data` message that would fire.
- **Exercises / quiz**: quiz on when sleep helps, what `DisableBit.ISLAND` does to sleep, which SleepPolicy values
  4.0.1 supports, why NVMAX does not fire without sleep; auto-checked: (1) size nvmax for a scene and assert no NVMAX
  overflow; (2) write `all_asleep(d)` and assert it becomes True for a settled scene within N steps; stretch: measure
  the throughput gain of sleep as a function of the fraction of moving objects.
- **Notebook**: setup; ex1-ex8 (GPU timing cells guarded); requirement checklist as a Python function.

### Chapter 22 - `22-determinism-and-reproducibility` - Determinism and Reproducibility

- **Level:** expert. **Prerequisites:** 19, 20 (21 recommended). **Research:** warp-perf §7; collision §1.13 (contact
  order), §5; pipeline §5 (determinism); `determinism_test.py`; `types.py::DeterminismType`.
- **Learning objectives**
  1. Explain GPU nondeterminism sources: atomic slot order for contacts (Ch 9) and efc rows (Ch 19), float atomics
     (`.recall` Ch 4 teaser), and why order changes results only in the low bits but chaos amplifies them.
  2. Know what `DeterminismType` actually does in 4.0.1: only ATOMICS has an effect (Warp `DeterministicMode.RUN_TO_RUN`
     module option + `deterministic_max_records`); CONTACTS and CONSTRAINT sorts are stubs.
  3. Achieve and test bitwise reproducibility where it is possible (contact-free models) and use the replay technique
     from `determinism_test.py` where it is not.
  4. Know the cost of determinism and when to pay it (RL reproducibility, debugging, regression tests).
  5. Synthesize the Part V solver knowledge in a reproducibility study.
- **Outline**
  1. Sources (`.recall` Ch 4 §9 atomics, Ch 19 §4 row reservation): contact slots via atomic counters, efc row blocks
     via `wp.atomic_add(nefc_out, worldid, k)`, float sums in arbitrary order; chaotic amplification (`.recall` Ch 5
     ex7).
  2. `m.opt.deterministic` setter (bool/int/complement); CONTACTS (`collision_driver._sort_contacts`: `pass`, TODO)
     and CONSTRAINT (`constraint._sort_constraints`: `pass`) are no-ops in 4.0.1; ATOMICS switches the deterministic
     Warp module option in `constraint.py`, `derivative.py`, `bvh.py`, `forward.py`. `.version`: dev tree adds
     `sort.py`. Render: `create_render_context(deterministic=...)` covers flex normals (Ch 27).
  3. Testing reproducibility: the `_Replay` helper in `determinism_test.py` records contacts and constraints and replays
     them, so the remaining pipeline can be compared bitwise under ATOMICS.
  4. Bitwise state restore (`.recall` Ch 8 §4): a reproducible run also needs `State.PHYSICS | State.WARMSTART`
     snapshots.
  5. Cost: steps/s for NONE vs ATOMICS vs ALL (ALL = ATOMICS in 4.0.1); determinism in your own kernels (Ch 26 §8).
  6. Part review quiz (Part V so far) and a forward note: the Part V checkpoint project is at the end of Ch 23.
- **Code examples**
  1. `ex1_deterministic_setter.py` - set True, `~DeterminismType.CONTACTS`, 99; print values and error.
  2. `ex2_atomic_order.py` - float atomic accumulation run twice on GPU (bit differences) and with
     `wp.DeterministicMode.RUN_TO_RUN` module option; print hex of results (CPU: identical, explained).
  3. `ex3_contact_order.py` - `box_stack(5)` on GPU, two runs: print whether the per-world contact order (sorted by
     geom pair) matches and whether the raw slot order matches (CPU: identical, explained).
  4. `ex4_bitwise_contact_free.py` - GPU: two 200-step runs of `HUMANOID` with `DisableBit.CONTACT` (and `PENDULUM`)
     x 1024 worlds with `deterministic=ATOMICS`; print max |Δqpos| (0 expected; the page states the result measured on
     Colab).
  5. `ex5_contact_scene_differences.py` - GPU: `box_stack(5)` runs for NONE, ATOMICS and ALL; print max |Δqpos| and
     whether contact order differed, without asserting 0; explain the stubs.
  6. `ex6_replay_test.py` - a simplified replay test in the style of `determinism_test.py::_Replay` (record
     `d.contact.*` and efc rows from run A, overwrite run B's with them before solve); print bitwise equality under
     ATOMICS (CPU: trivially equal, explained).
  7. `ex7_snapshot_replay.py` - snapshot with `State.PHYSICS | State.WARMSTART` at step 100, run 100 more, restore,
     rerun; print max |Δqpos| on CPU (0.0) and, on GPU, with and without ATOMICS.
  8. `ex8_determinism_cost.py` - GPU: steps/s with NONE vs ATOMICS vs ALL; print table.
  9. `ex9_compare_runs.py` - a reusable `compare_runs(d1, d2, fields)` that reports the first field and world where
     two runs differ bitwise (hex), used by the exercises.
- **Visuals**
  - Determinism matrix: rows (contact slot order, efc row order, float atomics) x columns (NONE, ATOMICS, ALL) with
    "fixed in 4.0.1?" cells; ATOMICS sorts records before summing in an animation.
  - Atomic race animation recall: a link back to the Ch 4 animation plus a new "chaos amplifier" chart (Rule D from
    ex5 on Colab, else labelled illustrative) of |Δqpos| growing over steps.
  - Replay test diagram: run A records contacts/rows → run B replays them → bitwise compare.
  - Contact-order shuffle figure: the pool bar (A.2) for two runs with the same contacts in different slots; a
    "sort by geom pair" toggle lines them up.
  - Decision flowchart: "Do you need bitwise reproducibility?" → contact-free? → ATOMICS; contacts? → replay testing or
    accept low-bit noise.
- **Exercises / quiz**: quiz on DeterminismType bits in 4.0.1, why contact scenes are not bitwise reproducible, what
  WARMSTART adds to a snapshot; auto-checked: (1) write `compare_runs(d1, d2)` that compares fields bitwise and assert
  it on two CPU runs; (2) assert that a PHYSICS|WARMSTART restore reproduces a CPU run exactly while QPOS|QVEL does
  not; stretch: extend the replay test to sensors.
- **Notebook**: setup; ex1-ex9 (GPU cells guarded); results table.

### Chapter 23 - `23-soft-bodies-flex-discrete-integrator` - Soft Bodies: Flex, Cloth, Rods and the Discrete Integrator

- **Level:** expert. **Prerequisites:** 13, 16, 19, 20 (moved after the solver chapters in round 2: most of this
  chapter is dynamics and constraints; heightfields/SDFs are not a prerequisite, they cannot even be combined with a
  flex). **Research:** collision §1.12; render-integrations §1.8, §1.11;
  pipeline §1.9 (discrete); `collision_flex.py`, `passive.py`, `smooth.py::flex`, `support.py`, `derivative.py::eff_*`,
  `io.py` flex checks; `benchmarks/cloth`.
- **Learning objectives**
  1. Model flexes with `flexcomp` (dim 1 rope, dim 2 cloth, dim 3 volumetric) and read flex Data (`flexvert_xpos`,
     `flexedge_length`, ...).
  2. Explain flex elasticity in `passive.py`: stretch and bending, stable Neo-Hookean (`snh_*`, requires the discrete
     integrator), plasticity; elastic rods (`support.rod_*`, `passive.eval_rod_chains`); interpolated (trilinear) flexes
     (`support.add_interp_weight`, `compute_interp_cell_quat`).
  3. Explain flex collision (`collision_flex.py::flex_collision`, `MJ_FLEX_COLLISION_TABLE`, self-collision, per-flex
     BVH) and flex equalities (`EqType.FLEX`, `FLEXSTRAIN`).
  4. Explain the DISCRETE integrator and the effective-metric path (`derivative.eff_build`, `eff_prec`, `eff_solve`)
     (owner of this topic; Ch 13, 19 and 20 forward-link here).
  5. Know the unsupported combinations checked in `io.py` and size buffers for cloth.
  6. Synthesize Part V: tune solver, sizes and integrator for a scene with cloth and rigid contacts under a
     throughput budget.
- **Outline**
  1. What a flex is: vertices, edges, elements; `flexcomp` types and dims; `smooth.flex` updates vertex/edge state.
  2. Elasticity models (passive.py), plasticity (`flex_plasticadr`, `flex_plasticmode`, `_next_plastic_flex_*` in
     `_advance`; `.recall` Ch 12 §1). Passive flex contact as the 4.0.1 wheel has it: `m.has_flex_passive`,
     `passive.py::build_efm_contact`, and the io.py check "Passive contact of interpolated flexes (dof=trilinear or
     quadratic) is not implemented". `.version`: the dev tree's `passive.flex_passive_contact` is not in 4.0.1.
  3. Rods: parallel transport and twist (`support.rod_parallel_transport`, `rod_has_twist`), `eval_rod_chains`.
  4. Interpolated flexes; io.py: "Quadratic flex interpolation (dof=quadratic) is not supported".
  5. Flex collision table, self-collision, flex-geom contacts in the pool (contact `flex`/`elem`/`vert` fields, which
     have shape `(0,)` when `nflex == 0`). **Pitfall box (verified):** a model with a flex cannot contain any hfield
     geom ("Flex-HField collision is not implemented.", even with contype=conaffinity=0), any SDF geom ("Flex-SDF
     collision is not implemented.") or a rigid flex ("Rigid flexes are not implemented.").
  6. Flex equalities (FLEX, FLEXSTRAIN) as efc rows (`.recall` Ch 19 §8 row layout) and io.py "Flex equality
     constraints are not supported with sleeping enabled" (`.recall` Ch 21 §2).
  7. **Discrete integrator and effective metric (owner).** Recall line used elsewhere: "DISCRETE solves with an
     effective metric built from passive stiffness (eff_build/eff_solve); Ch 23 §7." Content: why it is needed (stiff
     elasticity), `forward.py::check_discrete`, `forward.py::discrete`, `derivative.eff_build` (called from
     `fwd_position`), `eff_prec`, `eff_solve`, the `capture_while(efm_nsolving, ...)` loop in `derivative.py`,
     `constraint.regularize_constraint` (the Ch 19 §9 difference), the solver's best-of-two (Ch 20 §8),
     `_launch_discrete_free_gyro` after the solve; errors "discrete integrator: flex with general attachments requires
     solver='CG'", "stable Neo-Hookean elasticity requires integrator='discrete'".
  8. Flex rendering (`flex_render_smooth` option in `create_render_context`, `bvh.refit_flex_bvh`), pointer to Ch 27.
  9. Part V checkpoint project: "Cloth on a box stack under a throughput budget" (model M11 `cloth(n)`: plane +
     `box_stack(2)` + cloth, no hfield/SDF).
- **Code examples**
  1. `ex1_rope.py` - `test_data/flex/rope.xml`; print `m.nflex`, `nflexvert`, and the rope tip z over 100 steps.
  2. `ex2_flex_fields.py` - print shapes of `d.flexvert_xpos`, `flexedge_length` and `m.flexedge_length0`; strain per
     edge after settling.
  3. `ex3_cloth_drop.py` - 6x6 `flexcomp type="grid" dim="2"` cloth started ~0.05 above a sphere (so contacts occur
     within the CPU budget), explicit `nconmax`/`njmax`; 300 steps at dt 0.002; print `flexvert_xpos` min z, nacon and
     the overflow decode; `--dump-json` writes 60 decimated frames of `flexvert_xpos` for the cloth replay.
  4. `ex4_floppy_volumetric.py` - `test_data/flex/floppy.xml`; print volume-element count and center height over time.
  5. `ex5_unsupported_combos.py` - trigger the io.py errors in try/except and print each message: SNH without
     discrete, quadratic interpolation, flex equality with sleep, **Flex-HField** (a 4x4 flexcomp grid plus an hfield
     with contype=0, verified), **Flex-SDF**, **rigid flexes**, passive contact of interpolated flexes.
  6. `ex6_discrete_integrator.py` - a stiff flex with `integrator="discrete"` vs implicitfast: print max strain and
     whether the run stays finite (non-finite guard from Ch 8).
  7. `ex7_flexstrain.py` - `test_data/flex/moving_base_strain.xml`; print `neq`, equality types and the strain rows in
     `d.efc.type`, placed in the efc strip (`.recall` Ch 19 row layout).
  8. `ex8_flex_contacts.py` - the cloth over `scatter(30)` on a plane (no hfield): print contacts per path (flex-geom
     vs rigid primitive/convex, patching launches by kernel name as in Ch 18 ex9) and the `contact.flex/elem/vert`
     fields of the first 3 flex contacts.
  9. `ex9_checkpoint_cloth_stack.py` - Part V project on M11 `cloth(6)`: pick integrator (implicitfast vs discrete),
     solver (Newton/CG), cone, iterations, tolerance, `nconmax`/`njmax` (Ch 9 recipe) so every world converges without
     overflow (`describe_overflow`) while maximizing world-steps/s; print the chosen settings, mean `solver_niter`,
     overflow status and throughput (CPU: tiny budget; Colab prints the learner's numbers).
- **Visuals**
  - Flex anatomy SVG: vertices, edges, triangles/tetrahedra for dim 1/2/3 side by side.
  - Cloth drop replay (world replay player A.7, Rule D from ex3): the real `flexvert_xpos` frames of the 6x6 cloth
    draped over the sphere, drawn as a mesh in mini3d (A.8), with per-triangle BVH boxes toggled on.
  - Rod frame animation (mini3d): parallel-transported frames along a rod with a twist slider.
  - Elasticity model selector: stretch / bend / SNH energy curves vs strain, with the "requires discrete" badge.
  - Discrete integrator flow: build effective metric → precondition → solve, compared with the implicitfast path.
  - Unsupported-combination matrix (Rule D from ex5 messages): rows (SNH, general attachments, interpolation,
    flex-HField, flex-SDF, rigid flex, passive contact of interpolated flexes, flex equality + sleep), columns
    (integrator/solver/feature) with the io.py message on hover/tap.
  - Breadcrumb overlay: where flex work happens in the pipeline (`smooth.flex` in kinematics, `eff_build` in
    fwd_position, flex passive forces in velocity, flex rows in make_constraint, plastic updates in integrate).
- **Exercises / quiz**: quiz on dims, when discrete is required, which flex pairs collide; auto-checked: (1) build a
  rope with `flexcomp` and assert `nflexvert`; (2) assert the cloth min z stays above the sphere top minus a tolerance;
  stretch: compare cloth with and without self-collision.
- **Notebook**: setup; `%%writefile my_env.py`; ex1-ex9; cloth plots and (GPU) a batch-rendered cloth frame;
  "Part V review" quiz.

---
## Part VI. Performance, extension and integration

### Chapter 24 - `24-cuda-graphs` - CUDA Graphs: Capture, Replay and What Gets Baked

- **Level:** expert. **Prerequisites:** 6, 7 (recommended: 20). **Research:** warp-perf §2-§3, §11 (not §1.7-§1.8, dev
  tree); pipeline §2 J; `_src/warp_util.py::check_toolkit_driver`, `io.py` (`opt.graph_conditional`), `solver.py`
  (`capture_while`), `collision_driver.py` (`capture_if`).
- **Learning objectives**
  1. Capture `mjw.step` (and your own kernels) into a CUDA graph and replay it (owner of CUDA graphs; `.recall` the
     Ch 7 teaser).
  2. Know what is baked (Python branches on `m.opt.*`, sizes, pointers) vs live (array contents); know which Option
     knobs update live, which recompile and which need recapture; apply the replace-array rule (`.recall` Ch 6).
  3. Explain conditional graph nodes (`capture_while` in the solver and the discrete integrator, `capture_if` for
     sleep), `graph_conditional`, and the CUDA ≥ 12.4 requirement (`warp_util.check_toolkit_driver`,
     `wp.is_conditional_graph_supported()`), including the fallback on older toolkits.
  4. Measure eager vs graph throughput across nworld correctly, and build the reusable `capture_step` helper.
- **Outline**
  1. Why graphs: JIT + ~100 launches per step dispatch overhead (warp-perf §2.1; `.recall` the Ch 6 throughput curve).
  2. The canonical pattern (warp-perf §2.2) and warm-up: `with wp.ScopedCapture() as cap: mjw.step(m, d)`, then
     `wp.capture_launch(cap.graph)`.
  3. Baked vs live (warp-perf §2.3), the replace-array consequence, recapture rules, `.numpy()` not allowed inside;
     the **knob board**: continuous `opt.*` arrays (live via assign), Python ints and `wp.static` constants (recompile:
     `ls_iterations` → `LS_ITERATIONS`, `broadphase`, `integrator`, `warn_overflow`), and anything that changes
     Python control flow (recapture).
  4. Conditional nodes: `capture_while(nsolving, while_body=_solver_iteration, ...)` (`solver.py`),
     `capture_while(efm_nsolving, ...)` (`derivative.py`, discrete integrator), `capture_if(cond, on_true=_launch)`
     (`collision_driver.py`, sleep); `graph_conditional=False` falls back to a fixed iteration count.
  5. CUDA ≥ 12.4: `check_toolkit_driver` only *warns* ("Model.opt.graph_conditional should be set to False") while the
     default stays `True` (io.py). The fallback idiom (0.4 rule G): `if wp.get_device().is_cuda and not
     wp.is_conditional_graph_supported(): m.opt.graph_conditional = False`.
  6. CPU capture in Warp 1.19: records and replays (verified: capture leaves `d.time` at 0.01, 5 replays give 0.06;
     an assigned timestep and ctrl take effect; replacing `d.qpos` leaves the graph writing the old array); no speedup
     claims on CPU.
  7. Capturing your own kernels together with `mjw.step` (obs/reward, Ch 26; auto-reset, Ch 8) and substeps
     (`nsub` steps per capture).
- **Code examples**
  1. `ex1_capture.py` - warm-up, capture, replay 5x; print `d.time` after each phase (records, does not execute).
  2. `ex2_baked_vs_live.py` - after capture: change `d.ctrl` with assign (affects replay), `m.opt.timestep` with assign
     (affects replay) and `m.opt.integrator` (does not); print qpos evidence.
  3. `ex3_replace_after_capture.py` - replace `d.qpos` after capture (recall Ch 6 ex6); print old vs new arrays after
     replay.
  4. `ex4_eager_vs_graph.py` - world-steps/s for nworld in a sweep (CPU: 1..256; GPU: 1..65536), eager vs graph; print
     table, then log-log plot. Adds `capture_step(m, d, nsub)` (with the graph-conditional fallback) to `my_env.py`.
  5. `ex5_graph_conditional.py` - GPU: `box_stack(5)` captured with `graph_conditional` True vs False; print mean
     `solver_niter`, steps/s and whether results match (moved here from Ch 20); CPU: prints
     `wp.is_conditional_graph_supported()` and the skip note (Rule G).
  6. `ex6_knob_board.py` - for each knob in {`opt.timestep`, `opt.tolerance`, `opt.iterations`, `opt.ls_iterations`,
     `opt.integrator`, `opt.warn_overflow`}: change it after capture, replay, and classify the effect as live /
     needs-recompile / needs-recapture by comparing with eager stepping; print the classification table
     (`--dump-json` feeds the knob board).
  7. `ex7_substeps_and_kernels.py` - capture 4 substeps plus a user reward kernel in one graph; print per-world reward
     after 10 replays vs the eager equivalent (max diff 0 on CPU).
  8. `ex8_toolkit_check.py` - print `wp.get_device()`, the CUDA toolkit/driver versions Warp reports,
     `wp.is_conditional_graph_supported()` and what `capture_step` decided (fallback or not).
- **Visuals**
  - Eager vs graph timeline: CPU lane with ~100 small launch boxes and gaps; GPU lane busy in slivers; graph mode packs
    the GPU lane solid; nworld slider widens GPU boxes.
  - VCR metaphor animation: capture = record (time stays), replay = play (time ticks).
  - Baked vs live circuit: arrays as sockets, Python ifs as soldered switches; "assign" flows, "replace" pulls a plug.
  - **Knob board widget (Rule D from ex6):** real `opt` fields, each marked live / recompile / recapture; turning a knob
    plays the consequence (value flows, JIT spinner, or the graph tape is cut).
  - Conditional-node diagram: a graph with a `capture_while` loop node (nsolving counter) and a `capture_if` diamond;
    a toggle shows the `graph_conditional=False` fixed-iteration unrolled version.
  - Throughput chart (Rule D from ex4 on CPU; the notebook overlays the learner's GPU numbers).
  - Toolkit decision flowchart: driver ≥ 580? → PyPI wheel; else +cu12 → CUDA ≥ 12.4? → conditional graphs or fallback.
- **Exercises / quiz**: quiz on baked vs live items, what changing `ls_iterations` after capture does, why replacing
  an array breaks a graph; auto-checked: (1) assert that a captured graph replays the same qpos as eager stepping
  (CPU); (2) write `needs_recapture(field)` from the knob-board classification and assert it on 5 fields; stretch: find
  the nworld where your GPU saturates with graphs.
- **Notebook**: setup; `%%writefile my_env.py` (Ch 10 snapshot); ex1-ex8 (GPU-only cells guarded with clear messages
  on CPU).

### Chapter 25 - `25-profiling-benchmarking-tuning` - Profiling, Benchmarking and Tuning for Throughput

- **Level:** expert. **Prerequisites:** 24 (recommended: 9, 20, 22). **Research:** warp-perf §4-§6, §12; api-io §1.13;
  pipeline §1.15, §2 K, §5; render-integrations §1.12; `testspeed.py`, `_src/cli.py`,
  `io.py::{find_keys, make_trajectory, load_trajectory}`, `benchmarks/`.
- **Learning objectives**
  1. Profile with `EventTracer` (`.recall` Ch 7 structure) and read ns per world-step.
  2. Use `mjwarp-testspeed` with the full flags table and know the defaults that change results: ctrl noise
     (`--noise_std 0.01`, `--noise_rate 0.1`, `cli._ctrl_noise`), `--nworld 8192`, and `--function` for any public
     `(m, d)` or `(m, d, rc)` function, rendering included.
  3. Understand the benchmarks suite (`run.py`, `sweep.py`, nightly `contrib/systemd` timer).
  4. Replay control trajectories (`make_trajectory`, `load_trajectory`, `--replay`).
  5. Tune buffer sizes, solver settings, broadphase, launch configuration and determinism for throughput with a
     checklist.
- **Outline**
  1. Launch configuration: `m.block_dim` (`BlockDim`) and how tiled kernels pick block sizes (recall GPU model, Ch 4).
     `.version`: dev-tree-only `side_stream` and `efc_threads_per_world` (read-only figure, never called).
  2. Profiling workflow: `event_scope`, `EventTracer(enabled=ON_GPU)` (Rule G), trace dict, ns per world-step.
  3. `mjwarp-testspeed` (`testspeed.py`, `_src/cli.py`): GPU only ("testspeed available for gpu only"). Flags table
     generated from the `DEFINE_*` lines in `_src/cli.py` and `testspeed.py`: `--nworld` (default 8192), `--nstep`
     (1000), `--nconmax`, `--njmax`, `--njmax_nnz`, `--nccdmax`, `-o/--override`, `--keyframe`, `--event_trace`,
     `--noise_std` (0.01), `--noise_rate` (0.1), `--nvmax`, `--init_asleep`, `--device`, `--replay`, render flags
     (`--render_width/--render_height` per camera, `--render_rgb/--render_depth/--render_seg`, `--cam_active`,
     `--camera_name`, `--render_textures`, `--render_shadows`, `--render_skybox`, `--render_backface_culling`),
     and from testspeed.py `--function` (any public mjw function with parameters {m, d} or {m, d, rc}, found by
     `inspect.getmembers(mjw)` in `_FUNCS`), `--num_buckets`, `--format json`, `--measure_alloc`, `--measure_solver`,
     `--memory`, `--overflow_behavior error|continue`, `--clear_warp_cache`, `--info` (the author completes the list
     from the DEFINE lines). Rule: set `--noise_std 0` when comparing with your own eager loop.
  4. Control trajectories: `io.find_keys`, `io.make_trajectory` (linear interpolation between ctrl keyframes, with
     validation errors), `io.load_trajectory` (zero-order hold of an NPZ with `ctrl`/`times`, optional qpos/qvel);
     shipped benchmark NPZ files (aloha `lift_pot.npz`, franka_threading `threading.npz`, sharpa_wave `grasp_mug.npz`).
  5. Benchmarks suite (`benchmarks/*/__init__.py`, `run.py`, `sweep.py`, `kitchen/populate_scene.py`), nightly service
     (`contrib/systemd/mjwarp-nightly.{service,timer}`), rules (no overflow, all worlds converged). The `benchmarks/`
     directory is in the repo, not in the wheel.
  6. Memory vs nworld.
  7. Tuning checklist: nworld, nconmax/njmax from p95, solver/iterations/cone, broadphase, integrator, determinism off
     (cost from Ch 22), sleep (Ch 21), graphs (Ch 24), `warn_overflow` (recompile).
- **Code examples**
  1. `ex1_event_trace.py` - `with EventTracer(enabled=ON_GPU) as t:` around a captured step; on GPU print the trace tree
     in µs and ns/world-step; on CPU print the skip message.
  2. `ex2_testspeed.py` - Rule G guard; `mjwarp-testspeed test_data/humanoid/humanoid.xml --nworld 4096 --nstep 500
     --format json`; parse and print steps/s, ncon/nefc mean/p95, solver_niter.
  3. `ex3_testspeed_noise_function.py` - GPU: testspeed with `--noise_std 0` vs the default (0.01) and
     `--function forward` vs `--function step`; then `--function render --render_width 64 --render_height 64
     --render_depth true`; print a comparison table (steps/s, ncon). CPU: prints the skip note and what each run
     measures.
  4. `ex4_overrides.py` - GPU: testspeed with `-o "opt.solver=cg"`, `-o "opt.iterations=5"`, `-o "opt.cone=elliptic"`;
     print comparison table. CPU fallback: a Python loop applying `io.override_model(m, [...])` (in place) and timing
     50 eager steps per setting.
  5. `ex5_measure_alloc.py` - GPU: `--measure_alloc`; choose nconmax/njmax from p95 + headroom; rerun and compare
     speed. CPU fallback: track max nacon per world and max nefc in a short loop (what `--measure_alloc` reports).
  6. `ex6_trajectory_replay.py` - private badge: `find_keys`/`make_trajectory` on an inline model with 3 ctrl
     keyframes; save an NPZ (`ctrl`, `times`); reload with `load_trajectory(npz, mjm, mjd)`; print the trajectory shape
     and the first rows; GPU: run `mjwarp-testspeed ... --replay file.npz`.
  7. `ex7_memory_vs_nworld.py` - sum of Data array bytes for nworld 1k..64k; print the MB table; on GPU only, also the
     max nworld that fits in `wp.get_device().total_memory` (0 on CPU).
  8. `ex8_tuning_study.py` - apply the checklist to `box_stack(8)` (eager on CPU, graphs on GPU): baseline vs tuned
     settings; print the before/after table of steps/s, mean niter and overflow status.
- **Visuals**
  - Flame/icicle chart from a trace dict (bundled sample labelled "example structure"; the notebook renders the
    learner's own).
  - testspeed anatomy: the `unroll` loop (ctrl noise kernel → function → timing) as a flow diagram; the noise kernel
    box highlighted with "`--noise_std 0` to compare".
  - Flags explorer: the generated flags table filterable by category (sizes, solver, render, measurement), each linked
    to its DEFINE line.
  - Benchmark CI pipeline SVG (commit → testspeed json → jsonl → chart, nightly systemd timer) for `sweep.py`.
  - Tuning checklist board: each item a card with its knob, its cost/benefit and the owning chapter.
  - Memory-vs-nworld stacked bars (Rule D from ex7).
- **Exercises / quiz**: quiz on which flags testspeed needs, why the default noise matters, what `--function`
  accepts; auto-checked: (1) write `pick_budget(maxima, headroom)` and assert on ex5 data; (2) write
  `parse_testspeed(json_text)` and assert it on a bundled sample; stretch: reproduce one nightly-benchmark row on your
  Colab GPU.
- **Notebook**: setup; ex1-ex8 (GPU-only cells guarded); "Part VI tuning checklist" cell.

### Chapter 26 - `26-custom-kernels-and-extending` - Writing Custom Kernels and Extending MJWarp

- **Level:** expert. **Prerequisites:** 4, 24. **Research:** warp-perf §1.4-§1.6, §9-§10; `types.py::Callback`;
  pipeline §1.15; collision §2.9; `contrib/kernel_analyzer`.
- **Learning objectives**
  1. Write analyzer-clean kernels that read `mjw.Data`/`mjw.Model` (conventions: `# Model:`/`# Data in:`/`# Out:`,
     `_in`/`_out`, `worldid % shape[0]`, typed locals, no defaults).
  2. Build observation, reward and done kernels and capture them together with `mjw.step` and the Ch 8 auto-reset in
     one graph.
  3. Hook into the pipeline with the full callback catalogue (control recalled from Ch 8; new here: passive,
     act_dyn/gain/bias, sensor with `_src.types.Stage`, contactfilter).
  4. Feed external contacts into the solver with `opt.run_collision_detection=False` (vs `DisableBit.CONTACT`).
  5. Write kernel factories with `wp.static` and `warp_util.cache_kernel`; know the cache key rules.
  6. Use tiles for per-world reductions (owner of tiles: `launch_tiled`, `tile_load`, `tile_sum`, `tile_store`,
     `tile_load_indexed`), reuse MJWarp `wp.func`s (private API), keep your kernels deterministic.
  7. Test kernels against MuJoCo C (`test_data.fixture` style) and run the kernel analyzer.
  8. Keep per-world custom state in `d.userdata` (`<size nuserdata=...>`, shape `(nworld, nuserdata)`, saved and
     restored with `State.USERDATA`).
- **Outline**
  1. The anatomy of an MJWarp kernel (`.recall` Ch 4 `_next_velocity`) and CONTRIBUTING.md rules.
  2. RL-style kernels: obs/reward/done, preallocated outputs, capture together with the Ch 8 reset (warp-perf §9).
  3. Callback catalogue (`types.py::Callback`) and exact call sites and contracts: `control` (before
     `fwd_actuation`, writes `d.ctrl`); `act_dyn`, `act_gain`, `act_bias` run **after** the `_actuator_force` kernel
     (`forward.py`, `wp.launch(_actuator_force, ..., outputs=[d.act_dot, d.actuator_force])` then
     `if m.callback.act_gain: m.callback.act_gain(m, d)`), which has already applied ctrl clamping, gain, bias and
     forcerange; they overwrite `d.act_dot` / `d.actuator_force` directly. A USER-gain callback does not supply "a
     gain" (forward.py comment: "GainType.USER: gain stays 0, modified by act_gain_callback"): it must write the final
     force, and forcerange is not reapplied (only the tendon actfrc clamp runs later). `passive` (`passive.py::passive`,
     adds to `qfrc_passive`); `sensor` (`sensor.py`, with `Stage.POS/VEL/ACC`, not exported by `mujoco_warp`; import
     `mujoco_warp._src.types.Stage`); `contactfilter` (`collision_driver.py`, after the narrowphase and surfacevel,
     before the contact sort stub): `nacon` cannot shrink; to drop a contact clear the `ContactType.CONSTRAINT` bit in
     `d.contact.type` (constraint.py skips rows with `if not (type_in[conid] & ContactType.CONSTRAINT)`).
  4. User-populated contacts: `run_collision_detection=False` skips collision and keeps whatever is in `d.contact.*`
     and `d.nacon` (Option docstring), while `DisableBit.CONTACT` zeroes contacts each step; `forward.py::fwd_position`
     checks the flag. Fields to write: `dist, pos, frame, dim, geom, worldid, friction, solref, solimp` and `type = 1`
     (CONSTRAINT); `solreffriction` and `includemargin` as needed. **Never write `flex/elem/vert` unless
     `m.nflex > 0`** (shape `(0,)` otherwise; an out-of-bounds write segfaulted the CPU process with exit 139 and
     silently corrupts GPU memory); `efc_address` has shape `(naconmax, ...)` and is filled by `make_constraint`.
     Debugging tip: `wp.config.mode = "debug"` gives bounds checking while developing custom kernels.
  5. Specialization: factories, `wp.static`, `cache_kernel` (`warp_util.py`), `module="unique"`,
     `enable_backward=False`.
  6. Tiles (owner; Ch 4 had only a `.deeper` preview): what a tile is, `launch_tiled(dim, block_dim)`, `tile_load`,
     `tile_sum`, `tile_store`, `tile_load_indexed` (as in `_tile_cholesky_factorize_block`, `.recall` Ch 11), block_dim
     1 on CPU.
  6b. Per-world custom state: `d.userdata` (`m.nuserdata`) as the natural scratch store for env state (episode
     counters, targets), reset with `reset_data` and included in `State.USERDATA` snapshots.
  7. Reusing internals: `math.py`, `collision_primitive_core.py`, `util_misc.py` as `wp.func`s (unstable).
  8. Determinism in your kernels (atomics; `.recall` Ch 22).
  9. Testing: `mujoco_warp.test_data.fixture` (shipped in the wheel), compare with `mujoco.mj_*` at rtol=atol=1e-5,
     nworld 1 and 2 heterogeneous.
  10. The kernel analyzer: issue classes and CLI; contributing workflow.
- **Code examples**
  1. `ex1_reward_graph.py` - reward + accumulate kernels captured with `mjw.step` (warp-perf §9 snippet); print
     per-world totals.
  2. `ex2_obs_kernel.py` - pack qpos, qvel and sensordata (slices from `my_env.sensor_slices`, Ch 14) into an
     `(nworld, nobs)` buffer, and keep a per-world episode counter in `d.userdata` (model with
     `<size nuserdata="2"/>`); compare with NumPy concatenation; print shape, max diff and the counters. Adds
     obs/reward kernels to `my_env.py`.
  3. `ex3_reset_in_graph.py` - capture Ch 8's `reset_done` (imported from `my_env.py`) inside the graph with step +
     done kernel; print episodes per world after replaying 500 steps.
  4. `ex4_passive_callback.py` - quadratic air drag on the ball via `m.callback.passive` writing into `qfrc_passive`;
     print terminal velocity vs analytic.
  5. `ex5_act_gain_callback.py` - a USER gain actuator with `forcerange="-1 1"`; the `m.callback.act_gain` kernel
     computes `force = custom_gain(qpos) * ctrl` and writes `d.actuator_force`; print `actuator_force` vs the formula
     and assert that it exceeds the forcerange (forcerange is not reapplied after the callback).
  6. `ex6_sensor_callback.py` - user sensor `<sensor><user name="u" dim="2" needstage="pos" datatype="real"/></sensor>`
     (verified to compile, nsensor 1) filled by `m.callback.sensor(m, d, stage)` comparing `stage` with
     `mujoco_warp._src.types.Stage.POS` (private badge); print sensordata.
  7. `ex7_contactfilter.py` - a contactfilter callback launching a kernel over `naconmax` that clears the
     `ContactType.CONSTRAINT` bit in `d.contact.type` for contacts whose geom is in group 3; print `nacon` (unchanged)
     and `nefc` per world with and without the filter (fewer rows).
  8. `ex8_user_contacts.py` - `run_collision_detection=False`; a kernel writes one contact per world into exactly
     `dist, pos, frame, dim, geom, worldid, friction, solref, solimp` and `type = 1` (never `flex/elem/vert` here,
     nflex 0) and sets `d.nacon = 2` for 2 worlds; step; print `nefc` per world and the resulting `efc.force`
     (verified: nefc [4 4], efc.force 2.9549, equal to C MuJoCo's 2.954875) and compare with DisableBit.CONTACT → 0
     rows.
  9. `ex9_factory.py` - `cache_kernel` factory specialized by an int power and a bool; print cache keys and identity.
  10. `ex10_tile_contact_force.py` - per-world sum of contact normal forces via a tiled reduction over the contact
      pool grouped by world (`launch_tiled(dim=d.nworld, block_dim=...)`, `tile_load`, `tile_sum`); compare with a
      NumPy bincount of `mjw.contact_force` output; print values (the kinetic-energy identity stays in Ch 11 ex2).
  11. `ex11_reuse_math_test.py` - kernel using `math.quat_to_mat` to compute body tilt per world, plus a unittest
      comparing it with `mujoco.mju_quat2Mat` for 2 heterogeneous worlds; print the test result.
  12. `ex12_kernel_analyzer.py` - notebook-only (script skips if the clone is absent): clone the repo
      (`git clone --depth 1 https://github.com/google-deepmind/mujoco_warp` and check out the tag matching 4.0.1 if one
      exists, else add a version note), then run
      `python mujoco_warp/contrib/kernel_analyzer/kernel_analyzer/cli.py my_kernel.py --types $(python -c 'import
      mujoco_warp._src.types as t; print(t.__file__)')` on a learner file with deliberate issues; print the issue list.
- **Visuals**
  - Reward kernel grid animation: rows = worlds; each thread draws a distance arrow to the target and drops a number
    into `reward[worldid]`.
  - Callback socket map on the pipeline breadcrumb (Appendix A.1): where each callback fires and what it may write;
    act_dyn/act_gain/act_bias drawn *after* the `_actuator_force` box with "overwrites act_dot / actuator_force,
    forcerange not reapplied"; contactfilter after narrowphase + surfacevel with "clear CONSTRAINT bit; nacon
    unchanged".
  - User-contacts vs disabled-contacts diagram: your kernel writing into the pool bar (Appendix A.2) and the solver
    consuming it, vs DisableBit.CONTACT zeroing it.
  - Factory specialization tree: one Python factory → several compiled kernels keyed by arguments; cache hits glow.
  - Tile cooperation animation (stepper): 32 threads load a row into shared memory and tree-reduce.
  - Analyzer before/after code diff with issue badges (`MissingBatchModulo`, `InvalidSuffix`, `MissingComment`, ...;
    author takes names from the analyzer source).
- **Exercises / quiz**: quiz on cache_kernel key rules, run_collision_detection vs DisableBit.CONTACT; auto-checked:
  (1) a contact-count-per-world kernel asserted vs NumPy; (2) an obs kernel asserted against a NumPy reference;
  stretch: a custom passive spring field via the callback.
- **Notebook**: setup; ex1-ex12; graded exercise asserts.

### Chapter 27 - `27-rays-lidar-and-batch-rendering` - Rays, Lidar and Batch Rendering for Thousands of Worlds

- **Level:** expert. **Prerequisites:** 15, 24 (recommended: 10). **Research:** collision §1.14; render-integrations
  §0-§1.12, §2.1-§2.5, §3-§5.
- **Learning objectives**
  1. Cast rays with `mjw.ray` and `mjw.rays` (filters, outputs), build a batched lidar (owner of rays; Ch 14 used
     `rays` as a black box).
  2. Explain the world-grouped scene BVH (`bvh.py::build_scene_bvh`, groups = worlds), refit vs rebuild, and use it to
     accelerate rays and rendering.
  3. Use the four-call render pipeline and every `create_render_context` option (4.0.1 signature; no `backend`),
     always as keyword arguments, and know the pitfalls (geom groups ≥ 3 invisible by default, skybox needs a skybox
     texture, compile-time toggles).
  4. Explain `compute_ray` (pinhole, intrinsics, ortho), znear/zfar, planar depth, and how a render thread finds its
     camera and pixel.
  5. Explain the specialized megakernel and shading (Blinn-Phong, shadows, textures, skybox, supersampling).
  6. Decode output buffers (uint32 ARGB, depth, seg `(objid, objtype)`), use `get_rgb(rc, camera_index, rgb_out)`.
  7. Apply visual domain randomization and capture render into a graph to produce observation tensors and videos.
  8. Render Gaussian splats (per-world splat sets) alongside meshes.
  9. Use camera modes (fixed, track, trackcom, targetbody, targetbodycom) and lights, and the ordering rule for writing
     cameras by hand.
- **Outline**
  1. Rays (`ray.py::ray`, `rays`, `_ray_eliminate`, analytic ray-geom functions, tiled argmin), `geomgroup`
     (`types.vec6`), `flg_static`, `bodyexclude`; rangefinder link (`.recall` Ch 14).
  2. Scene BVH (`bvh.py::build_scene_bvh`, `_compute_bvh_bounds`, `group_root`, `refit_bvh`, `build_mesh_bvh`,
     `_optimize_hfield_mesh`), rays with `rc=`.
  3. Render pipeline (`render_util.py::create_render_context`, `bvh.py::refit_bvh`, `render.py::render`, `get_rgb/
     get_depth/get_segmentation`).
  3b. **Options table**, generated in ex12 from `inspect.signature(mjw.create_render_context)`: `nworld`, `cam_res`,
     `render_rgb/depth/seg`, `use_textures`, `use_fast_math`, `use_shadows`, `use_ambient_lighting`,
     `enabled_geom_groups` (default `[0, 1, 2]`: geoms in group 3+ are silently invisible), `cam_active` (bools, names
     or indices), `background_color`, `flex_render_smooth`, `use_precomputed_rays`, `render_skybox` (needs an
     `mjTEXTURE_SKYBOX` texture), `enable_backface_culling`, `shadow_light_fraction`, `samples_per_pixel`,
     `enable_vertex_normals`, `enable_specular`, `enable_emission`, `enable_per_light_ambient` (compile-time toggles,
     like `use_fast_math`), `splat_*`, `deterministic` (covers flex normals). Rule: keyword arguments only. Pitfall
     callout: the repo's own `contrib/render.py` passes `_USE_SHADOWS.value` as the 8th positional argument, which is
     `use_fast_math`, so its `--shadows` flag never enables shadows.
  4. Cameras and rays (`render_util.py::compute_ray`), MJCF camera `resolution`/`output` defaults, `cam_active`,
     orthographic cameras from `cam_projection` (`ProjectionType.ORTHOGRAPHIC`). **Camera and light modes**
     (`smooth.py::camlight`, called in `fwd_position` every forward): `cam_mode` fixed / track / trackcom / targetbody
     / targetbodycom with `cam_targetbodyid`, `cam_poscom0`; `light_mode`, `light_type`, `light_castshadow`,
     `light_cutoff`, `light_exponent`. **Ordering rule for manual camera writes:** camlight recomputes
     `d.cam_xpos/cam_xmat` every forward, so write them after `forward`/`step` and before `refit_bvh`/`render`,
     every frame.
  5. Thread mapping: `render.py` launches `dim=(d.nworld, rc.total_rays)`; `total_rays` concatenates all cameras'
     pixels; per-camera ray offsets and `rc.cam_id_map` (shape `(ncam,)`) let a thread find its camera and
     pixel (author reads the exact lookup in `render.py`; launch-shape atlas, Ch 7).
  6. Megakernel (`render.py::_build_megakernel`), static specialization, caching on `rc._megakernel`.
  7. Shading (`_make_compute_lighting`), shadows (`shadow_light_fraction`), textures (`_texture_*`), skybox, backface
     culling, vertex normals, supersampling.
  8. Buffers and layout (rgb/depth/seg addresses).
  9. Visual DR (render-integrations §1.7; `.recall` Ch 10).
  10. Flex rendering (`flex_render_smooth`, `refit_flex_bvh`; `.recall` Ch 23). **Gaussian splats:**
      `create_render_context(splat_position, splat_rotation (wxyz), splat_scale (std dev), splat_rgba, splat_adr,
      splat_group_id)` with per-world splat sets via `splat_group_id`; `bvh.py::build_splat_bvh`,
      `refit_splat_bvh(rc)`; `render.py::ray_splat`, `shade_splats`. A short walkthrough of `contrib/render.py`
      (a repo script, not installed by pip): its 3DGS PLY loader `_load_ply_splats` (`--splat file.ply`) and the
      `--tiled`, `--rollout`, `--orbit` modes. `.version`: OptiX backend dev tree only.
  11. Performance: resolution, flags, graph capture.
- **Code examples**
  1. `ex1_single_ray.py` - `mjw.ray` down onto a geom, with `bodyexclude`; print dist/geomid/normal (1.4 then 2.0).
  2. `ex2_lidar.py` - 360-ray horizontal lidar per world with `mjw.rays` and per-world robot positions; print min range
     per world; polar plot.
  3. `ex3_ray_filters.py` - geomgroup (`types.vec6`), `flg_static=False`; print which geoms get hit.
  4. `ex4_rays_bvh.py` - same as ex2 with `rc = mjw.create_render_context(...)` and `rc=`; time vs no-BVH for many geoms.
  5. `ex5_grid16.py` - render-integrations §2.1: 16 worlds RGB/depth/seg (CPU: 4 worlds at 32x32); save a 4x4 RGB grid
     and depth grid; print mean pixel values.
  6. `ex6_buffer_layout.py` - two cameras with different resolutions; print `rgb_adr`, `depth_adr`, `seg_adr`,
     `total_rays`; manual uint32 unpack equals `get_rgb`.
  7. `ex7_stale_bvh.py` - move the sphere without refit; print sphere pixel counts 16 → 0 → 18.
  8. `ex8_depth_and_seg.py` - `rc.depth_data` metric depth vs `get_depth` clamped at the image center; colorize seg ids
     and print unique (objid, objtype) pairs.
  9. `ex9_shading_options.py` - toggle `use_shadows` and `samples_per_pixel` 1 vs 2; print changed pixel count, shadow
     pixel ratio (~0.3) and ray buffer sizes.
  10. `ex10_visual_dr.py` - per-world `geom_rgba` and `cam_fovy` with `use_precomputed_rays` True vs False; print sphere
      pixel counts `[52,52,52]` vs `[256,52,12]`.
  11. `ex11_video_graph.py` - capture physics and render graphs (GPU; CPU: eager, few frames); render a rollout of
      world 0 to video and print frames/s vs nworld (GPU table).
  12. `ex12_options_and_groups.py` - print the options table from `inspect.signature`; then a scene with one geom in
      group 3: its pixel count is 0 with the default `enabled_geom_groups` and > 0 with `[0, 1, 2, 3]`; then
      `cam_active=["side"]` by name; print the counts.
  13. `ex13_splats.py` - N random splats generated in NumPy (no PLY needed) in two splat groups mapped to worlds 0 and
      1 via `splat_group_id`; render RGB at 32x32 (CPU) and print per-world pixel stats with and without splats;
      `--dump-png` feeds the splat figure.
  14. `ex14_camera_modes.py` - a `trackcom` camera and a `targetbody` camera following a falling body across 4 worlds;
      print `d.cam_xpos` per world over 5 frames; then overwrite `d.cam_xpos/cam_xmat` after `step` and before
      `refit_bvh`/`render` and print that the image changed (the ordering rule).
- **Visuals**
  - Lidar sweep animation (SVG laser sweeping), tiled-argmin vs BVH traversal comparison diagram.
  - Grouped BVH tree: root splits into per-world subtrees; a ray of world 2 lights only that subtree; refit animation
    stretches boxes.
  - Pinhole frustum SVG with fovy slider (CSS vars), pixel grid on near plane, ray through pixel center; perspective vs
    ortho toggle.
  - Planar vs ray depth side-view diagram.
  - **Stale-BVH flipbook** (Rule D images from ex7): the real 3 frames (before / moved without refit / after refit)
    with the sphere pixel counts 16 → 0 → 18 under each.
  - **Output-buffer mosaic** (built on the real 32x32 pixels of ex5/ex6, Rule D images; Rule I tap/keyboard and a
    phone zoom mode): two cameras x two worlds; hovering or tapping a pixel decodes its real uint32 ARGB value, depth
    and `(objid, objtype)`, highlights thread `(worldid, rayid)` and the camera segment of the flat ray range, and
    shows the rgb/depth/seg address it writes; a uint32 AARRGGBB bit diagram. This adds **atlas layout 5**
    ((world, ray) grid) to the shared atlas.
  - Splat shading figure (Rule D image from ex13 + SVG): a ray passing through overlapping Gaussian ellipses, alpha
    accumulating front to back (`shade_splats`), next to the real two-group render.
  - Camera-modes widget (mini3d): a falling body with fixed / track / trackcom / targetbody cameras drawn as frusta;
    the learner picks a mode and scrubs time (Rule D trajectory from ex14).
  - Shading equation builder: toggles for ambient/diffuse/specular/headlight/shadow/emission on a sphere (CSS blend
    layers) with the active formula terms highlighted.
  - Visual-DR contact sheet (Rule D images from ex10): the real per-world frames with `use_precomputed_rays` True vs
    False, sphere pixel counts under each.
- **Exercises / quiz**: quiz on (W,H) vs (H,W), camera_index meaning, when to refit; auto-checked: (1) build a pixel
  observation tensor `(nworld, 3, H, W)` and assert shape/dtype/range; (2) a lidar minimum-range function asserted vs
  geometry for a known scene; stretch: orbit camera by writing `d.cam_xpos/xmat` after `step` and before `refit_bvh`/`render` every frame.
- **Notebook**: setup (+EGL only for comparison); ex1-ex14; image grids and polar plots inline.

### Chapter 28 - `28-interop-torch-and-jax` - Interop with PyTorch and JAX

- **Level:** expert. **Prerequisites:** 24, 26. **Research:** render-integrations §2.6-§2.8, §2.10; warp-perf §9
  (interop bullet); `_src/jax_test.py`, `_src/io_jax_test.py`, `contrib/jax_unroll.py`,
  `contrib/apptronik_apollo_locomotion.ipynb` (custom_vmap).
- **Learning objectives**
  1. Share MJWarp arrays with PyTorch zero-copy (`wp.to_torch`, `wp.from_torch`) and know the dtype/stream/contiguity
     caveats (§1-§3 are all the RL capstone needs; the env wrapper itself is built in Ch 30).
  2. Wrap an MJWarp step as a JAX op with `wp.jax_callable` (`graph_mode=wp.JaxCallableGraphMode.WARP`,
     `output_dims`), unroll with `lax.scan`, and configure the XLA environment variables before the first jax import.
  3. Know what is stale in `contrib/jax_unroll.py` and use the corrected course version.
  4. Know the MJX `impl="warp"` path, the `io_jax_test` field contract and the `custom_vmap` batching pattern
     (pointers only).
- **Outline**
  1. Zero-copy memory sharing (DLPack): one GPU buffer, several views; `wp.to_torch(d.qpos)` aliases; writes from torch
     are visible to Warp. Version print block: `torch.__version__`, `torch.cuda.is_available()`, Warp device (Colab's
     torch is a CUDA 12 build next to a CUDA 13 Warp build; driver ≥ 580 matters, `.recall` Ch 1).
  2. Caveats: dtypes (float32 everywhere; vec3 arrays become `(..., 3)` tensors), contiguity, streams
     (`wp.stream_from_torch` / synchronize when torch and Warp use different streams), uint32 RGB buffers (Ch 27).
  3. Feeding actions in: `wp.from_torch` + `wp.copy` into `d.ctrl` (never replace `d.ctrl`, `.recall` Ch 6/24).
  4. JAX bridge, following `jax_test.py` exactly: set `XLA_FLAGS=--xla_gpu_graph_min_graph_size=1`,
     `XLA_PYTHON_CLIENT_ALLOCATOR=platform` and `XLA_PYTHON_CLIENT_PREALLOCATE=false` **before** `import jax` (JAX
     otherwise preallocates most GPU memory and starves Warp); skip unless `jax.default_backend() == "gpu"`; closure
     over `m, d`, copy in/out, `wp.jax_callable(..., graph_mode=wp.JaxCallableGraphMode.WARP, output_dims=...)`, set
     `m.opt.graph_conditional` explicitly; fixed NWORLD; `lax.scan` unroll. Use Colab's preinstalled JAX; never
     `pip install jax` (it can replace the matched jax/jaxlib).
  5. `contrib/jax_unroll.py` as a pattern, with a "what is stale" callout: it loads
     `resource_path('mujoco_warp') / '../benchmark' / 'humanoid/humanoid.xml'` (the repo directory is `benchmarks`, and
     it is not in the wheel); it passes `nconmax=64*NWORLDS`, but `nconmax` is per world in 4.0.1 (`naconmax` is the
     total), so it asks for ~4e9 contacts; it calls `wp.clear_kernel_cache()` at import. The course version fixes all
     three.
  6. `custom_vmap` bridging (Apollo notebook) as a pattern: 8192 per-env calls collapse into one batched Warp call.
  7. MJX `impl="warp"` (docs pointer; not in this repo) and the `io_jax_test` field contract.
  8. Ecosystem: Playground, mjlab, Isaac Lab via Newton.
- **Code examples**
  1. `ex1_torch_zero_copy.py` - `wp.to_torch(d.qpos)` view; modify in torch; print the change visible in Warp; print
     torch/Warp versions and devices (runs on CPU torch in the verification venv; skips if torch missing).
  2. `ex3_torch_ctrl.py` - torch tensor of per-world ctrl copied in via `wp.from_torch` + `wp.copy` each step for
     CARTPOLE; print mean pole angle (no policy training here).
  3. `ex2_torch_dtypes.py` - vec3 and quat arrays through `wp.to_torch`: print shapes, dtypes, `is_contiguous()`, and
     what happens to a non-contiguous torch slice passed to `wp.from_torch` (error or copy, printed).
  4. `ex4_jax_env_flags.py` - set the three XLA env vars before import, print them, `jax.__version__` and
     `jax.default_backend()` (skips without JAX).
  5. `ex5_jax_callable.py` - the corrected `jax_unroll` course version: GPU + JAX, model path from
     `mujoco_warp/test_data/humanoid/humanoid.xml`, per-world `nconmax` (or `naconmax`), no cache clear,
     `wp.jax_callable(..., graph_mode=wp.JaxCallableGraphMode.WARP, output_dims=...)` and a `lax.scan` unroll; print
     final qpos stats and steps/s; labelled "from Colab, not CPU-verified".
  6. `ex6_jax_grad_free_loop.py` - GPU + JAX: a `jax.jit`-compiled loop that reads obs from the jax_callable output
     and computes a reward in JAX; print reward stats (no gradients; Ch 29 explains why).
  7. `ex7_stale_contrib_check.py` - static check (no execution of repo code): read the text of `contrib/jax_unroll.py`
     from the clone if present and print the three stale lines with the corrected values (skips if the clone is
     absent).
- **Visuals**
  - Zero-copy memory diagram: one GPU buffer with three views (Warp, torch, JAX) and arrows; a copy path crossed out.
  - Stream diagram: torch stream and Warp stream lanes with a synchronize marker.
  - JAX bridge flow: `lax.scan` → `jax_callable` → copy in → `mjw.step` → copy out → back; with XLA graph icon; the XLA
    env vars drawn as a "set before import" gate.
  - custom_vmap diagram: 8192 per-env calls collapsing into one batched Warp call.
  - "Stale contrib script" diff figure: three lines of `jax_unroll.py` next to the corrected course lines.
- **Exercises / quiz**: quiz on zero-copy pitfalls (dtype, contiguity, stream), why the XLA vars must be set before
  import, `nconmax` vs `naconmax`; auto-checked: (1) assert that a torch write to `wp.to_torch(d.ctrl)` is seen by
  `d.ctrl.numpy()` (CPU torch); (2) write `make_ctrl_writer(d)` that copies a torch tensor into `d.ctrl` without
  replacing it and assert the array identity is unchanged; stretch: wrap `mjw.forward` with `jax_callable` and compare
  with the step version.
- **Notebook**: setup; a separate first cell for the XLA env vars; **torch section** (ex1-ex3) and **JAX section**
  (ex4-ex7) so a JAX failure does not block the torch part; Colab's preinstalled torch and JAX only.

### Chapter 29 - `29-gradients-and-system-identification` - Gradients, Sampling-Based Optimization and Parallel System Identification

- **Level:** expert. **Prerequisites:** 10, 24, 26 (28 recommended). **Research:** render-integrations §2.9; warp-perf §8;
  `_src/diff.py`, `_src/diff_test.py`; constraint-solver §6.
- **Learning objectives**
  1. Explain forward-mode vs reverse-mode differentiation and use `wp.Tape` on a plain Warp kernel (owner of autodiff
     basics).
  2. Explain `diff.py` exactly as 4.0.1 ships it: `differentiable(locals())` in `__init__.py` wraps every public mjw
     function with `_wrap`, but **no adjoint rule is registered for any of them** (`RULES[name] = None`), so *any* mjw
     call inside an active `wp.Tape` raises `NotImplementedError: Differentiation of '<name>' is not supported.`:
     `put_data`, `forward`, `step`, `ray`, `render`, all of them. Setup calls run before or outside the Tape.
  3. Use the `register_adjoint` options (`array_args`, `in_fields`, `out_fields`, `model_fields`, `render_fields`,
     `supported`, the decorator form) and the `AdjointRule` contract on your own wrapped functions.
  4. Compute derivatives with worlds as finite-difference perturbations and choose epsilons in float32.
  5. Extend Ch 8's MPC to CEM, with correct state snapshots (`State.PHYSICS`, `.recall` Ch 8 §4).
  6. Fit physical parameters to data in parallel (the non-RL capstone).
- **Outline**
  1. Derivatives in one picture: forward mode (push a tangent forward) vs reverse mode (pull a cotangent back); why
     reverse mode is cheap for many inputs and one loss.
  2. `wp.Tape` on a 2-line custom kernel (`y = x**2`): forward under the tape, `y.grad.fill_(1.0)`, `tape.backward()`,
     read `x.grad`, compare with finite differences; adjoint kernels generated by Warp.
  3. Why MJWarp's kernels have backward disabled (`enable_backward=False` module option, `.recall` Ch 4 `.deeper`) and
     how `diff.py` makes this explicit: `differentiable` wraps every public function; `_wrap` records the call on an
     active tape only if a rule exists; `RULES[name] = None` for every mjw function in 4.0.1; README status
     (experimental).
  4. `register_adjoint(fn, backward=None, *, array_args, in_fields, out_fields, model_fields, render_fields,
     supported)`: what each option declares (array arguments with gradients; Data input/output fields; Model fields;
     render fields), `supported(...)` returning reason strings that become `NotImplementedError: ... is not
     supported: <reason>.`, the decorator form, and the `AdjointRule` contract (backward must `+=` into input grads,
     consume the output grads, leave scratch rules alone; docstring in `diff.py`); the error messages for undeclared
     fields ("it accesses ..., which is not declared by this rule") and missing backward ("requires a backward rule").
  5. Finite differences across worlds; float32 epsilon choice.
  6. Sampling-based optimization: CEM as the iterative extension of Ch 8's random-shooting MPC (`.recall`); snapshots
     with `State.PHYSICS` (plus WARMSTART for exact replays; HISTORY/PLASTIC matter for models with delays or
     plasticity).
  7. Parallel system identification: one world per candidate parameter set (batched Model fields, Ch 10, and
     `set_const` outside any graph), loss vs a recorded trajectory, CEM or grid refinement.
- **Code examples**
  1. `ex1_tape_basics.py` - `wp.Tape` over a custom kernel `y = x**2` on a Warp array; print `x.grad` (2x) and the
     central-difference check.
  2. `ex2_tape_error.py` - setup (`put_model`, `make_data`, `forward`) outside the tape, then
     `with wp.Tape(): mjw.step(m, d)`; print the `NotImplementedError` message; then the same for `mjw.forward` and
     `mjw.put_data` inside the tape, and print `sorted(k for k, v in diff.RULES.items() if v is not None)` (empty).
  3. `ex3_register_adjoint.py` - private badge, exact verified pattern: a user elementwise op `square(m, d, x, y)` on
     Warp arrays; `w = diff._wrap(square)`; `diff.register_adjoint(square, square_bwd, array_args=("x", "y"))`; under
     `wp.Tape()` call `w(m, d, x, y)`, `y.grad.fill_(1.0)`, `tape.backward()`; print `x.grad` (3.0 for x = 1.5) and the
     central-difference check.
  4. `ex4_adjoint_fields.py` - extend ex3: a wrapped user function that reads a Data field and writes another,
     registered with `in_fields`/`out_fields`, and a `supported` hook returning a reason string when `m.nv > 6`; print
     the gradient on the Data field and the resulting `NotImplementedError ... is not supported: <reason>.` for a model
     that fails the hook; then call it without declaring a field it touches and print the "not declared by this rule"
     message.
  5. `ex5_fd_jacobian.py` - d(final cart position)/d(ctrl) by central differences using 2k+1 worlds in one launch;
     print the Jacobian and compare epsilons in float32.
  6. `ex6_cem.py` - CEM over open-loop ctrl sequences for `CARTPOLE` swing-up using NWORLD samples per iteration
     (extends Ch 8 ex11, snapshots with `State.PHYSICS`); print best return per iteration.
  7. `ex7_sysid_capstone.py` - non-RL capstone: record a "real" `PENDULUM` trajectory with hidden damping and mass;
     NWORLD candidate (damping, mass) worlds via batched Model fields (Ch 10) and `set_const` (outside any graph); loss
     on device; 5 CEM rounds; print the recovered parameters vs truth.
  8. `ex8_sysid_friction.py` - variant with contacts: identify sliding friction from a box trajectory on a slope
     (batched `geom_friction`, no set_const needed); print recovered vs true friction.
- **Visuals**
  - Forward vs reverse mode picture: a small computation graph with tangents flowing forward and cotangents backward.
  - **Tape diagram (animated, stepper), redrawn for 4.0.1:** setup calls (`put_data`, `forward`) sit *outside* the tape
    box; inside, only user functions with rules (`square`) are recorded; backward pops them in reverse, each calling
    its adjoint rule, with gradient chips flowing on in/out fields; an mjw call dragged into the tape box shows the
    `NotImplementedError` badge ("no rule registered in 4.0.1").
  - `register_adjoint` anatomy card: each option as a labelled socket on the wrapped function (array_args, in_fields,
    out_fields, model_fields, render_fields, supported).
  - Finite-difference fan: worlds as perturbed copies around a nominal; gradient arrow assembled.
  - CEM animation: action distribution (Gaussian) narrowing across iterations with elite samples highlighted.
  - System-ID landscape (Rule D from ex7): loss heatmap over (damping, mass) with CEM samples converging on the truth.
- **Exercises / quiz**: quiz including "which mjw calls can run inside a `wp.Tape` in 4.0.1?" (none: no rules are
  registered), what `_wrap` does, what `supported` returns; auto-checked: (1) FD gradient of ball landing time w.r.t.
  initial height asserted vs analytic; (2) a custom adjoint for `y = 2x + 1` asserted with Tape; stretch: identify
  friction and restitution together from a bouncing-box trajectory.
- **Notebook**: setup; ex1-ex8; "Part VI review" quiz is in Ch 30.

### Chapter 30 - `30-capstone-rl-at-scale` - Capstone: GPU-Native Reinforcement Learning at Scale

- **Level:** expert. **Prerequisites:** 8, 10, 24, 26, 28 (§1-§3 only; Ch 29 is optional for this track; recommended
  for the contact track: 9, 20, 25). **Research:** warp-perf §9; render-integrations §2.9-§2.10; api-io §1.8;
  constraint-solver §6 (tuning); `contrib/apptronik_apollo_locomotion.ipynb`, `contrib/xml`,
  `test_data/humanoid/humanoid.xml`.
- **Learning objectives**
  1. Know enough RL to follow the capstone: MDP, policy, return, advantage, why on-policy methods want many parallel
     envs, termination vs truncation with auto-reset (asynchronous episodes).
  2. Design a fully on-device RL environment: graph-captured physics substeps, obs/reward/done kernels, masked
     auto-reset, per-episode domain randomization, torch zero-copy (owner of the env wrapper), with a
     `backend="torch"|"warp"` switch so the env also runs without torch.
  3. Train with a tested reference PPO (read, run, modify; not written from scratch) on thousands of `CARTPOLE`
     worlds (warm-up track).
  4. Build and train a **contact-rich** task (humanoid standing, contact track) that uses Parts IV-V: contact sizing
     measured with the Ch 9 recipe, solver/cone/iterations tuned per Ch 20-21, overflow monitoring, friction DR, and
     optionally pixel observations from Ch 27.
  5. Evaluate robustness under randomized physics and render the trained policy.
  6. Tie the whole course together (course map and cumulative quiz).
- **Outline**
  1. RL in 15 minutes: MDP, policy, return, advantage/GAE in one picture, on-policy sampling, termination vs truncation
     and what auto-reset means for the value bootstrap.
  2. Warm-up track task definition (cartpole balance), observation/reward design.
  3. Environment architecture: policy (torch) ↔ zero-copy buffers ↔ captured graph (substeps + kernels + reset).
  4. Implementing the env from `my_env.py` (Ch 8 reset and snapshots, Ch 9 `describe_overflow`, Ch 10 randomize,
     Ch 14 `sensor_slices`, Ch 24 `capture_step`, Ch 26 kernels), sizing (no contacts; `njmax` for the slider limit),
     non-finite guard. **DR inside the graph** randomizes only fields that need no derived recompute
     (`geom_friction`, `actuator_gear`/`gainprm`, `dof_damping`; the verified Ch 10 ex9 pattern). **Mass DR** happens
     eagerly at rollout boundaries, outside the graph, followed by `mjw.set_const` (it allocates temporaries and
     relaunches every world; capturing it in a graph is "not verified" unless the author tests it on Colab).
  5. Reference PPO (`examples/30-capstone-rl-at-scale/ppo_reference.py`, ~200 lines, tested by the author on Colab):
     a guided reading of rollout → GAE → clipped objective → minibatch epochs. The notebook embeds it with
     `%%writefile ppo_reference.py` (0.10).
  6. Training run, logging, checkpoints; expected learning curve shape (learner's own numbers).
  7. **Contact track: `HumanoidStandEnv`** on the shipped `HUMANOID`: obs (torso height, orientation, joint state from
     `sensor_slices`), reward (height + upright − control cost), termination on fall; sizing by a measurement rollout
     (Ch 9 recipe, max per-world nacon/nefc + margin); solver settings from a small sweep (Newton vs CG, elliptic vs
     pyramidal, iterations; Ch 20-21); `describe_overflow` checked every rollout; per-episode floor-friction DR in the
     graph; optional 64x64 depth observations from the batch renderer (Ch 27).
  8. Evaluation: robustness sweep over masses/frictions/gear (DR from Ch 10), video via Ch 5 or batch render (Ch 27).
  9. CPU-friendly baseline: evolution strategies in NumPy for small nworld (also used for CPU verification); saves its
     linear policy to `policy_es.npz`.
  10. Optional stretch sections: swing-up variant; scaling study nworld 256 → 16384; Apollo locomotion notebook flow
      (Brax PPO + `custom_vmap`, `contrib/xml/apptronik_apollo.xml`) and the ecosystem.
  11. Course wrap-up: the course map (`reference/course-map.html`) with every pipeline station linked to its chapter
      and source files, a "Part VI review" quiz, and the 30-question cumulative quiz; where to go next (Playground,
      mjlab, Isaac Lab/Newton, contributing).
- **Code examples**
  1. `ex1_env.py` - `CartpoleEnv(backend="torch"|"warp")` (obs/rewards as zero-copy torch tensors, or wp arrays when
     torch is missing): graph-captured `n_substeps` physics + obs/reward/done kernels + masked reset + in-graph DR
     kernel (friction, gear, damping); print obs shape and one step of rewards.
  2. `ex2_random_policy.py` - random actions; print env steps/s (eager vs graph).
  3. `ex3_reward_check.py` - reward/obs kernels vs NumPy reference on random states; print max diff.
  4. `ex4_episodes.py` - verify episodes end and restart per world and that truncation is flagged separately from
     termination; print episode-length histogram counts.
  5. `ex5_es_baseline.py` - NumPy evolution strategies with a linear policy over NWORLD worlds (runs on CPU); print
     return per iteration; saves `policy_es.npz`.
  6. `ex6_ppo_train.py` - imports `ppo_reference.py`; trains (GPU: 10-20 min budget; CPU: 3 tiny iterations with CPU
     torch, which the verification venv installs); print iteration, mean return, steps/s; saves `policy_ppo.pt`.
  7. `ex7_evaluate.py` - evaluate the PPO checkpoint if present, else the ES policy, printing which one it used, over
     randomized masses (mass DR applied eagerly + `set_const` between evaluation rollouts); print success rate per
     mass bin.
  8. `ex8_render_policy.py` - render the trained policy for world 0 (Renderer or batch-render fallback) and a 4x4
     batch-render grid; save video/PNG; `--dump-json` writes evaluation rollouts for the replay player.
  9. `ex9_humanoid_sizing.py` - contact track step 1: measurement rollout of `HUMANOID` with random actions; print max
     per-world nacon/nefc, the recommended `nconmax`/`njmax` with 25% margin, and a small solver sweep table (mean
     niter, ITERATIONS bit, steps/s).
  10. `ex10_humanoid_env.py` - contact track step 2: `HumanoidStandEnv` with the measured sizes and chosen solver,
      in-graph friction DR, overflow check per rollout; print obs shape, one step of rewards and "overflow: none".
  11. `ex11_humanoid_train.py` - contact track step 3: PPO (GPU budget 20-30 min; CPU: 2 tiny iterations); print mean
      episode length and return per iteration, and overflow status.
  12. `ex12_scaling.py` (stretch) - steps/s and return after a fixed wall-clock budget for several nworld; print table.
  13. `ex13_swingup.py` (stretch) - swing-up variant (start at hinge = pi, energy-shaped reward); print success rate.
- **Visuals**
  - RL loop diagram: agent ↔ environment, with state/action/reward arrows, then the batched version (N envs).
  - Architecture diagram (SVG, animated data flow): actions → ctrl buffer → captured graph (substeps, kernels, reset,
    in-graph DR) → obs/reward buffers → policy; all inside a GPU boundary box; mass DR + `set_const` drawn outside the
    graph at the rollout boundary.
  - Episode timeline across worlds (world grid A.9, Rule D from ex4): colored bars ending at different times
    (auto-reset), termination vs truncation marked differently.
  - PPO loop diagram: rollout → GAE → minibatch epochs → update, with tensor shapes; GAE stepper over a 6-step
    trajectory (Rule A).
  - Training curve chart template (learner's numbers fill it; the page shows a schematic labelled illustrative).
  - Evaluation replay (world replay player A.7, Rule D from ex8): 16 evaluation rollouts of the trained (or ES) policy
    with randomized pole masses, each tile labelled with its mass; an optional JS cartpole with a pole-mass slider
    stays only as an interactive toy labelled illustrative.
  - Contact-track dashboard: per-rollout nacon/nefc against the chosen budget lines, overflow LEDs (the Ch 9 panel),
    mean niter; a humanoid replay (A.7) of the standing policy.
  - Course map (embedded preview of `reference/course-map.html`): the breadcrumb with each station linking to its
    chapter.
- **Exercises / quiz**: quiz on termination vs truncation, why the reset must be on device, why mass DR stays outside
  the graph; auto-checked: (1) add an action-rate penalty kernel and assert it against NumPy; (2) assert that in-graph
  DR changes frictions only at resets and that eager mass DR + `set_const` changes `body_subtreemass`; stretch: add
  depth-image observations to `HumanoidStandEnv` and compare learning speed. Then the "Part VI review" block and the
  cumulative quiz.
- **Notebook**: setup (+EGL); `%%writefile my_env.py` and `%%writefile ppo_reference.py`; warm-up track (ex1-ex8)
  with a 10-20 minute GPU budget, checkpoint saving, evaluation and video; contact track (ex9-ex11) with its own
  budget; stretch sections collapsed.

---
## Part VII. Coverage matrix (every important part of the repository)

| Repository area | Chapters |
|---|---|
| `__init__.py` public surface (incl. deprecated `set_const_fixed/set_const_0`), `diff.py` wrapper | 1 (+ reference/api-at-a-glance), 10, 29 |
| `io.py` put_model/make_data/put_data/get_data_into/reset/defaults, sleep and flex checks | 5, 6, 8, 9, 21, 23 |
| `io.py` override_model, find_keys/make_trajectory/load_trajectory | 5 (deeper), 17, 25 |
| `types.py` Model/Data/Option/Contact/Constraint/enums/BlockDim/Callback/RenderContext/State/Stage/SleepPolicy/OverflowType | 5, 6, 8, 9, 19, 21, 24, 26 |
| `forward.py` step/forward/fwd_*/integrators/_advance (incl. plastic updates)/overflow/run_qacc_smooth/discrete | 7, 9, 12, 13, 20, 23 |
| `smooth.py` kinematics/com_pos/camlight/crb/factor/rne/tendon/transmission/flex | 11, 12, 23, 27 |
| `passive.py` (springs incl. polynomial and plastic, dampers, fluid models, flex elasticity, rods, efm contact) | 12, 23 |
| `sensor.py` (catalogue, rangefinder data spec, contact, tactile) | 14 |
| `history.py` delays and interval sensors | 14 |
| `inverse.py`, `derivative.py` (deriv_smooth_vel, eff_*) | 14, 13, 23 |
| `set_const.py` (set_const, groups, set_length_range) | 10, 29, 30 |
| `support.py` jac/mul_m/contact_force/xfrc/get_state/set_state/rod_*/interp | 8, 9, 11, 12, 23 |
| `collision_driver.py`, `collision_core.py` (tables, filters, NXN, SAP, surfacevel, contactfilter) | 9, 15, 16, 26 |
| `collision_primitive*.py` | 16 |
| `collision_gjk.py`, `collision_convex.py` (incl. CCD scratch sizing) | 17, 18 |
| `collision_sdf.py` (incl. user SDF hooks, octree sampling) | 18 |
| `collision_flex.py` | 23 |
| `sort.py` (dev tree only) | 22 (`.version`) |
| `constraint.py` | 19, 22 |
| `solver.py`, `block_cholesky.py` | 20, 21 (compact solves) |
| `island.py`, `sleep.py` | 21 |
| `ray.py`, `bvh.py` (incl. splat BVH) | 27 (BVH also 23 for flex) |
| `render.py`, `render_util.py` (splats, camera modes; `render_optix.py` dev tree only) | 27 |
| `warp_util.py` in 4.0.1: `cache_kernel`, `event_scope`, `EventTracer`, `check_toolkit_driver`, `mark_batched`, `is_array_spec` (dev-only: `side_stream`, `efc_threads_per_world`, `.version` in 20/25) | 4, 6, 7, 24, 25, 26 |
| `math.py` (incl. `quat_integrate`), `util_misc.py` (muscle, dcmotor, wrap, `_poly_force`, actuator damping) | 3, 4, 12, 13, 26 |
| `util_pkg.py` (version checks) | 1 (one line) |
| `cli.py`, `testspeed.py`, `record.py`, `viewer.py` | 5, 21 (`--init_asleep`), 25 |
| `benchmarks/` (run.py, sweep.py, suites, `kitchen/populate_scene.py`, NPZ trajectories) | 25, reference/repo-tour |
| `contrib/` jax_unroll.py, render.py, kernel_analyzer, Apollo notebook, `xml/` (Apollo scene), `systemd/` (nightly timer) | 28, 27, 26, 30, 25, reference/repo-tour |
| `notebooks/tutorial.ipynb` | 1, 5, 27 |
| `test_data/` models, `test_data.fixture`, `collision_sdf/utils.py::register_sdf_plugins` | 0.6, 18, 26 |
| `*_test.py` (testing conventions, determinism_test `_Replay`, diff_test, jax tests, forward_test run_qacc_smooth, sensor/history/passive tests as MJCF sources) | 12, 14, 20, 22, 26, 28, 29 |

## Part VIII. Review checklist (used by reviewers in later phases)

1. Every code example exists as a script, runs on CPU in the course venv with small budgets (after the 0.4
   verification-venv install, CPU torch included), and its printed output matches the page's "Expected output"
   (captured with `wp.config.log_level = wp.LOG_WARNING`). GPU-only parts are guarded per Rule G, optional libraries
   per Rule O, and Colab-only outputs are labelled.
2. Rule W1: every `_src` name called by an example and every `file.py::name` in a Source map exists in the 4.0.1 wheel
   (grep), or is flagged dev-tree-only with a `.version` callout and never called. No `side_stream`,
   `efc_threads_per_world`, `kinematics1/2`, `prepare_*_context`, `_sdf_candidates`, `flex_passive_contact`, `sort.py`,
   PID or SO3 actuators used as if supported; no `set_const_fixed`/`set_const_0` except in the deprecation note.
3. Every chapter has >= 4 SVG diagrams, >= 2 animations, >= 2 interactive widgets, a recap block, the breadcrumb
   (Ch 7-23), a quiz (>= 6 questions), >= 2 auto-checked exercises + 1 stretch, a source map, a "Stuck?" link to the
   troubleshooting page, and working prev/next links ("Ch NN of 30"). Each Part's last chapter (7, 10, 14, 18, 23, 30)
   has a checkpoint project and a "Part review" quiz block.
4. Algorithm animations use the stepper (Rule A); data-driven figures embed JSON or images from a script run (Rule D);
   real trajectories use the replay player; no invented GPU performance numbers; illustrative charts and JS physics
   are labelled.
5. Shared components (Appendix A) are used verbatim: breadcrumb station ids, pool bar, efc strip, palette hex values,
   stepper, atlas, replay player, mini3d, world grid.
6. Concept owners (0.9) are respected: reused topics use a `.recall` box (with the given recall line), not a second
   full explanation or a second copy of the owner's widget.
7. Pages pass the phone-width check (no horizontal page scroll), Rule I (tap and keyboard parity, caption-line
   readouts) and dark mode.
8. Notebook mirrors the page's examples, starts with the standard setup cell (0.4 rule S), and **runs top to bottom in
   a fresh Colab runtime with no other files** (helper modules embedded with `%%writefile`; fresh-process examples run
   as `!python` subprocesses).
9. Long signatures (`create_render_context`, `make_data`, `put_data`, `register_adjoint`) are called with keyword
   arguments; every capture example applies the graph-conditional fallback; every state buffer is sized with
   `mj_stateSize` and asserted.

## Appendix A. Shared visual components (copy-paste reference markup; each chapter stays self-contained)

The integrator writes `planning/shared-components.html` containing the exact markup below before implementation
starts; authors paste the pieces they need.

- **A.1 Pipeline breadcrumb.** An inline SVG strip with stations in this fixed order, matching
  `forward.py::_forward` and `fwd_position` in the 4.0.1 wheel. Station ids (stable; never renamed):
  `st-kinematics` (kinematics, com_pos, camlight, flex, tendon) → `st-crb` (crb, tendon_armature; a dashed ghost
  socket `factor_m` labelled "only when you call `fwd_position(factorize=True)`") → `st-collision` →
  `st-make_constraint` → `st-island` (dashed, shown only with sleep; island.island) → `st-transmission` →
  sensor tap `sensor_pos` → `st-velocity` (com_vel, passive, rne, tendon_bias) → sensor tap `sensor_vel` →
  control-callback socket → `st-actuation` (fwd_actuation) → `st-acceleration` (qfrc_smooth + `factor_solve_i`,
  labelled "factor happens here inside `_forward`") → `st-solve` → `st-rne_post` (rne_postconstraint, when requested)
  → sensor tap `sensor_acc` → `st-integrate` (`_advance`/integrator). A small dashed pre-station `st-sleep`
  (`sleep.wake`, `update_sleep`) appears before kinematics only in Ch 21. Each station is
  `<g class="station" id="st-...">` with a rounded rect and label; the current chapter's stations get
  `class="station here"` (accent fill). Width scales to the column; on phones the labels collapse to numbers with a
  legend. The v2 id `crb-factor` is retired; `st-crb` replaces it.
- **A.2 Contact pool bar.** Horizontal SVG of `naconmax` cells, fixed cell width 14px (wraps rows on phones); each
  filled cell colored `--world-k` of its `worldid`; an `nacon` pointer triangle above the next free cell; a red vertical
  capacity line at `naconmax`; overflowed contacts drawn as red cells past the line that fade out.
- **A.3 efc row strip.** One row per world of `njmax` cells; blocks in order eq | friction | limit | contact with fixed
  hues (eq purple, friction amber, limit teal, contact `--accent-2`); a red line at `njmax`; contact blocks carry a
  small label with their contact id for `efc_address` arrows.
- **A.4 Palette.** `--accent #76b900`, `--accent-2 #2f7bd8`, `--warn #d98e04`, `--danger #d64545`, worlds
  `--world-0..7`: `#4e79a7 #f28e2b #e15759 #76b7b2 #59a14f #edc948 #b07aa1 #ff9da7` (light) with dark-mode
  variants lightened by 15% (the integrator writes the exact dark hex values in shared-components.html and authors copy
  them).
- **A.5 Stepper widget.** ~80 lines of JS: a state machine over an array of frames `{line, vars, draw}`; buttons
  Prev / Step / Play / Reset; a range input scrubbing the frame index; a `<pre>` pseudo-code panel whose line `line` is
  highlighted and whose header names the real function (e.g. `_S3D`, `_add_edge`, `_linesearch_iterative_kernel`,
  `_dsu_union`, `_solver_iteration`, `_history_find_index`, `_cfrc_subtree`); a small `<table>` showing `vars`; Play
  respects `prefers-reduced-motion` (starts paused); keyboard: left/right arrows step. Below 640px the figure,
  controls, pseudo-code and variable table stack vertically.
- **A.6 Launch-shape atlas.** Eight SVG layouts with a selector; each shows its real source launch line and, where an
  example records them (Ch 7 ex5), the measured `dim` values (Rule D). Layouts: (1) world × element grid (`smooth.py`
  `dim=(nworld, nbody)`); (2) flat pool-slot strip with worldid lookup and idle threads past `ncollision` greyed
  (`collision_primitive.py` `dim=d.naconmax`); (3) work-package sweep (`collision_driver.py` SAP `dim=nsweep`, added
  by Ch 15); (4) grid-stride loop where T threads cover N items (`collision_convex.py::_ccd_grid_size`, added by Ch 17);
  (5) (world, ray) grid (`render.py` `dim=(d.nworld, rc.total_rays)`, added by Ch 27); (6) tiled block-per-world
  launches, one block per world with its `block_dim` lanes and an animated stride cursor over efc rows
  (`wp.launch_tiled(dim=d.nworld, block_dim=...)`, `for efcid in range(tid, nefc, wp.block_dim())` in
  `solver.py::_linesearch_iterative`, `_cholesky_factorize_solve`; SAP_TILE `_segmented_sort`;
  `smooth.py::_factor_blocks` `dim=(nworld, tile.adr.size)`; on CPU block_dim collapses to 1 lane, cite the comment in
  solver.py); (7) 3-D grids drawn as a stacked cube whose innermost axis splits one row's work
  (`solver.py::_linesearch` `dim=(d.nworld, d.njmax, threads_per_efc)`, `smooth.py`
  `dim=(d.nworld, m.ntendon, m.max_ten_J_rownnz)`); (8) row-per-contact (`constraint.py` contact rows
  `dim=d.naconmax`). Ch 7 owns layouts 1, 2, 6, 7, 8; layouts 3, 4, 5 are greyed with "added in Ch 15 / 17 / 27" until
  then.
- **A.7 World replay player.** ~70 lines of JS. Input: a Rule D JSON `{"nworld": W, "dt": s, "frames": [[...per
  world values...], ...], "kind": "pendulum2d"|"points2d"|"height"|"mesh3d"|"tiles", "labels": [...]}` written by an
  example's `--dump-json` (decimated, e.g. 60 frames, values rounded to 3 decimals, under ~300 KB). Draws each world in
  its `--world-k` color (SVG for ≤ 64 worlds, canvas above), with play/pause/scrub, per-world highlight on
  hover/tap/focus, a caption line, paused by default under `prefers-reduced-motion`. Can drive the world grid (A.9) and
  mini3d (A.8) scenes. Used in Ch 1 (hero), 2, 3, 6, 8, 9, 10, 13, 21, 23, 27, 30.
- **A.8 mini3d.** ~60 lines of JS: yaw/pitch drag (pointer) and arrow-key rotation, a 3x3 rotation, orthographic
  projection with optional perspective, painter's-order depth sorting of polygons, an axis gizmo with fixed colors
  (x red, y green, z blue), respects reduced motion, and a default view chosen so the static image reads well. Every
  3-D figure uses it (Ch 2 quaternion card, 3 rigid body and inertia ellipsoid, 11 frames, 12 tendon wrap, 13
  quaternion integrate, 15 SAP projection, 17 GJK/EPA, 19 friction cone, 23 cloth and rod frames, 27 BVH, frustum and
  camera modes).
- **A.9 World grid.** N tiles (wrapping, minimum 28px), a `--world-k` border, a state fill from a fixed vocabulary
  (running / done = green / overflow = red / asleep = grey / reset = flash), a small corner label (t, niter or overflow
  bits), and an API `setState(worldid, state, label)` that the replay player (A.7) or a stepper can drive. Used for the
  Ch 8 reset-mask and mocap tiles, Ch 10 DR mosaic, Ch 20 per-world convergence grid (real `d.solver_niter`), Ch 21
  sleep tiles and Ch 30 episode timeline.

## Revision log round 1

Each critic gap was checked against the 4.0.1 wheel (`venv/.../site-packages/mujoco_warp/`) and against the v1 plan
before being applied. Chapter numbers below refer to the **new** numbering unless marked "old".

**Restructure summary (26 chapters kept).** Old → new: 1→1 (trimmed), 2→2 (expanded), 3→3 (adds GPU model), 4+6→4
(first simulation + seeing it), 5→5, 10→6 (pipeline tour moved up), 7→7 (+mocap/eq_active), 9→8, 8→9 (DR after
contacts), physics primer + 11→10, 12→11, 13→12, 14→13, 15→14 (+geometry toolkit), 16→15, 17→16, 18 split into 17
(heightfields + SDF), 18 (flex, new) and the rays half of 24, 19→19, 20→20, 21→21, 22→22, 23→23, 24→24 (+rays/lidar),
25→25 (+system-ID capstone, env wrapper moved to 26), 26→26 (+RL primer, reference PPO). Freed slots: old Ch 6 merged
into Ch 4/5, physics primer merged into Ch 10.

### Coverage lens

1. **APPLIED** - `warp_util.side_stream` / `efc_threads_per_world` dev-only. Verified: the wheel's `warp_util.py`
   defines only `is_array_spec, mark_batched, EventTracer, _merge, event_scope, cache_kernel, check_toolkit_driver`.
   Old Ch 22 ex10 dropped; Ch 20 §7 and Ch 22 §6 carry `.version` callouts; coverage row fixed; rule W1 added (0.4).
2. **APPLIED** - Determinism ALL on 4.0.1. Verified `_sort_contacts` and `_sort_constraints` are `pass` stubs. Ch 21
   §5-§6 and ex8-ex10 rewritten: bitwise test on contact-free models, measurement only for contact scenes, `_Replay`
   technique taught.
3. **APPLIED** - Install cell now uses `"mujoco-warp[viewer]==4.0.1"` (0.4 rule S) and Ch 1 §5 explains
   mujoco-core vs mujoco-core[rendering]; the verification venv installs the extra too.
4. **APPLIED** - `mjwarp-viewer` description corrected (verified `viewer.py`: `_VIEWER` enum mujoco|viser,
   `launch_passive` with key callback, `_ENGINE` flag). Ch 4 §9 and the capability matrix fixed; viser via tunnel marked
   unverified; `.version` callout for the dev tree's MuJoCo Studio.
5. **APPLIED** - Flex gets its own chapter (Ch 18) covering flexcomp dims, Data fields, elasticity (`snh_*`), rods
   (`support.rod_*`, `passive.eval_rod_chains`), interpolation, flex collision table, FLEX/FLEXSTRAIN equalities, the
   discrete integrator and `derivative.eff_*`, the io.py unsupported combinations (all grepped), and flex rendering.
   Correction: the critic's `support.add_flex_interp_weights` is spelled `support.add_interp_weight` in the wheel.
6. **APPLIED** - Mocap: new model M10, Ch 2 §6 + ex9, Ch 7 §5 + ex5, State widget includes MOCAP bits.
7. **APPLIED** - `d.eq_active`, all six EqTypes, `eq_solref/eq_solimp`, `wake_equality`: Ch 7 §6 + ex6, Ch 19 §8 +
   ex8-ex9, Ch 18 ex7 for FLEXSTRAIN.
8. **APPLIED** - MuJoCo 4 actuators (verified `actuator_ctrladr/ctrlnum/ctrlspec/actearly`, `DCMOTOR`, `GainType.SO3`,
   `CtrlInput`, `CtrlChart`, no PID in `mjw.DynType`): Ch 11 objective 4, §7, ex6-ex7; Ch 2 §7 mentions nu vs nactuator.
9. **APPLIED** - Unsupported list derived from code: Ch 1 ex7 diffs `mujoco.mjt*` enums against `mjw` enums (verified
   mujoco 4.0.1 has DIAGEXACT, FWDINV, IPC, OVERRIDE, SPECULATIVE enable bits and AUTORESET, MIDPHASE disable bits that
   `mjw` lacks); no-NaN-check rule in 0.4 and the non-finite reset kernel in Ch 7 ex10.
10. **APPLIED** - Sensor catalogue, RayDataField data spec, ConDataField, cutoff, interval sampling, magnetometer,
    tactile: Ch 13 objectives 2-3, §2-§5, ex1-ex7 (names grepped in `sensor.py`/`types.py`).
11. **APPLIED (moved)** - User SDF plugins: Ch 17 §4-§5, ex5-ex6 (`nutbolt.xml` + `register_sdf_plugins`) and ex8
    (custom analytic SDF). Placed in Ch 17 rather than Ch 23 because it belongs with the SDF narrowphase.
12. **APPLIED** - Option fields: Ch 4 ex1 prints every field programmatically, incl. `sleep_tolerance`, `magnetic`,
    `noslip_tolerance` and the `ls_parallel` AttributeError (verified message); `run_qacc_smooth` experiment in Ch 20
    ex8; `impratio_invsqrt` in Ch 19 objective 3.
13. **APPLIED** - Islands: verified `forward.py` calls `island.island(m, d)` only under `if sleep_enabled` and
    `__init__.py` exports `island`; Ch 21 objective 1, §1, ex1; both `smooth_solve_compact` and `solve_compact` named.
14. **APPLIED** - Dev-only internal names: verified absent from the wheel. Fixed citations: Ch 10 §5
    (`smooth.kinematics` → `_kinematics_branch`), Ch 14 objective 2 (`nxn_pairid_contact` is a local array in
    `put_model`), Ch 16 §7 (EPA scratch inline), Ch 17 §3 (`_sdf_candidates` dev-only). Rule W1 and checklist item 2.
15. **APPLIED** - Trajectory replay (`find_keys`, `make_trajectory`, `load_trajectory` verified in io.py) in Ch 22 §9 +
    ex9; testspeed flags table completed (`--overflow_behavior`, `--clear_warp_cache`, `--info`, `--replay`, verified).
16. **APPLIED** - `ContactType` bits and `surfacevel` (verified `ContactType`, `_contact_surfacevel`,
    `flg_surfacevel`): Ch 8 §4 + contact card + ex11; conveyor example Ch 15 ex9 (author verifies the MJCF attribute).
17. **APPLIED** - Primitive pairs and the flex table: Ch 15 heatmap and function list generated from
    `MJ_COLLISION_TABLE` (ex1), flex layer from `MJ_FLEX_COLLISION_TABLE`, `cylinder_triangle` listed (verified).
18. **APPLIED** - Fluid models: Ch 11 §2 + ex12 compare inertia-box vs ellipsoid (`geom_semiaxes`,
    `ellipsoid_max_moment` verified) and add wind.
19. **APPLIED** - `run_collision_detection=False`: Ch 23 objective 4, §4, ex8 with user-written contacts.
20. **APPLIED** - Coverage matrix rows for `contrib/systemd`, `contrib/xml`, `benchmarks/kitchen/populate_scene.py`,
    `test_data.fixture`; mentioned in Ch 22 §10, Ch 26 §9 and reference/repo-tour.

### Pedagogy lens

21. **APPLIED (as the first half of Ch 10)** - Physics primer: Ch 10 objectives 1-3, §1-§3, ex1-ex3 (NumPy 2-link
    derivation vs `mj_fullM`/`qfrc_bias`, spatial vectors in (rot, trans) order, com frame, M as kinetic energy). A
    separate chapter was not possible within the 26-chapter budget; the critic offered this option.
22. **APPLIED** - GPU execution model: Ch 3 objective 3, §4, §11, ex6-ex7, GPU anatomy / block scheduling /
    divergence / coalescing visuals; back-links from Ch 5, 14, 15, 20, 22. Note: the critic's evidence
    `efc_threads_per_world` is dev-only, so Ch 20/22 refer to the wheel's actual launch dims.
23. **APPLIED** - Ordering: pipeline tour moved to Ch 6 (before resets/control, contacts and DR); contacts (Ch 8) now
    depend on it; Ch 8 shows row counts as a black-box formula with a friction-cone intuition box, derived in Ch 19.
24. **APPLIED** - Ch 2 now covers equality constraints, mocap, limits, default classes, soft contacts with solref/solimp
    intuition, and MjSpec (ex7-ex10).
25. **APPLIED** - Beginner overload: Ch 1 trimmed to 8 examples (repo tour and API listing moved to reference pages,
    `diff.py` wrapping moved to Ch 25); Ch 4 keeps only the conceptual `put_model`, with internals, error gallery and
    `override_model` in a `.deeper` block.
26. **APPLIED** - Checkpoint projects at the end of every Part (0.2 table): Ch 6 ex11, Ch 9 ex11, Ch 13 ex12, Ch 18 ex8,
    Ch 21 ex12, plus a non-RL capstone (parallel system identification, Ch 25 ex9).
27. **APPLIED (table) / REJECTED (DR split)** - Ch 9 adds a plain-language derived-constant table with forward links
    and starts with DR that needs no `set_const`. Splitting DR across two Parts was rejected: the derived fields are
    explained well enough at the point of use, and a split would cost a chapter.
28. **APPLIED** - Levels are now monotonic per Part (0.2 table); Ch 12 (integrators) requires Ch 11 (and so Ch 10's
    mass matrix); Ch 3 prereqs are 1, 2; old Ch 3 ex10 (which used Model/Data before Ch 4) was removed.
29. **APPLIED** - Old Ch 18 split three ways: Ch 17 (heightfields + SDF), Ch 18 (flex), rays + BVH merged into Ch 24.
30. **REJECTED (split), mitigated** - Splitting Ch 22 and Ch 25 would exceed 26 chapters. Ch 22 was slimmed (dev-only
    example removed, CPU fallbacks for testspeed examples) and Ch 25 gave its env wrapper to Ch 26 and reuses Ch 7's
    MPC for CEM.
31. **APPLIED** - Concept-owner table (0.9) and `.recall` callouts; duplicates removed: Ch 23 ex3 captures Ch 7's reset,
    Ch 25 CEM extends Ch 7 MPC, `get_data_into` cost only in Ch 4, EventTracer structure in Ch 6 and workflow in Ch 22,
    replace-vs-assign owned by Ch 5.
32. **APPLIED** - Recap block required after each hero, grouped glossary with hover `abbr`, per-Part cheat sheets
    (0.5, 0.8, 0.10).
33. **APPLIED** - Ch 19 opens with the 1-D ball-on-floor toy (§1, ex1, toy widget); atomic row allocation and
    nondeterminism reduced to a forward link to Ch 21.
34. **APPLIED** - Geometry toolkit section opens Ch 14 (§1, ex1, interactive widgets).
35. **APPLIED** - RL primer (Ch 26 §1), reference PPO to read rather than write, stretch sections optional.
36. **REJECTED (split), mitigated** - Splitting old Ch 11 would exceed the budget. The factorization families are an
    expert-only `.deeper` section (Ch 10 §10, ex12) and the CSR → tile → factor figure uses the stepper.
37. **APPLIED** - MjSpec taught in Ch 2 §11 + ex10; used in Ch 9 §11 and Ch 17 ex2.
38. **APPLIED** - Ch 5 keeps only the pooled-array intuition (§7); old ex8 (contacts vs efc) removed; sizing stays in
    Ch 8.
39. **APPLIED** - Every chapter has at least 2 auto-checked coding exercises and 1 stretch exercise; running project
    `my_env.py` (0.10).
40. **APPLIED (progression) / REJECTED (move)** - Ch 3 is a teaser, Ch 19 a one-line forward link, Ch 21 the full
    treatment. Moving determinism to Part VI was rejected: Ch 21's determinism story depends on the contact and efc row
    order just taught in Part V.

### Runnable lens

41. **APPLIED** - Setup cell checks the driver version, points to the `+cu12` wheel (author pins the URL), asserts
    `wp.get_cuda_device_count()`, prints versions and `wp.is_conditional_graph_supported()` (verified to exist), keeps a
    CPU branch.
42. **APPLIED** - Ch 1 ex1 uses `md.version("mujoco-core")` and `mujoco.__version__`; pitfall about `pip install mujoco`.
43. **APPLIED** - `[viewer]` extra everywhere; `MUJOCO_GL` set before any `import mujoco`; restart note.
44. **APPLIED** - Verification venv install step, Rule O (Agg, guarded imports, numbers before plots, Colab-only
    labels).
45. **APPLIED** - Batch renderer is the CPU fallback for Renderer examples (Rule O; Ch 4 ex9-ex10); `mjwarp-record
    --render_mode warp` in Ch 4 ex11.
46. **APPLIED** - Same as item 1 (duplicate finding); dev-only names listed in rule W1.
47. **APPLIED** - SDF example uses `nutbolt.xml` with `register_sdf_plugins(mjw)` (Ch 17 ex5-ex6, expected C 6 vs
    MJWarp 4); `torus.xml` forbidden (0.6).
48. **APPLIED** - Ch 21 ex9 measures NONE/ATOMICS/ALL without asserting 0; ex11 notes ALL costs the same as ATOMICS.
49. **APPLIED** - Ch 25 ex6 uses the verified `_wrap` + `register_adjoint(..., array_args=...)` pattern; `_wrap` and
    `AdjointRule` added to allowed internals.
50. **APPLIED** - testspeed examples guarded (Rule G) with CPU fallbacks for ex7-ex8 (Ch 22).
51. **APPLIED** - `override_model` returns None; correct usage in 0.4, Ch 16 ex7, Ch 22 ex7; `io.override_model`, not
    `mjw.override_model`.
52. **APPLIED** - `Stage` imported from `mujoco_warp._src.types` (allowed internals) with the verified user-sensor MJCF
    (Ch 23 ex6).
53. **APPLIED** - EventTracer guarded before construction (Rule G; Ch 6 ex10, Ch 22 ex5).
54. **APPLIED** - Version/device print block and JAX guards (Ch 25 §1-§2, ex1, ex3-ex4); XLA env before import.
55. **APPLIED** - Cloth starts ~0.05 above the sphere, 300 steps, explicit budgets, overflow decode (Ch 18 ex3).
56. **APPLIED** - `deriv_smooth_vel` output `(nworld, m.nC)` and densification with `mju_sym2dense` (Ch 12 ex7).
57. **APPLIED** - `total_memory` used only on GPU (Rule G; Ch 22 ex10).
58. **APPLIED** - Exact kernel-analyzer command with `--types` and a pinned clone (Ch 23 ex12).
59. **APPLIED** - `mjwarp-record` with `--nworld 1`, `--render_mode warp`, PIL + CLI skip guard (Ch 4 ex11).
60. **APPLIED** - Unsupported wording: "actuator/sensor/passive plugins unsupported; SDF plugins need a Warp
    implementation (Ch 17)"; PGS message kept (Ch 1 §7, ex8).

### Visual lens

61. **APPLIED** - Appendix A shared components with fixed breadcrumb station ids (collision and make_constraint are
    their own stations), pool bar, efc strip and palette hex values.
62. **APPLIED** - Rule A stepper widget (Appendix A.5) required for all algorithm animations; named after real
    functions (all names W1-checked; the critic's `_compute_efc_eval_pt_3alphas` is spelled `_eval_pt_direct_3alphas`
    in the wheel).
63. **APPLIED** - Launch-shape atlas (Appendix A.6) owned by Ch 6 and reused in 14/15/20/24.
64. **APPLIED** - GPU anatomy SVG and block-scheduling widget with a CPU toggle (Ch 3).
65. **APPLIED** - Address ribbon (Ch 5 visuals, ex8).
66. **APPLIED** - Three-lane dispatch figure (Ch 15) plus the launch-recording example (ex8).
67. **APPLIED** - 3D GJK and EPA views (Ch 16), 2D canvas labelled "2D analogue", `_polytope2/3/4` thumbnails.
68. **APPLIED** - Convergence chart from a real run (Ch 20 ex4, Rule D).
69. **REJECTED (as specified), replaced** - The `efc_threads_per_world` slider would visualize a function that does not
    exist in 4.0.1. Ch 20 instead draws the wheel's actual solver thread mapping, with a dev-tree inset.
70. **APPLIED** - NXN upper-triangle matrix with `upper_tri_index` hover (Ch 14), replacing the separate pair heatmap.
71. **APPLIED** - SAP work-package panel with binary search and planes as full-axis bars (Ch 14).
72. **APPLIED** - efc strip shows per-contact block reservation, `efc_address` arrows and a rerun shuffle (Ch 19).
73. **APPLIED** - CSR → tile → factor stepper figure (Ch 10).
74. **APPLIED** - Factorize timeline with the stale-qLD row (Ch 6) plus a runnable stale-factor example (ex3).
75. **APPLIED** - Tape diagram for the diff.py mechanism (Ch 25).
76. **APPLIED** - Gather / solve / scatter animation and the two-pass collision-with-sleep flow (Ch 21).
77. **APPLIED** - Rule D (embedded JSON from `--dump-json`, caption with version and "CPU run"; else "illustrative").
78. **APPLIED** - Transmission gallery and moment-row strip (Ch 11, ex5).
79. **APPLIED** - Box-box SAT + clipping stepper widget (Ch 15).
80. **APPLIED** - sensordata ribbon (Ch 13, ex3).
81. **APPLIED** - ctrl clamp two-gauge widget (Ch 7).
82. **APPLIED** - Knob board widget for live / recompile / recapture (Ch 22 §3).
83. **APPLIED (moved)** - The line-count treemap moved with the repository tour to `reference/repo-tour.html`, with
    `wc -l` at 8f5b9f1 embedded as JSON and a sorted bar list as the phone fallback.
84. **APPLIED (corrected)** - Render thread-mapping hover figure (Ch 24). Correction: `rc.cam_id_map` has shape
    `(ncam,)` in types.py, so it is not a flat ray → camera map; the author documents the actual lookup in `render.py`.

## Revision log round 2

Every critic gap was re-checked against the 4.0.1 wheel (`venv/.../site-packages/mujoco_warp/`), the dev-tree clone
(for `contrib/`) and the v2 plan before it was applied. Chapter numbers below are the **new (v3) numbers** unless
marked "v2".

**Restructure summary (26 → 30 chapters).** The computed task text asked to keep 16-26 chapters; the user's own request
allows 10-30 and wins where the two conflict, and the pedagogy critics showed the round-1 "26-chapter budget" was not a
real constraint. v2 → v3 mapping: 1→1, 2→2, **new 3 (rigid-body physics primer)**, 3→4, 4→5, 5→6, 6→7, 7→8, 8→9, 9→10,
10→11, 11→12, 12→13, 13→14, 14→15, 15→16, 16→17, 17→18 (now also holds the Part IV checkpoint), 19→19, 20→20,
**21 split → 21 (islands and sleep) + 22 (determinism and reproducibility)**, **18 → 23 (flex moved after the solver
chapters, Part V)**, **22 split → 24 (CUDA graphs) + 25 (profiling, benchmarking, tuning)**, 23→26, 24→27,
**25 split → 28 (torch/JAX interop) + 29 (gradients, CEM, system identification)**, 26→30. All "Ch N" references in
the plan body were renumbered by script and then reviewed by hand for the split chapters. `course-plan.json` was
regenerated from the markdown headings.

### Coverage lens

1. **APPLIED** - SO3 ball-joint actuator. Verified: `types.py::TrnType` has JOINT, JOINTINPARENT, SLIDERCRANK, TENDON,
   BODY, SITE only, and `put_model` checks TrnType with `isin`. Ch 12 objective 4, §5, §7 now say "rejected in 4.0.1";
   ex6 keeps the DC-motor half with the verified MJCF and turns the SO3 half into a rejected demo printing
   `NotImplementedError: ['mjTRN_SO3'] not supported`; the actuator widget greys out SO3/PID with the badge; Ch 1 ex7's
   enum diff now includes `mjtTrn` (SO3) and `mjtSleepPolicy`.
2. **APPLIED** - State signatures. Verified the `types.py::State` docstring (PHYSICS, FULLPHYSICS, USER, INTEGRATION;
   HISTORY, PLASTIC, WARMSTART, USERDATA bits; `# unsupported: PLUGIN`). Ch 8 objective 3, §4 and ex4 (QPOS|QVEL vs
   PHYSICS|WARMSTART with both diffs, 2.98e-08 vs 0.0); State widget lists all bits and composites; MPC (Ch 8 ex11) and
   CEM (Ch 29) snapshot with PHYSICS; owner row added to 0.9.
3. **APPLIED** - `flex_passive_contact` is dev-tree only (grep of the wheel finds it only in two test names). Removed
   from Ch 23 §2, replaced by `m.has_flex_passive`, `passive.py::build_efm_contact` and the io.py "Passive contact of
   interpolated flexes" check; added to the rule W1 dev-only list and checklist item 2.
4. **APPLIED** - diff.py story. Verified `_wrap` sets `RULES[name] = None` and raises
   `NotImplementedError(f"Differentiation of '{name}' is not supported.")`. New Ch 29 objective 2, §3-§4, ex2 (step,
   forward, put_data inside the tape; prints the empty list of registered rules), ex4 (`in_fields`/`out_fields`,
   `supported` reason string, undeclared-field message); the tape diagram is redrawn with setup calls outside the tape;
   quiz item "which mjw calls can run inside a Tape in 4.0.1? none".
5. **APPLIED** - Callback semantics. Verified in `forward.py` (act_* callbacks after the `_actuator_force` launch, the
   "GainType.USER: gain stays 0" comment), `collision_driver.py:1235` (contactfilter) and the CONSTRAINT-bit check in
   `constraint.py`. Ch 26 §3 states the contracts; ex5 asserts that forcerange is not reapplied; ex7 clears the
   CONSTRAINT bit and prints nacon (unchanged) and nefc; the callback socket map shows both; Ch 12 §6 recalls it.
6. **APPLIED** - Gaussian splats. Verified the `splat_*` arguments of `create_render_context`, `render.py::ray_splat`,
   `shade_splats`, `bvh.py::build_splat_bvh/refit_splat_bvh` and `contrib/render.py::_load_ply_splats`. Ch 27 §10,
   objective 8, ex13 (NumPy splats in two groups), the splat shading figure and a contrib walkthrough (marked as a repo
   script).
7. **APPLIED** - `create_render_context` options and pitfalls. Verified the 4.0.1 signature (positional order
   `..., use_textures, use_fast_math, use_shadows, ...`) and the contrib/render.py call that passes `_USE_SHADOWS.value`
   positionally. Ch 27 §3b options table (generated by ex12), group-3 invisibility example, `cam_active` by name,
   ortho via `cam_projection`; keyword-arguments rule added to 0.4 and checklist item 9.
8. **APPLIED** - `contrib/jax_unroll.py` is stale. Verified lines 24-35 (`'../benchmark'`, `nconmax=64 * NWORLDS`,
   `wp.clear_kernel_cache()`). Ch 28 §5 callout, corrected course version in ex5, static check in ex7.
9. **APPLIED (one sub-claim corrected)** - MuJoCo 4 springs: Ch 12 objective 1, §1, ex2 (polynomial stiffness vs
   formula, `qfrc_passive` decomposition by name), ex7b (actuator damping), plastic references, the decomposition bars.
   Correction: the critic said no 4.0.1 kernel reads `jnt_springyield`/`tendon_springyield`; in fact
   `forward.py::_next_plastic_joint/_next_plastic_tendon` read them inside `_advance` (return mapping). The plan cites
   those kernels (Ch 12 §1, Ch 13 §1) and keeps a `.version` note that C parity is verified by the author on CPU.
10. **APPLIED** - set_const. Verified the DeprecationWarnings and `# TODO(team): remove` comments, the
    `set_const(m, d, groups, restore)` docstring tables and `set_length_range`. Ch 10 §6 reproduces both tables,
    explains `restore`, adds §6b and ex12 (`set_length_range`); ex7 uses `SetConstGroup.FIXED` and shows the warning
    once; 0.4 public-API list updated.
11. **APPLIED** - testspeed behaviour. Verified `DEFINE_*` lines (noise 0.01/0.1, nworld 8192, render flags,
    `--init_asleep`, `--nvmax`, `--keyframe`, `--device`) and `testspeed.py` (`--function` over `_FUNCS`,
    `--num_buckets`). Ch 25 objective 2, §3 flags table generated from the DEFINE lines, ex3 (noise 0 vs default,
    `--function forward` vs `step`, `--function render`), the "set `--noise_std 0`" rule.
12. **APPLIED** - Sleep requirements. Verified `SleepPolicy` (`# unsupported: NEVER, ALLOWED, INIT`), the flex-equality
    check, `sleep_enabled = SLEEP and not DSBL_ISLAND`, and the Newton ValueError. Ch 21 §2 requirements table, §4
    `--init_asleep` workaround (cli.py writes `mjd.tree_asleep[:] = np.arange(mjm.ntree)` before `put_data`), ex6 error
    gallery, ex7 workaround, quiz item on `DisableBit.ISLAND`, requirements checklist widget.
13. **APPLIED** - OverflowType. Verified LS_ITERATIONS (1<<10) and TACTILE (1<<11) and the `wp.static` read of
    `warn_overflow`. Ch 9 §7 generates the catalogue from the enum, ex7 loops over members, the LED panel is generated;
    `warn_overflow` added to the knob board (Ch 24 ex6) and 0.4; LS_ITERATIONS shown in Ch 20 ex3 with
    `ls_iterations=1`.
14. **APPLIED** - Data outputs. Verified the fields in `types.py::Data`. Ch 11 §4 kinematics-outputs table and the
    frames figure; Ch 12 §5 sparse actuator moment with a densify snippet (ex5 uses it); Ch 26 §6b and ex2 use
    `d.userdata` with `<size nuserdata>` and State.USERDATA.
15. **APPLIED** - Camera and light modes. Verified `cam_mode`, `cam_targetbodyid`, `cam_poscom0`, `light_*` fields and
    that `camlight` runs in `fwd_position`. Ch 27 §4 subsection with the ordering rule, objective 9, ex14, camera-modes
    widget; the stretch exercise now states the ordering.
16. **APPLIED** - mjwarp-record. Verified the docstring's `--video` usage line, the `.gif`/`.webp` check and the flags.
    Ch 5 §9 lists all flags and the docstring pitfall; ex11 adds `--channel depth --render_mode warp`; the full table
    goes to `reference/api-at-a-glance.html`.

### Pedagogy lens

17. **APPLIED** - Chapter budget. The arc is now 30 chapters (0.2): physics primer (Ch 3), Ch 21/22 split, Ch 24/25
    split, Ch 28/29 split. Spine, JSON, "Ch NN of 30" links and checklist item 3 updated.
18. **APPLIED** - Physics primer: new Ch 3 (beginner): F = ma, explicit vs semi-implicit Euler in NumPy, penalty-floor
    bouncing ball, 6-DOF rigid-body state, inertia tensor and principal axes (`body_inertia`/`body_iquat`), gyroscopic
    term, quaternion integration, reduced vs maximal coordinates, contacts/limits as constraints; 10 examples. Ch 11
    recalls it instead of re-teaching it.
19. **APPLIED** - CUDA-graph ordering. Ch 7 §10 adds a CUDA-graph teaser (no code) and a static figure; Ch 20 and Ch 21
    use `.recall` of the teaser plus a forward link; the graph_conditional on/off timing moved from Ch 20 ex10 to
    Ch 24 ex5; 0.9 row "CUDA graph basics: 7 (teaser) → 24 (owner)".
20. **APPLIED** - Flex placement. Flex is now Ch 23 in Part V with prerequisites 13, 16, 19, 20; Ch 18 keeps the rigid
    Part IV checkpoint; Ch 23's efc-row example (ex7) and discrete internals now come after the constraint chapters.
21. **APPLIED** - Math toolkit. Ch 19 §2 + ex12 (GD vs Newton vs CG on a NumPy SPD quadratic, piecewise quadratic
    linesearch) and the toolkit figure; Ch 20 §0 recalls it; `reference/math-toolkit.html` added (0.10).
22. **APPLIED** - Contact-rich capstone. Ch 30 adds a full contact track (`HumanoidStandEnv` on the shipped humanoid)
    with sizing by the Ch 9 recipe, a solver sweep (Ch 20-21), overflow monitoring, friction DR and optional depth
    observations (ex9-ex11), next to the cartpole warm-up track.
23. **APPLIED** - Ch 4 (v2 Ch 3) load. Tiles, module options and the factory preview are `.deeper`; Ch 26 owns tiles (0.9
    row); estimated time noted (2.5 h).
24. **APPLIED** - Ch 7 (v2 Ch 6) load. Atlas reduced to pipeline-wide layouts; the factorize subtlety is a one-line
    pitfall and its example moved to Ch 11 ex13 with the timeline figure; v2 ex8 (step1/step2) dropped (Ch 8 owns it)
    and replaced by a stage-timing example.
25. **APPLIED** - Autodiff basics. Ch 29 §1-§2 + ex1 (forward vs reverse mode, `wp.Tape` over `y = x**2` vs finite
    differences) before the diff.py internals.
26. **APPLIED** - Ch 21 split into Ch 21 (islands and sleep) and Ch 22 (determinism and reproducibility), each with 8-9
    examples; GPU-only examples are concentrated in Ch 22 with CPU explanations.
27. **APPLIED** - Discrete-integrator owner. 0.9 row "Discrete integrator / effective metric → Ch 23" with the exact
    recall line; Ch 13 §6, Ch 19 §9 and Ch 20 §8 now use it.
28. **APPLIED** - Concept owners. 0.9 rows for quaternions (Ch 2; Ch 4 only the storage pitfall, Ch 6 recall), solref/
    solimp (Ch 2 intuition, Ch 19 derivation), friction cone (Ch 9 intuition, Ch 19 math), with recall lines and an
    explicit "do not repeat the owner's widget" rule; Ch 4's convention widget became a static storage strip.
29. **APPLIED** - Duplicates. Ch 19 ex9 recalls Ch 8 ex6 and adds only the efc-strip view; Ch 11 exercise (1) now asks
    for c(q, qdot) from a NumPy RNE; Ch 26 ex10 now reduces contact forces with tiles; Ch 10 ex2 uses `opt.density`
    instead of gravity.
30. **APPLIED** - Ch 1 detail. Plain-language unsupported list; ex7 and the explorer moved to a `.deeper` block and to
    `reference/api-at-a-glance.html`; driver troubleshooting in a collapsed block; the hands-on example stays ex8 (PGS)
    and a predict-what-loads exercise.
31. **APPLIED** - Troubleshooting page: `reference/troubleshooting.html` (0.10), linked from every summary (0.5).
32. **APPLIED** - Course recap: `reference/course-map.html` (interactive breadcrumb linked to chapters and sources, a
    30-question cumulative quiz), "Part review" quiz blocks at the end of each Part, Ch 30 §11 wrap-up.
33. **APPLIED** - Ch 30 prerequisites are now "8, 10, 24, 26, 28 (§1-§3 only)"; 0.2 states Ch 29 is optional for the
    RL track.
34. **APPLIED** - Running project list fixed (0.3, 0.10): Ch 9 adds `describe_overflow`, Ch 14 adds `sensor_slices`
    (used by Ch 26 ex2 and Ch 30), Ch 8 adds `snapshot/restore`.
35. **APPLIED** - GPU throughput intuition: Ch 6 §10 + ex12 (world-steps/s vs nworld next to C MuJoCo) and the
    throughput curve, with a forward link to Ch 24.
36. **APPLIED** - Rays owner: 0.9 row "Rays → Ch 27"; Ch 14 §4 treats `rays` as a black box with a forward link; the
    Ch 27 recall arrow is gone.

### Runnable lens

37. **APPLIED** - Flex + hfield. Verified io.py lines ~605-612 (Flex-SDF, Flex-HField, rigid flexes). The v2 Part IV
    checkpoint is split: Ch 18 ex9 (TERRAIN + scatter(30), rigid paths) and Ch 23 ex8 (cloth over scatter on a plane);
    Ch 23 ex5 lists the three new unsupported combos; pitfall boxes in Ch 23 §5 and M7; new model M11 has no hfield/SDF.
38. **APPLIED** - mjwarp-record is GPU-only. Verified `cli.unroll` opens `wp.ScopedStream(wp.get_stream())`. Rule G
    lists it; Ch 5 ex11 is guarded by `ON_GPU` with the verified manual CPU loop; the capability matrix says "GPU only
    (CLI); CPU: manual loop" and notes `.gif`/`.webp` only.
39. **APPLIED** - SDF patching per process. Ch 18 ex5 runs as a subprocess with an ERROR-line count; ex6 and ex8 are
    fresh-process scripts run via `!python`; pitfall box and a "fresh process" diagram; 0.3 notes such examples.
40. **APPLIED** - Setup cell. Rule S now checks the driver first, picks `warp-lang==1.19.0` or the verified `+cu12` URL,
    pins `mujoco-warp`, `mujoco-core` and `warp-lang`, needs no restart, and prints `GRAPH_COND`.
41. **APPLIED** - Notebook self-containment: `%%writefile my_env.py` / `ppo_reference.py` cells generated by the
    integrator (0.10), notebook bullets updated in the chapters that use them, checklist item 8.
42. **APPLIED** - Warp log level. Verified `wp.config.log_level` defaults to 20 and `wp.config.quiet` does not exist.
    The canonical import block sets `wp.LOG_WARNING` after `import warp`; Expected outputs are captured with it; Ch 4 §8
    and ex12 show the INFO output once.
43. **APPLIED** - graph_conditional fallback in Rule G, `my_env.capture_step` and every capture example; Ch 24 §5 and
    ex8 explain `check_toolkit_driver` warning only.
44. **APPLIED** - User contacts. Ch 26 §4 and ex8 list exactly the fields to write, forbid `flex/elem/vert` when
    `nflex == 0`, use the verified numbers (nefc [4 4], efc.force 2.9549 vs C 2.954875) and add the
    `wp.config.mode = "debug"` tip; 0.4 carries the rule too.
45. **APPLIED** - CPU torch is now a required verification-venv install (0.4); `CartpoleEnv(backend="torch"|"warp")`;
    ex5 saves `policy_es.npz`; ex7 evaluates PPO if present else ES and prints which.
46. **APPLIED** - set_const in graphs. Ch 30 §4: in-graph DR only for fields with no derived recompute (friction, gear/
    gainprm, damping); mass DR eagerly at rollout boundaries + `set_const`; in-graph set_const marked "not verified";
    Ch 29 sysid also calls set_const outside any graph.
47. **APPLIED** - Verified MJCF strings pasted into the specs: dcmotor (Ch 12 ex6), surfacevel conveyor (Ch 16 ex9),
    motor delay with `[0,0,0,1,1,1]` (Ch 14 ex8), rangefinder data spec, contact sensor and interval jointpos strings
    from the shipped tests (Ch 14 ex4, ex6, ex7). "Author verifies" notes removed there; the remaining ones (polynomial
    stiffness and actuator damping attributes, custom SDF plugin layout) point to the exact test file to copy from.
48. **APPLIED** - JAX install. Ch 28 uses Colab's preinstalled JAX only, sets `XLA_FLAGS`,
    `XLA_PYTHON_CLIENT_ALLOCATOR=platform` and `XLA_PYTHON_CLIENT_PREALLOCATE=false` in a first cell, follows
    `jax_test.py` (`graph_mode=wp.JaxCallableGraphMode.WARP`, explicit `graph_conditional`, GPU-backend skip), and
    separates torch and JAX sections.
49. **APPLIED** - PID message. Ch 12 ex7 uses `<pid joint="j" kp="1"/>` and the exact
    `NotImplementedError: ['mjGAIN_PID'] not supported.`, and prints `mjw.DynType` members.
50. **APPLIED** - EventTracer wording. Rule G corrected (construction succeeds, the first `event_scope` raises); idiom
    `EventTracer(enabled=ON_GPU)` used in Ch 7 ex10 and Ch 25 ex1.
51. **APPLIED** - Renderer fallback catches `Exception` (ImportError without PyOpenGL/EGL) and prints the exception
    class (Rule O).
52. **APPLIED** - set_const_fixed / set_const_0 deprecated: same change as item 10 (duplicate finding from the runnable
    lens), with the verified ex5/ex7 numbers in Ch 10.
53. **APPLIED** - NVMAX only on the sleep path (verified: the bit is set only in `island.py`). Ch 21 ex4 is built on the
    sleep-enabled Newton scene and shows that a small nvmax without sleep gives overflow `[0]`.
54. **APPLIED** - `get_state` size. Pitfall in 0.4 and Ch 8 §4; `my_env.snapshot` allocates with `mj_stateSize` and
    asserts the shape; checklist item 9.
55. **APPLIED** - Viewer dependencies. Ch 5 §9: `pip install "mjviser>=0.0.13"` for `--viewer viser` (not `[dev]`),
    glfw from the `[viewer]` extra for the native viewer; "unverified via tunnel" kept.
56. **APPLIED** - Verification venv. Installing matplotlib, mediapy, pillow (via the extra), glfw, PyOpenGL and CPU torch
    is the integrator's first step, followed by a re-run of all examples (0.4).

### Visual lens

57. **APPLIED** - Breadcrumb order. Verified `fwd_position` (kinematics → crb/tendon_armature → optional factor_m →
    collision → make_constraint → island (sleep) → transmission) and `_forward` (factor inside
    `fwd_acceleration(factorize=True)`, `rne_postconstraint` before `sensor_acc`). A.1 redefined with stable ids, new
    `st-transmission`, `st-island`, `st-rne_post`, the dashed `factor_m` ghost socket and the "factor happens here"
    label; Ch 7 §2 and its figures match.
58. **APPLIED** - Narrowphase dispatch. Verified a single `wp.launch(_primitive_narrowphase(...), dim=d.naconmax)`
    with a static if-chain filtered by `geom_pair_type_count`, and one kernel per convex pair type. Ch 16 objective 2,
    §4, ex8 and the two-panel dispatch figure replace the "several type-pair kernels" picture.
59. **APPLIED** - RNE stepper. Verified `_cacc_branch` over `(nworld, nbranch)`, `_cfrc`, `_cfrc_subtree` (contiguous
    ranges), `_cfrc_world`. Ch 12 §3 and a three-phase stepper named after the kernels; the serial walk is a greyed
    "textbook / MuJoCo C" toggle.
60. **APPLIED** - Atlas layouts 6 (tiled block-per-world), 7 (3-D grids) and 8 (row per contact) added to A.6 and owned
    by Ch 7, fed by Ch 7 ex5's recorded dims. Combined with pedagogy item 24: Ch 7 shows layouts 1, 2, 6, 7, 8 and
    the algorithm-specific layouts 3, 4, 5 are added by Ch 15, 17 and 27.
61. **APPLIED** - World replay player (A.7) with `--dump-json` frames: Ch 1 hero (256 real pendulum worlds, ex5b), Ch 2
    mocap, Ch 3 tennis racket, Ch 6 small multiples, Ch 8 reset mask/mocap, Ch 9 overflow sink, Ch 10 DR mosaic,
    Ch 13 energy race, Ch 21 sleep, Ch 23 cloth (real `flexvert_xpos`), Ch 30 evaluation rollouts; JS physics only where
    interactivity needs it, labelled illustrative (Rule D).
62. **APPLIED** - Real render output. Rule D extended to images (`--dump-png`, base64, < 100 KB per chapter): Ch 5 "your
    first rendered worlds" strip, Ch 27 mosaic on real pixels, stale-BVH flipbook, visual-DR contact sheet, splat image.
63. **APPLIED** - Shared `mini3d` helper (A.8) and Rule 3D; listed users in A.8; Ch 17's hand-written 3D view now uses
    it.
64. **APPLIED** - SAP stepper rewritten (Ch 15): oblique direction in mini3d, interval radius formula, per-world sorted
    segments (SAP_TILE vs SAP_SEGMENTED), `sap_range` binary search, `array_scan`, NaN/missing-mesh toggle; verified
    against `collision_driver.py::sap_broadphase/_sap_project` and `collision_core.py::sap_range`.
65. **APPLIED** - J layout figure (Ch 19 §5, ex10): dense `(nworld, njmax_pad, nv_pad)` with padding vs sparse
    `(nworld, 1, njmax_nnz)` with rowadr/colind, byte counters, linked to the efc strip.
66. **APPLIED** - Ch 20: solver-iteration stepper named `_solver_iteration` driven by a NumPy teaching solver (Rule D),
    and a state-flip strip from real `d.efc.state` dumps (new ex12).
67. **APPLIED** - CCD scratch calculator and the EPA_HORIZON overflow frame (Ch 17, ex8 extended); rules verified in
    `collision_convex.py` lines ~1279-1322.
68. **APPLIED** - Shared world grid (A.9) used by Ch 8, 10, 20 (real `solver_niter`), 21 and 30.
69. **APPLIED** - Quaternion-integrate widget (Ch 13, owner) with ex10 data; verified `_next_position` uses
    `math.quat_integrate`.
70. **APPLIED** - Block router figure (Ch 11) with the four factorization paths and a level-schedule frame for
    `qLD_updates`.
71. **APPLIED** - Rule I (tap and keyboard parity, caption-line readouts, phone focus/zoom modes, stepper stacking below
    640px) in 0.5 and A.5; NXN matrix and output-buffer mosaic call it out.
72. **APPLIED** - Ring-buffer stepper named `_history_find_index` / `_history_read_scalar`, with
    `_history_physical_index` and the per-(world, actuator) grid (Ch 14).
73. **APPLIED** - Octree sampling figure (2-D quadtree analogue of `find_oct`, labelled) and Ch 18 §6 on
    `sample_volume_sdf`/`sample_volume_grad`/`box_project`.
74. **APPLIED** - Overflow LED panel driven by real per-world `d.overflow` dumps with step scrubbing, the exact warning
    string and the silencing line (Ch 9).

No gap was rejected outright. Two were applied in a corrected form (items 9 and 60), and item 52 duplicated item 10.
