"""Example 7.10 - per-stage GPU timing with EventTracer (CUDA only; guarded on CPU).

Most pipeline functions carry @event_scope (warp_util.py). Inside an EventTracer they record a
CUDA event before and after the call and nest: step > forward > fwd_position > ... On CPU the first
event_scope would raise "Device cpu is not a CUDA device", so the tracer is built with
enabled=ON_GPU and the CPU trace is empty (_src/cli.py shows the enabled= switch, driven by its
--event_trace flag; the course passes ON_GPU so the tracer is off on CPU).
To still show the real *structure* on CPU, we then swap the CUDA events for a stand-in that counts
kernel launches: the same tree comes out, with "launches inside" in place of milliseconds.
Ch 25 owns the profiling workflow.
Run: python ex10_event_trace.py [--dump-json PATH]
"""
import argparse
import json
from unittest import mock

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.warp_util import EventTracer   # private API: may change between versions

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

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
for _ in range(100):
    mjw.step(m, d)                    # warm-up: compile outside the trace, let objects land
wp.synchronize()

with EventTracer(enabled=ON_GPU) as tracer:
    for _ in range(5):
        mjw.step(m, d)
    wp.synchronize()
    trace = tracer.trace()           # {name: ((ms per call, ...), {child: ...})}


def show(tr, unit, scale, depth=0):
    for name, (vals, sub) in tr.items():
        mean = scale * sum(vals) / len(vals)
        num = f"{mean:8.1f}" if unit == "us" else f"{int(mean):4d}"
        print(f"{'  ' * depth}{name:<{30 - 2 * depth}} calls {len(vals)} {num} {unit}")
        show(sub, unit, scale, depth + 1)


if ON_GPU:
    print(f"EventTracer on {wp.get_device()}, nworld={NWORLD}, 5 steps (your GPU numbers):")
    show(trace, "us", 1e3)            # elapsed times are milliseconds -> microseconds
else:
    print("skipped on CPU: EventTracer needs CUDA, so the trace is empty:", trace)

# Structure on any device: a stand-in "event" remembers how many launches happened so far.
COUNT = [0]


class LaunchCountEvent:
    def __init__(self, *a, **kw):
        self.n = 0


def record(ev, *a, **kw):
    ev.n = COUNT[0]


def counting(real):
    def wrapper(*a, **kw):
        COUNT[0] += 1
        return real(*a, **kw)
    return wrapper


with mock.patch.object(wp, "Event", LaunchCountEvent), \
     mock.patch.object(wp, "record_event", record), \
     mock.patch.object(wp, "get_event_elapsed_time", lambda b, e: e.n - b.n), \
     mock.patch.object(wp, "launch", counting(wp.launch)), \
     mock.patch.object(wp, "launch_tiled", counting(wp.launch_tiled)):
    with EventTracer() as tracer:
        mjw.step(m, d)
        structure = tracer.trace()
print("event_scope tree of one mjw.step (launches inside each scope, not time):")
show(structure, "launches", 1.0)


def to_json(tr):
    return [{"name": k, "launches": int(sum(v)), "children": to_json(s)} for k, (v, s) in tr.items()]


if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"model": "PLAYGROUND", "tree": to_json(structure)}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
