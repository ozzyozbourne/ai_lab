"""Example 26.7 - drop contacts with m.callback.contactfilter by clearing the CONSTRAINT bit.

collision_driver.collision calls m.callback.contactfilter(m, d) after the narrowphase (and the
surface-velocity kernel), before make_constraint. The contact pool is append-only: nacon cannot
shrink and slots cannot be removed. To drop a contact, clear the ContactType.CONSTRAINT bit in
d.contact.type; constraint.py skips every contact with `if not (type_in[conid] &
ContactType.CONSTRAINT)`, so it gets no efc rows. Our filter launches over naconmax (the pool
capacity; threads past nacon exit) and drops every contact that touches a geom in group 3.
Scene: two boxes on a floor; the right box is in group 3, so with the filter it falls through.
Run: python ex7_contactfilter.py [--dump-json PATH]
  --dump-json PATH writes the pool (worldid, geom pair, type per slot) and nefc per world (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import ContactType   # private API: may change between releases

np.set_printoptions(precision=4, suppress=True)

TWO_BOXES = """
<mujoco model="two_boxes">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="solid" pos="-0.3 0 0.099"><freejoint/>
      <geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="ghost" pos="0.3 0 0.099"><freejoint/>
      <geom type="box" size=".1 .1 .1" group="3" rgba="1 .3 .3 .5"/></body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
NSTEP = 100                                  # 0.5 s


@wp.kernel
def drop_group(
    # Model:
    geom_group: wp.array[int],
    # Data in:
    contact_geom_in: wp.array[wp.vec2i],
    nacon_in: wp.array[int],
    # In:
    group: int,
    # Data out:
    contact_type_out: wp.array[int],
):
    conid = wp.tid()                          # launched over naconmax: exit past nacon
    if conid >= nacon_in[0]:
        return
    g = contact_geom_in[conid]
    if geom_group[g[0]] == group or geom_group[g[1]] == group:
        t = contact_type_out[conid]
        contact_type_out[conid] = t & (~int(ContactType.CONSTRAINT))   # keep SENSOR/PASSIVE


def contactfilter(m, d):
    wp.launch(drop_group, dim=d.naconmax, inputs=[m.geom_group, d.contact.geom, d.nacon, 3],
              outputs=[d.contact.type])


mjm = mujoco.MjModel.from_xml_string(TWO_BOXES)
m = mjw.put_model(mjm)
ghost = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "ghost")
dump = {"naconmax": 0, "runs": {}}

for use_filter in (False, True):
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
    m.callback.contactfilter = contactfilter if use_filter else None
    mjw.forward(m, d)
    n = d.nacon.numpy()[0]
    types = d.contact.type.numpy()[:n]
    label = "with filter   " if use_filter else "without filter"
    print(f"{label}: nacon {n} | nefc {d.nefc.numpy()[:4]} | "
          f"type[:16] {types[:16]} | CONSTRAINT {int((types & 1).sum())}")
    dump["naconmax"] = int(d.naconmax)
    dump["runs"]["filter" if use_filter else "nofilter"] = {
        "worldid": d.contact.worldid.numpy()[:n].tolist(), "type": types.tolist(),
        "geom": d.contact.geom.numpy()[:n].tolist(), "nefc": d.nefc.numpy()[:2].tolist()}
    for _ in range(NSTEP):
        mjw.step(m, d)
    z = d.xpos.numpy()[:, ghost, 2]
    print(f"{'':16}after {NSTEP} steps: ghost box z = {z[:4]} | overflow: "
          f"{'none' if not d.overflow.numpy().any() else d.overflow.numpy()}")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
