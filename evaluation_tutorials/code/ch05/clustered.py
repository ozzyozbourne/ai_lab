"""Clustered standard errors: why questions that share a passage are not independent.

Chapter 5, section 5.3 (#clustered).
Run:  python3 code/ch05/clustered.py
Shows: 50 passages x 4 questions, each passage's difficulty drawn from {0.2, 0.5, 0.9}.
Naive SE vs Miller's clustered SE vs Inspect's version (finite-cluster correction C/(C-1))
vs a cluster bootstrap; then 2,000 replications showing the coverage of naive vs clustered 95% CIs.
"""
from __future__ import annotations

import numpy as np

N_PASSAGES, Q_PER = 50, 4
LEVELS = np.array([0.2, 0.5, 0.9])
TRUE_MEAN = float(LEVELS.mean())  # super-population accuracy = 0.5333


def simulate(rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    """Return (scores, cluster_ids) for one benchmark draw."""
    p = rng.choice(LEVELS, size=N_PASSAGES)
    scores = (rng.random((N_PASSAGES, Q_PER)) < p[:, None]).astype(float)
    return scores.ravel(), np.repeat(np.arange(N_PASSAGES), Q_PER)


def naive_se(s: np.ndarray) -> float:
    return float(np.std(s, ddof=1) / np.sqrt(len(s)))


def clustered_se(s: np.ndarray, cid: np.ndarray, finite_correction: bool) -> float:
    """(1/n) * sqrt( sum_c (sum_{i in c} (s_i - mean))^2 ), optionally times sqrt(C/(C-1))."""
    mean = s.mean()
    clusters = np.unique(cid)
    v = sum(((s[cid == c] - mean).sum()) ** 2 for c in clusters)
    if finite_correction:
        v *= len(clusters) / (len(clusters) - 1)
    return float(np.sqrt(v) / len(s))


def cluster_bootstrap_se(s: np.ndarray, cid: np.ndarray, rng: np.random.Generator, b: int = 2000) -> float:
    """Resample whole passages with replacement and recompute the mean."""
    sums = np.bincount(cid, weights=s)
    sizes = np.bincount(cid)
    idx = rng.integers(0, len(sums), size=(b, len(sums)))
    means = sums[idx].sum(axis=1) / sizes[idx].sum(axis=1)
    return float(means.std(ddof=1))


def main() -> None:
    rng = np.random.default_rng(20241101)
    s, cid = simulate(rng)
    se_n = naive_se(s)
    se_m = clustered_se(s, cid, finite_correction=False)
    se_i = clustered_se(s, cid, finite_correction=True)
    se_b = cluster_bootstrap_se(s, cid, np.random.default_rng(7))
    print(f"One benchmark draw: {N_PASSAGES} passages x {Q_PER} questions, mean = {s.mean():.3f}")
    print(f"  naive SE (iid)                 = {se_n:.4f}")
    print(f"  clustered SE (Miller App. A)   = {se_m:.4f}   ratio {se_m/se_n:.2f}x")
    print(f"  clustered SE (Inspect, C/(C-1))= {se_i:.4f}   ratio {se_i/se_n:.2f}x")
    print(f"  cluster bootstrap SE (B=2000)  = {se_b:.4f}   ratio {se_b/se_n:.2f}x")

    # Theory: design effect 1 + (m - 1) * ICC
    var_p = LEVELS.var()
    icc = var_p / (TRUE_MEAN * (1 - TRUE_MEAN))
    deff = 1 + (Q_PER - 1) * icc
    print(f"  theory: ICC = {icc:.3f}, design effect = {deff:.2f}, SE inflation = sqrt(deff) = {np.sqrt(deff):.2f}x")

    # Coverage over many benchmark draws
    reps = 2000
    hit = {"naive": 0, "clustered (Inspect)": 0}
    ratios = []
    for _ in range(reps):
        s, cid = simulate(rng)
        m = s.mean()
        a, c = naive_se(s), clustered_se(s, cid, True)
        ratios.append(c / a)
        hit["naive"] += abs(m - TRUE_MEAN) <= 1.96 * a
        hit["clustered (Inspect)"] += abs(m - TRUE_MEAN) <= 1.96 * c
    print(f"\nCoverage of nominal 95% CIs over {reps} benchmark draws (true mean {TRUE_MEAN:.4f}):")
    for k, v in hit.items():
        print(f"  {k:<20} {v / reps * 100:5.1f}%")
    print(f"  median clustered/naive SE ratio = {np.median(ratios):.2f}x")
    assert 1.3 < se_m / se_n < 1.6
    assert hit["naive"] / reps < 0.90 and hit["clustered (Inspect)"] / reps > 0.92


if __name__ == "__main__":
    main()
