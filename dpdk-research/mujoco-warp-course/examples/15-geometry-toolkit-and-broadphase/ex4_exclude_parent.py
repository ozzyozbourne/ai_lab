"""Example 15.4 - the other model-time filters: same body (weld), dof-less, parent-child,
<exclude>, and the FILTERPARENT disable flag.

A 3-link arm with a gripper geom on its last link, a static wall, the floor, a free box and a
mocap target (a body with no dofs of its own).
We recompute the reason each pair is dropped with NumPy (mirroring io.py::put_model) and check it
against m.nxn_pairid. Then we compile again with parent filtering disabled.
Run: python ex4_exclude_parent.py [--dump-json PATH]
  --dump-json PATH writes the geoms, bits and per-pair reasons for the page's NXN matrix.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

ARM = """
<mujoco model="arm_scene">
  <worldbody>
    <geom name="floor" type="plane" size="3 3 .1"/>
    <geom name="wall" type="box" pos="1.5 0 .5" size=".1 1 .5"/>
    <body name="link1" pos="0 0 .3">
      <joint name="j1" type="hinge" axis="0 1 0"/>
      <geom name="link1" type="capsule" fromto="0 0 0 .4 0 0" size=".05"/>
      <body name="link2" pos=".4 0 0">
        <joint name="j2" type="hinge" axis="0 1 0"/>
        <geom name="link2" type="capsule" fromto="0 0 0 .4 0 0" size=".05"/>
        <body name="link3" pos=".4 0 0">
          <joint name="j3" type="hinge" axis="0 1 0"/>
          <geom name="link3" type="capsule" fromto="0 0 0 .3 0 0" size=".05"/>
          <geom name="gripper" type="box" pos=".33 0 0" size=".03 .06 .03"/>
        </body>
      </body>
    </body>
    <body name="box" pos=".5 .6 .2"><freejoint/><geom name="box" type="box" size=".1 .1 .1"/></body>
    <body name="target" mocap="true" pos="-.5 0 .5"><geom name="target" type="sphere" size=".05"/></body>
  </worldbody>
  <contact><exclude body1="link1" body2="link3"/></contact>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()


def reasons(mjm):
    """Why each upper-triangle pair is dropped, mirroring io.py::put_model (first reason wins)."""
    g1, g2 = np.triu_indices(mjm.ngeom, k=1)
    b1, b2 = mjm.geom_bodyid[g1], mjm.geom_bodyid[g2]
    w1, w2 = mjm.body_weldid[b1], mjm.body_weldid[b2]
    wp1, wp2 = mjm.body_weldid[mjm.body_parentid[w1]], mjm.body_weldid[mjm.body_parentid[w2]]
    filterparent = not (mjm.opt.disableflags & mujoco.mjtDisableBit.mjDSBL_FILTERPARENT)
    mask = ((mjm.geom_contype[g1] & mjm.geom_conaffinity[g2])
            | (mjm.geom_contype[g2] & mjm.geom_conaffinity[g1])) != 0
    out = []
    for k in range(len(g1)):
        if not mask[k]:
            out.append("contype")
        elif w1[k] == w2[k]:
            out.append("same body")
        elif mjm.body_dofnum[w1[k]] == 0 and mjm.body_dofnum[w2[k]] == 0:
            out.append("no dofs")
        elif filterparent and w1[k] != 0 and w2[k] != 0 and (w1[k] == wp2[k] or w2[k] == wp1[k]):
            out.append("parent-child")
        elif ((b1[k] << 16) + b2[k]) in mjm.exclude_signature:
            out.append("exclude")
        else:
            out.append("kept")
    return g1, g2, out


def show(mjm, title):
    m = mjw.put_model(mjm)
    names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(mjm.ngeom)]
    g1, g2, why = reasons(mjm)
    pid = m.nxn_pairid.numpy()[:, 0]
    assert np.array_equal(pid == -2, np.array(why) != "kept"), "mirror disagrees with put_model"
    print(f"--- {title}: kept {m.nxn_geom_pair_filtered.shape[0]} of {len(g1)} pairs")
    dropped = {}
    for i, j, w in zip(g1, g2, why):
        if w != "kept":
            dropped.setdefault(w, []).append(f"{names[i]}-{names[j]}")
    for w, lst in dropped.items():
        print(f"  {w:12s}: {', '.join(lst)}")
    return m, names, g1, g2, why


mjm = mujoco.MjModel.from_xml_string(ARM)
print("geom -> body:", {mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g):
                        mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_BODY, mjm.geom_bodyid[g])
                        for g in range(mjm.ngeom)})
print("exclude_signature:", mjm.exclude_signature.tolist(), "= (body1 << 16) + body2")
m, names, g1, g2, why = show(mjm, "default")

mjm_np = mujoco.MjModel.from_xml_string(ARM)
mjm_np.opt.disableflags |= mujoco.mjtDisableBit.mjDSBL_FILTERPARENT
show(mjm_np, "FILTERPARENT disabled")

if args.dump_json:
    out = {"names": names, "ngeom": mjm.ngeom,
           "body": [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_BODY, b) for b in mjm.geom_bodyid],
           "contype": mjm.geom_contype.tolist(), "conaffinity": mjm.geom_conaffinity.tolist(),
           "pairs": [[int(i), int(j), w] for i, j, w in zip(g1, g2, why)]}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
