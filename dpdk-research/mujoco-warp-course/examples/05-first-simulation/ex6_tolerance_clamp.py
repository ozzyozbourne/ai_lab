"""Example 5.2 - put_model clamps the solver tolerance to 1e-6 for float32.

C MuJoCo's default tolerance (1e-8) was chosen for float64. In float32 the solver could never
reach it and would bounce around the optimum, so put_model applies
opt.tolerance = max(tolerance, 1e-6). The host model is not changed.
Run: python ex6_tolerance_clamp.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=8, suppress=False)  # notebook: undo Example 5.1's print settings

XML = """
<mujoco>
  <worldbody>
    <geom type="plane" size="1 1 .1"/>
    <body pos="0 0 .5"><freejoint/><geom type="box" size=".1 .1 .1"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(XML)
print("MJCF default tolerance (host):", mjm.opt.tolerance)
for tol in (1e-10, 1e-8, 1e-6, 1e-3):
    mjm.opt.tolerance = tol
    m = mjw.put_model(mjm)
    print(f"host tolerance {tol:.0e} -> m.opt.tolerance = {m.opt.tolerance.numpy()}")
print("host value after the loop (put_model never writes it):", mjm.opt.tolerance)
print("float32 machine epsilon:", np.finfo(np.float32).eps)
