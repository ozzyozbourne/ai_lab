"""Example 10.11 - Part II checkpoint "Robust slide": a domain-randomization study with sizing.

NWORLD boxes on a plane, each world with its own friction (my_env.randomize, on device), mass
(batch_sizes + set_const) and slope (a tilted gravity vector: for a box on an infinite plane this
is the same physics as tilting the plane). Buffers are sized from a measurement rollout (Ch 9
recipe), then the study runs and reports which worlds slid more than 0.5 m.
Run: python ex11_checkpoint_robust_slide.py [--dump-json PATH]
"""
import argparse
import json
import pathlib
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
try:
    import my_env                           # notebook: written by the %%writefile cell
except ImportError:
    import my_env_step10 as my_env          # examples/10-domain-randomization/

np.set_printoptions(precision=3, suppress=True)

FLAT_BOX = """
<mujoco model="flat_box">
  <option timestep="0.005"/>
  <worldbody>
    <geom name="floor" type="plane" size="50 50 .1"/>
    <body name="box" pos="0 0 .101">
      <freejoint/>
      <geom name="box" type="box" size=".1 .1 .1" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""
parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 16
NSTEP = 200                                         # 1 s
rng = np.random.default_rng(0)

mjm = mujoco.MjModel.from_xml_string(FLAT_BOX)
box = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "box")
DR_FIELDS = ["geom_friction", "body_mass", "body_inertia",                       # inputs
             "body_subtreemass", "body_invweight0", "dof_invweight0"]            # derived
m = mjw.put_model(mjm, batch_sizes={k: NWORLD for k in DR_FIELDS})


def make_randomized_data(nconmax, njmax):
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=nconmax, njmax=njmax)
    mjw.set_const(m, d)                             # derived mass constants, one row per world
    return d


# --- 1. draw the parameters ------------------------------------------------------------------
seed, episode = wp.array([2026], dtype=int), wp.zeros(NWORLD, dtype=int)
all_worlds = wp.array(np.ones(NWORLD, dtype=bool), dtype=bool)
my_env.randomize(m, seed, episode, all_worlds, lo=0.1, hi=1.0)     # friction, on device
mass = rng.uniform(0.5, 5.0, NWORLD)
bm, bi = m.body_mass.numpy(), m.body_inertia.numpy()
bi[:, box] *= (mass / bm[:, box])[:, None]
bm[:, box] = mass
m.body_mass.assign(bm)
m.body_inertia.assign(bi)
slope = np.radians(rng.uniform(15.0, 40.0, NWORLD))
grav = np.stack([9.81 * np.sin(slope), np.zeros(NWORLD), -9.81 * np.cos(slope)], axis=1)
m.opt.gravity = wp.array(grav, dtype=wp.vec3)                   # opt fields: replace
mu = m.geom_friction.numpy()[:, 0, 0]

# --- 2. measurement rollout with a generous budget (Ch 9 recipe) ------------------------------
d = make_randomized_data(nconmax=32, njmax=128)
max_nacon, max_nefc = 0, 0
for i in range(NSTEP):
    mjw.step(m, d)
    if i % 10 == 0:                                 # sampled reads: this run only measures
        max_nacon = max(max_nacon, int(d.nacon.numpy()[0]))
        max_nefc = max(max_nefc, int(d.nefc.numpy().max()))
nconmax = int(np.ceil(1.5 * max_nacon / NWORLD)) + 1
njmax = int(np.ceil(1.5 * max_nefc)) + 4
print(f"measured: nacon <= {max_nacon} (all worlds), nefc <= {max_nefc} (per world)")
print(f"sized:    nconmax = {nconmax} per world, njmax = {njmax}")

# --- 3. the study ------------------------------------------------------------------------------
d = make_randomized_data(nconmax=nconmax, njmax=njmax)
x0 = d.qpos.numpy()[:, 0].copy()
for _ in range(NSTEP):
    mjw.step(m, d)
wp.synchronize()
slide = d.qpos.numpy()[:, 0] - x0
pred = np.maximum(0.0, 0.5 * 9.81 * (np.sin(slope) - mu * np.cos(slope)))   # Coulomb, t = 1 s

print(f"{NWORLD} worlds: mu in [0.1, 1.0), mass in [0.5, 5) kg, slope in [15, 40) deg")
edges = [0.1, 0.3, 0.5, 0.7, 1.0]
for lo, hi in zip(edges[:-1], edges[1:]):
    sel = (mu >= lo) & (mu < hi)
    frac = (slide[sel] > 0.5).mean() if sel.any() else float("nan")
    print(f"  mu in [{lo:.1f}, {hi:.1f}): {sel.sum():4d} worlds, slid > 0.5 m: {frac:5.0%}")
print("slides when mu < tan(slope):", bool(np.all((slide > 0.05) == (mu < np.tan(slope)))))
print("max |slide - Coulomb| =", round(float(np.abs(slide - pred).max()), 3), "m")
print("corr(mass, slide - Coulomb) =", round(float(np.corrcoef(mass, slide - pred)[0, 1]), 2),
      "(small: Coulomb sliding does not depend on mass)")
print("overflow:", my_env.describe_overflow(d))

if args.dump_json:
    with open(args.dump_json, "w") as f:
        r3 = lambda a: [round(float(v), 3) for v in a]
        json.dump({"nworld": NWORLD, "nstep": NSTEP, "nconmax": nconmax, "njmax": njmax,
                   "mu": r3(mu), "slope_deg": r3(np.degrees(slope)), "mass": r3(mass),
                   "slide": r3(slide), "pred": r3(pred)}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
