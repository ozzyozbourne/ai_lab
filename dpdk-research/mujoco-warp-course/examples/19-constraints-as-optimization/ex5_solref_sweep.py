"""Example 19.5 - a per-world solref sweep: the contact's time constant sets how deep a ball sinks.

BALL_DROP (from 0.3 m) with geom_solref batched over worlds: world w uses timeconst
tc_w in [0.005, 0.1] s, dampratio 1. Stiffness k = 1/(dmax^2 tc^2 dr^2) falls as 1/tc^2, so the
ball sinks deeper and rings longer as tc grows. We print the maximum and final penetration and
the static penetration predicted by the soft-constraint model (a* = 0 at rest).
Run: python ex5_solref_sweep.py [--dump-json PATH]
  --dump-json PATH writes the penetration over time per world for the sweep figure (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 0.3">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD = 8                                       # one world per time constant
NSTEP = 400                                      # 0.8 s: fall 0.2 m, land, settle
TC = np.geomspace(0.005, 0.1, NWORLD)

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm, batch_sizes={"geom_solref": NWORLD})
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
solref = m.geom_solref.numpy()                   # (NWORLD, ngeom, 2)
solref[:, :, 0] = TC[:, None]                    # floor and ball: same solref, so the mix is TC
solref[:, :, 1] = 1.0
m.geom_solref.assign(solref)
print("geom_solref shape:", m.geom_solref.shape)

pen = np.zeros((NSTEP, NWORLD))
for i in range(NSTEP):
    mjw.step(m, d)
    pen[i] = 0.1 - d.qpos.numpy()[:, 2]          # reads to host each step: demo only
wp.synchronize()

# static penetration: 0 = m a0 + D aref with aref = -k imp pos, D = imp / ((1 - imp) invweight)
dmin, dmax, width, mid, power = mjm.geom_solimp[1]


def imp_of(p):
    x = min(abs(p) / width, 1.0)
    if x <= mid:
        return dmin + (dmax - dmin) * x**power / mid ** (power - 1)
    return dmin + (dmax - dmin) * (1 - (1 - x) ** power / (1 - mid) ** (power - 1))


g = -mjm.opt.gravity[2]
print("  world  timeconst   k [1/s^2]   max pen [mm]  final pen [mm]  static model [mm]")
for w in range(NWORLD):
    tc = max(TC[w], 2 * mjm.opt.timestep)
    k = 1.0 / (dmax**2 * tc**2)
    p = 1e-4
    for _ in range(200):                         # fixed point p = g (1 - imp) / (k imp^2)
        imp = imp_of(p)
        p = 0.5 * p + 0.5 * g * (1 - imp) / (k * imp**2)
    print(f"  {w:5d}   {TC[w]:.4f}   {k:10.1f}    {pen[:, w].max()*1e3:9.3f}     "
          f"{pen[-1, w]*1e3:9.3f}       {p*1e3:9.3f}")
print("max penetration grows with timeconst:", bool(np.all(np.diff(pen.max(axis=0)) > 0)))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    t0 = 80                                      # skip the free fall before landing
    frames = pen[t0::4].round(5) * 1e3           # mm, every 4th step
    with open(args.dump_json, "w") as fh:
        json.dump({"nworld": NWORLD, "dt": 4 * float(mjm.opt.timestep),
                   "t0": t0 * float(mjm.opt.timestep), "tc": TC.round(4).tolist(),
                   "frames": frames.round(3).tolist()}, fh, separators=(",", ":"))
    print("wrote", args.dump_json)
