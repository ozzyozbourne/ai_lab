"""Example 19.12 - the math toolkit the solver needs, in plain NumPy (no MJWarp).

Part 1: minimize the 2-D SPD quadratic f(x) = 0.5 x^T A x - b^T x three ways:
gradient descent with a fixed step, one Newton step, and two conjugate-gradient steps.
Part 2: a 1-D piecewise quadratic with 3 kinks (the shape of the solver's cost along a search
ray): find its exact minimizer by checking each smooth piece, then by Newton steps that jump
from piece to piece.
Run: python ex12_math_toolkit.py [--dump-json PATH]
  --dump-json PATH writes the iterates and the piecewise curve for the toolkit figure (Rule D).
"""
import argparse
import json

import numpy as np

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

# ---------------- Part 1: a 2-D SPD quadratic ----------------
A = np.array([[4.0, 1.4], [1.4, 1.0]])           # symmetric positive definite
b = np.array([1.0, 2.0])
x0 = np.array([-2.0, -1.0])
x_star = np.linalg.solve(A, b)                     # the unique minimizer: A x = b
lam = np.linalg.eigvalsh(A)
print("eigenvalues of A:", lam, "-> SPD:", bool(lam.min() > 0),
      f"| condition number {lam.max() / lam.min():.1f}")
print("Cholesky factor L (A = L L^T):\n", np.linalg.cholesky(A))
print("x* = A^-1 b =", x_star)


def f(x):
    return 0.5 * x @ A @ x - b @ x


def grad(x):
    return A @ x - b


# gradient descent, fixed step 1/lambda_max (safe for any SPD A)
step = 1.0 / lam.max()
gd = [x0.copy()]
x = x0.copy()
for _ in range(40):
    x = x - step * grad(x)
    gd.append(x.copy())

# Newton: x1 = x0 - H^-1 grad, with H = A: exact in one step for a quadratic
newton = [x0.copy(), x0 - np.linalg.solve(A, grad(x0))]

# conjugate gradient (exact linesearch along A-conjugate directions): exact in n = 2 steps
cg = [x0.copy()]
x = x0.copy()
r = -grad(x)
p = r.copy()
for _ in range(2):
    alpha = (r @ r) / (p @ A @ p)                  # exact 1-D minimizer along p
    x = x + alpha * p
    r_new = r - alpha * (A @ p)
    beta = (r_new @ r_new) / (r @ r)               # Fletcher-Reeves (= every CG on a quadratic)
    p = r_new + beta * p
    r = r_new
    cg.append(x.copy())

for name, path in (("gradient descent", gd), ("Newton", newton), ("CG", cg)):
    errs = [np.linalg.norm(p - x_star) for p in path]
    shown = ", ".join(f"{e:.2e}" for e in errs[:4])
    print(f"{name:17s} {len(path) - 1:2d} steps | |x_k - x*| for k=0..3: {shown}"
          f" | final {errs[-1]:.2e}")
print("GD iterates 1..3:", np.array(gd[1:4]).round(4).tolist())
print(f"f(x*) = {f(x_star):.4f}; every local minimum of a convex f is this global one")

# ---------------- Part 2: a 1-D piecewise quadratic ----------------
# cost(alpha) = 0.5*a*alpha^2 + g*alpha  (the Gauss term along a ray)
#             + sum_i 0.5*D_i*(r_i + j_i*alpha)^2  only where r_i + j_i*alpha < 0 (row active)
a, g = 1.0, -1.0
rows = [(-0.5, 1.0, 4.0),      # (r_i, j_i, D_i): active for alpha < 0.5
        (0.6, -1.0, 3.0),      # active for alpha > 0.6
        (1.5, -1.0, 6.0)]      # active for alpha > 1.5
kinks = sorted(-r / j for r, j, _ in rows)
print("kinks (row switches) at alpha =", [round(k, 3) for k in kinks])


def pq(alpha):
    """Return (cost, slope, curvature) at alpha; the cost is C1, the curvature jumps at kinks."""
    c, s, h = 0.5 * a * alpha**2 + g * alpha, a * alpha + g, a
    for r, j, D in rows:
        x = r + j * alpha
        if x < 0:
            c += 0.5 * D * x * x
            s += D * j * x
            h += D * j * j
    return c, s, h


# exact minimizer: on each smooth piece the cost is one quadratic; take its stationary point
# if it lies inside that piece (convexity guarantees exactly one such point)
edges = [-np.inf] + kinks + [np.inf]
exact = None
for lo, hi in zip(edges[:-1], edges[1:]):
    mid = 0.5 * (max(lo, -10) + min(hi, 10))
    _, s_mid, h_mid = pq(mid)
    cand = mid - s_mid / h_mid                      # Newton is exact inside one piece
    if lo - 1e-12 <= cand <= hi + 1e-12:
        exact = cand
print(f"exact minimizer alpha* = {exact:.6f}, cost {pq(exact)[0]:.6f}, slope {pq(exact)[1]:.1e}")

# Newton steps on the piecewise quadratic: each step is exact for the current piece
alpha = 0.0
newton_1d = [alpha]
for _ in range(8):
    _, s, h = pq(alpha)
    if abs(s) < 1e-12:
        break
    alpha = alpha - s / h
    newton_1d.append(alpha)
print("1-D Newton iterates:", [round(v, 6) for v in newton_1d], f"({len(newton_1d) - 1} steps)")

if args.dump_json:
    grid = np.linspace(-0.5, 2.5, 121)
    curve = [[round(float(t), 4), round(float(pq(t)[0]), 4)] for t in grid]
    out = {"A": A.tolist(), "b": b.tolist(), "x0": x0.tolist(), "xstar": x_star.round(5).tolist(),
           "gd": np.array(gd).round(4).tolist(), "newton": np.array(newton).round(4).tolist(),
           "cg": np.array(cg).round(4).tolist(),
           "pq": {"a": a, "g": g, "rows": rows, "kinks": [round(k, 4) for k in kinks],
                  "exact": round(float(exact), 5), "newton": [round(v, 5) for v in newton_1d],
                  "curve": curve}}
    with open(args.dump_json, "w") as fh:
        json.dump(out, fh, separators=(",", ":"))
    print("wrote", args.dump_json)
