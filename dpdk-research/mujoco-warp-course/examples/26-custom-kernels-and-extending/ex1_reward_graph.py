"""Example 26.1 - a reward kernel and an accumulate kernel, captured with mjw.step in one graph.

The reward kernel follows MJWarp's own conventions: parameters grouped under # Model: /
# Data in: / # In: / # Out:, Data inputs end in _in, outputs in _out, the "*" Model field
opt_timestep is read with worldid % shape[0], locals are typed (ctrl_cost = float(0.0)) and no
parameter has a default. Both kernels are added to my_env.py as site_reward and accumulate.
Every world holds the double pendulum's shoulder with a different constant torque; the reward
is -(distance from the tip site to a target + 0.01 ctrl^2) * timestep, summed over the episode.
Run: python ex1_reward_graph.py [--dump-json PATH]
  --dump-json PATH writes decimated tip positions and rewards of every world (Rule D).
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
    import my_env_step26 as my_env          # examples/26-custom-kernels-and-extending/

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

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 200                                  # 2 s of simulated time
TARGET = (0.6, 0.0, 0.9)                     # a point the tip can reach (link lengths 0.5 + 0.5)
CTRL_W = 0.01

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
tip = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_SITE, "tip")

# allocate EVERYTHING the graph touches before capture: the graph stores array addresses
reward = wp.zeros(NWORLD, dtype=float)
total = wp.zeros(NWORLD, dtype=float)
ctrl = np.linspace(-4.0, 4.0, NWORLD, dtype=np.float32).reshape(NWORLD, 1)   # constant torque


def restart():
    d.qpos.zero_()
    d.qvel.zero_()
    d.time.zero_()
    d.ctrl.assign(ctrl)                      # assign = same array object, new contents
    total.zero_()


def post(m, d):                              # recorded after mjw.step inside the graph
    my_env.site_reward(m, d, tip, TARGET, CTRL_W, reward)
    my_env.accumulate(reward, total)


restart()
mjw.step(m, d)                               # warm-up: compile every kernel outside capture
post(m, d)
restart()
graph = my_env.capture_step(m, d, nsub=1, post=post)
print("captured: 1 x mjw.step + reward + accumulate; total before replay =", total.numpy()[:2])
for _ in range(NSTEP):
    wp.capture_launch(graph)
wp.synchronize()

tot = total.numpy()
print(f"{NSTEP} replays = {NSTEP * mjm.opt.timestep:.1f} s | ctrl per world:", ctrl[:, 0])
print("episode return per world:", tot)
best = int(np.argmax(tot))
print(f"best world: {best} (ctrl {ctrl[best, 0]:+.2f}), return {tot[best]:.4f}")

# check the LAST reward against NumPy on the host (reads happen after the loop, never inside)
p = d.site_xpos.numpy()[:, tip]
ref = -(np.linalg.norm(p - np.array(TARGET), axis=1) + CTRL_W * ctrl[:, 0] ** 2) \
    * mjm.opt.timestep
print(f"last-step reward vs NumPy: max |diff| = {np.abs(reward.numpy() - ref).max():.1e}")

if args.dump_json:                           # eager re-run with host reads: figure data only
    restart()
    frames = []
    for i in range(NSTEP):
        mjw.step(m, d)
        post(m, d)
        if i % 4 == 0:
            tp = d.site_xpos.numpy()[:8, tip]
            r = reward.numpy()[:8] / mjm.opt.timestep
            frames.append([[round(float(tp[w, 0]), 3), round(float(tp[w, 2]), 3),
                            round(float(r[w]), 3)] for w in range(min(8, NWORLD))])
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": min(8, NWORLD), "dt": 4 * float(mjm.opt.timestep),
                   "target": [TARGET[0], TARGET[2]], "pivot": [0.0, 1.5],
                   "ctrl": [round(float(c), 3) for c in ctrl[:8, 0]],
                   "returns": [round(float(t), 4) for t in tot[:8]], "frames": frames},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
