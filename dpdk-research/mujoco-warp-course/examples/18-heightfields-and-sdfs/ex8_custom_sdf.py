"""Example 18.8 - write your own analytic SDF and patch it in, the way register_sdf_plugins does.

Fresh process: the patch must happen before the first MJWarp collision kernel compiles in this
process (in a notebook: !python ex8_custom_sdf.py).

The shape is a "rounded tile": a flat square of half-size R (the core box has half-sizes
(R, R, 0)) inflated by a rounding radius r. Its bounding box, (R + r, R + r, r), is exactly the
bounding box of a torus with radius1 = R and radius2 = r, so we reuse the attribute layout of
the mujoco.sdf.torus plugin: attr[0] = R, attr[1] = r. MuJoCo C (and its visual mesh) still
see a torus; only MJWarp, through our patched user_sdf / user_sdf_grad, sees the tile.
We drop a ball on the centre: on a torus it falls through the hole, on the tile it rests at
z = r + ball radius.
Run: python ex8_custom_sdf.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import vec_pluginattr  # private API

np.set_printoptions(precision=4, suppress=True)

# 1. The plugin type id of mujoco.sdf.torus in this process (what geom -> m.plugin stores).
_probe = mujoco.MjModel.from_xml_string("""<mujoco><extension>
  <plugin plugin="mujoco.sdf.torus"><instance name="t"/></plugin></extension>
  <asset><mesh name="tm"><plugin instance="t"/></mesh></asset>
  <worldbody><geom type="sdf" mesh="tm"><plugin instance="t"/></geom></worldbody></mujoco>""")
TORUS_ID = int(_probe.plugin[0])


# 2. The analytic SDF as a @wp.func pair (value, gradient).
@wp.func
def rounded_tile(p: wp.vec3, attr: vec_pluginattr) -> float:
    q = wp.vec3(wp.abs(p[0]) - attr[0], wp.abs(p[1]) - attr[0], wp.abs(p[2]))
    outside = wp.length(wp.max(q, wp.vec3(0.0)))
    inside = wp.min(wp.max(q[0], wp.max(q[1], q[2])), 0.0)
    return outside + inside - attr[1]


@wp.func
def rounded_tile_grad(p: wp.vec3, attr: vec_pluginattr) -> wp.vec3:
    q = wp.vec3(wp.abs(p[0]) - attr[0], wp.abs(p[1]) - attr[0], wp.abs(p[2]))
    g = wp.max(q, wp.vec3(0.0))
    g = wp.vec3(g[0] * wp.sign(p[0]), g[1] * wp.sign(p[1]), g[2] * wp.sign(p[2]))
    if wp.length(g) < 1e-9:                     # on the core square itself
        return wp.vec3(0.0, 0.0, 1.0)
    return wp.normalize(g)


# 3. Dispatchers with the placeholder signatures, specialised on the plugin id with wp.static.
@wp.func
def user_sdf(p: wp.vec3, attr: vec_pluginattr, sdf_type: int) -> float:
    if sdf_type == wp.static(TORUS_ID):
        return rounded_tile(p, attr)
    return 0.0


@wp.func
def user_sdf_grad(p: wp.vec3, attr: vec_pluginattr, sdf_type: int) -> wp.vec3:
    if sdf_type == wp.static(TORUS_ID):
        return rounded_tile_grad(p, attr)
    return wp.vec3(0.0)


# 4. Patch BEFORE any put_model / forward / step (same two assignments as register_sdf_plugins).
mjw._src.collision_sdf.user_sdf = user_sdf
mjw._src.collision_sdf.user_sdf_grad = user_sdf_grad

R, r, BALL = 0.2, 0.03, 0.05
XML = f"""
<mujoco model="custom_sdf">
  <extension><plugin plugin="mujoco.sdf.torus"><instance name="tile">
    <config key="radius1" value="{R}"/><config key="radius2" value="{r}"/>
  </instance></plugin></extension>
  <asset><mesh name="tile"><plugin instance="tile"/></mesh></asset>
  <option timestep="0.002" sdf_iterations="10" sdf_initpoints="40"/>
  <worldbody>
    <geom name="floor" type="plane" size="1 1 .1" pos="0 0 -0.3"/>
    <body name="tile" pos="0 0 0"><geom name="tile" type="sdf" mesh="tile">
      <plugin instance="tile"/></geom></body>
    <body name="ball" pos="0 0 {r + BALL + 0.02}"><freejoint/>
      <geom name="ball" type="sphere" size="{BALL}"/></body>
  </worldbody>
</mujoco>
"""
mjm = mujoco.MjModel.from_xml_string(XML)
print(f"torus plugin type id {TORUS_ID}; tile attrs R={R}, r={r}; geom_aabb half-size of tile "
      f"{mjm.geom_aabb[1, 3:]}")
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=64, njmax=256)
mjd = mujoco.MjData(mjm)
for _ in range(400):                       # 0.8 s
    mjw.step(m, d)
    mujoco.mj_step(mjm, mjd)
wp.synchronize()
nacon = min(int(d.nacon.numpy()[0]), d.naconmax)
dist = d.contact.dist.numpy()[:nacon]
nrm = d.contact.frame.numpy()[:nacon, 0]
print(f"MJWarp (patched tile): ball z = {float(d.qpos.numpy()[0, 2]):.4f}  "
      f"(expected r + radius = {r + BALL:.4f}), nacon {nacon}")
print(f"  contact dist min {dist.min():+.5f}, mean normal {nrm.mean(0)}")
print(f"MuJoCo C (real torus):  ball z = {mjd.qpos[2]:.4f}  (fell through the hole to the floor)")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
