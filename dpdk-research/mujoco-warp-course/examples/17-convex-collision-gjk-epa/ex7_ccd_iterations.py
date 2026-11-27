"""Example 17.7 - how many GJK/EPA iterations does a deep cylinder-box contact need?

A cylinder (r = 0.05) lies along x on the top edge of a box that is turned 45 degrees, so the
edge points up. Where they touch, A - B is curved (the cylinder's round side), so EPA must
approximate a curved surface with flat faces: more iterations, smaller error. The exact depth
is r - |(y, z) of the axis relative to the edge line|. Each world uses a different depth.
MULTICCD is disabled so each pair writes the single EPA contact (multi-contact would replace
the depth with clipped polygon distances, Example 17.9). We rebuild the model with
opt.ccd_iterations = 4, 8 and 35 (the default) using io.override_model, which edits the
model in place and returns None. ccd_iterations bounds both
the GJK loop and, for any model that is not box-box only, the EPA loop; it is a compile-time
constant of the CCD kernel, so each value builds a new kernel.
Run: python ex7_ccd_iterations.py [--dump-json PATH]
  --dump-json PATH writes depth and error per ccd_iterations value for the page's error chart.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.io import override_model  # private API

np.set_printoptions(precision=4, suppress=True)
parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

CYL_ON_EDGE = """
<mujoco model="cyl_on_edge">
  <option><flag multiccd="disable"/></option>
  <worldbody>
    <geom name="ridge" type="box" size="0.3 0.1 0.1" euler="45 0 0"/>
    <body name="cyl" pos="0 0 0.2"><freejoint/>
      <geom name="cyl" type="cylinder" size="0.05 0.1"/></body>
  </worldbody>
</mujoco>
"""
R = 0.05
EDGE_Z = 0.1 * np.sqrt(2)                # the ridge's top edge: the line y = 0, z = EDGE_Z
DEPTHS = [0.005, 0.015, 0.03]            # wanted penetration, one per world
Y_OFF = 0.01                             # axis slightly off the edge: normal is not vertical

mjm = mujoco.MjModel.from_xml_string(CYL_ON_EDGE)
qpos = np.tile(mjm.qpos0, (len(DEPTHS), 1))
for w, depth in enumerate(DEPTHS):
    dz = np.sqrt((R - depth) ** 2 - Y_OFF ** 2)  # axis-to-edge distance is R - depth
    qpos[w, :3] = [0.0, Y_OFF, EDGE_Z + dz]
    qpos[w, 3:7] = [np.cos(np.pi / 4), 0, np.sin(np.pi / 4), 0]   # axis along x
exact = np.array(DEPTHS)

print("exact depth per world:", DEPTHS)
dump = {"exact": DEPTHS, "runs": []}
for iters in [4, 8, 35]:
    m = mjw.put_model(mjm)
    ret = override_model(m, [f"opt.ccd_iterations={iters}"])
    d = mjw.make_data(mjm, nworld=len(DEPTHS), nconmax=8, njmax=48)
    d.qpos.assign(qpos.astype(np.float32))
    mjw.kinematics(m, d)
    mjw.collision(m, d)
    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    wid, dist = d.contact.worldid.numpy()[:n], d.contact.dist.numpy()[:n]
    deepest = np.array([dist[wid == w].min() if (wid == w).any() else np.nan
                        for w in range(len(DEPTHS))])
    err = np.abs(-deepest - exact)
    print(f"ccd_iterations={m.opt.ccd_iterations:2d} (override_model returned {ret})  "
          f"contacts/world={[int((wid == w).sum()) for w in range(len(DEPTHS))]}  "
          f"depth={(-deepest).round(5)}  |error|={err.round(6)}")
    dump["runs"].append({"ccd_iterations": iters,
                         "depth": [None if np.isnan(v) else round(float(-v), 6) for v in deepest],
                         "error": [None if np.isnan(v) else round(float(v), 6) for v in err]})
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
