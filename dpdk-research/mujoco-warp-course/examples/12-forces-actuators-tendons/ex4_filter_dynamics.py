"""Example 12.4 - actuator activation dynamics: a first-order filter on ctrl.

With dyntype="filter" the actuator has one activation state act (stored in d.act) with
    act_dot = (ctrl - act) / tau          (forward.py::_actuator_force, tau = dynprm[0])
and the force uses act instead of ctrl. After a step input ctrl = 1 the exact answer is
act(t) = 1 - exp(-t / tau). "filter" integrates act with the integrator (Euler here),
"filterexact" uses the exact exponential update (support.py::next_act). actearly="true" lets the
force use the act of the *next* step, which removes one step of delay.
Run: python ex4_filter_dynamics.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

FILTERS = """
<mujoco model="filters">
  <option timestep="0.01" gravity="0 0 0"/>
  <worldbody>
    <body>
      <joint name="j" type="slide" axis="1 0 0"/>
      <geom type="sphere" size=".05" mass="1"/>
    </body>
  </worldbody>
  <actuator>
    <general name="filter"      joint="j" dyntype="filter"      dynprm="0.1" gainprm="1"/>
    <general name="filterexact" joint="j" dyntype="filterexact" dynprm="0.1" gainprm="1"/>
    <general name="early"       joint="j" dyntype="filterexact" dynprm="0.1" gainprm="1"
             actearly="true"/>
  </actuator>
</mujoco>
"""
TAU = 0.1
mjm = mujoco.MjModel.from_xml_string(FILTERS)
print(f"nu={mjm.nu}, na={mjm.na}, actuator_actadr={mjm.actuator_actadr}, "
      f"actuator_actnum={mjm.actuator_actnum}")
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
d.ctrl.fill_(1.0)                              # step input at t = 0

mjw.forward(m, d)
print("before any step: act =", d.act.numpy()[0], "force =", d.actuator_force.numpy()[0],
      "(actearly already sees the next act)")
steps_per_tau = round(TAU / mjm.opt.timestep)
for k in (1, 2, 3):
    for _ in range(steps_per_tau):
        mjw.step(m, d)
    act = d.act.numpy()[0]
    print(f"t = {k} tau: act = {act}  exact 1 - e^-{k} = {1 - np.exp(-k):.4f}  "
          f"Euler 1 - (1 - h/tau)^n = {1 - (1 - mjm.opt.timestep / TAU) ** (k * steps_per_tau):.4f}")
