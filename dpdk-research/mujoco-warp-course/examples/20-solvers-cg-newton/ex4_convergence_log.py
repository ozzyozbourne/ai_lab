"""Example 20.4 - convergence log: scaled gradient norm and improvement per iteration, CG vs Newton.

MJWarp does not expose its solver context, so we rerun ONE solve from the same state with
opt.iterations = 0, 1, 2, ... and rebuild the solver's own quantities in NumPy after each run:
  cost(a)  = 0.5 (a - qacc_smooth)' M (a - qacc_smooth) + sum_active 0.5 D (J a - aref)^2
  grad     = M a - qfrc_smooth - J' force               (scaled by inertia_scale = 1 / trace(M))
  decrement= grad' H^-1 grad with H = M + J' diag(D active) J    (Newton's model improvement)
The solve is cold-started (warmstart off) so that every iteration is visible. Then we mark which
_solve_done test would stop the solver at the default tolerance 1e-6, and finally collect the
per-world solver_niter of a 64-world batch (after 10 ordinary warm-started steps) for the histogram.
Run: python ex4_convergence_log.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

TOL = 1e-6
NWORLD_GRID = 64
mjm = mujoco.MjModel.from_xml_string(box_stack(5))
mjd = mujoco.MjData(mjm)

# one kicked, mid-motion state shared by both solvers
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=32, njmax=128)
d.qvel.assign(np.random.default_rng(1).normal(0.0, 0.1, size=(1, mjm.nv)).astype(np.float32))
for _ in range(20):
    mjw.step(m, d)
state = {k: getattr(d, k).numpy().copy() for k in ("qpos", "qvel", "qacc_warmstart")}


def numpy_metrics(d):
    """Rebuild cost, scaled gradient norm and Newton decrement for world 0."""
    mjw.get_data_into(mjd, mjm, d)
    M = np.zeros((mjm.nv, mjm.nv))
    mujoco.mj_fullM(mjm, mjd, M)
    n = int(d.nefc.numpy()[0])
    J = d.efc.J.numpy()[0, :n, :mjm.nv].astype(np.float64)
    D = d.efc.D.numpy()[0, :n].astype(np.float64)
    aref = d.efc.aref.numpy()[0, :n].astype(np.float64)
    a = d.qacc.numpy()[0].astype(np.float64)
    a0 = d.qacc_smooth.numpy()[0].astype(np.float64)
    jaref = J @ a - aref
    active = jaref < 0.0                     # pyramidal rows: QUADRATIC when J a - aref < 0
    cost = 0.5 * (a - a0) @ M @ (a - a0) + 0.5 * np.sum(D[active] * jaref[active] ** 2)
    force = np.where(active, -D * jaref, 0.0)
    grad = M @ (a - a0) - J.T @ force        # = M a - qfrc_smooth - qfrc_constraint
    H = M + J.T @ (D[:, None] * active[:, None] * J)
    scale = 1.0 / np.trace(M)
    return cost, scale, scale * np.linalg.norm(grad), scale * 0.5 * grad @ np.linalg.solve(H, grad)


log = {}
for solver, kmax in (("CG", 50), ("NEWTON", 6)):
    mjm.opt.solver = getattr(mujoco.mjtSolver, f"mjSOL_{solver}")
    m = mjw.put_model(mjm)
    m.opt.warn_overflow = 0
    m.opt.disableflags |= mjw.DisableBit.WARMSTART
    m.opt.tolerance = wp.array([1e-12], dtype=float)   # never stop early while logging
    rows, prev_cost = [], None
    for k in range(kmax + 1):
        m.opt.iterations = k
        for key, v in state.items():
            getattr(d, key).assign(v)
        mjw.forward(m, d)
        cost, scale, gnorm, dec = numpy_metrics(d)
        impr = 0.0 if prev_cost is None else scale * (prev_cost - cost)
        prev_cost = cost
        rows.append({"k": k, "cost": cost, "grad": gnorm, "improvement": impr, "decrement": dec})

    # which _solve_done test fires first at the default tolerance?
    fired = None
    for r in rows[1:]:
        tests = [("improvement", 0.0 < r["improvement"] < TOL), ("gradient", r["grad"] < TOL)]
        if solver == "NEWTON":
            tests.append(("model improvement (0.5 decrement)", r["decrement"] < TOL))
        hit = [name for name, ok in tests if ok]
        if hit:
            fired = (r["k"], hit)
            break
    m.opt.tolerance = wp.array([TOL], dtype=float)
    m.opt.iterations = 100
    for key, v in state.items():
        getattr(d, key).assign(v)
    mjw.forward(m, d)
    actual = int(d.solver_niter.numpy()[0])

    print(f"\n{solver}: cold start, nefc={int(d.nefc.numpy()[0])}, scale = 1/trace(M) = {scale:.4f}")
    print("  k        cost    log10|grad|s   log10 improvement")
    for r in rows:
        if solver == "CG" and r["k"] > 12 and r["k"] % 4:
            continue                          # print a subset of the long CG log
        li = f"{np.log10(r['improvement']):8.2f}" if r["improvement"] > 0 else "       -"
        print(f"  {r['k']:2d} {r['cost']:12.4f} {np.log10(r['grad']):12.2f}   {li}")
    print(f"  first test to pass at tol={TOL:g}: iteration {fired[0]} -> {', '.join(fired[1])}")
    print(f"  MJWarp solver_niter at tol={TOL:g}: {actual}")
    log[solver.lower()] = {"rows": [{kk: (float(f"{v:.6g}") if kk != "k" else v)
                                     for kk, v in r.items()} for r in rows],
                           "fired": fired[0], "test": fired[1][0], "niter": actual}

# per-world histogram: 64 worlds with their own kicks, after 10 ordinary (warm-started) steps
hist = {}
for solver in ("NEWTON", "CG"):
    mjm.opt.solver = getattr(mujoco.mjtSolver, f"mjSOL_{solver}")
    m = mjw.put_model(mjm)
    dg = mjw.make_data(mjm, nworld=NWORLD_GRID, nconmax=32, njmax=128)
    kicks = np.random.default_rng(2).normal(0.0, 0.5, size=(NWORLD_GRID, mjm.nv))
    dg.qvel.assign(kicks.astype(np.float32))
    for _ in range(10):
        mjw.step(m, dg)
    niter = dg.solver_niter.numpy()
    vals, counts = np.unique(niter, return_counts=True)
    print(f"\n{solver} per-world solver_niter, {NWORLD_GRID} worlds, step 10:")
    print("  niter:", dict(zip(vals.tolist(), counts.tolist())), " max:", int(niter.max()),
          " overflow:", "none" if not dg.overflow.numpy().any() else dg.overflow.numpy())
    hist[solver.lower()] = niter.tolist()

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"tol": TOL, "log": log, "grid": hist}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
