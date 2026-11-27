"""Example T.2 - a custom Warp kernel that reads MJWarp's batched state (template chapter demo).

One thread per world computes the ball's energy from d.qpos and d.qvel.
Run: python ex02_energy_kernel.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco>
  <option timestep="0.002"/>
  <worldbody>
    <geom type="plane" size="5 5 0.1"/>
    <body pos="0 0 1">
      <freejoint/>
      <geom type="sphere" size="0.1" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSTEP = 100


@wp.kernel
def ball_energy(qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float),
                mass: float, g: float, energy: wp.array(dtype=float)):
    worldid = wp.tid()                      # one thread per world
    v = wp.vec3(qvel[worldid, 0], qvel[worldid, 1], qvel[worldid, 2])
    energy[worldid] = 0.5 * mass * wp.dot(v, v) + mass * g * qpos[worldid, 2]


mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
energy = wp.zeros(NWORLD, dtype=float)

for _ in range(NSTEP):
    mjw.step(m, d)
wp.launch(ball_energy, dim=d.nworld, inputs=[d.qpos, d.qvel, 1.0, 9.81], outputs=[energy])
print("energy per world [J]:", energy.numpy()[:4])
print("expected at rest height 1 m:", round(1.0 * 9.81 * 1.0, 4))
