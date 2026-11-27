"""Example 23.3 - drop a 6x6 cloth on a sphere and size the contact and row buffers.

The cloth is a flexcomp type="grid" dim="2" (36 vertices, 50 triangles) whose edge lengths
are held by edge equality constraints. It starts 0.05 above a fixed sphere, so it touches
within the first 0.1 s, then drapes over it and the floor plane. We pass explicit nconmax and
njmax, step 300 times at dt = 0.002 and decode d.overflow (Ch 9).
Run: python ex3_cloth_drop.py [--dump-json PATH]
  --dump-json PATH writes 60 decimated frames of world 0's flexvert_xpos (cloth replay).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 300

CLOTH_ON_SPHERE = """
<mujoco model="cloth_on_sphere">
  <option timestep="0.002" solver="CG" tolerance="1e-6"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="2 2 .1"/>
    <geom name="ball" type="sphere" size=".1" pos="0 0 .2"/>
    <flexcomp name="cloth" type="grid" count="6 6 1" spacing=".06 .06 .06" pos="0 0 .35"
              radius=".01" dim="2" mass=".1">
      <edge equality="true"/>
      <contact condim="3" selfcollide="none"/>
    </flexcomp>
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
    return "\n".join(lines)


mjm = mujoco.MjModel.from_xml_string(CLOTH_ON_SPHERE)
print(f"nflexvert {mjm.nflexvert}  nflexedge {mjm.nflexedge}  nflexelem {mjm.nflexelem}  "
      f"nv {mjm.nv}  neq {mjm.neq}")
m = mjw.put_model(mjm)
d0 = mjw.make_data(mjm, nworld=1)
print(f"io.py defaults for a flex model: nconmax {d0.naconmax}, njmax {d0.njmax} per world")

NCONMAX, NJMAX = 64, 384                  # measured below; the defaults (256, 512) also fit
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=NCONMAX, njmax=NJMAX)
sphere_top = 0.3

frames, peak_nacon, peak_nefc = [], 0, 0
for i in range(NSTEP):
    mjw.step(m, d)
    if i % 30 == 29 or i == 0:          # demo only: host reads every 30 steps
        nacon = int(d.nacon.numpy()[0])
        nefc = int(d.nefc.numpy().max())
        peak_nacon, peak_nefc = max(peak_nacon, nacon), max(peak_nefc, nefc)
        zmin = d.flexvert_xpos.numpy()[0, :, 2].min()
        print(f"step {i + 1:3d}  cloth min z {zmin:.4f}  nacon {nacon:3d} (all worlds)  "
              f"max nefc {nefc}")
    if args.dump_json and i % 5 == 4:
        frames.append(np.round(d.flexvert_xpos.numpy()[0].astype(np.float64), 3).tolist())
wp.synchronize()

xyz = d.flexvert_xpos.numpy()
r = np.linalg.norm(xyz[0] - np.array([0, 0, 0.2]), axis=1)
print(f"final: min z {xyz[:, :, 2].min():.4f}, closest vertex to sphere centre {r.min():.4f} "
      f"(radius 0.1 + cloth radius 0.01)")
print(f"centre vertex rests at z {xyz[0, :, 2].max():.4f}  (sphere top {sphere_top})")
print(f"peak nacon {peak_nacon} of naconmax {d.naconmax}; peak nefc {peak_nefc} of njmax {d.njmax}")
print("overflow:", describe_overflow(d))

if args.dump_json:
    with open(args.dump_json, "w") as f:
        elem = mjm.flex_elem[: 3 * mjm.nflexelem].reshape(-1, 3).tolist()   # triangles
        json.dump({"nworld": 1, "dt": 5 * float(mjm.opt.timestep), "kind": "mesh3d",
                   "elem": elem, "radius": 0.01, "sphere": [0, 0, 0.2, 0.1], "frames": frames},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
