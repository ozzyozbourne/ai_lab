"""Example 21.2 - boxes land, come to rest and fall asleep one island at a time.

Six tilted boxes are dropped from different heights. Every step we read tree_asleep (the per-tree
countdown / sleep-cycle array), ntree_awake and nefc. A tree's countdown starts at
-(1 + mjMINAWAKE) = -11 and rises by one per still step; at -1 its island may sleep, and the tree
then stores the next tree of its sleep cycle (>= 0).

Run: python ex2_fall_asleep.py [--dump-json PATH]
  --dump-json PATH writes world 0's box heights, pitch angles and tree_asleep values for the
  page's sleep replay (Rule D).
"""
import argparse
import json
import math

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()  # parse_known_args: also works inside Jupyter

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
NSTEP = 160                              # enough for every box to fall asleep (default tolerance)

Z = [0.1, 0.2, 0.35, 0.5, 0.7, 0.9]      # drop heights; box i is pitched by 7*i degrees
BODIES = "".join(
    f'<body name="box{i}" pos="{0.4 * i:.2f} 0 {z}" euler="0 {7 * i} 0"><freejoint/>'
    f'<geom type="box" size=".1 .1 .1"/></body>' for i, z in enumerate(Z))
XML = ('<mujoco><option timestep="0.01" solver="Newton"><flag sleep="enable"/></option>'
       f'<worldbody><geom name="floor" type="plane" size="5 5 .1"/>{BODIES}</worldbody></mujoco>')

mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
print("ntree", mjm.ntree, "| MJ_MINAWAKE", mujoco.mjMINAWAKE,
      "| sleep_tolerance", mjm.opt.sleep_tolerance)
print("initial tree_asleep", d.tree_asleep.numpy()[0])

frames, nefc_log, awake_log, first_all_asleep = [], [], [], None
for i in range(NSTEP):
    mjw.step(m, d)
    asleep = d.tree_asleep.numpy()[0]       # host read every step: demo only
    nefc = int(d.nefc.numpy()[0])
    nawake = int(d.ntree_awake.numpy()[0])
    if i % 10 == 0:
        print(f"step {i:3d}  tree_asleep {asleep}  ntree_awake {nawake}  nefc {nefc}")
    if nawake == 0 and first_all_asleep is None:
        first_all_asleep = i
    if args.dump_json and i % 2 == 0:
        q = d.qpos.numpy()[0]
        fr = []
        for t in range(mjm.ntree):
            z, qw, qy = q[7 * t + 2], q[7 * t + 3], q[7 * t + 5]
            pitch = 2.0 * math.atan2(qy, qw)
            fr.append([round(float(z), 3), round(pitch, 3), int(asleep[t])])
        frames.append(fr)
        nefc_log.append(nefc)
        awake_log.append(nawake)
wp.synchronize()

print("all trees asleep from step", first_all_asleep)
print("final tree_asleep (all worlds equal):",
      bool((d.tree_asleep.numpy() == d.tree_asleep.numpy()[0]).all()))
print("final qvel max |v|:", float(np.abs(d.qvel.numpy()).max()))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": mjm.ntree, "dt": 2 * float(mjm.opt.timestep), "kind": "tiles",
                   "labels": [f"tree {t}" for t in range(mjm.ntree)],
                   "x": [round(0.4 * t, 2) for t in range(mjm.ntree)], "half": 0.1,
                   "frames": frames, "nefc": nefc_log, "ntree_awake": awake_log},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
