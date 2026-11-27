"""Example 23.1 - a 1-D flex: two pinned ropes from the shipped test model rope.xml.

Loads mujoco_warp/test_data/flex/rope.xml (two 12-vertex ropes made with flexcomp dim="1",
vertex 0 of each pinned, edge equality constraints), prints the flex sizes and follows the
free tip of rope 1 for 100 steps in NWORLD worlds.
Run: python ex1_rope.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 100

ROPE_PATH = epath.resource_path("mujoco_warp") / "test_data/flex/rope.xml"
mjm = mujoco.MjModel.from_xml_path(str(ROPE_PATH))
print(f"nflex {mjm.nflex}  nflexvert {mjm.nflexvert}  nflexedge {mjm.nflexedge}  "
      f"nflexelem {mjm.nflexelem}  flex_dim {mjm.flex_dim}")
print(f"nbody {mjm.nbody}  nv {mjm.nv}  neq {mjm.neq}  "
      f"(22 unpinned vertices x 3 slide DOFs = {22 * 3})")
print("flex_vertadr", mjm.flex_vertadr, " flex_vertnum", mjm.flex_vertnum)

m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)          # io.py defaults: no contacts here (contype=0)
tip = int(mjm.flex_vertadr[0] + mjm.flex_vertnum[0] - 1)   # last vertex of rope 1
mjw.forward(m, d)                               # fills flexvert_xpos before the first step

for i in range(NSTEP + 1):
    if i % 20 == 0:
        p = d.flexvert_xpos.numpy()[0, tip]      # demo only: reads to host every 20 steps
        print(f"step {i:3d}  t={i * mjm.opt.timestep:.3f}s  rope-1 tip xyz {p}")
    if i < NSTEP:
        mjw.step(m, d)
wp.synchronize()

z = d.flexvert_xpos.numpy()[:, tip, 2]
print("tip z in every world:", z)
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
