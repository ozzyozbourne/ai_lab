"""Example 23.2b - an elastic rod: a dim=1 flex with <elasticity> becomes a discrete elastic rod.

A 1-D flexcomp with young/poisson gets bending and twist data from the compiler: one hinge per
interior vertex, and extra twist joints. We clamp vertices 0 and 1 to a body (one pinned vertex
would only be a hinge) and let the rod sag as a cantilever under the DISCRETE integrator, next
to the same chain without elasticity. Both keep their edge lengths with an edge equality:
for dim=1, <elasticity> adds bending and twist, not stretch.
Run: python ex2b_elastic_rod.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 1
NSTEP = 250


def rod(elasticity):
    return f"""
<mujoco model="rod">
  <option integrator="discrete" timestep="0.002"/>
  <worldbody>
    <body name="clamp" pos="0 0 1">
      <flexcomp name="rod" type="grid" count="8 1 1" spacing=".05 .05 .05" dim="1"
                radius=".01" mass=".1">
        {elasticity}
        <pin id="0 1"/>
        <contact contype="0" conaffinity="0"/>
      </flexcomp>
    </body>
  </worldbody>
</mujoco>
"""


for name, el in (("elastic rod", '<elasticity young="1e7" poisson="0.3"/><edge equality="true"/>'),
                 ("rope (no elasticity)", '<edge equality="true"/>')):
    mjm = mujoco.MjModel.from_xml_string(rod(el))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD)
    mjw.forward(m, d)
    rest = d.flexvert_xpos.numpy()[0, -1].copy()
    for _ in range(NSTEP):
        mjw.step(m, d)
    wp.synchronize()
    tip = d.flexvert_xpos.numpy()[0, -1]
    print(f"{name}:")
    nfree = mjm.nflexvert - 2
    print(f"  nv {mjm.nv} = {nfree} free vertices x 3 + {mjm.nv - 3 * nfree} twist DOFs  "
          f"flex_bendingadr {mjm.flex_bendingadr}  nplastic {mjm.nplastic}")
    print(f"  rod hinges m.nflexrodhinge {m.nflexrodhinge}  rod edges m.nflexrodedge "
          f"{m.nflexrodedge}  m.flex_rod_has_twist {m.flex_rod_has_twist.numpy()}")
    print(f"  tip at rest {rest}, after {NSTEP * mjm.opt.timestep:.1f} s {tip}, "
          f"z drop {rest[2] - tip[2]:.4f} m")
