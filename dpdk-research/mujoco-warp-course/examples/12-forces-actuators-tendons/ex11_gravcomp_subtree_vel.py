"""Example 12.11 - gravity compensation, and subtree velocities that are computed on demand.

(a) body gravcomp="1" adds an anti-gravity force -gravcomp * m * g at the body's com, mapped to
    joint space by passive.py::_gravity_force into d.qfrc_gravcomp (and then qfrc_passive). The
    body floats. With actuatorgravcomp="true" on a joint the same force is routed into
    qfrc_actuator instead (forward.py::_qfrc_actuator_gravcomp_limits), where actfrcrange clamps it.
(b) d.subtree_linvel / d.subtree_angmom are filled only by smooth.py::subtree_vel, which forward
    calls only when a sensor needs it (m.sensor_subtree_vel). Otherwise call mjw.subtree_vel.
Run: python ex11_gravcomp_subtree_vel.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

FLOAT = """
<mujoco model="float">
  <option timestep="0.002"/>
  <worldbody>
    <body name="balloon" pos="0 0 1" gravcomp="{g}">
      <freejoint/>
      <geom type="sphere" size=".1" mass="0.5"/>
    </body>
  </worldbody>
</mujoco>
"""
print("(a) 0.5 s of simulation, no floor")
for g in ("0", "0.5", "1"):
    mjm = mujoco.MjModel.from_xml_string(FLOAT.format(g=g))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=1)
    for _ in range(250):
        mjw.step(m, d)
    print(f"  gravcomp={g:3s}: z drift = {d.qpos.numpy()[0, 2] - 1:+.4f} m, "
          f"qfrc_gravcomp[z] = {d.qfrc_gravcomp.numpy()[0, 2]:.4f}, "
          f"qfrc_passive[z] = {d.qfrc_passive.numpy()[0, 2]:.4f}")

ARM = """
<mujoco model="arm">
  <worldbody>
    <body name="arm" gravcomp="1">
      <joint name="j" type="hinge" axis="0 1 0" actuatorgravcomp="{a}" actuatorfrcrange="-1 1"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03" mass="1"/>
    </body>
  </worldbody>
  <actuator><motor joint="j"/></actuator>
</mujoco>
"""
for a in ("false", "true"):
    mjm = mujoco.MjModel.from_xml_string(ARM.format(a=a))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=1)
    mjw.forward(m, d)
    print(f"  arm, actuatorgravcomp={a:5s}: jnt_actgravcomp={mjm.jnt_actgravcomp[0]} "
          f"qfrc_gravcomp={d.qfrc_gravcomp.numpy()[0, 0]:+.4f} "
          f"qfrc_passive={d.qfrc_passive.numpy()[0, 0]:+.4f} "
          f"qfrc_actuator={d.qfrc_actuator.numpy()[0, 0]:+.4f} (actfrcrange -1..1)")

mjm = mujoco.MjModel.from_xml_string(FLOAT.format(g="0"))
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
d.qvel.assign(np.array([[1.0, 0.0, 2.0, 0.0, 0.0, 3.0]], dtype=np.float32))
mjw.forward(m, d)
print("(b) m.sensor_subtree_vel =", m.sensor_subtree_vel)
print("  after forward:        subtree_linvel[ball] =", d.subtree_linvel.numpy()[0, 1],
      "subtree_angmom[ball] =", d.subtree_angmom.numpy()[0, 1])
mjw.subtree_vel(m, d)
print("  after mjw.subtree_vel: subtree_linvel[ball] =", d.subtree_linvel.numpy()[0, 1],
      "subtree_angmom[ball] =", d.subtree_angmom.numpy()[0, 1])
print("  expected angmom about the com = I w = (2/5 m r^2) * 3 =", round(0.4 * 0.5 * 0.01 * 3, 4))
