"""Example 19.7 - joint frictionloss: a Huber cost that sticks, then saturates and slides.

A wheel on a vertical hinge (gravity does no work on it) has frictionloss 0.5 N m. World w
pushes it with a motor torque tau_w from 0 to 1 N m. Below the frictionloss the friction row
stays QUADRATIC (the wheel sticks, with a small soft creep); above it the row saturates in the
LINEARPOS state with force exactly -frictionloss, and the wheel spins up.
Run: python ex7_frictionloss.py [--dump-json PATH]
  --dump-json PATH writes (torque, force, state) per world for the Huber figure (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

WHEEL = """
<mujoco model="wheel">
  <option timestep="0.002"/>
  <worldbody>
    <body name="wheel" pos="0 0 0.5">
      <joint name="axle" type="hinge" axis="0 0 1" frictionloss="0.5"/>
      <geom type="cylinder" size=".2 .02" mass="2"/>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="axle" gear="1"/></actuator>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

STATE = {int(v): k[len("mjCNSTRSTATE_"):] for k, v in mujoco.mjtConstraintState.__members__.items()}
NWORLD = 12
NSTEP = 50
TAU = np.linspace(0.0, 1.0, NWORLD - 1).tolist() + [0.49]     # plus one just below 0.5

mjm = mujoco.MjModel.from_xml_string(WHEEL)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, njmax=4)
d.ctrl.assign(np.array(TAU, dtype=np.float32)[:, None])
mjw.forward(m, d)

# .copy(): on the CPU device .numpy() is a view of the Warp buffer; the steps below overwrite it
st = d.efc.state.numpy()[:, 0].copy()
force = d.efc.force.numpy()[:, 0].copy()
qacc = d.qacc.numpy()[:, 0].copy()
D = float(d.efc.D.numpy()[0, 0])
print(f"nf {d.nf.numpy()[0]}  efc.type {mujoco.mjtConstraint(int(d.efc.type.numpy()[0, 0])).name}"
      f"  D {D:.3f}  frictionloss {mjm.dof_frictionloss[0]}  rf = frictionloss / D = "
      f"{mjm.dof_frictionloss[0] / D:.4f}")
for _ in range(NSTEP):
    mjw.step(m, d)
qvel = d.qvel.numpy()[:, 0]
force_late = d.efc.force.numpy()[:, 0]
print(" world  torque   state       efc.force   qacc     | after 0.1 s: qvel    efc.force")
order = np.argsort(TAU)
prev = None
for w in order:
    tag = "   <- transition" if prev is not None and st[w] != prev else ""
    print(f"  {w:3d}   {TAU[w]:5.2f}    {STATE[st[w]]:10s} {force[w]:8.4f}  "
          f"{qacc[w]:8.4f}  |      {qvel[w]:8.4f}  {force_late[w]:8.4f}{tag}")
    prev = st[w]
print("saturated rows carry exactly -frictionloss:",
      bool(np.allclose(force[st == 3], -mjm.dof_frictionloss[0])))

if args.dump_json:
    with open(args.dump_json, "w") as fh:
        json.dump({"frictionloss": float(mjm.dof_frictionloss[0]), "D": round(D, 5),
                   "pts": [[round(float(TAU[w]), 4), round(float(force[w]), 5), STATE[st[w]]]
                           for w in order]}, fh, separators=(",", ":"))
    print("wrote", args.dump_json)
