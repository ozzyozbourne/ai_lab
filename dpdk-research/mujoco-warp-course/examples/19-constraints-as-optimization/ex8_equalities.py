"""Example 19.8 - four equality types in one model: rows per equality, row order and violations.

The equalities are declared in the order TENDON, JOINT, WELD, CONNECT (eq ids 0..3):
  TENDON : two slider tendons must have equal length (1 row)
  JOINT  : hinge b = 0.5 * hinge a (1 row, polycoef)
  WELD   : a free box is welded to the world frame where it starts (6 rows)
  CONNECT: a free capsule hangs from a world point, like a ball joint (3 rows)
make_constraint launches one kernel per type (connect, weld, joint, tendon), so the rows come out
grouped by type, not by eq id. Gravity pulls on everything; each equality has its own eq_solref,
and the soft rows show a small steady violation efc.pos that depends on the load each equality
carries as well as on its solref (an unloaded equality, like the tendon here, ends at zero).
FLEX and FLEXSTRAIN rows need a flex; they are shown in Ch 23.
Run: python ex8_equalities.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=5, suppress=True, linewidth=100)

EQUALITIES = """
<mujoco model="equalities">
  <option timestep="0.002"/>
  <worldbody>
    <body name="sl1" pos="-1 0 1">
      <joint name="s1" type="slide" axis="0 0 1"/>
      <geom type="box" size=".05 .05 .05" mass="1" contype="0" conaffinity="0"/>
    </body>
    <body name="sl2" pos="-0.7 0 1">
      <joint name="s2" type="slide" axis="0 0 1"/>
      <geom type="box" size=".05 .05 .05" mass="2" contype="0" conaffinity="0"/>
    </body>
    <body name="arm_a" pos="0 0 1">
      <joint name="ha" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .3 0 0" size=".02" mass="1" contype="0" conaffinity="0"/>
    </body>
    <body name="arm_b" pos="0 0.3 1">
      <joint name="hb" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .3 0 0" size=".02" mass="1" contype="0" conaffinity="0"/>
    </body>
    <body name="welded" pos="0.7 0 1">
      <freejoint/>
      <geom type="box" size=".05 .05 .05" mass="1" contype="0" conaffinity="0"/>
    </body>
    <body name="hanging" pos="1.2 0 1">
      <freejoint/>
      <geom type="capsule" fromto="0 0 0 0 0 -.3" size=".02" mass="1" contype="0" conaffinity="0"/>
    </body>
  </worldbody>
  <tendon>
    <fixed name="t1"><joint joint="s1" coef="1"/></fixed>
    <fixed name="t2"><joint joint="s2" coef="1"/></fixed>
  </tendon>
  <equality>
    <tendon tendon1="t1" tendon2="t2" solref="0.02 1"/>
    <joint joint1="hb" joint2="ha" polycoef="0 0.5 0 0 0" solref="0.01 1"/>
    <weld body1="welded" solref="0.005 1"/>
    <connect body1="hanging" anchor="0 0 0" solref="0.04 1"/>
  </equality>
</mujoco>
"""

NWORLD = 2
NSTEP = 200

mjm = mujoco.MjModel.from_xml_string(EQUALITIES)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, njmax=16)
print("eq_type :", [mujoco.mjtEq(int(t)).name for t in mjm.eq_type])
print("eq_solref timeconst:", mjm.eq_solref[:, 0])

qpos = np.tile(mjm.qpos0, (NWORLD, 1))
ha = mjm.jnt_qposadr[mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_JOINT, "ha")]
hb = mjm.jnt_qposadr[mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_JOINT, "hb")]
qpos[:, ha] = 0.4                                 # start the joint equality violated
qpos[:, 0] = 0.05                                 # and the tendon equality (s1 - s2 = 5 cm)
d.qpos.assign(qpos)
q = d.qpos.numpy()[0]
print(f"start: hb - 0.5*ha = {q[hb] - 0.5 * q[ha]:+.2e}, s1 - s2 = {q[0] - q[1]:+.2e}")
for _ in range(NSTEP):
    mjw.step(m, d)

n = int(d.nefc.numpy()[0])
eqid = d.efc.id.numpy()[0, :n]
pos = d.efc.pos.numpy()[0, :n]
print(f"ne {d.ne.numpy()}  nefc {d.nefc.numpy()}  (3 + 6 + 1 + 1 = 11)")
print("row -> eq id:", eqid)
for e in range(mjm.neq):
    rows = np.flatnonzero(eqid == e)
    print(f"  eq {e} {mujoco.mjtEq(int(mjm.eq_type[e])).name[5:]:8s} rows {rows.tolist()!s:22s}"
          f" max |pos| = {np.abs(pos[rows]).max():.2e}")
q = d.qpos.numpy()[0]
print(f"after {NSTEP * mjm.opt.timestep:.1f} s: hb - 0.5*ha = {q[hb] - 0.5 * q[ha]:+.2e},"
      f" s1 - s2 = {q[0] - q[1]:+.2e}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
