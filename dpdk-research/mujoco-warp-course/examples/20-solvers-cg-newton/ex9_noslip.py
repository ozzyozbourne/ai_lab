"""Example 20.9 - noslip: the slow creep of soft friction, and what noslip removes.

A flat slab (0.2 x 0.2 x 0.04 m, 1 kg, friction 0.8) rests on a 30-degree slope. The slope is
modelled by tilting gravity: g = 9.81 (sin 30, 0, -cos 30). tan 30 = 0.58 < 0.8, so a rigid model
would hold the slab still. MuJoCo's friction rows are soft (regularized): they only resist
sliding through a small velocity, so the slab creeps. noslip (solver.py::noslip) runs projected
Gauss-Seidel over the friction rows only, with the unregularized Delassus operator J M^-1 J',
after the main solve; noslip sweeps are added to d.solver_niter. We print the drift after 2 s for
both cones, with and without noslip, next to C MuJoCo (float64) for the same model.
Run: python ex9_noslip.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

SLOPE = """
<mujoco model="slope">
  <option timestep="0.005" gravity="4.905 0 -8.496"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="3 3 .1" friction="0.8"/>
    <body name="slab" pos="0 0 0.02">
      <freejoint/>
      <geom type="box" size=".1 .1 .02" mass="1" friction="0.8"/>
    </body>
  </worldbody>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
T_END = 2.0

print(f"drift down the slope in {T_END:.0f} s (after 20 settling steps)")
for cone in ("PYRAMIDAL", "ELLIPTIC"):
    for noslip in (0, 10):
        mjm = mujoco.MjModel.from_xml_string(SLOPE)
        mjm.opt.cone = getattr(mujoco.mjtCone, f"mjCONE_{cone}")
        mjm.opt.noslip_iterations = noslip
        nstep = int(round(T_END / mjm.opt.timestep))

        m = mjw.put_model(mjm)
        d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
        for _ in range(20):
            mjw.step(m, d)
        x0 = d.qpos.numpy()[0, 0]
        for _ in range(nstep):
            mjw.step(m, d)
        drift = d.qpos.numpy()[0, 0] - x0

        mjd = mujoco.MjData(mjm)                 # the same model in C MuJoCo, for reference
        for _ in range(20):
            mujoco.mj_step(mjm, mjd)
        cx0 = mjd.qpos[0]
        for _ in range(nstep):
            mujoco.mj_step(mjm, mjd)

        print(f"  {cone.lower():9s} noslip_iterations={noslip:2d}: MJWarp {drift * 1e3:7.3f} mm  "
              f"(C MuJoCo {(mjd.qpos[0] - cx0) * 1e3:7.3f} mm)  solver_niter "
              f"{d.solver_niter.numpy()[0]:2d}  nefc {d.nefc.numpy()[0]:2d}  overflow "
              f"{'none' if not d.overflow.numpy().any() else d.overflow.numpy()}")
print(f"noslip_tolerance: {m.opt.noslip_tolerance.numpy()[0]:.0e}")
