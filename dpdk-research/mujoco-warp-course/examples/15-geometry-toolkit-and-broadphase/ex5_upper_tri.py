"""Example 15.5 - upper_tri_index: how a geom pair (g1, g2) is packed into one integer.

m.nxn_pairid has one row per unordered pair g1 < g2, in np.triu_indices order. Both put_model and
the SAP sweep kernel find a pair's row with upper_tri_index(ngeom, g1, g2). We reproduce it in
Python and print the packed index of every filtered pair next to m.nxn_geom_pair_filtered.
Run: python ex5_upper_tri.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

ARM = """
<mujoco model="arm_scene">
  <worldbody>
    <geom name="floor" type="plane" size="3 3 .1"/>
    <geom name="wall" type="box" pos="1.5 0 .5" size=".1 1 .5"/>
    <body name="link1" pos="0 0 .3">
      <joint name="j1" type="hinge" axis="0 1 0"/>
      <geom name="link1" type="capsule" fromto="0 0 0 .4 0 0" size=".05"/>
      <body name="link2" pos=".4 0 0">
        <joint name="j2" type="hinge" axis="0 1 0"/>
        <geom name="link2" type="capsule" fromto="0 0 0 .4 0 0" size=".05"/>
        <body name="link3" pos=".4 0 0">
          <joint name="j3" type="hinge" axis="0 1 0"/>
          <geom name="link3" type="capsule" fromto="0 0 0 .3 0 0" size=".05"/>
          <geom name="gripper" type="box" pos=".33 0 0" size=".03 .06 .03"/>
        </body>
      </body>
    </body>
    <body name="box" pos=".5 .6 .2"><freejoint/><geom name="box" type="box" size=".1 .1 .1"/></body>
    <body name="target" mocap="true" pos="-.5 0 .5"><geom name="target" type="sphere" size=".05"/></body>
  </worldbody>
  <contact><exclude body1="link1" body2="link3"/></contact>
</mujoco>
"""



def upper_tri_index(n, i, j):
    """Row of pair (i, j), i != j, in the strict upper triangle (same formula as math.py / io.py)."""
    i, j = (j, i) if j < i else (i, j)
    return (i * (2 * n - i - 3)) // 2 + j - 1


mjm = mujoco.MjModel.from_xml_string(ARM)
m = mjw.put_model(mjm)
n = mjm.ngeom
names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(n)]

# 1. The formula enumerates np.triu_indices(n, k=1) exactly.
g1, g2 = np.triu_indices(n, k=1)
assert all(upper_tri_index(n, a, b) == k for k, (a, b) in enumerate(zip(g1, g2)))
assert upper_tri_index(n, 5, 2) == upper_tri_index(n, 2, 5)          # order does not matter
print(f"ngeom = {n}: {len(g1)} packed rows, row i starts at upper_tri_index(n, i, i+1)")
print("row starts:", [upper_tri_index(n, i, i + 1) for i in range(n - 1)])

# 2. Every filtered pair, its packed index, and the nxn_pairid row it points at.
pairid = m.nxn_pairid.numpy()
print("\nfiltered pair          packed idx   nxn_pairid[idx]")
for a, b in m.nxn_geom_pair_filtered.numpy():
    idx = upper_tri_index(n, a, b)
    print(f"({a},{b}) {names[a]:>7s}-{names[b]:<7s}  {idx:10d}   {pairid[idx].tolist()}")

dropped = [int(upper_tri_index(n, a, b)) for a, b in zip(g1, g2) if pairid[upper_tri_index(n, a, b), 0] == -2]
print("\npacked indices marked -2 (never tested):", dropped)
