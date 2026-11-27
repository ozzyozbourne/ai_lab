"""Example 2.6 - quaternions are (w, x, y, z) in MuJoCo, and what goes wrong if you forget.

Builds a free box, sets its orientation to 90 degrees about +z with mju_axisAngle2Quat, runs
mj_forward and reads xquat / xmat. Then it feeds the same four numbers in (x, y, z, w) order to
show the wrong rotation you get, and prints how qpos packs a free joint: 3 position + 4 quat.
Run: python ex6_quaternions.py
"""
import mujoco
import numpy as np

np.set_printoptions(precision=3, suppress=True)

FREE_BOX = """
<mujoco>
  <worldbody>
    <body name="box"><freejoint/><geom type="box" size=".2 .1 .05"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(FREE_BOX)
mjd = mujoco.MjData(mjm)
print("qpos0 of a free joint (x y z | w x y z):", mjm.qpos0)

quat = np.zeros(4)
mujoco.mju_axisAngle2Quat(quat, np.array([0.0, 0.0, 1.0]), np.pi / 2)
print("90 deg about +z as (w, x, y, z):", quat)

mjd.qpos[3:7] = quat           # qpos[0:3] = position, qpos[3:7] = orientation
mujoco.mj_forward(mjm, mjd)
print("xquat of the box:", mjd.xquat[1])
R = mjd.xmat[1].reshape(3, 3)
print("body x axis in world (first column of xmat):", R[:, 0], "-> points along +y")

mat = np.zeros(9)
mujoco.mju_quat2Mat(mat, quat)
print("mju_quat2Mat gives the same matrix:", np.allclose(mat, mjd.xmat[1]))

# Rotate a vector with the quaternion: the body x axis
v = np.zeros(3)
mujoco.mju_rotVecQuat(v, np.array([1.0, 0.0, 0.0]), quat)
print("mju_rotVecQuat([1,0,0]):", v)

# Wrong: someone stored (x, y, z, w), e.g. from scipy's as_quat() default
wrong = np.array([quat[1], quat[2], quat[3], quat[0]])
mujoco.mju_normalize4(wrong)
mujoco.mju_quat2Mat(mat, wrong)
angle = 2 * np.arccos(np.clip(wrong[0], -1, 1))
print("same numbers read as (x,y,z,w) -> w =", round(wrong[0], 3),
      f"angle {np.degrees(angle):.1f} deg about", wrong[1:] / np.linalg.norm(wrong[1:]))
print("wrong matrix maps x to:", mat.reshape(3, 3)[:, 0])

# Two quaternions describe every rotation: q and -q
neg = -quat
mujoco.mju_quat2Mat(mat, neg)
print("-q gives the same rotation:", np.allclose(mat, mjd.xmat[1]))
