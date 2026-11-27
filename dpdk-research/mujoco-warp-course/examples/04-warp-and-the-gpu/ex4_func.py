"""Example 4.4 - @wp.func device functions, reusing MJWarp's own math helpers.

A kernel calls our @wp.func, which calls mujoco_warp._src.math.rot_vec_quat (private API) to
rotate a vec3 by a MuJoCo-ordered (w, x, y, z) quaternion. The result is compared with
mujoco.mju_rotVecQuat, MuJoCo's C function.
Run: python ex4_func.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw  # noqa: F401  (imported for the course-wide import order)
from mujoco_warp._src import math as mjw_math   # private API: names may change

np.set_printoptions(precision=4, suppress=True)


@wp.func
def rotate_and_scale(v: wp.vec3, q: wp.quat, s: float) -> wp.vec3:
    """A device function: called from kernels, inlined by the compiler, may return a value."""
    return s * mjw_math.rot_vec_quat(v, q)


@wp.kernel
def rotate_all(vec_in: wp.array[wp.vec3], quat_in: wp.array[wp.quat],
               vec_out: wp.array[wp.vec3]):
    i = wp.tid()
    vec_out[i] = rotate_and_scale(vec_in[i], quat_in[i], 1.0)


rng = np.random.default_rng(1)
N = 4
quats = rng.standard_normal((N, 4))
quats /= np.linalg.norm(quats, axis=1, keepdims=True)        # unit quats, MuJoCo order (w,x,y,z)
vecs = rng.standard_normal((N, 3))

out = wp.zeros(N, dtype=wp.vec3)
wp.launch(rotate_all, dim=N,
          inputs=[wp.array(vecs, dtype=wp.vec3), wp.array(quats, dtype=wp.quat)],
          outputs=[out])

ref = np.zeros((N, 3))
for i in range(N):
    mujoco.mju_rotVecQuat(ref[i], vecs[i], quats[i])          # C MuJoCo, float64

print("quat[0] (w, x, y, z):", quats[0])
print("MJWarp rot_vec_quat :", out.numpy()[0])
print("mujoco.mju_rotVecQuat:", ref[0])
print("max abs difference over", N, "vectors:", f"{np.max(np.abs(out.numpy() - ref)):.1e}",
      "(float32 vs float64)")
