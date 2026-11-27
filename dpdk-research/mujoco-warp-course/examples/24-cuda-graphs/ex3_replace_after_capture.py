"""Example 24.3 - replacing an array after capture: the graph keeps writing the OLD array.

A graph stores the device addresses of the arrays it was recorded with. `d.qpos = wp.array(...)`
makes d point at a NEW array, but the graph still reads and writes the old one, so the new
array never changes and nothing warns you. Fix 1: change contents in place with .assign().
Fix 2: recapture after the replacement. (Ch 6 owns replace vs assign; this is the graph side.)
Run: python ex3_replace_after_capture.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NREPLAY = 50

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
if wp.get_device().is_cuda and not wp.is_conditional_graph_supported():
    m.opt.graph_conditional = False                    # Rule G fallback (CUDA < 12.4)
    print("note: CUDA < 12.4, using m.opt.graph_conditional = False")

mjw.step(m, d)                                         # warm-up
with wp.ScopedCapture() as capture:
    mjw.step(m, d)
graph = capture.graph

start = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
start[:, 2] = 2.0                                      # every ball starts at z = 2 m


def z(arr):
    return f"{arr.numpy()[0, 2]:.4f}"


# --- WRONG: replace the array object ------------------------------------------------------
old = d.qpos
d.qpos = wp.array(start, dtype=float)                  # new allocation, new address
d.qvel.zero_()
for _ in range(NREPLAY):
    wp.capture_launch(graph)
wp.synchronize()
print(f"replace: new d.qpos z = {z(d.qpos)}  (never written by the graph)")
print(f"         old array  z = {z(old)}  (the graph kept stepping this one)")
print("         same object?", d.qpos is old, "| same address?", d.qpos.ptr == old.ptr)

# --- RIGHT (fix 1): restore the old object and change its contents in place ---------------
d.qpos = old
d.qpos.assign(start)
d.qvel.zero_()
for _ in range(NREPLAY):
    wp.capture_launch(graph)
wp.synchronize()
print(f"assign:  d.qpos z = {z(d.qpos)}  (falls from 2.0 as expected)")

# --- RIGHT (fix 2): replace, then recapture so the graph records the new address ----------
d.qpos = wp.array(start, dtype=float)
d.qvel.zero_()
with wp.ScopedCapture() as capture:
    mjw.step(m, d)
graph = capture.graph
for _ in range(NREPLAY):
    wp.capture_launch(graph)
wp.synchronize()
print(f"replace + recapture: d.qpos z = {z(d.qpos)}  (matches the assign result)")
