"""Example 20.2 - a different solver tolerance in every world.

m.opt.tolerance is a batched option (shape ("*",)): the solver kernels read
tolerance[worldid % tolerance.shape[0]]. All four worlds hold the same falling box stack, so the
only difference is the tolerance. We print solver_niter for one cold-started solve (warmstart off,
so the solver starts from qacc_smooth) and for a warm-started one.
Note: put_model clamps the MJCF tolerance to >= 1e-6 (float32); assigning the array afterwards
bypasses that clamp, which is how 1e-8 gets in here.
Run: python ex2_tolerance_per_world.py
"""
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


TOLS = [1e-2, 1e-4, 1e-6, 1e-8]
mjm = mujoco.MjModel.from_xml_string(box_stack(5))
print("MJCF tolerance:", mjm.opt.tolerance)

for solver in ("NEWTON", "CG"):
    mjm.opt.solver = getattr(mujoco.mjtSolver, f"mjSOL_{solver}")
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0
    if solver == "NEWTON":
        print("after put_model:", m.opt.tolerance.numpy(), "(clamped to >= 1e-6)")
    d = mjw.make_data(mjm, nworld=len(TOLS), nconmax=32, njmax=128)
    for _ in range(20):                       # let the stack land: 80 active rows per world
        mjw.step(m, d)
    m.opt.tolerance = wp.array(TOLS, dtype=float)   # one value per world

    m.opt.disableflags |= mjw.DisableBit.WARMSTART
    mjw.forward(m, d)
    cold = d.solver_niter.numpy().copy()
    m.opt.disableflags &= ~mjw.DisableBit.WARMSTART
    mjw.forward(m, d)
    warm = d.solver_niter.numpy().copy()
    print(f"{solver:6s} tolerance {TOLS}")
    print(f"       niter cold start (qacc_smooth): {cold}")
    print(f"       niter warm start (last qacc):   {warm}")
    print("       nefc:", d.nefc.numpy(), " ITERATIONS bit:",
          bool((d.overflow.numpy() & mjw.OverflowType.ITERATIONS).any()))
