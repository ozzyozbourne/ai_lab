"""Example 14.7 - sensor cutoff (clamping) and interval sampling (sample-and-hold).

A 1 kg slider pushed by a constant 1 N force: v = t, x = t^2 / 2, dt = 0.01 s. Four sensors:
  vel_cut   <jointvel cutoff="0.05"/>                     clamped to [-0.05, 0.05]
  pos       <jointpos/>                                   fresh value every step
  pos_int   <jointpos interval="0.03 0" nsample="5"/>       recomputed every 0.03 s, held between
  pos_both  <jointpos delay="0.02" interval="0.03 0" nsample="5"/>  (string from history_test.py)
We print 10 steps of sensordata next to the true state and compare with MuJoCo C at every step.
The one difference (the 0.06 s sample) comes from float32 time; see the last line.
Run: python ex7_cutoff_interval.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=5, suppress=True)

SLIDER = """
<mujoco model="cutoff_interval">
  <option timestep="0.01" gravity="0 0 0"/>
  <worldbody>
    <body name="cart">
      <joint name="slide" type="slide" axis="1 0 0"/>
      <geom type="box" size=".1 .1 .1" mass="1" contype="0" conaffinity="0"/>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="slide" gear="1"/></actuator>
  <sensor>
    <jointvel name="vel_cut" joint="slide" cutoff="0.05"/>
    <jointpos name="pos" joint="slide"/>
    <jointpos name="pos_int" joint="slide" interval="0.03 0" nsample="5"/>
    <jointpos name="pos_both" joint="slide" delay="0.02" interval="0.03 0" nsample="5"/>
  </sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
NSTEP = 10

mjm = mujoco.MjModel.from_xml_string(SLIDER)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
d.ctrl.fill_(1.0)
mjd = mujoco.MjData(mjm)
mjd.ctrl[:] = 1.0

print("sensor_cutoff:", mjm.sensor_cutoff, "| sensor_interval (period, phase):",
      mjm.sensor_interval.tolist())
print("nhistory:", mjm.nhistory, "| d.history shape:", d.history.shape)
print(" step  time   qvel   vel_cut     qpos     pos   pos_int  pos_both | C pos_int")
rows, maxerr = [], 0.0
for i in range(NSTEP):
    qvel, qpos, t = d.qvel.numpy()[0, 0], d.qpos.numpy()[0, 0], d.time.numpy()[0]
    mjw.step(m, d)                     # sensors are computed inside step, before integration
    mujoco.mj_step(mjm, mjd)
    sd = d.sensordata.numpy()[0]
    maxerr = max(maxerr, float(np.abs(sd - mjd.sensordata).max()))
    print(f"{i:5d} {t:5.2f} {qvel:6.3f} {sd[0]:8.3f} {qpos:8.5f} {sd[1]:7.5f} {sd[2]:8.5f} "
          f"{sd[3]:8.5f} | {mjd.sensordata[2]:8.5f}")
    rows.append([round(float(t), 3), round(float(qpos), 6)] + [round(float(v), 6) for v in sd])
print(f"max |MJWarp - MuJoCo C| over {NSTEP} steps: {maxerr:.1e}")
# Why step 6 differs: d.time is float32 in MJWarp. Six additions of 0.01 give 0.059999995, and the
# interval test time_prev + period <= t (history.py) is 0.06 <= 0.059999995: False.
t32 = np.float32(0.0)
for _ in range(6):
    t32 = np.float32(t32 + np.float32(0.01))
print("float32 time after 6 steps:", repr(float(t32)), "| time_prev + period:",
      repr(float(np.float32(0.03) + np.float32(0.03))), "| C time:", 6 * 0.01)

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"cols": ["t", "qpos", "vel_cut", "pos", "pos_int", "pos_both"], "rows": rows},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
