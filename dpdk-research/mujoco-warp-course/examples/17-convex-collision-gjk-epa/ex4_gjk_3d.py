"""Example 17.4 - GJK in 3D with the signed-volume sub-algorithm, checked against MJWarp.

s1d / s2d / s3d below are line-by-line NumPy ports of collision_gjk.py::_S1D, _S2D and _S3D
(signed volumes and cofactors, no Voronoi-region tests). The loop is collision_gjk.py::gjk.
Two boxes are tested: (w0) separated by about 2 cm with margin 0.05, so MJWarp writes contacts
whose dist is the true gap, and (w1) overlapping, where GJK ends with a tetrahedron (n == 4).
For each iteration we print which sub-simplex _S3D/_S2D/_S1D kept (vertex, edge, face or the
whole tetrahedron) and finally compare the GJK distance with d.contact.dist from MJWarp and
with MuJoCo C.
Run: python ex4_gjk_3d.py [--dump-json PATH]
  --dump-json PATH writes the per-iteration simplices for the page's 3-D GJK view.
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


def gjk(g1, g2, iterations=35):
    """g = (pos, rot, size) of a box. Discrete geoms: tolerance ignored, as in MJWarp."""
    x_k = g1[0] - g2[0]
    simplex, log = [], []
    xnorm, xnorm_prev = np.linalg.norm(x_k), 0.0
    names = {1: "vertex", 2: "edge", 3: "face", 4: "tetrahedron (origin inside)"}
    for k in range(iterations):
        if xnorm < MINVAL or abs(xnorm_prev - xnorm) < MINVAL:
            break
        d = x_k / xnorm
        s = box_support(*g1, -d) - box_support(*g2, d)
        if x_k @ (x_k - s) < 0.0:                        # epsilon = 0 for discrete geoms
            break
        simplex.append(s)
        n = len(simplex)
        lam = {1: lambda: np.ones(1), 2: lambda: s1d(*simplex), 3: lambda: s2d(*simplex),
               4: lambda: s3d(*simplex)}[n]()
        kept = [i for i in range(n) if lam[i] != 0.0]
        simplex = [simplex[i] for i in kept]
        x_k = sum(lam[i] * p for i, p in zip(kept, simplex))
        xnorm_prev, xnorm = (0.0 if k == 0 else xnorm), np.linalg.norm(x_k)
        log.append({"k": k, "n_in": n, "kept": kept, "region": names[len(simplex)],
                    "s": s.round(4).tolist(), "x": x_k.round(5).tolist(),
                    "simplex": [p.round(4).tolist() for p in simplex]})
        if len(simplex) == 4:
            return 0.0, log
    return float(xnorm), log


def quat_z(deg):
    a = np.radians(deg) / 2
    return np.array([np.cos(a), 0, 0, np.sin(a)])


TWO_BOXES = """
<mujoco model="two_boxes">
  <worldbody>
    <geom name="A" type="box" size="0.1 0.1 0.1"/>
    <body name="B" pos="0.3 0 0"><freejoint/>
      <geom name="B" type="box" size="0.1 0.1 0.1" margin="0.05"/></body>
  </worldbody>
</mujoco>
"""
CASES = [("w0 separated", [0.1 + 0.1 * np.sqrt(2) + 0.02, 0.03, 0.0], 45.0),   # 2 cm gap
         ("w1 overlapping", [0.17, 0.04, 0.03], 30.0)]

mjm = mujoco.MjModel.from_xml_string(TWO_BOXES)
mjd = mujoco.MjData(mjm)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=len(CASES), nconmax=8, njmax=32)
qpos = np.tile(mjm.qpos0, (len(CASES), 1))
for w, (_, p, deg) in enumerate(CASES):
    qpos[w, :3], qpos[w, 3:7] = p, quat_z(deg)
d.qpos.assign(qpos.astype(np.float32))
mjw.kinematics(m, d)
mjw.collision(m, d)
n = min(int(d.nacon.numpy()[0]), d.naconmax)
cw, cdist = d.contact.worldid.numpy()[:n], d.contact.dist.numpy()[:n]

dump = {"cases": []}
for w, (name, p, deg) in enumerate(CASES):
    rot = np.zeros(9)
    mujoco.mju_quat2Mat(rot, quat_z(deg))
    gA = (np.zeros(3), np.eye(3), np.full(3, 0.1))
    gB = (np.array(p), rot.reshape(3, 3), np.full(3, 0.1))
    dist, log = gjk(gA, gB)
    print(f"--- {name} (B at {np.round(p, 4).tolist()}, turned {deg} deg about z)")
    for e in log:
        print(f"  k={e['k']}  {e['n_in']} pts in -> kept {e['kept']} = {e['region']:9s}"
              f"  |x| = {np.linalg.norm(e['x']):.5f}")
    mjd.qpos[:] = qpos[w]
    mujoco.mj_forward(mjm, mjd)
    c_dist = sorted(round(float(mjd.contact.dist[i]), 5) for i in range(mjd.ncon))
    print(f"  teaching GJK dist = {dist:.5f}")
    print(f"  MJWarp contact.dist = {[round(float(v), 5) for v in np.sort(cdist[cw == w])]}")
    print(f"  MuJoCo C contact.dist = {c_dist}")
    dump["cases"].append({"name": name, "B": np.round(p, 4).tolist(), "deg": deg, "dist": dist,
                          "log": log})
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
