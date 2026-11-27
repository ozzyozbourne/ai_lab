"""Example 11.3 - spatial velocity cvel: 6 numbers (angular, linear) in the com frame.

d.cvel[w, b] is a wp.spatial_vector: first 3 = angular velocity, last 3 = linear velocity of the
point that coincides with c = subtree_com[root of b] (the "com frame"), all in world axes.
For any point p moving with body b:  v_p = v_lin + w x (p - c).
We check (1) link1, which turns about a fixed hinge anchor a: v_lin = w x (c - a), and (2) the
velocity of each body com xipos against a finite difference of MuJoCo C kinematics.
Run: python ex3_spatial_vectors.py
"""
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
mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
q0 = np.array([0.6, -0.9])
qd0 = np.array([1.5, 2.0])
d.qpos.assign(q0[None].astype(np.float32))
d.qvel.assign(qd0[None].astype(np.float32))
mjw.forward(m, d)

cvel = d.cvel.numpy()[0]            # (nbody, 6)
c = d.subtree_com.numpy()[0, 1]     # com of the tree rooted at link1 (the "com frame" origin)
xanchor = d.xanchor.numpy()[0]      # (njnt, 3)
xipos = d.xipos.numpy()[0]
print("cvel shape per world:", d.cvel.numpy().shape[1:], "dtype", d.cvel.dtype.__name__)
for b in (1, 2):
    print(f"body {b} ({mjm.body(b).name}): angular = {cvel[b, :3]}, linear = {cvel[b, 3:]}")
print("com frame origin c = subtree_com[1] =", c)

# (1) link1 rotates about its hinge anchor: the linear part is w x (c - anchor)
w1, v1 = cvel[1, :3], cvel[1, 3:]
res1 = np.abs(v1 - np.cross(w1, c - xanchor[0])).max()
print(f"link1: |v_lin - w x (c - xanchor)| = {res1:.2e}")

# (2) com velocity of each body: v_lin + w x (xipos - c) vs finite difference in MuJoCo C
mjd = mujoco.MjData(mjm)
eps = 1e-6
pos = []
for s in (-1, 1):
    mjd.qpos[:] = q0 + s * eps * qd0
    mujoco.mj_kinematics(mjm, mjd)
    pos.append(mjd.xipos.copy())
v_fd = (pos[1] - pos[0]) / (2 * eps)
for b in (1, 2):
    v_pred = cvel[b, 3:] + np.cross(cvel[b, :3], xipos[b] - c)
    print(f"body {b}: v_com from cvel = {v_pred}, finite diff = {v_fd[b]}, "
          f"residual = {np.abs(v_pred - v_fd[b]).max():.2e}")
