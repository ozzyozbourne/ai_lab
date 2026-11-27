"""Example 6.12 - when is MJWarp faster than C MuJoCo? World-steps per second vs nworld.

Eager stepping (no CUDA graph) of BALL_DROP for several nworld, next to C MuJoCo's
single-world mj_step. Each mjw.step is a sequence of kernel launches whose fixed cost does
not depend on nworld, so throughput grows with nworld until the device is full.
CPU numbers are from Warp's CPU device ("on a CPU dev box"), NOT GPU performance.
Run: python ex12_throughput_vs_nworld.py [--dump-json PATH]
"""
import argparse
import json
import time

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

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLDS = [1, 16, 256, 4096] if ON_GPU else [1, 4, 16, 64]
NSTEP = 200 if ON_GPU else 50

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)

# --- C MuJoCo, one world, float64 on the host CPU -------------------------------------
mjd = mujoco.MjData(mjm)
n_c = 2000
t0 = time.perf_counter()
for _ in range(n_c):
    mujoco.mj_step(mjm, mjd)
c_rate = n_c / (time.perf_counter() - t0)

# --- count kernel launches in one mjw.step (wrap wp.launch for one call; demo only) ------
counts = {"n": 0}
real_launch, real_tiled = wp.launch, wp.launch_tiled


def counting(fn):
    def wrapper(*a, **k):
        counts["n"] += 1
        return fn(*a, **k)
    return wrapper


d = mjw.make_data(mjm, nworld=1, nconmax=4, njmax=16)
mjw.step(m, d)                                  # JIT compile outside the count
wp.launch, wp.launch_tiled = counting(real_launch), counting(real_tiled)
mjw.step(m, d)
wp.launch, wp.launch_tiled = real_launch, real_tiled
print(f"kernel launches per mjw.step (BALL_DROP): {counts['n']}")

# --- MJWarp, eager stepping -------------------------------------------------------------
def time_steps(d, nstep):
    wp.synchronize()
    t0 = time.perf_counter()
    for _ in range(nstep):
        mjw.step(m, d)
    wp.synchronize()                            # wait for the device before reading the clock
    return time.perf_counter() - t0


# one discarded timed pass: the first timed loop in a process is slower whatever nworld is
time_steps(mjw.make_data(mjm, nworld=NWORLDS[0], nconmax=4, njmax=16), NSTEP)

rows = []
for nworld in NWORLDS:
    d = mjw.make_data(mjm, nworld=nworld, nconmax=4, njmax=16)
    for _ in range(30):
        mjw.step(m, d)                          # warm up: compile is cached, caches get hot
    dt = time_steps(d, NSTEP)
    rows.append({"nworld": nworld, "step_ms": 1e3 * dt / NSTEP, "rate": nworld * NSTEP / dt})
    assert not d.overflow.numpy().any()

dev = f"{wp.get_device()} ({'GPU' if ON_GPU else 'CPU dev box, not GPU performance'})"
print(f"device: {dev}, nstep={NSTEP}, eager (no graph)")
print(f"C MuJoCo mj_step, 1 world: {c_rate:12,.0f} steps/s")
print(f"{'nworld':>7} {'ms/step':>9} {'world-steps/s':>15} {'vs C':>8}")
for r in rows:
    print(f"{r['nworld']:>7} {r['step_ms']:>9.3f} {r['rate']:>15,.0f} {r['rate'] / c_rate:>7.4f}x")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"device": str(wp.get_device()), "on_gpu": ON_GPU, "nstep": NSTEP,
                   "launches_per_step": counts["n"], "c_rate": round(c_rate, 1),
                   "rows": [{k: round(v, 4) for k, v in r.items()} for r in rows]}, f)
    print("wrote", args.dump_json)
