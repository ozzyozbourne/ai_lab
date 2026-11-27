"""Example 10.2 - per-world fluid density: vacuum, air and water in one batch.

Ch 6 ex7 gave every world its own gravity by REPLACING m.opt.gravity. Here we do the same with a
field Ch 6 did not touch: m.opt.density. MuJoCo's inertia-box fluid model then adds a quadratic
drag F_i = -0.5 * density * A_i * |v_i| * v_i on each axis of the body's inertia box, with A_x = b_y * b_z
etc. (passive.py::_fluid_force; this model has no buoyancy term), so the "water" world falls much more slowly. No floor: we only watch the ball.
Run: python ex2_density_worlds.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

# density="1.2" in the XML matters: put_model sets the host flag m.has_fluid from the XML values,
# and the fluid kernels only run when that flag is True (see the second half of this script).
LIGHT_BALL = """
<mujoco model="light_ball">
  <option timestep="0.01" density="{density}"/>
  <worldbody>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom type="sphere" size=".1" mass="4"/>
    </body>
  </worldbody>
</mujoco>
"""
DENSITY = [0.0, 1.2, 1000.0]          # vacuum, air, water [kg/m^3]
NSTEP = 100                            # 1 s of simulated time


def run(xml_density):
    mjm = mujoco.MjModel.from_xml_string(LIGHT_BALL.format(density=xml_density))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=len(DENSITY))
    m.opt.density = wp.array(DENSITY, dtype=float)        # replace: batch of 3, one per world
    for _ in range(NSTEP):
        mjw.step(m, d)
    return m, d.qpos.numpy()[:, 2], d.qvel.numpy()[:, 2]


m, z, vz = run(1.2)
print("m.opt.density:", m.opt.density.numpy(), "| m.has_fluid:", m.has_fluid)
for rho, zi, vi in zip(DENSITY, z, vz):
    print(f"  density {rho:7.1f}  ->  z after 1 s = {zi:+.4f} m, vz = {vi:+.3f} m/s")
print("free fall from 1 m for 1 s would give z =", round(1 - 0.5 * 9.81, 4))
# inertia box of a solid sphere: side = sqrt(6 * 0.4 r^2) = 0.155 m, frontal area A = side^2
side = np.sqrt(6 * 0.4 * 0.1**2)
print(f"water terminal speed sqrt(2 m g / (rho A)) = {np.sqrt(2 * 4 * 9.81 / (1000 * side**2)):.3f} m/s")

m0, z0, _ = run(0.0)
print("same batch, but XML density=0 -> m.has_fluid:", m0.has_fluid, "| z:", z0)
