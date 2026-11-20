"""Reducing variance with K samples per question, and the K*n pooling pitfall.

Chapter 5, section 5.4 (#variance-reduction).
Run:  python3 code/ch05/resample_k.py
Shows: a mock stochastic model whose per-question success probability is p_i ~ Beta(0.6, 0.4).
Law of total variance: Var(score) = E[p(1-p)] (within, prediction noise) + Var(p) (between, data noise).
Averaging K samples shrinks only the within term; the correct SE uses per-question means, while
pooling K*n samples as if independent understates it. Scoring with the probability p_i itself
(as with a token probability) removes the within term entirely.
"""
from __future__ import annotations

import numpy as np

A, B = 0.6, 0.4  # Beta prior over per-question success probability (mean 0.6, U-shaped)
N = 200
REPS = 4000


def theory() -> tuple[float, float]:
    mean = A / (A + B)
    var_between = A * B / ((A + B) ** 2 * (A + B + 1))
    within = mean * (1 - mean) - var_between  # E[p(1-p)] = mu(1-mu) - Var(p)
    return var_between, within


def main() -> None:
    rng = np.random.default_rng(42)
    vb, vw = theory()
    print(f"Law of total variance for one sampled answer (p_i ~ Beta({A},{B})):")
    print(f"  Var(p_i) between questions = {vb:.4f}   E[p_i(1-p_i)] within = {vw:.4f}   total = {vb+vw:.4f}")
    assert abs(vb + vw - 0.24) < 1e-12

    print(f"\nSE of the benchmark mean, n = {N} questions, {REPS} fresh benchmarks per row")
    print(f"  {'K':>3}  {'true SE':>8}  {'theory':>8}  {'per-question-mean SE':>21}  {'pooled K*n SE':>14}  {'95% cov pooled':>15}")
    rows = {}
    for k in (1, 4, 16):
        means, se_q, se_pool, cover = [], [], [], 0
        for _ in range(REPS):
            p = rng.beta(A, B, size=N)
            x = rng.random((N, k)) < p[:, None]
            qmean = x.mean(axis=1)
            m = qmean.mean()
            means.append(m)
            se_q.append(qmean.std(ddof=1) / np.sqrt(N))
            pooled = x.ravel().astype(float)
            sp = pooled.std(ddof=1) / np.sqrt(len(pooled))
            se_pool.append(sp)
            cover += abs(m - A / (A + B)) <= 1.96 * sp
        true_se = float(np.std(means))
        th = float(np.sqrt((vb + vw / k) / N))
        rows[k] = (true_se, th, float(np.mean(se_q)), float(np.mean(se_pool)), cover / REPS)
        print(f"  {k:>3}  {true_se:8.4f}  {th:8.4f}  {np.mean(se_q):21.4f}  {np.mean(se_pool):14.4f}  {cover/REPS*100:14.1f}%")
    # token-probability scoring: score is p_i itself
    tp = [rng.beta(A, B, size=N).mean() for _ in range(REPS)]
    print(f"  p_i  {np.std(tp):8.4f}  {np.sqrt(vb/N):8.4f}  (score = probability of the right answer; no sampling noise)")
    floor = np.sqrt(vb / N)
    print(f"\nK=1 -> K=16 cuts the SE from {rows[1][0]:.4f} to {rows[16][0]:.4f}; the floor set by n is {floor:.4f}.")
    print(f"Only more (or better) questions move the floor: n=800 would give {np.sqrt(vb/800):.4f}.")
    for k, r in rows.items():
        assert abs(r[0] - r[1]) / r[1] < 0.05      # simulation agrees with the formula
        assert abs(r[2] - r[1]) / r[1] < 0.05      # per-question-mean SE is right
    assert rows[16][3] < 0.5 * rows[16][0]          # pooling K*n badly understates the SE
    assert rows[16][4] < 0.60


if __name__ == "__main__":
    main()
