"""Example 5.1 - read m.opt: MuJoCo fields vs warp-only fields, arrays vs Python ints.

put_model turns mjm.opt into an mjw.Option. Continuous options become wp.arrays with a leading
batch dimension (shape (1,) by default); discrete options stay plain Python ints/bools, which
are baked into the kernels. Fields that do not exist on mujoco.MjOption are warp-only.
Run: python ex1_option_table.py
"""
import dataclasses

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

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)

mj_names = {n for n in dir(mujoco.MjOption) if not n.startswith("_")}
print(f"{'field':<24} {'kind':<20} {'value':<26} note")
for f in dataclasses.fields(m.opt):
    v = getattr(m.opt, f.name)
    if isinstance(v, wp.array):
        kind = f"array{v.shape} {v.dtype.__name__}"
        x = v.numpy()[0]
        val = f"{float(x):.6g}" if np.ndim(x) == 0 else np.array2string(x, precision=4)
    else:
        kind = type(v).__name__
        val = v.name if hasattr(v, "name") else repr(v)  # enums print their name
    note = "" if f.name in mj_names else "warp-only"
    print(f"{f.name:<24} {kind:<20} {val:<26} {note}")

print()
print("timestep:", m.opt.timestep.numpy(), "| integrator:", m.opt.integrator,
      mjw.IntegratorType(m.opt.integrator).name)
print("broadphase:", mjw.BroadphaseType(m.opt.broadphase).name,
      "| warn_overflow:", m.opt.warn_overflow, "=", int(mjw.OverflowType.ALL))
try:
    m.opt.ls_parallel
except AttributeError as e:
    print("AttributeError:", e)
