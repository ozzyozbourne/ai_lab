# Notebook spec for Chapter 14. Build with:
#   python3 tools/make_notebook.py notebooks/specs/14-sensors-delays-inverse-dynamics.py
SLUG = "14-sensors-delays-inverse-dynamics"
TITLE = "Ch 14 · Sensors, Delays and Inverse Dynamics"

PLOT11 = r'''
# Plot Example 14.11: torques of both methods and the open-loop tracking error (log scale).
# Run the Example 14.11 cell first (it defines t, tauA, tauB, err, NSAMPLE).
try:
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(1, 2, figsize=(11, 3.5))
    ts = t[:NSAMPLE]
    for j, (ca, cb) in enumerate([("C0", "C2"), ("C1", "C3")]):
        ax[0].plot(ts, tauA[:, j], ca, label=f"tau{j + 1} analytic (A)")
        ax[0].plot(ts, tauB[:, j], cb + "--", label=f"tau{j + 1} Euler-consistent (B)")
    ax[0].set_xlabel("t [s]"); ax[0].set_ylabel("N m"); ax[0].legend(fontsize=8)
    ax[1].semilogy(ts, err[:, 0] + 1e-12, label="replay A")
    ax[1].semilogy(ts, err[:, 1] + 1e-12, label="replay B")
    ax[1].set_xlabel("t [s]"); ax[1].set_ylabel("max |q - q_ref| [rad]"); ax[1].legend()
    plt.tight_layout(); plt.show()
except ImportError:
    print("skipped: matplotlib not installed")
'''

PLOT12 = r'''
# Plot Example 14.12: arm torques and the tracking error with and without INVDISCRETE.
# Run the Example 14.12 cell first (it defines t, tau, err, arm_dof, ARM, NSAMPLE).
try:
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(1, 2, figsize=(11, 3.5))
    ts = t[:NSAMPLE]
    for k, name in enumerate(ARM):
        ax[0].plot(ts, tau[:, arm_dof[k]], label=name)
    ax[0].set_xlabel("t [s]"); ax[0].set_ylabel("required torque [N m]"); ax[0].legend(fontsize=8)
    ax[1].semilogy(ts, np.abs(err[:, 0]).max(axis=1) + 1e-12, label="plain inverse")
    ax[1].semilogy(ts, np.abs(err[:, 1]).max(axis=1) + 1e-12, label="INVDISCRETE")
    ax[1].set_xlabel("t [s]"); ax[1].set_ylabel("max arm error [rad]"); ax[1].legend()
    plt.tight_layout(); plt.show()
except ImportError:
    print("skipped: matplotlib not installed")
'''

STUB1 = r'''
# Exercise 14.1: decode a framequat sensor and assert unit norm in every world.
FRAMEQUAT_XML = """
<mujoco>
  <worldbody><body name="box" pos="0 0 1"><freejoint/>
    <geom type="box" size=".1 .2 .3" mass="1"/><site name="s"/></body></worldbody>
  <sensor><framequat name="quat" objtype="site" objname="s"/></sensor>
</mujoco>"""
mjm = mujoco.MjModel.from_xml_string(FRAMEQUAT_XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=4)
qvel = np.zeros((4, 6), np.float32)
qvel[:, 3:] = np.random.default_rng(0).normal(size=(4, 3))   # tumble: random angular velocity
d.qvel.assign(qvel)
for _ in range(100):
    mjw.step(m, d)
mjw.forward(m, d)
# your code: find adr and dim of sensor "quat", slice d.sensordata, compute the norms
quat = ...
norm = ...
assert quat.shape == (4, 4)
assert np.allclose(norm, 1.0, atol=1e-5)
print("exercise 14.1 passed")
'''

SOL1 = r'''
FRAMEQUAT_XML = """
<mujoco>
  <worldbody><body name="box" pos="0 0 1"><freejoint/>
    <geom type="box" size=".1 .2 .3" mass="1"/><site name="s"/></body></worldbody>
  <sensor><framequat name="quat" objtype="site" objname="s"/></sensor>
</mujoco>"""
mjm = mujoco.MjModel.from_xml_string(FRAMEQUAT_XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=4)
qvel = np.zeros((4, 6), np.float32)
qvel[:, 3:] = np.random.default_rng(0).normal(size=(4, 3))
d.qvel.assign(qvel)
for _ in range(100):
    mjw.step(m, d)
mjw.forward(m, d)
sid = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_SENSOR, "quat")
adr, dim = int(mjm.sensor_adr[sid]), int(mjm.sensor_dim[sid])
quat = d.sensordata.numpy()[:, adr:adr + dim]          # (w, x, y, z) per world
norm = np.linalg.norm(quat, axis=1)
assert quat.shape == (4, 4)
assert np.allclose(norm, 1.0, atol=1e-5)
# the site has no offset, so the sensor equals the body quaternion up to sign
assert np.allclose(np.abs(np.sum(quat * d.xquat.numpy()[:, 1], axis=1)), 1.0, atol=1e-5)
print("exercise 14.1 passed: max |norm - 1| < 1e-5:", bool(np.abs(norm - 1).max() < 1e-5))
'''

STUB2 = r'''
# Exercise 14.2: measure the actuator delay of Example 14.8 in steps and assert it.
DELAY_XML = """
<mujoco>
  <option timestep="0.01" gravity="0 0 0"/>
  <worldbody><body><joint name="slide" type="slide" axis="1 0 0"/>
    <geom type="box" size=".1 .1 .1" mass="1" contype="0" conaffinity="0"/></body></worldbody>
  <actuator><motor joint="slide" delay="0.03" nsample="5"/></actuator>
</mujoco>"""
# your code: step with ctrl = 1, record actuator_force, find the first non-zero step,
# and compare it with round(actuator_delay / timestep)
nzero = None  # your code
expected = None  # your code
assert nzero is not None and expected is not None, "replace the placeholders"
assert nzero == expected, (nzero, expected)
print("exercise 14.2 passed")
'''

SOL2 = r'''
DELAY_XML = """
<mujoco>
  <option timestep="0.01" gravity="0 0 0"/>
  <worldbody><body><joint name="slide" type="slide" axis="1 0 0"/>
    <geom type="box" size=".1 .1 .1" mass="1" contype="0" conaffinity="0"/></body></worldbody>
  <actuator><motor joint="slide" delay="0.03" nsample="5"/></actuator>
</mujoco>"""
mjm = mujoco.MjModel.from_xml_string(DELAY_XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2)
d.ctrl.fill_(1.0)
force = []
for _ in range(8):
    mjw.step(m, d)
    force.append(float(d.actuator_force.numpy()[0, 0]))
nzero = next(i for i, f in enumerate(force) if f != 0.0)
expected = round(float(mjm.actuator_delay[0]) / mjm.opt.timestep)
assert nzero == expected, (nzero, expected)
print("exercise 14.2 passed: delay =", nzero, "steps;", force)
'''

STRETCH = r'''
# Stretch: a delayed PD controller. One world per actuator delay (actuator_delay is a batched field).
PD_XML = """
<mujoco>
  <option timestep="0.01" gravity="0 0 0"/>
  <worldbody><body><joint name="slide" type="slide" axis="1 0 0"/>
    <geom type="box" size=".1 .1 .1" mass="1" contype="0" conaffinity="0"/></body></worldbody>
  <actuator><motor joint="slide" delay="0.01" nsample="20"/></actuator>
</mujoco>"""
NW = 12
mjm = mujoco.MjModel.from_xml_string(PD_XML)
m = mjw.put_model(mjm, batch_sizes={"actuator_delay": NW})
delays = np.arange(NW) * 0.01
m.actuator_delay.assign(delays[:, None].astype(np.float32))
d = mjw.make_data(mjm, nworld=NW)
d.qpos.fill_(1.0)


@wp.kernel
def pd(qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float), kp: float, kd: float,
       ctrl: wp.array2d(dtype=float)):
    w = wp.tid()
    ctrl[w, 0] = -kp * qpos[w, 0] - kd * qvel[w, 0]


for i in range(800):
    wp.launch(pd, dim=NW, inputs=[d.qpos, d.qvel, 100.0, 5.0], outputs=[d.ctrl])
    mjw.step(m, d)
for dl, a in zip(delays, np.abs(d.qpos.numpy()[:, 0])):
    print(f"delay {dl:.2f} s  |q| after 8 s {a:.3e}")
# Now: refine the delay grid between the last stable and the first unstable world (on a GPU use
# thousands of worlds), vary kd, and compare with the phase-margin estimate of a delayed PD loop.
'''

CELLS = [
    ["md", "**How this notebook works.** Every example cell is the same file as on the chapter page "
           "(`examples/14-sensors-delays-inverse-dynamics/`). Budgets follow `ON_GPU`. The next cell writes "
           "the running helper module `my_env.py` (snapshot after Chapter 14: everything from Ch 6-10 plus the "
           "new `sensor_slices`), so the notebook runs in an empty `/content`."],
    ["writefile", "my_env.py", "examples/14-sensors-delays-inverse-dynamics/my_env_step14.py"],
    ["md", "## 1. Sensor stages and the catalogue\n"
           "`forward` zeroes `d.sensordata`, then calls `sensor_pos` after `fwd_position`, `sensor_vel` after "
           "`fwd_velocity` and `sensor_acc` after the solver. Example 14.1 builds a model with one sensor of "
           "every supported type and prints stage, address and dim (the full enum is the private "
           "`mujoco_warp._src.types.SensorType`)."],
    ["example", "ex1_sensor_catalogue.py", "14.1"],
    ["md", "## 2. An IMU: accelerometer, gyro, magnetometer\n"
           "The accelerometer measures specific force (acceleration minus gravity): +9.81 along 'up' at rest, "
           "0 in free fall. The magnetometer is `site_xmat^T @ opt.magnetic`."],
    ["example", "ex2_imu_magnetometer.py", "14.2"],
    ["md", "## 3. Reading sensordata by address\n"
           "`d.sensordata` has shape `(nworld, nsensordata)`. Sensor i lives in columns "
           "`sensor_adr[i] : sensor_adr[i] + sensor_dim[i]`. `my_env.sensor_slices(mjm)` builds the name map."],
    ["example", "ex3_sensordata_slices.py", "14.3"],
    ["md", "## 4. Rays and collisions as sensors\n"
           "Rangefinder outputs are chosen with `data=\"...\"`; the compiler stores a `RayDataField` bitmask in "
           "`sensor_intprm[:, 0]`. A camera rangefinder casts one ray per pixel."],
    ["example", "ex4_rangefinder_dataspec.py", "14.4"],
    ["md", "Collision sensors (`distance`, `normal`, `fromto`) run through the collision pipeline."],
    ["example", "ex5_geomdist.py", "14.5"],
    ["md", "Touch and contact sensors are acceleration-stage sensors: they read `efc.force`."],
    ["example", "ex6_contact_sensor.py", "14.6"],
    ["md", "## 5. Cutoff and interval sampling\n"
           "`cutoff` clamps; `interval=\"period phase\"` recomputes a sensor only every period and holds the "
           "value in between. Watch the 0.06 s sample: float32 time makes MJWarp sample one step later than C."],
    ["example", "ex7_cutoff_interval.py", "14.7"],
    ["md", "## 6. Delays: history ring buffers\n"
           "An actuator with `delay=0.03` at `dt=0.01` applies ctrl three steps late. The raw buffer is "
           "`[user, cursor, times..., values...]`."],
    ["example", "ex8_actuator_delay.py", "14.8"],
    ["md", "A delayed sensor lags its fresh copy; `mjw.read_sensor` queries the buffer at any time "
           "(it subtracts the sensor's delay)."],
    ["example", "ex9_sensor_delay.py", "14.9"],
    ["md", "## 7. Inverse dynamics\n"
           "`mjw.inverse` takes `qpos, qvel, qacc` and returns the generalized force `qfrc_inverse` that "
           "produces that acceleration. After `forward`, it must equal `qfrc_applied + qfrc_actuator`."],
    ["example", "ex10_inverse_identity.py", "14.10"],
    ["md", "One world per time sample: a whole trajectory's torques in one call, then an open-loop replay."],
    ["example", "ex11_inverse_trajectory.py", "14.11"],
    ["code", PLOT11],
    ["md", "## 8. Part III checkpoint: inverse-dynamics trajectory tracking for the humanoid arm\n"
           "Torso bolted, Euler implicit damping on, right arm on a smooth trajectory. Compare plain `inverse` "
           "with `EnableBit.INVDISCRETE`."],
    ["example", "ex12_checkpoint_humanoid_arm.py", "14.12"],
    ["code", PLOT12],
    ["md", "## Exercise 14.1: decode a framequat sensor\nSlice the quaternion out of `d.sensordata` and "
           "assert that it has unit norm in every world."],
    ["code", STUB1],
    ["solution", SOL1, "Exercise 14.1"],
    ["md", "## Exercise 14.2: the delay in steps\nAssert that the motor of Example 14.8 starts pushing exactly "
           "`round(delay / timestep)` steps late."],
    ["code", STUB2],
    ["solution", SOL2, "Exercise 14.2"],
    ["md", "## Stretch: when does delay destabilize a PD controller?\n"
           "`actuator_delay` is a batched model field, so every world can have its own delay. The starter below "
           "sweeps 0-0.11 s; find the boundary, then explore."],
    ["code", STRETCH],
    ["md", "## Part III review\n"
           "1. Which stage computes a touch sensor, and why? (acc: it sums `efc.force`.)\n"
           "2. Which call fills `qLD` and what goes wrong if you solve with an old one? (Ch 11)\n"
           "3. Where does `rne_postconstraint` run, and which sensors make `forward` call it? (Ch 12, §3 here)\n"
           "4. What does the implicitfast integrator drop compared with implicit? (Ch 13)\n"
           "5. Under RK4, from which moment of the step do sensors come? (the start)\n"
           "6. Why does inverse dynamics with INVDISCRETE reproduce an Euler trajectory exactly, while plain "
           "inverse does not when joint damping is integrated implicitly?"],
]
