"""Drift monitoring for an LLM feature: PSI on topics, KS on lengths, embedding-centroid drift,
CUSUM/EWMA on daily judge scores, and a judge-drift check on a frozen anchor set.

Chapter 9, section 9.18 (Drift detection and evolving eval sets).
  PSI  = sum_i (a_i - e_i) ln(a_i / e_i)       (heuristic: < 0.1 stable, 0.1-0.25 moderate, > 0.25 major)
  KS   = max_x |F_a(x) - F_b(x)|                (two-sample, asymptotic p-value)
  CUSUM: S_t = max(0, S_{t-1} + (mu_0 - x_t) - k); alarm when S_t > h
Run:  python3 code/ch09/drift_monitor.py
Expected key output: PSI 0.228 for [.25,.25,.25,.25] -> [.10,.20,.30,.40]; weekly PSI crosses 0.1
in week 6; KS flags a 20% length shift (D 0.164); the centroid cosine distance jumps in week 6; after a
silent 2-point drop on day 40 CUSUM alarms on day 48, EWMA on 53, a single-day 3-sigma rule on 54;
a judge upgrade moves the frozen anchor set by +7.5 points with no system change.
"""
from __future__ import annotations

import math

import numpy as np


def psi(expected: np.ndarray, actual: np.ndarray, eps: float = 1e-6) -> float:
    e, a = np.clip(expected, eps, None), np.clip(actual, eps, None)
    return float(np.sum((a - e) * np.log(a / e)))


def ks_2samp(x: np.ndarray, y: np.ndarray) -> tuple[float, float]:
    xs, ys = np.sort(x), np.sort(y)
    grid = np.concatenate([xs, ys])
    d = float(np.max(np.abs(np.searchsorted(xs, grid, "right") / len(xs)
                            - np.searchsorted(ys, grid, "right") / len(ys))))
    ne = len(x) * len(y) / (len(x) + len(y))
    lam = (math.sqrt(ne) + 0.12 + 0.11 / math.sqrt(ne)) * d
    p = 2 * sum((-1) ** (j - 1) * math.exp(-2 * j * j * lam * lam) for j in range(1, 101))
    return d, min(1.0, max(0.0, p))


def cusum_down(x: np.ndarray, mu0: float, k: float, h: float) -> int | None:
    s = 0.0
    for t, v in enumerate(x):
        s = max(0.0, s + (mu0 - v) - k)
        if s > h:
            return t
    return None


def ewma_alarm(x: np.ndarray, mu0: float, sigma: float, lam: float = 0.2, L: float = 3.0) -> int | None:
    z = mu0
    limit = L * sigma * math.sqrt(lam / (2 - lam))
    for t, v in enumerate(x):
        z = lam * v + (1 - lam) * z
        if z < mu0 - limit:
            return t
    return None


if __name__ == "__main__":
    rng = np.random.default_rng(12)
    w = psi(np.array([.25, .25, .25, .25]), np.array([.10, .20, .30, .40]))
    print(f"worked PSI = {w:.3f}")
    assert abs(w - 0.228) < 1e-3

    base = np.array([.25, .25, .25, .25])                      # topic mix in the eval set
    print("\nweekly topic mix (billing, returns, shipping, new-product) and PSI vs the eval set")
    weeks = {}
    for wk in range(1, 9):
        shift = min(1.0, (wk - 1) / 6)                         # new product launch ramps up
        target = (1 - shift) * base + shift * np.array([.10, .20, .30, .40])
        counts = rng.multinomial(3000, target)
        weeks[wk] = psi(base, counts / counts.sum())
        flag = "major" if weeks[wk] > 0.25 else "moderate" if weeks[wk] > 0.1 else "stable"
        print(f"  week {wk}: {np.round(counts / counts.sum(), 3)}  PSI {weeks[wk]:.3f}  {flag}")

    ref_len = rng.lognormal(np.log(180), 0.5, 2000)
    same_len = rng.lognormal(np.log(180), 0.5, 2000)
    new_len = rng.lognormal(np.log(215), 0.5, 2000)            # answers got ~20% longer
    d0, p0 = ks_2samp(ref_len, same_len)
    d1, p1 = ks_2samp(ref_len, new_len)
    print(f"\nKS on response length: no change D = {d0:.3f} (p = {p0:.2f}); after change D = {d1:.3f} (p = {p1:.1e})")

    dim = 64
    topic_dirs = rng.standard_normal((5, dim))
    ref_centroid = None
    print("\nembedding centroid cosine distance vs week 1")
    cos_d = {}
    for wk in range(1, 9):
        mix = np.array([.3, .3, .2, .2, 0.0]) if wk < 6 else np.array([.15, .15, .1, .1, .5])
        topics = rng.choice(5, size=1000, p=mix)
        emb = topic_dirs[topics] + 0.8 * rng.standard_normal((1000, dim))
        c = emb.mean(axis=0)
        if ref_centroid is None:
            ref_centroid = c
        cos_d[wk] = max(0.0, 1 - float(c @ ref_centroid / (np.linalg.norm(c) * np.linalg.norm(ref_centroid))))
        print(f"  week {wk}: {cos_d[wk]:.4f}")

    days = np.arange(60)
    judge_mean = np.where(days < 40, 0.85, 0.83) + rng.normal(0, 0.02, 60)   # silent provider update
    sd = 0.02
    t_c = cusum_down(judge_mean, 0.85, k=0.5 * sd, h=4 * sd)
    t_e = ewma_alarm(judge_mean, 0.85, sd)
    naive = next((t for t, v in enumerate(judge_mean) if v < 0.85 - 3 * sd), None)
    print(f"\ndaily judge faithfulness, true drop 0.85 -> 0.83 on day 40: CUSUM alarm day {t_c}, "
          f"EWMA alarm day {t_e}, single-day 3-sigma rule day {naive}")

    anchor_truth = rng.random(200) < 0.8                       # frozen, human-labelled anchor outputs
    judge_v1 = np.where(anchor_truth, rng.random(200) < 0.95, rng.random(200) < 0.20)
    judge_v2 = np.where(anchor_truth, rng.random(200) < 0.97, rng.random(200) < 0.45)   # more lenient
    print(f"anchor set (outputs frozen): human {anchor_truth.mean():.3f}, judge v1 {judge_v1.mean():.3f}, judge v2 {judge_v2.mean():.3f}"
          f" -> a {100 * (judge_v2.mean() - judge_v1.mean()):+.1f}-point move with no system change")

    assert weeks[1] < 0.1 and weeks[8] > 0.2
    assert p0 > 0.05 and p1 < 1e-6
    assert cos_d[6] > 5 * max(cos_d[2], cos_d[5])
    assert t_c is not None and 40 <= t_c <= 55
