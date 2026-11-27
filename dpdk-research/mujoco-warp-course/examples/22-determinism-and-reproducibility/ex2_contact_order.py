"""Example 22.2 - contact slot order: raw pool order vs a canonical (sorted) order.

box_stack(5) in NWORLD worlds, each world nudged differently, runs NSTEP steps twice from the
same start. Every contact takes the next free slot of the shared pool through
wp.atomic_add(nacon_out, 0, 1) (collision_core.write_contact), so on a GPU the slot order depends
on thread timing. We compare the two runs in raw slot order and after sorting every contact by
(worldid, geom pair, position). On a GPU the raw order usually differs while the sorted contacts
match; on Warp's CPU device the threads run in index order, so both orders match. The pool is
not grouped by world even on CPU: one kernel per geom-type pair fills it for all worlds.
Run: python ex2_contact_order.py [--dump-json PATH]
  --dump-json PATH writes slot worldids and geom pairs of a 2-world run (contact-order figure).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 200 if ON_GPU else 40

mjm = mujoco.MjModel.from_xml_string(box_stack(5))
m = mjw.put_model(mjm)


def contacts_after(nworld: int, nstep: int):
    """Run box_stack from a per-world nudged start; return the live contacts in slot order."""
    d = mjw.make_data(mjm, nworld=nworld, nconmax=32, njmax=128)
    qvel = np.zeros((nworld, mjm.nv), dtype=np.float32)
    qvel[:, 0::6] = np.linspace(0.0, 0.05, nworld)[:, None]   # each world slides a bit differently
    d.qvel.assign(qvel)
    for _ in range(nstep):
        mjw.step(m, d)
    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    c = d.contact
    out = {"worldid": c.worldid.numpy()[:n], "geom": c.geom.numpy()[:n],
           "pos": c.pos.numpy()[:n], "dist": c.dist.numpy()[:n]}
    assert not d.overflow.numpy().any(), "overflow: raise nconmax/njmax"
    return out


def canonical(c):
    """Permutation that sorts contacts by (worldid, geom0, geom1, pos.x, pos.y, pos.z)."""
    p = c["pos"]
    return np.lexsort((p[:, 2], p[:, 1], p[:, 0], c["geom"][:, 1], c["geom"][:, 0], c["worldid"]))


a, b = contacts_after(NWORLD, NSTEP), contacts_after(NWORLD, NSTEP)
print(f"device: {wp.get_device()} | nworld {NWORLD} | {NSTEP} steps"
      f" | contacts run A {len(a['dist'])}, run B {len(b['dist'])}")
same_raw = all(np.array_equal(a[k], b[k]) for k in a)
pa, pb = canonical(a), canonical(b)
same_sorted = all(np.array_equal(a[k][pa], b[k][pb]) for k in a)
print("raw slot order identical in both runs:", same_raw)
print("contacts identical after canonical sort:", same_sorted)
print("first 12 slots, worldid:", a["worldid"][:12].tolist())
print("pool grouped by world (worldid never decreases)?", bool(np.all(np.diff(a["worldid"]) >= 0)))
w0 = a["worldid"] == 0
print("world 0: slots", np.flatnonzero(w0).tolist())
print("world 0 geom pairs in slot order:", [tuple(g) for g in a["geom"][w0].tolist()])
print("contacts per world:", np.bincount(a["worldid"], minlength=NWORLD).tolist())

if args.dump_json:
    c = contacts_after(2, NSTEP)
    out = {"nworld": 2, "nstep": NSTEP, "worldid": c["worldid"].tolist(),
           "geom": c["geom"].tolist(), "canonical": canonical(c).tolist()}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(out["worldid"]), "contacts")
