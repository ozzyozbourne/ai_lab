"""Example 11.13 - the stale-factor trap: one factorization per new qpos, never zero.

The factor of M lives in d.qLD / d.qLDiagInv and is only rewritten when someone factors:
  fwd_position(m, d, factorize=True)       (public default)  -> smooth.factor_m
  fwd_acceleration(m, d, factorize=True)   (what _forward passes) -> fused smooth.factor_solve_i
  fwd_acceleration(m, d)                   (public default factorize=False) -> smooth.solve_m,
                                            which only READS the stored factor.
We factor at qpos A (mjw.forward), move every world to a new qpos B and run the stages by hand
with four pairings. The bad mix solves M(B) qacc = f with the factor of M(A): no error is raised,
qacc_smooth is just wrong.
Run: python ex13_stale_factor.py [--dump-json PATH]
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
ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
rng = np.random.default_rng(6)
qpos_a = rng.uniform(-np.pi, np.pi, (NWORLD, mjm.nq)).astype(np.float32)
qpos_b = rng.uniform(-np.pi, np.pi, (NWORLD, mjm.nq)).astype(np.float32)

# reference: a full forward at qpos B
d.qpos.assign(qpos_b)
mjw.forward(m, d)
ref = d.qacc_smooth.numpy().copy()

PAIRINGS = {
    "public defaults: fwd_position() + fwd_acceleration()": (True, False),
    "_forward pairing: fwd_position(False) + fwd_acceleration(True)": (False, True),
    "factor twice: fwd_position() + fwd_acceleration(True)": (True, True),
    "BAD MIX: fwd_position(False) + fwd_acceleration()": (False, False),
}
errors = {}
for name, (fp, fa) in PAIRINGS.items():
    d.qpos.assign(qpos_a)
    mjw.forward(m, d)                           # qLD now holds the factor of M(qpos A)
    d.qpos.assign(qpos_b)                       # move every world
    mjw.fwd_position(m, d, factorize=fp)        # rebuilds d.M = M(B); factors only if fp
    mjw.fwd_velocity(m, d)
    mjw.fwd_actuation(m, d)
    mjw.fwd_acceleration(m, d, factorize=fa)
    err = np.abs(d.qacc_smooth.numpy() - ref).max()
    errors[name] = float(err)
    print(f"{name:66s} max |qacc_smooth - ref| = {err:.2e}")
print("world 0 reference qacc_smooth:", ref[0])
d.qpos.assign(qpos_a); mjw.forward(m, d); d.qpos.assign(qpos_b)
mjw.fwd_position(m, d, factorize=False); mjw.fwd_velocity(m, d)
mjw.fwd_actuation(m, d); mjw.fwd_acceleration(m, d)
print("world 0 bad-mix qacc_smooth  :", d.qacc_smooth.numpy()[0])

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"errors": {k: float(f"{v:.3g}") for k, v in errors.items()},
                   "ref0": np.round(ref[0].astype(float), 4).tolist(),
                   "bad0": np.round(d.qacc_smooth.numpy()[0].astype(float), 4).tolist()}, f)
    print("wrote", args.dump_json)
