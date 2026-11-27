"""Example 13.8 - step1/step2 with an RK4 model integrates with Euler.

step2 ends with "integrate with Euler, implicitfast, or discrete" (forward.py): for RK4 it falls
back to euler(). Three copies of the double pendulum run 100 steps from q = (1.2, 0):
step() with RK4, step1()+step2() with the same RK4 model, and step() with an Euler model.
Run: python ex8_step2_rk4.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=6, suppress=True)

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
NSTEP = 100

mjm = mujoco.MjModel.from_xml_string(PENDULUM)


def make(integrator):
    m = mjw.put_model(mjm)
    m.opt.integrator = integrator
    d = mjw.make_data(mjm, nworld=NWORLD)
    d.qpos.assign(np.tile([1.2, 0.0], (NWORLD, 1)))
    return m, d


m_rk, d_step = make(mjw.IntegratorType.RK4)
_, d_split = make(mjw.IntegratorType.RK4)
m_eu, d_euler = make(mjw.IntegratorType.EULER)

for _ in range(NSTEP):
    mjw.step(m_rk, d_step)
    mjw.step1(m_rk, d_split)
    # ... a policy would read d_split.sensordata and write d_split.ctrl here ...
    mjw.step2(m_rk, d_split)
    mjw.step(m_eu, d_euler)

q_step, q_split, q_euler = (x.qpos.numpy()[0] for x in (d_step, d_split, d_euler))
print("RK4 model, step()        :", q_step)
print("RK4 model, step1 + step2 :", q_split)
print("Euler model, step()      :", q_euler)
print(f"|split - RK4 step|   = {np.abs(q_split - q_step).max():.2e}")
print(f"|split - Euler step| = {np.abs(q_split - q_euler).max():.2e}  <- step2 ran Euler")
