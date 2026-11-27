"""Example 3.9 - a resting contact is a constraint force that cancels gravity.

BALL_DROP in MJWarp: each world drops the ball from a different height and lets it settle for
1 s. Then, per world, we print the bias force on the vertical dof (gravity, qfrc_bias[2]), the
contact normal force decoded by mjw.contact_force, their balance, the remaining vertical
acceleration, and the small penetration contact.dist that the soft contact needs (Ch 9).
Run: python ex9_contact_as_constraint.py
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
NWORLD = 4096 if ON_GPU else 4
NSTEP = 500                                   # 1 s: enough for every world to come to rest

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)

qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qpos[:, 2] = np.linspace(0.3, 0.8, NWORLD)    # different drop heights per world
d.qpos.assign(qpos)

for _ in range(NSTEP):
    mjw.step(m, d)
wp.synchronize()

nacon = int(d.nacon.numpy()[0])
force = wp.zeros(nacon, dtype=wp.spatial_vector)
ids = wp.array(np.arange(nacon, dtype=np.int32), dtype=int)
mjw.contact_force(m, d, ids, False, force)       # contact frame: entry 0 is the normal force

f_n = force.numpy()[:, 0]
wid = d.contact.worldid.numpy()[:nacon]
dist = d.contact.dist.numpy()[:nacon]
bias = d.qfrc_bias.numpy()[:, 2]
qacc = d.qacc.numpy()[:, 2]
nefc = d.nefc.numpy()

print(f"nworld = {NWORLD}, contacts in the shared pool: nacon = {nacon}, "
      f"mg = {mjm.body_mass[1] * 9.81:.4f} N")
print(f"{'world':>5} {'qfrc_bias[2]':>13} {'normal force':>13} {'balance':>9} "
      f"{'qacc[2]':>9} {'dist [mm]':>10} {'nefc':>5}")
for c in range(min(nacon, 4)):
    w = wid[c]
    print(f"{w:>5} {bias[w]:>13.4f} {f_n[c]:>13.4f} {f_n[c] - bias[w]:>+9.4f} "
          f"{qacc[w]:>+9.4f} {1000 * dist[c]:>10.3f} {nefc[w]:>5}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
