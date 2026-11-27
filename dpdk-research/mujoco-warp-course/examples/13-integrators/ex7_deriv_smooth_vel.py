"""Example 13.7 - the matrix IMPLICITFAST factors: M - dt * D, from mjw.deriv_smooth_vel.

D = d(qfrc_passive + qfrc_actuator)/d(qvel) is the velocity derivative of the smooth forces.
The pendulum gets joint damping (1.0, 0.5) and a velocity servo (kv = 3) on hinge2, so D is not
zero. mjw.deriv_smooth_vel writes M - dt*D in MuJoCo's sparse lower-triangular layout of M
(m.nC values per world, the way forward.py allocates it). We densify it with mujoco.mju_sym2dense
and compare it with M (mujoco.mj_fullM) minus dt times a central finite-difference D from C MuJoCo.
Run: python ex7_deriv_smooth_vel.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=5, suppress=True)

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
NWORLD = 1024 if ON_GPU else 2

# damped variant of the shared model: joint damping and a velocity servo on the elbow
DAMPED = (PENDULUM
          .replace('name="hinge1" type="hinge"', 'name="hinge1" type="hinge" damping="1.0"')
          .replace('name="hinge2" type="hinge"', 'name="hinge2" type="hinge" damping="0.5"')
          .replace('</actuator>', '<velocity name="elbow_kv" joint="hinge2" kv="3"/></actuator>')
          .replace('timestep="0.01"', 'timestep="0.01" integrator="implicitfast"'))
mjm = mujoco.MjModel.from_xml_string(DAMPED)
mjd = mujoco.MjData(mjm)
mjd.qpos[:] = [0.7, -0.4]
mjd.qvel[:] = [1.0, 2.0]
dt = mjm.opt.timestep

m = mjw.put_model(mjm)
d = mjw.put_data(mjm, mjd, nworld=NWORLD)
mjw.fwd_position(m, d, factorize=False)
mjw.fwd_velocity(m, d)
mjw.fwd_actuation(m, d)
out = wp.empty((d.nworld, m.nC), dtype=float)       # sparse layout of M: nC values per world
mjw.deriv_smooth_vel(m, d, out)

print(f"nv = {mjm.nv}, nC = {mjm.nC}, M_rownnz = {mjm.M_rownnz}, M_rowadr = {mjm.M_rowadr}, "
      f"M_colind = {mjm.M_colind}")
vals = out.numpy()[0].astype(np.float64)
print("sparse values of world 0:", vals)
H_mjw = np.zeros((mjm.nv, mjm.nv))
mujoco.mju_sym2dense(H_mjw, vals, mjm.M_rownnz, mjm.M_rowadr, mjm.M_colind)

# reference in float64: M from C MuJoCo (MuJoCo 4 has no mjd.qM; mj_fullM reads mjd.M)
mujoco.mj_forward(mjm, mjd)
M = np.zeros((mjm.nv, mjm.nv))
mujoco.mj_fullM(mjm, mjd, M)


def smooth_force(qvel):
    dd = mujoco.MjData(mjm)
    dd.qpos[:], dd.qvel[:], dd.ctrl[:] = mjd.qpos, qvel, mjd.ctrl
    mujoco.mj_forward(mjm, dd)
    return dd.qfrc_passive + dd.qfrc_actuator


eps = 1e-6
D = np.column_stack([(smooth_force(mjd.qvel + eps * e) - smooth_force(mjd.qvel - eps * e)) / (2 * eps)
                     for e in np.eye(mjm.nv)])
H_ref = M - dt * D
print("M (mj_fullM):\n", M)
print("D = d(qfrc_passive + qfrc_actuator)/dqvel (finite differences):\n", D)
print("M - dt*D from mjw.deriv_smooth_vel:\n", H_mjw)
print("M - dt*D reference:\n", H_ref)
print(f"max |difference| = {np.abs(H_mjw - H_ref).max():.1e}")
