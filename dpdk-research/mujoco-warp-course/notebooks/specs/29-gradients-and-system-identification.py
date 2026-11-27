# Notebook spec for Chapter 29. Build with:
#   python3 tools/make_notebook.py notebooks/specs/29-gradients-and-system-identification.py
SLUG = "29-gradients-and-system-identification"
TITLE = "Ch 29 · Gradients, Sampling-Based Optimization and Parallel System Identification"

CELLS = [
    ["md", "This notebook holds every example of Chapter 29 in page order. Each cell is the same file as "
           "`examples/29-gradients-and-system-identification/exN_*.py`. On a GPU runtime the scripts pick "
           "the big budgets (NWORLD 1024); on CPU they use small ones. No example needs a helper module.\n\n"
           "Examples 29.2-29.4 use the private module `mujoco_warp._src.diff` (it may change between versions)."],
    ["md", "## 1-2. Reverse mode and `wp.Tape` on a plain kernel\n"
           "Forward under the tape, seed `y.grad = 1`, `tape.backward()`, read `x.grad`. Note that the "
           "backward *consumes* the output cotangent of an overwritten array and *accumulates* into inputs."],
    ["example", "ex1_tape_basics.py", "29.1"],
    ["md", "## 3. MJWarp functions inside a tape (4.0.1)\n"
           "Every public function is wrapped by `diff._wrap`; no rule is registered, so every call inside an "
           "active tape raises `NotImplementedError`. Setup runs before the tape."],
    ["example", "ex2_tape_error.py", "29.2"],
    ["md", "## 4. `register_adjoint` on your own wrapped function\n"
           "A custom backward must `+=` into input gradients and consume the output gradients."],
    ["example", "ex3_register_adjoint.py", "29.3"],
    ["md", "### Rules on Data fields, `supported()`, undeclared fields, native rules"],
    ["example", "ex4_adjoint_fields.py", "29.4"],
    ["md", "## 5. Finite differences across worlds\n"
           "One world per perturbation, all in one batched rollout. Compare epsilons in float32 against a "
           "float64 C MuJoCo reference: too big gives truncation error, too small gives round-off."],
    ["example", "ex5_fd_jacobian.py", "29.5"],
    ["md", "## 6. CEM: iterative sampling-based optimization\n"
           "Snapshot with `State.PHYSICS | TIME` once, restore it every iteration, sample NWORLD plans on the "
           "device, refit a Gaussian to the elites."],
    ["example", "ex6_cem.py", "29.6"],
    ["md", "## 7. Capstone: parallel system identification\n"
           "One world per candidate (damping, mass); batched Model fields plus `mjw.set_const` after each "
           "mass write, eagerly and outside any graph; loss summed on the device; full-covariance CEM."],
    ["example", "ex7_sysid_capstone.py", "29.7"],
    ["md", "### With contacts: identify sliding friction (no `set_const` needed)"],
    ["example", "ex8_sysid_friction.py", "29.8"],
    ["md", "## Exercise 29.1 (auto-checked)\nFD gradient of a ball's landing time with respect to its "
           "drop height, checked against the analytic value."],
    ["code", '# Exercise 29.1 - FD gradient of the landing time w.r.t. the drop height (auto-checked)\n# Drop BALL_DROP from H - EPS and H + EPS in TWO worlds of one batch, find the time at which the\n# ball centre first reaches z = R (interpolate between steps), and form the central difference.\n# Analytic: t = sqrt(2 (H - R) / g), so dt/dH = 1 / sqrt(2 g (H - R)).\nimport mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nH, EPS, R, G = 1.0, 0.05, 0.1, 9.81\ndtdh = ...       # your FD estimate\nanalytic = 1.0 / np.sqrt(2 * G * (H - R))\nif dtdh is ...:\n  print("Exercise 29.1: not attempted")\nelse:\n  assert abs(dtdh - analytic) / analytic < 0.03\n  print("Exercise 29.1: ok")\n'],
    ["solution", 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nBALL_DROP = """\n<mujoco model="ball_drop">\n  <option timestep="0.002"/>\n  <worldbody>\n    <light pos="0 0 3" dir="0 0 -1"/>\n    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>\n    <body name="ball" pos="0 0 1">\n      <freejoint/>\n      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>\n    </body>\n  </worldbody>\n</mujoco>\n"""\nH, EPS, R, G = 1.0, 0.05, 0.1, 9.81\n\n\ndef landing_times(heights):\n    """Time at which the ball centre first reaches z = R, linearly interpolated between steps."""\n    mjm = mujoco.MjModel.from_xml_string(BALL_DROP)\n    m = mjw.put_model(mjm)\n    d = mjw.make_data(mjm, nworld=len(heights), nconmax=4, njmax=16)\n    q = np.tile(mjm.qpos0, (len(heights), 1))\n    q[:, 2] = heights\n    d.qpos.assign(q)\n    dt = mjm.opt.timestep\n    t_land = np.full(len(heights), np.nan)\n    z_prev = np.array(heights, dtype=float)\n    for i in range(1, 400):\n        mjw.step(m, d)\n        z = d.qpos.numpy()[:, 2].copy()   # copy: on CPU .numpy() is a view\n        hit = np.isnan(t_land) & (z <= R)\n        t_land[hit] = (i - 1) * dt + dt * (z_prev[hit] - R) / (z_prev[hit] - z[hit])\n        z_prev = z\n        if not np.isnan(t_land).any():\n            break\n    return t_land\n\n\nt = landing_times([H - EPS, H + EPS])\ndtdh = (t[1] - t[0]) / (2 * EPS)\nanalytic = 1.0 / np.sqrt(2 * G * (H - R))\nprint(f"FD dt/dh = {dtdh:.4f} s/m, analytic = {analytic:.4f} s/m")\nassert abs(dtdh - analytic) / analytic < 0.03\nprint("ok")\n', "Exercise 29.1"],
    ["md", "## Exercise 29.2 (auto-checked)\nA custom adjoint rule for `y = 2x + 1`, checked with `wp.Tape`."],
    ["code", '# Exercise 29.2 - a custom adjoint for y = 2x + 1 (auto-checked)\n# Write affine(m, d, x, y) and affine_bwd(m, d, x, y), wrap with diff._wrap, register with\n# diff.register_adjoint(..., array_args=("x", "y")), run it under wp.Tape, seed y.grad = 1.\nimport mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\nfrom mujoco_warp._src import diff\n\ny = ...  # ... your code: define x and y, run under wp.Tape, call tape.backward() ...\nif y is ...:\n  print("Exercise 29.2: not attempted")\nelse:\n  assert np.allclose(y.numpy(), [1.0, 3.0, -5.0])   # x = [0, 1, -3]\n  assert np.allclose(x.grad.numpy(), 2.0)\n  assert np.allclose(y.grad.numpy(), 0.0)           # the rule consumed the output cotangent\n  print("Exercise 29.2: ok")\n'],
    ["solution", 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\nfrom mujoco_warp._src import diff\n\n\n@wp.kernel(enable_backward=False)\ndef affine_kernel(x: wp.array[float], y_out: wp.array[float]):\n    i = wp.tid()\n    y_out[i] = 2.0 * x[i] + 1.0\n\n\n@wp.kernel(enable_backward=False)\ndef affine_bwd_kernel(y_grad: wp.array[float], x_grad_out: wp.array[float]):\n    i = wp.tid()\n    x_grad_out[i] += 2.0 * y_grad[i]\n\n\ndef affine(m, d, x, y):\n    wp.launch(affine_kernel, dim=x.shape[0], inputs=[x], outputs=[y])\n\n\ndef affine_bwd(m, d, x, y):\n    wp.launch(affine_bwd_kernel, dim=x.shape[0], inputs=[y.grad], outputs=[x.grad])\n    y.grad.zero_()\n\n\nw = diff._wrap(affine)\ndiff.register_adjoint(affine, affine_bwd, array_args=("x", "y"))\nmjm = mujoco.MjModel.from_xml_string("<mujoco><worldbody/></mujoco>")\nm, d = mjw.put_model(mjm), mjw.make_data(mjm)\nx = wp.array([0.0, 1.0, -3.0], dtype=float)\ny = wp.zeros(3, dtype=float)\nwith wp.Tape() as tape:\n    w(m, d, x, y)\ny.grad.fill_(1.0)\ntape.backward()\nprint("y =", y.numpy(), "x.grad =", x.grad.numpy())\nassert np.allclose(y.numpy(), [1.0, 3.0, -5.0])\nassert np.allclose(x.grad.numpy(), 2.0)\nassert np.allclose(y.grad.numpy(), 0.0)\nprint("ok")\ndiff.RULES.pop("affine", None)    # leave the global registry as 4.0.1 ships it\ndiff._PARAMS.pop("affine", None)\n', "Exercise 29.2"],
    ["md", "## Stretch: friction and restitution together\n"
           "Record a box thrown onto a floor in C MuJoCo with hidden sliding friction and a hidden bounce "
           "(use the direct form of `solref`, both numbers negative: `\"-stiffness -damping\"`, e.g. "
           "`solref=\"-5000 -2\"` for stiffness 5000 and a low damping of 2; restitution needs "
           "per-world `geom_solref`). Identify both with a 2-D CEM over one batch per round, as in Example "
           "29.7. Which parameter is better determined, and why? Plot the 2-D loss landscape."],
]
