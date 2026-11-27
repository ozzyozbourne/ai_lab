"""Example 14.9 - sensor delay: a delayed jointpos next to a fresh one, and mjw.read_sensor.

A slider coasts at constant speed (world w: qvel = 1 + w, no gravity, no friction), so the fresh
jointpos equals speed * t. The delayed copy (delay="0.02" nsample="4") lags by exactly 2 steps of
dt = 0.01. Then mjw.read_sensor queries the history buffer at chosen times with ZOH (interp=0) and
linear (interp=1) interpolation. Note: read_sensor looks up the buffer at time - delay, i.e. it
returns what the delayed sensor would report at that time (history.py::_read_sensor_kernel).
Run: python ex9_sensor_delay.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

COAST = """
<mujoco model="sensor_delay">
  <option timestep="0.01" gravity="0 0 0"/>
  <worldbody>
    <body name="cart">
      <joint name="slide" type="slide" axis="1 0 0"/>
      <geom type="box" size=".1 .1 .1" mass="1" contype="0" conaffinity="0"/>
    </body>
  </worldbody>
  <sensor>
    <jointpos name="fresh" joint="slide"/>
    <jointpos name="delayed" joint="slide" delay="0.02" nsample="4"/>
  </sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 3
NSTEP = 8

mjm = mujoco.MjModel.from_xml_string(COAST)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
d.qvel.assign((1.0 + np.arange(NWORLD, dtype=np.float32))[:, None])

print("sensor_delay:", mjm.sensor_delay, "| sensor_history (nsample, interp):",
      mjm.sensor_history.tolist(), "| nhistory:", mjm.nhistory)
rows = []
print("step  time  fresh(w0) delayed(w0)  fresh(w1) delayed(w1)")
for i in range(NSTEP):
    mjw.step(m, d)            # sensors are evaluated at the state *before* integration
    sd = d.sensordata.numpy()
    t = i * mjm.opt.timestep                   # time at which they were measured
    print(f"{i:4d} {t:5.2f} {sd[0, 0]:9.4f} {sd[0, 1]:11.4f} {sd[1, 0]:10.4f} {sd[1, 1]:11.4f}")
    rows.append([round(t, 3)] + [round(float(v), 4) for v in sd[:2].ravel()])
lag = (sd[:, 0] - sd[:, 1]) / (1.0 + np.arange(NWORLD))
print("lag fresh - delayed, in seconds, per world:", lag[:4], "=", round(lag[0] / 0.01), "steps")

# query the delayed sensor at past times: one query time per world
res = wp.zeros((d.nworld, 1), dtype=float)
qt = np.full(NWORLD, 0.065, dtype=np.float32)             # between two buffer samples
for interp, label in ((0, "ZOH"), (1, "linear")):
    mjw.read_sensor(m, d, 1, wp.array(qt, dtype=float), interp, res)
    print(f"read_sensor(sensor 1, time=0.065, interp={interp} {label}): {res.numpy()[:4, 0]}"
          f"  (buffer at 0.065 - 0.02 = 0.045)")
buf = d.history.numpy()[0]
n = 4
cursor = int(buf[1])
order = [(cursor + 1 + k) % n for k in range(n)]           # _history_physical_index
print("world 0 buffer, oldest -> newest: times", buf[2:2 + n][order], "values",
      buf[2 + n:2 + 2 * n][order])

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"cols": ["t", "fresh_w0", "delayed_w0", "fresh_w1", "delayed_w1"],
                   "rows": rows}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
