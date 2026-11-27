"""Example 8.9 - put the controller inside mjw.step with m.callback.control.

The callback is a plain Python function (m, d) -> None that launches a kernel writing d.ctrl.
MJWarp calls it in _forward right after the velocity sensors and before actuation, so a plain
mjw.step loop (or a captured CUDA graph of it) runs the controller every step.
Run: python ex09_control_callback.py
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
NSTEP = 300  # 3 s


@wp.kernel
def pd_control(sensordata_in: wp.array2d[float], target: float, kp: float, kd: float,
               ctrl_out: wp.array2d[float]):
    worldid = wp.tid()
    q = sensordata_in[worldid, 0]   # sensor "q1"
    qd = sensordata_in[worldid, 1]  # sensor "v1"
    ctrl_out[worldid, 0] = kp * (target - q) - kd * qd


calls = [0]


def control(m, d):
    """Called by MJWarp as m.callback.control(m, d): once per forward / step1 / Euler or implicit
    step, but 4 times per RK4 step (stages 2-4 see intermediate qpos/qvel and stale sensors)."""
    calls[0] += 1  # Python side effect: runs once per call here, but only ONCE at graph capture
    wp.launch(pd_control, dim=d.nworld, inputs=[d.sensordata, 0.3, 50.0, 5.0], outputs=[d.ctrl])


mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
print("default callbacks:", m.callback)

for use_cb in (False, True):
    m.callback.control = control if use_cb else None
    mjw.reset_data_keyframe(m, d, 0)        # start horizontal: hinge1 = pi/2
    for _ in range(NSTEP):
        mjw.step(m, d)
    label = "with callback   " if use_cb else "without callback"
    print(f"{label}: hinge1 after {NSTEP} steps = {d.qpos.numpy()[:4, 0]}  (target 0.3)")
print("callback calls:", calls[0], "for", NSTEP, "steps")

m.opt.disableflags |= mjw.DisableBit.ACTUATION  # with actuation disabled the callback is skipped
mjw.step(m, d)
print("calls after one step with ACTUATION disabled:", calls[0])
