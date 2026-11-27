"""Example 16.6 - margin and gap: detected vs active contacts, and the strict-< boundary.

write_contact (collision_core.py) decides, per contact:
    detected = dist < margin + gap                     -> a slot in d.contact is used
    active   = dist < margin  (or, with adhesion != 0, dist < margin + gap)
make_constraint then builds constraint rows only for active contacts (dist < includemargin, with
includemargin = margin). A sphere (margin 0.02, gap 0.03) hovers above a floor at a different
height in each world; we compare MJWarp with MuJoCo C (mj_forward) world by world, then repeat
with adhesion so in-gap contacts become active with condim 1.
Run: python ex6_margin_gap.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

HOVER = """
<mujoco model="margin_gap">
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size="0.1" margin="0.02" gap="0.03" adhesion="{adh}"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

GAPS = np.array([-0.005, 0.01, 0.019, 0.021, 0.04, 0.049, 0.05, 0.051, 0.06])  # surface gap
NWORLD = len(GAPS)
rows = {}

for adh in [0.0, 0.5]:
    mjm = mujoco.MjModel.from_xml_string(HOVER.format(adh=adh))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
    qpos = np.tile(mjm.qpos0, (NWORLD, 1))
    qpos[:, 2] = 0.1 + GAPS
    d.qpos.assign(qpos.astype(np.float32))
    mjw.forward(m, d)                        # kinematics -> collision -> constraints -> solve

    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    wid = d.contact.worldid.numpy()[:n]
    cdist = dict(zip(wid, d.contact.dist.numpy()[:n]))
    cdim = dict(zip(wid, d.contact.dim.numpy()[:n]))
    incl = d.contact.includemargin.numpy()[:n]
    nefc = d.nefc.numpy()

    mjd = mujoco.MjData(mjm)
    print(f"adhesion = {adh}   (margin 0.02, gap 0.03, includemargin = {incl[0] if n else '-'})")
    print("  gap      MJWarp: dist      detected dim nefc | C: ncon nefc")
    out = []
    for w, g in enumerate(GAPS):
        mjd.qpos[:] = qpos[w]
        mujoco.mj_forward(mjm, mjd)
        det = w in cdist
        dstr = f"{cdist[w]: .6f}" if det else "    -    "
        dim = cdim[w] if det else "-"
        print(f"  {g:6.3f}   {dstr}   {str(det):5s}   {dim}  {nefc[w]:3d}  |"
              f"    {mjd.ncon}   {mjd.nefc:3d}")
        out.append({"gap": float(g), "detected": bool(det), "nefc": int(nefc[w]),
                    "c_ncon": int(mjd.ncon), "c_nefc": int(mjd.nefc)})
    rows[str(adh)] = out
    print("  overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

print("boundary row (gap 0.05): MJWarp keeps dist < margin + gap (strict, float32); C uses float64")
print(f"  float32 (MJWarp): dist = {np.float32(0.15) - np.float32(0.1):.9f}"
      f"  vs  margin + gap = {np.float32(0.02) + np.float32(0.03):.9f}  -> dropped")
print(f"  float64 (C):      dist = {0.15 - 0.1:.17f}  vs  margin + gap = {0.02 + 0.03:.17f}"
      "  -> kept")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"margin": 0.02, "gap": 0.03, "rows": rows}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
