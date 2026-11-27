"""Example 9.3 - which geom is geom[0], and which way the normal points.

The XML lists the ball BEFORE the plane, and a box (id 2) BEFORE the pebble (id 3) that rests
on it. Neither XML order nor geom id decides: MJWarp stores the lower GeomType first
(PLANE=0 < SPHERE=2 < BOX=6), and frame[0] (the normal) points from geom[0] to geom[1].
Run: python ex3_normal_direction.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

ORDER_SCENE = """
<mujoco model="normal_order">
  <worldbody>
    <body name="ball" pos="0 0 0.099"><freejoint/>
      <geom name="ball" type="sphere" size="0.1"/></body>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="crate" pos="1 0 0.099"><freejoint/>
      <geom name="crate" type="box" size="0.1 0.1 0.1"/></body>
    <body name="pebble" pos="1 0 0.2485"><freejoint/>
      <geom name="pebble" type="sphere" size="0.05"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(ORDER_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=16, njmax=64)
mjw.forward(m, d)

names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(mjm.ngeom)]
print("geom ids after compiling (world-body geoms first):", names)
print("GeomType per geom: ", [mjw.GeomType(int(t)).name for t in mjm.geom_type])

n = min(int(d.nacon.numpy()[0]), d.naconmax)
geom = d.contact.geom.numpy()[:n]
normal = d.contact.frame.numpy()[:n, 0]
dist = d.contact.dist.numpy()[:n]
seen = set()
for i in range(n):
    g0, g1 = geom[i]
    if (g0, g1) in seen:            # the box-plane pair has 4 contacts; print one per pair
        continue
    seen.add((g0, g1))
    print(f"geom[0] = {names[g0]:6s} ({mjw.GeomType(int(mjm.geom_type[g0])).name:6s})  "
          f"geom[1] = {names[g1]:6s} ({mjw.GeomType(int(mjm.geom_type[g1])).name:6s})  "
          f"normal = {normal[i]}  dist = {dist[i]:.4f}")
print("rule: normal points from geom[0] to geom[1]; push geom[1] along +normal to separate")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
