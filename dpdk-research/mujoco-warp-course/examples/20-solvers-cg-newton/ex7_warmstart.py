"""Example 20.7 - what warmstart buys: solver_niter with and without DisableBit.WARMSTART.

With warmstart on (the default), _solve_init_dof starts each world from qacc_warmstart, the qacc
of the previous step (written by step after integration), whenever the world has constraint rows.
With it off, every solve starts from qacc_smooth. Two scenes: box_stack(5) worlds that get random
kicks (lots of motion) and the same stack resting from the start (the common case in RL: most
contacts persist from step to step).
Run: python ex7_warmstart.py
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


ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 50

mjm = mujoco.MjModel.from_xml_string(box_stack(5))
kicked = np.random.default_rng(0).normal(0.0, 0.5, size=(NWORLD, mjm.nv)).astype(np.float32)
resting = np.zeros_like(kicked)

print(f"box_stack(5), nworld={NWORLD}, {NSTEP} steps; niter over all worlds and steps")
for scene, qvel0, solver in (("kicked", kicked, "NEWTON"), ("kicked", kicked, "CG"),
                             ("resting", resting, "NEWTON"), ("resting", resting, "CG")):
    mjm.opt.solver = getattr(mujoco.mjtSolver, f"mjSOL_{solver}")
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0
    for warm in (True, False):
        if warm:
            m.opt.disableflags &= ~mjw.DisableBit.WARMSTART
        else:
            m.opt.disableflags |= mjw.DisableBit.WARMSTART
        d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
        d.qvel.assign(qvel0)
        niter = []
        for _ in range(NSTEP):
            mjw.step(m, d)
            niter.append(d.solver_niter.numpy().copy())
        niter = np.concatenate(niter)
        q = np.percentile(niter, [50, 90, 100]).astype(int)
        label = "warmstart on " if warm else "warmstart off"
        print(f"  {scene:7s} {solver:6s} {label}: mean {niter.mean():6.2f}  median {q[0]:3d}  "
              f"p90 {q[1]:3d}  max {q[2]:3d}  ITERATIONS bit: "
              f"{bool((d.overflow.numpy() & mjw.OverflowType.ITERATIONS).any())}")
