"""Power analysis and minimum detectable effect (Miller 2024 formulas) with a simulation check.

Chapter 5, section 5.6 (#power) and Figure 5.4.
Run:  python3 code/ch05/power.py
Shows: questions needed to detect a 3-point gain at 80% power (4,361 / 2,181 / 873 for
correlation 0, 0.5, 0.8); an MDE table over n, rho and K; a Monte Carlo check that the
paired z-test really has ~80% power at those n; and MDE-vs-n curves for Figure 5.4.
"""
from __future__ import annotations

import math

import numpy as np

from _common import norm_ppf

Z_A = norm_ppf(1 - 0.05 / 2)   # 1.95996
Z_B = norm_ppf(0.80)           # 0.84162


def n_required(delta: float, omega2: float, sa2: float = 0.0, sb2: float = 0.0, ka: int = 1, kb: int = 1) -> int:
    """Miller: n = (z_{a/2} + z_b)^2 (omega^2 + sA^2/KA + sB^2/KB) / delta^2, rounded up."""
    return math.ceil((Z_A + Z_B) ** 2 * (omega2 + sa2 / ka + sb2 / kb) / delta**2)


def mde(n: int, omega2: float, sa2: float = 0.0, sb2: float = 0.0, ka: int = 1, kb: int = 1) -> float:
    return (Z_A + Z_B) * math.sqrt((omega2 + sa2 / ka + sb2 / kb) / n)


def correlated_pairs(rng: np.random.Generator, n: int, pa: float, pb: float, rho: float) -> tuple[np.ndarray, np.ndarray]:
    """Binary score pairs with given means and Pearson correlation (via the 2x2 joint table)."""
    cov = rho * math.sqrt(pa * (1 - pa) * pb * (1 - pb))
    p11 = pa * pb + cov
    p10, p01 = pa - p11, pb - p11
    u = rng.random(n)
    a = (u < p11 + p10).astype(float)
    b = ((u < p11) | ((u >= p11 + p10) & (u < p11 + p10 + p01))).astype(float)
    return a, b


def simulated_power(n: int, rho: float, paired: bool, reps: int = 4000, seed: int = 3) -> float:
    rng = np.random.default_rng(seed)
    hits = 0
    for _ in range(reps):
        a, b = correlated_pairs(rng, n, 0.515, 0.485, rho)
        d = a - b
        se = d.std(ddof=1) / math.sqrt(n) if paired else math.sqrt((a.var(ddof=1) + b.var(ddof=1)) / n)
        hits += abs(d.mean()) / se > Z_A
    return hits / reps


def main() -> None:
    print(f"z_(alpha/2) = {Z_A:.4f}, z_beta = {Z_B:.4f}")
    print("Questions needed for a 3-point gain at 80% power (accuracy ~50%, Var = 0.25 per model, K = 1, sigma^2 = 0):")
    need = {}
    for rho in (0.0, 0.5, 0.8):
        omega2 = 0.25 + 0.25 - 2 * rho * 0.25
        need[rho] = n_required(0.03, omega2)
        print(f"  rho = {rho:.1f}: omega^2 = {omega2:.2f} -> n = {need[rho]:,}")
    assert need == {0.0: 4361, 0.5: 2181, 0.8: 873}
    miller = n_required(0.03, 1 / 9)
    print(f"  Miller's example (omega^2 = 1/9, sigma^2 = 0): n = {miller:,}")
    assert miller == 969

    print("\nMonte Carlo check (4,000 simulated evals each, true gain 3 points, paired z-test at alpha = 0.05):")
    checks = [(4361, 0.0, True), (873, 0.8, True), (873, 0.8, False)]
    for n, rho, paired in checks:
        pw = simulated_power(n, rho, paired)
        print(f"  n = {n:>5}, rho = {rho:.1f}, {'paired  ' if paired else 'unpaired'} test: power = {pw*100:.1f}%")
        if paired:
            assert abs(pw - 0.80) < 0.03
        else:
            assert pw < 0.35

    # MDE table: split each model's per-answer variance 0.25 into between-question Var(x)=0.10
    # and within-question sigma^2=0.15; rho is the correlation of the two models' question means.
    vx, s2 = 0.10, 0.15
    print("\nMDE (points, 80% power, alpha 0.05). Var(x) = 0.10 between, sigma^2 = 0.15 within, per model")
    header = "  " + f"{'n':>5}" + "".join(f"  rho={r:.1f},K={k:<2}" for r in (0.0, 0.5, 0.8) for k in (1, 4, 16))
    print(header)
    table = {}
    for n in (100, 300, 1000, 3000):
        row = []
        for r in (0.0, 0.5, 0.8):
            for k in (1, 4, 16):
                v = mde(n, 2 * vx * (1 - r), s2, s2, k, k) * 100
                table[(n, r, k)] = v
                row.append(f"{v:15.1f}")
        print(f"  {n:>5}" + "".join(row))
    assert abs(table[(1000, 0.0, 1)] - 6.26) < 0.01

    print("\nFigure 5.4 data: MDE (points) vs n, K = 1, sigma^2 = 0, Var = 0.25 per model")
    for n in (50, 100, 200, 500, 1000, 2000, 5000, 10000):
        print(f"  n = {n:>5}: " + "  ".join(f"rho={r:.1f}: {mde(n, 0.5 - 0.5 * r)*100:5.1f}" for r in (0.0, 0.5, 0.8)))


if __name__ == "__main__":
    main()
