"""Example T.1 - drop a ball in NWORLD parallel worlds (template chapter demo).

Runs on CPU (small budget) and on a Colab GPU (big budget) without changes.
Run: python ex01_ball_drop.py [--dump-json PATH]
  --dump-json PATH writes decimated per-world heights for the page's replay player (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco>
  <option timestep="0.002"/>
  <worldbody>
    <geom type="plane" size="5 5 0.1"/>
    <body pos="0 0 1">
      <freejoint/>
      <geom type="sphere" size="0.1" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()  # parse_known_args: also works inside Jupyter

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 250

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)

# start every world at a different height: qpos[:, 2] is the ball's z
qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qpos[:, 2] = np.linspace(0.5, 1.5, NWORLD)
d.qpos.assign(qpos)

frames = []
for i in range(NSTEP):
    mjw.step(m, d)
    if args.dump_json and i % 5 == 0:   # decimate: every 5th step (reads to host: demo only)
        frames.append([round(float(v), 3) for v in d.qpos.numpy()[:, 2]])
wp.synchronize()

z = d.qpos.numpy()[:, 2]
print("device:", wp.get_device())
print("qpos shape:", d.qpos.shape)
print(f"t = {NSTEP * mjm.opt.timestep:.2f} s, z first 4 worlds:", z[:4])
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    dt = 5 * float(mjm.opt.timestep)
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "dt": dt, "kind": "height", "zmin": 0.0, "zmax": 1.6,
                   "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
