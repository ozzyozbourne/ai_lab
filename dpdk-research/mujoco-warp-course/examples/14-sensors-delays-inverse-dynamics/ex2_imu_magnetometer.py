"""Example 14.2 - an IMU: accelerometer, gyro and magnetometer on a box.

World 0: the box rests flat on the floor. World 1: rests rotated 90 deg about x (on its side).
World 2: tumbles in free fall (high up, spinning). After 200 steps we print each sensor and check
  * accelerometer = specific force: +9.81 along the site's "up" axis at rest, ~0 in free fall;
  * gyro = angular velocity in the site frame (0 at rest);
  * magnetometer = site_xmat^T @ opt.magnetic (sensor.py::_magnetometer).
Run: python ex2_imu_magnetometer.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

IMU_BOX = """
<mujoco model="imu_box">
  <option timestep="0.005" magnetic="0 -0.5 0"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="box" pos="0 0 .1">
      <freejoint/>
      <geom type="box" size=".1 .1 .1" mass="1"/>
      <site name="imu"/>
    </body>
  </worldbody>
  <sensor>
    <accelerometer name="acc" site="imu"/>
    <gyro name="gyro" site="imu"/>
    <magnetometer name="mag" site="imu"/>
  </sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD = 3            # three hand-made worlds: same on CPU and GPU
NSTEP = 200

mjm = mujoco.MjModel.from_xml_string(IMU_BOX)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qvel = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
c = np.cos(np.pi / 4)
qpos[1, 3:7] = [c, c, 0, 0]          # world 1: rotated 90 deg about x, resting on a side face
qpos[2, 2] = 50.0                    # world 2: high in the air ...
qvel[2, 3:6] = [2.0, 0.0, 5.0]       # ... and spinning (body-frame angular velocity, rad/s)
d.qpos.assign(qpos)
d.qvel.assign(qvel)

for _ in range(NSTEP):
    mjw.step(m, d)
mjw.forward(m, d)       # sensors of the final state
wp.synchronize()

sd = d.sensordata.numpy()
acc, gyro, mag = sd[:, 0:3], sd[:, 3:6], sd[:, 6:9]
xmat = d.site_xmat.numpy()[:, 0]                       # (nworld, 3, 3)
magnetic = mjm.opt.magnetic
labels = ["rest flat", "rest on side", "free fall + spin"]
for w in range(NWORLD):
    print(f"world {w} ({labels[w]}):")
    print("  accelerometer", acc[w], "| norm", f"{np.linalg.norm(acc[w]):.3f}")
    print("  gyro         ", gyro[w])
    print("  magnetometer ", mag[w], "| R^T @ magnetic", xmat[w].T @ magnetic)
err = max(np.abs(mag[w] - xmat[w].T @ magnetic).max() for w in range(NWORLD))
print(f"max |magnetometer - R^T magnetic| = {err:.2e}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())


def r3(a):
    return np.round(np.asarray(a, dtype=float), 3).tolist()     # float64 first: clean JSON


if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"labels": labels, "acc": r3(acc), "gyro": r3(gyro), "mag": r3(mag),
                   "magnetic": magnetic.tolist()}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
