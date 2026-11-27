"""Example 14.10 - inverse dynamics closes the loop: qfrc_inverse = qfrc_applied + qfrc_actuator.

PLAYGROUND (M3: a ball, a box and a hinged arm with a motor). Every world gets its own random
motor ctrl and random qfrc_applied. After 100 steps (so contacts are active) we run mjw.forward,
which computes qacc, then mjw.inverse, which takes that qacc and recovers the generalized force
that must have produced it:
    qfrc_inverse = M qacc + qfrc_bias - qfrc_passive - qfrc_constraint  (inverse.py::_qfrc_inverse)
Forward dynamics put qfrc_applied + qfrc_actuator (+ J^T xfrc_applied, zero here) in, so the two
must agree up to float32 round-off and the solver tolerance. World 0 is also compared with
mj_inverse.
Run: python ex10_inverse_identity.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

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

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 100

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
rng = np.random.default_rng(0)
d.ctrl.assign(rng.uniform(-1, 1, (NWORLD, mjm.nu)).astype(np.float32))
d.qfrc_applied.assign(rng.uniform(-0.5, 0.5, (NWORLD, mjm.nv)).astype(np.float32))

for _ in range(NSTEP):
    mjw.step(m, d)
mjw.forward(m, d)            # qacc from the current state and inputs
mjw.inverse(m, d)            # qfrc_inverse from the same state and that qacc
wp.synchronize()

qfrc_in = d.qfrc_applied.numpy() + d.qfrc_actuator.numpy()
err = np.abs(d.qfrc_inverse.numpy() - qfrc_in)
print("nefc per world:", d.nefc.numpy()[:8], "| contacts:", d.nacon.numpy()[0])
print("world 0 qfrc_inverse              :", d.qfrc_inverse.numpy()[0])
print("world 0 qfrc_applied + qfrc_actuator:", qfrc_in[0])
print(f"max |qfrc_inverse - (qfrc_applied + qfrc_actuator)| over {NWORLD} worlds: {err.max():.2e}")
print(f"largest |qfrc| for scale: {np.abs(qfrc_in).max():.3f}; "
      f"largest |qfrc_constraint|: {np.abs(d.qfrc_constraint.numpy()).max():.3f}")

# world 0 in MuJoCo C: same state and qacc, then mj_inverse
mjd = mujoco.MjData(mjm)
mjw.get_data_into(mjd, mjm, d, world_id=0)
mujoco.mj_inverse(mjm, mjd)
ec = np.abs(d.qfrc_inverse.numpy()[0] - mjd.qfrc_inverse).max()
print(f"world 0 |MJWarp - mj_inverse| max: {ec:.2e} "
      f"(relative to max |qfrc_constraint|: {ec / np.abs(mjd.qfrc_constraint).max():.1e})")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
