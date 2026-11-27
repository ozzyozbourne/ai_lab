"""Example 10.3 - a different timestep in every world.

m.opt.timestep is a "*" array, so we replace it with one value per world. Every kernel that
needs dt reads opt_timestep[worldid % opt_timestep.shape[0]] (forward.py::_next_time and the
integrators), so after the same number of steps each world is at a different time.
Run: python ex3_timestep_worlds.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=3, nconmax=4, njmax=16)

print("before: m.opt.timestep =", m.opt.timestep.numpy(), "shape", m.opt.timestep.shape)
m.opt.timestep = wp.array([0.001, 0.01, 0.02], dtype=float)   # one per world
print("after:  m.opt.timestep =", m.opt.timestep.numpy(), "shape", m.opt.timestep.shape)

for _ in range(10):
    mjw.step(m, d)
print("d.time after 10 steps:", d.time.numpy())
print("ball z after 10 steps:", d.qpos.numpy()[:, 2])
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
