"""Example 8.2 - reset worlds to a keyframe: one id for all worlds, or one id per world (-1 = skip).

PLAYGROUND has one keyframe "up" (ball and box lifted to z = 2, hinge at 0.3 rad).
Run: python ex02_keyframe_reset.py [--dump-json PATH]
  --dump-json PATH writes per-step time and ball height of every world (Rule D, keyframe mode).
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
args, _ = parser.parse_known_args()

NWORLD = 4
NSTEP = 5

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
print("nkey:", mjm.nkey, "| key 0 name:", mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_KEY, 0))

frames = []


def record():
    frames.append([[round(float(t), 3), round(float(z), 3)]
                   for t, z in zip(d.time.numpy(), d.qpos.numpy()[:, 2])])


# 1. one int: every world goes to keyframe 0
mjw.reset_data_keyframe(m, d, 0)
print("key 0 for all:      qpos[:, 2] =", d.qpos.numpy()[:, 2], "hinge =", d.qpos.numpy()[:, 14])
record()

# 2. let the worlds fall a little, then a per-world array: -1 (or any id outside [0, nkey)) skips
for _ in range(NSTEP):
    mjw.step(m, d)
    record()
print(f"after {NSTEP} steps:      qpos[:, 2] =", d.qpos.numpy()[:, 2])
keys = wp.array([0, -1, 0, -1], dtype=int)
mjw.reset_data_keyframe(m, d, keys)
record()
print("keys [0,-1,0,-1]:   qpos[:, 2] =", d.qpos.numpy()[:, 2], "time =", d.time.numpy())
for _ in range(NSTEP):
    mjw.step(m, d)
    record()

# 3. a plain int outside [0, nkey) is an error (only arrays may skip worlds)
try:
    mjw.reset_data_keyframe(m, d, 1)
except ValueError as e:
    print("int key 1 ->", f"ValueError: {e}")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "dt": float(mjm.opt.timestep), "kind": "tiles",
                   "labels": ["time", "ball z"], "reset_frame": NSTEP + 1,
                   "keys": [0, -1, 0, -1], "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
