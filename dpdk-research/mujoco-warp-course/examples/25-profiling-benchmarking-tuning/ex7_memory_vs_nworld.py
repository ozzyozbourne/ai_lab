"""Example 25.7 - memory of mjw.Data versus nworld, and which fields dominate.

We add up the capacity of every wp.array in Model and Data (what testspeed's --memory reports
as "Model memory" and "Data memory"), for the humanoid with nconmax=24, njmax=64. Data grows
linearly with nworld, so we measure small batches, check the line, and extrapolate the table
for 1k..64k worlds. A second line shows how njmax changes the slope.
GPU only: the largest nworld that fits in wp.get_device().total_memory (on CPU that value
is host RAM when psutil is installed, and 0 with a warning otherwise, so we skip it).
Run: python ex7_memory_vs_nworld.py [--dump-json PATH]
"""
import argparse
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

ON_GPU = wp.get_device().is_cuda
MEASURE = [1, 64, 256, 1024] if not ON_GPU else [1, 1024, 8192]


def field_bytes(obj, prefix=""):
    """{field: bytes} for every wp.array in a (nested) dataclass, like testspeed --memory."""
    out = {}
    for f in dataclasses.fields(obj):
        v = getattr(obj, f.name)
        if dataclasses.is_dataclass(v):
            out.update(field_bytes(v, prefix + f.name + "."))
        elif isinstance(v, wp.array):
            out[prefix + f.name] = v.capacity
    return out


def group(name):
    if name.startswith("efc."):
        return "efc (constraints)"
    if name.startswith("contact."):
        return "contact pool"
    if name in ("qM", "M", "qLD", "qLDiagInv", "qH", "qHLD", "qLU", "qLDiagSqrtInv"):
        return "mass/Hessian factors"
    return "everything else"


mjm = mujoco.MjModel.from_xml_path(str(epath.resource_path("mujoco_warp")
                                       / "test_data/humanoid/humanoid.xml"))
model_mb = sum(field_bytes(mjw.put_model(mjm)).values()) / 2**20
print(f"Model memory: {model_mb:.3f} MiB (shared by all worlds)")

sizes = {}
for n in MEASURE:
    d = mjw.make_data(mjm, nworld=n, nconmax=24, njmax=64)
    sizes[n] = field_bytes(d)
    del d
per_world = (sum(sizes[MEASURE[-1]].values()) - sum(sizes[1].values())) / (MEASURE[-1] - 1)
fixed = sum(sizes[1].values()) - per_world
for n in MEASURE:
    pred = fixed + per_world * n
    print(f"  nworld {n:>5}: measured {sum(sizes[n].values()) / 2**20:9.3f} MiB, line "
          f"{pred / 2**20:9.3f} MiB")
print(f"Data = {fixed:.0f} B + {per_world:,.1f} B x nworld (nconmax=24, njmax=64)")

groups = {}
for k, v in sizes[MEASURE[-1]].items():
    groups[group(k)] = groups.get(group(k), 0) + v / MEASURE[-1]
print("per-world bytes by group:",
      {g: round(b) for g, b in sorted(groups.items(), key=lambda x: -x[1])})

d256 = field_bytes(mjw.make_data(mjm, nworld=64, nconmax=24, njmax=256))
pw256 = sum(d256.values()) / 64
print(f"njmax=256 instead of 64: {pw256:,.0f} B per world ({pw256 / per_world:.2f}x)")

print(f"\n{'nworld':>7}{'Data MiB (njmax 64)':>22}{'Data MiB (njmax 256)':>23}")
table = []
for n in [1024, 4096, 8192, 16384, 32768, 65536]:
    a, b = (fixed + per_world * n) / 2**20, pw256 * n / 2**20
    table.append([n, round(a, 1), round(b, 1)])
    print(f"{n:>7}{a:>22.1f}{b:>23.1f}")

if ON_GPU:
    total = wp.get_device().total_memory
    print(f"device total_memory: {total / 2**30:.1f} GiB")
    print(f"max nworld in device memory (Data only, njmax 64): {int(total // per_world):,}")
else:   # on CPU total_memory is host RAM (via psutil; 0 plus a warning without it)
    print("skipped on CPU: no device-memory estimate")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"per_world": round(per_world, 1), "per_world_njmax256": round(pw256, 1),
                   "groups": {g: round(b) for g, b in groups.items()},
                   "groups_njmax256": {
                       g: round(sum(v for k, v in d256.items() if group(k) == g) / 64)
                       for g in groups},
                   "table": table}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
