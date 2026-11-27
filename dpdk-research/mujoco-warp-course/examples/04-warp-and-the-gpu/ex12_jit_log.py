"""Example 4.12 - JIT compilation, the kernel cache and Warp's INFO log.

This is the one script in the course that leaves Warp at its default log level (INFO) on
purpose: Warp then prints one "Module ... load on device ... took ... ms (compiled|cached)"
line per module it loads. A first mjw.step loads dozens of modules. We collect those lines with
wp.set_logger, then switch to wp.LOG_WARNING (what every other example does right after
`import warp`) and load a brand-new module: no line at all, although it is still compiled on a
cold cache, or loaded from the kernel cache on a warm one.
Run: python ex12_jit_log.py   (run it twice: the second run says "cached")
"""
import re
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_INFO                  # Warp 1.19 default, shown once in the course
import mujoco_warp as mjw

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


class CollectingLogger:
    """Implements Warp's Logger protocol (debug/info/warning/error) and keeps the messages."""

    def __init__(self):
        self.lines = []

    def debug(self, message):
        self.lines.append(message)

    def info(self, message):
        self.lines.append(message)

    def warning(self, message, category=None, stacklevel=1):
        self.lines.append(message)

    def error(self, message):
        self.lines.append(message)


def module_lines(log):
    return [s for s in log.lines if s.startswith("Module ")]


@wp.kernel(module="unique")
def double_it(x: wp.array[float]):
    i = wp.tid()
    x[i] = 2.0 * x[i]


# --- phase 1: default INFO level -------------------------------------------------------
log1 = CollectingLogger()
wp.set_logger(log1)
mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2, nconmax=4, njmax=16)
t0 = time.perf_counter()
mjw.step(m, d)                                     # first step: loads every module it needs
wp.synchronize()
t_first = time.perf_counter() - t0
t0 = time.perf_counter()
mjw.step(m, d)                                     # second step: modules already in memory
wp.synchronize()
t_second = time.perf_counter() - t0
lines1 = module_lines(log1)

# --- phase 2: the course setting ---------------------------------------------------------
wp.config.log_level = wp.LOG_WARNING
log2 = CollectingLogger()
wp.set_logger(log2)
x = wp.ones(4, dtype=float)
t0 = time.perf_counter()
wp.launch(double_it, dim=4, inputs=[x])            # a new module: compiled or loaded silently
t_new = time.perf_counter() - t0
lines2 = module_lines(log2)
wp.set_logger(None)                                # restore Warp's default logger

banner = [s for s in log1.lines if s.startswith("Warp ")]
first = banner[0].splitlines()[0] if banner else "none (Warp was already initialized)"
print("INFO level   : init banner captured:", first)
print("INFO level   : 'Module' lines during the first mjw.step:", len(lines1))
print("  of which (cached):", sum("(cached)" in s for s in lines1),
      "| (compiled):", sum("(compiled)" in s for s in lines1))
if lines1:
    print("  example line:", re.sub(r"took [0-9.]+ ms", "took ... ms", lines1[0]))
print(f"  first step {1e3 * t_first:.0f} ms, second step {1e3 * t_second:.1f} ms")
print("WARNING level: 'Module' lines for a new module:", len(lines2),
      f"(it still took {1e3 * t_new:.0f} ms)", "| x =", x.numpy())
print("kernel cache directory:", wp.config.kernel_cache_dir)
