"""Example 3.7 - the tennis-racket (intermediate-axis) flip, in many MJWarp worlds at once.

A free box with three different principal moments spins at 6 rad/s about its INTERMEDIATE axis
(body y), with gravity off. Each world adds a different tiny wobble about body x. The wobble grows
and the box flips over, again and again; worlds with a smaller wobble flip later. The model uses
the RK4 integrator, so kinetic energy stays constant to float32 round-off; a C MuJoCo run of
world 0 with the default Euler integrator shows the first-order drift you would get instead (Ch 13).
We also check that MJWarp's bias force for the rotational dofs is the gyroscopic term w x (I w).
Run: python ex7_tennis_racket.py [--dump-json PATH]
  --dump-json PATH writes per-world quaternions for the page's replay player (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

RACKET = """
<mujoco model="tennis_racket">
  <option timestep="0.005" gravity="0 0 0" integrator="RK4"/>
  <worldbody>
    <body name="racket" pos="0 0 1">
      <freejoint/>
      <geom type="box" size=".05 .2 .4" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 800                                   # 4 s at dt = 0.005 (same on CPU and GPU)
SPIN = 6.0                                    # rad/s about the intermediate axis

mjm = mujoco.MjModel.from_xml_string(RACKET)
I = mjm.body_inertia[1]
print("principal moments I =", I, "-> body y is the intermediate axis:", I[2] < I[1] < I[0])
lam = SPIN * np.sqrt((I[1] - I[2]) * (I[0] - I[1]) / (I[0] * I[2]))
print(f"linear theory: the wobble grows like exp({lam:.2f} t)")

m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)

wobble = SPIN * np.logspace(-4, -1.5, NWORLD)          # per-world wobble about body x [rad/s]
qvel = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
qvel[:, 3] = wobble                     # qvel[3:6] is the BODY-frame angular velocity
qvel[:, 4] = SPIN
d.qvel.assign(qvel)


def kinetic_energy(qv):
    w = qv[:, 3:6]
    return 0.5 * (w**2 * I).sum(axis=1)            # principal axes = body axes here (iquat = 1)


ke0 = kinetic_energy(qvel)
flip_t = np.full(NWORLD, np.nan)
show = np.linspace(0, NWORLD - 1, 8).astype(int)   # the 8 worlds the page replays
frames = []
for i in range(NSTEP):
    mjw.step(m, d)
    y_axis_y = d.xmat.numpy()[:, 1, 1, 1]           # world-y part of the body y axis (demo read)
    new = np.isnan(flip_t) & (y_axis_y < 0)
    flip_t[new] = (i + 1) * mjm.opt.timestep
    if args.dump_json and i % 4 == 3:
        frames.append([[round(float(v), 3) for v in q] for q in d.qpos.numpy()[show, 3:7]])
wp.synchronize()

ke1 = kinetic_energy(d.qvel.numpy())
print(f"{'world':>5} {'wobble [rad/s]':>15} {'first flip [s]':>15} {'KE drift (RK4)':>15}")
for w in show:
    print(f"{w:>5} {wobble[w]:>15.5f} {flip_t[w]:>15.3f} {(ke1[w] - ke0[w]) / ke0[w]:>+15.1e}")

# the same world 0 with the default Euler integrator, in C MuJoCo (fast for one world)
mjm_euler = mujoco.MjModel.from_xml_string(RACKET.replace(' integrator="RK4"', ""))
mjd = mujoco.MjData(mjm_euler)
mjd.qvel[:] = qvel[0]
for _ in range(NSTEP):
    mujoco.mj_step(mjm_euler, mjd)
ke_e = kinetic_energy(mjd.qvel[None, :])[0]
print(f"world 0 with Euler instead (C MuJoCo, same dt): KE drift {(ke_e - ke0[0]) / ke0[0]:+.1e}")

mjw.forward(m, d)                                   # recompute qfrc_bias for the current qvel
w0 = d.qvel.numpy()[0, 3:6].astype(np.float64)
gyro = np.cross(w0, I * w0)
print("world 0: qfrc_bias[3:6] =", d.qfrc_bias.numpy()[0, 3:6])
print("world 0: w x (I w)      =", gyro)

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": 8, "dt": 4 * float(mjm.opt.timestep), "kind": "quat",
                   "half": [0.05, 0.2, 0.4], "labels": [f"world {w}" for w in show],
                   "wobble": [round(float(wobble[w]), 5) for w in show],
                   "flip": [round(float(flip_t[w]), 3) for w in show],
                   "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
