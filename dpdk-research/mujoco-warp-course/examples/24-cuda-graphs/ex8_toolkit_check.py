"""Example 24.8 - which graph features does this machine have, and what does capture_step do?

Prints the Warp device, the CUDA toolkit Warp was built with and the CUDA driver it found,
wp.is_conditional_graph_supported() (needs both >= 12.4), whether put_model warned
(warp_util.check_toolkit_driver only *warns*; m.opt.graph_conditional stays True), and what
my_env.capture_step decided.
Run: python ex8_toolkit_check.py
"""
import pathlib
import sys
import warnings

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
    import my_env_step24 as my_env          # examples/24-cuda-graphs/

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


def version(v):
    return "none" if v is None else f"{v[0]}.{v[1]}"


wp.init()
device = wp.get_device()
print("warp", wp.__version__, "| device:", device, "| is_cuda:", device.is_cuda)
print("CUDA toolkit (Warp build):", version(wp.get_cuda_toolkit_version()))
print("CUDA driver:              ", version(wp.get_cuda_driver_version()))
print("wp.is_conditional_graph_supported():", wp.is_conditional_graph_supported())

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
with warnings.catch_warnings(record=True) as caught:
    warnings.simplefilter("always")
    m = mjw.put_model(mjm)                  # calls warp_util.check_toolkit_driver()
toolkit_warnings = [w for w in caught if "CUDA version < 12.4" in str(w.message)]
print("put_model warned about CUDA < 12.4:", bool(toolkit_warnings))
print("m.opt.graph_conditional after put_model:", m.opt.graph_conditional)

d = mjw.make_data(mjm, nworld=2, nconmax=4, njmax=16)
print("needs_conditional_fallback:", my_env.needs_conditional_fallback(device))
graph = my_env.capture_step(m, d, nsub=1)
print("m.opt.graph_conditional after capture_step:", m.opt.graph_conditional)
for _ in range(3):
    wp.capture_launch(graph)
print(f"3 replays OK: d.time = {d.time.numpy()[0]:.3f}")

if device.is_cuda:
    decision = ("conditional nodes (capture_while / capture_if on the device)"
                if m.opt.graph_conditional else "fallback: fixed iteration counts in the graph")
else:
    decision = "CPU graph (Warp APIC recording; capture_while callbacks replay on the CPU)"
print("decision:", decision)
