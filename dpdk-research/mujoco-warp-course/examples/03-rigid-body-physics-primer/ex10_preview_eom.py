"""Example 3.10 - a preview of the equation of motion M(q) qacc + c(q, qvel) = tau.

The double PENDULUM from Ch 2, upper link horizontal (keyframe "horizontal"), elbow bent by
0.6 rad, both joints moving, with 1 N m on the shoulder motor. C MuJoCo's mj_forward fills every
term; we print them and the residual, which is ~0 because this scene has no contacts or other
constraints. Then MJWarp's mjw.forward computes qacc for the same state. You derive all of this
in Ch 11.
Run: python ex10_preview_eom.py
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

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
mjd = mujoco.MjData(mjm)
mujoco.mj_resetDataKeyframe(mjm, mjd, mjm.key("horizontal").id)
mjd.qpos[1] = 0.6                  # bend the elbow
mjd.qvel[:] = [1.0, 0.5]           # moving, so the velocity-dependent part of c is not zero
mjd.ctrl[0] = 1.0                  # 1 N m on the shoulder
mujoco.mj_forward(mjm, mjd)

M = np.zeros((mjm.nv, mjm.nv))
mujoco.mj_fullM(mjm, mjd, M)       # dense copy of the (sparse) mass matrix
c = mjd.qfrc_bias                  # gravity + Coriolis/centrifugal ("bias") forces
tau = mjd.qfrc_actuator + mjd.qfrc_passive + mjd.qfrc_applied
print("M (mass matrix, depends on q):")
print(M)
still = mujoco.MjData(mjm)         # same pose, zero velocity: c(q, 0) is gravity alone
still.qpos[:] = mjd.qpos
mujoco.mj_forward(mjm, still)
print("c   = qfrc_bias     :", c, " = gravity", still.qfrc_bias,
      "+ velocity part", c - still.qfrc_bias)
print("tau = qfrc_actuator :", mjd.qfrc_actuator, " (+ passive", mjd.qfrc_passive, ")")
print("qacc                :", mjd.qacc)
print("residual M qacc + c - tau:", M @ mjd.qacc + c - tau, " (no constraints: J^T f = 0)")
print("qacc = M^-1 (tau - c):", np.linalg.solve(M, tau - c))

# MJWarp computes the same terms on the device
m = mjw.put_model(mjm)
d = mjw.put_data(mjm, mjd)
mjw.forward(m, d)
print("MJWarp qacc (float32):", d.qacc.numpy()[0])
print("MJWarp qfrc_bias     :", d.qfrc_bias.numpy()[0])
