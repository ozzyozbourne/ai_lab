"""Example 6.6 - replacing an array is not the same as writing into it.

d.qpos.assign(x) keeps the array object (and its device pointer) and changes its contents.
d.qpos = wp.array(x) puts a NEW array on the Data object; anything that still holds the old
one (your own variables, a captured CUDA graph, Ch 24) keeps using the old memory.
Run: python ex06_replace_vs_assign.py
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

NWORLD = 4

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)

old = d.qpos                       # e.g. a reference your controller or a graph holds
ptr = d.qpos.ptr
q = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)

# A. assign: same object, same pointer, new contents
q[:, 2] = 2.0
d.qpos.assign(q)
print("A assign : old is d.qpos =", old is d.qpos, "| same ptr =", d.qpos.ptr == ptr,
      "| old z =", old.numpy()[:, 2])

# B. replace: a new object with a new pointer; 'old' is now disconnected
q[:, 2] = 3.0
d.qpos = wp.array(q, dtype=float)
print("B replace: old is d.qpos =", old is d.qpos, "| same ptr =", d.qpos.ptr == ptr,
      "| old z =", old.numpy()[:, 2])

# the simulation reads whatever d.qpos is NOW; writes through 'old' are lost
old.fill_(0.0)                     # "reset" through the stale reference: no effect on d
mjw.step(m, d)
print("after step: d.qpos z =", d.qpos.numpy()[:, 2], "| old z =", old.numpy()[:, 2])

# C. replace with the wrong dtype: fails at the next kernel launch, not at assignment
d.qpos = wp.array(q.astype(np.float64))
try:
    mjw.step(m, d)
except RuntimeError as e:
    msg = str(e)
    print("C float64 replace ->", msg[: msg.index("expects")].strip(), "... expects float32")
