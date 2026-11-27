"""Example 5.4 - put_data copies a host MjData to the device, and changes the host copy too.

A fresh mujoco.MjData has qpos set but no kinematics. put_data runs mj_kinematics on it (and,
because its mass matrix is still all zero, mj_comPos, mj_camlight, mj_tendon, mj_crb and
mj_factorM), so mjd.xpos and mjd.M are filled afterwards. Then it tiles the state x nworld.
Run: python ex4_put_data_mutates.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
mjd = mujoco.MjData(mjm)
mjd.qvel[0] = 0.5                       # give the ball a sideways push on the host

print("host before put_data: xpos[1] =", mjd.xpos[1], "| M all zero:", not mjd.M.any())
d = mjw.put_data(mjm, mjd, nworld=3, nconmax=4, njmax=16)
print("host after  put_data: xpos[1] =", mjd.xpos[1], "| M all zero:", not mjd.M.any())

print("device qvel (every world got the push):")
print(d.qvel.numpy())
print("device xpos[:, 1] (copied, already filled):", d.xpos.numpy()[:, 1].tolist())
