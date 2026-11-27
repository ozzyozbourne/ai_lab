"""Example 17.5 - EPA in 2D (NumPy), starting from the triangle GJK ended with.

GJK only says "the origin is inside A - B". EPA (collision_gjk.py::_epa) recovers HOW deep:
it grows a polytope inside A - B until its face closest to the origin lies on the boundary.
Each iteration: take the closest face (lower bound on the depth), get the support point w along
its normal (upper bound = dot(n, w)), stop when upper - lower < eps; otherwise delete every face
that w can see, keep the horizon (in 2D: the two end vertices of the deleted chain) and attach
new faces from w to the horizon. Prints depth and normal per iteration and checks the result
against a brute-force separating-axis search.
Run: python ex5_epa_2d.py [--dump-json PATH]
  --dump-json PATH writes the polytope per iteration for the page's 2-D EPA stepper.
"""
import argparse
import json

import numpy as np

np.set_printoptions(precision=4, suppress=True)
parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()


def cross2(a, b):
    return a[0] * b[1] - a[1] * b[0]


def support_poly(verts, dir):
    return verts[np.argmax(verts @ dir)]


def mink_support(A, B, dir):
    return support_poly(A, dir) - support_poly(B, -dir)          # support of A - B along dir


def gjk_triangle(A, B, iterations=20):
    """Compact 2D GJK (Example 17.3) that returns the final simplex when it encloses 0."""
    x = A.mean(0) - B.mean(0)
    simplex = []
    for _ in range(iterations):
        s = mink_support(A, B, -x / np.linalg.norm(x))
        if x @ (x - s) < 1e-12:
            return None                                          # converged: separated
        simplex.append(s)
        if len(simplex) == 3:
            P = np.array(simplex)
            area = [cross2(P[(i + 1) % 3] - P[i], -P[i]) for i in range(3)]
            if np.all(np.sign(area) == np.sign(area[0])):
                return P                                         # origin inside
        # keep the closest feature to the origin (brute force is fine for a teaching code)
        best = None
        for idx in ([0], [1], [2], [0, 1], [0, 2], [1, 2]):
            if max(idx) >= len(simplex):
                continue
            pts = [simplex[i] for i in idx]
            if len(pts) == 1:
                q = pts[0]
            else:
                e = pts[1] - pts[0]
                q = pts[0] + np.clip(-(pts[0] @ e) / (e @ e), 0, 1) * e
            if best is None or q @ q < best[0] - 1e-15:
                best = (q @ q, idx, q)
        simplex = [simplex[i] for i in best[1]]
        x = best[2]
    return None


def edge_info(p, q, center):
    """Outward unit normal of edge pq and the origin's distance to its line (face_pr)."""
    e = q - p
    n = np.array([e[1], -e[0]])
    n /= np.linalg.norm(n)
    if n @ (p - center) < 0:
        n = -n
    return n, float(n @ p)                                       # outward normal, distance


def epa2d(A, B, P, iterations=35, tol=1e-6):
    center = P.mean(0)
    verts = [v for v in P]
    if cross2(verts[1] - verts[0], verts[2] - verts[0]) < 0:
        verts = verts[::-1]                                      # keep the polygon ccw
    upper, log = np.inf, []
    for k in range(iterations):
        faces = [(i, (i + 1) % len(verts)) for i in range(len(verts))]
        info = [edge_info(verts[i], verts[j], center) for i, j in faces]
        idx = int(np.argmin([dist for _, dist in info]))        # closest face: lower bound
        n, lower = info[idx]
        w = mink_support(A, B, n)
        upper = min(upper, float(n @ w))                         # upper bound on the depth
        entry = {"k": k, "verts": [v.round(4).tolist() for v in verts], "face": idx,
                 "lower": round(lower, 5), "upper": round(upper, 5), "n": n.round(4).tolist(),
                 "w": w.round(4).tolist()}
        if upper - lower < tol:
            entry["event"] = "converged"
            log.append(entry)
            return lower, n, log
        # delete every face that w can see; the horizon is where visible meets hidden
        visible = [f for f, (nf, df) in enumerate(info) if nf @ w - df > 1e-10]
        entry["visible"], entry["event"] = visible, "expand"
        log.append(entry)
        nf = len(faces)
        first = [f for f in visible if (f - 1) % nf not in visible][0]  # chain is contiguous
        start = faces[first][0]                                  # horizon vertex 1
        end = faces[(first + len(visible) - 1) % nf][1]          # horizon vertex 2
        new = [verts[start], w]
        i = end
        while i != start:                                        # keep the hidden chain
            new.append(verts[i])
            i = (i + 1) % len(verts)
        verts = new
    return lower, n, log


def sat_depth(A, B):
    """Brute force: the smallest overlap over all edge normals of both polygons."""
    best = (np.inf, None)
    for P in (A, B):
        for i in range(len(P)):
            e = P[(i + 1) % len(P)] - P[i]
            n = np.array([e[1], -e[0]]) / np.linalg.norm(e)
            overlap = min((A @ n).max() - (B @ n).min(), (B @ n).max() - (A @ n).min())
            if overlap < best[0]:
                best = (overlap, n)
    return best[0]


A = np.array([[0.0, 0.0], [1.0, -0.3], [1.6, 0.4], [1.0, 1.1], [0.1, 0.9]])
B0 = np.array([[0.0, 0.0], [0.9, 0.1], [1.0, 0.8], [0.2, 0.9]])
t = np.radians(35.0)
B0 = B0 @ np.array([[np.cos(t), -np.sin(t)], [np.sin(t), np.cos(t)]]).T
dump = {"A": A.tolist(), "cases": {}}
for name, off in [("shallow", [1.8, -0.6]), ("deep", [1.2, -0.2])]:
    B = B0 + off
    P = gjk_triangle(A, B)
    depth, n, log = epa2d(A, B, P)
    print(f"--- {name}: GJK triangle {P.round(3).tolist()}")
    for e in log:
        print(f"  k={e['k']}  nvert={len(e['verts'])}  lower={e['lower']:.5f}  "
              f"upper={e['upper']:.5f}  n={e['n']}  {e['event']}"
              + (f" (deleted faces {e['visible']})" if e["event"] == "expand" else ""))
    print(f"  EPA depth = {depth:.5f}  normal = {n.round(4)}   brute-force SAT depth = "
          f"{sat_depth(A, B):.5f}")
    dump["cases"][name] = {"B": B.round(4).tolist(), "depth": round(depth, 5), "log": log}

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
