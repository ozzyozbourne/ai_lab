"""Example 3.1 - a point mass under gravity: explicit vs semi-implicit Euler, in plain NumPy.

Both methods take the same 200 steps of dt = 0.01 s. Only the ORDER of the two updates differs:
  explicit Euler:       x += v * dt;  v += a * dt     (position uses the OLD velocity)
  semi-implicit Euler:  v += a * dt;  x += v * dt     (position uses the NEW velocity, like MuJoCo)
Run: python ex1_point_mass.py
"""
import numpy as np

np.set_printoptions(precision=4, suppress=True)

G = 9.81          # gravity [m/s^2], pointing down (-z)
M = 1.0           # mass [kg]
Z0, V0 = 20.0, 0.0
DT, T = 0.01, 2.0
NSTEP = round(T / DT)


def energy(z, v):
    """Total mechanical energy = kinetic + potential [J]."""
    return 0.5 * M * v**2 + M * G * z


def explicit_euler(z, v):
    for _ in range(NSTEP):
        a = -G                 # F = m a  ->  a = F / m = -m g / m
        z, v = z + v * DT, v + a * DT     # both right-hand sides use the old (z, v)
    return z, v


def semi_implicit_euler(z, v):
    for _ in range(NSTEP):
        a = -G
        v = v + a * DT         # 1. velocity first ...
        z = z + v * DT         # 2. ... then position with the NEW velocity
    return z, v


z_exact = Z0 + V0 * T - 0.5 * G * T**2
v_exact = V0 - G * T
E0 = energy(Z0, V0)
print(f"{NSTEP} steps of dt = {DT} s, t = {T} s, z0 = {Z0} m")
print(f"analytic      : z = {z_exact:.4f} m   v = {v_exact:.4f} m/s")
for name, fn in [("explicit", explicit_euler), ("semi-implicit", semi_implicit_euler)]:
    z, v = fn(Z0, V0)
    print(f"{name:<14}: z = {z:.4f} m   v = {v:.4f} m/s   "
          f"z error = {z - z_exact:+.4f} m   energy error = {energy(z, v) - E0:+.4f} J")
print(f"predicted |z error| = g*T*dt/2 = {G * T * DT / 2:.4f} m (same size, opposite sign)")
