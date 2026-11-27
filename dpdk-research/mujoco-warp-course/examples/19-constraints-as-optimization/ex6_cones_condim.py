"""Example 19.6 - pyramidal vs elliptic cones and condim 1/3/4/6: rows per contact and forces.

A ball rests on the floor while sliding along x, spinning about z and rolling about y, so every
friction direction has something to resist. A contact takes the larger condim and the larger
friction of its two geoms, so both geoms get the same values. For each cone and condim we build
a model, run one forward, and print the rows of the single contact (type, state, efc.force)
and the contact-frame force from mjw.contact_force (normal, two tangents, torsion, two rolling
torques).
cone and condim change kernel specializations, so each new combination compiles a few kernels.
Run: python ex6_cones_condim.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True, linewidth=110)

BALL = """
<mujoco model="ball_cone">
  <option timestep="0.002" cone="{cone}"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1" condim="{condim}" friction="0.8 0.02 0.01"/>
    <body name="ball" pos="0 0 0.0995">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" condim="{condim}"
            friction="0.8 0.02 0.01"/>
    </body>
  </worldbody>
</mujoco>
"""

STATE = {int(v): k[len("mjCNSTRSTATE_"):] for k, v in mujoco.mjtConstraintState.__members__.items()}
TYPE = {int(v): k[len("mjCNSTR_CONTACT_"):] for k, v in mujoco.mjtConstraint.__members__.items()}

print("cone       condim  rows  type          states / efc.force per row")
summary = {}
for cone in ("pyramidal", "elliptic"):
    for condim in (1, 3, 4, 6):
        mjm = mujoco.MjModel.from_xml_string(BALL.format(cone=cone, condim=condim))
        m = mjw.put_model(mjm)
        d = mjw.make_data(mjm, nworld=1, nconmax=2, njmax=16)
        qvel = np.array([[0.5, 0.0, 0.0, 0.0, 1.0, 3.0]])   # slide x, roll about y, spin about z
        d.qvel.assign(qvel)
        mjw.forward(m, d)
        n = int(d.nefc.numpy()[0])
        states = " ".join(STATE[s][:4] for s in d.efc.state.numpy()[0, :n])
        kind = TYPE[int(d.efc.type.numpy()[0, 0])]
        print(f"{cone:10s} {condim:5d} {n:5d}   {kind:12s}  {states}")
        print(f"{'':31s}{d.efc.force.numpy()[0, :n].round(3)}")
        ids = wp.array([0], dtype=int)
        cf = wp.zeros(1, dtype=wp.spatial_vector)
        mjw.contact_force(m, d, ids, False, cf)              # contact frame: normal first
        summary[(cone, condim)] = cf.numpy()[0]
        print(f"{'':31s}efc_address {d.contact.efc_address.numpy()[0]}"
              f"  (nmaxpyramid = {d.contact.efc_address.shape[1]})")

print("\ncontact-frame force [normal, t1, t2 | torsion, roll1, roll2] from mjw.contact_force:")
for (cone, condim), f in summary.items():
    print(f"  {cone:10s} condim {condim}: {f.round(3)}")
print("rows per contact: pyramidal 2*(condim-1) (1 for condim 1), elliptic condim")
