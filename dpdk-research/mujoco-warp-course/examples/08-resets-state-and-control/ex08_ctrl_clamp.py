"""Example 8.8 - ctrlrange is applied when the actuator reads ctrl; d.ctrl itself is never changed.

PENDULUM's motor has ctrlrange="-5 5". We write ctrl values outside the range in some worlds,
run forward, and compare d.ctrl with d.actuator_force (motor: gain 1, no bias, so force = clamped
ctrl; the gear is applied by the transmission and shows up only in d.qfrc_actuator).
Run: python ex08_ctrl_clamp.py
"""
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

NWORLD = 4

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
print("ctrllimited:", mjm.actuator_ctrllimited, "| ctrlrange:", mjm.actuator_ctrlrange)

d.ctrl.assign(np.array([[-10.0], [2.0], [5.0], [10.0]], dtype=np.float32))
mjw.forward(m, d)
print("d.ctrl            =", d.ctrl.numpy()[:, 0], " <- untouched")
print("d.actuator_force  =", d.actuator_force.numpy()[:, 0], " <- clamped inside _actuator_force")

mjw.step(m, d)
print("after a step, d.ctrl =", d.ctrl.numpy()[:, 0])

m.opt.disableflags |= mjw.DisableBit.CLAMPCTRL   # runtime flag: passed to the kernel as an int
mjw.forward(m, d)
print("CLAMPCTRL disabled: actuator_force =", d.actuator_force.numpy()[:, 0])
