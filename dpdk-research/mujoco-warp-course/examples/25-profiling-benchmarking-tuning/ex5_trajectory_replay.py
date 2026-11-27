"""Example 25.5 - control trajectories: find_keys, make_trajectory, NPZ, load_trajectory, replay.

1. An inline pendulum has three ctrl keyframes named traj_*. io.find_keys picks them by prefix;
   io.make_trajectory linearly interpolates their ctrl on the model timestep.
2. A coarse "log" (one ctrl every 0.03 s) saved as NPZ (ctrl, times, qpos) is read back by
   io.load_trajectory, which resamples it on the timestep with a zero-order hold and sets the
   initial qpos.
3. We replay the trajectory in NWORLD worlds, then show what testspeed's ctrl filter does to it:
   with --replay, every step pulls d.ctrl toward the trajectory at rate exp(-dt/noise_rate), so
   --noise_std 0 alone still lags; the franka_threading benchmark also sets noise_rate 1e-6.
GPU: also runs `mjwarp-testspeed <model> --replay file.npz --noise_std 0 --noise_rate 1e-6`.
Run: python ex5_trajectory_replay.py [--dump-json PATH]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import io as mjw_io            # private API: find_keys, make/load_trajectory

np.set_printoptions(precision=4, suppress=True)
parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4

PENDULUM = """
<mujoco model="traj_pendulum">
  <option timestep="0.01"/>
  <worldbody>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0" damping="0.1"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" ctrlrange="-5 5" ctrllimited="true"/></actuator>
  <keyframe>
    <key name="home" time="0" ctrl="0"/>
    <key name="traj_0" time="0" ctrl="0"/>
    <key name="traj_1" time="0.05" ctrl="4"/>
    <key name="traj_2" time="0.1" ctrl="-2"/>
  </keyframe>
</mujoco>
"""
mjm = mujoco.MjModel.from_xml_string(PENDULUM)
dt = mjm.opt.timestep

# 1. keyframes -> linearly interpolated ctrl trajectory
keys = mjw_io.find_keys(mjm, "traj_")
traj = mjw_io.make_trajectory(mjm, keys)
print("find_keys('traj_') ->", keys, "(key 0 'home' is skipped)")
print("make_trajectory shape:", traj.shape, "ctrl:", traj[:, 0])
try:
    mjw_io.make_trajectory(mjm, [keys[1], keys[0]])
except ValueError as e:
    print("ValueError:", e)

# 2. a coarse log -> NPZ -> zero-order hold on the model timestep
log_ctrl = np.array([[0.0], [3.0], [-1.0], [2.0]])
log_times = np.array([0.0, 0.03, 0.06, 0.09])
mjd = mujoco.MjData(mjm)
with tempfile.TemporaryDirectory() as tmp:  # the NPZ is deleted when the block ends
    path = os.path.join(tmp, "ch25_log.npz")
    np.savez(path, ctrl=log_ctrl, times=log_times, qpos=np.array([[0.3]]))
    ctrls = mjw_io.load_trajectory(path, mjm, mjd)
print("load_trajectory shape:", ctrls.shape, "ctrl:", ctrls[:, 0])
print("initial qpos from the NPZ:", mjd.qpos)

# 3. replay in NWORLD worlds: one assign per step (ctrl is live data)
m = mjw.put_model(mjm)
d = mjw.put_data(mjm, mjd, nworld=NWORLD)
for c in ctrls:
    d.ctrl.assign(np.tile(c, (NWORLD, 1)))
    mjw.step(m, d)
q = d.qpos.numpy()[:, 0]
print(f"after {len(ctrls)} steps, qpos per world:", q, "identical:", bool(np.all(q == q[0])))


def testspeed_ctrl(target, noise_rate, lo=-5.0, hi=5.0):
    """The ctrl that cli._ctrl_noise feeds the step for noise_std=0 (start from ctrl = 0)."""
    rate = np.exp(-dt / noise_rate)
    out, c = [], 0.0
    for t in target:
        c = float(np.clip(rate * c + (1 - rate) * t, lo, hi))
        out.append(c)
    return np.array(out)


for nr in (0.1, 1e-6):
    applied = testspeed_ctrl(traj[:, 0], nr)
    print(f"noise_std 0, noise_rate {nr:g}: applied ctrl", applied.round(3),
          f"max lag {np.abs(applied - traj[:, 0]).max():.3f}")

if ON_GPU:
    with tempfile.TemporaryDirectory() as tmp:  # NPZ and XML are deleted after the subprocess
        gpath = os.path.join(tmp, "ch25_traj.npz")
        np.savez(gpath, ctrl=traj, times=np.arange(len(traj)) * dt)
        xml = os.path.join(tmp, "ch25_pendulum.xml")
        with open(xml, "w") as f:
            f.write(PENDULUM)
        cmd = [sys.executable, "-m", "mujoco_warp.testspeed", xml, "--replay", gpath,
               "--noise_std", "0", "--noise_rate", "1e-6", "--nworld", str(NWORLD)]
        print(subprocess.run(cmd, capture_output=True, text=True).stdout[-400:])
else:
    print("skipped on CPU: mjwarp-testspeed --replay (GPU only)")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"dt": dt, "target": traj[:, 0].round(3).tolist(),
                   "lag_0.1": testspeed_ctrl(traj[:, 0], 0.1).round(3).tolist(),
                   "lag_1e-6": testspeed_ctrl(traj[:, 0], 1e-6).round(3).tolist(),
                   "log_times": log_times.tolist(), "log_ctrl": log_ctrl[:, 0].tolist(),
                   "zoh": ctrls[:, 0].round(3).tolist()}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
