"""Example 14.8 - actuator delay: <motor delay="0.03" nsample="5"/> at dt = 0.01.

ctrl = 1 from step 0 in every world. The actuator reads ctrl from its history buffer at
time - delay (history.py::read_ctrl_delayed), and _advance inserts the current ctrl just before
time advances (insert_ctrl_history). So actuator_force is 0 for 3 steps, then 1.
We also print the raw ring buffer of world 0 after each step: [user, cursor, times[5], values[5]].
Run: python ex8_actuator_delay.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

DELAYED_MOTOR = """
<mujoco model="actuator_delay">
  <option timestep="0.01" gravity="0 0 0"/>
  <worldbody>
    <body name="cart">
      <joint name="slide" type="slide" axis="1 0 0"/>
      <geom type="box" size=".1 .1 .1" mass="1" contype="0" conaffinity="0"/>
    </body>
  </worldbody>
  <actuator><motor joint="slide" delay="0.03" nsample="5"/></actuator>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
NSTEP = 6

mjm = mujoco.MjModel.from_xml_string(DELAYED_MOTOR)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
mjd = mujoco.MjData(mjm)

print("actuator_delay:", mjm.actuator_delay, "| actuator_history (nsample, interp):",
      mjm.actuator_history.tolist(), "| nhistory:", mjm.nhistory)
print("history buffer layout: [user, cursor, times x nsample, values x nsample x ctrlnum]")
buf0 = d.history.numpy()[0]
print("initial buffer (world 0):", buf0)

d.ctrl.fill_(1.0)
mjd.ctrl[:] = 1.0
force, force_c, frames = [], [], [{"t": 0.0, "buf": np.round(buf0.astype(float), 3).tolist(), "force": None}]
for i in range(NSTEP):
    t = float(d.time.numpy()[0])
    mjw.step(m, d)
    mujoco.mj_step(mjm, mjd)
    f = float(d.actuator_force.numpy()[0, 0])
    force.append(round(f, 3))
    force_c.append(round(float(mjd.actuator_force[0]), 3))
    buf = d.history.numpy()[0]
    print(f"step {i}: t={t:.2f}  reads ctrl at t-0.03={t - 0.03:+.2f} -> actuator_force {f:.1f} | "
          f"buffer after step: cursor={int(buf[1])} times={buf[2:7]} values={buf[7:12]}")
    frames.append({"t": round(t, 3), "buf": np.round(buf.astype(float), 3).tolist(), "force": round(f, 3)})
print("actuator_force over 6 steps, MJWarp :", force)
print("actuator_force over 6 steps, MuJoCo C:", force_c)
af = d.actuator_force.numpy()
print("all worlds identical:", bool((af == af[0]).all()))

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nsample": 5, "dt": 0.01, "delay": 0.03, "frames": frames}, f,
                  separators=(",", ":"))
    print("wrote", args.dump_json)
