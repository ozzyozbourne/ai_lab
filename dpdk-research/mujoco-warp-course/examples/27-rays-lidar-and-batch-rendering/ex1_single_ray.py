"""Example 27.1 - one ray per world with mjw.ray, and bodyexclude.

A ray from (2, 0, 2) straight down hits the top of a cylinder (top at z = 0.6), so dist = 1.4.
With bodyexclude = the cylinder's body the same ray passes through it and hits the floor
(dist = 2.0). A second call gives every world its own ray origin (pnt shape (nworld, 1)).
Run: python ex1_single_ray.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

RAY_SCENE = """
<mujoco model="ray_scene">
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="post" pos="2 0 0.3">
      <geom name="post" type="cylinder" size=".2 .3" rgba=".3 .6 .9 1"/>
    </body>
    <body name="ball" pos="0 0 0.5"><freejoint/>
      <geom name="ball" type="sphere" size=".25" rgba=".9 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4

mjm = mujoco.MjModel.from_xml_string(RAY_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
mjw.kinematics(m, d)          # rays read d.geom_xpos / d.geom_xmat: compute poses first

# 1. the same ray for every world: shape (1, 1) is broadcast over worlds (worldid % 1)
pnt = wp.array([[wp.vec3(2.0, 0.0, 2.0)]], dtype=wp.vec3)
vec = wp.array([[wp.vec3(0.0, 0.0, -1.0)]], dtype=wp.vec3)   # unit length: dist is in metres
dist, geomid, normal = mjw.ray(m, d, pnt, vec)
gname = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, int(geomid.numpy()[0, 0]))
print("output shapes:", dist.shape, geomid.shape, normal.shape)
print(f"hit {gname!r}: dist = {dist.numpy()[0, 0]:.4f}, normal = {normal.numpy()[0, 0]}")

post = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "post")
dist, geomid, normal = mjw.ray(m, d, pnt, vec, bodyexclude=post)
gname = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, int(geomid.numpy()[0, 0]))
print(f"bodyexclude=post (body {post}): hit {gname!r}, dist = {dist.numpy()[0, 0]:.4f}")

# 2. one origin per world: shape (nworld, 1); world k starts at x = 2 - (2/3)(k % 4)
x = 2.0 - (2.0 / 3.0) * (np.arange(NWORLD) % 4)
pnt_w = wp.array(np.stack([x, np.zeros(NWORLD), np.full(NWORLD, 2.0)], 1)[:, None, :],
                 dtype=wp.vec3)
vec_w = wp.array(np.tile([0.0, 0.0, -1.0], (NWORLD, 1, 1)), dtype=wp.vec3)
dist, geomid, _ = mjw.ray(m, d, pnt_w, vec_w)
for w in range(min(NWORLD, 4)):
    g = int(geomid.numpy()[w, 0])
    name = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) if g >= 0 else "miss"
    print(f"world {w}: origin x = {x[w]:+.1f} -> {name:5s} dist = {dist.numpy()[w, 0]:.4f}")

# 3. a ray that misses everything: dist = -1, geomid = -1
dist, geomid, _ = mjw.ray(m, d, pnt, wp.array([[wp.vec3(0.0, 0.0, 1.0)]], dtype=wp.vec3))
print("upward ray:", "dist =", dist.numpy()[0, 0], "geomid =", geomid.numpy()[0, 0])
