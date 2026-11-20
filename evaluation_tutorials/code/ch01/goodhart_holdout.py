"""Goodhart in miniature: tuning on a small dev set and the winner's curse.

Chapter 1, section 1.7 (Validity). Connects to Kapoor et al. 2024 (inadequate holdouts) and
Singh et al. 2025 (private best-of-N testing on Chatbot Arena).

Setup (all mocked, seeded):
  * 200 candidate "prompt configs". Config j has a TRUE accuracy p_j ~ Normal(0.70, 0.02),
    i.e. the configs are nearly indistinguishable in reality.
  * A 30-item dev set and a 2,000-item held-out test set. Each item is answered correctly
    with probability p_j (items independent).
  * We "tune" by picking the config with the best dev score among the first K configs tried.
Run:  python3 code/ch01/goodhart_holdout.py
Expected key output (averaged over 400 repetitions): with K=200 configs the winner scores
0.912 on dev but 0.712 on test; with K=1 dev and test agree (0.701 vs 0.699).
"""
from __future__ import annotations

import numpy as np

N_DEV, N_TEST, N_CONFIGS, REPS = 30, 2000, 200, 400
KS = [1, 2, 5, 10, 20, 50, 100, 200]


def one_run(rng: np.random.Generator) -> dict:
    p_true = np.clip(rng.normal(0.70, 0.02, size=N_CONFIGS), 0, 1)
    dev = rng.binomial(N_DEV, p_true) / N_DEV
    test = rng.binomial(N_TEST, p_true) / N_TEST
    out = {}
    for k in KS:
        j = int(np.argmax(dev[:k]))              # winner among the first k configs tried
        out[k] = (dev[j], test[j], p_true[j])
    out["oracle"] = float(p_true.max())
    return out


def main() -> dict[int, tuple[float, float, float]]:
    rng = np.random.default_rng(2026)
    runs = [one_run(rng) for _ in range(REPS)]
    table = {k: tuple(float(np.mean([r[k][i] for r in runs])) for i in range(3)) for k in KS}

    print(f"dev items={N_DEV}, test items={N_TEST}, configs={N_CONFIGS}, repetitions={REPS}")
    print(f"{'configs tried':>13} {'winner dev':>11} {'winner test':>12} {'winner true p':>14} {'optimism':>9}")
    for k, (d, t, p) in table.items():
        print(f"{k:>13} {d:>11.3f} {t:>12.3f} {p:>14.3f} {d - t:>+9.3f}")
    oracle = float(np.mean([r["oracle"] for r in runs]))
    print(f"\nbest TRUE accuracy among all {N_CONFIGS} configs (oracle) = {oracle:.3f}")
    print("The selected config's dev score climbs with every extra config tried; its test score")
    print("barely moves. The gap is selection bias (winner's curse), not skill.")
    return table


if __name__ == "__main__":
    t = main()
    assert abs(t[1][0] - t[1][1]) < 0.02                       # no selection, no optimism
    assert t[200][0] > 0.85 and t[200][1] < 0.74               # big winner's curse at K=200
    assert all(t[a][0] <= t[b][0] + 1e-9 for a, b in zip(KS, KS[1:]))   # dev optimism grows with K
