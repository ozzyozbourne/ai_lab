"""Example 2.8 - default classes and a joint limit that the arm is pushed against.

A <default class="limb"> sets the joint damping, the range and the geom size and colour once;
two links use it. The hinge range is -30..30 degrees. Gravity plus a motor command push the arm
past +30 degrees: the limit is soft, so qpos ends slightly beyond the range and one limit row
appears in the constraint list (nefc).
Run: python ex8_limits_defaults.py
"""
import mujoco
import numpy as np

np.set_printoptions(precision=4, suppress=True)

ARM = """
<mujoco model="limited_arm">
  <compiler angle="degree"/>
  <option timestep="0.002"/>
  <default>
    <default class="limb">
      <joint type="hinge" axis="0 1 0" damping="0.5" limited="true" range="-30 30"/>
      <geom type="capsule" size=".03" rgba=".2 .6 .9 1" mass="0.5"/>
    </default>
  </default>
  <worldbody>
    <body name="upper" pos="0 0 1">
      <joint name="shoulder" class="limb"/>
      <geom class="limb" fromto="0 0 0 .4 0 0"/>
      <body name="lower" pos=".4 0 0">
        <joint name="elbow" class="limb" range="-90 90"/>
        <geom class="limb" fromto="0 0 0 .3 0 0" rgba=".9 .5 .2 1"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="lift" joint="shoulder" gear="1"/></actuator>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(ARM)
mjd = mujoco.MjData(mjm)
for j in range(mjm.njnt):
    name = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_JOINT, j)
    damping = mjm.dof_damping[mjm.jnt_dofadr[j]]   # damping is stored per DOF
    print(f"joint {name:8s} damping {damping:.2f}  limited {bool(mjm.jnt_limited[j])}"
          f"  range [deg] {np.degrees(mjm.jnt_range[j])}")
print("geom rgba from the class / overridden:", mjm.geom_rgba[0], mjm.geom_rgba[1])
print("range is stored in radians:", mjm.jnt_range[0])

# Push down: gravity rotates the arm to +angle about +y (x axis toward -z); add a motor push.
mjd.ctrl[0] = 2.0
for _ in range(1000):   # 2 s
    mujoco.mj_step(mjm, mjd)
q = np.degrees(mjd.qpos)
print(f"shoulder qpos = {q[0]:.3f} deg (limit 30): beyond by {q[0] - 30:.3f} deg")
print("nefc =", mjd.nefc, "| efc_type:",
      [mujoco.mjtConstraint(t).name for t in mjd.efc_type[:mjd.nefc]])
print(f"limit force on the shoulder (qfrc_constraint[0]) = {mjd.qfrc_constraint[0]:.3f} N m")

# Inside the range there is no row at all.
mjd.ctrl[0] = 0.0
mujoco.mj_resetData(mjm, mjd)
mujoco.mj_forward(mjm, mjd)
print("at qpos = 0: nefc =", mjd.nefc)
