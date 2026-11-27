"""Example 11.4 - the humanoid body tree as branches (one kinematics thread per branch).

put_model splits the body tree into root-to-leaf branches (io.py: one branch per leaf body).
smooth.py::kinematics launches _kinematics_branch with dim=(nworld, m.nbranch); each thread walks
body_branches[body_branch_start[b]:body_branch_start[b + 1]] from root to leaf. Shared prefixes
(the torso) are recomputed in every branch. We also print body_subtreenum, the length of each
body's contiguous subtree range, and the level-by-level alternative (m.body_tree).
Run: python ex4_branches.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
mjm = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
m = mjw.put_model(mjm)

names = [mjm.body(i).name for i in range(mjm.nbody)]
branches_flat = m.body_branches.numpy()
start = m.body_branch_start.numpy()
subtreenum = m.body_subtreenum.numpy()
branches = [branches_flat[start[b]:start[b + 1]].tolist() for b in range(m.nbranch)]

print(f"nbody = {mjm.nbody}, nv = {mjm.nv}, nbranch = {m.nbranch}")
print("body_branch_start =", start.tolist())
for b, br in enumerate(branches):
    print(f"  branch {b}: {br}  ({' > '.join(names[i] for i in br)})")
work = sum(len(br) for br in branches)
print(f"body visits by the branch walk: {work} for {mjm.nbody - 1} bodies "
      f"({work - (mjm.nbody - 1)} redundant, the torso alone {sum(1 in br for br in branches)}x)")
print("body_subtreenum =", subtreenum.tolist())
print("subtree of body 3 (waist_lower) = range", (3, 3 + int(subtreenum[3])),
      "->", [names[i] for i in range(3, 3 + int(subtreenum[3]))])
levels = [lvl.numpy().tolist() for lvl in m.body_tree]
print(f"level-by-level alternative: {len(levels)} levels (one launch + barrier each):", levels)

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"names": names, "parent": mjm.body_parentid.tolist(), "branches": branches,
                   "subtreenum": subtreenum.tolist(), "levels": levels,
                   "mass": [round(float(x), 3) for x in mjm.body_mass]}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
