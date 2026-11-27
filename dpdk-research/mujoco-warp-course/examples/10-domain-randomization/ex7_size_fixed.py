"""Example 10.7 - per-world ball radius: geom_size plus its bounds, then set_const(FIXED).

geom_size changes the collision shape, but the broadphase prunes pairs with geom_rbound and
geom_aabb, which put_model computed from the XML size. Batch all three and recompute the bounds
with mjw.set_const(m, d, groups=mjw.SetConstGroup.FIXED). The second half calls the deprecated
alias set_const_fixed once, only to show its DeprecationWarning. Run 2b shows that forgetting the
bounds is not fixed by set_const: all worlds then race to write the one shared bounds row.
Run: python ex7_size_fixed.py
"""
import warnings

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
RADII = np.array([0.05, 0.1, 0.2])
NW = len(RADII)
NSTEP = 1000                                      # 2 s: the balls drop and come to rest


def make(fields):
    mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
    m = mjw.put_model(mjm, batch_sizes={k: NW for k in fields})
    d = mjw.make_data(mjm, nworld=NW, nconmax=4, njmax=16)
    ball = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_GEOM, "ball")
    gs = m.geom_size.numpy()
    gs[:, ball, 0] = RADII                        # sphere: size[0] is the radius
    m.geom_size.assign(gs)
    return mjm, m, d, ball


def rest_height(m, d):
    for _ in range(NSTEP):
        mjw.step(m, d)
    return d.qpos.numpy()[:, 2]


# 1. the right way: size + bounds batched, bounds recomputed
mjm, m, d, ball = make(["geom_size", "geom_rbound", "geom_aabb"])
print("geom_rbound before:", m.geom_rbound.numpy()[:, ball])
mjw.set_const(m, d, groups=mjw.SetConstGroup.FIXED)
print("geom_rbound after: ", m.geom_rbound.numpy()[:, ball])
print("geom_aabb half-size after:", m.geom_aabb.numpy()[:, ball, 1, 0])
print("rest z (expect r - ~0.0004 of soft-contact penetration):", rest_height(m, d))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

# 2. what happens if you forget the bounds: rbound stays 0.1 for every world
_, m2, d2, _ = make(["geom_size"])
print("forgot the bounds, rbound =", m2.geom_rbound.numpy()[:, ball], "-> rest z:",
      rest_height(m2, d2))

# 2b. forgot the bounds AND called set_const(FIXED): _set_bound launches over the LARGEST batch
# size of its inputs and outputs (here 3), so all three worlds write the one shared row (a race;
# on CPU the last world wins, on a GPU the winner is unspecified)
_, m3, d3, _ = make(["geom_size"])
mjw.set_const(m3, d3, groups=mjw.SetConstGroup.FIXED)
print("forgot the bounds + FIXED, shared rbound =", m3.geom_rbound.numpy()[:, ball],
      "aabb half-size =", m3.geom_aabb.numpy()[:, ball, 1, 0])

# 3. the deprecated alias, once (never use it in new code)
with warnings.catch_warnings(record=True) as caught:
    warnings.simplefilter("always")
    mjw.set_const_fixed(m, d)
for w in caught:
    print(f"{w.category.__name__}: {w.message}")
