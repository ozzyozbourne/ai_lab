# Notebook spec for Chapter 10. Build with:
#   python3 tools/make_notebook.py notebooks/specs/10-domain-randomization.py
SLUG = "10-domain-randomization"
TITLE = "Ch 10 · Domain Randomization with Batched Model Fields"

HIST = r'''
# Robustness histogram: the Example 10.11 study again, 4096 worlds on a GPU (64 on CPU).
# Reuses FLAT_BOX, DR_FIELDS and my_env from the Example 10.11 cell.
NW_H = 4096 if ON_GPU else 64
mjm_h = mujoco.MjModel.from_xml_string(FLAT_BOX)
box_h = mujoco.mj_name2id(mjm_h, mujoco.mjtObj.mjOBJ_BODY, "box")
m_h = mjw.put_model(mjm_h, batch_sizes={k: NW_H for k in DR_FIELDS})
d_h = mjw.make_data(mjm_h, nworld=NW_H, nconmax=8, njmax=32)
rng_h = np.random.default_rng(1)
my_env.randomize(m_h, wp.array([7], dtype=int), wp.zeros(NW_H, dtype=int),
                 wp.array(np.ones(NW_H, dtype=bool), dtype=bool), lo=0.1, hi=1.0)
mass_h = rng_h.uniform(0.5, 5.0, NW_H)
bm, bi = m_h.body_mass.numpy(), m_h.body_inertia.numpy()
bi[:, box_h] *= (mass_h / bm[:, box_h])[:, None]
bm[:, box_h] = mass_h
m_h.body_mass.assign(bm)
m_h.body_inertia.assign(bi)
slope_h = np.radians(rng_h.uniform(15.0, 40.0, NW_H))
m_h.opt.gravity = wp.array(np.stack([9.81 * np.sin(slope_h), 0 * slope_h, -9.81 * np.cos(slope_h)], 1),
                           dtype=wp.vec3)
mjw.set_const(m_h, d_h)
x0_h = d_h.qpos.numpy()[:, 0].copy()
for _ in range(200):
    mjw.step(m_h, d_h)
slide_h = d_h.qpos.numpy()[:, 0] - x0_h
mu_h = m_h.geom_friction.numpy()[:, 0, 0]
print(f"{NW_H} worlds, slid > 0.5 m: {(slide_h > 0.5).mean():.0%}, overflow:", my_env.describe_overflow(d_h))
try:
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(7, 3.5))
    for lo, hi in [(0.1, 0.3), (0.3, 0.5), (0.5, 0.7), (0.7, 1.0)]:
        sel = (mu_h >= lo) & (mu_h < hi)
        ax.hist(slide_h[sel], bins=40, range=(0, 3), alpha=0.6, label=f"mu in [{lo}, {hi})")
    ax.axvline(0.5, color="k", ls="--", lw=1)
    ax.set_xlabel("slide distance after 1 s [m]"); ax.set_ylabel("worlds"); ax.legend()
    fig.tight_layout()
    plt.show()
except ImportError:
    print("skipped: matplotlib not installed")
'''

STUB1 = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

SLIDER_BOX = """                      # the slider box of Example 10.5, compacted
<mujoco><worldbody>
  <body name="box" pos="0.5 0 0.5"><joint name="rail" type="slide" axis="1 0 0"/>
    <geom type="box" size=".1 .1 .1" mass="1" contype="0" conaffinity="0"/>
    <body name="payload" pos="0 0 .15"><geom type="sphere" size=".05" mass="0.5" contype="0" conaffinity="0"/></body>
  </body></worldbody>
  <actuator><motor joint="rail" gear="1"/></actuator>
</mujoco>"""

def dr_batch_sizes(nworld):
    ...  # your code: return {field_name: nworld, ...} for the inputs AND the derived outputs

NW = 3
mjm = mujoco.MjModel.from_xml_string(SLIDER_BOX)
sizes = dr_batch_sizes(NW)
m = mjw.put_model(mjm, batch_sizes=sizes)
d = mjw.make_data(mjm, nworld=NW)
assert set(sizes) >= {"body_mass", "body_subtreemass", "body_invweight0", "dof_invweight0", "actuator_acc0"}
for k in sizes:
    assert getattr(m, k).shape[0] == NW, k
bm = m.body_mass.numpy(); bm[:, 1] = [1.0, 2.0, 3.0]; m.body_mass.assign(bm)
mjw.set_const(m, d)
np.testing.assert_allclose(m.body_subtreemass.numpy()[:, 1], [1.5, 2.5, 3.5], rtol=1e-5)
np.testing.assert_allclose(m.actuator_acc0.numpy()[:, 0], 1 / np.array([1.5, 2.5, 3.5]), rtol=1e-4)
np.testing.assert_allclose(m.dof_invweight0.numpy()[:, 0], 1 / np.array([1.5, 2.5, 3.5]), rtol=1e-4)
print("exercise 10.1 passed")
'''

SOL1 = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

SLIDER_BOX = """                      # the slider box of Example 10.5, compacted
<mujoco><worldbody>
  <body name="box" pos="0.5 0 0.5"><joint name="rail" type="slide" axis="1 0 0"/>
    <geom type="box" size=".1 .1 .1" mass="1" contype="0" conaffinity="0"/>
    <body name="payload" pos="0 0 .15"><geom type="sphere" size=".05" mass="0.5" contype="0" conaffinity="0"/></body>
  </body></worldbody>
  <actuator><motor joint="rail" gear="1"/></actuator>
</mujoco>"""

def dr_batch_sizes(nworld):
    inputs = ["body_mass", "body_inertia"]
    derived = ["body_subtreemass", "body_invweight0", "dof_invweight0", "actuator_acc0"]
    return {k: nworld for k in inputs + derived}

NW = 3
mjm = mujoco.MjModel.from_xml_string(SLIDER_BOX)
sizes = dr_batch_sizes(NW)
m = mjw.put_model(mjm, batch_sizes=sizes)
d = mjw.make_data(mjm, nworld=NW)
assert set(sizes) >= {"body_mass", "body_subtreemass", "body_invweight0", "dof_invweight0", "actuator_acc0"}
for k in sizes:
    assert getattr(m, k).shape[0] == NW, k
bm = m.body_mass.numpy(); bm[:, 1] = [1.0, 2.0, 3.0]; m.body_mass.assign(bm)
mjw.set_const(m, d)
np.testing.assert_allclose(m.body_subtreemass.numpy()[:, 1], [1.5, 2.5, 3.5], rtol=1e-5)
np.testing.assert_allclose(m.actuator_acc0.numpy()[:, 0], 1 / np.array([1.5, 2.5, 3.5]), rtol=1e-4)
np.testing.assert_allclose(m.dof_invweight0.numpy()[:, 0], 1 / np.array([1.5, 2.5, 3.5]), rtol=1e-4)
print("exercise 10.1 passed")
'''

SOL2 = r'''
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

SLOPE = """
<mujoco><option timestep="0.005"/><worldbody>
  <geom name="slope" type="plane" size="5 5 .1" euler="0 30 0"/>
  <body name="box" pos="0.0505 0 0.08747" euler="0 30 0"><freejoint/>
    <geom name="box" type="box" size=".1 .1 .1" mass="1" friction="0.05 0.005 0.0001"/></body>
</worldbody></mujoco>"""
FLOOR_MU = [0.2, 0.35, 0.5]
mjm = mujoco.MjModel.from_xml_string(SLOPE)
floor = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_GEOM, "slope")
m = mjw.put_model(mjm, batch_sizes={"geom_friction": len(FLOOR_MU)})
d = mjw.make_data(mjm, nworld=len(FLOOR_MU), nconmax=8, njmax=32)
fr = m.geom_friction.numpy()
fr[:, floor, 0] = FLOOR_MU          # floor only; the box keeps 0.05 (max rule picks the floor)
m.geom_friction.assign(fr)
x0 = d.qpos.numpy()[:, :3].copy()
for _ in range(200):
    mjw.step(m, d)
dist = np.linalg.norm(d.qpos.numpy()[:, :3] - x0, axis=1)
print("slide:", dist.round(3))
assert dist[0] > dist[1] > dist[2] > 0.1
assert not d.overflow.numpy().any()
print("exercise 10.2 passed")
'''


CELLS = [
    ["md", "**How this notebook works.** Every example cell below is the same file as on the chapter page "
           "(`examples/10-domain-randomization/`). Budgets follow `ON_GPU`: on a Colab GPU the examples use "
           "thousands of worlds, on a CPU runtime a handful. The next cell writes the running helper module "
           "`my_env.py` (the course project file, snapshot after Chapter 10: `make_worlds`, `reset_done`, "
           "`nonfinite_reset`, `snapshot`/`restore`, `describe_overflow`, and the new `randomize`) so the "
           "notebook runs in an empty `/content`."],
    ["writefile", "my_env.py", "examples/10-domain-randomization/my_env_step10.py"],
    ["md", "Cells follow the order of the chapter page. Example numbers follow the example files (other chapters "
           "cite them), so they are not always in sequence."],
    ["md", "## 1. Simple DR: opt arrays (replace them)\n"
           "Per-world fluid density. Note the `m.has_fluid` host flag: it is decided from the XML, so the XML "
           "needs a non-zero density for the per-world values to matter. The inertia-box model adds drag only "
           "(no buoyancy)."],
    ["example", "ex2_density_worlds.py", "10.2"],
    ["md", "Per-world timestep: after 10 steps every world is at a different `d.time`."],
    ["example", "ex3_timestep_worlds.py", "10.3"],
    ["md", "## 2. Friction per world\n"
           "The same box on a 30 degree slope with friction 0.1 ... 1.0. Contact friction is the element-wise "
           "MAX of the two geoms, so the example sets box and slope to the same value. Compare with Coulomb: "
           "`s = 0.5 g (sin - mu cos) t^2`."],
    ["example", "ex4_friction_slide.py", "10.4"],
    ["md", "## 3. Actuator strength: gear and gain\nNo derived constants are needed for motors."],
    ["example", "ex8_actuator_gain.py", "10.8"],
    ["md", "## 4. What can differ per world?\n"
           "`put_model` tags every array whose type spec starts with `\"*\"` with `_is_batched = True`. "
           "Example 10.1 lists them, grouped by prefix. Numeric parameters can vary; sizes, topology, types and "
           "discrete options cannot."],
    ["example", "ex1_list_batchable.py", "10.1"],
    ["md", "## 5. Mass and set_const\n"
           "Batch the inputs (`body_mass`, `body_inertia`) **and** the derived outputs "
           "(`body_subtreemass`, `body_invweight0`, `dof_invweight0`, `actuator_acc0`), then call "
           "`mjw.set_const(m, d)` (groups=ALL)."],
    ["example", "ex5_mass_set_const.py", "10.5"],
    ["md", "The pitfall: batch only the inputs and `set_const` writes one shared row, computed from world 0. "
           "`qacc` is still right, but `subtree_com` divides by the wrong mass."],
    ["example", "ex6_derived_pitfall.py", "10.6"],
    ["md", "## 6. Sizes: geom_size + bounds, set_const(FIXED)\n"
           "Forget `geom_rbound`/`geom_aabb` and the broadphase prunes contacts of the bigger ball. Calling "
           "`set_const(FIXED)` without batching the bounds does not help: `_set_bound` launches over the largest "
           "batch size, so every world writes the one shared row (run 2b). The last lines show the "
           "DeprecationWarning of the old alias `set_const_fixed`, once."],
    ["example", "ex7_size_fixed.py", "10.7"],
    ["md", "## 7. Actuator length ranges after gear DR\n"
           "`set_length_range` copies jnt/tendon range x gear for limited transmissions and writes (0, 0) for "
           "everything else (its `index` argument is ignored in 4.0.1). Batch `actuator_lengthrange` to nworld: "
           "the kernel writes `[worldid, actuator]` without the `% batch` wrap."],
    ["example", "ex12_length_range.py", "10.12"],
    ["md", "## 8. What batch_sizes refuses\n`m.opt.*` fields can only be replaced; structural ints cannot be batched."],
    ["example", "ex10_batch_size_errors.py", "10.10"],
    ["md", "## 9. Re-randomize on device at episode resets\n"
           "An in-place kernel with a device seed, a per-world episode counter and a reset mask. The second half "
           "captures the reset path in a graph and replays it with two seeds. This is `my_env.randomize`."],
    ["example", "ex9_rerandomize_kernel.py", "10.9"],
    ["md", "## 10. Part II checkpoint project: Robust slide\n"
           "Friction (on device), mass (set_const) and slope (tilted gravity) per world; buffers sized from a "
           "measurement rollout (`nconmax = ceil(1.5 * pooled peak nacon / nworld) + 1`, "
           "`njmax = ceil(1.5 * per-world peak nefc) + 4`); overflow checked. Uses `my_env` from the first cell."],
    ["example", "ex11_checkpoint_robust_slide.py", "10.11"],
    ["md", "### Robustness histogram\nThe same study with many more worlds (4096 on a GPU). Your own numbers "
           "print first; the plot needs matplotlib (preinstalled on Colab). Run the Example 10.11 cell first."],
    ["code", HIST],
    ["md", "## Exercise 10.1: a batch_sizes recipe for mass DR\n"
           "Write `dr_batch_sizes(nworld)` returning the batch_sizes dict for randomizing body masses (inputs "
           "and derived outputs). The asserts check shapes and the per-world results of `set_const`."],
    ["code", STUB1],
    ["solution", SOL1, "Exercise 10.1"],
    ["md", "## Exercise 10.2: randomize only the floor\n"
           "Box friction 0.05 in the XML, slope friction 0.2 / 0.35 / 0.5 per world. Assert that the slide "
           "distances strictly decrease, the slowest moved more than 0.1 m, and nothing overflowed. Why does this "
           "work when randomizing only the box would not?"],
    ["code", "# your code here (start from Example 10.4)\n# assert dist[0] > dist[1] > dist[2] > 0.1\n"
             "# assert not d.overflow.numpy().any()"],
    ["solution", SOL2, "Exercise 10.2"],
    ["md", "## Stretch: bounce height versus contact damping\n"
           "Batch `geom_solref`, keep timeconst 0.02 s, give each world a damping ratio in [0.2, 1.0], drop the "
           "ball of Example 10.7 from 1 m and record the apex of the first bounce per world. Plot apex against "
           "dampratio and explain the shape. On a GPU, sweep both solref entries over 4096 worlds and draw a heat map."],
    ["code", "# your experiment here"],
]
