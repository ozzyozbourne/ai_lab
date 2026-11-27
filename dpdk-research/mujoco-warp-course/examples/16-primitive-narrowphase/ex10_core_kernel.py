"""Example 16.10 - call MJWarp's pure sphere_sphere collider from your own Warp kernel.

collision_primitive_core.py holds the geometry of every primitive collider as plain @wp.func
functions with no Model/Data arguments. They are private API (they may change), but they are
ordinary Warp functions, so any kernel can call them. Here one thread tests one random sphere
pair; we check the result against NumPy and time the kernel.
Run: python ex10_core_kernel.py
"""
import time

import mujoco  # noqa: F401  (course import order)
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw  # noqa: F401
from mujoco_warp._src.collision_primitive_core import sphere_sphere   # private API

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NPAIR = 1_000_000 if ON_GPU else 100_000
NREP = 20


@wp.kernel
def sphere_pairs(p1: wp.array(dtype=wp.vec3), r1: wp.array(dtype=float),
                 p2: wp.array(dtype=wp.vec3), r2: wp.array(dtype=float),
                 dist_out: wp.array(dtype=float), pos_out: wp.array(dtype=wp.vec3),
                 normal_out: wp.array(dtype=wp.vec3), ntouch: wp.array(dtype=int)):
    i = wp.tid()
    dist, pos, n = sphere_sphere(p1[i], r1[i], p2[i], r2[i])
    dist_out[i] = dist
    pos_out[i] = pos
    normal_out[i] = n
    if dist < 0.0:
        wp.atomic_add(ntouch, 0, 1)          # count overlapping pairs


rng = np.random.default_rng(0)
P1 = rng.uniform(-1, 1, (NPAIR, 3)).astype(np.float32)
P2 = (P1 + rng.normal(0, 0.15, (NPAIR, 3))).astype(np.float32)
R1 = rng.uniform(0.02, 0.1, NPAIR).astype(np.float32)
R2 = rng.uniform(0.02, 0.1, NPAIR).astype(np.float32)

p1, p2 = wp.array(P1, dtype=wp.vec3), wp.array(P2, dtype=wp.vec3)
r1, r2 = wp.array(R1, dtype=float), wp.array(R2, dtype=float)
dist = wp.empty(NPAIR, dtype=float)
pos = wp.empty(NPAIR, dtype=wp.vec3)
normal = wp.empty(NPAIR, dtype=wp.vec3)
ntouch = wp.zeros(1, dtype=int)
inputs = [p1, r1, p2, r2]
outputs = [dist, pos, normal, ntouch]

wp.launch(sphere_pairs, dim=NPAIR, inputs=inputs, outputs=outputs)     # JIT compile + warm-up
wp.synchronize()
t0 = time.perf_counter()
for _ in range(NREP):
    ntouch.zero_()
    wp.launch(sphere_pairs, dim=NPAIR, inputs=inputs, outputs=outputs)
wp.synchronize()
dt = (time.perf_counter() - t0) / NREP

# NumPy reference: dist = |p2 - p1| - (r1 + r2), pos = p1 + n (r1 + dist / 2)
v = P2 - P1
L = np.linalg.norm(v, axis=1)
n_ref = v / L[:, None]
d_ref = L - (R1 + R2)
pos_ref = P1 + n_ref * (R1 + 0.5 * d_ref)[:, None]

print(f"device: {wp.get_device()}  pairs: {NPAIR}")
print("first 3 dist  :", dist.numpy()[:3])
print("NumPy  dist   :", d_ref[:3])
print("first pos     :", pos.numpy()[0], " normal:", normal.numpy()[0])
print(f"max |dist err| = {np.abs(dist.numpy() - d_ref).max():.2e}, "
      f"max |pos err| = {np.abs(pos.numpy() - pos_ref).max():.2e}")
print(f"overlapping pairs: {ntouch.numpy()[0]} (NumPy: {int((d_ref < 0).sum())})")
label = "GPU" if ON_GPU else "CPU (not a GPU number)"
print(f"{label}: {dt * 1e3:.2f} ms per launch, {NPAIR / dt / 1e6:.1f} M pairs/s")
