"""Example 11.1 - derive M(q) and c(q, qdot) of the double pendulum by hand (Lagrange) in NumPy.

The PENDULUM model (shared model M2) is a planar 2-link arm: two hinges about +y, two capsules of
mass 1 and length 0.5. From the Lagrangian L = T - V we get the manipulator equation
    M(q) qacc + c(q, qdot) = tau
with c = Coriolis/centrifugal terms + gravity. We build M and c from the link masses, com offsets
and inertias that MuJoCo compiled, then compare with mujoco.mj_fullM and mjData.qfrc_bias at three
random states. This example uses only MuJoCo C (float64), so the errors are at round-off level.
Run: python ex1_two_link_numpy.py
"""
import mujoco
import numpy as np

np.set_printoptions(precision=4, suppress=True)

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

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
mjd = mujoco.MjData(mjm)

# --- link parameters, read from the compiled model --------------------------------------
m1, m2 = mjm.body_mass[1], mjm.body_mass[2]
lc1, lc2 = -mjm.body_ipos[1, 2], -mjm.body_ipos[2, 2]     # com distance from each hinge
l1 = -mjm.body_pos[2, 2]                                     # hinge1 -> hinge2 distance


def inertia_about_y(b):
    """Moment of inertia of body b about the y axis through its com."""
    R = np.zeros(9)
    mujoco.mju_quat2Mat(R, mjm.body_iquat[b])
    R = R.reshape(3, 3)
    return (R @ np.diag(mjm.body_inertia[b]) @ R.T)[1, 1]


I1, I2 = inertia_about_y(1), inertia_about_y(2)
g = -mjm.opt.gravity[2]
print(f"m = ({m1:.3f}, {m2:.3f})  lc = ({lc1:.3f}, {lc2:.3f})  l1 = {l1:.3f}  "
      f"I_yy = ({I1:.6f}, {I2:.6f})")


def mass_matrix(q):
    """M(q) from T = 0.5 qdot^T M qdot (planar 2-link, hinges about the same axis)."""
    c2 = np.cos(q[1])
    a = I1 + I2 + m1 * lc1**2 + m2 * (l1**2 + lc2**2 + 2 * l1 * lc2 * c2)
    b = I2 + m2 * (lc2**2 + l1 * lc2 * c2)
    d = I2 + m2 * lc2**2
    return np.array([[a, b], [b, d]])


def bias(q, qd):
    """c(q, qdot) = Christoffel terms (Coriolis + centrifugal) + dV/dq (gravity)."""
    s2 = np.sin(q[1])
    # dM/dq2 (M does not depend on q1)
    dM = np.array([[-2 * m2 * l1 * lc2 * s2, -m2 * l1 * lc2 * s2],
                   [-m2 * l1 * lc2 * s2, 0.0]])
    dMdq = [np.zeros((2, 2)), dM]
    cor = np.zeros(2)
    for i in range(2):
        for j in range(2):
            for k in range(2):
                cor[i] += (dMdq[k][i, j] - 0.5 * dMdq[i][j, k]) * qd[j] * qd[k]
    # V = sum m g z with z1 = -lc1 cos q1, z2 = -l1 cos q1 - lc2 cos(q1 + q2) (+ const)
    grav = np.array([m1 * g * lc1 * np.sin(q[0]) + m2 * g * (l1 * np.sin(q[0])
                                                              + lc2 * np.sin(q[0] + q[1])),
                     m2 * g * lc2 * np.sin(q[0] + q[1])])
    return cor + grav


rng = np.random.default_rng(0)
full = np.zeros((mjm.nv, mjm.nv))
err_M, err_c = 0.0, 0.0
for trial in range(3):
    mjd.qpos[:] = rng.uniform(-np.pi, np.pi, 2)
    mjd.qvel[:] = rng.uniform(-3, 3, 2)
    mujoco.mj_forward(mjm, mjd)
    mujoco.mj_fullM(mjm, mjd, full)   # MuJoCo 4 signature: (m, d, dst)
    M_hand = mass_matrix(mjd.qpos)
    c_hand = bias(mjd.qpos, mjd.qvel)
    err_M = max(err_M, np.abs(M_hand - full).max())
    err_c = max(err_c, np.abs(c_hand - mjd.qfrc_bias).max())
    print(f"state {trial}: q = {mjd.qpos}, qdot = {mjd.qvel}")
    print("  M (hand)      =", M_hand.ravel(), "\n  M (mj_fullM)  =", full.ravel())
    print("  c (hand)      =", c_hand, "\n  c (qfrc_bias) =", mjd.qfrc_bias)
print(f"max |M_hand - mj_fullM| = {err_M:.2e}")
print(f"max |c_hand - qfrc_bias| = {err_c:.2e}")
