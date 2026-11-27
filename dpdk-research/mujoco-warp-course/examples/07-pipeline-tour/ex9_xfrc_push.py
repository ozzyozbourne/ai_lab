"""Example 7.9 - push the box with d.xfrc_applied and follow the force through the pipeline.

xfrc_applied is a Cartesian wrench per body, (nworld, nbody) spatial vectors laid out as
(force x, y, z, torque x, y, z), applied at the body's center of mass. fwd_acceleration maps it to
joint space with J^T (support.py::xfrc_accumulate) and adds it to qfrc_smooth. Every world pushes
with a different force. We lower the sliding friction of all geoms to 0.3 at runtime (geom_friction
is an array field, so the change is live), so boxes slide above mu m g = 23.5 N and only tip over
above m g = 78.5 N.
Run: python ex9_xfrc_push.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

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
NSTEP = 1000 if ON_GPU else 50
SETTLE = 100                     # the box lands first
PUSH = 50                        # then 0.5 s of pushing

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
BOX = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "box")
BOX_DOF = mjm.jnt_dofadr[mjm.body_jntadr[BOX]]           # first of the box's 6 dofs
print("box body id:", BOX, "| box dofs:", BOX_DOF, "..", BOX_DOF + 5,
      "| box mass:", round(float(mjm.body_mass[BOX]), 3), "kg")

MU = 0.3
fr = m.geom_friction.numpy()                                # (1, ngeom, 3): slide, spin, roll
fr[..., 0] = MU
m.geom_friction.assign(fr)

for _ in range(SETTLE):
    mjw.step(m, d)

force = np.linspace(0.0, 70.0, NWORLD, dtype=np.float32)    # newtons, one value per world
xfrc = np.zeros((NWORLD, mjm.nbody, 6), np.float32)
xfrc[:, BOX, 0] = force                                     # +x force on the box
d.xfrc_applied.assign(xfrc)                                 # assign: keeps the same array

x0 = d.qpos.numpy()[:, 7].copy()                            # box x position (qpos 7..13)
for _ in range(PUSH):
    mjw.step(m, d)
mjw.forward(m, d)                                           # refresh qfrc_smooth for printing

qs = d.qfrc_smooth.numpy()[:, BOX_DOF]
vx = d.qvel.numpy()[:, BOX_DOF]
dx = d.qpos.numpy()[:, 7] - x0
mass = float(mjm.body_mass[BOX])
t_push = PUSH * float(mjm.opt.timestep)
coulomb = np.maximum(0.0, (force - MU * mass * 9.81) / mass * t_push)   # rigid Coulomb estimate
print(f"{'world':>5}{'F [N]':>8}{'qfrc_smooth x':>15}{'vx [m/s]':>10}{'Coulomb vx':>12}{'dx [m]':>9}")
for w in range(NWORLD):
    print(f"{w:5d}{force[w]:8.1f}{qs[w]:15.3f}{vx[w]:10.3f}{coulomb[w]:12.3f}{dx[w]:9.3f}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
