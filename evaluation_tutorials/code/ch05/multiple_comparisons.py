"""Multiple comparisons: FWER vs FDR with Bonferroni, Holm and Benjamini-Hochberg; rank intervals.

Chapter 5, section 5.7 (#multiple-comparisons).
Run:  python3 code/ch05/multiple_comparisons.py
Shows: (1) 20 benchmarks, no true difference: P(at least one p < 0.05) = 0.64 analytically and by
simulation, and how each correction controls it; (2) 20 benchmarks of which 5 have a real gain:
power and false discovery proportion per method; (3) marginal vs simultaneous (Bonferroni over
pairs) rank ranges for a mock 8-model leaderboard; (4) optional stopping: re-testing after every
seed and stopping at the first |z| > 1.96 inflates the false-positive rate of a null comparison.
"""
from __future__ import annotations

import itertools
import math

import numpy as np

from _common import norm_cdf, norm_ppf

M, ALPHA = 20, 0.05


def bonferroni(p: np.ndarray, alpha: float = ALPHA) -> np.ndarray:
    return p <= alpha / len(p)


def holm(p: np.ndarray, alpha: float = ALPHA) -> np.ndarray:
    """Step-down: compare the i-th smallest p (i = 0..m-1) with alpha / (m - i); stop at first failure."""
    m = len(p)
    order = np.argsort(p)
    reject = np.zeros(m, dtype=bool)
    for i, j in enumerate(order):
        if p[j] <= alpha / (m - i):
            reject[j] = True
        else:
            break
    return reject


def benjamini_hochberg(p: np.ndarray, q: float = ALPHA) -> np.ndarray:
    """Step-up: find the largest i with p_(i) <= i q / m and reject p_(1..i)."""
    m = len(p)
    order = np.argsort(p)
    thresh = q * np.arange(1, m + 1) / m
    below = np.nonzero(p[order] <= thresh)[0]
    reject = np.zeros(m, dtype=bool)
    if len(below):
        reject[order[: below[-1] + 1]] = True
    return reject


def two_sided_p(z: np.ndarray) -> np.ndarray:
    return np.array([2 * (1 - norm_cdf(abs(x))) for x in z])


METHODS = {"none": lambda p: p <= ALPHA, "Bonferroni": bonferroni, "Holm": holm, "BH (FDR)": benjamini_hochberg}


def main() -> None:
    rng = np.random.default_rng(2021)
    print(f"Analytic: P(>=1 false positive among {M} null tests) = 1 - 0.95^{M} = {1 - 0.95**M:.4f}; "
          f"Bonferroni threshold = {ALPHA/M:.4f}")
    assert abs(1 - 0.95**M - 0.6415) < 1e-4

    reps = 10_000
    print(f"\nScenario 1: {M} benchmarks, all null, {reps:,} simulated studies")
    fwer = {k: 0 for k in METHODS}
    for _ in range(reps):
        p = two_sided_p(rng.normal(size=M))
        for k, f in METHODS.items():
            fwer[k] += f(p).any()
    for k in METHODS:
        print(f"  {k:<11} family-wise error rate = {fwer[k]/reps*100:5.1f}%")
    assert abs(fwer["none"] / reps - 0.6415) < 0.02 and fwer["Holm"] / reps < 0.06

    print(f"\nScenario 2: {M} benchmarks, 5 with a real effect (z shift 3.0), {reps:,} studies")
    real = np.zeros(M, dtype=bool)
    real[:5] = True
    stats = {k: [0, 0, 0.0] for k in METHODS}  # true rejections, any-false-rejection, sum FDP
    for _ in range(reps):
        z = rng.normal(size=M) + 3.0 * real
        p = two_sided_p(z)
        for k, f in METHODS.items():
            r = f(p)
            tp, fp = int((r & real).sum()), int((r & ~real).sum())
            stats[k][0] += tp
            stats[k][1] += fp > 0
            stats[k][2] += fp / max(1, tp + fp)
    print(f"  {'method':<11} {'power':>7} {'FWER':>7} {'FDR':>7}")
    for k, (tp, anyfp, fdp) in stats.items():
        print(f"  {k:<11} {tp/(5*reps)*100:6.1f}% {anyfp/reps*100:6.1f}% {fdp/reps*100:6.1f}%")
    assert stats["Holm"][0] >= stats["Bonferroni"][0]
    assert stats["BH (FDR)"][0] > stats["Holm"][0] and stats["BH (FDR)"][2] / reps < 0.05

    print("\nScenario 3: rank ranges for 8 models (score, SE); rank = 1 + #models significantly better")
    scores = np.array([71.0, 70.2, 69.5, 66.0, 65.4, 61.0, 60.5, 52.0])
    ses = np.full(8, 1.1)
    pairs = len(list(itertools.combinations(range(8), 2)))
    for label, z in (("marginal 95%", 1.96), (f"simultaneous ({pairs} pairs)", norm_ppf(1 - ALPHA / (2 * pairs)))):
        ranks = []
        for i in range(8):
            se_d = np.sqrt(ses[i] ** 2 + ses**2)
            better = int(((scores - scores[i]) > z * se_d).sum())
            worse = int(((scores[i] - scores) > z * se_d).sum())
            ranks.append(f"{1 + better}-{8 - worse}")
        print(f"  {label:<26} z={z:.2f}: " + "  ".join(ranks))

    optional_stopping()


def optional_stopping(runs: int = 20_000, max_seeds: int = 30) -> None:
    """Null comparison: per-seed paired difference ~ N(0, 1). Peek after every seed."""
    rng = np.random.default_rng(0)
    d = rng.normal(size=(runs, max_seeds))
    k = np.arange(1, max_seeds + 1)
    z = np.cumsum(d, axis=1) / np.sqrt(k)                 # z after k seeds (known sd = 1)
    peek_all = float((np.abs(z) > 1.96).any(axis=1).mean())
    peek_5 = float((np.abs(z[:, 4:]) > 1.96).any(axis=1).mean())
    once = float((np.abs(z[:, -1]) > 1.96).mean())
    z_bonf = norm_ppf(1 - ALPHA / (2 * max_seeds))
    bonf = float((np.abs(z) > z_bonf).any(axis=1).mean())
    print(f"\nScenario 4: optional stopping, no true difference, {runs:,} simulated studies, up to {max_seeds} seeds")
    print(f"  test after every seed, stop at first |z| > 1.96:   false-positive rate = {peek_all*100:5.1f}%")
    print(f"  same, but first look at seed 5:                   false-positive rate = {peek_5*100:5.1f}%")
    print(f"  one test at the pre-registered K = {max_seeds}:            false-positive rate = {once*100:5.1f}%")
    print(f"  every look, Bonferroni over {max_seeds} looks (z = {z_bonf:.2f}):  false-positive rate = {bonf*100:5.1f}%")
    assert 0.24 < peek_all < 0.32 and 0.17 < peek_5 < 0.25
    assert abs(once - 0.05) < 0.01 and bonf <= 0.05


if __name__ == "__main__":
    main()
