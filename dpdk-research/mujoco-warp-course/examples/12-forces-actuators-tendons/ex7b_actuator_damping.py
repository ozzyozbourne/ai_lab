"""Example 12.7b - actuator damping: an actuator that adds passive damping to its joint.

In MuJoCo 4 an actuator can carry damping="b p1 p2" (m.actuator_damping, m.actuator_dampingpoly).
It is not an actuator force: passive.py::_spring_damper_dof_passive asks
util_misc.actuator_target_damping for every joint and adds gear^2 * (b, p1, p2) of each actuator
that targets the joint to the joint's own damping, so the result lands in qfrc_damper:
    qfrc_damper = -v * (B + P1 |v| + P2 v^2)
    B = dof_damping + gear^2 b,  (P1, P2) = dof_dampingpoly + gear^2 (p1, p2)
m.jnt_actuatorid[j] says which actuator to read: -1 none, >= 0 exactly one, < -1 scan them all.
Run: python ex7b_actuator_damping.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

XML = """
<mujoco model="actuator_damping">
  <option gravity="0 0 0"/>
  <worldbody>
    <body>
      <joint name="j0" type="hinge" axis="0 1 0" damping="0.1"/>
      <geom type="capsule" fromto="0 0 0 .3 0 0" size=".03" mass="1"/>
    </body>
  </worldbody>
  {actuator}
</mujoco>
"""
WITH = '<actuator><general joint="j0" gear="2" damping=".3 .1 .05"/></actuator>'
V = np.array([0.5, -1.0, 2.0], dtype=np.float32)          # one joint velocity per world


def damper(xml):
    mjm = mujoco.MjModel.from_xml_string(xml)
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=len(V))
    d.qvel.assign(V[:, None])
    mjw.forward(m, d)
    c = []
    for v in V:
        md = mujoco.MjData(mjm)
        md.qvel[0] = v
        mujoco.mj_forward(mjm, md)
        c.append(md.qfrc_damper[0])
    return mjm, d.qfrc_damper.numpy()[:, 0], np.array(c), d.actuator_force.numpy()


mjm0, f0, _, _ = damper(XML.format(actuator=""))
mjm1, f1, c1, af = damper(XML.format(actuator=WITH))
print("jnt_actuatorid without / with actuator:", mjm0.jnt_actuatorid, mjm1.jnt_actuatorid)
print("actuator_damping =", mjm1.actuator_damping, "| actuator_dampingpoly =",
      mjm1.actuator_dampingpoly, "| gear =", mjm1.actuator_gear[0, 0])
gear2 = mjm1.actuator_gear[0, 0] ** 2
B = 0.1 + gear2 * 0.3
P1, P2 = gear2 * 0.1, gear2 * 0.05
by_hand = -V * (B + P1 * np.abs(V) + P2 * V * V)
print("qvel                       ", V)
print("qfrc_damper, joint only    ", f0, "(= -0.1 v)")
print("qfrc_damper, with actuator ", f1)
print(f"by hand: B = 0.1 + 4*0.3 = {B:.2f}, P = 4*(0.1, 0.05) = ({P1:.2f}, {P2:.2f}) ->", by_hand)
print("C MuJoCo qfrc_damper       ", c1)
print("actuator_force (ctrl = 0) ", af[:, 0], "<- the damping is passive, not actuation")
