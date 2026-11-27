"""Example 9.1 - read the shared contact pool: one table row per contact, over 4 worlds.

A sphere, a box and a capsule rest on a plane. World 2 lifts the box 0.5 m, so it has fewer
contacts. We run mjw.forward once and print every field of d.contact that matters.
Run: python ex1_read_contacts.py [--dump-json PATH]
  --dump-json PATH writes the first contact's fields for the page's contact card.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import ContactType   # private API: not exported by mujoco_warp

np.set_printoptions(precision=4, suppress=True)

CONTACT_SCENE = """
<mujoco model="contact_scene">
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="sphere" pos="0 0 0.09"><freejoint/>
      <geom name="sphere" type="sphere" size="0.1"/></body>
    <body name="box" pos="1 0 0.095"><freejoint/>
      <geom name="box" type="box" size="0.1 0.1 0.1"/></body>
    <body name="capsule" pos="2 0 0.09" euler="0 90 0"><freejoint/>
      <geom name="capsule" type="capsule" size="0.1 0.2"/></body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD = 4          # the table is meant to be read: 4 worlds on CPU and GPU

mjm = mujoco.MjModel.from_xml_string(CONTACT_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[2, 9] += 0.5                       # world 2: box body (qpos 7..13) lifted 0.5 m
d.qpos.assign(qpos)
mjw.forward(m, d)                       # kinematics -> collision -> make_constraint -> solve

nacon = int(d.nacon.numpy()[0])
n = min(nacon, d.naconmax)              # the counter can exceed capacity; never read past it
print(f"naconmax = {d.naconmax} (nconmax 16 x nworld {NWORLD}) | nacon = {nacon}"
      f" | ncollision = {int(d.ncollision.numpy()[0])}")

c = d.contact
world, geom = c.worldid.numpy()[:n], c.geom.numpy()[:n]
dist, pos, frame = c.dist.numpy()[:n], c.pos.numpy()[:n], c.frame.numpy()[:n]
dim, ctype, efc = c.dim.numpy()[:n], c.type.numpy()[:n], c.efc_address.numpy()[:n]
gname = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(mjm.ngeom)]

print(" cid  w  geom[0]-geom[1]     dist     pos (midpoint)          normal = frame[0]  dim"
      "  type        efc_address")
for i in range(n):
    pair = f"{gname[geom[i, 0]]}-{gname[geom[i, 1]]}"
    p = np.array2string(pos[i], precision=3, suppress_small=True)
    nrm = np.array2string(frame[i, 0], precision=1, suppress_small=True)
    print(f"{i:4d} {world[i]:2d}  {pair:16s} {dist[i]:8.4f}  {p:22s}  {nrm:17s}  {dim[i]:3d}"
          f"  {ContactType(int(ctype[i])).name:10s}  {efc[i]}")

print("contacts per world:", np.bincount(world, minlength=NWORLD))
print("nefc per world:    ", d.nefc.numpy(), "(4 pyramidal rows per condim-3 contact)")

# One contact in full: the fields that do not fit in the table.
k = 0
print("\ncontact 0 in full")
print("  frame rows (normal, tangent1, tangent2):\n", frame[k])
print("  friction (t1, t2, spin, roll1, roll2):", c.friction.numpy()[k])
print("  solref:", c.solref.numpy()[k], " solreffriction:", c.solreffriction.numpy()[k])
print("  solimp:", c.solimp.numpy()[k])
print("  includemargin:", c.includemargin.numpy()[k], " adhesion:", c.adhesion.numpy()[k],
      " geomcollisionid:", c.geomcollisionid.numpy()[k])
print("  surfacevel:", c.surfacevel.numpy()[k])
print("  flex/elem/vert shapes (nflex = 0):", c.flex.shape, c.elem.shape, c.vert.shape)
print("  efc_address shape (naconmax, nmaxpyramid):", c.efc_address.shape)
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    def r4(a):                          # float64 before rounding: clean JSON numbers
        return np.round(np.asarray(a, dtype=float), 4).tolist()

    card = {"world": int(world[k]), "geom": [gname[g] for g in geom[k]],
            "dist": round(float(dist[k]), 4),
            "pos": r4(pos[k]), "frame": r4(frame[k]),
            "friction": r4(c.friction.numpy()[k]), "dim": int(dim[k]),
            "type": int(ctype[k]), "solref": r4(c.solref.numpy()[k]),
            "solreffriction": r4(c.solreffriction.numpy()[k]),
            "solimp": r4(c.solimp.numpy()[k]),
            "includemargin": float(c.includemargin.numpy()[k]),
            "surfacevel": r4(c.surfacevel.numpy()[k]),
            "efc_address": efc[k].tolist(), "nefc_world0": int(d.nefc.numpy()[0]),
            "rows": [{"cid": int(i), "w": int(world[i]), "pair": [gname[g] for g in geom[i]],
                      "dist": round(float(dist[i]), 4), "efc": efc[i].tolist()} for i in range(n)]}
    with open(args.dump_json, "w") as f:
        json.dump(card, f, separators=(",", ":"))
    print("wrote", args.dump_json)
