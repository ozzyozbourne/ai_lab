"""How big must an eval set be? Margins, two-arm power, paired designs, rule of three, coverage check.

Chapter 3, section 3.6 (#size). Full treatment of power: Chapter 5.6.
Run:  python3 code/ch03/sample_size.py
Expected key output: 97 / 385 / 1068 / 9604 items for +/-10/5/3/1 points; ~1,247 per arm for
70% vs 75% (unpaired), the same 1,248 when paired independent systems disagree on 40% of items,
and 306 when they disagree on 10%; rule of three; Monte-Carlo coverage near 95%.
"""
from __future__ import annotations

import math
from statistics import NormalDist

import numpy as np

Z = NormalDist().inv_cdf


def n_for_margin(E: float, p: float = 0.5, conf: float = 0.95) -> int:
    z = Z(1 - (1 - conf) / 2)
    return math.ceil(z * z * p * (1 - p) / (E * E))


def n_per_arm(p1: float, p2: float, alpha: float = 0.05, power: float = 0.8, z_round: bool = True) -> float:
    """Two independent proportions. z_round=True uses 1.96 and 0.84 like most textbook tables."""
    za, zb = (1.96, 0.84) if z_round else (Z(1 - alpha / 2), Z(power))
    return (za + zb) ** 2 * (p1 * (1 - p1) + p2 * (1 - p2)) / (p1 - p2) ** 2


def n_paired(p_discordant: float, delta: float, alpha: float = 0.05, power: float = 0.8) -> float:
    """Same items scored by both systems (McNemar-style). Var(d_i) ~ p_disc - delta^2, where
    p_disc = P(A and B disagree on an item). Strongly correlated systems disagree rarely."""
    za, zb = Z(1 - alpha / 2), Z(power)
    return (za + zb) ** 2 * (p_discordant - delta**2) / delta**2


def wilson(k: int, n: int, conf: float = 0.95) -> tuple[float, float]:
    z = Z(1 - (1 - conf) / 2)
    p = k / n
    c = (p + z * z / (2 * n)) / (1 + z * z / n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return c - h, c + h


def rule_of_three(n: int) -> float:
    return 3 / n


def coverage(p: float, n: int, reps: int, rng: np.random.Generator) -> tuple[float, float]:
    k = rng.binomial(n, p, reps)
    ph = k / n
    se = np.sqrt(ph * (1 - ph) / n)
    wald = np.mean((ph - 1.96 * se <= p) & (p <= ph + 1.96 * se))
    w = np.array([wilson(int(x), n) for x in k])
    return float(wald), float(np.mean((w[:, 0] <= p) & (p <= w[:, 1])))


if __name__ == "__main__":
    print("items needed for a 95% margin of error (worst case p = 0.5)")
    table = {E: n_for_margin(E) for E in (0.10, 0.05, 0.03, 0.01)}
    for E, n in table.items():
        print(f"  +/-{E * 100:4.0f} points: {n:6d}")
    assert table == {0.10: 97, 0.05: 385, 0.03: 1068, 0.01: 9604}

    n75 = n_per_arm(0.70, 0.75)
    n80 = n_per_arm(0.70, 0.80)
    print(f"\nunpaired, 80% power, alpha 0.05: 70% vs 75% -> {math.ceil(n75):,} per arm; 70% vs 80% -> {math.ceil(n80):,}")
    assert math.ceil(n75) == 1247 and math.ceil(n80) == 291

    print("\npaired (same items, both systems): items needed to detect +5 points")
    for disc in (0.40, 0.20, 0.10):
        tag = "  (independent systems)" if disc == 0.40 else ""
        print(f"  systems disagree on {disc:.0%} of items -> {n_paired(disc, 0.05):6.0f} items{tag}")
    # independent 70% and 75% systems disagree on 0.7*0.25 + 0.3*0.75 = 0.40 of items: no gain from pairing
    assert abs(n_paired(0.40, 0.05) - n_per_arm(0.70, 0.75, z_round=False)) < 2
    assert n_paired(0.10, 0.05) < n75 / 3

    print("\nrule of three (0 failures observed): 95% upper bound on the failure rate")
    for n in (30, 100, 300, 1000):
        exact = 1 - 0.05 ** (1 / n)
        print(f"  n = {n:5d}: 3/n = {rule_of_three(n):.4f}   exact (1 - 0.05^(1/n)) = {exact:.4f}")
    assert abs(rule_of_three(300) - 0.01) < 1e-12

    print("\nper-slice budget: 10 slices at +/-10 points ->", 10 * n_for_margin(0.10), "items")

    rng = np.random.default_rng(5)
    print(f"\nMonte-Carlo coverage of nominal 95% intervals (20,000 replications)")
    print(f"  {'p':>5}{'n':>6}{'Wald':>8}{'Wilson':>8}")
    cov = {}
    for p, n in ((0.5, 385), (0.8, 385), (0.95, 50), (0.99, 100)):
        cov[(p, n)] = coverage(p, n, 20_000, rng)
        print(f"  {p:5.2f}{n:6d}{cov[(p, n)][0]:8.3f}{cov[(p, n)][1]:8.3f}")
    assert abs(cov[(0.5, 385)][0] - 0.95) < 0.01          # Wald is fine in the middle
    assert cov[(0.99, 100)][0] < 0.9 < cov[(0.99, 100)][1]  # and breaks near the edge; Wilson holds
    print("\nall checks passed")
