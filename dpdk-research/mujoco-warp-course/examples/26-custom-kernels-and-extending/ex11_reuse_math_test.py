"""Example 26.11 - reuse an MJWarp wp.func in your kernel, and test it the way MJWarp tests itself.

mujoco_warp._src.math.quat_to_mat is a @wp.func (private API: it may change between releases),
so any kernel can call it. body_tilt computes each body's rotation matrix from d.xquat and its
tilt angle (between the body z axis and world z). The test follows CONTRIBUTING.md:
mujoco_warp.test_data.fixture(xml=...) builds MjModel/MjData/Model/Data, nworld 1 and 2 with
world 1 perturbed so the worlds differ, outputs pre-filled with wp.inf, and a comparison against
MuJoCo C (mujoco.mju_quat2Mat on mj_kinematics results) at rtol = atol = 1e-5.
Run: python ex11_reuse_math_test.py
"""
import io
import sys
import unittest

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from absl.testing import parameterized
from mujoco_warp import test_data                     # shipped in the wheel
from mujoco_warp._src.math import quat_to_mat         # private API: a @wp.func

np.set_printoptions(precision=4, suppress=True)

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <camera name="overview" pos="0.5 -3 1.5" xyaxes="1 0 0 0 0.45 0.9"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/><geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>
"""


@wp.kernel
def body_tilt(
    # Data in:
    xquat_in: wp.array2d[wp.quat],
    # Out:
    mat_out: wp.array2d[wp.mat33],
    tilt_out: wp.array2d[float],
):
    worldid, bodyid = wp.tid()
    rot = quat_to_mat(xquat_in[worldid, bodyid])      # MuJoCo (w, x, y, z) quaternion
    mat_out[worldid, bodyid] = rot
    tilt_out[worldid, bodyid] = wp.acos(wp.clamp(rot[2, 2], -1.0, 1.0))


def tilt(m, d):
    mat = wp.full((d.nworld, m.nbody), wp.mat33(*([wp.inf] * 9)), dtype=wp.mat33)  # pre-fill inf
    out = wp.full((d.nworld, m.nbody), wp.inf, dtype=float)
    wp.launch(body_tilt, dim=(d.nworld, m.nbody), inputs=[d.xquat], outputs=[mat, out])
    return mat.numpy(), out.numpy()


class BodyTiltTest(parameterized.TestCase):
    @parameterized.parameters(1, 2)
    def test_body_tilt(self, nworld):
        mjm, mjd, m, d = test_data.fixture(xml=PLAYGROUND, keyframe="up", qvel_noise=2.0,
                                           nworld=nworld)
        qpos = np.tile(mjd.qpos, (nworld, 1))
        if nworld == 2:                               # perturb world 1: heterogeneous worlds
            qpos[1, 3:7] = [0.8, 0.2, -0.5, 0.26]     # ball orientation (w, x, y, z)
            qpos[1, 3:7] /= np.linalg.norm(qpos[1, 3:7])
            qpos[1, 10:14] = [0.6, 0.0, 0.8, 0.0]     # box orientation: 106 deg about y
            qpos[1, 14] = -1.0                        # arm hinge
            d.qpos.assign(qpos.astype(np.float32))
            mjw.fwd_kinematics(m, d)                  # recompute xquat for both worlds

        mat, out = tilt(m, d)

        for w in range(nworld):                       # per-world MuJoCo C reference
            mjd.qpos[:] = qpos[w]
            mujoco.mj_kinematics(mjm, mjd)
            for b in range(mjm.nbody):
                ref = np.zeros(9)
                mujoco.mju_quat2Mat(ref, mjd.xquat[b])
                np.testing.assert_allclose(mat[w, b].reshape(9), ref, rtol=1e-5, atol=1e-5)
                np.testing.assert_allclose(out[w, b], np.arccos(np.clip(ref[8], -1, 1)),
                                           rtol=1e-5, atol=1e-5)
        if nworld == 2:
            self.assertFalse(np.allclose(out[0], out[1]))   # the worlds really differ
        print(f"nworld={nworld}: tilt [deg] per body (world, ball, box, arm)")
        print(np.degrees(out))


if __name__ == "__main__" or "ipykernel" in sys.modules:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(BodyTiltTest)
    log = io.StringIO()                               # runner chatter (timings) stays quiet
    result = unittest.TextTestRunner(stream=log, verbosity=0).run(suite)
    if not result.wasSuccessful():
        print(log.getvalue())
    print("tests run:", result.testsRun, "| failures:", len(result.failures),
          "| errors:", len(result.errors))
