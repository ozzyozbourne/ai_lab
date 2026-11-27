"""Example 27.3 - what a ray may hit: geomgroup, flg_static, bodyexclude and invisible geoms.

Five horizontal rays (one aimed at each object) are cast with different filters. The filter
rules are ray.py::_ray_eliminate: a geom is skipped if it is on bodyexclude, if its rgba (or
material) alpha is 0, if flg_static=False and its body is welded to the world, or if the
geomgroup mask is not all -1 and the entry for its group is 0.
Run: python ex3_ray_filters.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import vec6     # private API: the geomgroup mask type

FILTER_SCENE = """
<mujoco model="filters">
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1" group="0"/>
    <geom name="wall" type="box" pos="0 3 .5" size="3 .05 .5" group="1"/>
    <body name="crate" pos="-1 1 .2"><freejoint/>
      <geom name="crate" type="box" size=".2 .2 .2" group="2"/></body>
    <body name="probe" pos="0 1 .2"><freejoint/>
      <geom name="probe" type="sphere" size=".15" group="3"/></body>
    <body name="ghost" pos="1 1 .2"><freejoint/>
      <geom name="ghost" type="sphere" size=".15" rgba="1 1 1 0"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(FILTER_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=8, njmax=32)
mjw.kinematics(m, d)

# five rays from y = -1, z = 0.2, pointing +y, at x = -1 (crate), 0 (probe), 1 (ghost), 2, -2
xs = [-1.0, 0.0, 1.0, 2.0, -2.0]
pnt = wp.array([[wp.vec3(x, -1.0, 0.2) for x in xs]], dtype=wp.vec3)
vec = wp.array([[wp.vec3(0.0, 1.0, 0.0)] * len(xs)], dtype=wp.vec3)
dist = wp.zeros((1, len(xs)), dtype=float)
geomid = wp.zeros((1, len(xs)), dtype=int)
normal = wp.zeros((1, len(xs)), dtype=wp.vec3)


def cast(label, geomgroup, flg_static, bodyexclude):
    mjw.rays(m, d, pnt, vec, geomgroup, flg_static, wp.array(bodyexclude, dtype=int),
             dist, geomid, normal)
    names = []
    for g, r in zip(geomid.numpy()[0], dist.numpy()[0]):
        name = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, int(g))
        names.append(f"{name}@{r:.2f}" if g >= 0 else "miss")
    print(f"{label:34s}", "  ".join(f"{n:11s}" for n in names))


print("geom groups:", dict(zip([mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, i)
                                for i in range(mjm.ngeom)], mjm.geom_group.tolist())))
print(f"{'ray x =':34s}", "  ".join(f"{x:<11.1f}" for x in xs))
NONE = [-1] * len(xs)
cast("all groups, static on", vec6(-1, -1, -1, -1, -1, -1), True, NONE)
cast("geomgroup excludes group 1 (wall)", vec6(1, 0, 1, 1, 1, 1), True, NONE)
cast("only group 3 (probe)", vec6(0, 0, 0, 1, 0, 0), True, NONE)
cast("flg_static=False", vec6(-1, -1, -1, -1, -1, -1), False, NONE)
crate = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "crate")
cast("bodyexclude crate on ray 0 only", vec6(-1, -1, -1, -1, -1, -1), True,
     [crate, -1, -1, -1, -1])
print("body_weldid (0 = welded to world):", mjm.body_weldid.tolist())
