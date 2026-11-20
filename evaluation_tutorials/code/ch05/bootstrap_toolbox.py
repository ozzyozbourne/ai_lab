"""The bootstrap toolbox: percentile, basic and BCa intervals; stratified/cluster/paired resampling; seeding.

Chapter 5, section 5.8 (#bootstrap).
Run:  python3 code/ch05/bootstrap_toolbox.py
Shows: (1) three interval types for the mean and the median of a skewed per-item metric (n = 40);
(2) coverage of the percentile bootstrap vs Wilson for a mean of n = 30 binary scores;
(3) a stratified bootstrap over unequal subtasks; (4) the unseeded-bootstrap pitfall and the
Monte Carlo error of a 2.5% quantile for B = 200, 1,000 and 10,000 replicates.
"""
from __future__ import annotations

import math

import numpy as np

from _common import norm_cdf, norm_ppf, wilson


def boot_stats(x: np.ndarray, stat, rng: np.random.Generator, b: int) -> np.ndarray:
    idx = rng.integers(0, len(x), size=(b, len(x)))
    return np.array([stat(x[i]) for i in idx])


def intervals(x: np.ndarray, stat, rng: np.random.Generator, b: int = 10_000, alpha: float = 0.05) -> dict[str, tuple[float, float]]:
    theta = stat(x)
    t = boot_stats(x, stat, rng, b)
    lo_q, hi_q = np.quantile(t, [alpha / 2, 1 - alpha / 2])
    out = {"percentile": (lo_q, hi_q), "basic": (2 * theta - hi_q, 2 * theta - lo_q)}
    # BCa: bias correction z0 from the share of replicates below theta, acceleration from the jackknife
    z0 = norm_ppf(min(max((t < theta).mean(), 1e-6), 1 - 1e-6))
    jack = np.array([stat(np.delete(x, i)) for i in range(len(x))])
    dj = jack.mean() - jack
    acc = (dj**3).sum() / (6 * ((dj**2).sum()) ** 1.5 + 1e-300)
    qs = []
    for z in (norm_ppf(alpha / 2), norm_ppf(1 - alpha / 2)):
        qs.append(norm_cdf(z0 + (z0 + z) / (1 - acc * (z0 + z))))
    out["BCa"] = tuple(np.quantile(t, qs))
    return out


def main() -> None:
    rng = np.random.default_rng(123)
    x = rng.lognormal(mean=-1.0, sigma=1.0, size=40)   # e.g. a per-item continuous quality score
    print(f"(1) Skewed metric, n = 40: mean = {x.mean():.3f}, median = {np.median(x):.3f}, B = 10,000")
    for name, stat in (("mean", np.mean), ("median", np.median)):
        res = intervals(x, stat, np.random.default_rng(1))
        print(f"  {name:<6} " + "  ".join(f"{k}=[{a:.3f}, {b:.3f}]" for k, (a, b) in res.items()))

    print("\n(2) Coverage for a mean of n = 30 binary scores (p = 0.85), 2,000 simulated evals, B = 2,000")
    crng = np.random.default_rng(9)
    cov_b = cov_w = 0
    reps = 2000
    for _ in range(reps):
        s = (crng.random(30) < 0.85).astype(float)
        idx = crng.integers(0, 30, size=(2000, 30))
        lo, hi = np.quantile(s[idx].mean(axis=1), [0.025, 0.975])
        cov_b += lo <= 0.85 <= hi
        wl, wh = wilson(int(s.sum()), 30)
        cov_w += wl <= 0.85 <= wh
    print(f"  percentile bootstrap: {cov_b/reps*100:.1f}%   Wilson: {cov_w/reps*100:.1f}%")
    assert cov_b / reps < cov_w / reps

    print("\n(3) Stratified bootstrap over subtasks of very different size (400, 60 and 3 items)")
    srng = np.random.default_rng(4)
    sizes, accs = [400, 60, 3], [0.80, 0.55, 0.30]
    subtasks = [(srng.random(n) < p).astype(float) for n, p in zip(sizes, accs)]

    def macro(parts: list[np.ndarray]) -> float:
        """Macro-average over subtasks (undefined if a subtask is empty)."""
        return float(np.mean([p.mean() for p in parts])) if all(len(p) for p in parts) else float("nan")

    brng = np.random.default_rng(5)
    strat = [macro([p[brng.integers(0, len(p), len(p))] for p in subtasks]) for _ in range(4000)]
    pooled = np.concatenate(subtasks)
    labels = np.concatenate([np.full(len(p), j) for j, p in enumerate(subtasks)])
    naive = []
    for _ in range(4000):
        i = brng.integers(0, len(pooled), len(pooled))
        naive.append(macro([pooled[i][labels[i] == j] for j in range(3)]))
    naive = np.array(naive)
    print(f"  macro accuracy = {macro(subtasks):.3f}; stratified-bootstrap SE = {np.std(strat):.4f} (0 undefined replicates)")
    print(f"  unstratified: {np.isnan(naive).mean()*100:.1f}% of replicates drop the 3-item subtask entirely; "
          f"SE over the rest = {np.nanstd(naive):.4f}")
    assert not np.isnan(strat).any() and np.isnan(naive).mean() > 0.02

    print("\n(4) Seeding and replicate count")
    vals = np.random.default_rng(8).beta(2.0, 1.0, size=200)   # continuous per-item scores
    unseeded = [np.std([np.mean(np.random.choice(vals, len(vals))) for _ in range(1000)]) for _ in range(3)]
    print(f"  unseeded simple-evals-style bootstrap_std, three calls all different: {len(set(unseeded)) == 3}")
    def seeded_std(seed: int) -> float:
        r = np.random.default_rng(seed)
        return float(np.std(vals[r.integers(0, len(vals), size=(1000, len(vals)))].mean(axis=1)))
    print(f"  seeded (seed 0), three calls: {seeded_std(0):.5f}, {seeded_std(0):.5f}, {seeded_std(0):.5f}")
    print(f"  analytic SE (ddof=1) = {vals.std(ddof=1)/math.sqrt(len(vals)):.5f}; without Bessel = {vals.std()/math.sqrt(len(vals)):.5f}")
    assert seeded_std(0) == seeded_std(0)
    for b in (200, 1000, 10_000):
        qs = []
        for s in range(200):
            r = np.random.default_rng(1000 + s)
            qs.append(np.quantile(vals[r.integers(0, len(vals), size=(b, len(vals)))].mean(axis=1), 0.025))
        print(f"  B = {b:>6}: 2.5% quantile = {np.mean(qs):.4f} +/- {np.std(qs):.4f} (Monte Carlo sd over 200 seeds)")


if __name__ == "__main__":
    main()
