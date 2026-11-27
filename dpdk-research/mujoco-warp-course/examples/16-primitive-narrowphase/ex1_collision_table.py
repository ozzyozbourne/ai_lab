"""Example 16.1 - the collision dispatch table, read from MJWarp itself.

Prints MJ_COLLISION_TABLE as a GeomType x GeomType grid (P = PRIMITIVE, C = CONVEX, . = never
collides), the function that handles each cell, the flex table, and what DisableBit.NATIVECCD
does to box-box. Nothing here is hand-typed: every cell comes from the library's own dicts.
Run: python ex1_collision_table.py [--dump-json PATH]
  --dump-json PATH writes the grid (both NATIVECCD settings + flex row) for the page's heatmap.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.collision_driver import MJ_COLLISION_TABLE      # private API
from mujoco_warp._src.collision_driver import MJ_FLEX_COLLISION_TABLE  # private API
from mujoco_warp._src.collision_primitive import _PRIMITIVE_COLLISIONS  # private API

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

G = mjw.GeomType
RIGID = [G.PLANE, G.HFIELD, G.SPHERE, G.CAPSULE, G.ELLIPSOID, G.CYLINDER, G.BOX, G.MESH]
SHORT = {G.PLANE: "plane", G.HFIELD: "hfield", G.SPHERE: "sphere", G.CAPSULE: "capsule",
         G.ELLIPSOID: "ellips", G.CYLINDER: "cylind", G.BOX: "box", G.MESH: "mesh",
         G.FLEX: "flex"}


def table_for(nativeccd_disabled):
    """Same logic as collision_driver._narrowphase: copy the table, flip BOX-BOX if disabled."""
    table = dict(MJ_COLLISION_TABLE)
    if nativeccd_disabled:
        table[(G.BOX, G.BOX)] = type(table[(G.BOX, G.BOX)]).PRIMITIVE
    return table


def handler(t1, t2, kind):
    if kind == "PRIMITIVE":
        return _PRIMITIVE_COLLISIONS[(t1, t2)].key          # the wp.func name
    if G.HFIELD in (t1, t2):
        return f"ccd_hfield_kernel_builder({t1.name}, {t2.name})"
    return f"ccd_kernel_builder({t1.name}, {t2.name})"


def grid(table):
    cells = {}
    for i, t1 in enumerate(RIGID):
        for t2 in RIGID[i:]:
            v = table.get((t1, t2))
            cells[(t1, t2)] = None if v is None else v.name
    return cells


def show(cells, title):
    print(title)
    print("         " + " ".join(f"{SHORT[t]:>7s}" for t in RIGID))
    for i, t1 in enumerate(RIGID):
        row = []
        for j, t2 in enumerate(RIGID):
            a, b = (t1, t2) if i <= j else (t2, t1)
            k = cells[(a, b)]
            row.append(f"{'.' if k is None else k[0]:>7s}")
        print(f"{SHORT[t1]:>8s} " + " ".join(row))


default = grid(table_for(False))
noccd = grid(table_for(True))
show(default, "MJ_COLLISION_TABLE (P = PRIMITIVE, C = CONVEX, . = no entry: never collides)")
n_p = sum(v == "PRIMITIVE" for v in default.values())
n_c = sum(v == "CONVEX" for v in default.values())
n_none = sum(v is None for v in default.values())
print(f"cells: {n_p} PRIMITIVE, {n_c} CONVEX, {n_none} missing ->",
      [f"{a.name}-{b.name}" for (a, b), v in default.items() if v is None])

print("\nprimitive handlers (collision_primitive._PRIMITIVE_COLLISIONS):")
for (t1, t2), f in _PRIMITIVE_COLLISIONS.items():
    tag = "" if default[(t1, t2)] == "PRIMITIVE" else "   <- only with NATIVECCD disabled"
    print(f"  {t1.name:>8s}-{t2.name:<9s} {f.key}{tag}")

print("\nBOX-BOX by default:", default[(G.BOX, G.BOX)],
      "| with DisableBit.NATIVECCD:", noccd[(G.BOX, G.BOX)])
flipped = [f"{a.name}-{b.name}" for (a, b) in default if default[(a, b)] != noccd[(a, b)]]
print("cells changed by NATIVECCD:", flipped)

print("\nMJ_FLEX_COLLISION_TABLE:")
for (t1, t2), v in MJ_FLEX_COLLISION_TABLE.items():
    print(f"  {t1.name:>9s}-{t2.name:<5s} {v.name}")
missing_flex = [t.name for t in RIGID if (t, G.FLEX) not in MJ_FLEX_COLLISION_TABLE]
print("flex partners with no entry:", missing_flex)
print("SDF in the rigid table:", any(G.SDF in k for k in MJ_COLLISION_TABLE),
      "(SDF pairs go to sdf_narrowphase instead)")

if args.dump_json:
    out = {"types": [SHORT[t] for t in RIGID], "cells": []}
    for (t1, t2), kind in default.items():
        out["cells"].append({"a": RIGID.index(t1), "b": RIGID.index(t2), "kind": kind,
                             "kind_noccd": noccd[(t1, t2)],
                             "fn": None if kind is None else handler(t1, t2, kind),
                             "fn_noccd": None if noccd[(t1, t2)] is None
                             else handler(t1, t2, noccd[(t1, t2)])})
    out["flex"] = [{"a": RIGID.index(t1), "kind": v.name} for (t1, _), v
                   in MJ_FLEX_COLLISION_TABLE.items()]
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(out["cells"]), "cells")
