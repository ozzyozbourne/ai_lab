"""Example 17.3 - GJK in 2D (NumPy), shaped like collision_gjk.py::gjk.

The loop is the same as MJWarp's: start from x_k = c1 - c2, take the support point of the
Minkowski difference A - B along -x_k, stop on the Frank-Wolfe duality gap, run the
distance sub-algorithm (_S1D for a segment, a 2D _S2D for a triangle) to get barycentric
weights, drop the vertices whose weight is 0, and stop when the simplex is "full" (a triangle
in 2D, a tetrahedron in 3D) because then the origin is inside A - B: the shapes overlap.
Prints the simplex per iteration for a separated and an overlapping pair of polygons and checks
the distance against brute force.
Run: python ex3_gjk_2d.py [--dump-json PATH]
  --dump-json PATH writes polygons and per-iteration simplices for the page's GJK canvas.
"""
import argparse
import json

import numpy as np

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()


def support_poly(verts, dir):
    """Support of a convex polygon: the vertex with the largest dot(v, dir) (like a mesh)."""
    return verts[np.argmax(verts @ dir)]


def s1d(s1, s2):
    """Mirror of _S1D: weights of the origin's projection onto segment s1-s2."""
    diff = s2 - s1
    p_o = s2 - (s2 @ diff) / (diff @ diff) * diff        # _project_origin_line
    index = int(np.argmax(np.abs(s1 - s2)))              # axis with the largest shadow
    mu_max = s1[index] - s2[index]
    c1, c2 = p_o[index] - s2[index], s1[index] - p_o[index]
    if np.sign(mu_max) == np.sign(c1) == np.sign(c2) and c1 != 0 and c2 != 0:
        return np.array([c1 / mu_max, c2 / mu_max])
    return np.array([0.0, 1.0])                          # outside: keep the newer vertex


def cross2(a, b):
    return a[0] * b[1] - a[1] * b[0]


def s2d(s1, s2, s3):
    """2D analogue of _S2D: signed areas; inside -> weights, else the best edge via s1d."""
    m = cross2(s2 - s1, s3 - s1)                         # twice the signed area
    c = np.array([cross2(s2, s3), cross2(s3, s1), cross2(s1, s2)])   # areas with origin
    if np.all(np.sign(c) == np.sign(m)) and m != 0:
        return c / m, True                               # origin inside the triangle
    best, lam = np.inf, None
    for i, (a, b) in enumerate([(1, 2), (0, 2), (0, 1)]):
        if np.sign(c[i]) == np.sign(m):
            continue                                     # origin is on the inner side
        sub = s1d([s1, s2, s3][a], [s1, s2, s3][b])
        x = sub[0] * [s1, s2, s3][a] + sub[1] * [s1, s2, s3][b]
        if x @ x < best:
            best, lam = x @ x, np.zeros(3)
            lam[a], lam[b] = sub
    return lam, False


def gjk2d(A, B, iterations=20, tol=1e-6):
    """Returns (dist, overlap, log). log has one entry per iteration."""
    x_k = A.mean(0) - B.mean(0)                          # x1_0 - x2_0 (centres)
    simplex, log = [], []
    eps = 0.5 * tol * tol
    for k in range(iterations):
        xnorm = np.linalg.norm(x_k)
        if xnorm < tol:
            break
        d = x_k / xnorm
        s = support_poly(A, -d) - support_poly(B, d)     # support of A - B along -x_k
        gap = x_k @ (x_k - s)                            # Frank-Wolfe duality gap
        if gap < eps:
            log.append({"k": k, "x": x_k.tolist(), "s": s.tolist(), "gap": gap,
                        "simplex": [p.tolist() for p in simplex], "event": "gap"})
            break
        simplex.append(s)
        if len(simplex) == 1:
            lam, inside = np.array([1.0]), False
        elif len(simplex) == 2:
            lam, inside = s1d(*simplex), False
        else:
            lam, inside = s2d(*simplex)
        keep = [i for i in range(len(simplex)) if lam[i] != 0.0]
        simplex = [simplex[i] for i in keep]
        lam = lam[keep]
        x_k = sum(l * p for l, p in zip(lam, simplex))
        log.append({"k": k, "x": x_k.tolist(), "s": s.tolist(), "gap": gap,
                    "simplex": [p.tolist() for p in simplex],
                    "event": "full" if inside else "reduce"})
        if inside:                                       # 2D "tetrahedron": origin enclosed
            return 0.0, True, log
    return float(np.linalg.norm(x_k)), False, log


def brute_distance(A, B):
    def pt_seg(p, a, b):
        t = np.clip((p - a) @ (b - a) / ((b - a) @ (b - a)), 0, 1)
        return np.linalg.norm(p - (a + t * (b - a)))
    best = np.inf
    for P, Q in [(A, B), (B, A)]:
        for p in P:
            for i in range(len(Q)):
                best = min(best, pt_seg(p, Q[i], Q[(i + 1) % len(Q)]))
    return best


A = np.array([[0.0, 0.0], [1.0, -0.3], [1.6, 0.4], [1.0, 1.1], [0.1, 0.9]])
B0 = np.array([[0.0, 0.0], [0.9, 0.1], [1.0, 0.8], [0.2, 0.9]])
t = np.radians(35.0)
B0 = B0 @ np.array([[np.cos(t), -np.sin(t)], [np.sin(t), np.cos(t)]]).T   # B turned by 35 deg
cases = {"separated": B0 + [1.9, 0.9], "overlapping": B0 + [1.8, -0.6]}
dump = {"A": A.tolist(), "cases": {}}
for name, B in cases.items():
    dist, overlap, log = gjk2d(A, B)
    print(f"--- {name}")
    for e in log:
        simp = " ".join(f"({p[0]:.3f},{p[1]:.3f})" for p in e["simplex"])
        print(f"  k={e['k']}  {e['event']:6s}  n={len(e['simplex'])}  "
              f"|x|={np.linalg.norm(e['x']):.4f}  gap={e['gap']:.4f}  simplex: {simp}")
    print(f"  GJK distance = {dist:.4f}  overlap = {overlap}  brute force = "
          f"{0.0 if overlap else brute_distance(A, B):.4f}")
    dump["cases"][name] = {"B": B.tolist(), "dist": dist, "overlap": overlap,
                           "log": [{**e, "gap": round(e["gap"], 5)} for e in log]}

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
