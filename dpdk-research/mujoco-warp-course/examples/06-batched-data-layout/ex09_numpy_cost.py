"""Example 6.10 - what a .numpy() call costs inside a stepping loop.

arr.numpy() on a GPU array allocates host memory, copies device -> host and WAITS for every
queued kernel (a synchronization). An eager GPU mjw.step already syncs inside the solver
(wp.capture_while checks its counter on the host), so a read every step adds one more sync
plus the copy. We time NSTEP steps with a read every step against one read at the end.
Each variant runs once untimed first, then the two alternate for 3 repetitions and we keep the
minimum of each, so neither pays for being the first timed loop.
On the CPU device .numpy() is a view (no copy, no wait), so the gap is within timing noise;
on a GPU expect a larger gap (device -> host copy + sync), how large depends on the GPU and nworld.
Run: python ex09_numpy_cost.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

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
NWORLD = 4096 if ON_GPU else 64
NSTEP = 100

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
mjw.step(m, d)                     # warm up: JIT compile happens here, not in the timing
wp.synchronize()


def run(read_every_step):
    mjw.reset_data(m, d)
    wp.synchronize()
    t0 = time.perf_counter()
    zs = []
    for _ in range(NSTEP):
        mjw.step(m, d)
        if read_every_step:
            zs.append(d.qpos.numpy()[:, 2].copy())   # GPU: copy + sync; CPU: a view, so .copy()
    if not read_every_step:
        zs = d.qpos.numpy()[:, 2].copy()         # one read at the end
    wp.synchronize()
    return time.perf_counter() - t0, zs


run(False)                         # one untimed pass of each variant: the first timed loop
run(True)                          # after a fresh step is slower whatever it does
t_each, t_once = float("inf"), float("inf")
for _ in range(3):                 # alternate the order, keep the minimum of 3
    t_each = min(t_each, run(True)[0])
    t_once = min(t_once, run(False)[0])
dev = "GPU" if ON_GPU else "CPU dev box"
print(f"device: {wp.get_device()} ({dev}), nworld={NWORLD}, nstep={NSTEP}")
print(f"read every step: {1e3 * t_each / NSTEP:8.3f} ms/step")
print(f"read once      : {1e3 * t_once / NSTEP:8.3f} ms/step")
print(f"ratio          : {t_each / t_once:8.2f}x")
