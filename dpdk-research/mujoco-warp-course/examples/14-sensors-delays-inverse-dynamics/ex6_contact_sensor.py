"""Example 14.6 - touch and contact sensors under a resting box.

A box (mass per world 1, 2, 3, 4 kg) settles on the floor. A <touch> sensor on a site that encloses
the bottom face sums the normal forces in its zone; a <contact> sensor matches contacts of body
"box" and reports up to num=4 of them (reduce="maxforce" keeps the strongest) with
data="found force normal". Both are acceleration-stage sensors (they need efc.force).
Prints the dim layout, the found count, each slot's force and the sum compared with m g.
Run: python ex6_contact_sensor.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BOX = """
<mujoco model="contact_sensor">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="box" pos="0 0 .1">
      <freejoint/>
      <geom name="boxgeom" type="box" size=".1 .1 .1" mass="1"/>
      <site name="sole" pos="0 0 -.1" type="box" size=".11 .11 .02"/>
    </body>
  </worldbody>
  <sensor>
    <touch name="touch" site="sole"/>
    <contact name="contact" body1="box" num="4" reduce="maxforce" data="found force normal"/>
  </sensor>
</mujoco>
"""

NWORLD = 4            # one world per box mass
NSTEP = 200

mjm = mujoco.MjModel.from_xml_string(BOX)
m = mjw.put_model(mjm, batch_sizes={"body_mass": NWORLD})   # per-world mass (Ch 10)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
box = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "box")
bm = m.body_mass.numpy()
bm[:, box] = np.arange(1, NWORLD + 1)
m.body_mass.assign(bm)      # body_inertia stays as for 1 kg: fine for a box resting flat

for _ in range(NSTEP):
    mjw.step(m, d)
mjw.forward(m, d)
wp.synchronize()

print("touch dim:", mjm.sensor_dim[0], "| contact dim:", mjm.sensor_dim[1],
      "= num 4 x (1 found + 3 force + 3 normal)")
sd = d.sensordata.numpy()
g = 9.81
for w in range(NWORLD):
    slots = sd[w, 1:].reshape(4, 7)               # per slot: found(1) force(3) normal(3)
    found = int(slots[0, 0])                      # every slot repeats the match count
    fsum = slots[:found, 1].sum()                 # force[0] is the normal component
    print(f"world {w}: m={bm[w, box]:.0f} kg  m g={bm[w, box] * g:6.3f}  touch={sd[w, 0]:6.3f}  "
          f"found={found}  sum normal force={fsum:6.3f}")
print("world 0 slots [found | f_normal f_t1 f_t2 | nx ny nz]:")
print(sd[0, 1:].reshape(4, 7))
print("contacts per world:", np.bincount(d.contact.worldid.numpy()[:d.nacon.numpy()[0]],
                                         minlength=NWORLD))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
