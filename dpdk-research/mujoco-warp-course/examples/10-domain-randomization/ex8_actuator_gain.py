"""Example 10.8 - randomize actuator strength: actuator_gear or actuator_gainprm per world.

A motor's force on its joint is gear * gain * ctrl (gain = gainprm[0] for a FIXED gain). Both
fields are "*" arrays, so the same ctrl pushes the cart harder in some worlds than in others,
like motors from a production line that are all a little different. No set_const is needed for
the dynamics (transmission reads actuator_gear[worldid % B] every step); actuator_acc0 is only
used by muscles (Example 10.12).
Run: python ex8_actuator_gain.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

CARTPOLE = """
<mujoco model="cartpole">
  <option timestep="0.01" integrator="implicitfast"/>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="front" pos="0 -4 1" xyaxes="1 0 0 0 0 1"/>
    <geom name="rail" type="capsule" fromto="-2 0 1 2 0 1" size=".02" contype="0" conaffinity="0"/>
    <body name="cart" pos="0 0 1">
      <joint name="slider" type="slide" axis="1 0 0" range="-1.8 1.8" limited="true" damping="0.1"/>
      <geom name="cart" type="box" size=".2 .1 .05" mass="1" contype="0" conaffinity="0"/>
      <body name="pole">
        <joint name="hinge" type="hinge" axis="0 1 0" damping="0.01"/>
        <geom name="pole" type="capsule" fromto="0 0 0 0 0 .6" size=".03" mass="0.1"
              contype="0" conaffinity="0"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="slider" gear="10" ctrlrange="-1 1" ctrllimited="true"/></actuator>
  <sensor>
    <jointpos joint="slider"/><jointpos joint="hinge"/>
    <jointvel joint="slider"/><jointvel joint="hinge"/>
  </sensor>
</mujoco>
"""
NWORLD = 4
mjm = mujoco.MjModel.from_xml_string(CARTPOLE)

# A. gear per world: 5, 10, 15, 20
m = mjw.put_model(mjm, batch_sizes={"actuator_gear": NWORLD})
d = mjw.make_data(mjm, nworld=NWORLD)
gear = m.actuator_gear.numpy()                    # (NWORLD, nu, 6): spatial gear, [0] for joints
gear[:, 0, 0] = [5.0, 10.0, 15.0, 20.0]
m.actuator_gear.assign(gear)
d.ctrl.fill_(0.5)
mjw.forward(m, d)
print("A. gear       =", m.actuator_gear.numpy()[:, 0, 0])
print("   force      =", d.actuator_force.numpy()[:, 0], "(gain * ctrl, before gear)")
print("   qfrc_actuator[slider] =", d.qfrc_actuator.numpy()[:, 0])
print("   cart qacc  =", d.qacc.numpy()[:, 0])

# B. gain per world, gear fixed at 10: gainprm[0] = 0.5, 1, 1.5, 2
m = mjw.put_model(mjm, batch_sizes={"actuator_gainprm": NWORLD})
d = mjw.make_data(mjm, nworld=NWORLD)
gain = m.actuator_gainprm.numpy()                 # (NWORLD, nu, 10)
gain[:, 0, 0] = [0.5, 1.0, 1.5, 2.0]
m.actuator_gainprm.assign(gain)
d.ctrl.fill_(0.5)
mjw.forward(m, d)
print("B. gainprm[0] =", m.actuator_gainprm.numpy()[:, 0, 0])
print("   force      =", d.actuator_force.numpy()[:, 0])
print("   cart qacc  =", d.qacc.numpy()[:, 0], "(same as A: gear * gain is what counts)")
