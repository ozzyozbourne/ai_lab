"""Example 20.8 - EXPERIMENTAL: opt.run_qacc_smooth = False (warmstarted Newton without qacc_smooth).

With run_qacc_smooth False (and Newton, warmstart on, noslip off, iterations > 0, njmax > 0:
smooth.skip_qacc_smooth), fwd_acceleration skips smooth.factor_solve_i: no M factorization and
no qacc_smooth solve. Newton then starts every world from qacc_warmstart and never needs M^-1.
We run box_stack(5) for 200 steps both ways from identical kicked states and compare the time
per step (CPU here: a CPU number says nothing about a GPU) and the trajectories.
Run: python ex8_run_qacc_smooth.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import smooth  # private API: only to print the skip test


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 200

mjm = mujoco.MjModel.from_xml_string(box_stack(5))      # Newton is the default solver
qvel0 = np.random.default_rng(0).normal(0.0, 0.2, size=(NWORLD, mjm.nv)).astype(np.float32)

runs = {}
for flag in (True, False):
    m = mjw.put_model(mjm)
    m.opt.run_qacc_smooth = flag
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
    print(f"run_qacc_smooth={flag}: skip_qacc_smooth -> {smooth.skip_qacc_smooth(m, d)}")
    d.qvel.assign(qvel0)
    mjw.step(m, d)                                       # warm up (JIT compile)
    d.qvel.assign(qvel0)
    d.qpos.assign(np.tile(mjm.qpos0, (NWORLD, 1)))
    d.qacc_warmstart.zero_()
    d.time.zero_()
    wp.synchronize()
    t0 = time.perf_counter()
    for _ in range(NSTEP):
        mjw.step(m, d)                                   # no host readback inside the timed loop
    wp.synchronize()
    dt = (time.perf_counter() - t0) / NSTEP
    runs[flag] = d.qpos.numpy().copy()
    print(f"  {dt * 1e3:7.2f} ms/step (device {wp.get_device()}), mean niter "
          f"(last step) {d.solver_niter.numpy().mean():.2f}, overflow "
          f"{'none' if not d.overflow.numpy().any() else d.overflow.numpy()}")
    print(f"  max |d.qacc_smooth| = {np.abs(d.qacc_smooth.numpy()).max():.3f}"
          f"{'  (never computed: stale)' if not flag else ''}")

dq = np.abs(runs[True] - runs[False])
print(f"after {NSTEP} steps: max |dqpos| = {dq.max():.2e}, mean = {dq.mean():.2e}")
print("top box z, first 4 worlds (default):     ", np.round(runs[True][:4, 4 * 7 + 2], 4))
print("top box z, first 4 worlds (experimental):", np.round(runs[False][:4, 4 * 7 + 2], 4))
