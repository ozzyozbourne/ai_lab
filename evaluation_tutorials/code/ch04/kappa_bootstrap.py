"""Bootstrap confidence intervals for judge-human agreement (Chapter 4.3, #agreement).

A mock judge with TPR 0.90 and TNR 0.70 (the chapter's worked judge, true kappa = 0.60)
labels items whose human pass rate is 50%. We draw a validation set of n = 50 and of
n = 500 items and compute 95% percentile-bootstrap CIs for kappa, TPR and TNR.
We also repeat the whole experiment 300 times to show how much a single n = 50
validation set can mislead you.

Run: python3 code/ch04/kappa_bootstrap.py
Expected: the n = 50 kappa CI is roughly three times wider than the n = 500 one.
"""
from __future__ import annotations

import numpy as np

TPR, TNR, BASE = 0.90, 0.70, 0.50


def simulate(n: int, rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    human = rng.random(n) < BASE                      # True = PASS
    u = rng.random(n)
    judge = np.where(human, u < TPR, u > TNR)         # pass if human pass (p=TPR); false pass (p=1-TNR)
    return human, judge


def kappa(h: np.ndarray, j: np.ndarray) -> float:
    p_o = np.mean(h == j)
    p_e = h.mean() * j.mean() + (1 - h.mean()) * (1 - j.mean())
    return 0.0 if p_e == 1 else (p_o - p_e) / (1 - p_e)


def rates(h: np.ndarray, j: np.ndarray) -> tuple[float, float]:
    tpr = j[h].mean() if h.any() else np.nan
    tnr = (~j[~h]).mean() if (~h).any() else np.nan
    return tpr, tnr


def bootstrap(h, j, rng, B: int = 2000):
    n = len(h)
    idx = rng.integers(0, n, size=(B, n))
    ks, tp, tn = [], [], []
    for row in idx:
        hb, jb = h[row], j[row]
        ks.append(kappa(hb, jb))
        a, b = rates(hb, jb)
        tp.append(a)
        tn.append(b)
    q = lambda x: np.nanpercentile(x, [2.5, 97.5])
    return q(ks), q(tp), q(tn)


def main() -> None:
    rng = np.random.default_rng(7)
    p_e = BASE * (BASE * TPR + (1 - BASE) * (1 - TNR)) + (1 - BASE) * (1 - (BASE * TPR + (1 - BASE) * (1 - TNR)))
    p_o = BASE * TPR + (1 - BASE) * TNR
    k_true = (p_o - p_e) / (1 - p_e)
    print(f"True judge: TPR = {TPR:.2f}, TNR = {TNR:.2f}, base pass rate {BASE:.2f} -> population kappa = {k_true:.3f}\n")
    assert abs(k_true - 0.60) < 1e-9

    print(f"{'n':>5} {'kappa':>7} {'95% CI':>17} {'width':>7} {'TPR 95% CI':>16} {'TNR 95% CI':>16}")
    widths = {}
    for n in (50, 500):
        h, j = simulate(n, rng)
        (kl, ku), (tl, tu), (nl, nu) = bootstrap(h, j, rng)
        widths[n] = ku - kl
        print(f"{n:>5} {kappa(h, j):>7.3f} [{kl:6.3f}, {ku:6.3f}] {ku - kl:>7.3f}"
              f"   [{tl:.2f}, {tu:.2f}]     [{nl:.2f}, {nu:.2f}]")
    ratio = widths[50] / widths[500]
    print(f"\nCI width ratio n=50 / n=500 = {ratio:.2f} (theory: sqrt(10) = {np.sqrt(10):.2f})")
    assert 2.2 < ratio < 4.5

    # How often does one small validation set badly mislead?
    reps = 300
    for n in (50, 500):
        ks = np.array([kappa(*simulate(n, rng)) for _ in range(reps)])
        lo, hi = np.percentile(ks, [5, 95])
        print(f"n = {n:>3}: across {reps} repeated validation sets, 90% of kappa estimates fall in [{lo:.2f}, {hi:.2f}];"
              f" P(kappa_hat >= 0.70) = {np.mean(ks >= 0.70):.2f}")


if __name__ == "__main__":
    main()
