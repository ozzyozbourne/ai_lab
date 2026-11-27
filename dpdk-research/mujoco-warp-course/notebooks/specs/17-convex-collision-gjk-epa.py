# Notebook spec for Ch 17. Build with:
#   python3 tools/make_notebook.py notebooks/specs/17-convex-collision-gjk-epa.py
SLUG = "17-convex-collision-gjk-epa"
TITLE = "Ch 17 · Collision III: Convex Shapes with GJK, EPA and Multi-Contact"

GJK_PLOT = '''# Interactive GJK stepping (uses gjk2d, A and cases from Example 17.3: run that cell first).
%matplotlib inline
import numpy as np
try:
    import matplotlib.pyplot as plt
except ImportError:
    plt = None
    print("skipped: matplotlib not installed")


def hull(P):
    P = sorted(map(tuple, P))
    def cr(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for p in P:
        while len(lo) >= 2 and cr(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(P):
        while len(up) >= 2 and cr(up[-2], up[-1], p) <= 0:
            up.pop()
        up.append(p)
    return np.array(lo[:-1] + up[:-1])


def show(case="separated", k=0):
    B = cases[case]
    dist, overlap, log = gjk2d(A, B)
    k = min(k, len(log) - 1)
    M = hull([a - b for a in A for b in B])
    fig, ax = plt.subplots(1, 2, figsize=(10, 4.2))
    for P, c in ((A, "C0"), (B, "C1")):
        ax[0].fill(*np.vstack([P, P[:1]]).T, alpha=0.35, color=c)
    ax[0].set_title("world: A and B"); ax[0].set_aspect("equal")
    ax[1].fill(*np.vstack([M, M[:1]]).T, alpha=0.25, color="C9")
    ax[1].plot(0, 0, "k+", ms=14, mew=2)
    e = log[k]
    S = np.array(e["simplex"])
    if len(S):
        ax[1].fill(*np.vstack([S, S[:1]]).T, alpha=0.5, color="C2", lw=3, edgecolor="C2")
    ax[1].plot(*e["s"], "o", color="C1", ms=9, label="new support point")
    ax[1].plot([0, e["x"][0]], [0, e["x"][1]], "r-", lw=2, label="x_k")
    ax[1].set_title(f"A - B, k={e['k']} ({e['event']}), |x|={np.linalg.norm(e['x']):.4f}")
    ax[1].set_aspect("equal"); ax[1].legend(loc="lower left")
    plt.show()


if plt is not None:
    try:
        from ipywidgets import interact
        interact(show, case=list(cases), k=(0, 5))
    except ImportError:
        for kk in range(4):
            show("overlapping", kk)
'''

EX1_STUB = '''# Exercise 17.1 (needs support_poly, s1d, s2d, brute_distance and A from Example 17.3: run it first)
import numpy as np


def gjk2d_witness(A, B, iterations=20, tol=1e-6):
    """Return (dist, x1, x2): dist = |x1 - x2|, x1 on A, x2 on B."""
    ...   # keep simplex1 / simplex2 next to simplex and drop the same vertices


def cross2(a, b):
    return a[0] * b[1] - a[1] * b[0]


def on_or_in(P, x, eps=1e-9):
    return all(cross2(P[(i + 1) % len(P)] - P[i], x - P[i]) >= -eps for i in range(len(P)))


B0 = np.array([[0.0, 0.0], [0.9, 0.1], [1.0, 0.8], [0.2, 0.9]])
if gjk2d_witness(A, B0 + [1.9, 0.9]) is None:
    print("Exercise 17.1: fill in gjk2d_witness, then re-run this cell")
else:
    for off in ([1.9, 0.9], [2.5, 0.0], [0.4, 1.6]):
        B = B0 + off
        dist, x1, x2 = gjk2d_witness(A, B)
        assert abs(dist - brute_distance(A, B)) < 1e-6
        assert abs(np.linalg.norm(x1 - x2) - dist) < 1e-9
        assert on_or_in(A, x1) and on_or_in(B, x2)
    print("all 3 cases pass")
'''

EX1_SOL = '''def gjk2d_witness(A, B, iterations=20, tol=1e-6):
    x_k = A.mean(0) - B.mean(0)
    simplex, simplex1, simplex2 = [], [], []
    lam = np.ones(1)
    for k in range(iterations):
        xnorm = np.linalg.norm(x_k)
        if xnorm < tol:
            break
        d = x_k / xnorm
        p1, p2 = support_poly(A, -d), support_poly(B, d)
        s = p1 - p2
        if x_k @ (x_k - s) < 0.5 * tol * tol:
            break
        simplex.append(s); simplex1.append(p1); simplex2.append(p2)
        if len(simplex) == 1:
            lam, inside = np.array([1.0]), False
        elif len(simplex) == 2:
            lam, inside = s1d(*simplex), False
        else:
            lam, inside = s2d(*simplex)
        keep = [i for i in range(len(simplex)) if lam[i] != 0.0]
        simplex = [simplex[i] for i in keep]
        simplex1 = [simplex1[i] for i in keep]
        simplex2 = [simplex2[i] for i in keep]
        lam = lam[keep]
        x_k = sum(l * p for l, p in zip(lam, simplex))
        if inside:
            break
    x1 = sum(l * p for l, p in zip(lam, simplex1))   # same weights, applied to each shape
    x2 = sum(l * p for l, p in zip(lam, simplex2))
    return float(np.linalg.norm(x_k)), x1, x2


def cross2(a, b):
    return a[0] * b[1] - a[1] * b[0]


def on_or_in(P, x, eps=1e-9):
    return all(cross2(P[(i + 1) % len(P)] - P[i], x - P[i]) >= -eps for i in range(len(P)))


B0 = np.array([[0.0, 0.0], [0.9, 0.1], [1.0, 0.8], [0.2, 0.9]])
for off in ([1.9, 0.9], [2.5, 0.0], [0.4, 1.6]):
    B = B0 + off
    dist, x1, x2 = gjk2d_witness(A, B)
    assert abs(dist - brute_distance(A, B)) < 1e-6
    assert abs(np.linalg.norm(x1 - x2) - dist) < 1e-9
    assert on_or_in(A, x1) and on_or_in(B, x2)
    print(f"offset {off}: dist = {dist:.4f}  x1 = {x1.round(4)}  x2 = {x2.round(4)}")
print("all 3 cases pass")
'''

EX2_STUB = '''# Exercise 17.2: a cylinder support function
import numpy as np

MINVAL = 1e-15


def cylinder_support(size, pos, rot, dir):
    ...   # rotate dir into the local frame, rim point in xy, +-half-height by the sign of z


rng = np.random.default_rng(1)
size = np.array([0.05, 0.08, 0.0])
a = 0.4
rot = np.array([[1, 0, 0], [0, np.cos(a), -np.sin(a)], [0, np.sin(a), np.cos(a)]])
pos = np.array([0.1, -0.2, 0.3])
ang = rng.uniform(0, 2 * np.pi, 40000)
z = rng.choice([-1.0, 1.0], 40000) * size[1]
rim = np.column_stack([size[0] * np.cos(ang), size[0] * np.sin(ang), z]) @ rot.T + pos
dirs = [np.array(v, float) for v in ([1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 0, -1],
        [1, 1, 1], [-1, 2, 0.5], [0.3, -0.2, -1], [-1, -1, 0.2])]
if cylinder_support(size, pos, rot, dirs[0]) is None:
    print("Exercise 17.2: fill in cylinder_support, then re-run this cell")
else:
    for dvec in dirs:
        dn = dvec / np.linalg.norm(dvec)
        s = cylinder_support(size, pos, rot, dvec)
        assert abs((rim @ dn).max() - s @ dn) < 1e-6, dvec
    print("8 directions pass")
'''

EX2_SOL = '''import numpy as np

MINVAL = 1e-15


def cylinder_support(size, pos, rot, dir):
    """Mirror of the CYLINDER branch of collision_gjk.py::support (margin 0)."""
    local = rot.T @ (dir / np.linalg.norm(dir))
    res = np.zeros(3)
    d = np.hypot(local[0], local[1])
    if d > MINVAL:                                  # point on the rim circle
        res[:2] = local[:2] * size[0] / d
    res[2] = size[1] if local[2] >= 0.0 else -size[1]   # top or bottom cap
    return rot @ res + pos


rng = np.random.default_rng(1)
size = np.array([0.05, 0.08, 0.0])
a = 0.4
rot = np.array([[1, 0, 0], [0, np.cos(a), -np.sin(a)], [0, np.sin(a), np.cos(a)]])
pos = np.array([0.1, -0.2, 0.3])
ang = rng.uniform(0, 2 * np.pi, 40000)
z = rng.choice([-1.0, 1.0], 40000) * size[1]
rim = np.column_stack([size[0] * np.cos(ang), size[0] * np.sin(ang), z]) @ rot.T + pos
dirs = [np.array(v, float) for v in ([1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 0, -1],
        [1, 1, 1], [-1, 2, 0.5], [0.3, -0.2, -1], [-1, -1, 0.2])]
for dvec in dirs:
    dn = dvec / np.linalg.norm(dvec)
    s = cylinder_support(size, pos, rot, dvec)
    assert abs((rim @ dn).max() - s @ dn) < 1e-6, dvec
print("8 directions pass")
'''

STRETCH = '''# Stretch (Colab GPU): what does CCD cost? A starting point; report only your own numbers.
import time

def time_collision(m, d, n=20):
    mjw.kinematics(m, d)
    mjw.collision(m, d)           # warm-up (JIT)
    wp.synchronize()
    t0 = time.perf_counter()
    for _ in range(n):
        mjw.collision(m, d)
    wp.synchronize()
    return (time.perf_counter() - t0) / n

# Build (a) a primitive-only scene and (b) a convex scene with the same contacts per world,
# then compare d.nworld / time_collision(m, d) for nworld = 1024, 4096, 16384 (GPU only),
# and for scene (b) also ccd_iterations 8 vs 35 and naccdmax "just enough" vs the default.
print("GPU available:", ON_GPU)
'''

CELLS = [
    ["md", "Every code cell below is the same file as the matching block on the chapter page "
           "(`examples/17-convex-collision-gjk-epa/`). Examples 17.2-17.6 are NumPy teaching code that "
           "mirrors `collision_gjk.py` (17.4 and 17.6 also compare with MuJoCo Warp); the others run MuJoCo Warp. Budgets grow on a GPU "
           "(`ON_GPU`) and stay small on a CPU. CPU numbers are never GPU numbers."],
    ["md", "## 1. Why one general convex path\nPairs marked CONVEX in `MJ_COLLISION_TABLE` (cylinder, ellipsoid, "
           "box-box, mesh, heightfield) go through `collision_convex.py::convex_narrowphase`, which builds one "
           "kernel per convex type pair present: support functions, GJK, EPA when needed, multi-contact, "
           "`write_contact`. There is no MPR in this code base."],
    ["example", "ex1_convex_scene.py", "17.1"],
    ["md", "## 2. Support functions and the Minkowski difference\n`support(geom, dir)` returns the point of a "
           "shape furthest along `dir`, then pushes it out by `0.5 * margin`. The Minkowski difference A - B "
           "contains the origin exactly when A and B overlap, and its support is `s_A(d) - s_B(-d)`."],
    ["example", "ex2_support_numpy.py", "17.2"],
    ["md", "## 3. GJK in 2-D\nThe loop of `collision_gjk.py::gjk`: support point along `-x_k`, Frank-Wolfe "
           "duality-gap stop, distance sub-algorithm, drop vertices with weight 0, stop when the simplex is full."],
    ["example", "ex3_gjk_2d.py", "17.3"],
    ["md", "### Interactive GJK stepping\nPick a case and an iteration (needs `ipywidgets`, which Colab has; "
           "otherwise it draws the overlapping case iteration by iteration)."],
    ["code", GJK_PLOT],
    ["md", "### Exercise 17.1: witness points\nExtend the 2-D GJK so it also returns `x1` on A and `x2` on B "
           "(the same `lmbda` applied to the per-shape support points, like `simplex1`/`simplex2` in `gjk()`). "
           "Run it right after Example 17.3: later examples redefine `s1d`, `s2d` and `A` in 3-D."],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 17.1"],
    ["md", "## 3b. GJK in 3-D with signed volumes\n`_S3D` uses cofactors of the 4x4 matrix [[s1 s2 s3 s4], "
           "[1 1 1 1]]; all with the sign of their sum means the origin is inside. Otherwise `_S2D` on the faces "
           "with the wrong sign, and `_S1D` on edges."],
    ["example", "ex4_gjk_3d.py", "17.4"],
    ["md", "## 4. EPA\nGrow a polytope inside A - B: closest face (lower bound), support point along its "
           "normal (upper bound), delete visible faces, attach new faces to the horizon (`_add_edge`)."],
    ["example", "ex5_epa_2d.py", "17.5"],
    ["example", "ex6_mjw_vs_teaching.py", "17.6"],
    ["md", "## 5. Kernels, scratch and tuning\n`ccd_iterations` (default 35) bounds GJK and, unless the "
           "model is box-box only, EPA; it is compiled into the CCD kernels. Each EPA/multi-contact pair "
           "takes a scratch row (`naccdmax` rows per pair-type kernel); running out sets `OverflowType.CCD`."],
    ["example", "ex7_ccd_iterations.py", "17.7"],
    ["example", "ex8_naccdmax_overflow.py", "17.8"],
    ["md", "## 6. Multi-contact\nAligned faces are clipped against each other (`_polygon_clip`) and reduced "
           "to 4 points (`_polygon_quad`). Always on for box-box; other face/face and edge/face pairs follow "
           "`DisableBit.MULTICCD`."],
    ["example", "ex9_multiccd.py", "17.9"],
    ["md", "## 7. Meshes collide as their convex hull\nThe mesh support function returns the best vertex "
           "(hill-climbing on the hull graph), which is the support of the convex hull."],
    ["example", "ex10_nonconvex_mesh.py", "17.10"],
    ["md", "## Exercise 17.2: a cylinder support function\nMirror the CYLINDER branch of `support()` "
           "(margin 0) and check it on 8 directions against 40,000 rim samples."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 17.2"],
    ["md", "## Stretch: what does CCD cost?\nOn a GPU runtime, time `mjw.collision` alone for a primitive-only "
           "scene and a convex scene with the same contacts per world, for several `nworld`, then vary "
           "`ccd_iterations` and `naccdmax`."],
    ["code", STRETCH],
]
