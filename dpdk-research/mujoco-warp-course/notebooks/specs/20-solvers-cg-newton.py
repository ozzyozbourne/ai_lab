# Notebook spec for Ch 20. Build with:
#   python3 tools/make_notebook.py notebooks/specs/20-solvers-cg-newton.py
SLUG = "20-solvers-cg-newton"
TITLE = "Ch 20 · The Primal Solvers: CG, Newton and the Exact Linesearch"

EX1_STUB = 'import mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\nGRASP = """\n<mujoco model="stiff_grasp">\n  <option timestep="0.005"/>\n  <default><geom solref="0.004 1" friction="1.5"/></default>\n  <worldbody>\n    <geom name="floor" type="plane" size="2 2 .1"/>\n    <body name="left" pos="-0.16 0 0.3">\n      <joint name="lx" type="slide" axis="1 0 0"/>\n      <geom type="box" size=".05 .1 .1" mass="1"/>\n    </body>\n    <body name="right" pos="0.16 0 0.3">\n      <joint name="rx" type="slide" axis="1 0 0"/>\n      <geom type="box" size=".05 .1 .1" mass="1"/>\n    </body>\n    <body name="obj" pos="0 0 0.3">\n      <freejoint/>\n      <geom type="box" size=".1 .08 .08" mass="0.5"/>\n    </body>\n  </worldbody>\n  <actuator>\n    <position joint="lx" kp="2000" ctrlrange="-1 1"/>\n    <position joint="rx" kp="2000" ctrlrange="-1 1"/>\n  </actuator>\n</mujoco>\n"""\n\n\ndef run(solver, cone, iterations, tolerance, nworld=4, nstep=60):\n    """Squeeze a kicked box between two stiff pads; return mean niter, ITERATIONS bit, box z."""\n    mjm = mujoco.MjModel.from_xml_string(GRASP)\n    mjm.opt.solver, mjm.opt.cone = solver, cone\n    mjm.opt.iterations, mjm.opt.tolerance = iterations, tolerance\n    m = mjw.put_model(mjm)\n    m.opt.warn_overflow = 0\n    d = mjw.make_data(mjm, nworld=nworld, nconmax=16, njmax=64)\n    d.ctrl.assign(np.tile([0.02, -0.02], (nworld, 1)))         # pads press inwards\n    qvel = np.zeros((nworld, mjm.nv), np.float32)\n    qvel[:, 2:] = np.random.default_rng(0).normal(0, 1.0, (nworld, 6))   # kick the box\n    d.qvel.assign(qvel)\n    niter = []\n    for _ in range(nstep):\n        mjw.step(m, d)\n        niter.append(d.solver_niter.numpy().copy())\n    it_bit = bool((d.overflow.numpy() & mjw.OverflowType.ITERATIONS).any())\n    return float(np.mean(niter)), it_bit, d.qpos.numpy()[:, 4]\n\n\n# baseline: CG capped at 20 iterations\nprint("baseline:", run(mujoco.mjtSolver.mjSOL_CG, mujoco.mjtCone.mjCONE_PYRAMIDAL, 20, 1e-8))\nsettings = dict(solver=..., cone=..., iterations=..., tolerance=...)   # your choice\nmean_niter, it_bit, z = run(**settings)\nprint(f"mean niter {mean_niter:.2f}, ITERATIONS bit {it_bit}, box z {np.round(z, 3)}")\nassert mean_niter < 10 and not it_bit and (z > 0.25).all()\nprint("grasp solved")\n'
EX1_SOL = 'settings = dict(solver=mujoco.mjtSolver.mjSOL_NEWTON, cone=mujoco.mjtCone.mjCONE_PYRAMIDAL,\n                iterations=100, tolerance=1e-8)\nmean_niter, it_bit, z = run(**settings)\nprint(f"mean niter {mean_niter:.2f}, ITERATIONS bit {it_bit}, box z {np.round(z, 3)}")\nassert mean_niter < 10 and not it_bit and (z > 0.25).all()\nprint("grasp solved")\n'
EX2_STUB = '# Uses cost_grad, exact_linesearch and box_stack from Example 20.5 (run that cell first).\nimport mujoco\nimport numpy as np\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\n\n\ndef newton(P, tol=1e-10, maxiter=30):\n    a = P["a0"].copy()\n    for _ in range(maxiter):\n        ...   # H, search, linesearch, update a, stop test\n    return a\n\n\nmjm = mujoco.MjModel.from_xml_string(box_stack(3))\nm = mjw.put_model(mjm)\nm.opt.disableflags |= mjw.DisableBit.WARMSTART\nd = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)\nfor _ in range(20):\n    mjw.step(m, d)\nmjw.forward(m, d)\nmjd = mujoco.MjData(mjm)\nmjw.get_data_into(mjd, mjm, d)\nM = np.zeros((mjm.nv, mjm.nv))\nmujoco.mj_fullM(mjm, mjd, M)\nn = int(d.nefc.numpy()[0])\nP = {"M": M, "J": d.efc.J.numpy()[0, :n, :mjm.nv].astype(np.float64),\n     "D": d.efc.D.numpy()[0, :n].astype(np.float64),\n     "aref": d.efc.aref.numpy()[0, :n].astype(np.float64),\n     "a0": d.qacc_smooth.numpy()[0].astype(np.float64)}\na = newton(P)\nerr = np.abs(a - d.qacc.numpy()[0]).max()\nprint(f"nefc {n}, max |a_numpy - d.qacc| = {err:.2e}")\nassert err < 1e-4\nprint("NumPy Newton matches MJWarp")\n'
EX2_SOL = 'def newton(P, tol=1e-10, maxiter=30):\n    a = P["a0"].copy()\n    for _ in range(maxiter):\n        c, g, act = cost_grad(a, P)\n        H = P["M"] + P["J"].T @ (P["D"][:, None] * act[:, None] * P["J"])\n        s = -np.linalg.solve(H, g)\n        t, _ = exact_linesearch(a, s, P)\n        a = a + t * s\n        if np.linalg.norm(cost_grad(a, P)[1]) / np.trace(P["M"]) < tol:\n            break\n    return a\n\n\na = newton(P)\nerr = np.abs(a - d.qacc.numpy()[0]).max()\nprint(f"nefc {n}, max |a_numpy - d.qacc| = {err:.2e}")\nassert err < 1e-4\nprint("NumPy Newton matches MJWarp")\n'
EX3_STUB = 'import mujoco\nimport warp as wp\nwp.config.log_level = wp.LOG_WARNING\nimport mujoco_warp as mjw\nfrom mujoco_warp._src import solver, types   # private API: the thresholds\n\n\ndef cholesky_path(nv):\n    ...   # "one tile", "blocked" or "sparse tiles"\n\n\ndef nv_pad(nv):\n    ...   # Newton: multiple of 4 up to 48, else round_up(nv + 1, 16)\n\n\ndef h_bytes(nv, nworld):\n    return nworld * nv_pad(nv) ** 2 * 4\n\n\nassert [cholesky_path(n) for n in (13, 48, 49, 96, 97)] == \\\n    ["one tile", "one tile", "blocked", "blocked", "sparse tiles"]\nfor n_boxes in (2, 5, 10):                       # nv 12, 30, 60\n    xml = "".join(f\'<body pos="0 0 {0.3 * i + 0.2}"><freejoint/><geom type="box" size=".1 .1 .1"/></body>\'\n                  for i in range(n_boxes))\n    mjm = mujoco.MjModel.from_xml_string(f"<mujoco><worldbody>{xml}</worldbody></mujoco>")\n    assert mjw.put_model(mjm).nv_pad == nv_pad(mjm.nv), mjm.nv\nprint("humanoid-sized H (nv 27) in 8192 worlds:", h_bytes(27, 8192) / 2**20, "MiB")\n'
EX3_SOL = 'def cholesky_path(nv):\n    if nv <= types.H_ONE_TILE_MAX:\n        return "one tile"\n    if nv <= solver._SPARSE_BLOCK_CHOLESKY_DIM:\n        return "blocked"\n    return "sparse tiles"\n\n\ndef nv_pad(nv):\n    if nv <= types.H_ONE_TILE_MAX:\n        return -(-nv // 4) * 4\n    return -(-(nv + 1) // 16) * 16\n\n\ndef h_bytes(nv, nworld):\n    return nworld * nv_pad(nv) ** 2 * 4\n\n\nassert [cholesky_path(n) for n in (13, 48, 49, 96, 97)] == ["one tile", "one tile", "blocked", "blocked", "sparse tiles"]\nfor n_boxes in (2, 5, 10):                       # nv 12, 30, 60\n    xml = "".join(f\'<body pos="0 0 {0.3 * i + 0.2}"><freejoint/><geom type="box" size=".1 .1 .1"/></body>\'\n                  for i in range(n_boxes))\n    mjm = mujoco.MjModel.from_xml_string(f"<mujoco><worldbody>{xml}</worldbody></mujoco>")\n    assert mjw.put_model(mjm).nv_pad == nv_pad(mjm.nv), mjm.nv\nprint("humanoid-sized H (nv 27) in 8192 worlds:", h_bytes(27, 8192) / 2**20, "MiB")\n'

CONV_PLOT = """# Convergence plot from Example 20.4 (run it first: it defines `log`, `hist` and TOL).
%matplotlib inline
import matplotlib.pyplot as plt
import numpy as np

fig, ax = plt.subplots(1, 2, figsize=(11, 3.6))
for name, color in (("cg", "C0"), ("newton", "C1")):
    rows = log[name]["rows"]
    k = [r["k"] for r in rows]
    ax[0].semilogy(k, [r["grad"] for r in rows], "o-", color=color, ms=3, label=name)
    imp = [(r["k"], r["improvement"]) for r in rows if r["improvement"] > 0]
    ax[0].semilogy([a for a, _ in imp], [b for _, b in imp], "--", color=color, alpha=.6)
ax[0].axhline(TOL, color="red", ls=":", label="tolerance")
ax[0].set_xlabel("iteration k"); ax[0].set_ylabel("scaled gradient (solid), improvement (dashed)")
ax[0].legend(); ax[0].grid(alpha=.3)
for name, color in (("newton", "C1"), ("cg", "C0")):
    ax[1].hist(hist[name], bins=np.arange(0, max(hist[name]) + 2) - 0.5, color=color, alpha=.7, label=name)
ax[1].set_xlabel("solver_niter"); ax[1].set_ylabel("worlds"); ax[1].legend()
plt.tight_layout(); plt.show()
"""

LS_PLOT = """# Ray cost from Example 20.6 (run it first: it defines phi, kinks, t_exact, alpha_mjw).
%matplotlib inline
import matplotlib.pyplot as plt
import numpy as np

ts = np.linspace(0.0, 1.6 * t_exact, 400)
plt.figure(figsize=(7, 3.5))
plt.plot(ts, [phi(t)[0] for t in ts], label="phi(alpha)")
for k in kinks[kinks < ts[-1]]:
    plt.axvline(k, color="orange", lw=.8, ls=":")
plt.axvline(alpha_mjw, color="green", label="MJWarp alpha")
plt.xlabel("alpha"); plt.ylabel("cost change"); plt.legend(); plt.grid(alpha=.3); plt.show()
"""

CELLS = [
    ["md", "Every code cell below is the same file as the matching block on the chapter page "
           "(`examples/20-solvers-cg-newton/`). Budgets switch on `ON_GPU`: the same cell runs small on a CPU "
           "and big on a Colab GPU. CPU timings say nothing about GPU performance: read your own numbers."],
    ["md", "## 1-3. The problem, the solve flow and the gradient\nThe solver minimizes "
           "`f(a) = 0.5 (a - a0)' M (a - a0) + sum_i s_i(J_i a - aref_i)` over `a = qacc`. "
           "`_solve`: `_solve_init_dof` (warmstart or qacc_smooth), `init_context` (inertia_scale, Jaref, Ma, "
           "states), the first gradient `grad = Ma - qfrc_smooth - qfrc_constraint`, CG's first search, then "
           "`wp.capture_while(nsolving, _solver_iteration)`."],
    ["md", "## 4. One iteration on a 2-dof toy\nA NumPy teaching solver with MJWarp's two recipes (Newton with an "
           "exact linesearch; CG with Polak-Ribiere beta >= 0). No MJWarp call."],
    ["example", "ex5b_toy_2dof.py", "20.5b"],
    ["md", "The same Newton in float64 on the problem MJWarp built for one world of a kicked `box_stack(5)`. "
           "Costs agree to 1e-8; qacc can differ by ~1e-3 because the cost is flat in some directions."],
    ["example", "ex5_numpy_newton.py", "20.5"],
    ["md", "## 5. CG vs Newton\nIteration counts per world for the four (solver, cone) pairs. "
           "solver and cone are compile-time choices: each pair compiles its kernels once (slow on CPU)."],
    ["example", "ex1_niter.py", "20.1"],
    ["md", "## 6. Newton's Cholesky paths\nnv <= 48: one tile; 49..96: blocked 16x16 tiles; > 96: sparse tiles. "
           "Timing is printed on a GPU only."],
    ["example", "ex11_cholesky_path.py", "20.11"],
    ["md", "## 7. State flips and the incremental Hessian\nRerun one cold-started Newton solve with "
           "iterations = 0, 1, 2, ... and count rows that changed ConstraintState. Pyramidal Newton turns each "
           "QUADRATIC flip into one rank-1 update of H."],
    ["example", "ex12_state_flips.py", "20.12"],
    ["md", "## 8. The exact linesearch\nThe ray cost along MJWarp's first CG direction, its kinks, the exact "
           "minimizer, a NumPy replay of `_linesearch_iterative_kernel` (Newton probe from 0, then three probes "
           "per round) and the alpha MJWarp took."],
    ["example", "ex6_linesearch_plot.py", "20.6"],
    ["code", LS_PLOT],
    ["md", "## 9. Termination\nLog one cold-started solve per iteration and check which `_solve_done` test fires "
           "(alpha == 0, improvement, gradient, Newton's model improvement), then the per-world niter of 64 worlds."],
    ["example", "ex4_convergence_log.py", "20.4"],
    ["code", CONV_PLOT],
    ["md", "`m.opt.tolerance` is per world (`tolerance[worldid % len]`). put_model clamps the MJCF value to >= 1e-6; "
           "assigning an array afterwards bypasses the clamp."],
    ["example", "ex2_tolerance_per_world.py", "20.2"],
    ["md", "A capped CG returns a wrong qacc and sets ITERATIONS; `ls_iterations` is a compile-time constant "
           "(this cell recompiles the linesearch) and LS_ITERATIONS is bit 1 << 10. The kernel printf appears "
           "in the cell output."],
    ["example", "ex3_iteration_cap.py", "20.3"],
    ["md", "## 10. Knobs and their cost\nEager step time for iterations {1, 5, 20, 50} x ls_iterations {5, 20}. "
           "On a GPU, run this and read your own numbers."],
    ["example", "ex10_solver_timing.py", "20.10"],
    ["md", "## 11. Per-world convergence\n`capture_while(nsolving, ...)` runs until the slowest world is done "
           "(see the histogram above). With `graph_conditional=False` a fixed loop of `opt.iterations` runs. "
           "Graph capture itself is Chapter 24."],
    ["md", "## 12. Warmstart and run_qacc_smooth\n`qacc_warmstart` is written by `step` only. 4.0.1 never picks "
           "the better of warmstart and qacc_smooth."],
    ["example", "ex7_warmstart.py", "20.7"],
    ["md", "Experimental: `run_qacc_smooth=False` with Newton skips the M factorization and the qacc_smooth solve."],
    ["example", "ex8_run_qacc_smooth.py", "20.8"],
    ["md", "## 13. noslip\nPGS over the friction rows with the unregularized Delassus operator, after the main "
           "solve. Its sweeps are added to `solver_niter`. Compared with C MuJoCo on the same model."],
    ["example", "ex9_noslip.py", "20.9"],
    ["md", "## Exercise 20.1: settle a stiff grasp\nPick solver, cone, iterations and tolerance so that the mean "
           "niter is below 10, no ITERATIONS bit is set and the box is still held."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 20.1"],
    ["md", "## Exercise 20.2: your Newton matches MJWarp\nUses `cost_grad`, `exact_linesearch` and `box_stack` from "
           "Example 20.5 (run it first). Write the Newton loop and assert max |a - d.qacc| < 1e-4 on box_stack(3)."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 20.2"],
    ["md", "## Exercise 20.3: predict the Cholesky path and the H memory\nWrite `cholesky_path(nv)` and "
           "`nv_pad(nv)` from the rules in section 6 and check them against put_model."],
    ["code", EX3_STUB],
    ["solution", EX3_SOL, "Exercise 20.3"],
    ["md", "## Stretch: Newton for elliptic cones in NumPy\nExtend Example 20.5 to `mjCONE_ELLIPTIC`: group the "
           "rows of each contact, implement the SATISFIED / QUADRATIC / CONE zones of `_eval_constraint`, their "
           "gradient and Hessian block, and a linesearch that handles the cone piece. Compare the final cost "
           "with MJWarp's."],
    ["code", "# your elliptic NumPy Newton here\n"],
]
