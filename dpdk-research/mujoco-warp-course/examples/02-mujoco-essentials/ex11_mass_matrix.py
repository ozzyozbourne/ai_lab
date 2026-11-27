"""Example 2.11 - the joint-space mass matrix M of the double PENDULUM with mujoco.mj_fullM.

MuJoCo stores M in a compact sparse form (MuJoCo 4: the MjData field is M, not qM), and
mj_fullM(m, d, dst) expands it into a dense nv x nv matrix. M depends on the pose: we print it
with the arm straight (hinge2 = 0) and bent (hinge2 = 90 deg). Chapter 11 derives these numbers.
Run: python ex11_mass_matrix.py
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
print("nv =", mjm.nv, "| nM (stored entries) =", mjm.nM, "| MjData has M:", hasattr(mjd, "M"),
      "| has qM:", hasattr(mjd, "qM"))

dense = np.zeros((mjm.nv, mjm.nv))
for q2 in [0.0, np.pi / 2]:
    mjd.qpos[:] = [0.0, q2]
    mujoco.mj_forward(mjm, mjd)          # computes M (via the composite rigid body algorithm)
    mujoco.mj_fullM(mjm, mjd, dense)   # MuJoCo 4 signature: (m, d, dst)
    print(f"hinge2 = {np.degrees(q2):4.0f} deg  M =\n{dense}")
    print("  symmetric:", np.allclose(dense, dense.T),
          "| positive definite:", bool(np.all(np.linalg.eigvalsh(dense) > 0)))

# Kinetic energy = 0.5 * qvel^T M qvel (energy flag is enabled in this model)
mjd.qvel[:] = [1.0, -0.5]
mujoco.mj_forward(mjm, mjd)
mujoco.mj_fullM(mjm, mjd, dense)   # MuJoCo 4 signature: (m, d, dst)
ke = 0.5 * mjd.qvel @ dense @ mjd.qvel
print(f"0.5 v^T M v = {ke:.4f}  | mjd.energy[1] (kinetic) = {mjd.energy[1]:.4f}")
