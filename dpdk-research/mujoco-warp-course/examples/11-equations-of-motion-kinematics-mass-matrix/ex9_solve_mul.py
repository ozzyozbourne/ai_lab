"""Example 11.9 - factor_m, solve_m and mul_m: x = M^-1 y and back again.

BALL_DROP (shared model M1): one free sphere, mass 1, radius 0.1. Its inertia is
2/5 m r^2 = 0.004 about every axis, and the free joint's 6 dofs are decoupled, so
M = diag(1, 1, 1, 0.004, 0.004, 0.004) and M^-1 * ones = [1, 1, 1, 250, 250, 250].
  mjw.factor_m(m, d)        factor M into d.qLD / d.qLDiagInv
  mjw.solve_m(m, d, x, y)   x = M^-1 y using that stored factor
  mjw.mul_m(m, d, z, x)     z = M x (no factor needed)
Run: python ex9_solve_mul.py
"""
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
NWORLD = 4096 if ON_GPU else 8

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
mjw.fwd_position(m, d, factorize=False)      # build d.M only
mjw.factor_m(m, d)                           # explicit factorization

print("M_rownnz =", mjm.M_rownnz, "-> every row is diagonal-only (a 'simple' free body)")
print("d.M[0] =", d.M.numpy()[0])
print("M_tiles:", [(t.size, t.adr.numpy().tolist()) for t in m.M_tiles],
      " qLD_block_adr =", m.qLD_block_adr.numpy(), " qLD shape:", d.qLD.shape)
print("d.qLDiagInv[0] =", d.qLDiagInv.numpy()[0])

y = wp.ones((d.nworld, mjm.nv), dtype=float)
x = wp.zeros((d.nworld, mjm.nv), dtype=float)
z = wp.zeros((d.nworld, mjm.nv), dtype=float)
mjw.solve_m(m, d, x, y)                      # x = M^-1 y
mjw.mul_m(m, d, z, x)                        # z = M x
print("x = M^-1 ones :", x.numpy()[0])
print("z = M x       :", z.numpy()[0])
print(f"max |z - ones| over {NWORLD} worlds: {np.abs(z.numpy() - 1).max():.2e}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
