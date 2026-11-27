"""Example 5.8 - d.time is float32: it accumulates rounding error step by step.

_next_time adds opt.timestep to d.time once per step, in float32 on the device. After 11 steps
of dt = 0.01 the clock reads 0.10999998, not 0.11. The same running sum in NumPy float32 and
float64 shows where the error comes from and how it grows.
Run: python ex5_time_float32.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

XML = """
<mujoco>
  <option timestep="0.01"/>
  <worldbody>
    <body><joint type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2)

for _ in range(11):
    mjw.step(m, d)

t32 = d.time.numpy()[0]
t_py = 0.0
for _ in range(11):
    t_py += 0.01                      # Python float = float64
print(f"MJWarp d.time after 11 steps : {str(t32)}  (dtype {d.time.dtype.__name__})")
print(f"same sum in float64           : {t_py!r}")
print(f"exact                         : {11 * 0.01:.2f}")
print(f"float32 nearest to 0.01       : {float(np.float32(0.01)):.12f}")

# how the error grows: running sums in float32 vs float64 (pure NumPy, no simulation)
for n in (11, 1_000, 100_000, 1_000_000):
    s32 = np.cumsum(np.full(n, 0.01, dtype=np.float32), dtype=np.float32)[-1]
    err = abs(float(s32) - n * 0.01)
    print(f"n = {n:>9,} steps: float32 clock = {float(s32):>16.8f}  error = {err:.2e} s")
