"""Example 1.4 - the same BALL_DROP in MJWarp with nworld=1, compared with C MuJoCo.

put_model / make_data / mjw.step instead of MjData / mj_step. Prints the ball height every 0.1 s
and the largest difference from the C run (float32 vs float64).
Run: python ex4_ball_mjw.py [--dump-json PATH]
  --dump-json PATH writes both trajectories (every 0.01 s) for the page's comparison chart.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
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

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()  # parse_known_args: also works inside Jupyter

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
mjd = mujoco.MjData(mjm)                                    # C MuJoCo reference (float64)
m = mjw.put_model(mjm)                                      # copy constants to the device
d = mjw.make_data(mjm, nworld=1, nconmax=4, njmax=16)       # state for ONE world on the device

nstep = round(1.0 / mjm.opt.timestep)
z_c, z_w = [], []
for i in range(1, nstep + 1):
    mujoco.mj_step(mjm, mjd)
    mjw.step(m, d)
    if i % 5 == 0:                       # every 0.01 s; .numpy() copies to the host (fine here)
        z_c.append(float(mjd.qpos[2]))
        z_w.append(float(d.qpos.numpy()[0, 2]))
    if i % 50 == 0:
        print(f"t={i * mjm.opt.timestep:.1f} s  z_mjw={z_w[-1]:.5f}  z_c={z_c[-1]:.5f}")

diff = np.abs(np.array(z_c) - np.array(z_w))
print("d.qpos:", d.qpos.shape, d.qpos.dtype.__name__, "on", d.qpos.device)
print(f"max |z_mjw - z_c| over 1 s: {diff.max():.2e} m")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"dt": 0.01, "z_c": [round(v, 5) for v in z_c], "z_mjw": [round(v, 5) for v in z_w],
                   "diff": [float(f"{v:.3e}") for v in diff]}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(z_c), "samples")
