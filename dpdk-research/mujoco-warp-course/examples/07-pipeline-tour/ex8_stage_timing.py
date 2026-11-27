"""Example 7.8 - time each stage by hand and print its share of the step.

Kernel launches are asynchronous on a GPU, so each stage is bracketed by wp.synchronize() before
the clock is read. The stage calls use the public factorize pairing and add up to one Euler step.
Each number is the median over REPS synchronized repeats, which is steadier than a mean on a busy
machine. These are wall-clock times on whatever device runs the script: on CPU they are CPU numbers
and say nothing about GPU performance; at small nworld they are dominated by fixed per-launch cost
and vary from run to run. On GPU, launch overhead dominates small models (see the graph
teaser in the chapter, Ch 24-25 for real profiling).
Run: python ex8_stage_timing.py [--dump-json PATH]
"""
import argparse
import json
import os
import time

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
REPS = 200 if ON_GPU else 20

HUMANOID_PATH = os.path.join(os.path.dirname(mjw.__file__), "test_data", "humanoid", "humanoid.xml")
STAGES = [("fwd_position", mjw.fwd_position), ("fwd_velocity", mjw.fwd_velocity),
          ("fwd_actuation", mjw.fwd_actuation), ("fwd_acceleration", mjw.fwd_acceleration),
          ("solve", mjw.solve), ("euler", mjw.euler)]

out = {"device": str(wp.get_device()), "nworld": NWORLD, "reps": REPS, "models": {}}
for name, mjm in (("PLAYGROUND", mujoco.MjModel.from_xml_string(PLAYGROUND)),
                  ("HUMANOID", mujoco.MjModel.from_xml_path(HUMANOID_PATH))):
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
    for _ in range(30):                     # warm-up: compile, settle contacts
        mjw.step(m, d)
    for s, fn in STAGES:                    # the stage path compiles different kernels
        fn(m, d)                            # (factor_m + solve_m instead of the fused solve)
    wp.synchronize()
    times = {s: [] for s, _ in STAGES}
    for _ in range(REPS):
        for s, fn in STAGES:
            t0 = time.perf_counter()
            fn(m, d)
            wp.synchronize()
            times[s].append(time.perf_counter() - t0)
    step_t = []
    for _ in range(REPS):
        t0 = time.perf_counter()
        mjw.step(m, d)
        wp.synchronize()
        step_t.append(time.perf_counter() - t0)
    step_ms = 1e3 * float(np.median(step_t))      # median of REPS synchronized steps
    stage_ms = {s: 1e3 * float(np.median(t)) for s, t in times.items()}
    sum_ms = sum(stage_ms.values())
    print(f"{name} on {wp.get_device()}, nworld={NWORLD}, median of {REPS}: mjw.step {step_ms:.2f} ms, "
          f"sum of stage medians {sum_ms:.2f} ms, {NWORLD / step_ms * 1e3:,.0f} world-steps/s")
    for s, t in stage_ms.items():
        bar = "#" * int(round(40 * t / sum_ms))
        print(f"  {s:<17}{t:7.3f} ms {100 * t / sum_ms:5.1f}%  {bar}")
    out["models"][name] = {"step_ms": round(step_ms, 3),
                           "stage_ms": {s: round(t, 3) for s, t in stage_ms.items()}}
    print("  overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
