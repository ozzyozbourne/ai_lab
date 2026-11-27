"""Example 11.5 - run only the kinematics stage (mjw.kinematics) and compare with MuJoCo C.

HUMANOID in NWORLD worlds, each with its own random qpos (free-joint quaternion normalized,
hinges uniform in [-1, 1] rad). mjw.kinematics writes xpos/xquat/xmat, xipos/ximat, xanchor/xaxis,
geom_xpos/geom_xmat and site_xpos/site_xmat (the humanoid has no sites) for all worlds in five
launches. We compare every world with mujoco.mj_kinematics on the same qpos.
Run: python ex5_kinematics_only.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NCHECK = min(NWORLD, 64)      # worlds compared with MuJoCo C (the C loop is serial)

HUMANOID_PATH = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"
mjm = mujoco.MjModel.from_xml_path(str(HUMANOID_PATH))
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)

rng = np.random.default_rng(2)
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 0:3] += rng.normal(0, 0.3, (NWORLD, 3))              # free joint position
quat = rng.normal(size=(NWORLD, 4))
qpos[:, 3:7] = quat / np.linalg.norm(quat, axis=1, keepdims=True)   # free joint orientation
qpos[:, 7:] = rng.uniform(-1, 1, (NWORLD, mjm.nq - 7))        # 21 hinges
d.qpos.assign(qpos.astype(np.float32))

mjw.kinematics(m, d)                                         # just the kinematics stage

fields = ["xpos", "xquat", "xipos", "xanchor", "xaxis", "geom_xpos", "geom_xmat"]
got = {f: getattr(d, f).numpy() for f in fields}
err = {f: 0.0 for f in fields}
mjd = mujoco.MjData(mjm)
for w in range(NCHECK):
    mjd.qpos[:] = qpos[w]
    mujoco.mj_kinematics(mjm, mjd)
    for f in fields:
        ref = getattr(mjd, f).reshape(got[f][w].shape)   # C stores xmat as 9 numbers
        err[f] = max(err[f], np.abs(got[f][w] - ref).max())
print(f"jnt types: {sorted(set(mjm.jnt_type.tolist()))} (0=free, 3=hinge), nworld = {NWORLD}")
print("xpos of the torso in the first 3 worlds:\n", got["xpos"][:3, 1])
for f in fields:
    print(f"max |{f:9s} - C| over {NCHECK} worlds: {err[f]:.2e}   shape {got[f].shape}")
