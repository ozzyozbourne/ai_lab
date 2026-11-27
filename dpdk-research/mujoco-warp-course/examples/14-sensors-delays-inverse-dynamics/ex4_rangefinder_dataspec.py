"""Example 14.4 - rangefinder outputs chosen with data="...": the RayDataField bitmask.

A downward-looking site rangefinder with data="dist point normal" rides on a slider at a different
height in every world, over a floor with a raised block. A second rangefinder is attached to a tiny
4x3 downward camera (one ray per pixel) with data="dist". The camera sits in its own static body
"mast": rays exclude the geoms of the sensor's own body, so a camera on the worldbody would not see
the floor. We print the bitmask stored in
mjm.sensor_intprm[:, 0], the resulting sensor dims (1 + 3 + 3 = 7 and 4*3*1 = 12), and the readings.
Run: python ex4_rangefinder_dataspec.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

RANGE_SCENE = """
<mujoco model="rangefinder">
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <geom name="block" type="box" pos=".6 0 .1" size=".2 .2 .1"/>
    <body name="probe" pos="0 0 1">
      <joint name="z" type="slide" axis="0 0 1"/>
      <joint name="x" type="slide" axis="1 0 0"/>
      <geom type="sphere" size=".02" contype="0" conaffinity="0"/>
      <site name="down" zaxis="0 0 -1"/>
    </body>
    <body name="mast" pos="0.3 0 1.5">
      <camera name="eye" xyaxes="1 0 0 0 1 0" fovy="60" resolution="4 3"/>
    </body>
  </worldbody>
  <sensor>
    <rangefinder name="laser" site="down" data="dist point normal"/>
    <rangefinder name="depthcam" camera="eye" data="dist"/>
  </sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD = 4            # four hand-picked probe poses (same on CPU and GPU)

mjm = mujoco.MjModel.from_xml_string(RANGE_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)

# probe pose per world: (dz, dx) relative to the body position (0, 0, 1)
pose = np.array([[0.0, 0.0], [-0.5, 0.0], [0.0, 0.6], [-0.5, 0.6]], dtype=np.float32)
d.qpos.assign(pose)
mjw.forward(m, d)
wp.synchronize()

for i in range(mjm.nsensor):
    mask = int(mjm.sensor_intprm[i, 0])
    fields = [f.name for f in mjw.RayDataField if mask & (1 << f)]
    name = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_SENSOR, i)
    print(f"{name}: sensor_intprm[{i}, 0] = {mask:#08b} -> {fields}, dim = {mjm.sensor_dim[i]}")
print("rays cast per world (m.nrangefinder):", m.nrangefinder)

sd = d.sensordata.numpy()
for w in range(NWORLD):
    dist, point, normal = sd[w, 0], sd[w, 1:4], sd[w, 4:7]
    probe_z = 1.0 + pose[w, 0]
    print(f"world {w}: probe at x={pose[w, 1]:.1f} z={probe_z:.1f} | dist {dist:.4f} "
          f"point {point} normal {normal}")
cam = sd[:, 7:19].reshape(NWORLD, 3, 4)      # row-major pixels, 1 value (dist) per ray
print("camera rangefinder, world 0, dist per pixel (3 rows x 4 cols):")
print(cam[0])
mjd = mujoco.MjData(mjm)                     # same world 0 in MuJoCo C for comparison
mjd.qpos[:] = pose[0]
mujoco.mj_forward(mjm, mjd)
print("max |MJWarp - MuJoCo C| world 0:", f"{np.abs(sd[0] - mjd.sensordata).max():.1e}")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"pose": np.round(pose.astype(float), 3).tolist(),
                   "laser": np.round(sd[:, :7].astype(float), 4).tolist(),
                   "cam": np.round(cam[0].astype(float), 4).tolist()}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
