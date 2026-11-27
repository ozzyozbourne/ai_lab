"""Example 13.4 - implicit damping: why Euler survives very stiff damping.

A 1 kg slider with joint damping b and no gravity starts at qvel = 1. With step h, the explicit
update v <- v - h*b/m*v multiplies v by (1 - h*b/m) per step and blows up once h*b/m > 2.
MuJoCo's Euler integrator treats joint damping implicitly: it solves (M + h*D) qacc = f, which
multiplies v by 1 / (1 + h*b/m) and is stable for every b. Eight worlds get eight dampings
(per-world m.dof_damping), so h*b/m sweeps 0.5 ... 4 in one launch.
Run: python ex4_damping_stability.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=False, linewidth=110)

SLIDER = """
<mujoco model="damped_slider">
  <option timestep="0.01" gravity="0 0 0"/>
  <worldbody>
    <body name="block">
      <joint name="slide" type="slide" axis="1 0 0" damping="100"/>
      <geom type="box" size=".1 .1 .1" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NSTEP = 10
RATIO = np.array([0.5, 1.0, 1.5, 1.9, 2.1, 2.5, 3.0, 4.0])   # h*b/m, one per world
NWORLD = len(RATIO)

mjm = mujoco.MjModel.from_xml_string(SLIDER)
h, mass = mjm.opt.timestep, mjm.body_mass[1]


def run(disable_eulerdamp, njmax=None):
    m = mjw.put_model(mjm)
    if disable_eulerdamp:
        m.opt.disableflags |= mjw.DisableBit.EULERDAMP     # same as <flag eulerdamp="disable"/>
    # per-world damping: kernels read dof_damping[worldid % dof_damping.shape[0]]
    m.dof_damping = wp.array((RATIO * mass / h).reshape(NWORLD, 1), dtype=float)
    kw = {} if njmax is None else {"njmax": njmax}
    d = mjw.make_data(mjm, nworld=NWORLD, **kw)
    d.qvel.fill_(1.0)
    hist = [np.ones(NWORLD)]
    for _ in range(NSTEP):
        mjw.step(m, d)
        hist.append(d.qvel.numpy()[:, 0].copy())
    return np.array(hist)


implicit = run(disable_eulerdamp=False)
explicit = run(disable_eulerdamp=True)
print("h*b/m              ", RATIO)
print(f"|qvel| after {NSTEP} steps")
print("  Euler (default)  ", np.abs(implicit[-1]))
print("  predicted        ", (1 / (1 + RATIO)) ** NSTEP)
print("  EULERDAMP off    ", np.abs(explicit[-1]))
print("  predicted        ", np.abs(1 - RATIO) ** NSTEP)
print("unstable worlds (EULERDAMP off):", np.flatnonzero(np.abs(explicit[-1]) > 1).tolist())

# 4.0.1 pitfall: with njmax=0 the solver skips the code that fills d.efc.Ma, which the Euler
# damping solve uses as its right-hand side, so qacc = 0 and the damping does nothing.
frozen = run(disable_eulerdamp=False, njmax=0)
print("  Euler, njmax=0   ", np.abs(frozen[-1]), "<- 4.0.1 wheel: velocities frozen")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"ratio": RATIO.tolist(), "nstep": NSTEP,
                   "implicit": [[float(f"{v:.4e}") for v in row] for row in implicit.T],
                   "explicit": [[float(f"{v:.4e}") for v in row] for row in explicit.T]}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
