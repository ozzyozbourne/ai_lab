"""Example 6.9 - read the shape rules from the library itself.

Two sources describe every field: the class docstring (human-readable, NumPy-style shapes
with the vector tail, e.g. "(nworld, nbody, 3)") and the declared spec on the dataclass
field (types.py::array, e.g. ('nworld', 'nbody') with dtype vec3). We print both next to
the shapes of a real Data/Model made by my_env.make_worlds.
Run: python ex11_docstring_specs.py   (my_env_step06.py must be next to it)
"""
import dataclasses
import os
import re
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

sys.path.insert(0, os.path.dirname(os.path.abspath(globals().get("__file__", "my_env.py"))))
sys.dont_write_bytecode = True                # no __pycache__ next to the examples
try:
    from my_env import make_worlds            # notebook / project copy
except ImportError:
    from my_env_step06 import make_worlds     # examples/06-batched-data-layout/

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


def doc_shapes(cls):
    """Map field name -> shape string from the 'Attributes:' block of a class docstring."""
    out = {}
    for line in cls.__doc__.splitlines():
        hit = re.match(r"\s+(\w+): .*?(\([^()]*\))\s*$", line)
        if hit:
            out[hit.group(1)] = hit.group(2)
    return out


def spec(cls, name):
    """The declared dims of a dataclass field (the arguments of types.array)."""
    f = next(f for f in dataclasses.fields(cls) if f.name == name)
    return getattr(f.type, "shape", None), getattr(f.type, "dtype", None)


mjm, m, d = make_worlds(PLAYGROUND, nworld=8, nconmax=16, njmax=64)
print(f"make_worlds -> nworld={d.nworld}, nq={mjm.nq}, nbody={mjm.nbody}, naconmax={d.naconmax}")
print(f"{'field':<12}{'docstring':<24}{'spec':<30}{'warp':<9}{'numpy':<13}")
rows = [(mjw.Data, d, n) for n in ("qpos", "xpos", "xquat", "xmat", "sensordata", "nacon")]
rows += [(mjw.Contact, d.contact, n) for n in ("pos", "frame", "worldid")]
rows += [(mjw.Model, m, n) for n in ("body_mass", "geom_size", "geom_type")]
for cls, obj, name in rows:
    dims, dtype = spec(cls, name)
    arr = getattr(obj, name)
    spec_txt = f"({', '.join(map(str, dims))}) {dtype.__name__}"
    print(f"{name:<12}{doc_shapes(cls).get(name, '?'):<24}{spec_txt:<30}"
          f"{str(arr.shape):<9}{str(arr.numpy().shape):<13}")
