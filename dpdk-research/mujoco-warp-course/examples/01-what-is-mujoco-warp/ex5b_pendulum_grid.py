"""Example 1.5b - 256 double pendulums, one launch per stage: the data behind the chapter's hero replay.

Every world starts horizontal with a slightly different shoulder angle (a spread of 0.1 rad).
The worlds never talk to each other, so they are free to drift apart (a double pendulum is chaotic).
Run: python ex5b_pendulum_grid.py [--dump-json PATH]
  --dump-json PATH writes 60 decimated frames of both hinge angles for all 256 worlds (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD = 256          # same on CPU and GPU: the replay needs exactly 16 x 16 worlds
NSTEP = 300           # 3 s at timestep 0.01
EVERY = 5             # keep every 5th step -> 60 frames

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)          # no contacts in this model: default sizes are fine

qpos = np.zeros((NWORLD, mjm.nq), dtype=np.float32)
qpos[:, 0] = np.pi / 2 + np.linspace(0.0, 0.1, NWORLD)   # shoulder: horizontal + 0..0.1 rad
d.qpos.assign(qpos)

frames = []
for i in range(1, NSTEP + 1):
    mjw.step(m, d)
    if i % EVERY == 0:
        q = d.qpos.numpy()                       # host copy: only for recording, not for speed
        frames.append([[round(float(a), 3), round(float(b), 3)] for a, b in q])
        if i % 100 == 0:
            spread = q[:, 0].max() - q[:, 0].min()
            print(f"t = {i * mjm.opt.timestep:.0f} s  shoulder angle spread over {NWORLD} worlds: "
                  f"{spread:.3f} rad")

q = d.qpos.numpy()
print("start spread: 0.100 rad | d.qpos.shape:", d.qpos.shape)
print("world 0 and world 255 at t = 3 s (hinge1, hinge2):", q[0], q[-1])

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "dt": EVERY * float(mjm.opt.timestep), "kind": "pendulum2d",
                   "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
