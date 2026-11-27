"""Example 1.7 - which MuJoCo features MJWarp lacks, read from the code itself.

put_model rejects any enum value that the MJWarp enums do not contain, so diffing MuJoCo's
mjt* enums against MJWarp's enums lists the unsupported features.
Run: python ex7_unsupported_enums.py [--dump-json PATH]
  --dump-json PATH writes {enum: {supported: [...], unsupported: [...]}} for the explorer.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import types as mjw_types   # private API: SleepPolicy, EqType are not exported

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

PAIRS = [  # (MuJoCo enum, MJWarp enum) - put_model checks each of these
    ("mjtEnableBit", mjw.EnableBit),
    ("mjtDisableBit", mjw.DisableBit),
    ("mjtDyn", mjw.DynType),
    ("mjtGain", mjw.GainType),
    ("mjtBias", mjw.BiasType),
    ("mjtTrn", mjw.TrnType),
    ("mjtSleepPolicy", mjw_types.SleepPolicy),
    ("mjtIntegrator", mjw.IntegratorType),
    ("mjtSolver", mjw.SolverType),
    ("mjtCone", mjw.ConeType),
    ("mjtEq", mjw_types.EqType),
]


def short(name):
    return name.split("_", 1)[1]           # "mjENBL_ENERGY" -> "ENERGY"


def is_sentinel(name):
    return name.startswith("mjN") or name.endswith("_UNDEFINED")   # counts and markers, not features


report = {}
for mj_name, warp_enum in PAIRS:
    mj_enum = getattr(mujoco, mj_name)
    have = {int(v) for v in warp_enum}
    members = [(n, int(v)) for n, v in mj_enum.__members__.items() if not is_sentinel(n)]
    ok = [short(n) for n, v in members if v in have]
    missing = [short(n) for n, v in members if v not in have]
    report[mj_name] = {"warp": warp_enum.__name__, "supported": ok, "unsupported": missing}
    print(f"{mj_name:15s} -> {warp_enum.__name__:15s} unsupported: {', '.join(missing) or '-'}")

n_bad = sum(len(r["unsupported"]) for r in report.values())
n_all = n_bad + sum(len(r["supported"]) for r in report.values())
print(f"{n_bad} of {n_all} enum members are rejected by put_model")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(report, f, indent=1)
    print("wrote", args.dump_json)
