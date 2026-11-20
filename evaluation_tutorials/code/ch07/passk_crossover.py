"""pass@k curves that cross: an RL-sharpened model wins at k = 1 and loses at large k.

Section 7.9 (#llm-policy-metrics) of Chapter 7, Figure 7.7.  Run:  python3 code/ch07/passk_crossover.py

A mock of the pattern Yue et al. (arXiv:2504.13837) report. 500 problems, per-problem solve probabilities:
  base : p ~ Beta(0.35, 1.2) on 85% of problems, 0 on the rest (diverse but unreliable sampling)
  rl   : "sharpened" base: p_rl = p_base ** 0.25 where p_base >= 0.03, and 0 where the base model solved the
         problem only rarely (p_base < 0.03): RL raised reliability on what it already could do, and stopped
         sampling the rare correct paths.
Reports exact expected pass@k = mean_i[1 - (1 - p_i)^k], the unbiased estimator from n = 256 samples per problem
(Chen et al.), pass^k = mean_i[p_i^k], and the crossover k.
Expected key output: RL wins pass@1 (0.374 vs 0.170) but the base model overtakes it at k = 26 and is ahead at
k = 256 (0.687 vs 0.540, the RL model's coverage ceiling); RL is far ahead on pass^k at every k.
"""
from __future__ import annotations

import math

import numpy as np

KS = [1, 2, 4, 8, 16, 32, 64, 128, 256]


def models(rng: np.random.Generator, n_problems: int = 500) -> tuple[np.ndarray, np.ndarray]:
    p_base = np.where(rng.random(n_problems) < 0.85, rng.beta(0.35, 1.2, n_problems), 0.0)
    p_rl = np.where(p_base >= 0.03, p_base ** 0.25, 0.0)
    return p_base, p_rl


def pass_at_k_exact(p: np.ndarray, k: int) -> float:
    return float(np.mean(1 - (1 - p) ** k))


def pass_hat_k_exact(p: np.ndarray, k: int) -> float:
    return float(np.mean(p ** k))


def pass_at_k_unbiased(n: int, c: int, k: int) -> float:
    if n - c < k:
        return 1.0
    return 1.0 - math.comb(n - c, k) / math.comb(n, k)


def main() -> None:
    rng = np.random.default_rng(0)
    p_base, p_rl = models(rng)
    n = 256
    c_base = rng.binomial(n, p_base)
    c_rl = rng.binomial(n, p_rl)
    print(f"{'k':>4} | {'base pass@k':>11} {'(est.)':>7} | {'RL pass@k':>9} {'(est.)':>7} | {'base pass^k':>11} {'RL pass^k':>9}")
    rows = []
    for k in KS:
        b, r = pass_at_k_exact(p_base, k), pass_at_k_exact(p_rl, k)
        be = np.mean([pass_at_k_unbiased(n, int(c), k) for c in c_base])
        re_ = np.mean([pass_at_k_unbiased(n, int(c), k) for c in c_rl])
        hat = f"{pass_hat_k_exact(p_base, k):11.3f} {pass_hat_k_exact(p_rl, k):9.3f}" if k <= 16 else f"{'-':>11} {'-':>9}"
        rows.append((k, b, r))
        print(f"{k:>4} | {b:11.3f} {be:7.3f} | {r:9.3f} {re_:7.3f} | {hat}")
    cross = next(k for k in range(1, 257) if pass_at_k_exact(p_base, k) > pass_at_k_exact(p_rl, k))
    print(f"\ncrossover: base model first ahead at k = {cross}")
    print(f"coverage (pass@inf = share of problems with p > 0): base {np.mean(p_base > 0):.3f}, RL {np.mean(p_rl > 0):.3f}")
    grid = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256]
    print("fig7.7 k   : " + " ".join(map(str, grid)))
    print("fig7.7 base: " + " ".join(f"{pass_at_k_exact(p_base, k):.3f}" for k in grid))
    print("fig7.7 rl  : " + " ".join(f"{pass_at_k_exact(p_rl, k):.3f}" for k in grid))
    assert rows[0][2] > rows[0][1] + 0.2           # RL wins pass@1
    assert rows[-1][1] > rows[-1][2]               # base wins pass@256
    assert cross == 26 and abs(rows[0][1] - 0.170) < 1e-3 and abs(rows[0][2] - 0.374) < 1e-3


if __name__ == "__main__":
    main()
