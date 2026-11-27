"""Example 7.2 - run the stages one at a time and print what each one fills in.

A fresh Data starts with zeros in every derived field. We copy a settled state (qpos, qvel, ctrl)
into it and call the five stages in order, printing a few outputs after each one.
Run: python ex2_stage_outputs.py
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
run = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
run.ctrl.assign(np.linspace(-1.0, 1.0, NWORLD, dtype=np.float32).reshape(NWORLD, 1))
for _ in range(SETTLE):
    mjw.step(m, run)

# a fresh Data: copy only the state and the inputs; every derived field is still zero
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
wp.copy(d.qpos, run.qpos)
wp.copy(d.qvel, run.qvel)
wp.copy(d.ctrl, run.ctrl)
W = 0      # world to print
BALL, BOX, ARM = 1, 2, 3
HINGE = 12  # dof index of the arm hinge (6 ball dofs + 6 box dofs come first)


def show(name, arr):
    print(f"  {name:<22}", arr)


print("before any stage: xpos[ball] =", d.xpos.numpy()[W, BALL], "| nacon =", d.nacon.numpy()[0])

mjw.fwd_position(m, d)
print("after fwd_position (kinematics, com, crb + factor_m, collision, constraints, transmission)")
show("xpos[ball]", d.xpos.numpy()[W, BALL])
show("xpos[box]", d.xpos.numpy()[W, BOX])
show("M nonzeros (of nC=%d)" % mjm.nC, int(np.count_nonzero(d.M.numpy()[W])))
show("M diagonal[ball]", d.M.numpy()[W, :6])
show("nacon (all worlds)", int(d.nacon.numpy()[0]))
show("nefc (world 0)", int(d.nefc.numpy()[W]))
show("actuator_moment", d.actuator_moment.numpy()[W])

mjw.fwd_velocity(m, d)
print("after fwd_velocity (com_vel, passive, rne)")
show("cvel[arm] (rot, lin)", d.cvel.numpy()[W, ARM])
show("qfrc_bias", d.qfrc_bias.numpy()[W])

mjw.fwd_actuation(m, d)
print("after fwd_actuation")
show("ctrl", d.ctrl.numpy()[W])
show("actuator_force", d.actuator_force.numpy()[W])
show("qfrc_actuator[hinge]", d.qfrc_actuator.numpy()[W, HINGE])

mjw.fwd_acceleration(m, d)
print("after fwd_acceleration (sum forces, solve M qacc_smooth = qfrc_smooth)")
show("qfrc_smooth", d.qfrc_smooth.numpy()[W])
show("qacc_smooth", d.qacc_smooth.numpy()[W])

mjw.solve(m, d)
print("after solve (constraint forces)")
show("qacc", d.qacc.numpy()[W])
show("qfrc_constraint", d.qfrc_constraint.numpy()[W])
show("solver iterations", int(d.solver_niter.numpy()[W]))

mjw.forward(m, run)
print("same qacc as mjw.forward:", bool(np.allclose(d.qacc.numpy(), run.qacc.numpy(), atol=1e-5)))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
