"""Example 20.5b - NumPy teaching solver on a 2-dof toy (drives the solver-iteration stepper).

The Ch 19 cost on a problem small enough to draw: 2 dofs (a = qacc), a 2x2 mass matrix M, the
unconstrained acceleration a0 = qacc_smooth and three pyramidal-style rows (active when
J_i a - aref_i < 0). Both solvers follow MJWarp's 4.0.1 recipe:
  Newton: H = M + J' diag(D active) J, search = -H^-1 grad, exact linesearch
  CG:     Mgrad = M^-1 grad, beta = max(0, grad'(Mgrad - Mgrad_prev) / (grad_prev' Mgrad_prev)),
          search = -Mgrad + beta * search, exact linesearch       (Polak-Ribiere, clamped >= 0)
and stop with the _solve_done tests (scaled by 1/trace(M)). No MJWarp call: pure NumPy.
Run: python ex5b_toy_2dof.py [--dump-json PATH]
"""
import argparse
import json

import numpy as np

M = np.array([[3.0, 1.2], [1.2, 1.0]])
A0 = np.array([-1.0, -3.0])                  # gravity-like pull: where a would go unconstrained
J = np.array([[0.0, 1.0], [0.8, 0.6], [-1.0, 0.25]])
AREF = np.array([0.5, 0.2, 0.6])
D = np.array([4.0, 6.0, 3.0])
TOL = 1e-6


def cost_grad(a):
    jaref = J @ a - AREF
    act = jaref < 0
    da = a - A0
    cost = 0.5 * da @ M @ da + 0.5 * np.sum(D[act] * jaref[act] ** 2)
    grad = M @ da + J.T @ (D * act * jaref)
    return cost, grad, act


def linesearch(a, s):
    """Exact minimizer of the convex piecewise quadratic t -> cost(a + t s)."""
    jaref, jv = J @ a - AREF, J @ s
    with np.errstate(divide="ignore", invalid="ignore"):
        k = np.where(jv != 0, -jaref / jv, np.inf)
    edges = np.concatenate([[0.0], np.sort(k[(k > 0) & np.isfinite(k)]), [np.inf]])
    for lo, hi in zip(edges[:-1], edges[1:]):
        tm = lo + 1.0 if np.isinf(hi) else 0.5 * (lo + hi)
        act = jaref + tm * jv < 0
        g = s @ M @ (a - A0) + np.sum(D[act] * jv[act] * jaref[act])
        h = s @ M @ s + np.sum(D[act] * jv[act] ** 2)
        t = -g / h
        if lo <= t <= hi:
            return t
    return 0.0


def solve(kind, maxiter=20):
    scale = 1.0 / np.trace(M)
    a = A0.copy()
    c, g, act = cost_grad(a)
    mg = np.linalg.solve(M, g)
    s = -mg if kind == "cg" else None
    frames = [{"a": a.tolist(), "cost": c, "alpha": 0.0, "grad": scale * np.linalg.norm(g),
               "active": act.astype(int).tolist(), "line": 1}]
    for it in range(1, maxiter + 1):
        if kind == "newton":
            H = M + J.T @ (D[:, None] * act[:, None] * J)
            s = -np.linalg.solve(H, g)
        t = linesearch(a, s)
        a = a + t * s
        c_new, g_new, act = cost_grad(a)
        improvement = scale * (c - c_new)
        if kind == "cg":
            mg_new = np.linalg.solve(M, g_new)
            beta = max(0.0, g_new @ (mg_new - mg) / max(1e-15, g @ mg))
            s = -mg_new + beta * s
            mg = mg_new
        c, g = c_new, g_new
        gn = scale * np.linalg.norm(g)
        frames.append({"a": a.tolist(), "cost": c, "alpha": t, "grad": gn,
                       "active": act.astype(int).tolist(), "line": 3})
        done = t == 0 or 0 < improvement < TOL or gn < TOL
        if kind == "newton":
            H = M + J.T @ (D[:, None] * act[:, None] * J)
            done = done or 0.5 * scale * g @ np.linalg.solve(H, g) < TOL
        if done:
            break
    return frames


out = {"M": M.tolist(), "a0": A0.tolist(), "J": J.tolist(), "aref": AREF.tolist(),
       "D": D.tolist(), "runs": {}}
for kind in ("newton", "cg"):
    fr = solve(kind)
    out["runs"][kind] = [{k: (np.round(v, 5).tolist() if isinstance(v, (list, np.ndarray))
                              else (round(float(v), 6) if isinstance(v, float) else v))
                          for k, v in f.items()} for f in fr]
    print(f"{kind}: {len(fr) - 1} iterations")
    with np.printoptions(precision=4, suppress=True):   # local: no global print state
        for i, f in enumerate(fr):
            print(f"  {i}: a = {np.array(f['a'])}  cost {f['cost']:9.4f}  alpha {f['alpha']:.4f}  "
                  f"|grad|*scale {f['grad']:.2e}  active rows {f['active']}")

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()
if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
