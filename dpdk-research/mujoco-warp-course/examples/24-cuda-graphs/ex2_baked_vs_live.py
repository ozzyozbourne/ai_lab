"""Example 24.2 - baked vs live: what a captured graph sees when you change things after capture.

We capture one step of PENDULUM, then change three things and replay 20 steps from the same
start state, comparing with eager mjw.step:
  1. d.ctrl            via .assign()   -> an array's CONTENTS: live, the graph uses it
  2. m.opt.timestep    via .assign()   -> also an array (one float per world): live
  3. m.opt.integrator  = RK4           -> a Python int read while recording: baked, ignored
Run: python ex2_baked_vs_live.py
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
NWORLD = 4096 if ON_GPU else 4
NSTEP = 20

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
if wp.get_device().is_cuda and not wp.is_conditional_graph_supported():
    m.opt.graph_conditional = False                    # Rule G fallback (CUDA < 12.4)
    print("note: CUDA < 12.4, using m.opt.graph_conditional = False")

q0 = np.tile(mjm.key_qpos[0], (NWORLD, 1))             # start horizontal, at rest, t = 0


def restart():
    """Put every world back at the start state (in place: the graph keeps working)."""
    d.qpos.assign(q0)
    d.qvel.zero_()
    d.time.zero_()


def rollout(use_graph):
    restart()
    for _ in range(NSTEP):
        if use_graph:
            wp.capture_launch(graph)
        else:
            mjw.step(m, d)
    wp.synchronize()
    return d.qpos.numpy().copy(), float(d.time.numpy()[0])


mjw.step(m, d)                                         # warm-up (compile)
with wp.ScopedCapture() as capture:                    # recorded with ctrl 0, dt 0.01, EULER
    mjw.step(m, d)
graph = capture.graph


def report(label, eager, replay, eager_old=None):
    (qe, te), (qg, tg) = eager, replay
    print(f"--- {label}")
    print(f"  eager : qpos w0 {qe[0]}  t {te:.3f}")
    print(f"  graph : qpos w0 {qg[0]}  t {tg:.3f}")
    print(f"  max |graph - eager| = {np.abs(qg - qe).max():.2e}")
    if eager_old is not None:
        print(f"  max |graph - eager with OLD value| = {np.abs(qg - eager_old[0]).max():.2e}")


# 1. ctrl: assign new contents, a different torque per world
d.ctrl.assign(np.linspace(-2.0, 2.0, NWORLD).reshape(NWORLD, 1))
report("1. d.ctrl.assign(...)        (array contents)", rollout(False), rollout(True))

# 2. timestep: m.opt.timestep is a wp.array with one entry (shared by all worlds)
m.opt.timestep.assign([0.005])
report("2. m.opt.timestep.assign(...) (array contents)", rollout(False), rollout(True))

# 3. integrator: a Python int; mjw.step branches on it in Python while recording
euler = rollout(False)                                 # eager, still EULER
m.opt.integrator = int(mjw.IntegratorType.RK4)
report("3. m.opt.integrator = RK4    (Python int)", rollout(False), rollout(True), euler)

m.opt.integrator = int(mjw.IntegratorType.EULER)       # put it back before any recapture
print("verdict: ctrl live, timestep live, integrator baked (recapture after changing it)")
