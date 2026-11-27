"""Example 17.10 - a non-convex mesh collides as its convex hull.

The support function of a mesh (collision_gjk.py::support, MESH branch) returns the vertex
with the largest dot(v, dir): that is the support function of the CONVEX HULL of the
vertices, so GJK/EPA only ever see the hull. An L-shaped block (seen from above) has a notch;
a ball dropped into the notch should fall to the floor, but in MJWarp (and MuJoCo C) it rests on
the invisible hull lid at the block's top height. We print the ball height over time and the
expected heights for "hull" and "true L shape".
Run: python ex10_nonconvex_mesh.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4

S, T, H = 0.4, 0.12, 0.1      # L arm length, arm width, block height
L2D = [(0, 0), (S, 0), (S, T), (T, T), (T, S), (0, S)]   # L footprint, notch at (S, S)
VERT = " ".join(f"{x} {y} {z}" for z in (0.0, H) for x, y in L2D)
R = 0.05
NOTCH = (0.2, 0.2)            # inside the hull (x + y < S + T), outside the L

L_MESH = f"""
<mujoco model="l_block">
  <option timestep="0.002"/>
  <asset><mesh name="L" vertex="{VERT}"/></asset>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="2 2 .1"/>
    <geom name="L" type="mesh" mesh="L"/>
    <body name="ball" pos="{NOTCH[0]} {NOTCH[1]} 0.35"><freejoint/>
      <geom name="ball" type="sphere" size="{R}"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(L_MESH)
print(f"mesh: {mjm.mesh_vertnum[0]} vertices; MuJoCo stores the convex hull as the collision "
      f"graph (mesh_graphadr = {mjm.mesh_graphadr[0]})")
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
lz = mjm.geom_pos[1][2]                        # MuJoCo re-centres the mesh at its centroid
top = lz + H / 2
print(f"block top at z = {top:.4f}; ball centre would rest at {top + R:.4f} on the hull lid "
      f"and at {R:.4f} on the floor of a truly L-shaped block")
for step in range(500):
    mjw.step(m, d)
    if step % 100 == 99:
        z = d.qpos.numpy()[:, 2]
        print(f"t = {(step + 1) * mjm.opt.timestep:.1f} s  ball z (all worlds) = {z.round(4)}")
n = min(int(d.nacon.numpy()[0]), d.naconmax)
pairs = {tuple(int(g) for g in gp) for gp in d.contact.geom.numpy()[:n]}
names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(mjm.ngeom)]
print("touching pairs:", sorted(f"{names[a]}-{names[b]}" for a, b in pairs))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
