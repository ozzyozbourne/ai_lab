"""Example 23.6 - a stiff cloth: Euler blows up, DISCRETE stays finite at the same timestep.

The 5x5 hanging cloth of Example 23.2, with a 10x stiffer membrane (young 5e5). Explicit
(semi-implicit) Euler is only stable while the stiffest mode satisfies omega * dt < 2; here it
does not. DISCRETE builds an effective metric M_hat = M + h D + h^2 K from the flex stiffness
(derivative.eff_build) and solves the step in that metric, so it stays stable. IMPLICITFAST
refuses flex elasticity (forward.py::check_discrete). We step both integrators in the same
script and watch for non-finite values (the non-finite guard of Ch 8, without the reset).
Run: python ex6_discrete_integrator.py
"""
import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2
NSTEP = 400


def hanging_cloth(young, integrator):
    return f"""
<mujoco model="stiff_cloth">
  <option timestep="0.002" integrator="{integrator}" solver="CG" tolerance="1e-8"/>
  <worldbody>
    <flexcomp name="cloth" type="grid" count="5 5 1" spacing=".05 .05 .05" pos="0 0 1"
              radius=".005" dim="2" mass=".05">
      <pin id="20 24"/>
      <elasticity young="{young}" poisson="0.2" thickness="1e-3" elastic2d="stretch"/>
      <contact contype="0" conaffinity="0"/>
    </flexcomp>
  </worldbody>
</mujoco>
"""


@wp.kernel
def nonfinite_flag(qpos: wp.array2d(dtype=float), bad: wp.array(dtype=int)):
    w, j = wp.tid()
    if not wp.isfinite(qpos[w, j]):
        bad[w] = 1


def run(young, integrator):
    mjm = mujoco.MjModel.from_xml_string(hanging_cloth(young, integrator))
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=NWORLD)
    bad = wp.zeros(NWORLD, dtype=int)
    first_bad = None
    mjw.step(m, d)                                # compile
    wp.synchronize()
    t0 = time.perf_counter()
    for i in range(1, NSTEP):
        mjw.step(m, d)
        wp.launch(nonfinite_flag, dim=(NWORLD, mjm.nq), inputs=[d.qpos, bad])
        if first_bad is None and i % 10 == 0 and bad.numpy().any():   # demo: host read
            first_bad = i
    wp.synchronize()
    sec = time.perf_counter() - t0
    L0 = m.flexedge_length0.numpy()
    strain = (d.flexedge_length.numpy() - L0) / L0
    finite = bool(np.isfinite(d.qpos.numpy()).all())
    a = np.abs(strain)
    smax = float(np.nanmax(a)) if np.isfinite(a).any() else float("nan")
    return m, finite, first_bad, smax, d.solver_niter.numpy(), sec


print(f"{'young':>7} {'integrator':>11} {'finite':>6} {'first NaN step':>14} "
      f"{'max |strain|':>12} {'ms/step (' + ('GPU' if ON_GPU else 'CPU') + ')':>13}")
for young in (5e4, 5e5):
    for integ in ("Euler", "discrete"):
        m, finite, first_bad, smax, niter, sec = run(young, integ)
        fb = "-" if first_bad is None else f"<= {first_bad}"
        sm = f"{smax:.4f}" if finite else "nan/inf"
        print(f"{young:7.0e} {integ:>11} {str(finite):>6} {fb:>14} {sm:>12} "
              f"{1000 * sec / (NSTEP - 1):13.2f}")
        if integ == "discrete":
            print(f"        DISCRETE: K has m.nefmK = {m.nefmK} nonzeros; "
                  f"solver_niter in the last step {niter}")

mjm = mujoco.MjModel.from_xml_string(hanging_cloth(5e5, "Euler"))
mjm.opt.integrator = mujoco.mjtIntegrator.mjINT_IMPLICITFAST   # the C compiler refuses it too
try:
    m = mjw.put_model(mjm)
    mjw.forward(m, mjw.make_data(mjm, nworld=1))
except ValueError as e:
    print("implicitfast:", e)
