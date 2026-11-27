"""Example 13.6 - under RK4, sensordata holds the values from the start of the step.

rungekutta4 runs _forward three more times at perturbed states with skip_sensor=True, so the
sensors written by the first forward (state at time t) survive. The double pendulum's jointpos
sensor q1 therefore equals qpos[0] *before* the step, not after it. d.energy is different: it is
recomputed in every stage, so after an RK4 step it describes the last perturbed stage (close
to the end-of-step state). C MuJoCo
(mujoco.mj_step) is printed next to MJWarp for both.
Run: python ex6_rk4_sensors.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=5, suppress=True)

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
NWORLD = 1024 if ON_GPU else 2

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
mjm.opt.integrator = mujoco.mjtIntegrator.mjINT_RK4
mjd = mujoco.MjData(mjm)
mujoco.mj_resetDataKeyframe(mjm, mjd, 0)          # q = (pi/2, 0): horizontal, at rest
mujoco.mj_step(mjm, mjd)                          # one step so qvel is not zero
m = mjw.put_model(mjm)
d = mjw.put_data(mjm, mjd, nworld=NWORLD)

for _ in range(20):
    mujoco.mj_step(mjm, mjd)
    mjw.step(m, d)

q_before, v_before = d.qpos.numpy()[0].copy(), d.qvel.numpy()[0].copy()
mjw.forward(m, d)                                 # no integration: energy of the start state
e_start = d.energy.numpy()[0].copy()
mujoco.mj_step(mjm, mjd)
mjw.step(m, d)
sens = d.sensordata.numpy()[0]
print(f"{'quantity':<22}{'before step':>13}{'after step':>13}{'sensordata':>13}{'C sensordata':>14}")
print(f"{'q1 (jointpos)':<22}{q_before[0]:>13.5f}{d.qpos.numpy()[0, 0]:>13.5f}{sens[0]:>13.5f}"
      f"{mjd.sensordata[0]:>14.5f}")
print(f"{'v1 (jointvel)':<22}{v_before[0]:>13.5f}{d.qvel.numpy()[0, 0]:>13.5f}{sens[1]:>13.5f}"
      f"{mjd.sensordata[1]:>14.5f}")
print("sensordata == start-of-step state:",
      bool(np.allclose(sens[:2], [q_before[0], v_before[0]], atol=1e-6)))

# energy of the state after the step: recompute with forward (no integration)
e_step = d.energy.numpy()[0].copy()
mjw.forward(m, d)
print("energy [pot, kin] of the start state:", e_start)
print("d.energy right after the RK4 step  :", e_step, "| C:", mjd.energy)
print("energy of the post-step state      :", d.energy.numpy()[0], "(mjw.forward)")
