"""Example 14.11 - inverse dynamics over a whole trajectory, one world per time sample.

The double pendulum (M2) must follow q1 = 0.6 sin(pi t), q2 = 0.4 sin(pi t + 1) for 2 s at
dt = 0.01 (200 samples). Instead of looping over time, we put sample k in world k: qpos, qvel,
qacc of that instant, and ONE mjw.inverse call returns all 200 torque vectors in d.qfrc_inverse.
Two ways to get qvel and qacc:
  A. analytic derivatives of the sines (continuous time);
  B. finite differences that match the semi-implicit Euler update
     (qvel_k = (q_k - q_{k-1}) / dt, qacc_k = (qvel_{k+1} - qvel_k) / dt).
Then both torque tables are replayed open loop through qfrc_applied in 2 worlds (a tiny kernel
copies row k on the device each step) and the tracking error is printed.
Run: python ex11_inverse_trajectory.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

DT = 0.01
NSAMPLE = 200          # 2 s of samples = 200 worlds (small enough for a CPU run)
AMP, PHASE, W = np.array([0.6, 0.4]), np.array([0.0, 1.0]), np.pi


def traj(t):
    s = np.sin(W * t[:, None] + PHASE)
    c = np.cos(W * t[:, None] + PHASE)
    return AMP * s, AMP * W * c, -AMP * W * W * s


@wp.kernel
def set_row(table: wp.array3d(dtype=float), k: int, out: wp.array2d(dtype=float)):
    worldid, dofid = wp.tid()
    out[worldid, dofid] = table[worldid, k, dofid]


mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
t = np.arange(NSAMPLE + 2) * DT
q, qd_a, qdd_a = traj(t)
# method B: velocities and accelerations consistent with semi-implicit Euler
qd_b = np.vstack([qd_a[:1], np.diff(q, axis=0) / DT])          # qvel_k = (q_k - q_{k-1}) / dt
qdd_b = np.vstack([np.diff(qd_b, axis=0) / DT, qdd_a[-1:]])    # qacc_k = (qvel_{k+1} - qvel_k)/dt

tables = {}
dinv = mjw.make_data(mjm, nworld=NSAMPLE)       # one world per time sample
for name, qd, qdd in (("A analytic", qd_a, qdd_a), ("B Euler-consistent", qd_b, qdd_b)):
    dinv.qpos.assign(q[:NSAMPLE].astype(np.float32))
    dinv.qvel.assign(qd[:NSAMPLE].astype(np.float32))
    dinv.qacc.assign(qdd[:NSAMPLE].astype(np.float32))
    mjw.inverse(m, dinv)                          # 200 time samples, one call
    tables[name] = dinv.qfrc_inverse.numpy().copy()
wp.synchronize()
tauA, tauB = tables["A analytic"], tables["B Euler-consistent"]
print(f"inverse: {NSAMPLE} worlds = {NSAMPLE} time samples, qfrc_inverse shape {tauA.shape}")
print("tau at t = 0, 0.5, 1.0 s (method A):\n", tauA[[0, 50, 100]])
diff = np.abs(tauA - tauB)
# sample 0 differs most: qd_b[0] = qd_a[0], so qdd_b[0] contains a velocity-jump kick
print(f"|tauA - tauB| at k = 0: {diff[0].max():.3f} N m; max over k >= 1: {diff[1:].max():.4f} N m")

# open-loop replay of both tables in 2 worlds at once
drep = mjw.make_data(mjm, nworld=2)
drep.qpos.assign(np.tile(q[0], (2, 1)).astype(np.float32))
drep.qvel.assign(np.stack([qd_a[0], qd_b[0]]).astype(np.float32))
table = wp.array(np.stack([tauA, tauB]).astype(np.float32), dtype=float)   # (2, NSAMPLE, nv)
err = np.zeros((NSAMPLE, 2))
for k in range(NSAMPLE):
    wp.launch(set_row, dim=(2, mjm.nv), inputs=[table, k], outputs=[drep.qfrc_applied])
    mjw.step(m, drep)                             # state k -> k+1 with torque k
    err[k] = np.abs(drep.qpos.numpy() - q[k + 1]).max(axis=1)   # demo: reads every step
for j, name in enumerate(tables):
    rms = np.sqrt((err[:, j] ** 2).mean())
    print(f"replay {name:18s}: RMS tracking error {rms:.2e} rad, final {err[-1, j]:.2e} rad")
print("peak |tau| per joint (method B):", np.abs(tauB).max(axis=0))

if args.dump_json:
    dec = slice(0, NSAMPLE, 2)
    with open(args.dump_json, "w") as f:
        json.dump({"dt": 2 * DT, "t": np.round(t[:NSAMPLE][dec], 3).tolist(),
                   "q": np.round(q[:NSAMPLE][dec], 3).tolist(),
                   "tauA": np.round(tauA[dec], 3).tolist(), "tauB": np.round(tauB[dec], 3).tolist(),
                   "errA": [float(f"{v:.3g}") for v in err[dec, 0]],
                   "errB": [float(f"{v:.3g}") for v in err[dec, 1]]}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
