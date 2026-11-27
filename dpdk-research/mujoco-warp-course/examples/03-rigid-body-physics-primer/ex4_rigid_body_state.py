"""Example 3.4 - the state of one free rigid body: 7 numbers of position, 6 of velocity.

A free box of full side lengths 0.2 x 0.4 x 0.6 m and mass 3 kg. We print nq, nv, the unit
quaternion qpos[3:7], the angular velocity qvel[3:6], and the mass properties MuJoCo computed,
and check body_inertia against the textbook box formula I_xx = m (b^2 + c^2) / 12.
Run: python ex4_rigid_body_state.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

FREE_BOX = """
<mujoco model="free_box">
  <option timestep="0.002" gravity="0 0 0"/>
  <worldbody>
    <body name="box" pos="0 0 1">
      <freejoint/>
      <geom type="box" size=".1 .2 .3" mass="3"/>
    </body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(FREE_BOX)
mjd = mujoco.MjData(mjm)
mjd.qvel[:] = [0.5, 0.0, 0.0, 0.0, 0.0, 2.0]      # 0.5 m/s along x, 2 rad/s about the body z axis
for _ in range(500):                              # 1 s
    mujoco.mj_step(mjm, mjd)

print("nq =", mjm.nq, " nv =", mjm.nv, " (free joint: 3 position + 4 quaternion, 3 + 3 velocity)")
print("qpos[0:3] position   :", mjd.qpos[0:3])
print("qpos[3:7] quaternion :", mjd.qpos[3:7],
      " |q| =", round(float(np.linalg.norm(mjd.qpos[3:7])), 6))
print("qvel[0:3] linear vel :", mjd.qvel[0:3])
print("qvel[3:6] angular vel:", mjd.qvel[3:6])
angle = 2 * np.arccos(mjd.qpos[3])
print(f"rotation angle from quat = {angle:.4f} rad (expected 2 rad/s * 1 s = 2.0)")

body = 1                                           # body 0 is the world
a, b, c = 0.2, 0.4, 0.6                           # full side lengths
m_box = 3.0
I_formula = m_box / 12 * np.array([b**2 + c**2, a**2 + c**2, a**2 + b**2])
print("body_mass   :", mjm.body_mass[body])
print("body_inertia:", mjm.body_inertia[body], " (principal moments, diagonal)")
print("formula     :", I_formula)
print("body_iquat  :", mjm.body_iquat[body], " (principal axes = body axes here)")
print("body_ipos   :", mjm.body_ipos[body], " (centre of mass in the body frame)")

# The same constants on the device: mjw.put_model copies them into Warp arrays.
# Shape (1, nbody) of vec3: the leading 1 is a batch axis that domain randomization grows (Ch 10).
m = mjw.put_model(mjm)
print("MJWarp m.body_inertia: shape", m.body_inertia.shape, "dtype", m.body_inertia.dtype.__name__,
      "| body 1:", m.body_inertia.numpy()[0, body])
