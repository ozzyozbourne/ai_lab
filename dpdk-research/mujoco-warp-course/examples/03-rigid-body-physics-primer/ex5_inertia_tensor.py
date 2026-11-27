"""Example 3.5 - the inertia tensor of an L-shaped body, by hand, and what MuJoCo stores.

Two boxes form an "L" in the x-z plane. We build the full 3x3 inertia tensor about the combined
centre of mass with the parallel-axis theorem, diagonalize it with NumPy, and compare with
MuJoCo's body_ipos (centre of mass), body_inertia (principal moments) and body_iquat (rotation
from the body frame to the principal axes).
Run: python ex5_inertia_tensor.py
"""
import mujoco
import numpy as np

np.set_printoptions(precision=4, suppress=True)

L_SHAPE = """
<mujoco model="l_shape">
  <worldbody>
    <body name="L" pos="0 0 1">
      <freejoint/>
      <geom name="arm" type="box" pos=".3 0 0"   size=".3 .05 .05" mass="2"/>
      <geom name="leg" type="box" pos=".05 0 .25" size=".05 .05 .2" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""

# (mass, centre in the body frame, half sizes) of each box, copied from the XML above
parts = [(2.0, np.array([0.3, 0.0, 0.0]), np.array([0.3, 0.05, 0.05])),
         (1.0, np.array([0.05, 0.0, 0.25]), np.array([0.05, 0.05, 0.2]))]

mass = sum(p[0] for p in parts)
com = sum(p[0] * p[1] for p in parts) / mass             # mass-weighted mean position

I = np.zeros((3, 3))
for m_i, c_i, h in parts:
    full = 2 * h                                           # full side lengths
    I_own = m_i / 12 * np.diag([full[1]**2 + full[2]**2,   # box about its own centre
                                full[0]**2 + full[2]**2,
                                full[0]**2 + full[1]**2])
    r = c_i - com                                          # parallel-axis theorem:
    I += I_own + m_i * (r @ r * np.eye(3) - np.outer(r, r))  # I_com = I_own + m (|r|^2 E - r r^T)

evals, evecs = np.linalg.eigh(I)                           # symmetric -> real eigen-decomposition
print("mass:", mass, " centre of mass:", com)
print("full inertia tensor about the com (note the off-diagonal I_xz):")
print(I)
print("NumPy principal moments (ascending):", evals)

mjm = mujoco.MjModel.from_xml_string(L_SHAPE)
b = mjm.body("L").id
R = np.zeros(9)
mujoco.mju_quat2Mat(R, mjm.body_iquat[b])
R = R.reshape(3, 3)                                        # columns = principal axes in body frame
print("MuJoCo body_ipos    :", mjm.body_ipos[b])
print("MuJoCo body_inertia :", mjm.body_inertia[b])
print("MuJoCo body_iquat   :", mjm.body_iquat[b])
print("sorted moments match:", np.allclose(np.sort(mjm.body_inertia[b]), evals, atol=1e-6))
I_back = R @ np.diag(mjm.body_inertia[b]) @ R.T              # rotate the diagonal back
print("R diag(body_inertia) R^T equals the hand-built tensor:", np.allclose(I_back, I, atol=1e-6))
# the axis of the smallest moment is the "easy" spin axis; where does it point in the x-z plane?
v_np = evecs[:, 0]
v_mj = R[:, int(np.argmin(mjm.body_inertia[b]))]
ang = lambda v: (np.degrees(np.arctan2(v[2], v[0])) + 90) % 180 - 90   # axis: sign does not matter
print(f"easiest spin axis is tilted from +x by: NumPy {ang(v_np):.2f} deg, "
      f"MuJoCo {ang(v_mj):.2f} deg")
