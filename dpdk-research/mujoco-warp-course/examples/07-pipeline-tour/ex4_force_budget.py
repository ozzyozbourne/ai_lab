"""Example 7.4 - audit the force budget: qfrc_smooth is a sum of named force terms.

fwd_acceleration computes, per world and per dof,
  qfrc_smooth = qfrc_passive - qfrc_bias + qfrc_actuator + qfrc_applied  (+ J^T xfrc_applied)
(forward.py::_qfrc_smooth, then support.py::xfrc_accumulate). We rebuild the right-hand side
from the individual Data fields and print the residual. The physics of each term is Ch 11-12.
Run: python ex4_force_budget.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <camera name="overview" pos="0.5 -3 1.5" xyaxes="1 0 0 0 0.45 0.9"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/><geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 50

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

rng = np.random.default_rng(0)
# give every term something to do:
d.ctrl.assign(rng.uniform(-1, 1, (NWORLD, mjm.nu)).astype(np.float32))         # actuator
d.qvel.assign(rng.normal(0, 1, (NWORLD, mjm.nv)).astype(np.float32))           # bias + damper
qfrc_applied = np.zeros((NWORLD, mjm.nv), np.float32)
qfrc_applied[:, 0] = rng.uniform(-2, 2, NWORLD)                                # push the ball in x
d.qfrc_applied.assign(qfrc_applied)
xfrc = np.zeros((NWORLD, mjm.nbody, 6), np.float32)
xfrc[:, 2, 0] = 5.0                                                            # 5 N on the box, +x
xfrc[:, 2, 5] = 0.5                                                            # 0.5 N m about z
d.xfrc_applied.assign(xfrc)
damping = m.dof_damping.numpy()
damping[:, 12] = 0.2                                                           # hinge damping
m.dof_damping.assign(damping)                                                  # array field: live

for _ in range(NSTEP):
    mjw.step(m, d)
mjw.forward(m, d)

passive, bias = d.qfrc_passive.numpy(), d.qfrc_bias.numpy()
actuator, applied = d.qfrc_actuator.numpy(), d.qfrc_applied.numpy()
jt_xfrc_arr = wp.zeros((NWORLD, mjm.nv), dtype=float)
mjw.xfrc_accumulate(m, d, jt_xfrc_arr)                                         # J^T xfrc_applied
jt_xfrc = jt_xfrc_arr.numpy()
smooth = d.qfrc_smooth.numpy()

rhs = passive - bias + actuator + applied + jt_xfrc
res = np.abs(smooth - rhs).max(axis=1)
parts = (d.qfrc_spring.numpy() + d.qfrc_damper.numpy() + d.qfrc_gravcomp.numpy()
         + d.qfrc_fluid.numpy() + d.qfrc_adhesion.numpy())
print("residual |qfrc_smooth - sum of terms| per world:", res)
print("max residual over all worlds:", f"{res.max():.2e}")
print("qfrc_passive == spring + damper + gravcomp + fluid + adhesion:",
      bool(np.allclose(passive, parts, atol=1e-6)))

W = 1
names = ["ball x", "ball y", "ball z", "ball rx", "ball ry", "ball rz",
         "box x", "box y", "box z", "box rx", "box ry", "box rz", "hinge"]
print(f"world {W}, per dof:")
print(f"{'dof':<8}{'passive':>9}{'-bias':>9}{'actuator':>9}{'applied':>9}{'J^T xfrc':>9}"
      f"{'= smooth':>10}")
for i, n in enumerate(names):
    print(f"{n:<8}{passive[W, i]:9.3f}{-bias[W, i]:9.3f}{actuator[W, i]:9.3f}"
          f"{applied[W, i]:9.3f}{jt_xfrc[W, i]:9.3f}{smooth[W, i]:10.3f}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    out = {"dofs": names, "worlds": []}
    for w in range(min(NWORLD, 4)):
        out["worlds"].append({k: [round(float(v), 3) for v in a[w]] for k, a in
                              (("passive", passive), ("neg_bias", -bias), ("actuator", actuator),
                               ("applied", applied), ("jt_xfrc", jt_xfrc), ("smooth", smooth))})
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
