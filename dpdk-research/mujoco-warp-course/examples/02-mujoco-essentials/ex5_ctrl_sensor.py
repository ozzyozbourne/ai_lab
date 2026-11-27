"""Example 2.5 - set ctrl, read sensordata by address, on the double PENDULUM.

A constant motor command ctrl = 2 (N m, gear 1) drives the shoulder hinge. The three sensors
(jointpos q1, jointvel v1, framepos tip_pos) live side by side in one flat sensordata vector;
sensor_adr and sensor_dim say where each one starts and how long it is.
Run: python ex5_ctrl_sensor.py
"""
import mujoco
import numpy as np

np.set_printoptions(precision=3, suppress=True)

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
print("nu =", mjm.nu, "| nactuator =", mjm.nactuator, "| nsensor =", mjm.nsensor,
      "| nsensordata =", mjm.nsensordata)

slices = {}
for i in range(mjm.nsensor):
    name = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_SENSOR, i)
    adr, dim = int(mjm.sensor_adr[i]), int(mjm.sensor_dim[i])
    slices[name] = slice(adr, adr + dim)
    print(f"  sensor {name:8s} adr {adr} dim {dim}")

mjd.ctrl[0] = 2.0           # constant torque on hinge1; ctrlrange clamps to [-5, 5]
for step in range(1, 301):  # 3 s
    mujoco.mj_step(mjm, mjd)
    if step % 50 == 0:
        s = mjd.sensordata
        print(f"t={mjd.time:.1f}  q1={s[slices['q1']][0]:7.3f}  v1={s[slices['v1']][0]:7.3f}"
              f"  tip_pos={s[slices['tip_pos']]}  E={mjd.energy.sum():7.3f}")

# The framepos sensor equals the site position computed by kinematics.
same = np.allclose(mjd.site_xpos[0], mjd.sensordata[slices["tip_pos"]])
print("tip site_xpos:", mjd.site_xpos[0], "== sensor:", same)
mjd.ctrl[0] = 50.0
mujoco.mj_step(mjm, mjd)
print("ctrl=50 is clamped by ctrlrange: actuator_force =", mjd.actuator_force)
