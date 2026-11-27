# MuJoCo Warp, from zero to expert

An interactive, 30-chapter course on **MuJoCo Warp (MJWarp)**: MuJoCo rewritten as NVIDIA Warp kernels so that
thousands of simulations ("worlds") step together on a GPU. The course starts from rigid-body physics and a first
GPU kernel and builds up to the collision pipeline, the constraint solver, CUDA graphs, custom kernels, rendering,
PyTorch/JAX interop and reinforcement learning at scale.

Each chapter has three parts that match one-to-one:

- an HTML page with explanations, diagrams, animations, interactive widgets, a quiz and exercises
  (`chapters/<slug>.html`);
- runnable Python examples (`examples/<slug>/exNN_name.py`), verified on CPU;
- a Colab notebook with the same examples plus exercises and solutions (`notebooks/<slug>.ipynb`).

## Pinned versions

| Package | Version |
|---|---|
| `mujoco-warp` | 4.0.1 (source read at commit `8f5b9f1`) |
| `warp-lang` | 1.19.0 (PyPI build needs an NVIDIA driver R580+; older drivers use the `+cu12` wheel, chosen automatically by the setup cell) |
| `mujoco-core` | 4.0.1 (import name `mujoco`; do not also `pip install mujoco`) |

## Open the course

- **Locally:** open `index.html` in a browser (double-click works; pages need no server and no build step). The
  pages load fonts, highlight.js 11.9.0 and KaTeX 0.16.9 from CDNs; without network they still render, only less
  styled.
- **On GitHub:** browse the files, or view a page through an HTML preview service such as
  `https://htmlpreview.github.io/?<raw GitHub URL of index.html>`.

Light and dark themes follow your system setting; the moon/sun button switches manually. Progress ("Mark chapter as
complete") is stored only in your browser.

## Chapters

Six Parts; each Part ends with a checkpoint project. Prerequisites always point to lower-numbered chapters.

| # | Chapter | Level | Part | Notebook |
|---|---|---|---|---|
| 01 | [What Is MuJoCo Warp?](chapters/01-what-is-mujoco-warp.html) | beginner | I | [ipynb](notebooks/01-what-is-mujoco-warp.ipynb) |
| 02 | [MuJoCo Essentials for MJWarp Users](chapters/02-mujoco-essentials.html) | beginner | I | [ipynb](notebooks/02-mujoco-essentials.ipynb) |
| 03 | [Rigid-Body Physics from Scratch: Particles, Rigid Bodies, Joints and Contacts](chapters/03-rigid-body-physics-primer.html) | beginner | I | [ipynb](notebooks/03-rigid-body-physics-primer.ipynb) |
| 04 | [NVIDIA Warp and How a GPU Runs Your Kernel](chapters/04-warp-and-the-gpu.html) | beginner | I | [ipynb](notebooks/04-warp-and-the-gpu.ipynb) |
| 05 | [Your First MJWarp Simulation (and How to See It)](chapters/05-first-simulation.html) | beginner | I | [ipynb](notebooks/05-first-simulation.ipynb) |
| 06 | [Many Worlds: The Batched Data Layout](chapters/06-batched-data-layout.html) | beginner | I | [ipynb](notebooks/06-batched-data-layout.ipynb) |
| 07 | [A Guided Tour of step and forward](chapters/07-pipeline-tour.html) | intermediate | I | [ipynb](notebooks/07-pipeline-tour.ipynb) |
| 08 | [Resets, State, Mocap and Control Loops](chapters/08-resets-state-and-control.html) | intermediate | II | [ipynb](notebooks/08-resets-state-and-control.ipynb) |
| 09 | [Contacts, Constraint Budgets and Overflow](chapters/09-contacts-and-buffer-sizing.html) | intermediate | II | [ipynb](notebooks/09-contacts-and-buffer-sizing.ipynb) |
| 10 | [Domain Randomization with Batched Model Fields](chapters/10-domain-randomization.html) | intermediate | II | [ipynb](notebooks/10-domain-randomization.ipynb) |
| 11 | [Equations of Motion, Kinematics and the Mass Matrix](chapters/11-equations-of-motion-kinematics-mass-matrix.html) | advanced | III | [ipynb](notebooks/11-equations-of-motion-kinematics-mass-matrix.ipynb) |
| 12 | [Forces: Passive, Springs, Bias, Actuators and Tendons](chapters/12-forces-actuators-tendons.html) | advanced | III | [ipynb](notebooks/12-forces-actuators-tendons.ipynb) |
| 13 | [Time Integration: Euler, RK4, Implicit and Discrete](chapters/13-integrators.html) | advanced | III | [ipynb](notebooks/13-integrators.ipynb) |
| 14 | [Sensors, Delays and Inverse Dynamics](chapters/14-sensors-delays-inverse-dynamics.html) | advanced | III | [ipynb](notebooks/14-sensors-delays-inverse-dynamics.ipynb) |
| 15 | [Collision I: Geometry Toolkit, Pair Filtering and the Broadphase](chapters/15-geometry-toolkit-and-broadphase.html) | advanced | IV | [ipynb](notebooks/15-geometry-toolkit-and-broadphase.ipynb) |
| 16 | [Collision II: Geom Types and Primitive Colliders](chapters/16-primitive-narrowphase.html) | advanced | IV | [ipynb](notebooks/16-primitive-narrowphase.ipynb) |
| 17 | [Collision III: Convex Shapes with GJK, EPA and Multi-Contact](chapters/17-convex-collision-gjk-epa.html) | expert | IV | [ipynb](notebooks/17-convex-collision-gjk-epa.ipynb) |
| 18 | [Collision IV: Heightfields, SDFs and User SDF Plugins](chapters/18-heightfields-and-sdfs.html) | expert | IV | [ipynb](notebooks/18-heightfields-and-sdfs.ipynb) |
| 19 | [Constraints as Convex Optimization](chapters/19-constraints-as-optimization.html) | expert | V | [ipynb](notebooks/19-constraints-as-optimization.ipynb) |
| 20 | [The Primal Solvers: CG, Newton and the Exact Linesearch](chapters/20-solvers-cg-newton.html) | expert | V | [ipynb](notebooks/20-solvers-cg-newton.ipynb) |
| 21 | [Islands and Sleeping](chapters/21-islands-and-sleep.html) | expert | V | [ipynb](notebooks/21-islands-and-sleep.ipynb) |
| 22 | [Determinism and Reproducibility](chapters/22-determinism-and-reproducibility.html) | expert | V | [ipynb](notebooks/22-determinism-and-reproducibility.ipynb) |
| 23 | [Soft Bodies: Flex, Cloth, Rods and the Discrete Integrator](chapters/23-soft-bodies-flex-discrete-integrator.html) | expert | V | [ipynb](notebooks/23-soft-bodies-flex-discrete-integrator.ipynb) |
| 24 | [CUDA Graphs: Capture, Replay and What Gets Baked](chapters/24-cuda-graphs.html) | expert | VI | [ipynb](notebooks/24-cuda-graphs.ipynb) |
| 25 | [Profiling, Benchmarking and Tuning for Throughput](chapters/25-profiling-benchmarking-tuning.html) | expert | VI | [ipynb](notebooks/25-profiling-benchmarking-tuning.ipynb) |
| 26 | [Writing Custom Kernels and Extending MJWarp](chapters/26-custom-kernels-and-extending.html) | expert | VI | [ipynb](notebooks/26-custom-kernels-and-extending.ipynb) |
| 27 | [Rays, Lidar and Batch Rendering for Thousands of Worlds](chapters/27-rays-lidar-and-batch-rendering.html) | expert | VI | [ipynb](notebooks/27-rays-lidar-and-batch-rendering.ipynb) |
| 28 | [Interop with PyTorch and JAX](chapters/28-interop-torch-and-jax.html) | expert | VI | [ipynb](notebooks/28-interop-torch-and-jax.ipynb) |
| 29 | [Gradients, Sampling-Based Optimization and Parallel System Identification](chapters/29-gradients-and-system-identification.html) | expert | VI | [ipynb](notebooks/29-gradients-and-system-identification.ipynb) |
| 30 | [Capstone: GPU-Native Reinforcement Learning at Scale](chapters/30-capstone-rl-at-scale.html) | expert | VI | [ipynb](notebooks/30-capstone-rl-at-scale.ipynb) |

## Reference pages

All in `reference/`, linked from the home page and chained by their own Previous/Next buttons.

| Page | What it is for |
|---|---|
| [Glossary](reference/glossary.html) | Every term the chapters mark (`data-term`), with its owning chapter section; searchable |
| [API at a glance](reference/api-at-a-glance.html) | All 101 public names of `mujoco_warp` 4.0.1 with signatures and the teaching section, a "supported?" explorer, CLI flag tables |
| [Repository tour](reference/repo-tour.html) | What lives where in the repository at `8f5b9f1`, module by module |
| [Troubleshooting](reference/troubleshooting.html) | Symptom → cause → fix → owning section, plus a `d.overflow` decoder |
| [Course map](reference/course-map.html) | Prerequisite graph, reading paths, the pipeline with its owning chapters, concept owners, a course quiz |
| [Math toolkit](reference/math-toolkit.html) | SPD matrices, Cholesky, gradient descent, Newton, CG, the exact linesearch, quaternions, spatial vectors |
| [Cheat sheets](reference/cheatsheet-part1.html) | One printable sheet per Part ([I](reference/cheatsheet-part1.html), [II](reference/cheatsheet-part2.html), [III](reference/cheatsheet-part3.html), [IV](reference/cheatsheet-part4.html), [V](reference/cheatsheet-part5.html), [VI](reference/cheatsheet-part6.html)) |

## Run the notebooks on Google Colab

1. Open a chapter page and press **Open in Colab**, or go to
   `https://colab.research.google.com/github/ozzyozbourne/ai_lab/blob/main/dpdk-research/mujoco-warp-course/notebooks/<slug>.ipynb`.
2. **Runtime > Change runtime type**, choose a GPU (T4, L4 or A100), save.
3. Run the first cells: `!nvidia-smi`, then the standard setup cell. It checks the driver, installs the pinned
   versions, quiets Warp's JIT log and prints `device: cuda:0`. If it prints "Warp sees no GPU", the runtime has no
   GPU; change the runtime type and run it again.
4. Run the rest top to bottom. Every notebook is self-contained (helper modules are written with `%%writefile`).

The first `mjw.step` compiles kernels and takes a while; later calls use Warp's kernel cache.

The Colab links point at the `main` branch of the repository, so they work once the course is merged there.

## Run the examples on your own machine

```bash
python -m venv .venv && . .venv/bin/activate
pip install "mujoco-warp[viewer]==4.0.1" "mujoco-core[rendering]==4.0.1" "warp-lang==1.19.0" matplotlib mediapy
cd examples/01-what-is-mujoco-warp
python ex1_env_check.py           # any example; small budgets on CPU, big ones on a GPU
```

Every example runs on Warp's CPU device with small `nworld`; GPU-only parts print a "skipped on CPU" note.

## How the examples were verified

There was no GPU while the course was built, so everything was checked on Warp's CPU device:

- Every `examples/<slug>/*.py` was run on CPU (Python 3.13, `mujoco-warp` 4.0.1, `warp-lang` 1.19.0,
  `mujoco-core` 4.0.1, NumPy 2, plus matplotlib, mediapy, CPU PyTorch and JAX for the chapters that use them) with
  small `nworld` and step budgets. The *Expected output* blocks on the pages are what those runs printed; CPU
  timings vary between runs and the pages say so.
- Parts that only run on a GPU (CUDA graph conditional nodes, big budgets, the batch renderer, `mjwarp-record`,
  GPU timings) carry a "GPU only" or "Colab only" badge or note on the page, and the scripts take their CPU branch
  (smaller budgets, or a printed "skipped" note) when Warp sees no GPU.
- Technical claims were checked against the library source at commit `8f5b9f1` and the installed 4.0.1 wheel;
  where the dev tree differs from the wheel, the page has a version note.
- Each chapter went through two review rounds (write, review, verify, fix). `tools/check_chapter.py` checks that
  every code figure equals its script, every link and anchor resolves, and every example appears in the notebook.
- Notebooks are generated from `notebooks/specs/*.py` and were checked by running their cells as scripts on CPU,
  not end to end in Colab. Exercise stub cells fail on purpose until you fill them in, so *Run all* stops at the
  first exercise.

## Layout

```
index.html              course home (chapter list generated from planning/course-plan.json)
chapters/<slug>.html    chapter pages; chapters/_template.html shows every component
examples/<slug>/        runnable example scripts (+ data/ for figure data)
notebooks/<slug>.ipynb  Colab notebooks (generated from notebooks/specs/<slug>.py)
reference/              glossary, troubleshooting, API at a glance, repo tour, course map, math toolkit
assets/                 course.css (design system), course.js (shared widgets), favicon
tools/                  make_notebook.py, sync_examples.py, check_chapter.py, build_index.py
planning/               course plan and research notes
STYLE_GUIDE.md          rules for chapter authors
```

## For authors

Read `STYLE_GUIDE.md`, copy `chapters/_template.html`, and before handing in run:

```bash
python3 tools/sync_examples.py chapters/<slug>.html
python3 tools/make_notebook.py notebooks/specs/<slug>.py
python3 tools/check_chapter.py chapters/<slug>.html
python3 tools/build_index.py     # refresh the home page's chapter list
python3 tools/check_chapter.py --all --strict   # whole course: expect 0 errors, 0 warnings
```

MuJoCo and MuJoCo Warp are projects of Google DeepMind with NVIDIA. This course is an independent study guide built
from the open-source code.
