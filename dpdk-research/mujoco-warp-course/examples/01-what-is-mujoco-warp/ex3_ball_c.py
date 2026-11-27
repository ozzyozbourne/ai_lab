"""Example 1.3 - BALL_DROP in classic C MuJoCo: one world, float64, on the CPU.

Drops a 0.1 m ball from 1 m for 1 s with mujoco.mj_step and prints its height every 0.1 s.
Run: python ex3_ball_c.py
"""
import mujoco
import numpy as np

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

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)  # MJCF -> compiled model (constants)
mjd = mujoco.MjData(mjm)                         # state of ONE world
print(f"nq={mjm.nq} nv={mjm.nv} ngeom={mjm.ngeom} timestep={mjm.opt.timestep}")
print("qpos0 =", mjm.qpos0, "(x y z, then the quaternion w x y z)")

nstep = round(1.0 / mjm.opt.timestep)            # 500 steps = 1 s
for i in range(1, nstep + 1):
    mujoco.mj_step(mjm, mjd)
    if i % 50 == 0:                              # every 0.1 s
        print(f"t={mjd.time:.1f} s  z={mjd.qpos[2]:.5f}  ncon={mjd.ncon}")
