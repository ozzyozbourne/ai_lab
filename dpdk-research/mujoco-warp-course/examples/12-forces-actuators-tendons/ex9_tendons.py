"""Example 12.9 - tendons: fixed and spatial lengths, the sparse tendon Jacobian, wrapping.

smooth.py::tendon fills d.ten_length (nworld, ntendon) and the tendon Jacobian d.ten_J, stored
sparsely with a pattern fixed at put_model time: row t has m.ten_J_rownnz[t] entries starting at
m.ten_J_rowadr[t], in the dofs m.ten_J_colind[...]; only the values d.ten_J[w, k] change.
  (a) test_data/tendon/fixed.xml: a fixed tendon is a linear combination, L = sum coef_j q_j.
  (b) test_data/tendon/site.xml: spatial tendons through sites, compared with C MuJoCo.
  (c) an elbow: a spatial tendon wraps over a cylinder at the joint (util_misc.wrap). We sweep the
      angle over 31 worlds; once the tendon touches the cylinder its moment arm equals the radius.
Run: python ex9_tendons.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()
TEST = epath.resource_path("mujoco_warp") / "test_data/tendon"


def run_key(path):
    """Load a test model, set keyframe 0, forward in MJWarp and C; return both."""
    mjm = mujoco.MjModel.from_xml_path(str(path))
    md = mujoco.MjData(mjm)
    mujoco.mj_resetDataKeyframe(mjm, md, 0)
    mujoco.mj_forward(mjm, md)
    m = mjw.put_model(mjm)
    d = mjw.put_data(mjm, md, nworld=1)
    mjw.forward(m, d)
    return mjm, md, m, d


def dense_ten_J(m, d, w, ntendon, nv):
    nnz, adr, col = m.ten_J_rownnz.numpy(), m.ten_J_rowadr.numpy(), m.ten_J_colind.numpy()
    J = np.zeros((ntendon, nv))
    for t in range(ntendon):
        J[t, col[adr[t]:adr[t] + nnz[t]]] = d.ten_J.numpy()[w, adr[t]:adr[t] + nnz[t]]
    return J


mjm, md, m, d = run_key(TEST / "fixed.xml")
print("(a) fixed.xml, qpos =", md.qpos, "coef = .25 .5 .75")
print("    ten_length MJWarp", d.ten_length.numpy()[0], "| C", md.ten_length,
      "| by hand", round(.25 * .2 + .5 * .4 + .75 * .6, 4))
print("    ten_J (dense)", dense_ten_J(m, d, 0, mjm.ntendon, mjm.nv)[0],
      "| ten_velocity", d.ten_velocity.numpy()[0], "= J @ qvel")

mjm, md, m, d = run_key(TEST / "site.xml")
print("(b) site.xml: ntendon =", mjm.ntendon, "| ten_J_rownnz =", m.ten_J_rownnz.numpy(),
      "| d.ten_J shape", d.ten_J.shape)
print("    ten_length MJWarp", d.ten_length.numpy()[0])
print("    ten_length C     ", md.ten_length)
Jc = np.zeros((mjm.ntendon, mjm.nv))
mujoco.mju_sparse2dense(Jc, md.ten_J, mjm.ten_J_rownnz, mjm.ten_J_rowadr, mjm.ten_J_colind)
Jw = dense_ten_J(m, d, 0, mjm.ntendon, mjm.nv)
print(f"    max |ten_J MJWarp - C| = {np.abs(Jw - Jc).max():.1e}")

ELBOW = """
<mujoco model="elbow">
  <compiler angle="radian"/>
  <option gravity="0 0 0"/>
  <worldbody>
    <site name="origin" pos="-.3 0 .12"/>
    <geom name="pulley" type="cylinder" size=".06 .05" quat="0.7071068 0.7071068 0 0"
          contype="0" conaffinity="0"/>
    <site name="side" pos="0 0 .2"/>
    <body name="forearm">
      <joint name="elbow" type="hinge" axis="0 1 0" range="-2 2"/>
      <geom type="capsule" fromto="0 0 0 .4 0 0" size=".02" contype="0" conaffinity="0"/>
      <site name="insert" pos=".25 0 .03"/>
    </body>
  </worldbody>
  <tendon>
    <spatial name="flexor">
      <site site="origin"/>
      <geom geom="pulley" sidesite="side"/>
      <site site="insert"/>
    </spatial>
  </tendon>
</mujoco>
"""
mjm = mujoco.MjModel.from_xml_string(ELBOW)
m = mjw.put_model(mjm)
ang = np.linspace(-1.5, 1.5, 31)
d = mjw.make_data(mjm, nworld=len(ang))
d.qpos.assign(ang[:, None].astype(np.float32))
mjw.forward(m, d)
L = d.ten_length.numpy()[:, 0]
J = d.ten_J.numpy()[:, 0]                    # one tendon, one dof: J = dL/dq
wrapnum = d.ten_wrapnum.numpy()[:, 0]
path = d.wrap_xpos.numpy().reshape(len(ang), -1, 3)   # 2 points per wrap object, flattened
print("(c) elbow over a cylinder of radius 0.06, angle sweep over 31 worlds")
for i in (0, 10, 15, 20, 30):
    print(f"    angle {ang[i]:+.2f}: ten_length {L[i]:.4f}  ten_J {J[i]:+.4f}  "
          f"path points {wrapnum[i]} ({'wrapped' if wrapnum[i] == 4 else 'straight'})")
fd = np.gradient(L, ang)
print(f"    max |ten_J - dL/dq (finite diff)| away from the touch point = "
      f"{np.abs(J - fd)[(wrapnum == 4) & (np.roll(wrapnum, 1) == 4)][1:-1].max():.4f}")

if args.dump_json:
    out = {"angle": [round(float(x), 4) for x in ang], "length": [round(float(x), 4) for x in L],
           "J": [round(float(x), 4) for x in J], "wrapnum": wrapnum.tolist(),
           "path": [[[round(float(p[0]), 4), round(float(p[2]), 4)] for p in path[i, :wrapnum[i]]]
                    for i in range(len(ang))],
           "radius": 0.06}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
