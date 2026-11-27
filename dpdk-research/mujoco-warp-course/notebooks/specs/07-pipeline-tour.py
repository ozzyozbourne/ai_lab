# Notebook spec for Chapter 7. Build with:
#   python3 tools/make_notebook.py notebooks/specs/07-pipeline-tour.py
SLUG = "07-pipeline-tour"
TITLE = "Ch 07 · A Guided Tour of step and forward"

ICICLE = r'''# Icicle chart of the event_scope tree from Example 7.10.
# On a GPU this uses the real EventTracer times (mean ms per call); on CPU it falls back to the
# launch-count structure, so the chart shows "launches inside each scope" instead of time.
try:
    import matplotlib.pyplot as plt
except ImportError:
    plt = None
    print("skipped: matplotlib not installed")

tree = trace if (ON_GPU and trace) else structure
unit = "ms" if (ON_GPU and trace) else "launches"


def boxes(tr, depth=0, x0=0.0, out=None):
    out = [] if out is None else out
    x = x0
    for name, (vals, sub) in tr.items():
        w = sum(vals) / len(vals) if unit == "ms" else sum(vals)
        out.append((name, depth, x, w))
        boxes(sub, depth + 1, x, out)
        x += w
    return out


def show_tree(tr, depth=0):
    for name, (vals, sub) in tr.items():
        v = sum(vals) / len(vals) if unit == "ms" else sum(vals)
        print(f"{'  ' * depth}{name:<{30 - 2 * depth}} {v:10.4f} {unit}")
        show_tree(sub, depth + 1)


show_tree(tree)
if plt is not None:
    bx = boxes(tree)
    fig, ax = plt.subplots(figsize=(12, 0.6 * (1 + max(b[1] for b in bx))))
    for name, depth, x, w in bx:
        if w <= 0:
            continue
        ax.barh(-depth, w, left=x, height=0.9, color=plt.cm.tab20(hash(name) % 20), edgecolor="white")
        if w > 0.04 * bx[0][3]:
            ax.text(x + w / 2, -depth, name, ha="center", va="center", fontsize=8)
    ax.set_yticks([])
    ax.set_xlabel(unit)
    ax.set_title(f"event_scope tree of one mjw.step ({unit})")
    plt.show()
'''

DASHBOARD = r'''# Show the 4-panel figure Example 7.11 saved (needs matplotlib, which the setup cell installs).
import os
try:
    from IPython.display import Image, display
except ImportError:                       # outside Jupyter
    Image = display = None
if os.path.exists("ex11_dashboard.png") and display is not None:
    display(Image("ex11_dashboard.png"))
else:
    print("ex11_dashboard.png not found: run Example 7.11 first (and make sure matplotlib is installed)")
'''

EX1_STUB = r'''# Exercise 7.1: reproduce forward with the _forward factorize pairing
import os
HUMANOID_PATH = os.path.join(os.path.dirname(mjw.__file__), "test_data", "humanoid", "humanoid.xml")
mjm = mujoco.MjModel.from_xml_path(HUMANOID_PATH)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=4, nconmax=32, njmax=128)
d.ctrl.assign(np.random.default_rng(1).uniform(-1, 1, (4, mjm.nu)).astype(np.float32))
for _ in range(20):
    mjw.step(m, d)
mjw.forward(m, d)
qacc_ref = d.qacc.numpy().copy()
d.qacc.zero_()                      # so that the check below really tests your calls

# your five calls here

err = np.abs(d.qacc.numpy() - qacc_ref).max()
print("max |qacc diff|:", err)
if err < 1e-5:
    print("Exercise 7.1 passed")
else:
    print("not solved yet: qacc does not match forward")
'''

EX1_SOL = r'''import os
HUMANOID_PATH = os.path.join(os.path.dirname(mjw.__file__), "test_data", "humanoid", "humanoid.xml")
mjm = mujoco.MjModel.from_xml_path(HUMANOID_PATH)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=4, nconmax=32, njmax=128)
d.ctrl.assign(np.random.default_rng(1).uniform(-1, 1, (4, mjm.nu)).astype(np.float32))
for _ in range(20):
    mjw.step(m, d)
mjw.forward(m, d)
qacc_ref = d.qacc.numpy().copy()

mjw.fwd_position(m, d, factorize=False)     # no factor in the position stage ...
mjw.fwd_velocity(m, d)
mjw.fwd_actuation(m, d)
mjw.fwd_acceleration(m, d, factorize=True)  # ... a fused factor + solve here
mjw.solve(m, d)

err = np.abs(d.qacc.numpy() - qacc_ref).max()
print("max |qacc diff|:", err)
assert err < 1e-5, err
print("Exercise 7.1 passed")
'''

EX2_STUB = r'''# Exercise 7.2: fewer launches without contacts
from unittest import mock
import mujoco
import numpy as np
import warp as wp
import mujoco_warp as mjw

XML = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
</mujoco>
"""


def count_launches(m, d):
    ...  # your code: wrap wp.launch and wp.launch_tiled, run mjw.step(m, d), return the count


mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=4, nconmax=16, njmax=64)
for _ in range(150):
    mjw.step(m, d)
n_default = count_launches(m, d)
m.opt.disableflags = int(mjw.DisableBit.CONTACT)
mjw.step(m, d)                      # warm up the new configuration
n_nocontact = count_launches(m, d)
print("launches: default", n_default, "| CONTACT disabled", n_nocontact)
if n_default is None or n_nocontact is None:
    print("not solved yet: count_launches returns None")
else:
    assert n_nocontact < n_default
    print("Exercise 7.2 passed")
m.opt.disableflags = 0
'''

EX2_SOL = r'''def count_launches(m, d):
    n = [0]

    def spy(real):
        def wrapper(*a, **kw):
            n[0] += 1
            return real(*a, **kw)
        return wrapper

    with mock.patch.object(wp, "launch", spy(wp.launch)), \
         mock.patch.object(wp, "launch_tiled", spy(wp.launch_tiled)):
        mjw.step(m, d)
    return n[0]


m.opt.disableflags = 0
d = mjw.make_data(mjm, nworld=4, nconmax=16, njmax=64)
for _ in range(150):
    mjw.step(m, d)
n_default = count_launches(m, d)
m.opt.disableflags = int(mjw.DisableBit.CONTACT)
mjw.step(m, d)
n_nocontact = count_launches(m, d)
m.opt.disableflags = 0
print("launches: default", n_default, "| CONTACT disabled", n_nocontact)
assert n_nocontact < n_default
print("Exercise 7.2 passed")
'''

EX3_STUB = r'''# Exercise 7.3: audit the humanoid's force budget
import os
HUMANOID_PATH = os.path.join(os.path.dirname(mjw.__file__), "test_data", "humanoid", "humanoid.xml")
mjm = mujoco.MjModel.from_xml_path(HUMANOID_PATH)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=4, nconmax=32, njmax=128)
rng = np.random.default_rng(2)
d.ctrl.assign(rng.uniform(-1, 1, (4, mjm.nu)).astype(np.float32))
xfrc = np.zeros((4, mjm.nbody, 6), np.float32)
xfrc[:, 1, :3] = rng.normal(0, 20, (4, 3))      # push the torso
d.xfrc_applied.assign(xfrc)
for _ in range(10):
    mjw.step(m, d)
mjw.forward(m, d)

jt = None   # J^T xfrc_applied as a (4, nv) wp.array
res = None  # max |qfrc_smooth - (sum of the terms)|

if jt is None or res is None:
    print("not solved yet: fill in jt and res")
else:
    print("max residual:", res)
    assert res < 1e-4
    assert np.abs(jt.numpy()).max() > 1.0
    print("Exercise 7.3 passed")
'''

EX3_SOL = r'''import os
HUMANOID_PATH = os.path.join(os.path.dirname(mjw.__file__), "test_data", "humanoid", "humanoid.xml")
mjm = mujoco.MjModel.from_xml_path(HUMANOID_PATH)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=4, nconmax=32, njmax=128)
rng = np.random.default_rng(2)
d.ctrl.assign(rng.uniform(-1, 1, (4, mjm.nu)).astype(np.float32))
xfrc = np.zeros((4, mjm.nbody, 6), np.float32)
xfrc[:, 1, :3] = rng.normal(0, 20, (4, 3))
d.xfrc_applied.assign(xfrc)
for _ in range(10):
    mjw.step(m, d)
mjw.forward(m, d)

jt = wp.zeros((4, mjm.nv), dtype=float)
mjw.xfrc_accumulate(m, d, jt)                   # adds J^T xfrc_applied into jt
rhs = (d.qfrc_passive.numpy() - d.qfrc_bias.numpy() + d.qfrc_actuator.numpy()
       + d.qfrc_applied.numpy() + jt.numpy())
res = np.abs(d.qfrc_smooth.numpy() - rhs).max()
print("max residual:", res)
assert res < 1e-4
assert np.abs(jt.numpy()).max() > 1.0
print("Exercise 7.3 passed")
'''

CELLS = [
    ["md", "This notebook holds every example of Chapter 7 in page order. All examples are device-agnostic: "
           "on a Colab GPU they use the big budgets (`nworld=4096`, 10,240 balls in the checkpoint), on CPU the "
           "small ones. Numbers you see here are **your** numbers; the chapter page shows CPU runs."],
    ["md", "## 2. Inside `forward`: calling the stages yourself\n"
           "`mjw.forward` runs `fwd_position`, `fwd_velocity`, `fwd_actuation`, `fwd_acceleration` and `solve` "
           "(plus sensors). Example 7.1 reproduces it with the public stage functions and their default "
           "factorize pairing; Example 7.2 prints what each stage fills in."],
    ["example", "ex1_manual_stages.py", "7.1"],
    ["example", "ex2_stage_outputs.py", "7.2"],
    ["md", "## 4. The stage → Data cheat sheet, measured\n"
           "Example 7.3 wraps `wp.launch` / `wp.launch_tiled` with `unittest.mock` to see which `Data` arrays "
           "each stage passes as kernel inputs and outputs, and compares every field before and after."],
    ["example", "ex3_stage_fields.py", "7.3"],
    ["md", "## 5. The force budget\n"
           "`qfrc_smooth = qfrc_passive - qfrc_bias + qfrc_actuator + qfrc_applied (+ J^T xfrc_applied)`. "
           "Example 7.4 checks the identity per world; Example 7.9 pushes the box through `xfrc_applied`."],
    ["example", "ex4_force_budget.py", "7.4"],
    ["example", "ex9_xfrc_push.py", "7.9"],
    ["md", "## 7. Disable flags\n`m.opt.disableflags` is a Python int read at dispatch: flip bits between steps "
           "(and recapture any CUDA graph afterwards)."],
    ["example", "ex7_disable_flags.py", "7.7"],
    ["md", "## 8. How many kernels, and what shape\n"
           "Example 7.5 counts the launches of one step and sorts them into the launch-shape atlas layouts; "
           "Example 7.6 lists them in order with their pipeline station. On a GPU the counts are the same as on "
           "CPU, only the dims grow with `nworld`."],
    ["example", "ex5_count_launches.py", "7.5"],
    ["example", "ex6_kernel_names.py", "7.6"],
    ["md", "## 9. Where the time goes\n"
           "Example 7.8 times each stage with `wp.synchronize()` around it. **On Colab these are your GPU "
           "numbers**: compare the shares with the CPU figure on the chapter page (that is the stretch "
           "exercise). Example 7.10 prints the nested `EventTracer` tree (real GPU times on a GPU, the launch-"
           "count structure on CPU)."],
    ["example", "ex8_stage_timing.py", "7.8"],
    ["example", "ex10_event_trace.py", "7.10"],
    ["md", "### Trace pretty-printer and icicle chart\nUses `trace` and `structure` from Example 7.10."],
    ["code", ICICLE],
    ["md", "## 11. Part I checkpoint: the bouncing-balls dashboard\n"
           "10,240 balls on a GPU (64 on CPU), 2 s, bounces counted on the device by a custom kernel. "
           "The script prints the summary and saves `ex11_dashboard.png`."],
    ["example", "ex11_checkpoint_dashboard.py", "7.11"],
    ["code", DASHBOARD],
    ["md", "## Exercise 7.1: reproduce `forward` with the `_forward` pairing\n"
           "Five manual calls with the same factorize pairing as `_forward` (not the public defaults). "
           "The assert checks your result."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 7.1"],
    ["md", "## Exercise 7.2: fewer launches without contacts\n"
           "Write `count_launches(m, d)`, count for the playground, disable `CONTACT`, count again."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 7.2"],
    ["md", "## Exercise 7.3: audit the humanoid's force budget\n"
           "Rebuild `qfrc_smooth` from its terms (use `mjw.xfrc_accumulate` for the `J^T xfrc` term)."],
    ["code", EX3_STUB],
    ["solution", EX3_SOL, "Exercise 7.3"],
    ["md", "## Stretch: why do the stage shares differ between CPU and GPU?\n"
           "Rerun Example 7.8 with `NWORLD = 8` and `NWORLD = 4096` (edit the budget block) for both models, "
           "compare with the CPU figure on the chapter page, and explain the differences: per-launch overhead, "
           "the eager solver loop's device-to-host sync per iteration, and how CPU time grows linearly with "
           "`nworld`. Use Example 7.10's tree to find the most expensive scope on your GPU."],
]
