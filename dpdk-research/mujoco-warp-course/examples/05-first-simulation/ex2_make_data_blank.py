"""Example 5.3 - make_data leaves derived fields blank until forward fills them.

make_data tiles qpos0 into every world and seeds a few poses (body orientations, static geoms),
but body positions such as d.xpos stay zero until you call mjw.forward (or mjw.step).
forward computes everything except integration, so d.time does not move.
Run: python ex2_make_data_blank.py
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
d = mjw.make_data(mjm, nworld=4, nconmax=4, njmax=16)

print("qpos (tiled qpos0), world 0:", d.qpos.numpy()[0])
print("after make_data : xpos[0, 1] =", d.xpos.numpy()[0, 1], "| time =", d.time.numpy())
print("seeded by make_data: xquat[0, 1] =", d.xquat.numpy()[0, 1],
      "| geom_xpos[0, 1] =", d.geom_xpos.numpy()[0, 1])

mjw.forward(m, d)
print("after forward   : xpos[0, 1] =", d.xpos.numpy()[0, 1], "| time =", d.time.numpy())
print("qacc world 0 (gravity only):", d.qacc.numpy()[0])

mjw.step(m, d)
print("after one step  : time =", d.time.numpy())
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
