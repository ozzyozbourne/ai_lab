"""Example 16.3 - capsule-capsule: parallel axes give 2 contacts, crossed axes give 1.

A capsule is a segment plus a radius, so capsule-capsule reduces to "closest points between two
segments" (_segment_weights, a port of MuJoCo's mjc_segWeights) followed by sphere_sphere at
those points. For parallel segments the closest points are not unique: the collider returns the
two ends of the overlap, so the pair writes 2 contacts (geomcollisionid 0 and 1).
Run: python ex3_capsule_capsule.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

CAPSULES = """
<mujoco model="capsule_capsule">
  <worldbody>
    <geom name="rail" type="capsule" fromto="-0.3 0 0.5  0.3 0 0.5" size="0.05"/>
    <body name="rod" pos="0 0 0.59">
      <freejoint/>
      <geom name="rod" type="capsule" fromto="-0.2 0 0  0.2 0 0" size="0.05"/>
    </body>
  </worldbody>
</mujoco>
"""


def quat_z(deg):
    a = np.radians(deg) / 2
    return [np.cos(a), 0.0, 0.0, np.sin(a)]


# world: (description, x offset of the rod, yaw of the rod in degrees)
CASES = [("parallel, centred", 0.0, 0.0),
         ("parallel, shifted +0.3", 0.3, 0.0),
         ("yaw 30 deg", 0.0, 30.0),
         ("crossed (yaw 90 deg)", 0.0, 90.0)]
NWORLD = len(CASES)

mjm = mujoco.MjModel.from_xml_string(CAPSULES)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)

qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
for w, (_, dx, yaw) in enumerate(CASES):
    qpos[w, 0] = dx
    qpos[w, 3:7] = quat_z(yaw)
d.qpos.assign(qpos)
mjw.kinematics(m, d)
mjw.collision(m, d)

n = min(int(d.nacon.numpy()[0]), d.naconmax)
wid = d.contact.worldid.numpy()[:n]
gcid = d.contact.geomcollisionid.numpy()[:n]
dist = d.contact.dist.numpy()[:n]
pos = d.contact.pos.numpy()[:n]
normal = d.contact.frame.numpy()[:n, 0]

print("surfaces overlap by 0.01 m (centre distance 0.09, radii 0.05 + 0.05)")
for w, (name, _, _) in enumerate(CASES):
    sel = np.where(wid == w)[0]
    sel = sel[np.argsort(gcid[sel])]
    print(f"w{w} {name:24s} contacts: {len(sel)}")
    for i in sel:
        print(f"     gcid {gcid[i]}  dist {dist[i]: .4f}  pos {pos[i]}  normal {normal[i]}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
