"""Example 23.4 - a 3-D (volumetric) flex: the shipped Floppy model falls on a cylinder.

Loads mujoco_warp/test_data/flex/floppy.xml: a 24x4x4 vertex block made with flexcomp
dim="3" (tetrahedral elements) and <elasticity young="5e4" poisson="0.2">, above a hinged
cylinder. Prints the element counts and the block's centre height over time.
Run: python ex4_floppy_volumetric.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 1
NSTEP = 2000 if ON_GPU else 600

FLOPPY_PATH = epath.resource_path("mujoco_warp") / "test_data/flex/floppy.xml"
mjm = mujoco.MjModel.from_xml_path(str(FLOPPY_PATH))
f = 0
print(f"flex_dim {mjm.flex_dim[f]}  vertices {mjm.flex_vertnum[f]}  edges {mjm.flex_edgenum[f]}  "
      f"tetrahedra {mjm.flex_elemnum[f]}  nv {mjm.nv}")
print(f"integrator {mjw.IntegratorType(mjm.opt.integrator).name}  "
      f"solver {mjw.SolverType(mjm.opt.solver).name}  dt {mjm.opt.timestep}")
elem = mjm.flex_elem[mjm.flex_elemdataadr[f]: mjm.flex_elemdataadr[f] + 4 * mjm.flex_elemnum[f]]
print("first tetrahedron vertex ids:", elem[:4], "(dim + 1 = 4 per element)")

m = mjw.put_model(mjm)
print(f"nonzeros of the flex stiffness matrix K (m.nefmK, used by DISCRETE): {m.nefmK}")
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=256, njmax=1024)

mjw.step(m, d)                      # first call compiles the kernels
wp.synchronize()
t0 = time.perf_counter()
for i in range(1, NSTEP + 1):
    mjw.step(m, d)
    if i % 100 == 0:                # demo only: host reads every 100 steps
        x = d.flexvert_xpos.numpy()[0]
        print(f"t={(i + 1) * mjm.opt.timestep:.3f}s  centre z {x[:, 2].mean():.4f}  "
              f"min z {x[:, 2].min():.4f}  nacon {int(d.nacon.numpy()[0])}")
wp.synchronize()
dt = time.perf_counter() - t0
print("finite:", bool(np.isfinite(d.qpos.numpy()).all()),
      "| overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
print(f"{NWORLD * NSTEP / dt:.0f} world-steps/s on {wp.get_device()} "
      + ("(GPU numbers)" if ON_GPU else "(CPU numbers are not GPU numbers)"))
