"""Example 18.9 - Part IV checkpoint "Falling clutter": profile the rigid paths, fix overflow.

The scene is TERRAIN (model M7: a heightfield with a sphere, an ellipsoid, a cylinder and a
tetrahedron mesh) plus scatter(30) (model M9: 30 free spheres and capsules) over a floor plane.
It uses the PRIMITIVE, CONVEX and HFIELD narrowphase paths; no flex and no SDF.
1. Start from deliberately small budgets, step, and decode d.overflow (describe_overflow, Ch 9).
   Double whatever overflowed and try again until the run is clean.
2. With the fixed budgets, record every kernel that one mjw.collision call launches (we wrap
   wp.launch and keep the kernel names, as in Example 16.8) and count contacts per path.
Run: python ex9_checkpoint_clutter.py [--dump-json PATH]
"""
import argparse
import collections
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import warp_util                            # private API (kernel cache)
from mujoco_warp._src.collision_driver import MJ_COLLISION_TABLE  # private API

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 200
G = mjw.GeomType

TERRAIN_ASSETS = """
    <hfield name="bumps" nrow="5" ncol="5" size="1 1 .2 .1"
      elevation="0 0 0 0 0  0 .5 1 .5 0  0 1 0 1 0  0 .5 1 .5 0  0 0 0 0 0"/>
    <mesh name="tetra" vertex="0 0 0  .2 0 0  0 .2 0  0 0 .2"/>"""
TERRAIN_BODIES = """
    <geom name="ground" type="hfield" hfield="bumps"/>
    <body name="ball" pos="0.2 0.1 .6"><freejoint/><geom type="sphere" size=".08"/></body>
    <body name="ellipsoid" pos="-0.3 0.2 .6"><freejoint/>
      <geom type="ellipsoid" size=".1 .07 .05"/></body>
    <body name="cyl" pos="0.3 -0.3 .6"><freejoint/><geom type="cylinder" size=".06 .05"/></body>
    <body name="tetra" pos="-0.3 -0.3 .6"><freejoint/><geom type="mesh" mesh="tetra"/></body>"""


def scatter_bodies(n, seed=0, spacing=0.4, z0=0.9, per_side=10, center=(0.0, 0.0)):
    """The bodies of scatter(n) (model M9, Ch 15), started z0 above the floor.

    per_side bodies per row and per_side rows per layer, spacing apart, centred on center (x, y).
    """
    rng = np.random.default_rng(seed)
    out = []
    for i in range(n):
        layer, k = divmod(i, per_side * per_side)
        row, col = divmod(k, per_side)
        x = center[0] - 0.5 * spacing * (per_side - 1) + spacing * col + rng.uniform(-0.02, 0.02)
        y = center[1] - 0.5 * spacing * (per_side - 1) + spacing * row + rng.uniform(-0.02, 0.02)
        z = z0 + spacing * layer
        if i % 2 == 0:
            geom = f'<geom type="sphere" size="{rng.uniform(0.05, 0.1):.3f}"/>'
        else:
            e = rng.uniform(-180, 180, size=3)
            geom = (f'<geom type="capsule" size="{rng.uniform(0.05, 0.07):.3f} '
                    f'{rng.uniform(0.05, 0.1):.3f}" euler="{e[0]:.0f} {e[1]:.0f} {e[2]:.0f}"/>')
        out.append(f'<body name="b{i}" pos="{x:.3f} {y:.3f} {z:.3f}"><freejoint/>{geom}</body>')
    return "".join(out)


# Drop the 30 bodies as a 5 x 5 (+5) block, 0.25 m apart, over the middle of the 2 m x 2 m
# heightfield: they land on the terrain and on the TERRAIN bodies, so the CONVEX pairs
# (sphere/capsule against ellipsoid, cylinder, mesh) and HFIELD-CAPSULE really make contacts.
LAYOUT = dict(spacing=0.25, per_side=5, z0=1.0, center=(0.0, 0.0))

CLUTTER = f"""
<mujoco model="falling_clutter">
  <option timestep="0.005"/>
  <asset>{TERRAIN_ASSETS}</asset>
  <worldbody>
    <light pos="0 0 4" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="3 3 .1"/>{TERRAIN_BODIES}
    {scatter_bodies(30, **LAYOUT)}
  </worldbody>
</mujoco>
"""


def describe_overflow(d, max_worlds=8):
    """Same as my_env.describe_overflow (Ch 9): "none", or the flagged bits per world."""
    ov = d.overflow.numpy()
    if not ov.any():
        return "none"
    flagged = np.nonzero(ov)[0]
    lines = [f"world {w}: " + " | ".join(b.name for b in mjw.OverflowType if ov[w] & b)
             for w in flagged[:max_worlds]]
    counts = [f"{b.name} x{int(np.count_nonzero(ov & b))}" for b in mjw.OverflowType
              if (ov & b).any()]
    return "\n".join(lines + ["worlds per bit: " + ", ".join(counts)])


def path_of(t1, t2):
    if G.HFIELD in (t1, t2):
        return "HFIELD"
    return MJ_COLLISION_TABLE[(t1, t2)].name


mjm = mujoco.MjModel.from_xml_string(CLUTTER)
m = mjw.put_model(mjm)
m.opt.warn_overflow = 0      # we decode d.overflow ourselves (this recompiles nothing yet)
types = sorted({mujoco.mjtGeom(t).name[7:] for t in mjm.geom_type})
print(f"nbody {mjm.nbody}  nv {mjm.nv}  ngeom {mjm.ngeom}  geom types {types}")
d1 = mjw.make_data(mjm, nworld=1)
print(f"io.py defaults: nconmax {d1.naconmax} per world, njmax {d1.njmax}")

# ---- 1. find and fix the first overflow ----
sizes = {"nconmax": 8, "njmax": 32, "nccdmax": 1}         # per world
FIX = {"BROADPHASE": "nconmax", "NARROWPHASE": "nconmax", "NEFC": "njmax", "CCD": "nccdmax"}
history = []
for attempt in range(6):
    d = mjw.make_data(mjm, nworld=NWORLD, **sizes)
    for _ in range(NSTEP):
        mjw.step(m, d)
    wp.synchronize()
    report = describe_overflow(d)
    bits = {b.name for b in mjw.OverflowType if (d.overflow.numpy() & b).any()}
    raw = int(d.nacon.numpy()[0])                       # can exceed naconmax
    print(f"try {attempt}: {sizes} nacon {raw}/{d.naconmax} -> {report.splitlines()[-1]}")
    history.append({"sizes": dict(sizes), "bits": sorted(bits), "nacon": raw,
                    "naconmax": d.naconmax,
                    "worldid": d.contact.worldid.numpy()[:min(raw, d.naconmax)].tolist()})
    if not bits:
        break
    grow = {FIX[b] for b in bits if b in FIX}
    if "nccdmax" in grow and sizes["nccdmax"] >= sizes["nconmax"]:
        grow.add("nconmax")                              # CCD is capped by nconmax
    for key in grow:
        sizes[key] *= 4 if key == "nccdmax" else 2
    sizes["nccdmax"] = min(sizes["nccdmax"], sizes["nconmax"])   # make_data: nccdmax <= nconmax

# ---- 2. one recorded collision call with the clean budgets ----
calls = []
_launch = wp.launch


built = {id(k): key for key, k in warp_util._KERNEL_CACHE.items()}   # kernel -> builder args


def label(kernel):
    key = built.get(id(kernel))
    if key and key[-1] in ("ccd_kernel_builder", "ccd_hfield_kernel_builder"):
        return f"{key[-1]}({G(key[0]).name}, {G(key[1]).name})"
    return kernel.key.split("__")[0]


def recording_launch(kernel, dim, *a, **kw):
    calls.append((label(kernel), np.atleast_1d(dim).tolist()))
    return _launch(kernel, dim, *a, **kw)


wp.launch = recording_launch
try:
    mjw.collision(m, d)
finally:
    wp.launch = _launch
wp.synchronize()
print("kernels launched by one mjw.collision call:")
for name, dim in calls:
    print(f"  {name:44s} dim {dim}")

nacon = min(int(d.nacon.numpy()[0]), d.naconmax)
gt = mjm.geom_type[d.contact.geom.numpy()[:nacon]]
per_path = collections.Counter(path_of(G(int(a)), G(int(b))) for a, b in gt)
per_pair = collections.Counter(f"{G(int(a)).name}-{G(int(b)).name}" for a, b in gt)
print(f"contacts after {NSTEP} steps, {NWORLD} worlds (nacon {nacon} of {d.naconmax}):")
for path in ["PRIMITIVE", "CONVEX", "HFIELD"]:
    pairs = {k: v for k, v in sorted(per_pair.items())
             if path_of(*[G[x] for x in k.split("-")]) == path}
    print(f"  {path:9s} {per_path[path]:4d}  {pairs}")
assert per_path["CONVEX"] > 0 and per_pair["HFIELD-CAPSULE"] > 0, "layout must exercise every path"
print(f"max nefc per world {int(d.nefc.numpy().max())} of njmax {d.njmax}")
print("overflow:", describe_overflow(d))

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"history": history, "per_path": dict(per_path), "per_pair": dict(per_pair),
                   "calls": calls, "nworld": NWORLD, "nstep": NSTEP}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
