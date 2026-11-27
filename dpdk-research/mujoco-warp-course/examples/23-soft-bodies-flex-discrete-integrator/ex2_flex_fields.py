"""Example 23.2 - read flex Data: vertex positions, edge lengths and per-edge strain.

A 5x5 cloth (flexcomp type="grid" dim="2") hangs from two pinned corners. It has an elastic
membrane (<elasticity elastic2d="stretch" young=... thickness=...>), so its edges stretch under
gravity. After settling we compare d.flexedge_length with the rest lengths m.flexedge_length0.
Run: python ex2_flex_fields.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
NSTEP = 400

HANGING_CLOTH = """
<mujoco model="hanging_cloth">
  <option timestep="0.002"/>
  <worldbody>
    <flexcomp name="cloth" type="grid" count="5 5 1" spacing=".05 .05 .05" pos="0 0 1"
              radius=".005" dim="2" mass=".05">
      <pin id="20 24"/>
      <elasticity young="5e4" poisson="0.2" thickness="1e-3" elastic2d="stretch"/>
      <contact contype="0" conaffinity="0"/>
    </flexcomp>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(HANGING_CLOTH)
print(f"nflexvert {mjm.nflexvert}  nflexedge {mjm.nflexedge}  nflexelem {mjm.nflexelem} "
      f"(triangles)  nv {mjm.nv}")
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)

print("Model  m.flexedge_length0  ", m.flexedge_length0.shape, m.flexedge_length0.dtype.__name__)
print("Model  m.flex_edge         ", m.flex_edge.shape, m.flex_edge.dtype.__name__)
print("Data   d.flexvert_xpos     ", d.flexvert_xpos.shape, d.flexvert_xpos.dtype.__name__)
print("Data   d.flexedge_length   ", d.flexedge_length.shape, d.flexedge_length.dtype.__name__)
print("Data   d.flexedge_velocity ", d.flexedge_velocity.shape)
print("Data   d.flexedge_J        ", d.flexedge_J.shape, "(sparse rows, m.flexedge_J_rownnz)")

for _ in range(NSTEP):
    mjw.step(m, d)
wp.synchronize()

L0 = m.flexedge_length0.numpy()
L = d.flexedge_length.numpy()[0]
strain = (L - L0) / L0
edges = m.flex_edge.numpy()
order = np.argsort(strain)[::-1]
print(f"after {NSTEP} steps ({NSTEP * mjm.opt.timestep:.1f} s):")
print(f"  rest lengths: {np.unique(np.round(L0, 4))}  (grid edges and diagonals)")
print(f"  strain min {strain.min():+.4f}  mean {strain.mean():+.4f}  max {strain.max():+.4f}")
for e in order[:3]:
    print(f"  most stretched edge {e:2d} verts {edges[e]}  L0 {L0[e]:.4f}  L {L[e]:.4f}  "
          f"strain {strain[e]:+.4f}")
lowest = d.flexvert_xpos.numpy()[0, :, 2].min()
print(f"lowest vertex z {lowest:.4f}  (pinned corners stay at z=1)")
print("finite:", bool(np.isfinite(d.qpos.numpy()).all()))
