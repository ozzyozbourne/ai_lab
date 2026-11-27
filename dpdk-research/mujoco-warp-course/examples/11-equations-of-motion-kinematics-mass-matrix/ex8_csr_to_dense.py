"""Example 11.8 - read MJWarp's CSR mass matrix d.M and turn it into a dense matrix.

d.M has shape (nworld, nC). Row i of the lower triangle stores the entries M[i, j] for the dofs j
that are ancestors of dof i (and i itself, last): M_rowadr[i] is where the row starts, M_rownnz[i]
how many entries it has, M_colind[adr] the column of each entry (these three live on mjModel).
We densify the PENDULUM at qpos0 and compare with mujoco.mj_fullM, then print the sparsity of the
HUMANOID (nC = 243 of 27 x 27 = 729 entries).
Run: python ex8_csr_to_dense.py [--dump-json PATH]
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

def csr_to_dense(mjm, values):
    """Symmetric dense M from the CSR lower triangle of one world."""
    M = np.zeros((mjm.nv, mjm.nv))
    for i in range(mjm.nv):
        for k in range(mjm.M_rownnz[i]):
            adr = mjm.M_rowadr[i] + k
            j = mjm.M_colind[adr]
            M[i, j] = M[j, i] = values[adr]
    return M


mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
mjw.fwd_position(m, d)                       # kinematics, com_pos, crb -> d.M (and factor_m)

print("nv =", mjm.nv, " nC =", mjm.nC)
print("M_rownnz =", mjm.M_rownnz, " M_rowadr =", mjm.M_rowadr, " M_colind =", mjm.M_colind)
print("d.M shape:", d.M.shape, " values [M00, M10, M11] =", d.M.numpy()[0])
dense = csr_to_dense(mjm, d.M.numpy()[0])
mjd = mujoco.MjData(mjm)
mujoco.mj_forward(mjm, mjd)
full = np.zeros((mjm.nv, mjm.nv))
mujoco.mj_fullM(mjm, mjd, full)
print("dense from d.M:\n", dense)
print("mujoco.mj_fullM:\n", full)
print(f"max |dense - mj_fullM| = {np.abs(dense - full).max():.2e}")
# fwd_position(factorize=True) also ran factor_m: the 2x2 block is stored as a packed upper
# Cholesky factor U (M = U^T U), row-major [U00, U01, U10 = 0, U11], at qLD_block_adr[0] = 0
U = d.qLD.numpy()[0].reshape(2, 2)
print("d.qLD[0] =", d.qLD.numpy()[0], " U^T U =", (U.T @ U).ravel())

HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
hum = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
pattern = np.zeros((hum.nv, hum.nv), dtype=int)
for i in range(hum.nv):
    for k in range(hum.M_rownnz[i]):
        j = hum.M_colind[hum.M_rowadr[i] + k]
        pattern[i, j] = pattern[j, i] = 1
print(f"HUMANOID: nv = {hum.nv}, nC = {hum.nC} (lower triangle incl. diagonal), "
      f"dense nonzeros = {pattern.sum()} of {hum.nv * hum.nv}")
print("M_rownnz =", hum.M_rownnz.tolist())

if args.dump_json:
    rows = [[int(j) for j in hum.M_colind[hum.M_rowadr[i]:hum.M_rowadr[i] + hum.M_rownnz[i]]]
            for i in range(hum.nv)]
    dof_body = [hum.body(int(b)).name for b in hum.dof_bodyid]
    with open(args.dump_json, "w") as f:
        json.dump({"nv": int(hum.nv), "nC": int(hum.nC), "rows": rows, "dof_body": dof_body,
                   "pendulum": [round(float(v), 4) for v in d.M.numpy()[0]],
                   "pendulum_qLD": [round(float(v), 4) for v in d.qLD.numpy()[0]]},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
