"""Example 15.11 - explicit <contact><pair>: a pair id >= 0 in m.nxn_pairid and its own material.

The ball has contype=conaffinity=0, so the bitmask test alone would drop ball-floor (-2). The
explicit <pair> overrides that: put_model writes the pair's index into column 0 of nxn_pairid,
the broadphase filter uses the pair's margin + gap, and the narrowphase takes friction, condim,
solref and margin from the pair instead of mixing the two geoms' values.
Run: python ex11_explicit_pair.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

XML = """
<mujoco model="explicit_pair">
  <worldbody>
    <geom name="floor" type="plane" size="3 3 .1" friction="1 0.005 0.0001"/>
    <body name="ball" pos="0 0 0.105"><freejoint/>
      <geom name="ball" type="sphere" size="0.1" contype="0" conaffinity="0"/></body>
    <body name="box" pos="0.5 0 0.099"><freejoint/>
      <geom name="box" type="box" size="0.1 0.1 0.1"/></body>
  </worldbody>
  <contact>
    <pair geom1="ball" geom2="floor" condim="4" friction="0.3 0.3 0.01 0.0001 0.0001" margin="0.01"/>
  </contact>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(mjm.ngeom)]
g1, g2 = np.triu_indices(mjm.ngeom, k=1)
print("npair =", mjm.npair, "| pair_geom1/2 =", mjm.pair_geom1.tolist(), mjm.pair_geom2.tolist())
for k, (a, b) in enumerate(zip(g1, g2)):
    print(f"row {k}: {names[a]:5s}-{names[b]:5s} nxn_pairid = {m.nxn_pairid.numpy()[k].tolist()}")
print("filtered work list:", m.nxn_geom_pair_filtered.numpy().tolist())

d = mjw.make_data(mjm, nworld=2, nconmax=16, njmax=64)
mjw.kinematics(m, d)
mjw.collision(m, d)
n = min(int(d.nacon.numpy()[0]), d.naconmax)
geom = d.contact.geom.numpy()[:n]
print(f"\nnacon = {n} (ball sits 0.005 above the floor: inside the pair margin 0.01)")
for c in range(n):
    if d.contact.worldid.numpy()[c] != 0:
        continue
    print(f"world 0 {names[geom[c, 0]]}-{names[geom[c, 1]]:5s} dist={d.contact.dist.numpy()[c]:+.4f} "
          f"dim={d.contact.dim.numpy()[c]} includemargin={d.contact.includemargin.numpy()[c]:.3f} "
          f"friction={d.contact.friction.numpy()[c]}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
