"""Example 7.5 - count the kernel launches in one mjw.step and sort them by launch shape.

wp.launch and wp.launch_tiled are wrapped with unittest.mock (the real functions still run), so
we see every launch: kernel name, the calling source line, and the launch `dim`. Each launch is
then put into one of the pipeline-wide launch-shape layouts of the atlas:
  1 (world, element) grid     dim=(nworld, n)          e.g. smooth.py kinematics
  2 flat pool slots           dim=naconmax             e.g. collision_primitive.py narrowphase
  6 tiled, block per world    wp.launch_tiled(...)     e.g. solver.py, smooth.py factor blocks
  7 3-D grid                  dim=(nworld, n, k)       e.g. solver.py jaref / jv
  8 row per contact           dim=naconmax in constraint.py
Run: python ex5_count_launches.py [--dump-json PATH]
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
SETTLE = 30                     # a few steps first, so contacts and constraints exist

HUMANOID_PATH = os.path.join(os.path.dirname(mjw.__file__), "test_data", "humanoid", "humanoid.xml")


def layout_of(dim, tiled, file, d):
    if tiled:
        return 6
    if isinstance(dim, int):
        if dim == d.naconmax:
            return 8 if file == "constraint.py" else 2
        return 1                       # dim=nworld: a (world, 1) grid
    if len(dim) == 3:
        return 7
    return 1


def record_step(m, d):
    """Run one mjw.step and return the list of launches it made."""
    log = []

    def spy(real, tiled):
        def wrapper(kernel, *a, **kw):
            dim = kw.get("dim", a[0] if a else None)
            dim = tuple(int(x) for x in dim) if isinstance(dim, (tuple, list)) else int(dim)
            caller = sys._getframe(1)               # the MJWarp line that called wp.launch
            file = os.path.basename(caller.f_code.co_filename)
            log.append({"kernel": kernel.key.split("__locals__")[0].rstrip("_"),
                        "file": file, "line": caller.f_lineno, "func": caller.f_code.co_name,
                        "dim": dim, "tiled": tiled, "block_dim": kw.get("block_dim"),
                        "layout": layout_of(dim, tiled, file, d)})
            return real(kernel, *a, **kw)
        return wrapper

    with mock.patch.object(wp, "launch", spy(wp.launch, False)), \
         mock.patch.object(wp, "launch_tiled", spy(wp.launch_tiled, True)):
        mjw.step(m, d)
    return log


results = {}
for name, mjm in (("PLAYGROUND", mujoco.MjModel.from_xml_string(PLAYGROUND)),
                  ("HUMANOID", mujoco.MjModel.from_xml_path(HUMANOID_PATH))):
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
    for _ in range(SETTLE):
        mjw.step(m, d)
    log = record_step(m, d)
    results[name] = {"nworld": NWORLD, "naconmax": d.naconmax, "njmax": d.njmax,
                     "nv": mjm.nv, "nbody": mjm.nbody, "launches": log}
    n_plain = sum(not x["tiled"] for x in log)
    by_layout = collections.Counter(x["layout"] for x in log)
    print(f"{name}: nv={mjm.nv} nbody={mjm.nbody} naconmax={d.naconmax} njmax={d.njmax}")
    print(f"  launches in one mjw.step: {len(log)} ({n_plain} wp.launch + "
          f"{len(log) - n_plain} wp.launch_tiled), solver iterations: "
          f"{int(d.solver_niter.numpy().max())}")
    n_empty = sum(int(np.prod(x["dim"])) == 0 for x in log)
    print(f"  of these, {n_empty} have an empty dim (no tendons, flex, limits...): Warp skips them")
    print("  by layout:", dict(sorted(by_layout.items())))
    for lay in (1, 2, 6, 7, 8):
        ex = next((x for x in log if x["layout"] == lay and int(np.prod(x["dim"])) > 0), None)
        if ex:
            print(f"    layout {lay}: {ex['file']}:{ex['line']} {ex['kernel']} dim={ex['dim']}"
                  + (f" block_dim={ex['block_dim']}" if ex["tiled"] else ""))
    print("  overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(results, f, separators=(",", ":"))
    print("wrote", args.dump_json)
