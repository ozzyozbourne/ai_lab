"""Example 4.5 - the quaternion storage pitfall: wp.quat_rotate expects (x, y, z, w).

MuJoCo and MJWarp store quaternions as (w, x, y, z) inside wp.quat slots. Warp's own built-ins
(wp.quat_rotate, wp.transform, ...) read the same four slots as (x, y, z, w). Passing a
MuJoCo-ordered quaternion straight to wp.quat_rotate silently gives a different rotation.
Run: python ex5_quat_pitfall.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw  # noqa: F401  (imported for the course-wide import order)
from mujoco_warp._src import math as mjw_math   # private API: names may change

np.set_printoptions(precision=4, suppress=True)


@wp.kernel
def three_ways(v: wp.vec3, q_mj: wp.quat, out: wp.array[wp.vec3]):
    # q_mj holds MuJoCo order: q_mj[0] = w, q_mj[1..3] = x, y, z
    out[0] = mjw_math.rot_vec_quat(v, q_mj)                  # MJWarp helper: (w, x, y, z)
    out[1] = wp.quat_rotate(q_mj, v)                         # WRONG: Warp reads (x, y, z, w)
    q_warp = wp.quat(q_mj[1], q_mj[2], q_mj[3], q_mj[0])     # reorder to Warp's (x, y, z, w)
    out[2] = wp.quat_rotate(q_warp, v)                       # right again


# 90 degrees about z, in MuJoCo order (w, x, y, z)
q_mj = np.array([np.cos(np.pi / 4), 0.0, 0.0, np.sin(np.pi / 4)])
v = np.array([1.0, 0.0, 0.0])

out = wp.zeros(3, dtype=wp.vec3)
wp.launch(three_ways, dim=1, inputs=[wp.vec3(*v), wp.quat(*q_mj)], outputs=[out])
ref = np.zeros(3)
mujoco.mju_rotVecQuat(ref, v, q_mj)

r = np.round(out.numpy(), 6) + 0.0                         # tidy -0.0 and 1e-8 noise
print("rotate (1, 0, 0) by 90 deg about z; quat (w, x, y, z) =", q_mj)
print("mujoco.mju_rotVecQuat            :", ref)
print("mjw math.rot_vec_quat (w,x,y,z)  :", r[0])
print("wp.quat_rotate, MuJoCo order     :", r[1], "<- wrong")
print("wp.quat_rotate, reordered x,y,z,w:", r[2])
print("wp.quat_identity() slots         :", np.array(wp.quat_identity()), "(w is LAST in Warp)")
