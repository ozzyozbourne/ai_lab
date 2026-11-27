"""Example 1.8 - what an unsupported feature looks like: the PGS solver.

C MuJoCo compiles the model fine; mjw.put_model refuses it with NotImplementedError.
Switching to the default Newton solver makes it load.
Run: python ex8_unsupported_pgs.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

XML = """
<mujoco>
  <option solver="{solver}"/>
  <worldbody>
    <geom type="plane" size="1 1 .1"/>
    <body pos="0 0 .2"><freejoint/><geom type="sphere" size=".1"/></body>
  </worldbody>
</mujoco>
"""

for solver in ["PGS", "CG", "Newton"]:
    mjm = mujoco.MjModel.from_xml_string(XML.format(solver=solver))   # C MuJoCo accepts all three
    try:
        m = mjw.put_model(mjm)
        print(f"solver={solver:6s}: put_model OK, m.opt.solver = {mjw.SolverType(m.opt.solver).name}")
    except NotImplementedError as e:
        print(f"solver={solver:6s}: {type(e).__name__}: {e}")
