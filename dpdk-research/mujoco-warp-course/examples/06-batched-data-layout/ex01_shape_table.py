"""Example 6.1 - the nworld-first rule: print the shape table of mjw.Data.

Every Data array starts with an nworld dimension (one row per world). Vector dtypes
(vec3, quat, mat33, spatial_vector) add trailing dimensions only in the NumPy view.
Run: python ex01_shape_table.py
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

NWORLD = 4  # shapes only: a small nworld keeps the table readable on CPU and GPU

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
print(f"nq={mjm.nq} nv={mjm.nv} nu={mjm.nu} nbody={mjm.nbody} ngeom={mjm.ngeom} nworld={d.nworld}")
print(f"{'field':<16}{'warp shape':<14}{'dtype':<17}{'numpy shape':<14}")

scalars, rows, total, not_world = [], 0, 0, []
for f in dataclasses.fields(d):
    arr = getattr(d, f.name)
    if not isinstance(arr, wp.array):
        continue
    total += 1
    if arr.size and arr.shape[0] != d.nworld:  # (empty workspaces are skipped)
        not_world.append(f.name)
    if arr.shape == (d.nworld,) and arr.dtype in (wp.int32, wp.float32):
        scalars.append(f.name)  # one number per world: summarized below
        continue
    if arr.size == 0 or rows >= 25:
        continue  # skip empty arrays (this model has no mocap, act, ...)
    np_shape = arr.numpy().shape  # vector dtypes append their length here
    print(f"{f.name:<16}{str(arr.shape):<14}{arr.dtype.__name__:<17}{str(np_shape):<14}")
    rows += 1
print(f"(nworld,) scalars: {', '.join(scalars)}")
print(f"{total} top-level arrays in Data; non-empty ones without a leading nworld: {not_world}")

print("-- pooled and per-world sub-structs --")
for name in ("contact.pos", "contact.worldid", "efc.force", "efc.J", "nacon", "nefc"):
    obj = d
    for part in name.split("."):
        obj = getattr(obj, part)
    print(f"{name:<16}{str(obj.shape):<14}{obj.dtype.__name__:<17}")
print(f"naconmax={d.naconmax} (nconmax 16 x nworld {d.nworld}), njmax={d.njmax} per world")
