"""Example 16.2 - plane-sphere: contact.dist and contact.pos against the closed-form formula.

A sphere of radius r sits above a tilted plane at a different height in every world. The
primitive collider plane_sphere computes
    dist = dot(c - p, n) - r          (signed gap between the surfaces, negative = overlap)
    pos  = c - n * (r + dist / 2)     (the MIDPOINT between the two surfaces)
We recompute both in NumPy and compare with what MJWarp wrote into d.contact.
Run: python ex2_plane_sphere.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

PLANE_SPHERE = """
<mujoco model="plane_sphere">
  <worldbody>
    <geom name="ramp" type="plane" size="5 5 .1" zaxis="0.3 0 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size="0.1" margin="0.2"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

HEIGHTS = np.array([0.05, 0.08, 0.10, 0.12, 0.16, 0.25], dtype=np.float32)  # sphere centre z
NWORLD = len(HEIGHTS)                    # one world per height (same on CPU and GPU)

mjm = mujoco.MjModel.from_xml_string(PLANE_SPHERE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)

qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qpos[:, 2] = HEIGHTS
d.qpos.assign(qpos)
mjw.kinematics(m, d)                     # geom_xpos / geom_xmat for every world
mjw.collision(m, d)                      # broadphase + narrowphase

n = min(int(d.nacon.numpy()[0]), d.naconmax)
wid = d.contact.worldid.numpy()[:n]
dist = d.contact.dist.numpy()[:n]
pos = d.contact.pos.numpy()[:n]
normal = d.contact.frame.numpy()[:n, 0]
order = np.argsort(wid)                  # pool order is arbitrary on a GPU; sort by world

n_plane = np.array([0.3, 0.0, 1.0]) / np.linalg.norm([0.3, 0.0, 1.0])
r = 0.1
print(f"plane normal n = {n_plane}, sphere radius r = {r}, margin = 0.2")
print("world  centre_z   dist(MJWarp)  dist(formula)  pos(MJWarp)                 |pos err|")
max_err = 0.0
rows = []
for i in order:
    c = np.array([0.0, 0.0, HEIGHTS[wid[i]]])
    dist_ref = c @ n_plane - r
    pos_ref = c - n_plane * (r + 0.5 * dist_ref)
    err = max(abs(dist[i] - dist_ref), np.abs(pos[i] - pos_ref).max())
    max_err = max(max_err, err)
    rows.append({"z": float(HEIGHTS[wid[i]]), "dist": round(float(dist[i]), 5),
                 "pos": [round(float(v), 5) for v in pos[i]]})
    print(f"  w{wid[i]}   {HEIGHTS[wid[i]]:.3f}     {dist[i]: .5f}      {dist_ref: .5f}     "
          f"{pos[i]}   {np.abs(pos[i] - pos_ref).max():.1e}")
print("normal of every contact (frame[0]) equals the plane normal:",
      bool(np.allclose(normal, n_plane, atol=1e-6)))
print(f"max |MJWarp - formula| = {max_err:.2e}  (float32)")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"normal": [round(float(v), 5) for v in n_plane], "r": r, "rows": rows}, f,
                  separators=(",", ":"))
    print("wrote", args.dump_json)
