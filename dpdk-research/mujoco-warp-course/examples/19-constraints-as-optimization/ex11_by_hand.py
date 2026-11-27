"""Example 19.11 - run the constraint stages by hand: make_constraint, then solve.

forward() already calls collision -> make_constraint -> ... -> solve. Here we let three stacked
boxes settle, run forward once and keep qacc, then call mjw.make_constraint(m, d) and
mjw.solve(m, d) ourselves. make_constraint rebuilds the efc rows from the current contacts and
kinematics; solve needs qacc_smooth, qfrc_smooth and the factorized M that forward left in d.
The result must be identical. Then we disable warmstart and solve again from qacc_smooth: the
same answer within float32 noise. Newton still needs one iteration: at qacc_smooth (free fall)
every contact row is active, the optimum has the same active set, and one Newton step on a
single quadratic piece is exact (section 2 of the chapter).
Run: python ex11_by_hand.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
NSTEP = 1000 if ON_GPU else 40

mjm = mujoco.MjModel.from_xml_string(box_stack(3))
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
for _ in range(NSTEP):
    mjw.step(m, d)

mjw.forward(m, d)
qacc_fwd = d.qacc.numpy().copy()
force_fwd = d.efc.force.numpy().copy()
niter_fwd = d.solver_niter.numpy().copy()
print("nv", mjm.nv, "| nefc", d.nefc.numpy()[:2], "| nacon", d.nacon.numpy(),
      "| solver_niter after forward", niter_fwd[:2])

mjw.make_constraint(m, d)                       # rows from d.contact and the kinematics
mjw.solve(m, d)                                 # uses qacc_smooth, qfrc_smooth, qLD from forward
print("max |qacc(by hand) - qacc(forward)| =", float(np.abs(d.qacc.numpy() - qacc_fwd).max()))
print("max |efc.force difference|         =", float(np.abs(d.efc.force.numpy() - force_fwd).max()))

m.opt.disableflags |= mjw.DisableBit.WARMSTART  # start from qacc_smooth instead
mjw.solve(m, d)
print("no warmstart: solver_niter", d.solver_niter.numpy()[:2],
      "| max |qacc - qacc(forward)| =", f"{np.abs(d.qacc.numpy() - qacc_fwd).max():.1e}")
m.opt.disableflags &= ~mjw.DisableBit.WARMSTART
print("box z:", d.qpos.numpy()[0, [2, 9, 16]])
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
