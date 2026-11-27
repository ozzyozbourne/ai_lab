"""Example 12.2b - a plastic spring: the spring reference moves when the joint yields.

MuJoCo 4 joints and tendons can have springyield: when |q - ref| exceeds the yield distance, the
spring reference is dragged along so that |q - ref| = yield (a "return mapping"). The reference
lives in d.plastic (m.jnt_plasticadr[j] >= 0 is the joint's slot) and is updated after every step
in forward.py::_advance by _next_plastic_joint. passive.py::_spring_damper_dof_passive then reads
the spring reference from d.plastic instead of m.qpos_spring.
We bend a plastic hinge with a large qfrc_applied, release it, and compare d.plastic and qpos with
C MuJoCo step by step (parity check on CPU).
Run: python ex2b_plastic_spring.py [--dump-json PATH]
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

PLASTIC = """
<mujoco model="plastic_hinge">
  <compiler angle="radian"/>
  <option timestep="0.002" gravity="0 0 0"/>
  <worldbody>
    <body name="wire">
      <joint name="bend" type="hinge" axis="0 1 0" stiffness="20" springref="0"
             springyield="0.1" damping="1"/>
      <geom type="capsule" fromto="0 0 0 .3 0 0" size=".02" mass="0.2"/>
    </body>
  </worldbody>
</mujoco>
"""
NSTEP = 1500        # 3 s: push for 0.5 s, then release
PUSH = 3.0          # N m, held for the first 250 steps

mjm = mujoco.MjModel.from_xml_string(PLASTIC)
print("nplastic =", mjm.nplastic, "| jnt_plasticadr =", mjm.jnt_plasticadr,
      "| jnt_springyield =", mjm.jnt_springyield)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
md = mujoco.MjData(mjm)

frames, maxdiff = [], 0.0
for i in range(NSTEP):
    tau = PUSH if i < 250 else 0.0
    d.qfrc_applied.fill_(tau)
    md.qfrc_applied[0] = tau
    mjw.step(m, d)
    mujoco.mj_step(mjm, md)
    q, ref = float(d.qpos.numpy()[0, 0]), float(d.plastic.numpy()[0, 0])
    maxdiff = max(maxdiff, abs(q - md.qpos[0]), abs(ref - md.plastic[0]))
    if i % 25 == 24:
        frames.append([round((i + 1) * mjm.opt.timestep, 3), round(q, 4), round(ref, 4)])
    if i + 1 in (50, 250, 1500):
        print(f"t={(i + 1) * mjm.opt.timestep:.1f}s q={q:+.4f} plastic ref={ref:+.4f} "
              f"(C: q={md.qpos[0]:+.4f} ref={md.plastic[0]:+.4f}) q-ref={q - ref:+.4f}")
print(f"elastic limit would hold q at PUSH/k = {PUSH / 20:.3f}; yield = 0.1")
print(f"max |MJWarp - C| over {NSTEP} steps (qpos and plastic): {maxdiff:.2e}")
print("after release the wire rests at its new reference: permanent set =",
      round(float(d.plastic.numpy()[0, 0]), 4), "rad")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"push": PUSH, "k": 20, "yield": 0.1, "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
