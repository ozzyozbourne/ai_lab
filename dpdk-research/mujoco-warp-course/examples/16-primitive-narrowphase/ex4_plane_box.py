"""Example 16.4 - plane-box: 8 corners in, only the ones within margin + gap come out.

plane_box (collision_primitive_core.py) returns the signed distance of all 8 box corners.
plane_box_wrapper calls write_contact once per corner with id_ = corner index, and write_contact
keeps a corner only if dist < margin + gap. So contact.geomcollisionid tells you WHICH corner.
A flat resting box gives 4 contacts, a box tilted about one edge gives 2, a box balanced on a
corner gives 1.
Run: python ex4_plane_box.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BOX_ON_PLANE = """
<mujoco model="plane_box">
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="box" pos="0 0 0.5">
      <freejoint/>
      <geom name="box" type="box" size="0.1 0.1 0.1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

HALF = 0.1
DEPTH = 0.001          # the lowest corner penetrates the floor by 1 mm in every world


def quat_axis_angle(axis, deg):
    axis = np.asarray(axis, float) / np.linalg.norm(axis)
    a = np.radians(deg) / 2
    return np.concatenate([[np.cos(a)], np.sin(a) * axis])


def corners_local():
    # same corner numbering as plane_box: bit 0 -> x, bit 1 -> y, bit 2 -> z
    return np.array([[HALF if i & 1 else -HALF, HALF if i & 2 else -HALF,
                      HALF if i & 4 else -HALF] for i in range(8)])


CASES = [("flat", [1, 0, 0], 0.0),
         ("tilt 10 deg about x (edge)", [1, 0, 0], 10.0),
         ("tilt 50 deg about (1,-1,0) (corner)", [1, -1, 0], 50.0)]
NWORLD = len(CASES)

mjm = mujoco.MjModel.from_xml_string(BOX_ON_PLANE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)

qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float64)
for w, (_, axis, deg) in enumerate(CASES):
    q = quat_axis_angle(axis, deg)
    rot = np.zeros(9)
    mujoco.mju_quat2Mat(rot, q)
    zc = (corners_local() @ rot.reshape(3, 3).T)[:, 2]
    qpos[w, 2] = -zc.min() - DEPTH        # lift so the lowest corner is 1 mm deep
    qpos[w, 3:7] = q
d.qpos.assign(qpos.astype(np.float32))
mjw.kinematics(m, d)
mjw.collision(m, d)

n = min(int(d.nacon.numpy()[0]), d.naconmax)
wid = d.contact.worldid.numpy()[:n]
gcid = d.contact.geomcollisionid.numpy()[:n]
dist = d.contact.dist.numpy()[:n]
xpos = d.geom_xpos.numpy()
xmat = d.geom_xmat.numpy()

out = []
for w, (name, _, _) in enumerate(CASES):
    # what plane_box computes for all 8 corners (plane normal +z through the origin)
    corner_z = (corners_local() @ xmat[w, 1].T + xpos[w, 1])[:, 2]
    sel = np.where(wid == w)[0]
    sel = sel[np.argsort(gcid[sel])]
    print(f"w{w} {name}")
    print("    corner dist (all 8):", np.round(corner_z, 4))
    print(f"    contacts written: {len(sel)}  geomcollisionid = {gcid[sel].tolist()}"
          f"  dist = {dist[sel]}")
    out.append({"name": name, "corner_dist": [round(float(v), 4) for v in corner_z],
                "gcid": gcid[sel].tolist()})
print("rule: corner i is kept when dist_i < margin + gap (= 0 here); 'resting' needs dist < 0")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"worlds": out}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
