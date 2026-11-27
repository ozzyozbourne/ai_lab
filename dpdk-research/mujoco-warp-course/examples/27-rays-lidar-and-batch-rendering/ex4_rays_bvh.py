"""Example 27.4 - the same lidar, accelerated by the render context's scene BVH (rc=).

Without rc, mjw.rays launches the tiled kernel ray.py::_ray: each ray's block strides over
ALL geoms and reduces with wp.tile_argmin, so the cost per ray grows with ngeom. With
rc = mjw.create_render_context(...), ray.py::_ray_bvh walks the world-grouped BVH from
rc.group_root[worldid] and tests only the geoms whose boxes the ray enters.
The scene has 4 walls and NPILLAR random pillars. Timings are for THIS device; on a CPU they
are CPU numbers, not GPU numbers.
Run: python ex4_rays_bvh.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import vec6     # private API: the geomgroup mask type

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NRAY = 360
NPILLAR = 400 if ON_GPU else 200
NREP = 20 if ON_GPU else 3


def pillar_room(n, seed=0):
    rng = np.random.default_rng(seed)
    xy = rng.uniform(-1.8, 1.8, (n, 2))
    xy = xy[np.linalg.norm(xy, axis=1) > 0.5]            # keep the robot's spot free
    pillars = "".join(f'<geom type="cylinder" pos="{x:.3f} {y:.3f} .3" size=".03 .3"/>'
                      for x, y in xy)
    walls = "".join(f'<geom type="box" pos="{px} {py} .5" size="{sx} {sy} .5"/>'
                    for px, py, sx, sy in [(2, 0, .05, 2), (-2, 0, .05, 2),
                                           (0, 2, 2, .05), (0, -2, 2, .05)])
    return (f'<mujoco><worldbody><geom name="floor" type="plane" size="3 3 .1"/>{walls}{pillars}'
            f'<body name="robot" pos="0 0 .15"><freejoint/>'
            f'<geom type="cylinder" size=".15 .15"/></body></worldbody></mujoco>')


mjm = mujoco.MjModel.from_xml_string(pillar_room(NPILLAR))
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
robot = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "robot")
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 0] = np.linspace(-0.3, 0.3, NWORLD)              # each world's robot a bit further east
d.qpos.assign(qpos.astype(np.float32))
mjw.kinematics(m, d)

# the BVH lives in a render context; this model has no camera, so nothing is rendered
rc = mjw.create_render_context(mjm, nworld=NWORLD)
mjw.refit_bvh(m, d, rc)          # built from qpos0: refit to the current poses first
print(f"ngeom {mjm.ngeom} | bvh_ngeom {rc.bvh_ngeom} | BVH boxes {rc.lower.shape[0]}"
      f" (= nworld x bvh_ngeom) | nrender {rc.nrender}")
print("group_root (one BVH node per world):", rc.group_root.numpy()[:4])

ang = np.radians(np.arange(NRAY))
origin = d.xpos.numpy()[:, robot]                        # setup only: host copy is fine here
pnt = wp.array(np.repeat(origin[:, None, :], NRAY, 1), dtype=wp.vec3)
vec = wp.array(np.tile(np.stack([np.cos(ang), np.sin(ang), 0 * ang], 1), (NWORLD, 1, 1)),
               dtype=wp.vec3)
excl = wp.full(NRAY, robot, dtype=int)
allgroups = vec6(-1, -1, -1, -1, -1, -1)
out = {}
for label, ctx in (("brute force (rc=None)", None), ("scene BVH (rc=rc)", rc)):
    dist = wp.zeros((NWORLD, NRAY), dtype=float)
    gid = wp.zeros((NWORLD, NRAY), dtype=int)
    nrm = wp.zeros((NWORLD, NRAY), dtype=wp.vec3)
    mjw.rays(m, d, pnt, vec, allgroups, True, excl, dist, gid, nrm, rc=ctx)   # warm-up (JIT)
    wp.synchronize()
    t0 = time.perf_counter()
    for _ in range(NREP):
        mjw.rays(m, d, pnt, vec, allgroups, True, excl, dist, gid, nrm, rc=ctx)
    wp.synchronize()
    dt = (time.perf_counter() - t0) / NREP
    out[label] = (dist.numpy(), gid.numpy())
    print(f"{label:22s} {dt * 1e3:8.2f} ms per call  {NWORLD * NRAY / dt / 1e6:7.3f} Mrays/s"
          f"  [{wp.get_device()}]")
(d0, g0), (d1, g1) = out.values()
print("same geom hit on every ray:", bool((g0 == g1).all()),
      "| max |dist difference|:", float(np.abs(d0 - d1).max()))
print("world 0 min range:", round(float(d1[0][d1[0] > 0].min()), 3), "m")
