"""Example 6.3 - a different hinge angle in every world, written in place with .assign.

Each row of d.qpos is one world. We build the full (nworld, nq) array on the host, change
column 14 (the arm hinge), copy it into the existing device array, and run forward to
update the kinematics. The arm tip is computed from xpos and xmat of the arm body.
Run: python ex03_per_world_qpos.py
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

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

hinge_adr = mjm.jnt_qposadr[mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_JOINT, "hinge")]
arm = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "arm")
angles = np.linspace(-np.pi / 2, np.pi / 2, NWORLD)

qpos = np.tile(mjm.qpos0, (NWORLD, 1))      # (nworld, nq), every world starts at qpos0
qpos[:, hinge_adr] = angles                  # one angle per world
d.qpos.assign(qpos)                          # copy into the SAME device array (in place)
mjw.forward(m, d)                            # kinematics: xpos, xmat, ... for all worlds

xpos = d.xpos.numpy()[:, arm]                # (nworld, 3): arm body origin per world
xmat = d.xmat.numpy()[:, arm]                # (nworld, 3, 3)
tip = xpos + xmat @ np.array([0.5, 0.0, 0.0])  # capsule end in the body frame -> world
print("hinge qpos address:", hinge_adr, "| arm body id:", arm)
print(" world  angle[rad]  tip x    tip z   formula z")
for w in range(min(NWORLD, 8)):
    z_formula = 1.0 - 0.5 * np.sin(angles[w])  # rotation about +y moves the tip down for q > 0
    print(f"{w:5d}  {angles[w]:9.4f}  {tip[w, 0]:7.4f}  {tip[w, 2]:7.4f}  {z_formula:8.4f}")
err = float(np.abs(tip[:, 2] - (1 - 0.5 * np.sin(angles))).max())
print(f"max |tip z - formula| over {NWORLD} worlds: {err:.1e}  (float32 on device)")
