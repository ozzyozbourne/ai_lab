"""Example 6.5 - in-place writes: fill_, zero_, wp.copy, row views, and a size trap.

All of these change the contents of an existing device array and keep its identity
(same object, same device pointer), which is what kernels and CUDA graphs rely on.
Run: python ex05_fill_copy_zero.py
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

NWORLD = 4  # small on purpose: we print whole arrays

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
ptr0 = d.qvel.ptr

# 1. fill_: one value everywhere (all worlds, all dofs)
d.qvel.fill_(0.5)
print("after fill_(0.5):\n", d.qvel.numpy())

# 2. a row view d.qvel[w] shares memory with world w only
d.qvel.zero_()
d.qvel[2].fill_(1.0)          # world 2 only: indexing one row returns a view, not a copy
print("after zero_() and qvel[2].fill_(1.0):\n", d.qvel.numpy())

# 3. wp.copy from another device array (same shape and dtype): one world gets an upward kick
kick = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
kick[1, 2] = 3.0                                   # world 1, dof 2 = linear z velocity
wp.copy(d.qvel, wp.array(kick, dtype=float))
print("after wp.copy(d.qvel, kick):\n", d.qvel.numpy())

# 4. round trip: host -> device -> step -> host
for _ in range(10):
    mjw.step(m, d)
print("ball z after 10 steps:", d.qpos.numpy()[:, 2])
print("same object and pointer:", d.qvel.ptr == ptr0)

# 5. trap: assign/copy check only that the source is not LARGER (a flat byte copy)
d.qvel.zero_()
d.qvel.assign(np.ones((NWORLD - 1, mjm.nv)))      # one world short: no error!
print("assign with (nworld-1, nv) rows -> silently fills a prefix:\n", d.qvel.numpy())
try:
    d.qvel.assign(np.ones((NWORLD + 1, mjm.nv)))
except RuntimeError as e:
    print("one world too many ->", type(e).__name__ + ":", str(e)[:58] + "...")
