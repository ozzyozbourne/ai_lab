"""Example 10.1 - which Model fields can differ per world? List every "*"-batched field.

put_model marks every array whose type spec starts with "*" (Model) or "nworld" (Data) with
arr._is_batched = True (warp_util.mark_batched). Those are the fields you may give one row per
world. Everything else (topology, ids, sizes, discrete options) is shared by all worlds.
Run: python ex1_list_batchable.py [--dump-json PATH]
"""
import argparse
import collections
import dataclasses
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

# any model works; the humanoid has bodies, joints, actuators, cameras and lights
path = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
mjm = mujoco.MjModel.from_xml_path(str(path))
m = mjw.put_model(mjm)

batched, shared = [], []
for f in dataclasses.fields(m):
    arr = getattr(m, f.name)
    if isinstance(arr, wp.array):
        (batched if getattr(arr, "_is_batched", False) else shared).append(f.name)
opt_batched = [f.name for f in dataclasses.fields(m.opt)
               if getattr(getattr(m.opt, f.name), "_is_batched", False)]

groups = collections.defaultdict(list)
for name in batched:
    groups[name.split("_")[0]].append(name)

print(f"Model arrays: {len(batched)} batched ('*'), {len(shared)} shared")
for prefix, names in sorted(groups.items(), key=lambda kv: -len(kv[1])):
    print(f"  {prefix:9s} {len(names):3d}  e.g. {', '.join(names[:3])}")
print(f"m.opt batched arrays ({len(opt_batched)}):", ", ".join(opt_batched))
print("every batched array starts with batch size 1:",
      all(getattr(m, n).shape[0] == 1 for n in batched))
print("some shared arrays:", ", ".join(n for n in ["geom_type", "body_parentid", "jnt_type",
                                                    "dof_jntid", "geom_bodyid"] if n in shared))
print("plain ints in m.opt (one value for all worlds):",
      {k: int(getattr(m.opt, k)) for k in ["integrator", "cone", "solver", "iterations",
                                            "ls_iterations"]})

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"groups": {k: v for k, v in sorted(groups.items())}, "opt": opt_batched,
                   "nbatched": len(batched), "nshared": len(shared)}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
