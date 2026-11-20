"""Sampling production traffic: SRS, proportional stratified, oversample-and-reweight, failure-biased.

Chapter 3, section 3.4 (#sampling), Figure 3.1.
Run:  python3 code/ch03/stratified_sampler.py
Expected key output: the worked example (pooled 75%, weighted 84%, SE 0.0259, +/-5.1 points);
over 1,000 repetitions every design except 'oversample, pooled' and 'failure-biased' is unbiased,
and oversampling the legal slice cuts the SD of its estimate roughly in half.
"""
from __future__ import annotations

import math

import numpy as np

SEED = 7
SHARES = {"faq": 0.7, "billing": 0.2, "legal": 0.1}
TRUE_PASS = {"faq": 0.92, "billing": 0.78, "legal": 0.55}   # mock per-intent pass probabilities
BUDGET = 300                                                 # traces we can afford to label


def worked_example() -> tuple[float, float, float]:
    """Dossier 03: 80% FAQ / 20% billing, 100 labelled each, 90 and 60 passes."""
    w, p, n = np.array([0.8, 0.2]), np.array([0.9, 0.6]), np.array([100, 100])
    pooled = (90 + 60) / 200
    weighted = float(w @ p)
    se = math.sqrt(float(np.sum(w**2 * p * (1 - p) / n)))
    return pooled, weighted, se


def make_logs(rng: np.random.Generator, n: int = 10_000) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    names = list(SHARES)
    intent = rng.choice(len(names), size=n, p=list(SHARES.values()))
    passed = rng.random(n) < np.array([TRUE_PASS[k] for k in names])[intent]
    # thumbs-down is much more likely on failures: the signal failure-biased sampling uses
    thumbs_down = rng.random(n) < np.where(passed, 0.03, 0.40)
    return intent, passed.astype(float), thumbs_down


def stratified_estimate(intent, passed, idx_by_h, weights) -> tuple[float, list[float]]:
    per = [passed[ix].mean() for ix in idx_by_h]
    return float(np.dot(weights, per)), per


def one_rep(rng, intent, passed, thumbs, W) -> dict[str, tuple[float, float]]:
    """Returns {design: (overall estimate, legal-slice estimate)}."""
    H = len(W)
    pools = [np.flatnonzero(intent == h) for h in range(H)]
    out = {}
    # 1. simple random sample
    s = rng.choice(len(intent), BUDGET, replace=False)
    legal = s[intent[s] == 2]
    out["SRS"] = (passed[s].mean(), passed[legal].mean() if len(legal) else np.nan)
    # 2. proportional stratified: n_h = n * W_h  (210 / 60 / 30)
    n_prop = np.round(BUDGET * W).astype(int)
    idx = [rng.choice(pools[h], n_prop[h], replace=False) for h in range(H)]
    est, per = stratified_estimate(intent, passed, idx, W)
    out["proportional"] = (est, per[2])
    # 3. equal allocation (oversample rare slices) + reweight by W_h
    idx = [rng.choice(pools[h], BUDGET // H, replace=False) for h in range(H)]
    est, per = stratified_estimate(intent, passed, idx, W)
    out["oversample+reweight"] = (est, per[2])
    # 4. same sample, but pooled without weights (the common mistake)
    allidx = np.concatenate(idx)
    out["oversample, pooled"] = (passed[allidx].mean(), per[2])
    # 5. failure-biased: label only thumbs-down traces (great for finding bugs, useless for rates)
    flagged = np.flatnonzero(thumbs)
    s = rng.choice(flagged, BUDGET, replace=False)
    legal = s[intent[s] == 2]
    out["failure-biased"] = (passed[s].mean(), passed[legal].mean())
    return out


if __name__ == "__main__":
    pooled, weighted, se = worked_example()
    print(f"worked example: pooled {pooled:.0%}, weighted {weighted:.0%}, SE {se:.4f}, "
          f"95% CI {weighted:.0%} +/- {1.96 * se * 100:.1f} points")
    assert abs(weighted - 0.84) < 1e-12 and abs(se - 0.0259) < 1e-4 and abs(1.96 * se - 0.051) < 1e-3

    rng = np.random.default_rng(SEED)
    intent, passed, thumbs = make_logs(rng)
    W = np.array([np.mean(intent == h) for h in range(3)])
    truth = float(passed.mean())
    truth_legal = float(passed[intent == 2].mean())
    print(f"\n10,000 mock logs: shares {np.round(W, 3).tolist()}, population pass rate {truth:.4f}, "
          f"legal slice {truth_legal:.4f}, thumbs-down {thumbs.sum()}")

    reps = [one_rep(rng, intent, passed, thumbs, W) for _ in range(1000)]
    print(f"\n{'design (n=300)':<22}{'mean':>8}{'bias':>8}{'SD':>8}{'legal mean':>12}{'legal SD':>10}")
    stats = {}
    for d in reps[0]:
        o = np.array([r[d][0] for r in reps])
        lg = np.array([r[d][1] for r in reps])
        stats[d] = (o.mean() - truth, o.std(), np.nanmean(lg) - truth_legal, np.nanstd(lg))
        print(f"{d:<22}{o.mean():8.4f}{o.mean() - truth:+8.4f}{o.std():8.4f}"
              f"{np.nanmean(lg):12.4f}{np.nanstd(lg):10.4f}")

    for d in ("SRS", "proportional", "oversample+reweight"):
        assert abs(stats[d][0]) < 0.005, d                     # unbiased overall
    assert stats["oversample, pooled"][0] < -0.03               # pooled oversample is biased low
    assert stats["failure-biased"][0] < -0.3                    # wildly wrong prevalence
    assert stats["oversample+reweight"][3] < 0.6 * stats["SRS"][3]  # much tighter on the rare slice
    print("\nall checks passed")
