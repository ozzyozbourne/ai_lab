"""Example 2.3 - step PLAYGROUND with mujoco.mj_step and record a trajectory.

Steps 200 times (2 s at timestep 0.01), records the ball and box heights (qpos z slots) and the
hinge angle, prints where they settle, then saves a plot (Rule O: numbers first, plot optional).
Run: python ex3_trajectory.py [--dump-json PATH] [--png PATH]
  --dump-json PATH  writes the recorded heights for the chapter figure (Rule D)
  --png PATH        where to save the matplotlib plot (default ex3_trajectory.png)
"""
import argparse
import json

import mujoco
import numpy as np

np.set_printoptions(precision=4, suppress=True)

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <camera name="overview" pos="0.5 -3 1.5" xyaxes="1 0 0 0 0.45 0.9"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/>
      <geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/>
      <geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
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
parser.add_argument("--png", default="ex3_trajectory.png")
args, _ = parser.parse_known_args()

NSTEP = 200
mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
mjd = mujoco.MjData(mjm)

# qpos layout (Example 2.2): ball 0..6, box 7..13, hinge 14. z is the 3rd slot of a free joint.
BALL_Z, BOX_Z, HINGE = 2, 7 + 2, 14
t, ball_z, box_z, hinge = [], [], [], []
for _ in range(NSTEP):
    mujoco.mj_step(mjm, mjd)
    t.append(mjd.time)
    ball_z.append(mjd.qpos[BALL_Z])
    box_z.append(mjd.qpos[BOX_Z])
    hinge.append(mjd.qpos[HINGE])

print(f"t = {mjd.time:.2f} s after {NSTEP} steps")
print(f"ball z: start 1.000, settled {ball_z[-1]:.4f}  (radius 0.1)")
print(f"box  z: start 1.000, settled {box_z[-1]:.4f}  (half-size 0.1)")
print(f"hinge angle at the end: {hinge[-1]:.3f} rad (no limit, no damping: it keeps swinging)")
print("contacts at the end:", mjd.ncon, "| constraint rows:", mjd.nefc)

if args.dump_json:
    keep = slice(0, NSTEP, 2)   # 100 samples
    out = {"dt": 2 * mjm.opt.timestep, "t": [round(v, 3) for v in t[keep]],
           "ball_z": [round(float(v), 4) for v in ball_z[keep]],
           "box_z": [round(float(v), 4) for v in box_z[keep]],
           "hinge": [round(float(v), 3) for v in hinge[keep]]}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    print("skipped plot: matplotlib not installed")
else:
    fig, ax = plt.subplots(figsize=(6, 3))
    ax.plot(t, ball_z, label="ball z")
    ax.plot(t, box_z, label="box z")
    ax.set_xlabel("time [s]")
    ax.set_ylabel("height [m]")
    ax.legend()
    fig.tight_layout()
    fig.savefig(args.png, dpi=80)
    print("saved", args.png)
