"""Example 29.2 - in mujoco-warp 4.0.1 no public function can run inside an active wp.Tape.

mujoco_warp/__init__.py ends with _differentiable(locals()): every public function is wrapped by
diff._wrap. Outside a tape the wrapper calls straight through. Inside a tape it looks up
diff.RULES[name]; 4.0.1 registers no rule for any API function, so it raises before touching
the arguments. Setup calls (put_model, make_data, forward) therefore run before the tape.
Run: python ex2_tape_error.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src import diff   # private API: the differentiability registry

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

# setup OUTSIDE any tape: these calls pass straight through the wrapper
mjm = mujoco.MjModel.from_xml_string(PENDULUM)
mjd = mujoco.MjData(mjm)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2)
d.qpos.assign(np.tile(mjm.key_qpos[0], (2, 1)))     # keyframe "horizontal"
mjw.forward(m, d)
print("untaped forward ok, qacc[0] =", np.round(d.qacc.numpy()[0], 4))
print("mjw.step is a wrapper of", mjw.step.__wrapped__.__module__ + "." + mjw.step.__name__)

for name, call in [
    ("step", lambda: mjw.step(m, d)),
    ("forward", lambda: mjw.forward(m, d)),
    ("put_data", lambda: mjw.put_data(mjm, mjd, nworld=2)),
]:
    try:
        with wp.Tape() as tape:
            call()
        print(f"{name}: recorded (unexpected)")
    except NotImplementedError as e:
        print(f"{name:9s} -> NotImplementedError: {e}  | launches recorded: {len(tape.launches)}")

print("wrapped public functions:", len(diff.RULES))
print("registered rules:", sorted(k for k, v in diff.RULES.items() if v is not None))
