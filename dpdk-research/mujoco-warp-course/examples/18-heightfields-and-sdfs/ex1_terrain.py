"""Example 18.1 - the TERRAIN scene: which collision path makes each contact.

TERRAIN (course model M7) has a 5 x 5 heightfield and four free bodies: a sphere, an ellipsoid,
a cylinder and a tetrahedron mesh. We step 2 worlds for 100 steps and then sort every contact
by the body it touches and by the narrowphase path that produced it. Every geom here collides
with the hfield, so every contact comes from the HFIELD prism kernel
(collision_convex.py::ccd_hfield_kernel_builder), even for the sphere.
Run: python ex1_terrain.py
"""
import collections

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.collision_driver import MJ_COLLISION_TABLE  # private API

np.set_printoptions(precision=4, suppress=True)

TERRAIN = """
<mujoco model="terrain">
  <option timestep="0.005"/>
  <asset>
    <hfield name="bumps" nrow="5" ncol="5" size="1 1 .2 .1"
      elevation="0 0 0 0 0  0 .5 1 .5 0  0 1 0 1 0  0 .5 1 .5 0  0 0 0 0 0"/>
    <mesh name="tetra" vertex="0 0 0  .2 0 0  0 .2 0  0 0 .2"/>
  </asset>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="ground" type="hfield" hfield="bumps"/>
    <body name="ball" pos="0.2 0.1 .6"><freejoint/><geom type="sphere" size=".08"/></body>
    <body name="ellipsoid" pos="-0.3 0.2 .6"><freejoint/>
      <geom type="ellipsoid" size=".1 .07 .05"/></body>
    <body name="cyl" pos="0.3 -0.3 .6"><freejoint/><geom type="cylinder" size=".06 .05"/></body>
    <body name="tetra" pos="-0.3 -0.3 .6"><freejoint/><geom type="mesh" mesh="tetra"/></body>
  </worldbody>
</mujoco>
"""

NWORLD = 2
NSTEP = 100
G = mjw.GeomType


def collision_path(t1, t2):
    """Name the narrowphase path for a (lower type, higher type) geom pair."""
    if G.HFIELD in (t1, t2):
        return "HFIELD (prisms + GJK/EPA)"
    if G.SDF in (t1, t2):
        return "SDF (gradient descent)"
    return MJ_COLLISION_TABLE[(t1, t2)].name


mjm = mujoco.MjModel.from_xml_string(TERRAIN)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
print(f"nq {mjm.nq}  nv {mjm.nv}  ngeom {mjm.ngeom}  nhfield {mjm.nhfield}  "
      f"hfield {mjm.hfield_nrow[0]}x{mjm.hfield_ncol[0]}  size {mjm.hfield_size[0]}")
print(f"naconmax {d.naconmax}  njmax {d.njmax}")

for _ in range(NSTEP):
    mjw.step(m, d)
wp.synchronize()

nacon = min(int(d.nacon.numpy()[0]), d.naconmax)
geom = d.contact.geom.numpy()[:nacon]
world = d.contact.worldid.numpy()[:nacon]
dist = d.contact.dist.numpy()[:nacon]
per_body = collections.Counter()
per_path = collections.Counter()
for (g1, g2), w in zip(geom, world):
    body = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_BODY, int(mjm.geom_bodyid[g2]))
    per_body[(int(w), body)] += 1
    per_path[collision_path(G(int(mjm.geom_type[g1])), G(int(mjm.geom_type[g2])))] += 1

print(f"after {NSTEP} steps: nacon = {nacon} over {NWORLD} worlds")
for (w, body), n in sorted(per_body.items()):
    print(f"  world {w}  {body:10s} {n} contact(s)")
print("contacts per collision path:", dict(per_path))
print("min / max contact dist:", round(float(dist.min()), 4), round(float(dist.max()), 4))
print("body heights world 0 (z):", d.xpos.numpy()[0, 1:, 2])
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
