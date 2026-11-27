"""Example 3.2 - a 1-D mass-spring: explicit Euler gains energy, semi-implicit Euler stays bounded.

The spring has period 1 s (omega = 2 pi). For dt in {0.01, 0.05, 0.2} both methods run 10 s and we
print the largest energy ratio E(t) / E(0). Exact physics keeps the ratio at 1.
Run: python ex2_spring_oscillator.py [--dump-json PATH]
  --dump-json PATH writes (x, v) phase-portrait traces for the page's figure (Rule D).
"""
import argparse
import json

import numpy as np

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()   # parse_known_args: also works inside Jupyter

M = 1.0
K = (2 * np.pi) ** 2      # stiffness so that omega = sqrt(K / M) = 2 pi rad/s (period 1 s)
X0, V0 = 1.0, 0.0
T = 10.0
DTS = [0.01, 0.05, 0.2]


def energy(x, v):
    return 0.5 * M * v**2 + 0.5 * K * x**2


def simulate(dt, semi_implicit):
    x, v = X0, V0
    xs, vs = [x], [v]
    for _ in range(round(T / dt)):
        a = -K * x / M                    # Hooke's law F = -k x, then a = F / m
        if semi_implicit:
            v = v + a * dt
            x = x + v * dt
        else:
            x, v = x + v * dt, v + a * dt
        xs.append(x)
        vs.append(v)
    return np.array(xs), np.array(vs)


E0 = energy(X0, V0)
dump = {"omega": 2 * np.pi, "runs": []}
print(f"omega = {np.sqrt(K / M):.4f} rad/s, T = {T} s, E0 = {E0:.4f} J")
print(f"{'dt':>6} {'omega*dt':>9} {'explicit max E/E0':>18} {'semi-implicit max E/E0':>23}")
for dt in DTS:
    ex = simulate(dt, semi_implicit=False)
    si = simulate(dt, semi_implicit=True)
    r_ex = energy(*ex).max() / E0
    r_si = energy(*si).max() / E0
    print(f"{dt:>6} {np.sqrt(K / M) * dt:>9.3f} {r_ex:>18.4g} {r_si:>23.4f}")
    # keep the first 3 s for the figure; at most ~150 points per trace
    n = round(3.0 / dt) + 1
    step = max(1, n // 150)
    dump["runs"].append({
        "dt": dt,
        "explicit": [[round(float(a), 3), round(float(b), 3)]
                     for a, b in zip(ex[0][:n:step], ex[1][:n:step])],
        "semi": [[round(float(a), 3), round(float(b), 3)]
                 for a, b in zip(si[0][:n:step], si[1][:n:step])],
    })

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump(dump, f, separators=(",", ":"))
    print("wrote", args.dump_json)
