"""Example 21.8 - contacts build islands: a stack shares one island, loose boxes get their own.

Scene: a stack of three boxes (trees 0-2), three loose boxes (trees 3-5), and two boxes touching
side by side (trees 6, 7). After forward we print tree_island and compare with C MuJoCo. Then we
time mjw.island alone (the DSU over efc rows) for a few nworld values. CPU numbers are from
Warp's CPU device; on a GPU the notebook prints its own table.

Run: python ex8_islands_vs_contacts.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLDS = [1024, 4096, 16384] if ON_GPU else [1, 4, 16]
NCALL = 100 if ON_GPU else 10

BOX = '<freejoint/><geom type="box" size=".1 .1 .1"/>'
XML = f"""
<mujoco>
  <option timestep="0.005" solver="Newton"><flag sleep="enable"/></option>
  <worldbody>
    <geom type="plane" size="5 5 .1"/>
    <body name="s0" pos="0 0 .099">{BOX}</body>
    <body name="s1" pos="0 0 .298">{BOX}</body>
    <body name="s2" pos="0 0 .497">{BOX}</body>
    <body name="a" pos=".6 0 .099">{BOX}</body>
    <body name="b" pos="1.0 0 .099">{BOX}</body>
    <body name="c" pos="1.4 0 .099">{BOX}</body>
    <body name="p" pos="0 .8 .099">{BOX}</body>
    <body name="q" pos=".199 .8 .099">{BOX}</body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2, nconmax=64, njmax=256)
mjw.forward(m, d)
print("ntree", mjm.ntree, "| nacon", d.nacon.numpy()[0], "| nefc w0", d.nefc.numpy()[0])
print("MJWarp  nisland", d.nisland.numpy()[0], "tree_island", d.tree_island.numpy()[0])
mjd = mujoco.MjData(mjm)
mujoco.mj_forward(mjm, mjd)
print("C       nisland", mjd.nisland, "tree_island", mjd.tree_island)
print("same partition:", bool((d.tree_island.numpy()[0] == mjd.tree_island).all()))

dev = "GPU" if ON_GPU else "CPU dev box"
print(f"mjw.island timing ({dev}, {NCALL} calls each):")
for nworld in NWORLDS:
    d = mjw.make_data(mjm, nworld=nworld, nconmax=64, njmax=256)
    mjw.forward(m, d)                        # fills the efc rows the DSU walks
    mjw.island(m, d)                         # warm up (JIT)
    wp.synchronize()
    t0 = time.perf_counter()
    for _ in range(NCALL):
        mjw.island(m, d)
    wp.synchronize()
    dt = (time.perf_counter() - t0) / NCALL
    print(f"  nworld {nworld:6d}: {dt * 1e3:7.3f} ms/call  {dt / nworld * 1e6:8.3f} us/world")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
