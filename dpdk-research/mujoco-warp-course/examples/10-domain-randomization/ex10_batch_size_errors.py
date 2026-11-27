"""Example 10.10 - what put_model(batch_sizes=...) refuses, and the fix for m.opt fields.

batch_sizes keys must be top-level Model fields whose type spec starts with "*" (io.py::put_model).
m.opt.* arrays are "*" too, but they live in the nested Option dataclass, so they can only be
replaced. Integer topology fields such as geom_type are shared and cannot be batched at all.
Run: python ex10_batch_size_errors.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

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

for request in ({"opt.timestep": 4}, {"geom_type": 4}, {"nbody": 4}, {"body_mass": 0}):
    try:
        mjw.put_model(mjm, batch_sizes=request)
        print(f"{request}: accepted")
    except ValueError as e:
        print(f"{request}: ValueError: {e}")

# the fix for opt fields: replace the array after put_model
m = mjw.put_model(mjm)
m.opt.timestep = wp.array(np.full(4, 0.002), dtype=float)
print("replaced m.opt.timestep:", m.opt.timestep.shape)
print("geom_type stays shared:", m.geom_type.shape, m.geom_type.numpy())
