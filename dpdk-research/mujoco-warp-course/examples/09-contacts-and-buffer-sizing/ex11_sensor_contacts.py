"""Example 9.11 - collision sensors put SENSOR contacts in the pool, but no constraint rows.

Two balls rest on a floor 0.3 m apart. A <distance> sensor between the balls makes the
narrowphase write a contact with only the SENSOR bit (dist = +0.3). A second sensor between the
floor and ball_a marks a real contact CONSTRAINT|SENSOR. nefc counts only CONSTRAINT contacts.
Run: python ex11_sensor_contacts.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import ContactType   # private API: not exported by mujoco_warp

np.set_printoptions(precision=4, suppress=True)

SENSOR_SCENE = """
<mujoco model="sensor_contacts">
  <option timestep="0.002"/>
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="a" pos="0 0 0.1"><freejoint/><geom name="ball_a" type="sphere" size="0.1"/></body>
    <body name="b" pos="0.5 0 0.1"><freejoint/><geom name="ball_b" type="sphere" size="0.1"/></body>
  </worldbody>
  <sensor>
    <distance name="gap_ab" geom1="ball_a" geom2="ball_b" cutoff="1"/>
    <distance name="gap_floor_a" geom1="floor" geom2="ball_a" cutoff="1"/>
  </sensor>
</mujoco>
"""

NWORLD = 2
mjm = mujoco.MjModel.from_xml_string(SENSOR_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
for _ in range(10):
    mjw.step(m, d)

names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(mjm.ngeom)]
n = min(int(d.nacon.numpy()[0]), d.naconmax)
c = d.contact
print(f"nacon = {n}, nefc per world = {d.nefc.numpy()}")
print(" cid  w  pair             dist     type                efc_address")
for i in range(n):
    g0, g1 = c.geom.numpy()[i]
    t = ContactType(int(c.type.numpy()[i]))
    pair = names[g0] + "-" + names[g1]
    print(f"{i:4d} {c.worldid.numpy()[i]:2d}  {pair:15s} {c.dist.numpy()[i]:7.4f}"
          f"   {t.name:18s}  {c.efc_address.numpy()[i]}")

is_sensor = (c.type.numpy()[:n] & ContactType.SENSOR) != 0
is_constraint = (c.type.numpy()[:n] & ContactType.CONSTRAINT) != 0
w0 = c.worldid.numpy()[:n] == 0
print("world 0: SENSOR contacts", int((is_sensor & w0).sum()),
      "| CONSTRAINT contacts", int((is_constraint & w0).sum()),
      "| 4 rows each ->", 4 * int((is_constraint & w0).sum()),
      "== nefc[0] =", int(d.nefc.numpy()[0]))
print("sensordata (gap_ab, gap_floor_a) per world:\n", d.sensordata.numpy())

mjd = mujoco.MjData(mjm)
mjw.get_data_into(mjd, mjm, d, world_id=0)          # exports CONSTRAINT | PASSIVE contacts only
print("get_data_into(world 0): mjd.ncon =", mjd.ncon, "(the SENSOR-only contact is not exported)")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
