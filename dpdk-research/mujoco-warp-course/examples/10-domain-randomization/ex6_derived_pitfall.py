"""Example 10.6 - the derived-field pitfall: batch body_mass only, and set_const writes ONE row.

Same model and masses as Example 10.5, but the derived outputs keep batch size 1. set_const
launches its kernels over the OUTPUT's leading size (e.g. dim=(body_subtreemass.shape[0], nbody)),
so it computes world 0 only and every world then reads that single row.
Run: python ex6_derived_pitfall.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

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

mjm = mujoco.MjModel.from_xml_string(SLIDER_BOX)
box = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "box")
m = mjw.put_model(mjm, batch_sizes={"body_mass": NWORLD, "body_inertia": NWORLD})  # inputs only!
d = mjw.make_data(mjm, nworld=NWORLD)

scale = np.array([1.0, 2.0, 4.0, 8.0])
bm = m.body_mass.numpy()
bm[:, box] *= scale
m.body_mass.assign(bm)
bi = m.body_inertia.numpy()
bi[:, box] *= scale[:, None]
m.body_inertia.assign(bi)
mjw.set_const(m, d)

print("body_mass[:, box]        shape", m.body_mass.shape, "->", m.body_mass.numpy()[:, box])
print("body_subtreemass[:, box] shape", m.body_subtreemass.shape, "->",
      m.body_subtreemass.numpy()[:, box], "(world 0's value, shared)")
print("actuator_acc0            shape", m.actuator_acc0.shape, "->", m.actuator_acc0.numpy()[:, 0])

d.ctrl.fill_(1.0)
mjw.forward(m, d)
print("qacc per world (uses body_mass directly, still right):", d.qacc.numpy()[:, 0])
# subtree_com = sum(xipos * body_mass) / body_subtreemass: the stale denominator shows up here
print("subtree_com x of 'box' (true value 0.5 in every world):", d.subtree_com.numpy()[:, box, 0])
