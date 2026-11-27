"""Example 18.7 - sweep sdf_initpoints and sdf_iterations on one SDF contact.

The SDF geom is a 0.2 m cube mesh with type="sdf" and no plugin: MuJoCo compiles the mesh into
an octree of SDF samples, and MJWarp reads it with collision_sdf.py::sample_volume_sdf (no user
code, so no registration is needed and this runs in-process). The cube sits on a plane with a
known overlap of 1 mm. The SDF path reports dist = max(A, B) at the point where the descent
stops, so a flat overlap of depth h gives at best -h/2 (here -0.0005), not -h.
For each setting we call mjw.collision once and print the number of contacts (every starting
point that ends in contact writes its own contact), the min and mean distance, and how much of
the 0.2 x 0.2 m bottom face the contacts cover. Both options are plain kernel inputs, so
changing them between calls does not recompile anything.
Run: python ex7_sdf_iterations.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

CUBE = "-1 -1 -1  1 -1 -1  1 1 -1  -1 1 -1  -1 -1 1  1 -1 1  1 1 1  -1 1 1"
XML = f"""
<mujoco model="sdf_cube_on_plane">
  <asset><mesh name="cube" vertex="{CUBE}" scale=".1 .1 .1"/></asset>
  <worldbody>
    <geom name="floor" type="plane" size="1 1 .1"/>
    <body name="cube" pos="0.013 -0.021 0.099" euler="0 0 17"><freejoint/>
      <geom name="cube" type="sdf" mesh="cube"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(XML)
print(f"geom types {[mujoco.mjtGeom(t).name for t in mjm.geom_type]}, mesh_octadr "
      f"{mjm.mesh_octadr.tolist()}, octree nodes {mjm.noct}")
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=256, njmax=1024)
mjw.kinematics(m, d)

rows = []
print(" initpoints  iterations  nacon   min dist   mean dist   face coverage (x, y extent)")
for initpoints, iterations in [(1, 10), (5, 10), (10, 10), (40, 10), (100, 10),
                               (40, 0), (40, 1), (40, 3), (40, 30)]:
    m.opt.sdf_initpoints = initpoints
    m.opt.sdf_iterations = iterations
    mjw.collision(m, d)
    wp.synchronize()
    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    dist = d.contact.dist.numpy()[:n]
    pos = d.contact.pos.numpy()[:n]
    ext = np.ptp(pos[:, :2], axis=0) if n else np.zeros(2)
    dmin = float(dist.min()) if n else float("nan")
    dmean = float(dist.mean()) if n else float("nan")
    print(f" {initpoints:10d}  {iterations:10d}  {n:5d}   {dmin:+.5f}   {dmean:+.5f}    {ext}")
    rows.append({"initpoints": initpoints, "iterations": iterations, "nacon": n,
                 "min": round(dmin, 5), "mean": round(dmean, 5),
                 "xy": pos[:, :2].astype(float).round(4).tolist()})
print("overlap 0.00100 -> best possible max(A, B) = -0.00050; overflow:",
      "none" if not d.overflow.numpy().any() else d.overflow.numpy())
mjd = mujoco.MjData(mjm)
mujoco.mj_forward(mjm, mjd)
print(f"MuJoCo C, same pose: ncon {mjd.ncon}, min dist {min(c.dist for c in mjd.contact):+.5f} "
      "(C uses a different collider for plane-SDF)")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"rows": rows, "half": 0.1, "yaw_deg": 17, "center": [0.013, -0.021]}, f,
                  separators=(",", ":"))
    print("wrote", args.dump_json)
