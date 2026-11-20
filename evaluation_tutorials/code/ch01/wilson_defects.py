"""An eval score is an estimate: normal vs Wilson intervals, and how many items you need.

Chapter 1, section 1.6. Full treatment (clustered SE, paired tests, power, bootstrap): Chapter 5.
Run:  python3 code/ch01/wilson_defects.py
Expected key output:
  78% on 200 items  -> normal 95% CI [72.3%, 83.7%]
  3% defects on 200 -> normal [0.6%, 5.4%], Wilson [1.4%, 6.4%]: cannot certify a 5% limit
  detect a 3-point gap (variance of A=80%, B=75%, rho=0.5) -> ~1,518 paired / ~3,027 unpaired items
"""
from __future__ import annotations

import math

Z = 1.96            # two-sided 95%
Z_POWER = 0.84      # one-sided 80% power (the rounded value used in dossier 01 and Miller 2024)


def normal_ci(p: float, n: int) -> tuple[float, float]:
    half = Z * math.sqrt(p * (1 - p) / n)
    return p - half, p + half


def wilson_ci(p: float, n: int) -> tuple[float, float]:
    denom = 1 + Z**2 / n
    centre = (p + Z**2 / (2 * n)) / denom
    half = Z * math.sqrt(p * (1 - p) / n + Z**2 / (4 * n**2)) / denom
    return centre - half, centre + half


def n_for_difference(var_d: float, delta: float) -> float:
    """Items needed to detect a mean difference delta (alpha=0.05 two-sided, power 0.8)."""
    return (Z + Z_POWER) ** 2 * var_d / delta**2


def pct(x: tuple[float, float]) -> str:
    return f"[{100 * x[0]:.1f}%, {100 * x[1]:.1f}%]"


if __name__ == "__main__":
    lo, hi = normal_ci(0.78, 200)
    print(f"accuracy 78% on n=200: SE={math.sqrt(0.78 * 0.22 / 200):.4f}, normal 95% CI {pct((lo, hi))}")

    p, n, limit = 0.03, 200, 0.05
    nci, wci = normal_ci(p, n), wilson_ci(p, n)
    print(f"\ndefect rate 3% on n={n}, requirement <= {limit:.0%}")
    print(f"  normal (Wald) 95% CI {pct(nci)}   upper bound above limit? {nci[1] > limit}")
    print(f"  Wilson        95% CI {pct(wci)}   upper bound above limit? {wci[1] > limit}")
    for m in (400, 800, 1600):
        print(f"  n={m:<5} normal margin = +/-{100 * Z * math.sqrt(p * (1 - p) / m):.2f} pp,"
              f" Wilson upper = {100 * wilson_ci(p, m)[1]:.2f}%")

    # Power: assumptions exactly as dossier 01 sec 2.3(d)-(e): model A 80%, model B 75%,
    # per-item Bernoulli variances, correlation rho = 0.5 between the models' item scores,
    # and we want to detect a 3-point difference using that variance of d_i = s_A,i - s_B,i.
    pa, pb, rho, delta = 0.80, 0.75, 0.5, 0.03
    va, vb = pa * (1 - pa), pb * (1 - pb)
    var_paired = va + vb - 2 * rho * math.sqrt(va * vb)
    var_unpaired = va + vb
    n_p, n_u = n_for_difference(var_paired, delta), n_for_difference(var_unpaired, delta)
    print(f"\nVar(d) paired = {var_paired:.4f}, unpaired = {var_unpaired:.4f}")
    print(f"items to detect a 3-point gap: paired ~{n_p:,.0f}, unpaired ~{n_u:,.0f}")

    assert abs(lo - 0.723) < 1e-3 and abs(hi - 0.837) < 1e-3
    assert abs(nci[0] - 0.006) < 1e-3 and abs(nci[1] - 0.054) < 1e-3
    assert abs(wci[0] - 0.014) < 1e-3 and abs(wci[1] - 0.064) < 1e-3
    assert round(n_p) == 1518 and round(n_u) == 3027
