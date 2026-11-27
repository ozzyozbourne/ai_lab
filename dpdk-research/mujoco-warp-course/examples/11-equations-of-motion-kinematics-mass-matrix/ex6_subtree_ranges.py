"""Example 11.6 - subtree centers of mass from contiguous body ranges.

MuJoCo numbers bodies so that every parent comes before its children (depth-first order). Then the
subtree of body b is exactly the index range [b, b + body_subtreenum[b]). smooth.py::_subtree_com
uses this: one thread per (world, body) sums mass * xipos over its range, no per-level launches.
The world body (0) is summed separately from the tree roots (_subtree_com_world).
We redo the sum in NumPy from d.xipos and compare with mjw.com_pos.
Run: python ex6_subtree_ranges.py [--dump-json PATH]
"""
import argparse
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
NWORLD = 4096 if ON_GPU else 8

HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
mjm = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)

rng = np.random.default_rng(3)
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 7:] = rng.uniform(-1, 1, (NWORLD, mjm.nq - 7))
d.qpos.assign(qpos.astype(np.float32))
mjw.kinematics(m, d)
mjw.com_pos(m, d)               # subtree_com, cinert, cdof

subtreenum = m.body_subtreenum.numpy()
mass = mjm.body_mass
xipos = d.xipos.numpy()                     # (nworld, nbody, 3)
ours = np.zeros_like(xipos)
for b in range(1, mjm.nbody):
    rng_b = slice(b, b + subtreenum[b])     # the contiguous subtree range
    ours[:, b] = (mass[rng_b, None] * xipos[:, rng_b]).sum(1) / mass[rng_b].sum()
roots = [b for b in range(1, mjm.nbody) if mjm.body_parentid[b] == 0]
ours[:, 0] = sum(mjm.body_subtreemass[r] * ours[:, r] for r in roots) / mjm.body_subtreemass[0]

got = d.subtree_com.numpy()
print("body_subtreenum:", subtreenum.tolist())
print("tree roots (children of the world body):", roots)
print("subtree ranges:", {b: (b, int(b + subtreenum[b])) for b in (1, 3, 5, 11)})
print("world 0 subtree_com[1] (whole humanoid):", got[0, 1])
print("NumPy contiguous-range sum           :", ours[0, 1])
print(f"max |NumPy - mjw.com_pos| over {NWORLD} worlds x {mjm.nbody} bodies: "
      f"{np.abs(ours - got).max():.2e}")
print("body_subtreemass (Model constant, set at compile):", np.round(mjm.body_subtreemass[:6], 3))

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"names": [mjm.body(i).name for i in range(mjm.nbody)],
                   "parent": mjm.body_parentid.tolist(), "subtreenum": subtreenum.tolist(),
                   "mass": [round(float(x), 3) for x in mass],
                   "subtreemass": [round(float(x), 3) for x in mjm.body_subtreemass]},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
