"""Example 11.7 - cdof is the Jacobian, one column per dof, in the com frame.

A planar 3-link hinge arm. For a hinge, smooth.py::_cdof writes
    cdof = (axis, axis x (c - xanchor))          c = subtree_com[root]
i.e. the spatial velocity (in the com frame) produced by qdot_j = 1. The Jacobian of a point p
on body b is then, for every dof j that is an ancestor of b:
    jacr[:, j] = cdof_ang,   jacp[:, j] = cdof_lin + cdof_ang x (p - c)
(support.py::jac_dof). We rebuild mj_jacBody's jacp/jacr for every body from cdof.
Run: python ex7_cdof_vs_jac.py [--dump-json PATH]
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

ARM3 = """
<mujoco model="arm3">
  <worldbody>
    <body name="l1" pos="0 0 0">
      <joint name="j1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .4 0 0" size=".03" mass="1"/>
      <body name="l2" pos=".4 0 0">
        <joint name="j2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 .3 0 0" size=".03" mass=".7"/>
        <body name="l3" pos=".3 0 0">
          <joint name="j3" type="hinge" axis="0 1 0"/>
          <geom type="capsule" fromto="0 0 0 .2 0 0" size=".03" mass=".4"/>
          <site name="hand" pos=".2 0 0"/>
        </body>
      </body>
    </body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(ARM3)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
q = np.array([0.5, -0.8, 0.9])
d.qpos.assign(q[None].astype(np.float32))
mjw.kinematics(m, d)
mjw.com_pos(m, d)

cdof = d.cdof.numpy()[0]                   # (nv, 6)
c = d.subtree_com.numpy()[0, 1]            # com frame origin (root of this tree: body 1)
xpos = d.xpos.numpy()[0]
print("com frame origin c =", c)
print("cdof rows (angular | linear):")
for j in range(mjm.nv):
    print(f"  dof {j}: {cdof[j, :3]} | {cdof[j, 3:]}")

mjd = mujoco.MjData(mjm)
mjd.qpos[:] = q
mujoco.mj_kinematics(mjm, mjd)
mujoco.mj_comPos(mjm, mjd)
jacp_c, jacr_c = np.zeros((3, mjm.nv)), np.zeros((3, mjm.nv))
worst = 0.0
for b in range(1, mjm.nbody):
    mujoco.mj_jacBody(mjm, mjd, jacp_c, jacr_c, b)
    jacp, jacr = np.zeros((3, mjm.nv)), np.zeros((3, mjm.nv))
    for j in range(mjm.nv):
        if mjm.dof_bodyid[j] <= b:          # in this chain: dof j is an ancestor of body b
            jacr[:, j] = cdof[j, :3]
            jacp[:, j] = cdof[j, 3:] + np.cross(cdof[j, :3], xpos[b] - c)
    worst = max(worst, np.abs(jacp - jacp_c).max(), np.abs(jacr - jacr_c).max())
    if b == 3:
        print("jacp of body l3 from cdof:\n", jacp, "\nmj_jacBody:\n", jacp_c)
print(f"max |jac from cdof - mj_jacBody| over all bodies: {worst:.2e}")

if args.dump_json:
    r4 = lambda a: np.round(np.asarray(a, dtype=float), 4).tolist()   # float64 for clean JSON
    out = {"xpos": r4(xpos), "xanchor": r4(d.xanchor.numpy()[0]),
           "site": r4(d.site_xpos.numpy()[0, 0]), "c": r4(c), "cdof": r4(cdof), "q": q.tolist()}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
