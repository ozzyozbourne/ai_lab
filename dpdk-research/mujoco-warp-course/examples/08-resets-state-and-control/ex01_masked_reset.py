"""Example 8.1 - reset some worlds and leave the others running (reset_data with a mask).

Four PLAYGROUND worlds take 5 steps, then worlds 0 and 2 are reset with a per-world bool mask.
Run: python ex01_masked_reset.py [--dump-json PATH]
  --dump-json PATH writes per-step time and ball height of every world (Rule D, reset-mask figure).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

PLAYGROUND = """
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
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()  # parse_known_args: also works inside Jupyter

NWORLD = 4  # the mask below is written for 4 worlds; the lesson does not need more
NSTEP = 5

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

frames = []


def record():
    frames.append([[round(float(t), 3), round(float(z), 3)]
                   for t, z in zip(d.time.numpy(), d.qpos.numpy()[:, 2])])


record()
for _ in range(NSTEP):
    mjw.step(m, d)
    record()
print("before reset: time  =", d.time.numpy())
print("before reset: ball z =", d.qpos.numpy()[:, 2])

mask = wp.array([True, False, True, False], dtype=bool)  # shape (nworld,), bool or int
mjw.reset_data(m, d, reset=mask)
record()
print("after reset:  time  =", d.time.numpy())
print("after reset:  ball z =", d.qpos.numpy()[:, 2])

for _ in range(NSTEP):
    mjw.step(m, d)
    record()
print(f"{NSTEP} more steps: time =", d.time.numpy())

try:
    mjw.reset_data(m, d, reset=wp.array([True, False], dtype=bool))
except ValueError as e:
    print("wrong mask shape ->", f"ValueError: {e}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "dt": float(mjm.opt.timestep), "kind": "tiles",
                   "labels": ["time", "ball z"], "reset_frame": NSTEP + 1,
                   "mask": [1, 0, 1, 0], "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
