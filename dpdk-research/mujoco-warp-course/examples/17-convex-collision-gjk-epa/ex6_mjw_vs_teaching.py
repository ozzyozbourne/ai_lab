"""Example 17.6 - EPA in 3D (NumPy) vs MJWarp's box-box penetration depth.

The teaching EPA mirrors collision_gjk.py::_epa: faces store the origin's projection onto
their plane (face_pr, pointing outward, see _attach_face) and its squared length (face_norm2);
each iteration picks the closest valid face, adds the support point w along its normal,
deletes every face that w can see, collects the horizon with _add_edge semantics (an edge
added twice is shared by two deleted faces and cancels) and attaches one new face per horizon
edge. GJK (the signed-volume code of Example 17.4) supplies the start tetrahedron, as in
_polytope4. Two axis-aligned boxes overlap by 1 cm; we compare depth and normal with MJWarp.
Run: python ex6_mjw_vs_teaching.py [--dump-json PATH]
  --dump-json PATH writes every EPA iteration for the page's 3-D EPA stepper.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)
parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

# ---- GJK, copied from Example 17.4 (signed-volume sub-algorithm) ----
FLOAT_MAX, MINVAL = 1e30, 1e-15


def det3(a, b, c):
    return a @ np.cross(b, c)


def same_sign(a, b):
    return (a > 0 and b > 0) or (a < 0 and b < 0)


def project_origin_line(v1, v2):
    diff = v2 - v1
    return v2 - (v2 @ diff) / (diff @ diff) * diff


def project_origin_plane(v1, v2, v3):
    for a, b, c in [(v3 - v2, v2 - v1, v2), (v2 - v1, v3 - v1, v1), (v3 - v1, v3 - v2, v3)]:
        n = np.cross(a, b)
        nv, nn = n @ c, n @ n
        if nn == 0.0:
            return None
        if nv != 0.0 and nn > MINVAL:
            return (nv / nn) * n
    return (nv / nn) * n


def s1d(s1, s2):
    p_o = project_origin_line(s1, s2)
    index = 0
    mu_max = s1[0] - s2[0]
    for i in (1, 2):
        if abs(s1[i] - s2[i]) >= abs(mu_max):
            mu_max, index = s1[i] - s2[i], i
    c1, c2 = p_o[index] - s2[index], s1[index] - p_o[index]
    if same_sign(mu_max, c1) and same_sign(mu_max, c2):
        return np.array([c1 / mu_max, c2 / mu_max])
    return np.array([0.0, 1.0])


def s2d(s1, s2, s3):
    p_o = project_origin_plane(s1, s2, s3)
    if p_o is None:
        return np.append(s1d(s1, s2), 0.0)
    # minors M_14, M_24, M_34 of [[s1 s2 s3]; [1 1 1]] (same formulas as _S2D)
    m14 = (s2[1] * s3[2] - s2[2] * s3[1] - s1[1] * s3[2] + s1[2] * s3[1]
           + s1[1] * s2[2] - s1[2] * s2[1])
    m24 = (s2[0] * s3[2] - s2[2] * s3[0] - s1[0] * s3[2] + s1[2] * s3[0]
           + s1[0] * s2[2] - s1[2] * s2[0])
    m34 = (s2[0] * s3[1] - s2[1] * s3[0] - s1[0] * s3[1] + s1[1] * s3[0]
           + s1[0] * s2[1] - s1[1] * s2[0])
    # drop the axis with the largest projection of the triangle
    if abs(m14) >= abs(m24) and abs(m14) >= abs(m34):
        m_max, keep = m14, [1, 2]
    elif abs(m24) >= abs(m34):
        m_max, keep = m24, [0, 2]
    else:
        m_max, keep = m34, [0, 1]
    a, b, c, p = (v[keep] for v in (s1, s2, s3, p_o))
    # cofactors C31, C32, C33 = signed areas of (p, s2, s3), (p, s3, s1), (p, s1, s2)
    c31 = p[0] * b[1] + p[1] * c[0] + b[0] * c[1] - p[0] * c[1] - p[1] * b[0] - c[0] * b[1]
    c32 = p[0] * c[1] + p[1] * a[0] + c[0] * a[1] - p[0] * a[1] - p[1] * c[0] - a[0] * c[1]
    c33 = p[0] * a[1] + p[1] * b[0] + a[0] * b[1] - p[0] * b[1] - p[1] * a[0] - b[0] * a[1]
    comp = [same_sign(m_max, c31), same_sign(m_max, c32), same_sign(m_max, c33)]
    if all(comp):
        return np.array([c31, c32, c33]) / m_max         # projection inside the triangle
    dmin, lam = FLOAT_MAX, np.zeros(3)
    for i, (u, v) in enumerate([(1, 2), (0, 2), (0, 1)]):
        if comp[i]:
            continue
        sub = s1d([s1, s2, s3][u], [s1, s2, s3][v])
        x = sub[0] * [s1, s2, s3][u] + sub[1] * [s1, s2, s3][v]
        if x @ x < dmin:
            dmin, lam = x @ x, np.zeros(3)
            lam[u], lam[v] = sub
    return lam


def s3d(s1, s2, s3, s4):
    c41, c42, c43, c44 = -det3(s2, s3, s4), det3(s1, s3, s4), -det3(s1, s2, s4), det3(s1, s2, s3)
    m_det = c41 + c42 + c43 + c44                        # 6 x signed volume
    comp = [same_sign(m_det, c) for c in (c41, c42, c43, c44)]
    if all(comp):
        return np.array([c41, c42, c43, c44]) / m_det    # origin inside: keep all four
    S, dmin, lam = [s1, s2, s3, s4], FLOAT_MAX, np.zeros(4)
    for drop in range(4):
        if comp[drop]:
            continue
        idx = [i for i in range(4) if i != drop]
        sub = s2d(*(S[i] for i in idx))
        x = sum(sub[j] * S[idx[j]] for j in range(3))
        if x @ x < dmin:
            dmin, lam = x @ x, np.zeros(4)
            lam[idx] = sub
    return lam


def box_support(pos, rot, size, dir):
    return rot @ (np.sign(rot.T @ dir) * size) + pos


def gjk_tetra(A, B, iterations=35):
    """GJK on two boxes; returns the final simplex (4 points when they overlap)."""
    x_k = A[0] - B[0]
    simplex = []
    for _ in range(iterations):
        d = x_k / np.linalg.norm(x_k)
        s = box_support(*A, -d) - box_support(*B, d)
        if x_k @ (x_k - s) < 0.0:
            break
        simplex.append(s)
        n = len(simplex)
        lam = {1: lambda: np.ones(1), 2: lambda: s1d(*simplex), 3: lambda: s2d(*simplex),
               4: lambda: s3d(*simplex)}[n]()
        simplex = [simplex[i] for i in range(n) if lam[i] != 0.0]
        x_k = sum(l * p for l, p in zip(lam[lam != 0.0], simplex))
        if len(simplex) == 4:
            break
    return np.array(simplex)


# ---- EPA, shaped like _epa / _attach_face / _add_edge ----
HORIZON_MAX = 24                                         # MJ_MAX_EPAHORIZON in types.py


class Polytope:
    def __init__(self, verts):
        self.vert = [v for v in verts]
        self.center = np.mean(verts, axis=0)
        self.face, self.face_pr, self.face_norm2 = [], [], []
        self.deleted, self.invalid = [], []

    def attach_face(self, v1, v2, v3):
        p1, p2, p3 = self.vert[v1], self.vert[v2], self.vert[v3]
        n = np.cross(p2 - p1, p3 - p1)
        r = (n @ p1) / (n @ n) * n                       # origin projected onto the plane
        if r @ (p1 - self.center) < 0.0:
            r = -r                                       # point outward from the polytope
        self.face.append((v1, v2, v3))
        self.face_pr.append(r)
        self.face_norm2.append(float(r @ r))
        self.deleted.append(False)
        self.invalid.append(False)
        return self.face_norm2[-1]


def add_edge(horizon, e1, e2):
    """_add_edge: an edge seen twice is interior to the deleted region and cancels."""
    edge = (min(e1, e2), max(e1, e2))
    if edge in horizon:
        horizon.remove(edge)
        return True
    if len(horizon) == HORIZON_MAX:
        return False                                     # EPA_HORIZON overflow in MJWarp
    horizon.append(edge)
    return True


def epa(A, B, simplex, iterations=16, tol=1e-7):
    pt = Polytope(simplex)
    for f in [(0, 1, 2), (0, 3, 1), (0, 2, 3), (3, 2, 1)]:          # _polytope4 faces
        pt.attach_face(*f)
    upper, upper2, idx, log = np.inf, np.inf, -1, []
    for k in range(iterations):
        alive = [i for i in range(len(pt.face)) if not (pt.deleted[i] or pt.invalid[i])]
        idx = min(alive, key=lambda i: pt.face_norm2[i])  # closest face: lower bound
        lower2 = pt.face_norm2[idx]
        lower = np.sqrt(lower2)
        normal = pt.face_pr[idx] / lower
        w = box_support(*A, normal) - box_support(*B, -normal)       # _epa_support
        upper = min(upper, float(pt.face_pr[idx] @ w) / lower)
        upper2 = upper * upper
        entry = {"k": k, "lower": round(lower, 6), "upper": round(upper, 6),
                 "closest": idx, "n": normal.round(4).tolist(), "w": w.round(4).tolist(),
                 "verts": [v.round(4).tolist() for v in pt.vert],
                 "faces": [list(pt.face[i]) for i in range(len(pt.face)) if not pt.deleted[i]],
                 "nvalid": len(alive)}
        if upper - lower < tol:
            entry["event"] = "converged"
            log.append(entry)
            break
        if any(np.allclose(w, v) for v in pt.vert):
            entry["event"] = "repeated support point"
            log.append(entry)
            break
        wi = len(pt.vert)
        pt.vert.append(w)
        horizon, removed = [], []
        for i in range(len(pt.face)):                    # every face w can see (+ closest)
            if pt.deleted[i]:
                continue
            if i == idx or pt.face_pr[i] @ w - pt.face_norm2[i] > 1e-10:
                pt.deleted[i] = True
                removed.append(list(pt.face[i]))
                a, b, c = pt.face[i]
                for e in ((a, b), (b, c), (c, a)):
                    assert add_edge(horizon, *e), "horizon overflow"
        added = []
        for e1, e2 in horizon:                           # one new face per horizon edge
            d2 = pt.attach_face(wi, e1, e2)
            if not (lower2 <= d2 <= upper2):
                pt.invalid[-1] = True                    # cannot be the answer: skip it
            added.append([wi, e1, e2])
        entry.update({"event": "expand", "removed": removed, "horizon": horizon,
                      "added": added, "nhorizon": len(horizon)})
        log.append(entry)
    return lower, normal, log


BOXES = """
<mujoco model="box_on_box">
  <worldbody>
    <geom name="A" type="box" size="0.2 0.15 0.05"/>
    <body name="B" pos="0.05 0.02 0.139"><freejoint/>
      <geom name="B" type="box" size="0.1 0.08 0.1"/></body>
  </worldbody>
</mujoco>
"""


def quat(axis, deg):
    a = np.radians(deg) / 2
    return np.concatenate([[np.cos(a)], np.sin(a) * np.asarray(axis) / np.linalg.norm(axis)])


# w0: axis-aligned, B sinks 11 mm into A. w1: B tilted, a corner digs into A's top.
CASES = [("w0 axis-aligned", [0.05, 0.02, 0.139], [1, 0, 0, 0]),
         ("w1 tilted", [-0.093, -0.007, 0.15], quat([0.2, -1.61, 1.81], 44.3))]
mjm = mujoco.MjModel.from_xml_string(BOXES)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=len(CASES), nconmax=8, njmax=32)
qpos = np.array([np.concatenate([p, q]) for _, p, q in CASES])
d.qpos.assign(qpos.astype(np.float32))
mjw.kinematics(m, d)
mjw.collision(m, d)
n = min(int(d.nacon.numpy()[0]), d.naconmax)
cw, cdist = d.contact.worldid.numpy()[:n], d.contact.dist.numpy()[:n]
cframe = d.contact.frame.numpy()[:n]
print("analytic overlap of w0 along z = 0.05 + 0.1 - 0.139 =", round(0.05 + 0.1 - 0.139, 4))

dump = {"cases": []}
for w, (name, p, q) in enumerate(CASES):
    rot = np.zeros(9)
    mujoco.mju_quat2Mat(rot, np.asarray(q, float))
    A = (np.zeros(3), np.eye(3), mjm.geom_size[0])
    B = (np.array(p), rot.reshape(3, 3), mjm.geom_size[1])
    simplex = gjk_tetra(A, B)
    depth, normal, log = epa(A, B, simplex)
    print(f"--- {name}: GJK simplex has {len(simplex)} points")
    for e in log:
        extra = (f"  removed {len(e['removed'])} faces, horizon {e['nhorizon']} edges,"
                 f" +{len(e['added'])} faces" if e["event"] == "expand" else "")
        print(f"  k={e['k']}  faces={len(e['faces']):2d} (valid {e['nvalid']:2d})  "
              f"lower={e['lower']:.6f}  "
              f"upper={e['upper']:.6f}  {e['event']}{extra}")
    sel = cw == w
    print(f"  teaching EPA: depth = {depth:.5f}  normal = {normal.round(4)}")
    print(f"  MJWarp: {sel.sum()} contacts, dist = {[round(float(v), 5) for v in cdist[sel]]},"
          f" normal = {cframe[sel][0, 0].round(4)}")
    dump["cases"].append({"name": name, "A": [A[0].tolist(), A[2].tolist()],
                          "B": [list(p), rot.round(5).tolist(), B[2].tolist()],
                          "simplex": simplex.round(4).tolist(), "depth": round(depth, 6),
                          "log": log})
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
