"""Example 6.7 - which Model fields can vary per world?

Numeric parameters have a leading batch dimension B (default 1, shared by all worlds).
Structural fields (types, ids, addresses) have no batch dimension: all worlds share topology.
Run: python ex02_model_batched.py
"""
import dataclasses

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

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)

for name, arr in [("body_mass", m.body_mass), ("geom_size", m.geom_size),
                  ("opt.gravity", m.opt.gravity), ("geom_type", m.geom_type),
                  ("body_parentid", m.body_parentid)]:
    print(f"{name:<14}{str(arr.shape):<9}{arr.dtype.__name__:<9}"
          f"batched: {getattr(arr, '_is_batched', False)}")
print("nq (Python int):", m.nq, type(m.nq).__name__)


def count(obj, prefix=""):
    """Count warp arrays in a (nested) dataclass and how many carry _is_batched."""
    n_arr = n_bat = 0
    names = []
    for f in dataclasses.fields(obj):
        val = getattr(obj, f.name, None)
        if dataclasses.is_dataclass(val):
            a, b, sub = count(val, prefix + f.name + ".")
            n_arr, n_bat, names = n_arr + a, n_bat + b, names + sub
        elif isinstance(val, wp.array):
            n_arr += 1
            if getattr(val, "_is_batched", False):
                n_bat += 1
                names.append(prefix + f.name)
    return n_arr, n_bat, names


n_arr, n_bat, names = count(m)
print(f"Model arrays: {n_arr}, batched ('*' spec): {n_bat}, structural: {n_arr - n_bat}")
print("first batched fields:", names[:8])


def star_specs(cls):
    """Fields whose declared spec (types.py::array) starts with '*'."""
    return sum(1 for f in dataclasses.fields(cls) if getattr(f.type, "shape", ())[:1] == ("*",))


print(f"'*' specs declared: Model {star_specs(mjw.Model)} + Option {star_specs(mjw.Option)}"
      f" = {star_specs(mjw.Model) + star_specs(mjw.Option)}")

# batch_sizes: allocate a per-world copy of chosen fields at put_model time
m4 = mjw.put_model(mjm, batch_sizes={"body_mass": 4, "geom_friction": 4})
print("with batch_sizes: body_mass", m4.body_mass.shape, "geom_friction", m4.geom_friction.shape)
print("body_mass rows identical:", bool((m4.body_mass.numpy() == m4.body_mass.numpy()[0]).all()))
