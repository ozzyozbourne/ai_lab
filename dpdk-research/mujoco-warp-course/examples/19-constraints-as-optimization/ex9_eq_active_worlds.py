"""Example 19.9 - per-world eq_active seen through the efc strip: where each row block lands.

Ch 8 ex6 toggled the MOCAP_TARGET weld per world and counted d.ne. Here the welded box rests on
the floor, so every world also has 4 contacts (condim 3, pyramidal: 4 rows each). The weld
block (6 rows) always comes first, because make_constraint launches the equality kernels before
the contact kernels. In worlds where the weld is off, the block disappears and every contact's
contact.efc_address shifts down by 6. We print, per world, the row blocks and the first row of
each contact.
Run: python ex9_eq_active_worlds.py [--dump-json PATH]
  --dump-json PATH writes the per-world row blocks for the efc strip figure (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

MOCAP_TARGET = """
<mujoco model="mocap_target">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="target" mocap="true" pos="0 0 0.0495">
      <geom type="box" size=".05 .05 .05" contype="0" conaffinity="0" rgba="0 1 0 .3"/>
    </body>
    <body name="box" pos="0 0 0.0495">
      <freejoint/>
      <geom name="box" type="box" size=".05 .05 .05" mass="0.5" rgba=".3 .3 1 1"/>
    </body>
  </worldbody>
  <equality><weld body1="box" body2="target" solref="0.02 1"/></equality>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
SHOW = 4                                    # worlds printed

mjm = mujoco.MjModel.from_xml_string(MOCAP_TARGET)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)

active = np.ones((NWORLD, mjm.neq), dtype=bool)
active[1::2, 0] = False                     # odd worlds: weld off (recall Ch 8 ex6)
d.eq_active.assign(active)
mjw.forward(m, d)

TYPE = {int(v): k[len("mjCNSTR_"):] for k, v in mujoco.mjtConstraint.__members__.items()}
ne, nefc = d.ne.numpy(), d.nefc.numpy()
nacon = int(d.nacon.numpy()[0])
cw = d.contact.worldid.numpy()[:nacon]
ca = d.contact.efc_address.numpy()[:nacon]
etype = d.efc.type.numpy()

print("eq_active[:, 0]:", active[:SHOW, 0].astype(int), "| ne:", ne[:SHOW], "| nefc:", nefc[:SHOW])
print("world  eq_active  row blocks (kind[first:last])           contacts: id -> first row")
strip = []
for w in range(SHOW):
    blocks, r = [], 0
    if ne[w]:
        blocks.append(["eq", int(ne[w]), "weld"])
        r = int(ne[w])
    cons = sorted((int(ca[c, 0]), c) for c in range(nacon) if cw[c] == w)
    for first, c in cons:
        blocks.append(["contact", 4, f"c{c}"])
    txt = " ".join(f"{b[0]}[{s}:{s + b[1] - 1}]" for b, s in
                   zip(blocks, np.cumsum([0] + [b[1] for b in blocks[:-1]])))
    links = " ".join(f"c{c}->{first}" for first, c in cons)
    print(f"  {w}       {int(active[w, 0])}      {txt:40s} {links}")
    strip.append(blocks)
row_types = sorted({TYPE[int(t)] for t in etype[0, :nefc[0]]})
print("row types in world 0:", row_types)
first_rows = {w: sorted(int(ca[c, 0]) for c in range(nacon) if cw[c] == w) for w in range(SHOW)}
print("first contact row, weld on vs off:", first_rows[0][0], "vs", first_rows[1][0],
      f"(shift = ne = {int(ne[0])})")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as fh:
        json.dump({"njmax": int(d.njmax), "eq_active": active[:SHOW, 0].astype(int).tolist(),
                   "rows": strip, "first_rows": [first_rows[w] for w in range(SHOW)]},
                  fh, separators=(",", ":"))
    print("wrote", args.dump_json)
