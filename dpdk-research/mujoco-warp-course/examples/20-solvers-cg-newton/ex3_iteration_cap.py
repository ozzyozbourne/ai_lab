"""Example 20.3 - capping the solver: opt.iterations, ITERATIONS and LS_ITERATIONS overflow bits.

CG on a landed box_stack(5), cold-started (warmstart off) so it needs many iterations.
Part 1 caps opt.iterations at 1, 5, 20 and 100 (a runtime value: no recompile) and prints
solver_niter, the ITERATIONS bit and the z acceleration of the bottom box against a converged
Newton reference. Part 2 sets opt.ls_iterations = 1 (a compile-time constant of the linesearch
kernel: this recompiles it) and shows the LS_ITERATIONS bit (1 << 10) and the kernel's printf.
Run: python ex3_iteration_cap.py
"""
import sys

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


def bits(d):
    ov = int(d.overflow.numpy()[0])
    return [b.name for b in mjw.OverflowType if ov & b] or ["none"]


mjm = mujoco.MjModel.from_xml_string(box_stack(5))
m = mjw.put_model(mjm)                       # Newton (default) for the settle run and reference
d = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)
for _ in range(20):
    mjw.step(m, d)
m.opt.disableflags |= mjw.DisableBit.WARMSTART
mjw.forward(m, d)
ref = d.qacc.numpy()[0, 2]
print(f"Newton reference: niter {d.solver_niter.numpy()[0]}, qacc[2] = {ref:.5f}")

mjm.opt.solver = mujoco.mjtSolver.mjSOL_CG
m = mjw.put_model(mjm)
m.opt.disableflags |= mjw.DisableBit.WARMSTART
m.opt.warn_overflow = 0                      # silence printf for part 1 (read the bits instead)
print("\nPart 1: CG with an iteration cap")
for cap in (1, 5, 20, 100):
    m.opt.iterations = cap
    d2 = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)   # fresh Data: bits are sticky
    for name in ("qpos", "qvel", "qacc_warmstart"):
        getattr(d2, name).assign(getattr(d, name).numpy())
    mjw.forward(m, d2)
    q2 = d2.qacc.numpy()[0, 2]
    print(f"  iterations={cap:3d}: niter {d2.solver_niter.numpy()[0]:3d}  overflow {bits(d2)}  "
          f"qacc[2] = {q2:9.5f}  (error {abs(q2 - ref):.1e})")

print("\nPart 2: ls_iterations = 1 (recompiles the linesearch kernel)")
m.opt.iterations = 100
m.opt.disableflags &= ~mjw.DisableBit.WARMSTART
m.opt.ls_iterations = 1
d3 = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)
rng = np.random.default_rng(0)
d3.qvel.assign(rng.normal(0.0, 0.5, size=(1, mjm.nv)).astype(np.float32))   # a kicked stack
for step in range(40):
    snap = {k: getattr(d3, k).numpy().copy() for k in ("qpos", "qvel", "qacc_warmstart")}
    mjw.step(m, d3)
    if d3.overflow.numpy()[0] & mjw.OverflowType.LS_ITERATIONS:
        break
print(f"  first LS_ITERATIONS overflow at step {step}: overflow {bits(d3)}")

# replay that step with the warning switched on (warn_overflow is read through wp.static:
# changing it recompiles the kernels that print)
m.opt.warn_overflow = int(mjw.OverflowType.LS_ITERATIONS)
d4 = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)
for k, v in snap.items():
    getattr(d4, k).assign(v)
sys.stdout.flush()
mjw.forward(m, d4)
wp.synchronize()                             # the kernel printf goes straight to the C stdout
sys.stdout.flush()
ov = int(d4.overflow.numpy()[0])
print(f"  replayed: niter {d4.solver_niter.numpy()[0]}, overflow = {ov} -> {bits(d4)}")
print("  LS_ITERATIONS set:", bool(ov & mjw.OverflowType.LS_ITERATIONS), f"(1 << 10 = {1 << 10})")
