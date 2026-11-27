"""Example 2.2 - the joint table: type, qpos address, dof address and range for every joint.

Prints one row per joint of PLAYGROUND from mujoco.MjModel (jnt_type, jnt_qposadr, jnt_dofadr,
jnt_range), then reads the same address tables from the MJWarp Model, where jnt_type values are
mjw.JointType members.
Run: python ex2_joint_table.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <camera name="overview" pos="0.5 -3 1.5" xyaxes="1 0 0 0 0.45 0.9"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/>
      <geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/>
      <geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>
"""
# qpos / qvel slots per joint type (free 7/6, ball 4/3, slide 1/1, hinge 1/1)
JT = mjw.JointType
NQ = {JT.FREE: 7, JT.BALL: 4, JT.SLIDE: 1, JT.HINGE: 1}
NV = {JT.FREE: 6, JT.BALL: 3, JT.SLIDE: 1, JT.HINGE: 1}

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
print(f"{'joint':8s} {'type':6s} {'qposadr':>7s} {'nq':>3s} {'dofadr':>6s} {'nv':>3s}  range")
for j in range(mjm.njnt):
    name = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_JOINT, j) or f"(jnt {j})"
    jt = JT(int(mjm.jnt_type[j]))   # mjw.JointType mirrors mujoco.mjtJoint
    rng = mjm.jnt_range[j] if mjm.jnt_limited[j] else "unlimited"
    print(f"{name:8s} {jt.name:6s} {mjm.jnt_qposadr[j]:7d} {NQ[jt]:3d} "
          f"{mjm.jnt_dofadr[j]:6d} {NV[jt]:3d}  {rng}")
print("total: nq =", sum(NQ[JT(t)] for t in mjm.jnt_type),
      "| nv =", sum(NV[JT(t)] for t in mjm.jnt_type))

# Which joint owns each DOF, and which body owns it?
print("dof_jntid :", mjm.dof_jntid)
print("dof_bodyid:", mjm.dof_bodyid)

# The same tables on the MJWarp model (device arrays, read back with .numpy()).
m = mjw.put_model(mjm)
print("mjw jnt_qposadr:", m.jnt_qposadr.numpy(), "| jnt_dofadr:", m.jnt_dofadr.numpy())
print("mjw jnt_type   :", [JT(t).name for t in m.jnt_type.numpy()])
