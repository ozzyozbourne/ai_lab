"""Example 13.1 - choose the integrator in MJCF or on the device model.

Two ways to pick an integrator: the MJCF attribute <option integrator="..."/> (read by put_model),
or the Python int m.opt.integrator = mjw.IntegratorType.X on an existing mjw.Model. Both give
the same trajectory. The double pendulum starts at q = (1.2, 0) and runs 100 steps per integrator.
Run: python ex1_switch.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=5, suppress=True)

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01" integrator="{integrator}"><flag energy="enable"/></option>
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
Q0 = np.array([1.2, 0.0])

# MJCF spelling -> enum member (the XML attribute is case-sensitive)
NAMES = {"Euler": mjw.IntegratorType.EULER, "RK4": mjw.IntegratorType.RK4,
         "implicit": mjw.IntegratorType.IMPLICIT, "implicitfast": mjw.IntegratorType.IMPLICITFAST,
         "discrete": mjw.IntegratorType.DISCRETE}


def run(m, mjm):
    d = mjw.make_data(mjm, nworld=NWORLD)
    d.qpos.assign(np.tile(Q0, (NWORLD, 1)))
    for _ in range(NSTEP):
        mjw.step(m, d)
    return d.qpos.numpy()[0]


# way B: one model, switch the Python int on the device model
mjm_b = mujoco.MjModel.from_xml_string(PENDULUM.format(integrator="Euler"))
m_b = mjw.put_model(mjm_b)
print("type(m.opt.integrator):", type(m_b.opt.integrator).__name__, "| value:", m_b.opt.integrator)

print(f"{'integrator':<13}{'enum':>5}  {'qpos via MJCF':<22}{'qpos via m.opt':<22}{'max diff':>9}")
for name, enum in NAMES.items():
    # way A: MJCF attribute, compiled by MuJoCo, copied by put_model
    mjm_a = mujoco.MjModel.from_xml_string(PENDULUM.format(integrator=name))
    q_a = run(mjw.put_model(mjm_a), mjm_a)
    m_b.opt.integrator = enum          # a plain int: read when step() dispatches
    q_b = run(m_b, mjm_b)
    print(f"{name:<13}{int(enum):>5}  {np.array2string(q_a):<22}{np.array2string(q_b):<22}"
          f"{np.abs(q_a - q_b).max():>9.1e}")
