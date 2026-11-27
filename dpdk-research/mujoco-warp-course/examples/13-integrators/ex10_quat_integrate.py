"""Example 13.10 - integrating orientation: the exact quaternion update vs "add and renormalize".

A free cube spins with gravity off. A cube has equal principal inertias, so its body-frame angular
velocity qvel[3:6] stays constant and the exact answer is known: q(t) = q0 * exp(omega * t / 2).
forward.py::_next_position calls math.quat_integrate for free and ball joints, which multiplies
by the exact rotation of one step. The naive update q <- normalize(q + dt/2 * q * (0, omega))
(NumPy, float64) drifts. Five worlds use five timesteps; every world runs 500 steps.
Run: python ex10_quat_integrate.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=5, suppress=True)

CUBE = """
<mujoco model="spinning_cube">
  <option timestep="0.01" gravity="0 0 0"/>
  <worldbody>
    <body name="cube" pos="0 0 1">
      <freejoint/>
      <geom type="box" size=".1 .1 .1" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
# Q-prefixed names: in the notebook this cell must not overwrite DTS / EVERY from Examples 13.3 and 13.9.
QDTS = np.array([0.002, 0.005, 0.01, 0.02, 0.05])
QNWORLD = len(QDTS)
QNSTEP = 500
QEVERY = 10
OMEGA = np.array([1.0, 2.0, 3.0])           # body-frame angular velocity [rad/s]


def qmul(a, b):
    w1, x1, y1, z1 = a
    w2, x2, y2, z2 = b
    return np.array([w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2, w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
                     w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2, w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2])


def qexp(omega, t):                          # rotation by |omega| t about omega
    th = np.linalg.norm(omega) * t
    return np.concatenate([[np.cos(th / 2)], np.sin(th / 2) * omega / np.linalg.norm(omega)])


def angle(a, b):                             # angle of the rotation a^-1 * b (robust near 0)
    r = qmul(a * [1, -1, -1, -1], b)
    return 2 * np.arctan2(np.linalg.norm(r[1:]), abs(r[0]))


mjm = mujoco.MjModel.from_xml_string(CUBE)
m = mjw.put_model(mjm)
m.opt.timestep = wp.array(QDTS, dtype=float)
d = mjw.make_data(mjm, nworld=QNWORLD)
qvel = np.zeros((QNWORLD, mjm.nv))
qvel[:, 3:6] = OMEGA
d.qvel.assign(qvel)
print("free joint: qpos = [x y z | qw qx qy qz] (7), qvel = [vx vy vz | wx wy wz] (6)")
print("qpos[0] at t=0:", d.qpos.numpy()[0], "| qvel[0]:", d.qvel.numpy()[0])

q0 = mjm.qpos0[3:7].copy()
naive = np.tile(q0, (QNWORLD, 1))
norm_before = np.zeros(QNWORLD)
rec = {"mjw": [], "naive": [], "exact": [], "err_mjw": [], "err_naive": []}
for i in range(QNSTEP + 1):
    if i % QEVERY == 0:
        q_mjw = d.qpos.numpy()[:, 3:7].astype(np.float64)
        exact = np.array([qmul(q0, qexp(OMEGA, i * dt)) for dt in QDTS])
        rec["mjw"].append(np.round(q_mjw, 4).tolist())
        rec["naive"].append(np.round(naive, 4).tolist())
        rec["exact"].append(np.round(exact, 4).tolist())
        rec["err_mjw"].append([angle(a, b) for a, b in zip(q_mjw, exact)])
        rec["err_naive"].append([angle(a, b) for a, b in zip(naive, exact)])
    if i == QNSTEP:
        break
    mjw.step(m, d)
    for w, dt in enumerate(QDTS):                 # naive: q += dt/2 * q * (0, omega), renormalize
        qn = naive[w] + 0.5 * dt * qmul(naive[w], np.concatenate([[0.0], OMEGA]))
        norm_before[w] = np.linalg.norm(qn)
        naive[w] = qn / norm_before[w]

print(f"after {QNSTEP} steps, |omega| = {np.linalg.norm(OMEGA):.3f} rad/s")
print(f"{'dt [s]':>8}{'turned [rad]':>14}{'MJWarp err [deg]':>18}{'naive err [deg]':>17}"
      f"{'|q| before renorm':>19}")
for w, dt in enumerate(QDTS):
    print(f"{dt:>8.3f}{np.linalg.norm(OMEGA) * dt * QNSTEP:>14.2f}"
          f"{np.degrees(rec['err_mjw'][-1][w]):>18.1e}{np.degrees(rec['err_naive'][-1][w]):>17.4f}"
          f"{norm_before[w]:>19.6f}")
print("MJWarp |q| after the run:", np.linalg.norm(d.qpos.numpy()[:, 3:7], axis=1))

if args.dump_json:
    rec["err_mjw"] = [[float(f"{v:.2e}") for v in r] for r in np.degrees(rec["err_mjw"])]
    rec["err_naive"] = [[float(f"{v:.3e}") for v in r] for r in np.degrees(rec["err_naive"])]
    with open(args.dump_json, "w") as f:
        json.dump({"dts": QDTS.tolist(), "omega": OMEGA.tolist(), "every": QEVERY, "nstep": QNSTEP,
                   **rec}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
