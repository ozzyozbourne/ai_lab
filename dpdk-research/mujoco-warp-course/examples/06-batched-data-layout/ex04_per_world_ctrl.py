"""Example 6.4 - a different control in every world: d.ctrl is (nworld, nu).

World w gets a motor torque in [-1, 1]. After 100 steps the hinge angles spread out,
while the ball and the box (same in every world) land identically.
Run: python ex04_per_world_ctrl.py
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
NSTEP = 100

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

ctrl = np.linspace(-1.0, 1.0, NWORLD, dtype=np.float32).reshape(NWORLD, mjm.nu)  # (nworld, nu)
d.ctrl.assign(ctrl)            # set once; the motor applies it on every step
for _ in range(NSTEP):
    mjw.step(m, d)
wp.synchronize()

qpos = d.qpos.numpy()          # one host read at the end, not inside the loop
print("ctrl shape:", d.ctrl.shape, "| qpos shape:", d.qpos.shape)
print("ctrl per world:      ", ctrl[:8, 0])
print("hinge qpos per world:", qpos[:8, 14])
print("ball z per world:    ", qpos[:8, 2])
print(f"hinge spread (max - min): {qpos[:, 14].max() - qpos[:, 14].min():.4f} rad")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
