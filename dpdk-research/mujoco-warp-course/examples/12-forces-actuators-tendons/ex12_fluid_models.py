"""Example 12.12 - fluid forces: per-world density, inertia box vs ellipsoid, and wind.

passive.py::_fluid_force (one thread per (world, body)) has two models:
  * inertia box (default): the body is replaced by the box with the same inertia; drag is
    0.5 * density * (face area) * |v| v plus a viscous 3 pi diam viscosity v term.
  * ellipsoid (geom fluidshape="ellipsoid"): per-geom blunt and slender drag, Magnus lift,
    Kutta lift, added mass, with coefficients in geom fluidcoef (m.geom_fluid).
The fluid moves with opt.wind: the force depends on the velocity relative to the wind.
(a) 4 worlds with their own opt.density (replace the batched field, Ch 10).
(b) the same ball with the inertia-box model vs the ellipsoid model, density 1.2.
(c) wind = (3, 0, 0) m/s pushes a falling ball sideways.
Run: python ex12_fluid_models.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NSTEP = 400                                  # 4 s at dt = 0.01

BALL = """
<mujoco model="beach_ball">
  <option timestep="0.01" density="1.2" viscosity="0.00002" wind="{wind}"/>
  <worldbody>
    <body name="ball" pos="0 0 10">
      <freejoint/>
      <geom type="sphere" size=".2" mass="0.1" {shape}/>
    </body>
  </worldbody>
</mujoco>
"""


def fall(xml, density=None, record=False):
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm)
    nworld = len(density) if density is not None else 1
    d = mjw.make_data(mjm, nworld=nworld)
    if density is not None:
        m.opt.density = wp.array(density, dtype=float)     # replace: one density per world
    traj = []
    for i in range(NSTEP):
        mjw.step(m, d)
        if record and i % 10 == 9:
            traj.append([round(float(v), 3) for v in d.qvel.numpy()[:, 2]])
    return mjm, m, d, traj


DENS = [0.0, 1.2, 5.0, 20.0]
mjm, m, d, traj = fall(BALL.format(wind="0 0 0", shape=""), DENS, record=True)
vz = d.qvel.numpy()[:, 2]
print("(a) inertia-box model, m.has_fluid =", m.has_fluid, "| body_fluid_ellipsoid =",
      m.body_fluid_ellipsoid.numpy())
side = np.sqrt(6 * 0.4 * 0.2**2)             # inertia box of a solid sphere: side = sqrt(2.4) r
for rho, v in zip(DENS, vz):
    vt = np.sqrt(2 * 0.1 * 9.81 / (rho * side**2)) if rho else float("inf")
    print(f"  density {rho:5.1f}: vz after {NSTEP * 0.01:.0f} s = {v:+8.3f} m/s"
          f"  (quadratic-drag terminal speed {vt:.3f})")

_, mb, db, _ = fall(BALL.format(wind="0 0 0", shape=""))
_, me, de, _ = fall(BALL.format(wind="0 0 0", shape='fluidshape="ellipsoid"'))
print("(b) density 1.2: inertia box vz =", db.qvel.numpy()[0, 2].round(3),
      "| ellipsoid vz =", de.qvel.numpy()[0, 2].round(3),
      "| body_fluid_ellipsoid =", me.body_fluid_ellipsoid.numpy())
mje = mujoco.MjModel.from_xml_string(BALL.format(wind="0 0 0", shape='fluidshape="ellipsoid"'))
print("    geom_fluid[0] (coef, blunt, slender, ang, kutta, magnus, added-mass...) =",
      mje.geom_fluid[0, :6].round(4))

_, mw, dw, _ = fall(BALL.format(wind="3 0 0", shape=""))
x, vx = dw.qpos.numpy()[0, 0], dw.qvel.numpy()[0, 0]
print(f"(c) wind (3, 0, 0): after {NSTEP * 0.01:.0f} s x drift = {x:+.3f} m, vx = {vx:+.3f} m/s "
      "(approaches the wind speed)")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"density": DENS, "dt": 0.1, "vz": traj}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
