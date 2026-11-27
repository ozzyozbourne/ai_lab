"""Example 7.6 - list the kernels of one mjw.step in launch order, tagged with their stage.

Every wp.launch / wp.launch_tiled call is recorded with its kernel name and source file. Walking
up the Python call stack to the nearest pipeline function (kinematics, crb, collision, ...)
tells us which stage of the breadcrumb launched it. The order you see IS the stage order.
Run: python ex6_kernel_names.py [--dump-json PATH]
"""
import argparse
import collections
import json
import os
import sys
from unittest import mock

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

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 50
SETTLE = 150

# Python function name in the call stack -> breadcrumb station
STATION = {
    "kinematics": "kinematics", "com_pos": "kinematics", "camlight": "kinematics",
    "flex": "kinematics", "tendon": "kinematics",
    "crb": "crb", "tendon_armature": "crb", "factor_m": "crb",
    "collision": "collision", "make_constraint": "make_constraint",
    "transmission": "transmission", "sensor_pos": "sensor_pos",
    "fwd_velocity": "velocity", "sensor_vel": "sensor_vel",
    "fwd_actuation": "actuation", "fwd_acceleration": "acceleration", "solve": "solve",
    "rne_postconstraint": "rne_post", "sensor_acc": "sensor_acc",
    "euler": "integrate", "implicit": "integrate", "rungekutta4": "integrate",
}


def station_of(frame):
    while frame is not None:
        name = frame.f_code.co_name
        if name in STATION and "mujoco_warp" in frame.f_code.co_filename:
            return STATION[name]
        frame = frame.f_back
    return "?"


mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
d.ctrl.assign(np.linspace(-1.0, 1.0, NWORLD, dtype=np.float32).reshape(NWORLD, 1))
for _ in range(SETTLE):
    mjw.step(m, d)

log = []


def spy(real):
    def wrapper(kernel, *a, **kw):
        dim = kw.get("dim", a[0] if a else None)
        size = int(np.prod(dim)) if isinstance(dim, (tuple, list)) else int(dim)
        caller = sys._getframe(1)
        log.append({"kernel": kernel.key.split("__locals__")[0].rstrip("_"),
                    "file": os.path.basename(caller.f_code.co_filename),
                    "station": station_of(caller), "empty": size == 0})
        return real(kernel, *a, **kw)
    return wrapper


with mock.patch.object(wp, "launch", spy(wp.launch)), \
     mock.patch.object(wp, "launch_tiled", spy(wp.launch_tiled)):
    mjw.step(m, d)

print(f"PLAYGROUND, one mjw.step: {len(log)} launches. First 40 in order (* = empty dim):")
for i, x in enumerate(log[:40]):
    print(f"{i:3d} {x['station']:<16}{x['kernel'] + ('*' if x['empty'] else ''):<36}{x['file']}")
counts = collections.Counter(x["station"] for x in log)
print("launches per station:", dict(counts))

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"model": "PLAYGROUND", "nworld": NWORLD, "launches": log}, f,
                  separators=(",", ":"))
    print("wrote", args.dump_json, len(log), "launches")
