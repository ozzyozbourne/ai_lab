"""Example 21.5 - what sleep buys: step time of a resting clutter scene, awake vs asleep.

A 4 x 4 grid of resting boxes (16 trees, nv = 96). We time mjw.step in three states:
  off    sleep disabled (the normal pipeline),
  awake  sleep enabled, first steps (every countdown starts at -11, so all trees are awake),
  asleep sleep enabled, after every tree has fallen asleep.
CPU numbers are from Warp's CPU device and say nothing about GPU speed; the notebook prints your
own GPU numbers. On CPU the sleep path is slower: solver.solve_compact turns graph_conditional off
off-CUDA, so the compacted Newton loop runs all opt.iterations instead of stopping at convergence.
What carries over to the GPU is the work count: asleep worlds have no contacts and no efc rows.

Run: python ex5_sleep_cost.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NTIME = 100 if ON_GPU else 8           # timed steps per state


def clutter_xml(sleep):
    flag = '<flag sleep="enable"/>' if sleep else ""
    bodies = "".join(
        f'<body pos="{0.3 * (i % 4):.2f} {0.3 * (i // 4):.2f} 0.099"><freejoint/>'
        f'<geom type="box" size=".1 .1 .1"/></body>' for i in range(16))
    return (f'<mujoco><option timestep="0.01" solver="Newton">{flag}</option><worldbody>'
            f'<geom type="plane" size="5 5 .1"/>{bodies}</worldbody></mujoco>')


def time_steps(m, d, n):
    wp.synchronize()
    t0 = time.perf_counter()
    for _ in range(n):
        mjw.step(m, d)
    wp.synchronize()
    return (time.perf_counter() - t0) / n


results, work = {}, {}
for sleep in (False, True):
    mjm = mujoco.MjModel.from_xml_string(clutter_xml(sleep))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=96, njmax=512)
    warm = mjw.make_data(mjm, nworld=NWORLD, nconmax=96, njmax=512)
    for _ in range(3):
        mjw.step(m, warm)                  # JIT compile + warm up on a throwaway Data
    if not sleep:
        results["off"] = (time_steps(m, d, NTIME), d)
        work["off"] = (d.nacon.numpy()[0], d.nefc.numpy()[0])
        continue
    results["awake"] = (time_steps(m, d, NTIME), d)   # countdowns still running: all awake
    work["awake"] = (d.nacon.numpy()[0], d.nefc.numpy()[0])
    print("awake state:  ntree_awake", d.ntree_awake.numpy()[0])
    for _ in range(200):
        mjw.step(m, d)
        if d.ntree_awake.numpy().max() == 0:
            break
    mjw.step(m, d)                          # one step in the asleep state before timing
    print("asleep state: ntree_awake", d.ntree_awake.numpy()[0])
    results["asleep"] = (time_steps(m, d, NTIME), d)
    work["asleep"] = (d.nacon.numpy()[0], d.nefc.numpy()[0])

dev = "GPU" if ON_GPU else "CPU dev box"
for k, (dt, _) in results.items():
    nacon, nefc = work[k]
    print(f"{k:7s} {dt * 1e3:8.2f} ms/step  {NWORLD / dt:9.0f} world-steps/s  ({dev})"
          f"  nacon (all worlds) {nacon:4d}  nefc w0 {nefc:4d}")
print(f"asleep vs off: {results['off'][0] / results['asleep'][0]:.2f}x speed-up ({dev})")
print(f"asleep vs awake (sleep on): {results['awake'][0] / results['asleep'][0]:.2f}x speed-up")
print("overflow:", "none" if not any(r[1].overflow.numpy().any() for r in results.values())
      else "set")
