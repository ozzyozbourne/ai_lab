"""Example 13.2 - every integrator against MuJoCo C (mujoco.mj_step).

The double pendulum from q = (1.2, 0) runs 300 steps (dt = 0.01) in MJWarp and in C MuJoCo with
the same integrator, without and with joint damping 5. The table shows the largest |delta qpos|
over the whole trajectory. MJWarp computes in float32, C MuJoCo in float64.
Run: python ex2_parity.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

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
NWORLD = 1           # one world is enough to compare with C; the code is the same for 4096
NSTEP = 300
INTEGRATORS = [("Euler", mujoco.mjtIntegrator.mjINT_EULER),
               ("RK4", mujoco.mjtIntegrator.mjINT_RK4),
               ("implicit", mujoco.mjtIntegrator.mjINT_IMPLICIT),
               ("implicitfast", mujoco.mjtIntegrator.mjINT_IMPLICITFAST),
               ("discrete", mujoco.mjtIntegrator.mjINT_DISCRETE)]


def max_diff(integrator, damping):
    mjm = mujoco.MjModel.from_xml_string(PENDULUM)
    mjm.opt.integrator = integrator
    mjm.dof_damping[:] = damping
    mjd = mujoco.MjData(mjm)
    mjd.qpos[:] = [1.2, 0.0]
    m = mjw.put_model(mjm)
    d = mjw.put_data(mjm, mjd, nworld=NWORLD)
    worst = 0.0
    for _ in range(NSTEP):
        mujoco.mj_step(mjm, mjd)
        mjw.step(m, d)
        worst = max(worst, float(np.abs(d.qpos.numpy()[0] - mjd.qpos).max()))
    return worst, mjd.qpos.copy()


print(f"{'integrator':<13}{'damping 0':>11}{'damping 5':>11}   C qpos after 3 s (damping 5)")
for name, integ in INTEGRATORS:
    e0, _ = max_diff(integ, 0.0)
    e5, q5 = max_diff(integ, 5.0)
    print(f"{name:<13}{e0:>11.1e}{e5:>11.1e}   {np.array2string(q5, precision=4)}")
