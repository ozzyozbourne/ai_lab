"""Example 16.8 - what the narrowphase actually launches, and what changes when a geom type goes.

We wrap wp.launch to record every kernel launched by mjw.collision (name and dim), and wrap
collision_driver.create_collision_context to keep the broadphase output, so we can say which
static branch each primitive thread takes. Scene A has PLANE, SPHERE, BOX and CYLINDER geoms
(one convex pair type: BOX-CYLINDER). Scene B is the same without the spheres. Expect:
  - exactly ONE primitive launch in both scenes, dim = d.naconmax, but a different compiled
    kernel (its if-chain is built from the pair types with geom_pair_type_count > 0);
  - one convex launch per present convex pair type (here BOX-CYLINDER), unchanged.
Run: python ex8_type_pair_launches.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import collision_driver           # private API
from mujoco_warp._src import warp_util                  # private API (cache_kernel's dict)
from mujoco_warp._src.collision_driver import MJ_COLLISION_TABLE  # private API
from mujoco_warp._src.math import upper_trid_index      # private API

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

SCENE = """
<mujoco model="dispatch">
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="crate" pos="0 0 0.0995"><freejoint/>
      <geom name="crate" type="box" size="0.1 0.1 0.1"/></body>
    <body name="drum" pos="0.1595 0 0.0995"><freejoint/>
      <geom name="drum" type="cylinder" size="0.06 0.1"/></body>
    {spheres}
  </worldbody>
</mujoco>
"""
SPHERES = """
    <body name="ball_top" pos="0 0 0.249"><freejoint/>
      <geom name="ball_top" type="sphere" size="0.05"/></body>
    <body name="ball_floor" pos="-0.3 0 0.0495"><freejoint/>
      <geom name="ball_floor" type="sphere" size="0.05"/></body>"""

G = mjw.GeomType
NWORLD = 2
_launch = wp.launch
_make_ctx = collision_driver.create_collision_context
calls, ctxs = [], []


def recording_launch(kernel, dim, *a, **kw):
    calls.append((kernel.key, kernel.module.name, dim))
    return _launch(kernel, dim, *a, **kw)


def recording_ctx(naconmax):
    ctx = _make_ctx(naconmax)
    ctxs.append(ctx)
    return ctx


def present_pairs(m):
    rigid = [t for t in G if t.value <= G.MESH.value]       # geom types a geom can have here
    out = []
    for t1 in rigid:
        for t2 in rigid:
            if t1.value <= t2.value:
                if m.geom_pair_type_count[upper_trid_index(len(G), t1.value, t2.value)]:
                    out.append(f"{t1.name}-{t2.name}")
    return out


report = {}
for label, spheres in [("A: plane+sphere+box+cylinder", SPHERES), ("B: spheres removed", "")]:
    mjm = mujoco.MjModel.from_xml_string(SCENE.format(spheres=spheres))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=24, njmax=96)
    mjw.kinematics(m, d)
    mjw.collision(m, d)                     # warm-up: compile outside the recording
    calls.clear(), ctxs.clear()
    wp.launch = recording_launch
    collision_driver.create_collision_context = recording_ctx
    try:
        mjw.collision(m, d)
    finally:
        wp.launch = _launch
        collision_driver.create_collision_context = _make_ctx
    wp.synchronize()

    print(label)
    print("  geom_pair_type_count > 0:", present_pairs(m))
    for key, module, dim in calls:
        print(f"  launch {key.split('__')[0]:22s} module {module.split('_')[-1]:>9s}  dim = {dim}")
    ncol = min(int(d.ncollision.numpy()[0]), d.naconmax)
    nacon = min(int(d.nacon.numpy()[0]), d.naconmax)
    pair = ctxs[0].collision_pair.numpy()[:ncol]
    wid = ctxs[0].collision_worldid.numpy()[:ncol]
    types = [(G(int(mjm.geom_type[a])), G(int(mjm.geom_type[b]))) for a, b in pair]
    branch = [f"{a.name}-{b.name}" if MJ_COLLISION_TABLE[(a, b)].name == "PRIMITIVE"
              else f"none ({a.name}-{b.name} is convex)" for a, b in types]
    print(f"  d.naconmax = {d.naconmax}, d.ncollision = {ncol}, d.nacon = {nacon}")
    print("  primitive kernel, thread -> world, static branch taken:")
    for i in range(ncol):
        print(f"    tid {i:2d}  w{wid[i]}  {branch[i]}")
    print(f"    tid {ncol:2d} .. {d.naconmax - 1}: tid >= ncollision, return at once")
    cg = d.contact.geom.numpy()[:nacon]
    cw = d.contact.worldid.numpy()[:nacon]
    ctype = [f"{G(int(mjm.geom_type[a])).name}-{G(int(mjm.geom_type[b])).name}" for a, b in cg]
    kinds, counts = np.unique(ctype, return_counts=True)
    print("  contacts per type pair (both worlds):", dict(zip(kinds.tolist(), counts.tolist())))
    report[label] = {"pairs": present_pairs(m),
                     "launches": [[k.split("__")[0], mod.split("_")[-1], np.atleast_1d(n).tolist()]
                                  for k, mod, n in calls],
                     "naconmax": int(d.naconmax), "ncollision": ncol, "nacon": nacon,
                     "threads": [[int(wid[i]), branch[i]] for i in range(ncol)],
                     "contacts": [[int(cw[i]), ctype[i]] for i in range(nacon)]}

prim = [k for k in warp_util._KERNEL_CACHE if k[-1] == "_primitive_narrowphase"]
print("compiled _primitive_narrowphase variants in the cache_kernel dict:", len(prim))

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(report, f, separators=(",", ":"))
    print("wrote", args.dump_json)
