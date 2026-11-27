"""Example 12.10 - cacc and cfrc_ext are only "real" after rne_postconstraint.

During fwd_velocity, smooth.py::rne runs without accelerations (flg_acc=False): d.cacc holds only
the gravity trick (+g upward) plus velocity terms, and d.cfrc_ext is not touched. The contact
force is only known after the solver, so smooth.py::rne_postconstraint (called at the end of
forward) rebuilds cfrc_ext (xfrc_applied + contacts + equality + spatial tendons) and recomputes
cacc with the real qacc. It runs when m.opt.run_rne_postconstraint is True, or when the model has
a sensor that needs it (accelerometer, force, torque, ...: m.sensor_rne_postconstraint).
World 0: a 1 kg ball resting on the floor. World 1: the same ball lifted to z = 1 (free fall).
cacc includes the gravity trick, so after rne_postconstraint it reads like an accelerometer:
+g when resting, 0 in free fall.
Run: python ex10_postconstraint.py
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
mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=2, nconmax=4, njmax=16)
for _ in range(1000):                       # 2 s: the ball lands and comes to rest
    mjw.step(m, d)
qpos, qvel = d.qpos.numpy().copy(), d.qvel.numpy().copy()
qpos[1, 2], qvel[1] = 1.0, 0.0              # world 1: lift the ball, it starts to fall
d.qpos.assign(qpos)
d.qvel.assign(qvel)
print("ball z per world =", qpos[:, 2].round(4), "| m.sensor_rne_postconstraint =",
      m.sensor_rne_postconstraint)

for flag in (False, True):
    m.opt.run_rne_postconstraint = flag
    d.cfrc_ext.zero_()
    mjw.forward(m, d)
    print(f"run_rne_postconstraint={flag}:")
    for w, name in ((0, "resting"), (1, "falling")):
        print(f"  {name}: cacc[ball] = {d.cacc.numpy()[w, 1]}  cfrc_ext[ball] = "
              f"{d.cfrc_ext.numpy()[w, 1]}")
print("qacc[z] per world =", d.qacc.numpy()[:, 2].round(4), "-> cacc_z = 9.81 + qacc_z;",
      "the floor pushes the resting ball up with m g = 9.81 N")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
