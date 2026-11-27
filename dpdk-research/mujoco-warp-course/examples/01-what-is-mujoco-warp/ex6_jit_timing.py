"""Example 1.6 - why the first mjw.step is slow: JIT compilation and the kernel cache.

Times the first and the second step, counts the kernel launches inside one step, and prints
where Warp keeps compiled kernels.
Run: python ex6_jit_timing.py [--cold] [--dump-json PATH]
  --cold uses an empty, temporary kernel cache, so every kernel is compiled from scratch (slow).
  --dump-json PATH writes the three step times for the page's bar chart (Rule D).
"""
import argparse
import json
import shutil
import tempfile
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

parser = argparse.ArgumentParser()
parser.add_argument("--cold", action="store_true")
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()
cold_root = None
if args.cold:
    cold_root = tempfile.mkdtemp(prefix="warp-cold-")   # Warp adds a version subfolder inside it
    wp.config.kernel_cache_dir = cold_root               # before wp.init()
wp.init()

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

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)

times = []
for _ in range(3):
    t0 = time.perf_counter()
    mjw.step(m, d)
    wp.synchronize()                   # wait for the device before reading the clock
    times.append(time.perf_counter() - t0)

# Count kernel launches in one step by wrapping wp.launch / wp.launch_tiled for a moment.
counts = {"launch": 0, "launch_tiled": 0}
orig = {k: getattr(wp, k) for k in counts}


def counting(name):
    def f(*a, **kw):
        counts[name] += 1
        return orig[name](*a, **kw)
    return f


for k in counts:
    setattr(wp, k, counting(k))
mjw.step(m, d)
for k in counts:
    setattr(wp, k, orig[k])

print("device:", wp.get_device(), "| nworld:", NWORLD, "| cold cache:", args.cold)
print(f"1st step: {times[0]:8.3f} s   (compile or load every kernel module)")
print(f"2nd step: {times[1]:8.4f} s")
print(f"3rd step: {times[2]:8.4f} s")
print(f"first / second: {times[0] / times[1]:.0f}x")
print("kernel launches in one mjw.step:", counts["launch"], "wp.launch +",
      counts["launch_tiled"], "wp.launch_tiled")
print("kernel cache dir:", wp.config.kernel_cache_dir)
if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"device": str(wp.get_device()), "nworld": NWORLD, "cold": args.cold,
                   "times": [round(t, 5) for t in times], "launch": counts["launch"],
                   "launch_tiled": counts["launch_tiled"]}, f)
    print("wrote", args.dump_json)
if cold_root:
    shutil.rmtree(cold_root, ignore_errors=True)   # tidy up the whole temporary cache folder
