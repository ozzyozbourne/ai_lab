"""Example 10.5 - per-world mass, done right: batch the inputs AND the derived outputs.

body_mass feeds derived constants that put_model computed once on the host (body_subtreemass,
dof_invweight0, body_invweight0, actuator_acc0). mjw.set_const recomputes them on the device,
one row per world, but only if those output fields also have one row per world.
Run: python ex5_mass_set_const.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

# a box on a rail (slide joint) carrying a 0.5 kg payload, pushed by a motor
SLIDER_BOX = """
<mujoco model="slider_box">
  <option timestep="0.01"/>
  <worldbody>
    <body name="box" pos="0.5 0 0.5">
      <joint name="rail" type="slide" axis="1 0 0"/>
      <geom type="box" size=".1 .1 .1" mass="1" contype="0" conaffinity="0"/>
      <body name="payload" pos="0 0 .15">
        <geom type="sphere" size=".05" mass="0.5" contype="0" conaffinity="0"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="rail" gear="1"/></actuator>
</mujoco>
"""
NWORLD = 4
INPUTS = ["body_mass", "body_inertia"]                    # what we randomize
DERIVED = ["body_subtreemass", "body_invweight0", "dof_invweight0", "actuator_acc0"]

mjm = mujoco.MjModel.from_xml_string(SLIDER_BOX)
box = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "box")
m = mjw.put_model(mjm, batch_sizes={k: NWORLD for k in INPUTS + DERIVED})
d = mjw.make_data(mjm, nworld=NWORLD)

scale = np.array([1.0, 2.0, 4.0, 8.0])                    # box mass 1, 2, 4, 8 kg
bm = m.body_mass.numpy()
bm[:, box] *= scale
m.body_mass.assign(bm)
bi = m.body_inertia.numpy()
bi[:, box] *= scale[:, None]                               # inertia = sum(m r^2): scale together
m.body_inertia.assign(bi)

print("before set_const: body_subtreemass[:, box] =", m.body_subtreemass.numpy()[:, box])
mjw.set_const(m, d)                                        # groups=SetConstGroup.ALL
print("after  set_const: body_subtreemass[:, box] =", m.body_subtreemass.numpy()[:, box])
print("actuator_acc0 (unit motor force -> accel)  =", m.actuator_acc0.numpy()[:, 0])
print("1 / (box + payload mass)                    =", 1.0 / (scale + 0.5))
print("dof_invweight0 [1/kg]                       =", m.dof_invweight0.numpy()[:, 0])

d.ctrl.fill_(1.0)                                          # 1 N in every world
mjw.forward(m, d)
print("qacc for ctrl = 1 N                         =", d.qacc.numpy()[:, 0])
