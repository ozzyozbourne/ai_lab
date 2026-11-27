"""Example 23.8 - flex contacts next to rigid contacts in the one shared pool.

A 6x6 cloth (1 m wide) falls on scatter(30) (model M9: free spheres and capsules, Ch 15) over a
plane; no hfield and no SDF, which a flex model may not contain. We count the contacts of each
path, record the kernels that one mjw.collision call launches (wp.launch wrapped, as in
Example 18.9), and print the flex/elem/vert fields of the first flex contacts.
A contact side is a flex exactly when contact.geom is -1 on that side. In 4.0.1 the rigid
colliders do not reset contact.flex/elem/vert, so a rigid contact can carry stale flex ids
from an earlier step: classify by contact.geom, as support.contact_bodies_and_weights does.
Run: python ex8_flex_contacts.py [--dump-json PATH]
  --dump-json PATH writes the pool (worldid and path per slot) and the kernel list.
"""
import argparse
import collections
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.collision_driver import MJ_COLLISION_TABLE       # private API
from mujoco_warp._src.collision_driver import MJ_FLEX_COLLISION_TABLE  # private API

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 2
NSTEP = 1000 if ON_GPU else 250
G = mjw.GeomType


def scatter_bodies(n, seed=0, spacing=0.4, z0=0.3):
    """The bodies of scatter(n) (model M9, Ch 15)."""
    rng = np.random.default_rng(seed)
    per_side = 10
    out = []
    for i in range(n):
        layer, k = divmod(i, per_side * per_side)
        row, col = divmod(k, per_side)
        x = -0.5 * spacing * (per_side - 1) + spacing * col + rng.uniform(-0.02, 0.02)
        y = -0.5 * spacing * (per_side - 1) + spacing * row + rng.uniform(-0.02, 0.02)
        z = z0 + spacing * layer
        if i % 2 == 0:
            geom = f'<geom type="sphere" size="{rng.uniform(0.05, 0.1):.3f}"/>'
        else:
            e = rng.uniform(-180, 180, size=3)
            geom = (f'<geom type="capsule" size="{rng.uniform(0.05, 0.07):.3f} '
                    f'{rng.uniform(0.05, 0.1):.3f}" euler="{e[0]:.0f} {e[1]:.0f} {e[2]:.0f}"/>')
        out.append(f'<body name="b{i}" pos="{x:.3f} {y:.3f} {z:.3f}"><freejoint/>{geom}</body>')
    return "".join(out)


SCENE = f"""
<mujoco model="cloth_over_scatter">
  <option timestep="0.002" solver="CG" tolerance="1e-6"/>
  <worldbody>
    <light pos="0 0 4" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="3 3 .1"/>
    {scatter_bodies(30)}
    <flexcomp name="cloth" type="grid" count="6 6 1" spacing=".2 .2 .2" pos="0 -1.4 .5"
              radius=".01" dim="2" mass=".2">
      <edge equality="true"/>
      <contact condim="3" selfcollide="none"/>
    </flexcomp>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(SCENE)
m = mjw.put_model(mjm)
m.opt.warn_overflow = 0
print(f"ngeom {mjm.ngeom}  nflex {mjm.nflex}  nflexvert {mjm.nflexvert}  nv {mjm.nv}")
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=128, njmax=640)
for _ in range(NSTEP):
    mjw.step(m, d)
wp.synchronize()

# ---- record the kernels of one collision call ----
calls = []
_launch = wp.launch


def recording_launch(kernel, dim, *a, **kw):
    calls.append((kernel.key.split("__")[0], np.atleast_1d(dim).tolist()))
    return _launch(kernel, dim, *a, **kw)


wp.launch = recording_launch
try:
    mjw.collision(m, d)
finally:
    wp.launch = _launch
wp.synchronize()
print(f"one mjw.collision call launches {len(calls)} kernels:")
for name, dim in calls:
    print(f"  {name:32s} dim {dim}")

# ---- contacts per path ----
nacon = min(int(d.nacon.numpy()[0]), d.naconmax)
geom = d.contact.geom.numpy()[:nacon]
flex = d.contact.flex.numpy()[:nacon]
elem = d.contact.elem.numpy()[:nacon]
vert = d.contact.vert.numpy()[:nacon]
is_flex = (geom < 0).any(axis=1)          # a flex side has geom == -1
per_path = collections.Counter()
slot_kind = []
for g, flx in zip(geom, is_flex):
    if flx:
        gt = G(int(mjm.geom_type[g[g >= 0][0]]))
        key = f"flex-{gt.name} ({MJ_FLEX_COLLISION_TABLE[(gt, G.FLEX)].name})"
    else:
        t1, t2 = G(int(mjm.geom_type[g[0]])), G(int(mjm.geom_type[g[1]]))
        key = f"{t1.name}-{t2.name} ({MJ_COLLISION_TABLE[(t1, t2)].name})"
    per_path[key] += 1
    slot_kind.append(key)
print(f"after {NSTEP} steps, {NWORLD} worlds: nacon {nacon} of {d.naconmax}")
for k, v in sorted(per_path.items()):
    print(f"  {v:4d}  {k}")
stale = int(((flex >= 0).any(axis=1) & ~is_flex).sum())
print(f"rigid contacts whose (stale) contact.flex is not -1: {stale}")
print("first flex contact of each kind (geom, flex, elem, vert; -1 = not that kind of object):")
seen = set()
for c in np.nonzero(is_flex)[0]:
    kind = int(mjm.geom_type[geom[c][0]])
    if kind in seen:
        continue
    seen.add(kind)
    print(f"  contact {c}: geom {geom[c]}  flex {flex[c]}  elem {elem[c]}  vert {vert[c]}  "
          f"dist {d.contact.dist.numpy()[c]:+.4f}")
print(f"max nefc {int(d.nefc.numpy().max())} of njmax {d.njmax}; overflow:",
      "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"naconmax": d.naconmax, "nworld": NWORLD, "nstep": NSTEP,
                   "worldid": d.contact.worldid.numpy()[:nacon].tolist(), "kind": slot_kind,
                   "calls": calls, "per_path": dict(per_path)}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
