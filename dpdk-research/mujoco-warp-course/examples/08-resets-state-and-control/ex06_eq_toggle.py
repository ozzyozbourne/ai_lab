"""Example 8.6 - switch an equality constraint off in some worlds with d.eq_active.

MOCAP_TARGET again: the weld holds the box at the target. Odd worlds turn the weld off, so their
box falls to the floor; even worlds keep it. Equality rows (d.ne) appear only where it is on.
Run: python ex06_eq_toggle.py [--dump-json PATH]
  --dump-json PATH writes decimated box heights per world (Rule D, mocap replay, odd tiles).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

MOCAP_TARGET = """
<mujoco model="mocap_target">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="target" mocap="true" pos="0 0 0.5">
      <geom type="box" size=".05 .05 .05" contype="0" conaffinity="0" rgba="0 1 0 .3"/>
    </body>
    <body name="box" pos="0 0 0.5">
      <freejoint/>
      <geom name="box" type="box" size=".05 .05 .05" mass="0.5" rgba=".3 .3 1 1"/>
    </body>
  </worldbody>
  <equality><weld body1="box" body2="target" solref="0.02 1"/></equality>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 100

mjm = mujoco.MjModel.from_xml_string(MOCAP_TARGET)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
print("m.eq_active0:", m.eq_active0.numpy(), "| d.eq_active shape:", d.eq_active.shape)

active = np.ones((NWORLD, mjm.neq), dtype=bool)
active[1::2, 0] = False                  # odd worlds: weld off
d.eq_active.assign(active)               # in place: same array object (graph-safe)

frames = []
for i in range(NSTEP):
    mjw.step(m, d)
    if i == 0:
        print("after 1 step:    ne   =", d.ne.numpy()[:8], "| nefc =", d.nefc.numpy()[:8])
    if args.dump_json and i % 2 == 0:
        frames.append([round(float(z), 3) for z in d.qpos.numpy()[:8, 2]])

print(f"after {NSTEP} steps: box z =", d.qpos.numpy()[:8, 2])
print(f"after {NSTEP} steps: ne   =", d.ne.numpy()[:8], "| nefc =", d.nefc.numpy()[:8])
print("contacts per world (odd worlds sit on the floor):",
      np.bincount(d.contact.worldid.numpy()[:int(d.nacon.numpy()[0])], minlength=8)[:8])

mjw.reset_data(m, d)                     # a reset restores eq_active from m.eq_active0
print("after reset_data: eq_active =", d.eq_active.numpy()[:8, 0].astype(int))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": 8, "dt": 2 * float(mjm.opt.timestep), "kind": "height",
                   "zmin": 0.0, "zmax": 0.6, "eq_active": [int(a) for a in active[:8, 0]],
                   "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
