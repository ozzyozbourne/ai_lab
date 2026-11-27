"""Example 19.3 - rebuild the primal cost in NumPy from MJWarp's arrays and verify the optimum.

A box tilted by 10 degrees rests on one edge (2 contacts, condim 3, pyramidal: 8 rows) and
slides with a different initial speed in each world. For every world we read efc.J, efc.D,
efc.aref, qacc_smooth and the dense M, rebuild
    cost(a) = 0.5 (a - qacc_smooth)^T M (a - qacc_smooth) + sum_active 0.5 D (J a - aref)^2,
recompute the forces from the cost, check M (qacc - qacc_smooth) = J^T force, and check that
random perturbations of qacc never lower the cost (qacc is the minimizer).
Run: python ex3_rebuild_cost.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True, linewidth=100)

TILTED_BOX = """
<mujoco model="tilted_box">
  <option timestep="0.002" cone="pyramidal"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="box" pos="0 0 .098" euler="0 10 0">
      <freejoint/>
      <geom type="box" size=".1 .1 .1" friction="0.5"/>
    </body>
  </worldbody>
</mujoco>
"""

SPEEDS = [0.0, 0.3, 1.0, 3.0]                  # initial x velocity per world [m/s]
NWORLD = len(SPEEDS)

mjm = mujoco.MjModel.from_xml_string(TILTED_BOX)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
qvel = np.zeros((NWORLD, mjm.nv))
qvel[:, 0] = SPEEDS
d.qvel.assign(qvel)
mjw.forward(m, d)

nv = mjm.nv
mjd = mujoco.MjData(mjm)
rng = np.random.default_rng(0)
for w in range(NWORLD):
    n = int(d.nefc.numpy()[w])
    J = d.efc.J.numpy()[w, :n, :nv]               # dense: (njmax_pad, nv_pad), keep the used part
    D = d.efc.D.numpy()[w, :n]
    aref = d.efc.aref.numpy()[w, :n]
    qacc = d.qacc.numpy()[w].astype(np.float64)
    qs = d.qacc_smooth.numpy()[w].astype(np.float64)
    mjw.get_data_into(mjd, mjm, d, world_id=w)    # copy world w (incl. qM) into an MjData
    M = np.zeros((nv, nv))
    mujoco.mj_fullM(mjm, mjd, M)

    def cost(a):
        jar = J @ a - aref
        return 0.5 * (a - qs) @ M @ (a - qs) + np.where(jar < 0, 0.5 * D * jar**2, 0.0).sum()

    jar = J @ qacc - aref
    f_np = np.where(jar < 0, -D * jar, 0.0)        # force = -d(row cost)/d(jar)
    f_mjw = d.efc.force.numpy()[w, :n]
    resid = np.abs(M @ (qacc - qs) - J.T @ f_np).max()
    # Ma and qfrc_smooth come from MJWarp itself: the same balance without C MuJoCo
    resid_mjw = np.abs(d.efc.Ma.numpy()[w] - d.qfrc_smooth.numpy()[w]
                       - J.T @ f_mjw).max()
    c0 = cost(qacc)
    worse = min(cost(qacc + 1e-3 * rng.standard_normal(nv)) - c0 for _ in range(200))
    print(f"world {w}: v0 = {SPEEDS[w]:.1f} m/s  nefc {n}  cost {c0:10.4f}")
    print("  state       ", d.efc.state.numpy()[w, :n])
    print("  force (cost)", f_np.round(3))
    print("  efc.force   ", f_mjw.round(3))
    print(f"  max |M(qacc-qacc_smooth) - J^T f| = {resid:.1e}   (Ma - qfrc_smooth - J^T f:"
          f" {resid_mjw:.1e})")
    print(f"  smallest cost change under 200 random 1e-3 perturbations: {worse:+.2e}"
          f" (relative {worse / abs(c0):+.1e})")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
