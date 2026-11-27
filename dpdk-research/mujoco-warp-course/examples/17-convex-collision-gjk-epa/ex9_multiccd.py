"""Example 17.9 - multi-contact: one EPA witness pair becomes up to 4 contacts.

GJK/EPA returns ONE pair of witness points. A box resting flat on a box needs several contacts
or it rocks. collision_gjk.py::multicontact finds the two aligned faces, clips one against the
other (_polygon_clip) and keeps at most 4 points (_polygon_quad). It runs for face/face and
face/edge pairs, unless DisableBit.MULTICCD is set; box-box multi-contact is always on
(ccd_kernel_builder checks geomtype1 == geomtype2 == BOX before use_multiccd).
We count contacts for box-on-box, cylinder-on-box and mesh-on-box, flat and tilted 20 degrees
about a horizontal axis, with and without MULTICCD.
Run: python ex9_multiccd.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

ON_GPU = wp.get_device().is_cuda

HEX = " ".join(f"{0.05 * np.cos(a):.5f} {0.05 * np.sin(a):.5f} {z}"
               for z in (-0.03, 0.03) for a in np.arange(6) * np.pi / 3)


def scene(multiccd):
    flag = "" if multiccd else '<option><flag multiccd="disable"/></option>'
    return f"""
<mujoco model="multiccd">
  {flag}
  <asset><mesh name="hex" vertex="{HEX}"/></asset>
  <worldbody>
    <geom name="t0" type="box" pos="0 0 0.05" size="0.1 0.1 0.05"/>
    <geom name="t1" type="box" pos="1 0 0.05" size="0.1 0.1 0.05"/>
    <geom name="t2" type="box" pos="2 0 0.05" size="0.1 0.1 0.05"/>
    <body name="box" pos="0 0 0.149"><freejoint/><geom type="box" size="0.05 0.05 0.05"/></body>
    <body name="cyl" pos="1 0 0.149"><freejoint/><geom type="cylinder" size="0.05 0.05"/></body>
    <body name="hex" pos="2 0 0.129"><freejoint/><geom type="mesh" mesh="hex"/></body>
  </worldbody>
</mujoco>"""


def tilted_qpos(mjm):
    """World 1: every body turned 20 deg about the y-axis, lowest point 1 mm deep."""
    q = mjm.qpos0.copy()
    t = np.radians(20.0)
    for b, (r, h) in enumerate([(0.05, 0.05), (0.05, 0.05), (0.05, 0.03)]):
        adr = 7 * b
        low = h * np.cos(t) + r * np.sin(t)               # centre height above the lowest point
        q[adr + 2] = 0.1 + low - 0.001
        q[adr + 3:adr + 7] = [np.cos(t / 2), 0, np.sin(t / 2), 0]
    return q


labels = ["box-box", "cylinder-box", "mesh-box"]
for multiccd in (True, False):
    mjm = mujoco.MjModel.from_xml_string(scene(multiccd))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=2, nconmax=24, njmax=96)
    d.qpos.assign(np.stack([mjm.qpos0, tilted_qpos(mjm)]).astype(np.float32))
    mjw.kinematics(m, d)
    mjw.collision(m, d)
    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    geom, wid = d.contact.geom.numpy()[:n], d.contact.worldid.numpy()[:n]
    print(f"MULTICCD {'enabled ' if multiccd else 'disabled'}:")
    for w, pose in enumerate(["flat  ", "tilted"]):
        counts = []
        for k in range(3):
            body_geom = 3 + k                              # geoms 3, 4, 5 are the free bodies
            counts.append(int(((wid == w) & ((geom == body_geom).any(axis=1))).sum()))
        print(f"  {pose}: " + "  ".join(f"{lab} {c}" for lab, c in zip(labels, counts)))
    print("  overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
