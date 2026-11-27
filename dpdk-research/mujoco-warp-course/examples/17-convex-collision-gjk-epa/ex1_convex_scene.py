"""Example 17.1 - three convex pairs that no closed-form collider handles.

A cylinder, an ellipsoid and a hexagonal-prism mesh each rest on their own fixed box. In
MJ_COLLISION_TABLE all three pairs (cylinder-box, ellipsoid-box, box-mesh) are CONVEX, so
collision_convex.py::convex_narrowphase builds one GJK/EPA kernel per pair type. We print the
path of every pair, the contacts per pair at t = 0 and after 0.4 s of simulation, and nacon.
Run: python ex1_convex_scene.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.collision_driver import MJ_COLLISION_TABLE  # private API

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 200

# hexagonal prism: 12 vertices (>= 10, so support() hill-climbs the mesh graph)
HEX = " ".join(f"{0.05 * np.cos(a):.5f} {0.05 * np.sin(a):.5f} {z}"
               for z in (-0.03, 0.03) for a in np.arange(6) * np.pi / 3)

CONVEX_SCENE = f"""
<mujoco model="convex_scene">
  <option timestep="0.002"/>
  <asset><mesh name="hexprism" vertex="{HEX}"/></asset>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="2 2 .1"/>
    <geom name="table_cyl" type="box" pos="-0.4 0 0.05" size="0.1 0.1 0.05"/>
    <geom name="table_ell" type="box" pos="0 0 0.05" size="0.1 0.1 0.05"/>
    <geom name="table_mesh" type="box" pos="0.4 0 0.05" size="0.1 0.1 0.05"/>
    <body name="cyl" pos="-0.4 0 0.149"><freejoint/>
      <geom name="cyl" type="cylinder" size="0.05 0.05"/></body>
    <body name="ell" pos="0 0 0.129"><freejoint/>
      <geom name="ell" type="ellipsoid" size="0.06 0.04 0.03"/></body>
    <body name="hex" pos="0.4 0 0.129"><freejoint/>
      <geom name="hex" type="mesh" mesh="hexprism"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(CONVEX_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=24, njmax=96)
names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(mjm.ngeom)]

print("pair path in MJ_COLLISION_TABLE:")
for a, b in [("cyl", "table_cyl"), ("ell", "table_ell"), ("hex", "table_mesh")]:
    t1, t2 = sorted([mjw.GeomType(mjm.geom_type[names.index(a)]),
                     mjw.GeomType(mjm.geom_type[names.index(b)])])
    print(f"  {a:4s} vs {b:10s}: ({t1.name}, {t2.name}) -> {MJ_COLLISION_TABLE[(t1, t2)].name}")


def per_pair(d):
    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    geom = d.contact.geom.numpy()[:n]
    wid = d.contact.worldid.numpy()[:n]
    dist = d.contact.dist.numpy()[:n]
    out = {}
    for (g1, g2), w, dd in zip(geom, wid, dist):
        if w != 0:
            continue
        key = f"{names[g1]}-{names[g2]}"
        out.setdefault(key, []).append(round(float(dd), 4))
    return n, out


mjw.kinematics(m, d)
mjw.collision(m, d)
n0, pairs0 = per_pair(d)
print("t = 0.0 s, world 0 contacts per pair (geom[0]-geom[1]: dist list):")
for k, v in sorted(pairs0.items()):
    print(f"  {k:16s} {len(v)} contacts  dist = {v}")
print(f"nacon over {NWORLD} worlds = {n0}")

for _ in range(NSTEP):
    mjw.step(m, d)
wp.synchronize()
n1, pairs1 = per_pair(d)
print(f"t = {NSTEP * mjm.opt.timestep:.1f} s, world 0 contacts per pair:")
for k, v in sorted(pairs1.items()):
    print(f"  {k:16s} {len(v)} contacts")
print(f"nacon over {NWORLD} worlds = {n1}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
