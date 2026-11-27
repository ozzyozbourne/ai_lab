"""Example 20.10 - eager step time vs opt.iterations and opt.ls_iterations (CG and Newton).

opt.iterations is a runtime value; opt.ls_iterations is a compile-time constant of the
linesearch kernel, so each new value compiles once (we warm up every configuration first).
Eager stepping (no CUDA graph): the solver loop is wp.capture_while, which outside a graph
capture is a host loop that reads nsolving after every iteration and stops when all worlds are
done. On a CPU the numbers are CPU numbers and say nothing about a GPU; on Colab run it on a GPU.
Run: python ex10_solver_timing.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 200 if ON_GPU else 20

mjm = mujoco.MjModel.from_xml_string(box_stack(5))
qvel0 = np.random.default_rng(0).normal(0.0, 0.5, size=(NWORLD, mjm.nv)).astype(np.float32)

print(f"device {wp.get_device()}, box_stack(5), nworld={NWORLD}, {NSTEP} timed steps per row")
print(f"{'solver':7s} {'iters':>5s} {'ls_iters':>8s} {'ms/step':>8s} {'world-steps/s':>14s} "
      f"{'niter (last step)':>17s} {'ITER bit':>8s}")
for solver in ("CG", "NEWTON"):
    mjm.opt.solver = getattr(mujoco.mjtSolver, f"mjSOL_{solver}")
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0
    for ls_iters in (5, 20):
        m.opt.ls_iterations = ls_iters
        for iters in (1, 5, 20, 50):
            m.opt.iterations = iters
            d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
            d.qvel.assign(qvel0)
            for _ in range(3):                 # warm-up: compiles the new ls_iterations once
                mjw.step(m, d)
            wp.synchronize()
            t0 = time.perf_counter()
            for _ in range(NSTEP):
                mjw.step(m, d)
            wp.synchronize()
            dt = (time.perf_counter() - t0) / NSTEP
            it_bit = bool((d.overflow.numpy() & mjw.OverflowType.ITERATIONS).any())
            print(f"{solver:7s} {iters:5d} {ls_iters:8d} {dt * 1e3:8.2f} {NWORLD / dt:14,.0f} "
                  f"{d.solver_niter.numpy().mean():17.2f} {str(it_bit):>8s}")
