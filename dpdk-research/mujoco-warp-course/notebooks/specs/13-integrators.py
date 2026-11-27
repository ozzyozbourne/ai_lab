# Notebook spec for Ch 13. Build with:
#   python3 tools/make_notebook.py notebooks/specs/13-integrators.py
SLUG = "13-integrators"
TITLE = "Ch 13 · Time Integration: Euler, RK4, Implicit and Discrete"

EX1_STUB = '# Needs DTS and errors from Example 13.9 (run that cell first).\nimport numpy as np\n\n\ndef fit_order(dts, err, floor=2e-5):\n    keep = ...            # drop the points at the float32 floor\n    return ...            # least-squares slope of log(err) against log(dt)\n\n\np_rk4, p_euler = fit_order(DTS, errors["RK4"]), fit_order(DTS, errors["Euler"])\nprint(f"order: RK4 {p_rk4:.2f}, Euler {p_euler:.2f}")\nassert p_rk4 > 3\nassert 0.8 < p_euler < 1.3'
EX1_SOL = 'def fit_order(dts, err, floor=2e-5):\n    keep = err > floor\n    return float(np.polyfit(np.log(dts[keep]), np.log(err[keep]), 1)[0])'
EX2_STUB = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nCARTPOLE = """\n<mujoco model="cartpole">\n  <option timestep="0.01" integrator="implicitfast"/>\n  <worldbody>\n    <light pos="0 -2 3" dir="0 1 -1"/>\n    <camera name="front" pos="0 -4 1" xyaxes="1 0 0 0 0 1"/>\n    <geom name="rail" type="capsule" fromto="-2 0 1 2 0 1" size=".02" contype="0" conaffinity="0"/>\n    <body name="cart" pos="0 0 1">\n      <joint name="slider" type="slide" axis="1 0 0" range="-1.8 1.8" limited="true" damping="0.1"/>\n      <geom name="cart" type="box" size=".2 .1 .05" mass="1" contype="0" conaffinity="0"/>\n      <body name="pole">\n        <joint name="hinge" type="hinge" axis="0 1 0" damping="0.01"/>\n        <geom name="pole" type="capsule" fromto="0 0 0 0 0 .6" size=".03" mass="0.1"\n              contype="0" conaffinity="0"/>\n      </body>\n    </body>\n  </worldbody>\n  <actuator><motor name="push" joint="slider" gear="10" ctrlrange="-1 1" ctrllimited="true"/></actuator>\n  <sensor>\n    <jointpos joint="slider"/><jointpos joint="hinge"/>\n    <jointvel joint="slider"/><jointvel joint="hinge"/>\n  </sensor>\n</mujoco>\n"""\nDTS = np.array([0.002, 0.004, 0.006, 0.008, 0.01, 0.012, 0.014, 0.016, 0.02, 0.025, 0.03, 0.04])\nmjm = mujoco.MjModel.from_xml_string(CARTPOLE)\nmjm.dof_damping[:] = [200.0, 0.01]          # a very stiff damper on the cart\nCASES = {"Euler": (mjw.IntegratorType.EULER, False),\n         "Euler, EULERDAMP off": (mjw.IntegratorType.EULER, True),\n         "RK4": (mjw.IntegratorType.RK4, False),\n         "implicitfast": (mjw.IntegratorType.IMPLICITFAST, False)}\n\n\ndef largest_stable_dt(integrator, no_eulerdamp, nstep=100):\n    ...   # one model, per-world timesteps, qvel = (1.0, 0.5) in every world, nstep steps\n    ...   # return the largest dt before the first unstable world\n\n\ndt_max = {name: largest_stable_dt(*case) for name, case in CASES.items()}\nfor name, dt in dt_max.items():\n    print(f"{name:<22} largest stable dt = {dt:.3f} s")\nassert dt_max["implicitfast"] >= dt_max["RK4"] > dt_max["Euler, EULERDAMP off"]\nassert dt_max["Euler"] > dt_max["Euler, EULERDAMP off"]'
EX2_SOL = 'def largest_stable_dt(integrator, no_eulerdamp, nstep=100):\n    m = mjw.put_model(mjm)\n    m.opt.integrator = integrator\n    if no_eulerdamp:\n        m.opt.disableflags |= mjw.DisableBit.EULERDAMP\n    m.opt.timestep = wp.array(DTS, dtype=float)        # one timestep per world\n    d = mjw.make_data(mjm, nworld=len(DTS))\n    d.qvel.assign(np.tile([1.0, 0.5], (len(DTS), 1)))\n    for _ in range(nstep):\n        mjw.step(m, d)\n    v = d.qvel.numpy()\n    stable = np.isfinite(v).all(axis=1) & (np.abs(v).max(axis=1) < 10)\n    first_bad = np.flatnonzero(~stable)\n    return DTS[-1] if first_bad.size == 0 else DTS[: first_bad[0]].max()\n\n\ndt_max = {name: largest_stable_dt(*case) for name, case in CASES.items()}\nfor name, dt in dt_max.items():\n    print(f"{name:<22} largest stable dt = {dt:.3f} s")\nassert dt_max["implicitfast"] >= dt_max["RK4"] > dt_max["Euler, EULERDAMP off"]\nassert dt_max["Euler"] > dt_max["Euler, EULERDAMP off"]\nprint("ordering OK")'

ENERGY_PLOT = """# Interactive energy plot: uses `energy` and DT/EVERY from Example 13.3 (run it first).
%matplotlib inline
import matplotlib.pyplot as plt
import numpy as np

def plot_energy(Euler=True, RK4=True, implicit=True, implicitfast=False):
    show = dict(Euler=Euler, RK4=RK4, implicit=implicit, implicitfast=implicitfast)
    t = np.arange(len(energy["Euler"])) * DT * EVERY
    plt.figure(figsize=(7, 3.5))
    for name, e in energy.items():
        if show[name]:
            plt.plot(t, e, label=name, ls="--" if name == "implicitfast" else "-")
    plt.xlabel("time [s]"); plt.ylabel("total energy [J]"); plt.legend(); plt.grid(alpha=.3)
    plt.show()

try:
    from ipywidgets import interact
    interact(plot_energy)
except ImportError:
    plot_energy()
"""

SHOW_PNG = """# Log-log plot of the errors left behind by Example 13.9 (DTS and errors).
%matplotlib inline
import matplotlib.pyplot as plt

fig, ax = plt.subplots(figsize=(5, 4))
for name, err in errors.items():
    ax.loglog(DTS, err, marker="o", label=name, ls="--" if name == "implicitfast" else "-")
ax.loglog(DTS, 3 * DTS, "k:", label="slope 1")
ax.loglog(DTS, 0.3 * DTS ** 4, "k--", label="slope 4")
ax.set_xlabel("timestep dt [s]"); ax.set_ylabel("max |qpos - reference| at t = 1 s")
ax.legend(); plt.show()
"""

CELLS = [
    ["md", "Every code cell below is the same file as the matching block on the chapter page "
           "(`examples/13-integrators/`). Budgets grow automatically on a GPU (`ON_GPU`); on a CPU they "
           "stay small. Timings printed here are **your** numbers, and CPU numbers are never GPU numbers.\n\n"
           "The examples run in numeric order. The page shows them where each concept is taught."],
    ["md", "## 1. One step = forward + integrate\n`step` runs `forward`, then dispatches on the Python int "
           "`m.opt.integrator`: `euler`, `rungekutta4`, `implicit` (IMPLICIT and IMPLICITFAST) or `discrete`. "
           "All of them finish in `_advance`: activation, **velocity first**, then position with the new "
           "velocity (semi-implicit), plastic updates, history, time + overflow bits, warm start.\n\n"
           "Two ways to choose the integrator: MJCF `<option integrator=...>` or `m.opt.integrator = "
           "mjw.IntegratorType.X`. After switching, **recapture any CUDA graph**."],
    ["example", "ex1_switch.py", "13.1"],
    ["md", "## 2. Parity with MuJoCo C\nEach integrator should follow `mujoco.mj_step` with the same "
           "integrator to float32 accuracy (about 1e-6), with and without damping."],
    ["example", "ex2_parity.py", "13.2"],
    ["md", "## 3. The energy race\nUndamped double pendulum, q = (1.2, 0), dt = 0.02, 6 s. Euler gains "
           "energy, IMPLICIT loses some (implicit treatment of Coriolis forces is dissipative), RK4 holds it, "
           "IMPLICITFAST equals Euler because no smooth force depends on velocity (D = 0). The example calls "
           "`mjw.forward` before each sample because RK4 leaves `d.energy` from its last stage."],
    ["example", "ex3_energy_race.py", "13.3"],
    ["code", ENERGY_PLOT],
    ["md", "## 4. Implicit damping\nEuler solves `(M + h B) qacc = M qacc_forward` unless EULERDAMP (or "
           "DAMPER) is disabled. Explicit damping multiplies v by `1 - h b/m` per step (unstable above 2); "
           "implicit damping by `1 / (1 + h b/m)` (always stable). Eight worlds, eight dampings, one launch. "
           "The last line shows a 4.0.1 pitfall: with `njmax=0`, `d.efc.Ma` is never filled and the "
           "damping solve returns zero acceleration."],
    ["example", "ex4_damping_stability.py", "13.4"],
    ["md", "## 5. What a step costs\nHumanoid, all four standard integrators, after a warm-up step. RK4 "
           "costs about four forwards. The last lines compute the scratch memory IMPLICIT's RNE derivative "
           "allocates per step."],
    ["example", "ex5_cost_table.py", "13.5"],
    ["md", "## 6. RK4 and sensors\nStages 2-4 call `_forward(skip_sensor=True)`, so `sensordata` keeps the "
           "start-of-step values; `energy` comes from the last stage. C MuJoCo agrees."],
    ["example", "ex6_rk4_sensors.py", "13.6"],
    ["md", "## 7. The IMPLICITFAST matrix\n`mjw.deriv_smooth_vel(m, d, out)` writes `M - dt*D` in M's sparse "
           "layout (`m.nC` values per world). Densify with `mujoco.mju_sym2dense` and compare with a float64 "
           "finite-difference reference."],
    ["example", "ex7_deriv_smooth_vel.py", "13.7"],
    ["md", "## 8. step2 with RK4 runs Euler\n`step2` ends with `# note: RK4 defaults to Euler`. Keep RK4 "
           "and use `m.callback.control` if you need code inside the step. Under RK4 the callback runs at each "
           "of the 4 stage states and stages 2-4 skip sensors, so keep it a cheap, side-effect-free function "
           "of the state."],
    ["example", "ex8_step2_rk4.py", "13.8"],
    ["md", "## 9. Convergence study in one launch\n`m.opt.timestep` is batched: one timestep per world. "
           "Errors at t = 1 s against a float64 RK4 reference give the order of each method, and the float32 "
           "floor of RK4. This cell takes about a minute on CPU."],
    ["example", "ex9_dt_sweep.py", "13.9"],
    ["code", SHOW_PNG],
    ["md", "## Exercise 13.1: measure the order of RK4\nUses `DTS` and `errors` from Example 13.9. Fit the "
           "slope of log(error) against log(dt) above the float32 floor."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL + "\n\n\np_rk4, p_euler = fit_order(DTS, errors[\"RK4\"]), fit_order(DTS, errors[\"Euler\"])\n"
                 "print(f\"order: RK4 {p_rk4:.2f}, Euler {p_euler:.2f}\")\nassert p_rk4 > 3\nassert 0.8 < p_euler < 1.3",
     "Exercise 13.1"],
    ["md", "## 10. Quaternion integration\n`_next_position` rotates free and ball joints with "
           "`math.quat_integrate` (an exact rotation per step). The naive add-and-renormalize update drifts "
           "with h^3 per step."],
    ["example", "ex10_quat_integrate.py", "13.10"],
    ["md", "## Exercise 13.2: largest stable timestep per integrator\nA very stiff damper on the cartpole's "
           "cart; twelve timesteps in one launch per case. Predict first: explicit damping is stable for "
           "h < 2m/b with m = 1.1 kg; RK4's real stability interval ends near -2.785."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 13.2"],
    ["md", "## Stretch: semi-implicit Euler for a free body, by hand\nTake the cube of Example 13.10, switch "
           "gravity on and add a linear velocity. Each step: `mjw.forward`, read `d.qacc`, update `qvel` first, "
           "then the position with the new linear velocity and the quaternion with the exact exponential of the "
           "new body-frame angular velocity. Compare with `mjw.step` (EULERDAMP disabled or no damping)."],
    ["code", "# your hand-written integrator here\n"],
]
