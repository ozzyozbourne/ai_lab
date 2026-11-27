"""Example 19.1 - the 1-D ball-on-floor toy: one soft contact row, solved by hand and by MJWarp.

A ball (mass 1) is pressed into the floor by depth p and moves with vertical velocity v. Its
acceleration a minimizes 0.5*m*(a - a0)^2 + 0.5*D*(a - aref)^2 (the second term only while
a < aref, i.e. while the row is active). We compute k, b, imp, D and aref from solref/solimp
exactly as constraint.py does, take the closed-form optimum, and compare with MJWarp: one world
per (p, v) pair. Floor and ball use condim="1" (a contact takes the larger condim of its two
geoms), so the contact has exactly one row: CONTACT_FRICTIONLESS.
Run: python ex1_toy_1d.py
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
    <geom name="floor" type="plane" size="5 5 .1" condim="1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" condim="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

CASES = [(0.0002, 0.0), (0.0005, 0.0), (0.001, 0.0), (0.002, 0.0), (0.005, 0.0),
         (0.002, -0.5), (0.002, 0.5), (-0.001, 0.0)]          # (penetration p [m], v [m/s])
NWORLD = len(CASES)                    # one world per case (same tiny budget on GPU and CPU)


def kbimp(timestep, solref, solimp, pos):
    """NumPy copy of constraint.py::_contact_kbimp for positive (standard) solref."""
    timeconst, dampratio = solref
    dmin, dmax, width, mid, power = solimp
    timeconst = max(timeconst, 2.0 * timestep)                 # refsafe
    k = 1.0 / (dmax**2 * timeconst**2 * dampratio**2)
    b = 2.0 / (dmax * timeconst)
    x = abs(pos) / width
    if x >= 1.0:
        imp = dmax
    elif x <= mid:
        imp = dmin + (dmax - dmin) * x**power / mid ** (power - 1)
    else:
        imp = dmin + (dmax - dmin) * (1 - (1 - x) ** power / (1 - mid) ** (power - 1))
    return k, b, imp


mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=2, njmax=4)

qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qvel = np.zeros((NWORLD, mjm.nv))
for w, (p, v) in enumerate(CASES):
    qpos[w, 2] = 0.1 - p                # ball centre: radius minus penetration
    qvel[w, 2] = v
d.qpos.assign(qpos)
d.qvel.assign(qvel)
mjw.forward(m, d)

mass = 1.0
a0 = mjm.opt.gravity[2]                 # unconstrained acceleration (qacc_smooth, z)
h = mjm.opt.timestep
solref, solimp = mjm.geom_solref[1], mjm.geom_solimp[1]
invweight = float(m.body_invweight0.numpy()[0, 1, 0])   # ball's translational invweight0
print(f"solref {solref}  solimp {solimp}  invweight0 {invweight:.4f}  a0 {a0:.2f}")

nefc = d.nefc.numpy()
D_w, aref_w = d.efc.D.numpy()[:, 0], d.efc.aref.numpy()[:, 0]
f_w, a_w = d.efc.force.numpy()[:, 0], d.qacc.numpy()[:, 2]
print("   p[mm]  v     imp     D       aref      a* toy   a* mjw   f toy    f mjw")
for w, (p, v) in enumerate(CASES):
    pos = -p                            # dist - margin (negative = penetrating)
    if pos >= 0:                        # the row does not exist: no contact force at all
        print(f"  {p*1e3:5.2f} {v:5.2f}   inactive: nefc = {nefc[w]}, a* = a0 = {a_w[w]:.3f}")
        continue
    k, b, imp = kbimp(h, solref, solimp, pos)
    D = 1.0 / (invweight * (1.0 - imp) / imp)    # constraint.py::_efc_D
    aref = -k * imp * pos - b * v                # constraint.py::_efc_row (continuous time)
    if a0 < aref:                                # row active at the optimum
        a_star = (mass * a0 + D * aref) / (mass + D)
    else:
        a_star = a0
    f = -D * (a_star - aref) if a_star < aref else 0.0
    print(f"  {p*1e3:5.2f} {v:5.2f}  {imp:.4f} {D:7.2f} {aref:9.3f}  {a_star:7.3f}  {a_w[w]:7.3f}"
          f"  {f:7.3f}  {f_w[w]:7.3f}")
print("rows per world (nefc):", nefc, "| efc.type world 0:",
      mujoco.mjtConstraint(int(d.efc.type.numpy()[0, 0])).name)
print("Newton's law at the optimum, m*(a* - a0) = f, world 3:",
      round(mass * (a_w[3] - a0), 3), "=", round(float(f_w[3]), 3))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
