"""Time-split contamination analysis: accuracy by problem release month around a training cutoff.

Chapter 3, section 3.12 (#prevention), Figure 3.5. The LiveCodeBench method: score only problems
released after the cutoff, and compare pre- vs post-cutoff accuracy against a clean reference model.
Run:  python3 code/ch03/time_split.py
Expected key output: both models lose accuracy over time (newer problems are harder), but the
contaminated model's pre/post gap is far larger; the difference-in-differences CI excludes 0.
"""
from __future__ import annotations

import numpy as np

SEED, PER_MONTH, B = 3, 40, 2000
MONTHS = [f"{y}-{m:02d}" for y in (2023, 2024, 2025) for m in range(1, 13)][6:30]  # 2023-07 .. 2025-06
CUTOFF, MARGIN = "2024-06", 1          # announced cutoff; skip 1 month after it (fuzzy cutoffs)


def simulate(rng: np.random.Generator):
    month_idx = np.repeat(np.arange(len(MONTHS)), PER_MONTH)
    difficulty = rng.normal(0.0, 1.0, len(month_idx)) + 0.03 * month_idx   # newer = a bit harder
    p_clean = 1 / (1 + np.exp(-(0.9 - difficulty)))
    c = MONTHS.index(CUTOFF)
    memorised = (month_idx < c) & (rng.random(len(month_idx)) < 0.35)       # seen in training
    u = rng.random(len(month_idx))                                          # shared item noise
    clean = (u < p_clean).astype(float)
    contaminated = np.where(memorised, 1.0, clean)
    return month_idx, clean, contaminated


def gap_ci(month_idx, y, rng, cutoff=None):
    c = MONTHS.index(cutoff or CUTOFF)
    pre, post = y[month_idx < c], y[month_idx >= c + MARGIN]
    gap = pre.mean() - post.mean()
    boots = [rng.choice(pre, len(pre)).mean() - rng.choice(post, len(post)).mean() for _ in range(B)]
    return gap, np.percentile(boots, [2.5, 97.5])


def did_ci(month_idx, clean, cont, rng, cutoff=None):
    """Difference-in-differences, bootstrapping items jointly (both models saw the same items)."""
    c = MONTHS.index(cutoff or CUTOFF)
    pre, post = np.flatnonzero(month_idx < c), np.flatnonzero(month_idx >= c + MARGIN)

    def stat(a, b):
        return (cont[a].mean() - cont[b].mean()) - (clean[a].mean() - clean[b].mean())
    boots = [stat(rng.choice(pre, len(pre)), rng.choice(post, len(post))) for _ in range(B)]
    return stat(pre, post), np.percentile(boots, [2.5, 97.5])


if __name__ == "__main__":
    rng = np.random.default_rng(SEED)
    month_idx, clean, cont = simulate(rng)
    print(f"{len(MONTHS)} months x {PER_MONTH} problems; cutoff {CUTOFF}, margin {MARGIN} month\n")
    print(f"{'month':<9}{'clean':>7}{'contam.':>9}")
    for i, m in enumerate(MONTHS):
        mark = "  <- cutoff" if m == CUTOFF else ""
        print(f"{m:<9}{clean[month_idx == i].mean():7.2f}{cont[month_idx == i].mean():9.2f}{mark}")

    print("\nby quarter (Figure 3.5):")
    for q in range(len(MONTHS) // 3):
        mask = (month_idx // 3) == q
        print(f"  {MONTHS[3 * q]}..{MONTHS[3 * q + 2][5:]}  clean {clean[mask].mean():.3f}  contam. {cont[mask].mean():.3f}")

    g_clean, ci_clean = gap_ci(month_idx, clean, rng)
    g_cont, ci_cont = gap_ci(month_idx, cont, rng)
    did, ci_did = did_ci(month_idx, clean, cont, rng)
    print(f"\npre - post gap, clean model       : {g_clean:+.3f}  95% CI [{ci_clean[0]:+.3f}, {ci_clean[1]:+.3f}]")
    print(f"pre - post gap, contaminated model: {g_cont:+.3f}  95% CI [{ci_cont[0]:+.3f}, {ci_cont[1]:+.3f}]")
    print(f"difference-in-differences         : {did:+.3f}  95% CI [{ci_did[0]:+.3f}, {ci_did[1]:+.3f}]")
    post_mask = month_idx >= MONTHS.index(CUTOFF) + MARGIN
    print(f"\npost-cutoff-only accuracy: clean {clean[post_mask].mean():.3f}, "
          f"contaminated {cont[post_mask].mean():.3f}  (the honest comparison)")
    print(f"full-benchmark accuracy  : clean {clean.mean():.3f}, contaminated {cont.mean():.3f}")

    assert g_clean > 0.03           # even the clean model 'drops': difficulty drift, not contamination
    assert ci_did[0] > 0.05         # the excess drop is what signals contamination
    assert abs(clean[post_mask].mean() - cont[post_mask].mean()) < 1e-12
    print("\nall checks passed")
