"""Example 2.7 - contacts are soft: a resting ball sinks a little into the floor.

Drops BALL_DROP, lets it settle for 1 s and prints the contact MuJoCo found: the geom pair,
dist (negative = penetration), the normal frame[0:3] and the constraint rows. Then it halves the
solref time constant (0.02 -> 0.01, a stiffer contact) and shows the smaller penetration.
Run: python ex7_contacts_soft.py [--dump-json PATH]
  --dump-json PATH  writes the penetration for a sweep of timeconst values (chapter slider, Rule D)
"""
import argparse
import json

import mujoco
import numpy as np

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()


def settle(timeconst=None, dampratio=1.0, seconds=1.0):
    """Drop the ball and return (MjModel, MjData) after `seconds` of simulation."""
    mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
    if timeconst is not None:
        mjm.geom_solref[:] = [timeconst, dampratio]   # both geoms; MuJoCo mixes the pair
    mjd = mujoco.MjData(mjm)
    for _ in range(int(seconds / mjm.opt.timestep)):
        mujoco.mj_step(mjm, mjd)
    return mjm, mjd


mjm, mjd = settle()
print("default geom solref (timeconst, dampratio):", mjm.geom_solref[1])
print("default geom solimp:", mjm.geom_solimp[1])
print("ncon =", mjd.ncon, "| nefc =", mjd.nefc, "(pyramidal cone, condim 3 -> 4 rows per contact)")
c = mjd.contact[0]
g1 = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, c.geom[0])
g2 = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, c.geom[1])
print(f"contact 0: geoms ({g1}, {g2})  dist = {c.dist:.5f} m  normal = {c.frame[:3]}")
print(f"ball z = {mjd.qpos[2]:.5f} (radius 0.1, so it sits {0.1 - mjd.qpos[2]:.5f} m deep)")

mjm2, mjd2 = settle(timeconst=0.01)
print(f"solref timeconst 0.01: dist = {mjd2.contact[0].dist:.5f} m  "
      f"(ratio {mjd2.contact[0].dist / c.dist:.2f})")

if args.dump_json:
    # For each (timeconst, dampratio): the ball height over the first 1.2 s (every 6th step,
    # 100 samples) and the resting penetration after 3 s.
    out = {"series_dt": 6 * float(mjm.opt.timestep), "runs": []}
    for tc in [0.005, 0.01, 0.02, 0.04, 0.08]:
        for dr in [0.3, 1.0]:
            m3 = mujoco.MjModel.from_xml_string(BALL_DROP)
            m3.geom_solref[:] = [tc, dr]
            d3 = mujoco.MjData(m3)
            zs = []
            for i in range(1500):   # 3 s
                mujoco.mj_step(m3, d3)
                if i < 600 and i % 6 == 0:
                    zs.append(round(float(d3.qpos[2]), 4))
            out["runs"].append({"timeconst": tc, "dampratio": dr, "z": zs,
                                "rest_dist": round(float(d3.qpos[2]) - 0.1, 6)})
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(out["runs"]), "runs")
