"""Example 14.5 - collision sensors: distance (GEOMDIST), normal and fromto between two geoms.

A ball (radius 0.1) drops from z=1 onto a floor in every world, from a slightly different height.
A <distance> sensor with cutoff="2" reports the signed ball-floor distance (negative = penetration);
<normal> and <fromto> report the direction and the closest-point segment. These sensors reuse the
collision pipeline (contacts tagged ContactType.SENSOR, sensor.py::_sensor_collision), so the scene
needs contact buffer room. Prints the distance every 50 steps and compares world 0 with MuJoCo C.
Run: python ex5_geomdist.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

DROP = """
<mujoco model="geomdist">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1"/>
    </body>
  </worldbody>
  <sensor>
    <distance name="dist" geom1="ball" geom2="floor" cutoff="2"/>
    <normal name="normal" geom1="ball" geom2="floor" cutoff="2"/>
    <fromto name="fromto" geom1="ball" geom2="floor" cutoff="2"/>
  </sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 300

mjm = mujoco.MjModel.from_xml_string(DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qpos[:, 2] = np.linspace(1.0, 1.3, NWORLD)
d.qpos.assign(qpos)

mjd = mujoco.MjData(mjm)                     # world 0 in MuJoCo C, for comparison
mjd.qpos[:] = qpos[0]

show = np.linspace(0, NWORLD - 1, min(NWORLD, 4)).astype(int)   # 4 evenly spaced worlds (0..3 on CPU)
frames = []
print("worlds shown:", show)
print("step   t     dist per world (4 shown)             C world 0")
for i in range(NSTEP + 1):
    mjw.forward(m, d)                        # sensors for the current state
    mujoco.mj_forward(mjm, mjd)
    if i % 2 == 0:
        frames.append([round(float(v), 3) for v in d.sensordata.numpy()[show, 0]])
    if i % 50 == 0:
        sd = d.sensordata.numpy()
        print(f"{i:4d} {i * mjm.opt.timestep:5.2f}  {sd[show, 0]}  {mjd.sensordata[0]:.4f}")
        if i == 0:
            normal0, fromto0 = sd[0, 1:4].copy(), sd[0, 4:10].copy()
    if i < NSTEP:
        mjw.step(m, d)
        mujoco.mj_step(mjm, mjd)
wp.synchronize()

sd = d.sensordata.numpy()
print("step 0   (separated)  normal:", normal0, "fromto:", fromto0)
print("step 300 (penetrating) normal:", sd[0, 1:4], "fromto:", sd[0, 4:10])
print("MuJoCo C world 0 normal:", mjd.sensordata[1:4], "fromto:", mjd.sensordata[4:10])
print("ball z (world 0):", f"{d.qpos.numpy()[0, 2]:.4f}", "= radius 0.1 + dist")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"dt": 2 * mjm.opt.timestep, "frames": frames, "nworld": len(show)},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
