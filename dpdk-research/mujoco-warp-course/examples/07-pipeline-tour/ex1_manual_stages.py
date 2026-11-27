"""Example 7.1 - call the forward stages by hand and reproduce mjw.forward exactly.

The public stage functions use the "factorize in the position stage" pairing:
fwd_position(factorize=True) writes qLD, then fwd_acceleration(factorize=False) solves with it.
mjw.forward uses the other pairing internally (factorize=False, then a fused factor+solve).
Both give the same qacc. Never combine fwd_position(factorize=False) with the default
fwd_acceleration(): that solves with an old factor (Ch 11 owns that experiment).
Run: python ex1_manual_stages.py
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
NSTEP = 1000 if ON_GPU else 50
SETTLE = 150                    # 1.5 s: the ball and box land, so there are contacts

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

# a different motor command per world, then let the objects land so there are contacts
d.ctrl.assign(np.linspace(-1.0, 1.0, NWORLD, dtype=np.float32).reshape(NWORLD, 1))
for _ in range(SETTLE):
    mjw.step(m, d)

# 1) the reference: one call
mjw.forward(m, d)
qacc_ref = d.qacc.numpy().copy()

# 2) the same thing, stage by stage (public defaults: factor in the position stage)
mjw.fwd_position(m, d)          # factorize=True: kinematics ... crb, factor_m, collision, constraints
mjw.fwd_velocity(m, d)          # com_vel, passive, rne -> qfrc_bias
mjw.fwd_actuation(m, d)         # actuator_force -> qfrc_actuator
mjw.fwd_acceleration(m, d)      # factorize=False: qfrc_smooth, solve with qLD -> qacc_smooth
mjw.solve(m, d)                 # constraint solver -> qacc
qacc_manual = d.qacc.numpy()

print("device:", wp.get_device(), "| nworld:", NWORLD, "| nv:", mjm.nv)
print("contacts in the pool (all worlds):", int(d.nacon.numpy()[0]))
print("max |qacc(forward) - qacc(manual stages)|:", float(np.abs(qacc_ref - qacc_manual).max()))
print("world 0 qacc:", qacc_ref[0])
print("world 0 qacc_smooth (before the constraint solve):", d.qacc_smooth.numpy()[0])
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
