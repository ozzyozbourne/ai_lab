"""Example 8.3 - a reset writes the state, not the things computed from it: call forward.

After reset_data_keyframe, qpos holds the keyframe but xpos and the sensors are stale until
mjw.forward (or the next mjw.step) recomputes them.
Run: python ex03_forward_after_reset.py
"""
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

NWORLD = 2

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
ball = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "ball")

for _ in range(50):  # let the ball fall for 0.5 s
    mjw.step(m, d)
print("after 50 steps:  qpos z =", d.qpos.numpy()[0, 2], "| xpos z =", d.xpos.numpy()[0, ball, 2],
      "| hinge sensor =", d.sensordata.numpy()[0, 0])

mjw.reset_data_keyframe(m, d, 0)  # key "up": ball at z = 2, hinge at 0.3 rad
print("after reset:     qpos z =", d.qpos.numpy()[0, 2], "| xpos z =", d.xpos.numpy()[0, ball, 2],
      "| hinge sensor =", d.sensordata.numpy()[0, 0], " <- xpos stale, sensordata zeroed")

mjw.forward(m, d)  # position, velocity, acceleration stages; no integration
print("after forward:   qpos z =", d.qpos.numpy()[0, 2], "| xpos z =", d.xpos.numpy()[0, ball, 2],
      "| hinge sensor =", d.sensordata.numpy()[0, 0])
print("time after forward:", d.time.numpy(), "(forward does not advance time)")
