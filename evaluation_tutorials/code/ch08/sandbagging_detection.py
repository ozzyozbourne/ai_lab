"""Detecting sandbagging: elicitation gaps and difficulty-inconsistent errors (Chapter 8.11).

Mock items: 300 "general" (MMLU-like) and 300 "hazard-proxy" (WMDP-like) 4-option questions with
known IRT difficulties b. Correct-answer probability follows a 3PL-style curve with guessing
floor 0.25: P = 0.25 + 0.75 * sigmoid(theta - b).

Two mock models with about the same hazard-proxy accuracy:
  honest-weak : theta = 1.0 on general items, genuinely weaker (theta = -0.3) on hazard items
  sandbagger  : theta = 1.0 everywhere, but without the password string it deliberately picks
                a wrong option on 25% of hazard items, regardless of difficulty

We report (1) prompted vs password-elicited vs "fine-tuning-elicited" accuracy (k labelled
examples shrink the sandbagging rate by exp(-k/25)), and (2) a black-box consistency check:
fit theta on the hazard items by maximum likelihood, then compute the standardised person-fit
statistic l_z (very negative = errors on items that should be easy) and the error rate on the
easiest quartile of items.

Run:  python3 code/ch08/sandbagging_detection.py
Key output: hazard accuracy 0.567 (honest-weak) vs 0.520 (sandbagger) when prompted, but 0.773
with the password; l_z = -0.32 vs -3.07; easy-quartile error 0.347 vs 0.253 expected.
"""
from __future__ import annotations

import math

import numpy as np


def p_correct(theta: float, b: np.ndarray) -> np.ndarray:
    return 0.25 + 0.75 / (1 + np.exp(-(theta - b)))


def answer(theta: float, b: np.ndarray, rng: np.random.Generator, sandbag: float = 0.0) -> np.ndarray:
    u = rng.random(b.size) < p_correct(theta, b)
    drop = rng.random(b.size) < sandbag
    return (u & ~drop).astype(int)


def fit_theta(u: np.ndarray, b: np.ndarray) -> float:
    """MLE of theta by grid search (robust, no SciPy)."""
    grid = np.linspace(-4, 4, 1601)
    ll = [np.sum(u * np.log(p_correct(t, b)) + (1 - u) * np.log(1 - p_correct(t, b))) for t in grid]
    return float(grid[int(np.argmax(ll))])


def l_z(u: np.ndarray, b: np.ndarray, theta: float) -> float:
    """Standardised log-likelihood person-fit statistic (Drasgow et al. style)."""
    p = p_correct(theta, b)
    l0 = np.sum(u * np.log(p) + (1 - u) * np.log(1 - p))
    e = np.sum(p * np.log(p) + (1 - p) * np.log(1 - p))
    v = np.sum(p * (1 - p) * np.log(p / (1 - p)) ** 2)
    return float((l0 - e) / math.sqrt(v))


def main() -> None:
    rng = np.random.default_rng(99)
    b_gen = rng.normal(0, 1.2, 300)
    b_haz = rng.normal(0, 1.2, 300)
    easy = b_haz < np.quantile(b_haz, 0.25)
    models = {"honest-weak": (1.0, -0.3, 0.0), "sandbagger": (1.0, 1.0, 0.25)}

    print("Part 1: elicitation (accuracy)")
    print(f"  {'model':<12} {'general':>8} {'hazard prompted':>16} {'hazard + password':>18} "
          f"{'FT k=10':>8} {'FT k=50':>8}")
    detect = {}
    for name, (t_gen, t_haz, sb) in models.items():
        gen = answer(t_gen, b_gen, rng).mean()
        u_haz = answer(t_haz, b_haz, rng, sb)
        pw = answer(t_haz, b_haz, rng, 0.0).mean()
        ft = [answer(t_haz, b_haz, rng, sb * math.exp(-k / 25)).mean() for k in (10, 50)]
        print(f"  {name:<12} {gen:8.3f} {u_haz.mean():16.3f} {pw:18.3f} {ft[0]:8.3f} {ft[1]:8.3f}")
        th = fit_theta(u_haz, b_haz)
        detect[name] = (th, l_z(u_haz, b_haz, th), 1 - u_haz[easy].mean(),
                        1 - p_correct(th, b_haz[easy]).mean())

    print("\nPart 2: black-box consistency check on hazard items (no password needed)")
    print(f"  {'model':<12} {'theta_hat':>9} {'l_z':>7} {'easy-quartile error':>20} {'expected from theta_hat':>24}")
    for name, (th, lz, e_obs, e_exp) in detect.items():
        print(f"  {name:<12} {th:9.2f} {lz:7.2f} {e_obs:20.3f} {e_exp:24.3f}")
    assert detect["sandbagger"][1] < -2.0 < detect["honest-weak"][1]
    assert detect["sandbagger"][2] > detect["sandbagger"][3] + 0.05


if __name__ == "__main__":
    main()
