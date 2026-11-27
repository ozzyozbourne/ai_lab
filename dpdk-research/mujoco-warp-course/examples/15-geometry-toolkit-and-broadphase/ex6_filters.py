"""Example 15.6 - the four bounding-volume filters on one packed scene.

m.opt.broadphase_filter is a bitmask of BroadphaseFilter.PLANE | SPHERE | AABB | OBB. The filter
only decides which pairs reach the narrowphase (d.ncollision); every filter is conservative, so the
contacts the narrowphase finds (d.nacon) are the same for every choice.
Run: python ex6_filters.py [--dump-json PATH]
  --dump-json PATH writes the per-filter counts for the page's bar chart.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

F = mjw.BroadphaseFilter
ON_GPU = wp.get_device().is_cuda
NWORLD = 64 if ON_GPU else 2

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()


def scatter(n, seed=0, spacing=0.4):
    """MJCF string: a plane plus n free bodies (alternating sphere / capsule), lattice + jitter."""
    rng = np.random.default_rng(seed)
    per_side = 10                                   # 10 x 10 bodies per layer, 4 m x 4 m
    bodies = []
    for i in range(n):
        layer, k = divmod(i, per_side * per_side)
        row, col = divmod(k, per_side)
        x = -0.5 * spacing * (per_side - 1) + spacing * col + rng.uniform(-0.02, 0.02)
        y = -0.5 * spacing * (per_side - 1) + spacing * row + rng.uniform(-0.02, 0.02)
        z = 0.3 + spacing * layer
        if i % 2 == 0:
            geom = f'<geom type="sphere" size="{rng.uniform(0.05, 0.1):.3f}"/>'
        else:
            e = rng.uniform(-180, 180, size=3)
            geom = (f'<geom type="capsule" size="{rng.uniform(0.05, 0.07):.3f} '
                    f'{rng.uniform(0.05, 0.1):.3f}" euler="{e[0]:.0f} {e[1]:.0f} {e[2]:.0f}"/>')
        bodies.append(f'<body name="b{i}" pos="{x:.3f} {y:.3f} {z:.3f}"><freejoint/>{geom}</body>')
    return ('<mujoco model="scatter"><option timestep="0.002"/><worldbody>'
            '<light pos="0 0 4" dir="0 0 -1"/><geom name="floor" type="plane" size="3 3 .1"/>'
            + "".join(bodies) + '</worldbody></mujoco>')



mjm = mujoco.MjModel.from_xml_string(scatter(100, spacing=0.22))   # packed: neighbours overlap
m = mjw.put_model(mjm)
nfiltered = m.nxn_geom_pair_filtered.shape[0]
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=nfiltered + 64, njmax=256)  # room for every pair
mjw.kinematics(m, d)
print(f"ngeom = {mjm.ngeom}, filtered pairs per world = {nfiltered}, nworld = {NWORLD}")
print("filter                     ncollision  per world   nacon")
configs = [F.PLANE, F.SPHERE, F.PLANE | F.SPHERE, F.PLANE | F.AABB, F.PLANE | F.OBB,
           F.PLANE | F.SPHERE | F.OBB, F.PLANE | F.SPHERE | F.AABB | F.OBB]
results = []
for flt in configs:
    m.opt.broadphase_filter = flt            # baked in with wp.static: a new kernel per value
    mjw.collision(m, d)
    ncol, nacon = int(d.ncollision.numpy()[0]), int(d.nacon.numpy()[0])
    name = "|".join(f.name for f in F if f & flt)
    results.append((ncol, nacon, name))
    default = "  (default)" if flt == F.PLANE | F.SPHERE | F.OBB else ""
    print(f"{name:26s} {ncol:10d} {ncol // NWORLD:10d} {nacon:7d}{default}")
assert len({r[1] for r in results}) == 1, "nacon must not depend on the filter"
assert max(r[0] for r in results) <= d.naconmax, "candidate buffer overflowed"
print("nacon identical for every filter:", results[0][1])

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "nfiltered": nfiltered, "ngeom": mjm.ngeom,
                   "rows": [{"filter": r[2], "ncollision": r[0], "nacon": r[1]} for r in results]},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
