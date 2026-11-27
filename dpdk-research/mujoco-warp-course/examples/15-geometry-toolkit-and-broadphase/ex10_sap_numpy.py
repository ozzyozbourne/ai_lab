"""Example 15.10 - sweep-and-prune re-implemented in NumPy, step by step, for two worlds.

Mirrors collision_driver.py::sap_broadphase: _sap_project (project bounding spheres onto a fixed
oblique axis), a per-world sort of the lower bounds, collision_core.py::sap_range (binary search
for how far each interval reaches), an inclusive prefix sum (wp.utils.array_scan), and the sweep
that decodes every work id into (world, i, j). The pairs that pass the PLANE | SPHERE filter must
match d.ncollision from MJWarp's SAP_TILE broadphase.
Run: python ex10_sap_numpy.py [--dump-json PATH]
  --dump-json PATH writes the intervals, sort order, ranges and prefix sum for the SAP stepper.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True, linewidth=100)
NWORLD = 2
MAXVAL = mujoco.mjMAXVAL                            # 1e10: a plane's "infinite" radius

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



def upper_tri_index(n, i, j):
    i, j = (j, i) if j < i else (i, j)
    return (i * (2 * n - i - 3)) // 2 + j - 1


mjm = mujoco.MjModel.from_xml_string(scatter(12, spacing=0.22))
m = mjw.put_model(mjm)
m.opt.broadphase = mjw.BroadphaseType.SAP_TILE
m.opt.broadphase_filter = mjw.BroadphaseFilter.PLANE | mjw.BroadphaseFilter.SPHERE
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=128, njmax=64)
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[1, 0::7] += np.random.default_rng(1).uniform(-0.15, 0.15, mjm.nbody - 1)  # world 1: jitter x
d.qpos.assign(qpos.astype(np.float32))
mjw.kinematics(m, d)
mjw.collision(m, d)

n = mjm.ngeom
xpos = d.geom_xpos.numpy()                          # (nworld, ngeom, 3)
xmat = d.geom_xmat.numpy()
rbound = mjm.geom_rbound
margin = mjm.geom_margin + mjm.geom_gap             # no explicit <pair>: pair margin is 0
pairid = m.nxn_pairid.numpy()

# 1. _sap_project: interval [c - r, c + r] on a fixed oblique axis (a constant in the code)
direction = np.array([0.5935, 0.7790, 0.1235])
direction /= np.linalg.norm(direction)
radius = np.where(rbound == 0.0, MAXVAL, rbound) + margin
center = xpos @ direction                           # (nworld, ngeom)
lower, upper = center - radius, center + radius
print("axis =", direction.round(4), "| geom 0 is the plane: radius", radius[0])

# 2. sort the lower bounds within each world (SAP_TILE: one tile per world)
order = np.argsort(lower, axis=1, kind="stable")    # sort_index
lower_sorted = np.take_along_axis(lower, order, axis=1)

# 3. sap_range: first later sorted lower bound > my upper bound, clamped to n - 1
rng_ = np.zeros((NWORLD, n), dtype=int)
for w in range(NWORLD):
    for i in range(n):
        up = upper[w, order[w, i]]
        limit = i + 1 + np.searchsorted(lower_sorted[w, i + 1:], up, side="right")
        rng_[w, i] = min(n - 1, limit) - i

# 4. array_scan: inclusive prefix sum over ALL worlds -> total number of work packages
cumsum = np.cumsum(rng_.reshape(-1))
nwork = int(cumsum[-1])

# 5. _sap_broadphase: decode work id -> (world, i, j), skip -2 pairs, run the filter
found = []
for work in range(nwork):
    flat_i = int(np.searchsorted(cumsum, work, side="right"))     # sap_binary_search
    flat_j = flat_i + work + 1 - (cumsum[flat_i - 1] if flat_i > 0 else 0)
    w, i, j = flat_i // n, flat_i % n, flat_j % n
    g1, g2 = sorted((order[w, i], order[w, j]))
    if pairid[upper_tri_index(n, g1, g2), 0] == -2:
        continue
    if rbound[g1] == 0.0:                                         # plane band test
        ok = (xpos[w, g2] - xpos[w, g1]) @ xmat[w, g1][:, 2] <= rbound[g2] + margin[g1] + margin[g2]
    else:                                                         # bounding spheres
        bound = rbound[g1] + rbound[g2] + margin[g1] + margin[g2]
        ok = np.sum((xpos[w, g2] - xpos[w, g1]) ** 2) <= bound * bound
    if ok:
        found.append((w, int(g1), int(g2)))

for w in range(NWORLD):
    print(f"world {w}: sort_index = {order[w].tolist()}")
    print(f"         range      = {rng_[w].tolist()}")
print("cumulative_sum =", cumsum.tolist())
print(f"work packages (SAP) = {nwork}  vs  NXN threads = {NWORLD * m.nxn_geom_pair_filtered.shape[0]}")
print(f"nsweep threads launched by MJWarp = 5 * nworld * ngeom = {5 * NWORLD * n}")
print("pairs passing PLANE|SPHERE (NumPy):", len(found), "| d.ncollision (MJWarp SAP_TILE):",
      int(d.ncollision.numpy()[0]))
print("per world:", np.bincount([f[0] for f in found], minlength=NWORLD).tolist(),
      "| first pairs:", found[:4])
assert len(found) == int(d.ncollision.numpy()[0])

if args.dump_json:
    clip = lambda a: np.clip(a, -9.99, 9.99).round(3).tolist()   # planes: +-1e10 -> +-9.99
    out = {"ngeom": n, "nworld": NWORLD, "direction": direction.round(4).tolist(),
           "type": mjm.geom_type.tolist(), "rbound": rbound.round(3).tolist(),
           "xpos": xpos.astype(np.float64).round(3).tolist(), "center": center.round(3).tolist(),
           "lower": clip(lower), "upper": clip(upper), "order": order.tolist(),
           "range": rng_.tolist(), "cumsum": cumsum.tolist(), "found": found}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
