"""Example 3.8 - one pendulum, two descriptions: maximal coordinates vs reduced coordinates.

(a) Maximal: a point mass with free (x, z) and a very stiff spring standing in for the rod,
    in NumPy with semi-implicit Euler. 2 coordinates, and the rod length is only kept
    approximately; stiffer rods drift less but need smaller time steps.
(b) Reduced: a hinge joint in MuJoCo. 1 coordinate (the angle); the rod length is exact
    by construction.
We print the period from both, the exact large-amplitude period, and the rod-length drift of (a).
Run: python ex8_pendulum_two_ways.py
"""
import mujoco
import numpy as np

np.set_printoptions(precision=4, suppress=True)

L, G, TH0 = 0.5, 9.81, 0.5          # rod length [m], gravity, start angle [rad] from straight down
DT, T = 0.001, 5.0

PENDULUM_HINGE = f"""
<mujoco model="hinge_pendulum">
  <option timestep="{DT}"/>
  <worldbody>
    <body name="pivot">
      <joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="sphere" pos="0 0 -{L}" size=".01" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""


def period_from(x, dt):
    """Mean time between upward zero crossings of x(t)."""
    up = np.nonzero((x[:-1] < 0) & (x[1:] >= 0))[0]
    # linear interpolation of the crossing time inside the step
    t = (up + x[up] / (x[up] - x[up + 1])) * dt
    return float(np.diff(t).mean())


def exact_period(L, g, th0):
    """T = 4 sqrt(L/g) K(sin(th0/2)); K by the arithmetic-geometric mean."""
    a, b = 1.0, np.sqrt(1 - np.sin(th0 / 2) ** 2)
    for _ in range(30):
        a, b = (a + b) / 2, np.sqrt(a * b)
    return 4 * np.sqrt(L / g) * np.pi / (2 * a)


def cartesian_pendulum(k):
    """(a) point mass on a stiff spring 'rod' (k per unit mass), semi-implicit Euler."""
    p = L * np.array([np.sin(TH0), -np.cos(TH0)])     # (x, z), pivot at the origin
    v = np.zeros(2)
    xs, stretch = [], 0.0
    for _ in range(round(T / DT)):
        r = np.linalg.norm(p)
        a = np.array([0.0, -G]) - k * (r - L) * p / r  # gravity + spring along the rod
        v = v + a * DT
        p = p + v * DT
        xs.append(p[0])
        stretch = max(stretch, abs(np.linalg.norm(p) - L))
        if not np.isfinite(p).all() or stretch > 10 * L:
            return None, np.inf
    return period_from(np.array(xs), DT), stretch


print(f"L = {L} m, start angle {TH0} rad, dt = {DT} s, {T} s simulated")
print(f"small-angle period 2 pi sqrt(L/g) = {2 * np.pi * np.sqrt(L / G):.4f} s")
print(f"exact period for this amplitude   = {exact_period(L, G, TH0):.4f} s")
print("(a) maximal coordinates (x, z) + stiff spring rod, 2 DOF:")
for k in [1e3, 1e4, 1e5, 1e6, 1e7]:
    per, st = cartesian_pendulum(k)
    if per is None:
        print(f"    k/m = {k:8.0e}: unstable (sqrt(k/m)*dt = {np.sqrt(k) * DT:.2f} > 2), blew up")
    else:
        print(f"    k/m = {k:8.0e}: period = {per:.4f} s   "
              f"max rod-length error = {1000 * st:7.3f} mm")

mjm = mujoco.MjModel.from_xml_string(PENDULUM_HINGE)
mjd = mujoco.MjData(mjm)
mjd.qpos[0] = TH0
xs = []
for _ in range(round(T / DT)):
    mujoco.mj_step(mjm, mjd)
    xs.append(mjd.geom_xpos[0, 0])
rod = np.linalg.norm(mjd.geom_xpos[0] - mjd.xpos[1])
print(f"(b) reduced coordinate (hinge angle), nq = {mjm.nq}, nv = {mjm.nv}:")
print(f"    period = {period_from(np.array(xs), DT):.4f} s   rod length at the end = {rod:.6f} m")
