"""Example 14.3 - reading d.sensordata by address: one row per world, one slice per sensor.

PENDULUM (M2) with a different constant shoulder torque in every world. After 100 steps we slice
d.sensordata[:, adr:adr + dim] for each sensor using my_env.sensor_slices(mjm) (new in this
chapter) and print the per-world matrix. The model enables the energy flag, so d.energy is filled too.
Run: python ex3_sensordata_slices.py [--dump-json PATH]
"""
import argparse
import json
import pathlib
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
try:
    import my_env                           # notebook: written by the %%writefile cell
except ImportError:
    import my_env_step14 as my_env          # examples/14-sensors-delays-inverse-dynamics/

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

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 100

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
d.ctrl.assign(np.linspace(-2.0, 2.0, NWORLD, dtype=np.float32)[:, None])   # torque per world

for _ in range(NSTEP):
    mjw.step(m, d)
mjw.forward(m, d)          # sensors for the final state (step computed them before integrating)
wp.synchronize()

slices = my_env.sensor_slices(mjm)
print("sensor_slices:", slices)
print("sensordata shape:", d.sensordata.shape, "(nworld, nsensordata)")
sd = d.sensordata.numpy()
show = np.linspace(0, NWORLD - 1, min(NWORLD, 4)).astype(int)   # 4 evenly spaced worlds (0..3 on CPU)
print("worlds shown:", show)
print("ctrl per world:", d.ctrl.numpy()[show, 0])
for name, (adr, dim) in slices.items():
    print(f"d.sensordata[:, {adr}:{adr + dim}]  # {name}")
    print(sd[show, adr:adr + dim])
# the sensor slices agree with the state they measure
q1_adr = slices["q1"][0]
err_q = np.abs(sd[:, q1_adr] - d.qpos.numpy()[:, 0]).max()
pa, pd = slices["tip_pos"]
err_p = np.abs(sd[:, pa:pa + pd] - d.site_xpos.numpy()[:, 0]).max()
print(f"max |q1 - qpos[:,0]| = {err_q:.1e}, max |tip_pos - site_xpos| = {err_p:.1e}")
# PENDULUM enables <flag energy="enable"/>: forward also fills d.energy = [potential, kinetic]
print("d.energy:", d.energy.shape, "array of wp.vec2 | worlds shown [E_potential, E_kinetic]:")
print(d.energy.numpy()[show])

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"slices": slices, "ctrl": np.round(d.ctrl.numpy()[show, 0].astype(float), 3).tolist(),
                   "sensordata": np.round(sd[show].astype(float), 3).tolist()}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
