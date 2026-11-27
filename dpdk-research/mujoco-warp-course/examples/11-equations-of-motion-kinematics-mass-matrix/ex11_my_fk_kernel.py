"""Example 11.11 - write your own forward-kinematics kernel for the planar 2-link arm.

One Warp thread per world computes the tip position of the PENDULUM in closed form:
    tip = base + R_y(q1) (0, 0, -l1) + R_y(q1 + q2) (0, 0, -l2),
where a rotation by angle a about +y maps (0, 0, -l) to (-l sin a, 0, -l cos a).
We compare with d.site_xpos written by mjw.kinematics and time both. The general kernel walks
branches, joints and quaternions for any tree; ours knows the model, so it does less work.
Timings are from whatever device you run on (on this page: a CPU dev box, not a GPU).
Run: python ex11_my_fk_kernel.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""
ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NREP = 200 if ON_GPU else 20


@wp.kernel
def planar_fk(qpos: wp.array2d[float], base: wp.vec3, l1: float, l2: float,
              tip_out: wp.array[wp.vec3]):
    worldid = wp.tid()                       # one thread per world
    a1 = qpos[worldid, 0]
    a12 = a1 + qpos[worldid, 1]
    p = base + wp.vec3(-l1 * wp.sin(a1), 0.0, -l1 * wp.cos(a1))
    tip_out[worldid] = p + wp.vec3(-l2 * wp.sin(a12), 0.0, -l2 * wp.cos(a12))


mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
rng = np.random.default_rng(5)
d.qpos.assign(rng.uniform(-np.pi, np.pi, (NWORLD, mjm.nq)).astype(np.float32))

base = wp.vec3(*mjm.body_pos[1])             # hinge1 anchor (0, 0, 1.5)
l1, l2 = float(-mjm.body_pos[2, 2]), float(-mjm.site_pos[0, 2])
tip = wp.zeros(NWORLD, dtype=wp.vec3)

wp.launch(planar_fk, dim=NWORLD, inputs=[d.qpos, base, l1, l2], outputs=[tip])
mjw.kinematics(m, d)                         # warm up (JIT) both, then compare
err = np.abs(tip.numpy() - d.site_xpos.numpy()[:, 0]).max()
print("tip, world 0 (ours)        :", tip.numpy()[0])
print("site_xpos, world 0 (mjw)   :", d.site_xpos.numpy()[0, 0])
print(f"max |ours - mjw.kinematics| over {NWORLD} worlds: {err:.2e}")


def timed(fn):
    wp.synchronize()
    t0 = time.perf_counter()
    for _ in range(NREP):
        fn()
    wp.synchronize()
    return (time.perf_counter() - t0) / NREP


t_ours = timed(lambda: wp.launch(planar_fk, dim=NWORLD, inputs=[d.qpos, base, l1, l2],
                                 outputs=[tip]))
t_mjw = timed(lambda: mjw.kinematics(m, d))
print(f"device {wp.get_device()}: our kernel {t_ours * 1e6:.1f} us/call (1 launch), "
      f"mjw.kinematics {t_mjw * 1e6:.1f} us/call (5 launches), nworld = {NWORLD}")
