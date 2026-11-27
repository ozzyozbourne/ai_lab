"""Example 17.8 - CCD scratch: the naccdmax budget, its overflow bit, and its size in bytes.

Every convex pair that needs EPA (or multi-contact) reserves one row of scratch memory with
ccdid = wp.atomic_add(nccd, geomgeomid, 1). If ccdid >= naccdmax the pair is dropped and the
CCD bit is set in d.overflow (collision_convex.py::ccd_kernel_builder). Part 1 puts 6
ellipsoids into 6 boxes in each of 2 worlds (12 EPA pairs) and runs with nccdmax = 2 per world
(make_data multiplies it by nworld: naccdmax = 4) and with the default (naccdmax = naconmax). Part 2 computes the per-row scratch that
convex_narrowphase allocates in 4.0.1 from the same rules, and checks the rules by recording
the real wp.empty calls of collision_convex.py for four small models.
Run: python ex8_naccdmax_overflow.py [--dump-json PATH]
  --dump-json PATH writes the measured scratch sizes for the page's scratch calculator.
"""
import argparse
import json
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.collision_driver import MJ_COLLISION_TABLE  # private API

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 2
MJ_MAX_EPAHORIZON, MJ_MAX_EPAFACES = 24, 5          # constants from _src/types.py (4.0.1)


def ellipsoids_in_boxes(k=6):
    parts = []
    for i in range(k):
        x = 0.3 * i
        parts.append(f'<geom type="box" pos="{x} 0 0.05" size="0.1 0.1 0.05"/>'
                     f'<body pos="{x} 0 0.12"><freejoint/>'
                     f'<geom type="ellipsoid" size="0.06 0.05 0.04"/></body>')
    return f'<mujoco><worldbody>{"".join(parts)}</worldbody></mujoco>'


# ---------- Part 1: overflow ----------
dump = {"part1": [], "rows": []}
mjm = mujoco.MjModel.from_xml_string(ellipsoids_in_boxes())
for nccdmax in [2, None]:                             # per world, like nconmax; None = default
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0                           # keep stdout clean; the bit is still set
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64, nccdmax=nccdmax)
    mjw.kinematics(m, d)
    mjw.collision(m, d)
    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    ov = d.overflow.numpy()
    bits = [mjw.OverflowType(int(v)) for v in ov]
    print(f"naccdmax={d.naccdmax:3d} (naconmax={d.naconmax}): contacts written = {n} of "
          f"{6 * NWORLD} penetrating pairs; overflow per world = {[b.name for b in bits]}")
    worlds = [int(w) for w in d.contact.worldid.numpy()[:n]]
    print(f"  worldid of the written contacts = {worlds}")
    dump["part1"].append({"naccdmax": d.naccdmax, "naconmax": d.naconmax, "worlds": worlds,
                          "pairs": 6 * NWORLD, "overflow": [b.name for b in bits]})

# ---------- Part 2: scratch bytes per CCD row ----------
VEC3, INT, FLT = 12, 4, 4


def rules(epa_iterations, npolygonmax, nmeshdegmax):
    """Bytes per row of every array convex_narrowphase allocates (4.0.1, lines ~1311-1438)."""
    nv, nf = 10 + 2 * epa_iterations, 6 + MJ_MAX_EPAFACES * epa_iterations
    epa = {"epa_vert": nv * VEC3, "epa_vert_index": nv * INT, "epa_face": nf * INT,
           "epa_pr": nf * VEC3, "epa_norm2": nf * FLT, "epa_horizon": MJ_MAX_EPAHORIZON * INT}
    p, q = npolygonmax, nmeshdegmax
    multi = {"multiccd_polygon": 2 * p * VEC3, "multiccd_clipped": 2 * p * VEC3,
             "multiccd_pnormal": p * VEC3, "multiccd_pdist": p * FLT,
             "multiccd_idx1": q * INT, "multiccd_idx2": q * INT, "multiccd_n1": q * VEC3,
             "multiccd_n2": q * VEC3, "multiccd_endvert": q * VEC3,
             "multiccd_face1": p * VEC3, "multiccd_face2": p * VEC3}
    return epa, multi


def predicted_dims(m):
    """The epa_iterations / npolygonmax / nmeshdegmax rules of convex_narrowphase."""
    G = mjw.GeomType
    ng = len(G)

    def count(a, b):
        a, b = min(a, b), max(a, b)
        return m.geom_pair_type_count[a * ng - a * (a + 1) // 2 + b]   # upper_trid_index
    convex = [k for k, v in MJ_COLLISION_TABLE.items() if v.name == "CONVEX"]
    total = sum(count(int(a), int(b)) for a, b in convex)
    nboxbox = count(G.BOX, G.BOX)
    epa_it = 16 if nboxbox == total else m.opt.ccd_iterations
    multi = (m.opt.disableflags & mjw.DisableBit.MULTICCD) == 0
    P, Q = (4, 3) if nboxbox else (0, 0)
    if multi and count(5, 5) + count(5, 6) + count(5, 7) + count(3, 5) > 0:
        P, Q = max(m.npolygonmax, 16), max(m.nmeshdegmax, 3)
    elif multi and count(7, 7) + count(6, 7) + count(3, 7) > 0:
        P, Q = max(m.npolygonmax, 4 if count(6, 7) else P), max(m.nmeshdegmax, 3)
    return epa_it, P, Q


def record_allocs(xml):
    """Run collision once and record every wp.empty made inside collision_convex.py."""
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=1, nconmax=16, njmax=64)
    mjw.kinematics(m, d)
    seen, orig = [], wp.empty

    def spy(*a, **k):
        arr = orig(*a, **k)
        if sys._getframe(1).f_code.co_filename.endswith("collision_convex.py"):
            seen.append(arr)
        return arr
    wp.empty = spy
    try:
        mjw.collision(m, d)
    finally:
        wp.empty = orig
    rows = [a for a in seen if a.ndim == 2 and a.shape[0] == d.naccdmax]
    measured = sum(a.shape[1] * wp.types.type_size_in_bytes(a.dtype) for a in rows)
    return m, d, measured


MESH = ('<asset><mesh name="hex" vertex="' + " ".join(
    f"{0.05 * np.cos(a):.4f} {0.05 * np.sin(a):.4f} {z}" for z in (-.03, .03)
    for a in np.arange(6) * np.pi / 3) + '"/></asset>')
BOX = '<body pos="{x} 0 0.15"><freejoint/><geom type="box" size=".05 .05 .05"/></body>'
CONFIGS = {
    "ellipsoid-box (Part 1)": ellipsoids_in_boxes(),
    "box-box only": f'<mujoco><worldbody><geom type="box" size=".1 .1 .1"/>'
                    f'{BOX.format(x=0)}</worldbody></mujoco>',
    "+ cylinder": f'<mujoco><worldbody><geom type="box" size=".1 .1 .1"/>{BOX.format(x=0)}'
                  f'<body pos="1 0 .1"><freejoint/><geom type="cylinder" size=".05 .05"/></body>'
                  f'</worldbody></mujoco>',
    "+ mesh": f'<mujoco>{MESH}<worldbody><geom type="box" size=".1 .1 .1"/>{BOX.format(x=0)}'
              f'<body pos="1 0 .1"><freejoint/><geom type="mesh" mesh="hex"/></body>'
              f'</worldbody></mujoco>',
}
print(f"{'model':24s} {'epa_it':>6s} {'npoly':>5s} {'ndeg':>4s} {'EPA B':>6s} {'multi B':>7s}"
      f" {'rule B/row':>10s} {'measured':>8s} {'naccdmax':>8s} {'total':>9s}")
for name, xml in CONFIGS.items():
    m, d, measured = record_allocs(xml)
    e_it, P, Q = predicted_dims(m)
    epa, multi = rules(e_it, P, Q)
    rule = sum(epa.values()) + sum(multi.values())
    print(f"{name:24s} {e_it:6d} {P:5d} {Q:4d} {sum(epa.values()):6d} {sum(multi.values()):7d}"
          f" {rule:10d} {measured:8d} {d.naccdmax:8d} {rule * d.naccdmax:9d}")
    dump["rows"].append({"name": name, "epa_iterations": e_it, "npolygonmax": P,
                         "nmeshdegmax": Q, "epa_bytes": sum(epa.values()),
                         "multi_bytes": sum(multi.values()), "measured": measured,
                         "naccdmax": d.naccdmax, "epa": epa, "multi": multi})
nslot = 4096 * 48 if ON_GPU else 8 * 48
print(f"e.g. a mesh scene with naccdmax = {nslot}: "
      f"{dump['rows'][-1]['measured'] * nslot / 2**20:.1f} MiB of CCD scratch per collision call")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
