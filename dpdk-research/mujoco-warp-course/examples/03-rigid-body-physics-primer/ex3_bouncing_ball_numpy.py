"""Example 3.3 - a ball on a penalty-spring floor in NumPy, next to the same drop in MuJoCo/MJWarp.

The NumPy floor is a spring-damper that pushes up only while the ball is below the floor. Its
stiffness k and damping b come from a time constant and a damping ratio with the same formula
MuJoCo uses for solref (with dmax = solimp[1] set to 1):  k/m = 1 / (timeconst * dampratio)^2,
b/m = 2 / timeconst. MuJoCo's default solref is (0.02, 1).
Run: python ex3_bouncing_ball_numpy.py [--dump-json PATH]
  --dump-json PATH writes the height traces for the page's figure (Rule D).
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

G, R, Z0 = 9.81, 0.1, 1.0     # gravity, ball radius, start height of the centre
DT, T = 0.002, 1.5
NSTEP = round(T / DT)


def numpy_ball(timeconst, dampratio):
    """Semi-implicit Euler with a one-sided spring-damper floor. Returns heights and penetration."""
    k = 1.0 / (timeconst * dampratio) ** 2       # per unit mass [1/s^2]
    b = 2.0 / timeconst                          # per unit mass [1/s]
    z, v = Z0, 0.0
    zs = [z]
    for _ in range(NSTEP):
        pen = R - z                              # > 0 when the ball is inside the floor
        a = -G
        if pen > 0:
            a += max(0.0, k * pen - b * v)       # push only, never pull (one-sided)
        v += a * DT
        z += v * DT
        zs.append(z)
    return np.array(zs)


def bounce_peaks(zs):
    """Heights of the local maxima after the first impact (bounce apex of the centre)."""
    i0 = int(np.argmax(zs < R + 1e-3))
    peaks = [zs[i] for i in range(i0 + 1, len(zs) - 1) if zs[i - 1] < zs[i] >= zs[i + 1]]
    return [round(float(p), 3) for p in peaks if p > R + 1e-3][:4]


print(f"NumPy penalty floor, dt = {DT} s, {NSTEP} steps, ball radius {R} m, drop from {Z0} m")
traces = {}
for tc, dr in [(0.02, 1.0), (0.02, 0.3), (0.02, 0.15)]:
    zs = numpy_ball(tc, dr)
    traces[f"{tc}_{dr}"] = zs
    print(f"  solref ({tc}, {dr:<4}): k/m = {1 / (tc * dr) ** 2:6.0f} 1/s^2  "
          f"b/m = {2 / tc:.0f} 1/s  "
          f"max penetration = {1000 * (R - zs.min()):5.2f} mm  "
          f"bounce apexes [m] = {bounce_peaks(zs)}")

# --- the same drop in C MuJoCo (default solref 0.02, 1) ---
mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
mjd = mujoco.MjData(mjm)
z_c, pen_c = [], 0.0
for _ in range(NSTEP):
    mujoco.mj_step(mjm, mjd)
    z_c.append(mjd.qpos[2])
    if mjd.ncon:
        pen_c = max(pen_c, -mjd.contact.dist.min())

# --- and in MJWarp, one world ---
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=4, njmax=16)
z_w, pen_w = [], 0.0
for _ in range(NSTEP):
    mjw.step(m, d)
    z_w.append(float(d.qpos.numpy()[0, 2]))        # reads to host every step: demo only
    n = int(d.nacon.numpy()[0])
    if n:
        pen_w = max(pen_w, -float(d.contact.dist.numpy()[:n].min()))

zn = traces["0.02_1.0"]
print("max penetration, same drop, default solref (0.02, 1):")
print(f"  NumPy penalty floor : {1000 * (R - zn.min()):.2f} mm   rest {1000 * (R - zn[-1]):.2f} mm")
print(f"  C MuJoCo            : {1000 * pen_c:.2f} mm   rest {1000 * (R - z_c[-1]):.2f} mm")
print(f"  MJWarp (1 world)    : {1000 * pen_w:.2f} mm   rest {1000 * (R - z_w[-1]):.2f} mm")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    every = 10          # 0.02 s per frame
    out = {"dt": DT * every, "radius": R,
           "numpy": {k: [round(float(z), 4) for z in v[::every]] for k, v in traces.items()},
           "mujoco": [round(float(z), 4) for z in z_c[::every]],
           "mjwarp": [round(float(z), 4) for z in z_w[::every]]}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
