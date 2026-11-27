"""Example 17.2 - support functions in NumPy, checked against brute force.

A support function s(dir) returns the point of a shape that lies furthest along dir. The four
NumPy functions below follow collision_gjk.py::support line by line (capsule, ellipsoid, box:
rotate dir into the geom frame, pick the extreme point, rotate back, add pos, then inflate by
margin/2; the sphere uses the world dir directly).
Each is checked against the "analytic extreme": the max of dot(x, dir) over 20k surface samples.
The shapes are built with MjSpec (Ch 2 §11), so their sizes are MuJoCo's geom_size convention.
Run: python ex2_support_numpy.py
"""
import mujoco
import numpy as np

np.set_printoptions(precision=4, suppress=True)
rng = np.random.default_rng(0)


def rotate(q):
    mat = np.zeros(9)
    mujoco.mju_quat2Mat(mat, np.asarray(q, float))
    return mat.reshape(3, 3)


def support(gtype, size, pos, rot, margin, dir):
    """NumPy mirror of collision_gjk.py::support for sphere, capsule, ellipsoid and box."""
    dir = dir / np.linalg.norm(dir)
    if gtype == "sphere":                      # returns early: its own 0.5*margin term
        return pos + (size[0] + 0.5 * margin) * dir
    local = rot.T @ dir                        # local_dir = transpose(rot) @ dir
    if gtype == "box":
        res = np.sign(local) * size            # the corner with the right signs
    elif gtype == "capsule":
        res = local * size[0]                  # sphere of radius r ...
        res[2] += np.sign(local[2]) * size[1]  # ... moved to the end cap +-halflength
    elif gtype == "ellipsoid":
        res = local * size
        res = res / np.linalg.norm(res)        # normalize(dir * size) * size
        res = res * size
    point = rot @ res + pos
    return point + dir * (0.5 * margin)        # margin inflation, as at the end of support()


def surface_samples(gtype, size, n=20000):
    u = rng.normal(size=(n, 3))
    u /= np.linalg.norm(u, axis=1, keepdims=True)
    if gtype == "sphere":
        return size[0] * u
    if gtype == "ellipsoid":
        return u * size
    if gtype == "capsule":
        p = size[0] * u
        p[:, 2] += np.where(u[:, 2] >= 0, size[1], -size[1])   # two hemispheres
        t = rng.uniform(-size[1], size[1], n)                    # plus the side wall
        side = np.column_stack([size[0] * u[:, 0], size[0] * u[:, 1], t])
        side[:, :2] /= np.linalg.norm(u[:, :2], axis=1, keepdims=True)
        side[:, :2] *= size[0]
        return np.vstack([p, side])
    if gtype == "box":
        corners = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)])
        return np.vstack([corners * size, rng.uniform(-1, 1, (n, 3)) * size])


spec = mujoco.MjSpec()
body = spec.worldbody.add_body(name="shapes")
shapes = {
    "sphere": body.add_geom(type=mujoco.mjtGeom.mjGEOM_SPHERE, size=[0.1, 0, 0]),
    "capsule": body.add_geom(type=mujoco.mjtGeom.mjGEOM_CAPSULE, size=[0.05, 0.1, 0]),
    "ellipsoid": body.add_geom(type=mujoco.mjtGeom.mjGEOM_ELLIPSOID, size=[0.12, 0.06, 0.03]),
    "box": body.add_geom(type=mujoco.mjtGeom.mjGEOM_BOX, size=[0.1, 0.05, 0.02]),
}
mjm = spec.compile()

pos = np.array([0.3, -0.2, 0.5])
rot = rotate([np.cos(0.3), np.sin(0.3) * 0.6, np.sin(0.3) * 0.8, 0.0])   # some rotation
dirs = rng.normal(size=(6, 3))
for gid, (name, _) in enumerate(shapes.items()):
    size = mjm.geom_size[gid].copy()
    pts = surface_samples(name, size) @ rot.T + pos
    errs = []
    for dvec in dirs:
        dn = dvec / np.linalg.norm(dvec)
        s = support(name, size, pos, rot, 0.0, dvec)
        best = (pts @ dn).max()                # brute-force extreme along dir
        errs.append(best - s @ dn)             # >= 0 up to sampling error
    print(f"{name:9s} size={size}  max |extreme - dot(s, dir)| over 6 dirs = "
          f"{np.abs(errs).max():.2e}")

# margin: the support point moves out by margin/2 along dir (each geom gets half)
s0 = support("box", mjm.geom_size[3], pos, rot, 0.0, dirs[0])
s1 = support("box", mjm.geom_size[3], pos, rot, 0.02, dirs[0])
print("box support, margin 0   :", s0)
print("box support, margin 0.02:", s1, " shift =", round(float(np.linalg.norm(s1 - s0)), 4))

# Minkowski difference A - B: its support along dir is s_A(dir) - s_B(-dir)
a = support("sphere", mjm.geom_size[0], np.zeros(3), np.eye(3), 0.0, np.array([1.0, 0, 0]))
b = support("box", mjm.geom_size[3], np.array([0.25, 0, 0]), np.eye(3), 0.0,
            -np.array([1.0, 0, 0]))
print("support of (sphere - box) along +x:", a - b, "(x < 0: the shapes are 0.05 apart)")
