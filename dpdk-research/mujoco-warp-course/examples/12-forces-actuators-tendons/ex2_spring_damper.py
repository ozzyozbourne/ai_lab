"""Example 12.2 - joint springs and dampers, polynomial stiffness, and qfrc_passive by name.

passive.py::_spring_damper_dof_passive (one thread per (world, joint)) writes qfrc_spring and
qfrc_damper. For a hinge: qfrc_spring = -x * (k + p1*x + p2*x^2) with x = q - springref, and
qfrc_damper = -v * (b + p1*|v| + p2*v^2) (util_misc._poly_force; flg_odd=1 uses |v|). MuJoCo 4
reads the polynomial terms from extra numbers in stiffness="k p1 p2" and damping="b p1 p2".
Part (c) builds a 3-link arm with springs, dampers, gravcomp and fluid drag and checks that
qfrc_passive = qfrc_spring + qfrc_damper + qfrc_gravcomp + qfrc_fluid (+ qfrc_adhesion, 0 here;
flex passive forces are written into qfrc_spring / qfrc_damper).
Run: python ex2_spring_damper.py [--dump-json PATH]
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

HINGE = """
<mujoco model="spring_hinge">
  <compiler angle="radian"/>  <!-- springref is an angle: without this it is read in degrees -->
  <option gravity="0 0 0"/>
  <worldbody>
    <body name="flap">
      <joint name="j" type="hinge" axis="0 1 0" stiffness="{stiffness}" damping="{damping}"
             springref="0.2"/>
      <geom type="box" size=".2 .02 .05" pos=".2 0 0" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""


def passive_at(xml, qpos, qvel):
    """One world per (qpos, qvel) pair; returns MJWarp and C MuJoCo qfrc_spring, qfrc_damper."""
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=len(qpos))
    d.qpos.assign(np.array(qpos, dtype=np.float32)[:, None])
    d.qvel.assign(np.array(qvel, dtype=np.float32)[:, None])
    mjw.forward(m, d)
    c_spring, c_damper = [], []
    for q, v in zip(qpos, qvel):
        md = mujoco.MjData(mjm)
        md.qpos[0], md.qvel[0] = q, v
        mujoco.mj_forward(mjm, md)
        c_spring.append(md.qfrc_spring[0])
        c_damper.append(md.qfrc_damper[0])
    return (mjm, d.qfrc_spring.numpy()[:, 0], d.qfrc_damper.numpy()[:, 0],
            np.array(c_spring), np.array(c_damper))


Q = [0.0, 0.5, -0.4]
V = [1.0, -2.0, 0.5]
REF = 0.2

# (a) linear spring and damper
mjm, sp, dm, csp, cdm = passive_at(HINGE.format(stiffness="10", damping="0.5"), Q, V)
print("(a) linear: k=10, b=0.5, springref=0.2")
print("  jnt_stiffness", mjm.jnt_stiffness, "| jnt_stiffnesspoly", mjm.jnt_stiffnesspoly)
for q, v, s, dd in zip(Q, V, sp, dm):
    print(f"  q={q:+.2f} v={v:+.2f}: qfrc_spring={s:+.4f} (formula {-10 * (q - REF):+.4f})"
          f"  qfrc_damper={dd:+.4f} (formula {-0.5 * v:+.4f})")

# (b) MuJoCo 4 polynomial stiffness and damping: stiffness="k p1 p2", damping="b p1 p2"
K, KP = 10.0, (5.0, 40.0)
B, BP = 0.5, (0.2, 0.1)
mjm, sp, dm, csp, cdm = passive_at(
    HINGE.format(stiffness=f"{K} {KP[0]} {KP[1]}", damping=f"{B} {BP[0]} {BP[1]}"), Q, V)
print("(b) polynomial: stiffness='10 5 40', damping='0.5 0.2 0.1'")
print("  jnt_stiffnesspoly", mjm.jnt_stiffnesspoly, "| dof_dampingpoly", mjm.dof_dampingpoly)
for q, v, s, dd, cs, cd in zip(Q, V, sp, dm, csp, cdm):
    x = q - REF
    f_s = -x * (K + KP[0] * x + KP[1] * x * x)
    f_d = -v * (B + BP[0] * abs(v) + BP[1] * v * v)
    print(f"  x={x:+.2f}: spring {s:+.4f} numpy {f_s:+.4f} C {cs:+.4f} | "
          f"v={v:+.2f}: damper {dd:+.4f} numpy {f_d:+.4f} C {cd:+.4f}")

# (c) qfrc_passive decomposed by name on a 3-link arm
ARM = """
<mujoco model="passive_arm">
  <compiler angle="radian"/>
  <option timestep="0.002" density="1.2" viscosity="0.00002"/>
  <worldbody>
    <body name="l1" pos="0 0 1">
      <joint name="j1" type="hinge" axis="0 1 0" stiffness="4" damping="0.4"/>
      <geom type="capsule" fromto="0 0 0 .4 0 0" size=".05" mass="1"/>
      <body name="l2" pos=".4 0 0">
        <joint name="j2" type="hinge" axis="0 1 0" stiffness="2 1 0" damping="0.2" springref="0.3"/>
        <geom type="capsule" fromto="0 0 0 .3 0 0" size=".04" mass="0.6"/>
        <body name="l3" pos=".3 0 0" gravcomp="1">
          <joint name="j3" type="hinge" axis="0 1 0" damping="0.1"/>
          <geom type="box" size=".15 .1 .02" pos=".15 0 0" mass="0.3"/>
        </body>
      </body>
    </body>
  </worldbody>
</mujoco>
"""
mjm = mujoco.MjModel.from_xml_string(ARM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
d.qpos.assign(np.array([[0.4, -0.5, 0.8]], dtype=np.float32))
d.qvel.assign(np.array([[1.5, -3.0, 6.0]], dtype=np.float32))
mjw.forward(m, d)
parts = {k: getattr(d, k).numpy()[0] for k in
         ("qfrc_spring", "qfrc_damper", "qfrc_gravcomp", "qfrc_fluid", "qfrc_passive")}
print("(c) 3-link arm, m.has_fluid =", m.has_fluid)
for k, v in parts.items():
    print(f"  {k:14s}", v)
resid = parts["qfrc_passive"] - (parts["qfrc_spring"] + parts["qfrc_damper"]
                                 + parts["qfrc_gravcomp"] + parts["qfrc_fluid"])
print("  passive - (spring + damper + gravcomp + fluid) =", resid)
md = mujoco.MjData(mjm)
md.qpos[:], md.qvel[:] = [0.4, -0.5, 0.8], [1.5, -3.0, 6.0]
mujoco.mj_forward(mjm, md)
err = np.abs(parts["qfrc_passive"] - md.qfrc_passive).max()
print(f"  max |qfrc_passive MJWarp - C| = {err:.2e}")

if args.dump_json:
    out = {"dofs": ["j1", "j2", "j3"],
           **{k: [round(float(x), 4) for x in v] for k, v in parts.items()}}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
