"""Example 15.1 - the geometry toolkit in plain NumPy: AABB overlap, a 2-D OBB separating-axis
test and the closest points between two segments.

These are the yes/no questions and distances that every broadphase filter and many narrowphase
colliders are built from. No MJWarp yet: only NumPy, so you can read every line.
Run: python ex1_toolkit_numpy.py
"""
import numpy as np

np.set_printoptions(precision=4, suppress=True)


def rot2(theta):
    """2-D rotation matrix; its columns are the box's local x and y axes in world coordinates."""
    c, s = np.cos(theta), np.sin(theta)
    return np.array([[c, -s], [s, c]])


def obb_corners(center, half, theta):
    """The 4 corners of an oriented box (center, half sizes, angle)."""
    signs = np.array([[-1, -1], [1, -1], [1, 1], [-1, 1]], float)
    return center + (signs * half) @ rot2(theta).T


def aabb_of_obb(center, half, theta):
    """Axis-aligned box around an oriented box: min and max over its corners."""
    c = obb_corners(center, half, theta)
    return c.min(axis=0), c.max(axis=0)


def aabb_overlap(lo1, hi1, lo2, hi2, margin=0.0):
    """Two AABBs overlap unless they are separated along x or along y (Ericson 4.2)."""
    return bool(np.all(hi1 + margin >= lo2) and np.all(hi2 + margin >= lo1))


def obb_sat(c1, h1, t1, c2, h2, t2, margin=0.0):
    """Separating-axis test for two 2-D boxes. Candidate axes: the 2 face normals of each box.

    On each axis n, a box covers [proj - radius, proj + radius] with
    radius = sum_k |half_k * dot(axis_k, n)|. A gap on any axis proves separation.
    Returns (overlap, index of the first separating axis or -1).
    """
    axes = [rot2(t1)[:, 0], rot2(t1)[:, 1], rot2(t2)[:, 0], rot2(t2)[:, 1]]
    for k, n in enumerate(axes):
        r1 = sum(abs(h1[i] * axes[i] @ n) for i in range(2))
        r2 = sum(abs(h2[i] * axes[2 + i] @ n) for i in range(2))
        if r1 + r2 + margin < abs((c2 - c1) @ n):
            return False, k
    return True, -1


def segment_closest(p1, q1, p2, q2):
    """Closest points between segments p1-q1 and p2-q2 (Ericson 5.1.9). Returns (s, t, c1, c2, dist)."""
    d1, d2, r = q1 - p1, q2 - p2, p1 - p2
    a, e, f = d1 @ d1, d2 @ d2, d2 @ r
    c, b = d1 @ r, d1 @ d2
    denom = a * e - b * b
    s = np.clip((b * f - c * e) / denom, 0.0, 1.0) if denom > 1e-12 else 0.0  # parallel: pick s = 0
    t = (b * s + f) / e
    if t < 0.0:
        t, s = 0.0, np.clip(-c / a, 0.0, 1.0)
    elif t > 1.0:
        t, s = 1.0, np.clip((b - c) / a, 0.0, 1.0)
    c1, c2 = p1 + s * d1, p2 + t * d2
    return s, t, c1, c2, float(np.linalg.norm(c1 - c2))


# Four box configurations: box A fixed, box B moved/rotated.
A = (np.array([0.0, 0.0]), np.array([1.0, 0.5]), 0.0)
configs = {
    "far apart": (np.array([3.0, 0.0]), np.array([0.5, 0.5]), 0.0),
    "overlapping": (np.array([1.2, 0.3]), np.array([0.5, 0.5]), 0.3),
    "AABB yes, OBB no": (np.array([1.3, 0.8]), np.array([0.6, 0.15]), -np.pi / 4),
    "touching corner": (np.array([1.5, 1.0]), np.array([0.5, 0.5]), 0.0),
}
print("config             | AABB overlap | OBB (SAT) overlap | separating axis")
for name, B in configs.items():
    lo1, hi1 = aabb_of_obb(*A)
    lo2, hi2 = aabb_of_obb(*B)
    ok_aabb = aabb_overlap(lo1, hi1, lo2, hi2)
    ok_obb, axis = obb_sat(*A, *B)
    label = "-" if axis < 0 else ["A.x", "A.y", "B.x", "B.y"][axis]
    print(f"{name:18s} | {str(ok_aabb):12s} | {str(ok_obb):17s} | {label}")

print()
segs = {
    "crossing (X)": ([-1, 0], [1, 0], [0, -1], [0, 1]),
    "skew, end-to-mid": ([0, 0], [1, 0], [2, -1], [2, 1]),
    "parallel": ([0, 0], [2, 0], [1, 0.5], [3, 0.5]),
    "end to end": ([0, 0], [1, 0], [2, 1], [3, 2]),
}
for name, (p1, q1, p2, q2) in segs.items():
    s, t, c1, c2, dist = segment_closest(*(np.array(v, float) for v in (p1, q1, p2, q2)))
    print(f"{name:17s} s={s:.3f} t={t:.3f} c1={c1} c2={c2} dist={dist:.4f}")
