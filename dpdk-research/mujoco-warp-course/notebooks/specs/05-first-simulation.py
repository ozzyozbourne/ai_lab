# Notebook spec for Ch 05. Build with:
#   python3 tools/make_notebook.py notebooks/specs/05-first-simulation.py
# AUTO_HEADER is off so the EGL ICD cell can run before the standard setup cell (plan 0.4 rule S:
# rendering notebooks write the ICD file right after choosing MUJOCO_GL).
SLUG = "05-first-simulation"
TITLE = "Ch 05 · Your First MJWarp Simulation (and How to See It)"
AUTO_HEADER = False

COLAB = ("https://colab.research.google.com/github/ozzyozbourne/ai_lab/blob/main/"
         "dpdk-research/mujoco-warp-course/notebooks/05-first-simulation.ipynb")

EXERCISE_1 = '''# Exercise 5.1: put_data from a settled MjData carries its contacts to the device.
# 1. Step BALL_DROP in C MuJoCo until the ball rests on the floor.
# 2. Copy it to 4 worlds with mjw.put_data (explicit nconmax / njmax).
# 3. Assert that the device contact pool is not empty.
import mujoco
import numpy as np
import warp as wp
import mujoco_warp as mjw

BALL_DROP = """
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
"""
mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
mjd = mujoco.MjData(mjm)
# ... your code: settle mjd, then d = mjw.put_data(...)
d = None
assert d is not None and d.nacon.numpy()[0] > 0, "no contacts on the device"
print("Exercise 5.1 passed")'''

SOLUTION_1 = '''mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
mjd = mujoco.MjData(mjm)
for _ in range(1000):                       # 2 s: the ball has landed and settled
    mujoco.mj_step(mjm, mjd)
print("host ncon:", mjd.ncon, "nefc:", mjd.nefc)          # 1 contact, 4 rows (pyramidal)
d = mjw.put_data(mjm, mjd, nworld=4, nconmax=4, njmax=16)
print("device nacon:", d.nacon.numpy(), "nefc per world:", d.nefc.numpy())
assert d.nacon.numpy()[0] > 0
print("Exercise 5.1 passed")'''

EXERCISE_2 = '''# Exercise 5.2: 100 MJWarp steps of BALL_DROP match C MuJoCo within 1e-4.
# Use make_data with nworld=2, step both engines 100 times, compare world 1 with C.
mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
# ... your code
err = None
assert err is not None and err < 1e-4, err
print(f"max |qpos diff| = {err:.2e}  Exercise 5.2 passed")'''

SOLUTION_2 = '''mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2, nconmax=4, njmax=16)
ref = mujoco.MjData(mjm)
for _ in range(100):
    mjw.step(m, d)
    mujoco.mj_step(mjm, ref)
err = np.abs(d.qpos.numpy()[1] - ref.qpos).max()   # one host read, after the loop
assert err < 1e-4, err
print(f"max |qpos diff| = {err:.2e}  Exercise 5.2 passed")   # about 1e-7 on CPU'''

EGL_CELL = '''# Rendering notebooks only: let glvnd find the NVIDIA EGL driver (from the official
# mujoco_warp tutorial). Must run before mujoco is imported by the setup cell below.
import os
os.environ.setdefault("MUJOCO_GL", "egl")
NVIDIA_ICD_CONFIG_PATH = "/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
try:
    if not os.path.exists(NVIDIA_ICD_CONFIG_PATH):
        os.makedirs(os.path.dirname(NVIDIA_ICD_CONFIG_PATH), exist_ok=True)
        with open(NVIDIA_ICD_CONFIG_PATH, "w") as f:
            f.write('{"file_format_version": "1.0.0", '
                    '"ICD": {"library_path": "libEGL_nvidia.so.0"}}\\n')
    print("EGL ICD file:", NVIDIA_ICD_CONFIG_PATH, "| MUJOCO_GL =", os.environ["MUJOCO_GL"])
except OSError as e:
    print("could not write the EGL ICD file (fine outside Colab):", e)'''

CELLS = [
    ["md", f"# {TITLE}\n\n[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)]({COLAB})\n\n"
           "Companion notebook for the chapter page `chapters/05-first-simulation.html`. Pinned versions: "
           "mujoco-warp 4.0.1, warp-lang 1.19.0, mujoco-core 4.0.1.\n\n"
           "**Before you start:** Runtime > Change runtime type > select a GPU. Then run the cells top to "
           "bottom. Every example also runs on a CPU runtime with small budgets (slower, but correct)."],
    ["code", "# Check the GPU Colab gave you (this fails harmlessly on a CPU runtime).\n!nvidia-smi"],
    ["code", EGL_CELL],
    ["setup", {"render": True}],
    ["code", "# Optional media helpers used under some examples (Rule O: skip if missing).\n"
             "try:\n    import mediapy as media\nexcept ImportError:\n    media = None\n    print('skipped: mediapy not installed')"],

    ["md", "## 1-3. The four calls, `put_model` and `Option`\n"
           "`put_model` copies a compiled `MjModel` to the device as float32 arrays, checks features and adds "
           "warp-only options. Continuous options are arrays of shape `(1,)`; discrete ones are Python ints that "
           "are baked into the kernels."],
    ["example", "ex1_option_table.py", "5.1"],
    ["example", "ex6_tolerance_clamp.py", "5.2"],

    ["md", "## 4. `make_data` vs `put_data`\n"
           "`make_data` starts every world at `qpos0` with derived fields blank until `forward`. `put_data` copies "
           "an existing `MjData`, and runs kinematics **on your host copy** first."],
    ["example", "ex2_make_data_blank.py", "5.3"],
    ["example", "ex4_put_data_mutates.py", "5.4"],

    ["md", "## 5-7. `step`, `get_data_into`, float32 accuracy, chaos and the clock"],
    ["example", "ex8_get_data_into.py", "5.5"],
    ["example", "ex3_step_compare.py", "5.6"],
    ["md", "### Chaos\nThe next cell runs 2000 steps in both engines (about 40 s on a CPU runtime, mostly kernel "
           "compilation). The cell after it plots the divergence inline."],
    ["example", "ex7_chaos.py", "5.7"],
    ["code", "# Plot the divergence from Example 5.7 (variables dq_warp, dq_twin, dt are still defined).\n"
             "try:\n    import matplotlib.pyplot as plt\nexcept ImportError:\n    print('skipped: matplotlib not installed')\n"
             "else:\n    t = np.arange(1, len(dq_warp) + 1) * dt\n"
             "    plt.semilogy(t, np.maximum(dq_warp, 1e-12), label='MJWarp (float32) vs C')\n"
             "    plt.semilogy(t, np.maximum(dq_twin, 1e-12), label='C vs C + 1e-9 rad')\n"
             "    plt.xlabel('time [s]'); plt.ylabel('max |dq| [rad]'); plt.legend(); plt.show()"],
    ["md", "### The clock is float32 too\n`d.time` is a float32 array; `_next_time` adds the timestep once per "
           "step, so long runs accumulate rounding error."],
    ["example", "ex5_time_float32.py", "5.8"],

    ["md", "## 8. Seeing it\nOn Colab with EGL, Example 5.9 uses `mujoco.Renderer`; elsewhere it falls back to the "
           "MJWarp batch renderer."],
    ["example", "ex9_one_frame.py", "5.9"],
    ["code", "if media is not None:\n    media.show_image(img, width=320)"],
    ["example", "ex10_video_tiled.py", "5.10"],
    ["code", "if media is not None:\n    media.show_video(video, fps=1.0 / (render_every * dt), width=256)\n"
             "    media.show_image(tiles[nstep], width=384)"],

    ["md", "## 9. The command-line tools\n`mjwarp-record` runs only on a GPU in 4.0.1; on CPU the example "
           "runs the same loop by hand. `mjwarp-viewer` needs a display, so it is not usable inside Colab."],
    ["example", "ex11_record.py", "5.11"],
    ["code", "import os\nfrom IPython.display import Image, display\n"
             "for name in ('humanoid.gif', 'depth.gif', 'out.gif'):\n"
             "    if os.path.exists(name):\n        display(Image(filename=name))"],

    ["md", "## Exercise 5.1: contacts survive `put_data`\nStep `BALL_DROP` in C MuJoCo until the ball rests, copy "
           "it to 4 worlds with `put_data`, and assert `d.nacon > 0`."],
    ["code", EXERCISE_1],
    ["solution", SOLUTION_1, "Exercise 5.1"],
    ["md", "## Exercise 5.2: match C MuJoCo\nAssert that 100 MJWarp steps of `BALL_DROP` match `mujoco.mj_step` "
           "within 1e-4 (max over qpos)."],
    ["code", EXERCISE_2],
    ["solution", SOLUTION_2, "Exercise 5.2"],
    ["md", "## Stretch: find a model MJWarp refuses\nWrite (or find) an MJCF that compiles in MuJoCo but that "
           "`mjw.put_model` rejects. Print the exception and explain, in one sentence, why MJWarp cannot run it. "
           "Hints: solver, plugins, dense Jacobians, sleeping."],
    ["code", "# your model here\n"],
]
