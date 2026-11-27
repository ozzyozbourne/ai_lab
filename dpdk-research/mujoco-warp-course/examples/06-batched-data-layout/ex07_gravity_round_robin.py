"""Example 6.8 - batched Model fields are dealt round robin: world w reads row w % B.

m.opt.gravity has spec array("*", wp.vec3): any leading size B. With B = 2, even worlds get
the first gravity and odd worlds the second, NOT "first half / second half".
Run: python ex07_gravity_round_robin.py
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

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
g = np.array([0.0, 0.0, -9.81], dtype=np.float32)


def vz_after(nworld, gravity_rows, nstep=5):
    """Ball z velocity per world after nstep steps from rest, for a gravity batch."""
    m.opt.gravity = wp.array(gravity_rows, dtype=wp.vec3)   # replace: B = len(gravity_rows)
    d = mjw.make_data(mjm, nworld=nworld, nconmax=4, njmax=16)
    for _ in range(nstep):
        mjw.step(m, d)
    return d.qvel.numpy()[:, 2]


print("default gravity shape:", m.opt.gravity.shape, "-> every world reads row 0")
vz = vz_after(4, [g, -g])
print("B=2, nworld=4: qvel z =", vz, "(5 steps x 0.002 s x 9.81 = 0.0981)")
print("  row used per world  =", [w % 2 for w in range(4)])

rows = [g, 0.5 * g, 0.0 * g]                         # B = 3 with nworld = 8
vz = vz_after(8, rows)
print("B=3, nworld=8: qvel z =", vz)
print("  row used per world  =", [w % 3 for w in range(8)])

per_world = [g * (1 + 0.25 * w) for w in range(4)]   # B = nworld: one row per world
print("B=nworld=4:    qvel z =", vz_after(4, per_world))
# a replaced array is a plain wp.array: put_model's mark_batched tag is not carried over
print("replaced gravity shape:", m.opt.gravity.shape,
      "| _is_batched tag:", getattr(m.opt.gravity, "_is_batched", False))
