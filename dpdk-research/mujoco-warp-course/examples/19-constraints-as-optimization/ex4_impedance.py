"""Example 19.4 - the impedance curve imp(x) from solimp, and the D it produces, vs d.efc.D.

solimp = (dmin, dmax, width, mid, power) shapes how "hard" a constraint is as it is violated
more deeply. We use a wide transition (width 1 cm) so the curve is visible, press a ball into
the floor by a different depth in each world, and compare D = imp / ((1 - imp) * invweight)
computed in NumPy with d.efc.D. condim="1" on both geoms gives one row per contact.
Run: python ex4_impedance.py [--dump-json PATH] [--plot PNG]
  --dump-json PATH writes the curve and the measured points for the impedance figure (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

SOLIMP = (0.5, 0.95, 0.01, 0.3, 3.0)          # dmin dmax width mid power
BALL = f"""
<mujoco model="ball_imp">
  <option timestep="0.002"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1" condim="1" solimp="{' '.join(map(str, SOLIMP))}"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" condim="1"
            solimp="{' '.join(map(str, SOLIMP))}"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
parser.add_argument("--plot", default=None)
args, _ = parser.parse_known_args()


def impedance(x, solimp):
    """NumPy copy of the imp branch of constraint.py::_contact_kbimp; x = |pos| / width."""
    dmin, dmax, width, mid, power = solimp
    x = np.clip(np.asarray(x, dtype=float), 0.0, 1.0)
    lo = dmin + (dmax - dmin) * x**power / mid ** (power - 1)
    hi = dmin + (dmax - dmin) * (1 - (1 - x) ** power / (1 - mid) ** (power - 1))
    return np.where(x <= mid, lo, hi)


PEN = np.array([0.0005, 0.001, 0.002, 0.003, 0.005, 0.007, 0.01, 0.015])
NWORLD = len(PEN)

mjm = mujoco.MjModel.from_xml_string(BALL)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=2, njmax=4)
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 2] = 0.1 - PEN
d.qpos.assign(qpos)
mjw.forward(m, d)

invweight = float(m.body_invweight0.numpy()[0, 1, 0])
imp_np = impedance(PEN / SOLIMP[2], SOLIMP)
D_np = imp_np / ((1 - imp_np) * invweight)
D_mjw = d.efc.D.numpy()[:, 0]
print(f"solimp {SOLIMP}  invweight0 {invweight:.3f}")
print(" depth[mm]   x=|pos|/width   imp     D numpy   d.efc.D")
for w in range(NWORLD):
    print(f"  {PEN[w]*1e3:6.2f}      {PEN[w]/SOLIMP[2]:6.3f}       {imp_np[w]:.4f}  {D_np[w]:8.3f}"
          f"  {D_mjw[w]:8.3f}")
print(f"max relative difference in D: {np.abs(D_np - D_mjw).max() / D_mjw.max():.1e}")
print("D grows from dmin/(1-dmin) =", round(SOLIMP[0] / (1 - SOLIMP[0]), 3),
      "to dmax/(1-dmax) =", round(SOLIMP[1] / (1 - SOLIMP[1]), 3), "(times 1/invweight)")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

xs = np.linspace(0, 1.2, 61)
curve = impedance(xs, SOLIMP)
if args.dump_json:
    with open(args.dump_json, "w") as fh:
        json.dump({"solimp": SOLIMP, "x": xs.round(4).tolist(), "imp": curve.round(5).tolist(),
                   "pts": [[round(float(p / SOLIMP[2]), 4), round(float(i), 5), round(float(Dm), 4)]
                           for p, i, Dm in zip(PEN, imp_np, D_mjw)]}, fh, separators=(",", ":"))
    print("wrote", args.dump_json)
if args.plot:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        plt.plot(xs, curve, label="imp(x)")
        plt.plot(PEN / SOLIMP[2], D_mjw * invweight / (1 + D_mjw * invweight), "o",
                 label="from d.efc.D")
        plt.xlabel("x = |pos| / width"); plt.ylabel("impedance"); plt.legend()
        plt.savefig(args.plot, dpi=80)
        print("saved", args.plot)
    except ImportError:
        print("skipped: matplotlib not installed")
