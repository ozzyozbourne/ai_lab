"""Example 11.2 - the mass matrix is the kinetic energy: T = 0.5 qvel^T M qvel, per world.

PENDULUM (energy flag enabled) in NWORLD worlds with random qpos/qvel. After mjw.forward we
1. densify each world's CSR mass matrix d.M and evaluate 0.5 qvel^T M qvel in NumPy,
2. read MJWarp's own kinetic energy d.energy[:, 1] (sensor.energy_vel),
3. sum 0.5 m |v_com|^2 + 0.5 w^T I w over the bodies in MuJoCo C (mj_objectVelocity),
and print all three per world. They agree to float32 round-off.
Run: python ex2_kinetic_energy.py
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

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8


def csr_to_dense(mjm, values):
    """Symmetric dense M from MJWarp's CSR lower triangle (one world)."""
    M = np.zeros((mjm.nv, mjm.nv))
    for i in range(mjm.nv):
        for k in range(mjm.M_rownnz[i]):
            adr = mjm.M_rowadr[i] + k
            j = mjm.M_colind[adr]
            M[i, j] = M[j, i] = values[adr]
    return M


mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)

rng = np.random.default_rng(1)
qpos = rng.uniform(-np.pi, np.pi, (NWORLD, mjm.nq)).astype(np.float32)
qvel = rng.uniform(-4, 4, (NWORLD, mjm.nv)).astype(np.float32)
d.qpos.assign(qpos)
d.qvel.assign(qvel)
mjw.forward(m, d)

M_csr = d.M.numpy()               # (nworld, nC)
energy = d.energy.numpy()         # (nworld, 2): [potential, kinetic]

mjd = mujoco.MjData(mjm)
vel = np.zeros(6)
print("world  0.5 v^T M v   d.energy[:,1]   sum over bodies (C)")
worst = 0.0
for w in range(min(NWORLD, 8)):
    M = csr_to_dense(mjm, M_csr[w])
    t_m = 0.5 * qvel[w] @ M @ qvel[w]
    mjd.qpos[:], mjd.qvel[:] = qpos[w], qvel[w]
    mujoco.mj_forward(mjm, mjd)
    t_b = 0.0
    for b in range(1, mjm.nbody):
        # velocity of the body's inertial frame, in that frame: (angular, linear)
        mujoco.mj_objectVelocity(mjm, mjd, mujoco.mjtObj.mjOBJ_BODY, b, vel, 1)
        w_loc, v_loc = vel[:3], vel[3:]
        t_b += 0.5 * mjm.body_mass[b] * v_loc @ v_loc + 0.5 * w_loc @ (mjm.body_inertia[b] * w_loc)
    worst = max(worst, abs(t_m - energy[w, 1]), abs(t_m - t_b))
    print(f"{w:5d}  {t_m:11.5f}   {energy[w, 1]:13.5f}   {t_b:12.5f}")
print(f"max abs difference: {worst:.2e} (float32 MJWarp vs float64 C)")
