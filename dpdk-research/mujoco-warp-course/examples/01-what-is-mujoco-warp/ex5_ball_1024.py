"""Example 1.5 - many BALL_DROP worlds in one call: 1024 on a GPU, 8 on the CPU.

Each world starts at its own random height (written with d.qpos.assign); one mjw.step advances all.
Run: python ex5_ball_1024.py
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

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 8
NSTEP = 250                                   # 0.5 s: the highest balls are still falling

mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)   # nconmax is per world

rng = np.random.default_rng(0)
qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)   # (nworld, nq)
qpos[:, 2] = rng.uniform(0.5, 2.0, NWORLD)                  # column 2 = ball z
d.qpos.assign(qpos)                                          # write in place on the device
print("device:", wp.get_device(), "| nworld:", d.nworld)
print("d.qpos.shape:", d.qpos.shape, "| first start heights:", qpos[:4, 2])

for _ in range(NSTEP):
    mjw.step(m, d)                            # ONE call advances every world
wp.synchronize()

z = d.qpos.numpy()[:, 2]
t = NSTEP * mjm.opt.timestep
print(f"t = {t:.2f} s  final z: min {z.min():.4f}  max {z.max():.4f}")
print("worlds resting on the floor (z < 0.101):", int((z < 0.101).sum()), "of", NWORLD)
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
