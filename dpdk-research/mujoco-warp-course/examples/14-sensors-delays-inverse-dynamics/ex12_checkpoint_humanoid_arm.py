"""Example 14.12 - Part III checkpoint: inverse-dynamics trajectory tracking for the humanoid arm.

The shipped humanoid (M8) with its torso bolted in the air (MjSpec removes the free joint) and
Euler's implicit joint damping switched back on (the shipped file disables eulerdamp). The right
shoulder and elbow follow smooth sines for 2 s; every other joint holds 0.
  1. Build Euler-consistent qpos/qvel/qacc samples (finite differences, Example 14.11).
  2. Put sample k in world k and call mjw.inverse once: 400 torque vectors.
     Do it twice: plain inverse, and with EnableBit.INVDISCRETE, which first converts the
     discrete-time qacc to a continuous one (inverse.py::discrete_acc: (M + h D) qacc for Euler).
  3. Replay both torque tables open loop through qfrc_applied, with gravity, in 2 worlds.
Prints the RMS tracking error of the arm joints, the peak torque per arm joint and whether the
humanoid's own arm motors (gear 20, 20, 40; ctrlrange [-1, 1]) could deliver it.
Run: python ex12_checkpoint_humanoid_arm.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
spec = mujoco.MjSpec.from_file(str(HUMANOID_PATH))
spec.delete(spec.joint("root"))                # bolt the torso to the world ...
for key in list(spec.keys):                    # ... (keyframes still have the 28-wide qpos)
    spec.delete(key)
spec.body("torso").pos = [0, 0, 1.5]           # feet clear of the floor
spec.option.disableflags &= ~int(mujoco.mjtDisableBit.mjDSBL_EULERDAMP)   # implicit damping on
mjm = spec.compile()
m = mjw.put_model(mjm)

ARM = ["shoulder1_right", "shoulder2_right", "elbow_right"]
arm_dof = [int(mjm.jnt_dofadr[mjm.joint(n).id]) for n in ARM]
arm_act = [mjm.actuator(n).id for n in ARM]
DT = float(mjm.opt.timestep)                   # 0.005 s
NSAMPLE = 400                                  # 2 s -> 400 worlds for one inverse call

t = np.arange(NSAMPLE + 2) * DT
q = np.zeros((t.size, mjm.nq))
q[:, arm_dof[0]] = 0.5 * np.sin(np.pi * t)
q[:, arm_dof[1]] = 0.4 * np.sin(np.pi * t + 1.0)
q[:, arm_dof[2]] = -0.6 + 0.5 * np.sin(np.pi * t + 2.0)
qd = np.vstack([np.zeros((1, mjm.nv)), np.diff(q, axis=0) / DT])     # Euler-consistent
qd[0] = qd[1]
qdd = np.vstack([np.diff(qd, axis=0) / DT, np.zeros((1, mjm.nv))])

dinv = mjw.make_data(mjm, nworld=NSAMPLE, nconmax=8, njmax=64)
tables = {}
for name, flag in (("plain inverse", 0), ("INVDISCRETE", int(mjw.EnableBit.INVDISCRETE))):
    m.opt.enableflags = flag                   # a Python int, read when inverse() is called
    dinv.qpos.assign(q[:NSAMPLE].astype(np.float32))
    dinv.qvel.assign(qd[:NSAMPLE].astype(np.float32))
    dinv.qacc.assign(qdd[:NSAMPLE].astype(np.float32))
    mjw.inverse(m, dinv)
    tables[name] = dinv.qfrc_inverse.numpy().copy()
m.opt.enableflags = 0
wp.synchronize()
print(f"humanoid, torso fixed: nq={mjm.nq} nv={mjm.nv}; inverse over {NSAMPLE} worlds "
      f"(= {NSAMPLE * DT:.1f} s of samples)")


@wp.kernel
def set_row(table: wp.array3d(dtype=float), k: int, out: wp.array2d(dtype=float)):
    worldid, dofid = wp.tid()
    out[worldid, dofid] = table[worldid, k, dofid]


drep = mjw.make_data(mjm, nworld=2, nconmax=8, njmax=64)
drep.qpos.assign(np.tile(q[0], (2, 1)).astype(np.float32))
drep.qvel.assign(np.tile(qd[0], (2, 1)).astype(np.float32))
table = wp.array(np.stack(list(tables.values())).astype(np.float32), dtype=float)
err = np.zeros((NSAMPLE, 2, len(ARM)))
for k in range(NSAMPLE):
    wp.launch(set_row, dim=(2, mjm.nv), inputs=[table, k], outputs=[drep.qfrc_applied])
    mjw.step(m, drep)
    err[k] = drep.qpos.numpy()[:, arm_dof] - q[k + 1, arm_dof]      # demo: reads every step

for j, name in enumerate(tables):
    rms = np.sqrt((err[:, j] ** 2).mean(axis=0))
    print(f"replay with {name:13s}: RMS arm error [rad] "
          + " ".join(f"{v:.1e}" for v in rms) + f"  max {np.abs(err[:, j]).max():.1e}")
tau = tables["INVDISCRETE"]
peak = np.abs(tau[:, arm_dof]).max(axis=0)
gear = mjm.actuator_gear[arm_act, 0]
for n, p, g in zip(ARM, peak, gear):
    print(f"  {n:16s} peak |tau| = {p:6.3f} N m  -> ctrl = tau / gear = {p / g:.3f} "
          f"(gear {g:.0f}, ctrlrange [-1, 1])")
print("non-arm joints: peak holding torque", f"{np.abs(np.delete(tau, arm_dof, 1)).max():.2f} N m")
print("overflow:", "none" if not drep.overflow.numpy().any() else drep.overflow.numpy())

if args.dump_json:
    dec = slice(0, NSAMPLE, 5)
    with open(args.dump_json, "w") as f:
        json.dump({"joints": ARM, "t": np.round(t[:NSAMPLE][dec], 3).tolist(),
                   "q": np.round(q[:NSAMPLE][dec][:, arm_dof], 3).tolist(),
                   "tau": np.round(tau[dec][:, arm_dof], 3).tolist(),
                   "err_plain": [[float(f"{v:.3g}") for v in r] for r in err[dec, 0]],
                   "err_inv": [[float(f"{v:.3g}") for v in r] for r in err[dec, 1]]},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
