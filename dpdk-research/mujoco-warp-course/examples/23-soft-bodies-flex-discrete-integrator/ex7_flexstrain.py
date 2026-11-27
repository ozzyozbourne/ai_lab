"""Example 23.7 - FLEXSTRAIN equality rows of an interpolated (trilinear) flex, in the efc strip.

Loads mujoco_warp/test_data/flex/moving_base_strain.xml: a 4x4x4 soft cube with dof="trilinear"
(its vertices follow 8 corner nodes) hangs under a box on a vertical slide joint and is held
in shape by <edge equality="strain"/>, which compiles to one FLEXSTRAIN equality per cell (this cube has a single cell).
We kick one corner node sideways, step, and print the equality types and where their rows sit
in d.efc (Ch 19 layout), plus how hard the strain rows push back.
Run: python ex7_flexstrain.py [--dump-json PATH]
"""
import argparse
import collections
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
NSTEP = 50
C = mujoco.mjtConstraint          # same values as MJWarp's types.ConstraintType

PATH = epath.resource_path("mujoco_warp") / "test_data/flex/moving_base_strain.xml"
mjm = mujoco.MjModel.from_xml_path(str(PATH))
print(f"nflex {mjm.nflex}  flex_interp {mjm.flex_interp} (1 = trilinear)  "
      f"cells {mjm.flex_cellnum[0]}  nodes {mjm.flex_nodenum[0]}  vertices {mjm.nflexvert}")
print(f"nv {mjm.nv} (slide 1 + 7 free nodes x 3: node 0 is pinned to the base)")
print(f"neq {mjm.neq}  eq_type {[mujoco.mjtEq(t).name for t in mjm.eq_type]}  "
      f"flex_edgeequality {mjm.flex_edgeequality} (3 = strain)")

m = mjw.put_model(mjm)
print(f"m.eq_flexstrain_adr {m.eq_flexstrain_adr.numpy()}  m.neq_flexstrain {m.neq_flexstrain}")
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
qvel = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
qvel[:, -3] = 0.5                         # last free node: 0.5 m/s along x (a shear kick)
d.qvel.assign(qvel)
for _ in range(NSTEP):
    mjw.step(m, d)
wp.synchronize()

nefc = d.nefc.numpy()
types = d.efc.type.numpy()[0, : nefc[0]]
ids = d.efc.id.numpy()[0, : nefc[0]]
print(f"nefc per world {nefc}  (njmax {d.njmax})")
runs = []
for t, i in zip(types, ids):
    if runs and runs[-1][0] == t and runs[-1][1] == i:
        runs[-1][2] += 1
    else:
        runs.append([t, i, 1])
for t, i, n in runs:
    print(f"  {n:3d} rows  {C(t).name[8:]:16s} id {i}")
pos = d.efc.pos.numpy()[0, : nefc[0]]
force = d.efc.force.numpy()[0, : nefc[0]]
eq = types == C.mjCNSTR_EQUALITY
print(f"strain rows: |pos| max {np.abs(pos[eq]).max():.2e}  "
      f"|force| max {np.abs(force[eq]).max():.4f}  "
      f"({eq.sum()} = 3 x 8 node DOFs - 6 rigid-body modes)")
print(f"base slide qpos {d.qpos.numpy()[0, 0]:.4f}  cube lowest vertex z "
      f"{d.flexvert_xpos.numpy()[0, :, 2].min():.4f}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    rows = [[C(t).name[8:], int(i), int(n)] for t, i, n in runs]
    with open(args.dump_json, "w") as f:
        json.dump({"njmax": d.njmax, "nefc": int(nefc[0]), "runs": rows}, f)
    print("wrote", args.dump_json)
