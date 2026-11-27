"""Example 16.7 - box-box: CONVEX (GJK/EPA + multi-contact) by default, PRIMITIVE without NATIVECCD.

MJ_COLLISION_TABLE sends BOX-BOX to the convex path. Setting DisableBit.NATIVECCD makes
collision_driver._narrowphase flip that one cell to PRIMITIVE, so box_box_wrapper (a port of
MuJoCo C's mjc_BoxBox: separating-axis test + face clipping) handles it instead. We stack two
boxes in three poses (aligned, top box yawed 20 and 45 degrees) and count box-box contacts:
MJWarp default, MJWarp with NATIVECCD disabled, and MuJoCo C (mj_forward) for reference.
Run: python ex7_box_box_native.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.io import override_model      # private API

np.set_printoptions(precision=4, suppress=True)


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


YAWS = [0.0, 20.0, 45.0]           # yaw of the top box, one world each
NWORLD = len(YAWS)

mjm = mujoco.MjModel.from_xml_string(box_stack(2))
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
for w, yaw in enumerate(YAWS):
    qpos[w, 2] = 0.0995                       # bottom box 0.5 mm into the floor
    qpos[w, 9] = 0.2985                       # top box 1 mm into the bottom box
    a = np.radians(yaw) / 2
    qpos[w, 10:14] = [np.cos(a), 0, 0, np.sin(a)]


def count_box_box(geom):
    return int(np.sum((geom[:, 0] == 1) & (geom[:, 1] == 2)))


results = {}
for label, overrides in [("MJWarp default", []),
                         ("MJWarp NATIVECCD off", ["opt.disableflags = nativeccd"])]:
    m = mjw.put_model(mjm)
    if overrides:
        override_model(m, overrides)           # mutates m in place, returns None
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
    d.qpos.assign(qpos.astype(np.float32))
    mjw.kinematics(m, d)
    mjw.collision(m, d)
    n = min(int(d.nacon.numpy()[0]), d.naconmax)
    wid = d.contact.worldid.numpy()[:n]
    geom = d.contact.geom.numpy()[:n]
    results[label] = [(count_box_box(geom[wid == w]), int(np.sum(wid == w))) for w in range(NWORLD)]
    print(f"{label:22s} disableflags = {int(m.opt.disableflags):6d}  overflow:",
          "none" if not d.overflow.numpy().any() else d.overflow.numpy())

for label, flag in [("MuJoCo C default", 0), ("MuJoCo C NATIVECCD off", 1)]:
    mjm_c = mujoco.MjModel.from_xml_string(box_stack(2))
    if flag:
        mjm_c.opt.disableflags |= mujoco.mjtDisableBit.mjDSBL_NATIVECCD
    mjd = mujoco.MjData(mjm_c)
    res = []
    for w in range(NWORLD):
        mjd.qpos[:] = qpos[w]
        mujoco.mj_forward(mjm_c, mjd)
        geom = np.array([c.geom for c in mjd.contact[:mjd.ncon]])
        res.append((count_box_box(geom), int(mjd.ncon)))
    results[label] = res

print("\nbox-box contacts (total incl. 4 floor contacts) per pose of the top box:")
print("                          " + "".join(f"yaw {y:4.0f}    " for y in YAWS))
for label, res in results.items():
    print(f"{label:24s}  " + "".join(f"{bb:2d} ({tot:2d})    " for bb, tot in res))
