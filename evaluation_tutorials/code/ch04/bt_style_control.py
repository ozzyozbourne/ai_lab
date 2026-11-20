"""Bradley-Terry ratings from judge battles, style control and length-controlled win rate
(Chapter 4.7, #aggregation).

Six mock models have a hidden "substance" strength and a typical answer length. A mock judge
decides each battle with P(i beats j) = sigmoid(beta_i - beta_j + gamma * s_ij), where
s_ij = (len_i - len_j) / (len_i + len_j) is the normalised length difference (the LMSYS
style-control feature) and gamma > 0 is the judge's length bias.
  1. Fit plain BT by Newton's method (logistic regression); report the Elo-like scale
     400 * beta / ln 10 + 1000 used by FastChat.
  2. Fit BT with the length covariate ("style control"); the verbose model loses its inflated rank.
  3. Length-controlled win rate vs a baseline (simplified AlpacaEval GLM: no per-instruction term):
     logit q = theta + phi * tanh(dlen / std(dlen)); LC win rate = sigmoid(theta).

Run: python3 code/ch04/bt_style_control.py
"""
from __future__ import annotations

import math

import numpy as np

NAMES = ["concise-pro", "balanced", "verbose-lite", "mid", "small", "tiny"]
BETA_TRUE = np.array([1.0, 0.8, 0.3, 0.4, 0.0, -0.4])
MEAN_LEN = np.array([180, 300, 650, 300, 280, 250])
GAMMA_TRUE = 2.0


def sigmoid(z):
    return 1 / (1 + np.exp(-z))


def answer_lengths(m: np.ndarray, instr_factor: np.ndarray, rng) -> np.ndarray:
    """Length = model's typical length x how long this instruction needs x noise."""
    return MEAN_LEN[m] * instr_factor * rng.lognormal(0, 0.25, len(m))


def simulate_battles(n: int, rng):
    i = rng.integers(0, 6, n)
    j = (i + rng.integers(1, 6, n)) % 6
    x = rng.lognormal(0, 0.6, n)            # per-instruction length factor, shared by both answers
    li, lj = answer_lengths(i, x, rng), answer_lengths(j, x, rng)
    s = (li - lj) / (li + lj)
    y = rng.random(n) < sigmoid(BETA_TRUE[i] - BETA_TRUE[j] + GAMMA_TRUE * s)
    return i, j, s, y.astype(float)


def fit_logistic(X: np.ndarray, y: np.ndarray, ridge: float = 1e-6, iters: int = 50) -> np.ndarray:
    w = np.zeros(X.shape[1])
    for _ in range(iters):
        p = sigmoid(X @ w)
        g = X.T @ (y - p) - ridge * w
        H = (X * (p * (1 - p))[:, None]).T @ X + ridge * np.eye(len(w))
        step = np.linalg.solve(H, g)
        w += step
        if np.abs(step).max() < 1e-10:
            break
    return w


def fit_bt(i, j, y, s=None) -> tuple[np.ndarray, float | None]:
    """Design: +1 for model i, -1 for model j; model 0 is the reference (beta = 0)."""
    n = len(y)
    X = np.zeros((n, 6))
    X[np.arange(n), i] += 1
    X[np.arange(n), j] -= 1
    X = X[:, 1:]
    if s is not None:
        X = np.column_stack([X, s])
    w = fit_logistic(X, y)
    beta = np.concatenate([[0.0], w[:5]])
    return beta - beta.mean(), (w[5] if s is not None else None)


def elo(beta: np.ndarray) -> np.ndarray:
    return 400 * beta / math.log(10) + 1000


def lc_win_rate(dlen: np.ndarray, y: np.ndarray) -> tuple[float, float]:
    t = np.tanh(dlen / dlen.std())
    theta, phi = fit_logistic(np.column_stack([np.ones_like(t), t]), y)
    return float(sigmoid(theta)), float(phi)


def main() -> None:
    print(f"Worked example: beta_A - beta_B = 0.5 -> P(A wins) = {sigmoid(0.5):.3f},"
          f" Elo gap = {400 * 0.5 / math.log(10):.0f} points")
    assert abs(sigmoid(0.5) - 0.622) < 1e-3 and round(400 * 0.5 / math.log(10)) == 87

    rng = np.random.default_rng(8)
    i, j, s, y = simulate_battles(12000, rng)
    b_plain, _ = fit_bt(i, j, y)
    b_style, g = fit_bt(i, j, y, s)
    # bootstrap the style-controlled fit
    boots = []
    for _ in range(100):
        k = rng.integers(0, len(y), len(y))
        boots.append(elo(fit_bt(i[k], j[k], y[k], s[k])[0]))
    lo, hi = np.percentile(boots, [2.5, 97.5], axis=0)
    truth = elo(BETA_TRUE - BETA_TRUE.mean())
    rank = lambda b: np.argsort(np.argsort(-b)) + 1
    print(f"\n12,000 judge battles; judge length bias gamma = {GAMMA_TRUE}; fitted gamma = {g:.2f}")
    print(f"{'model':<14}{'mean len':>9}{'true Elo':>10}{'plain BT':>10}{'rank':>6}{'style-ctl':>11}{'95% CI':>16}{'rank':>6}")
    for m in np.argsort(-b_style):
        print(f"{NAMES[m]:<14}{MEAN_LEN[m]:>9}{truth[m]:>10.0f}{elo(b_plain)[m]:>10.0f}{rank(b_plain)[m]:>6}"
              f"{elo(b_style)[m]:>11.0f}   [{lo[m]:5.0f},{hi[m]:5.0f}]{rank(b_style)[m]:>6}")
    v = NAMES.index("verbose-lite")
    assert rank(b_plain)[v] < rank(b_style)[v]
    assert abs(g - GAMMA_TRUE) < 0.4
    assert np.all(rank(b_style) == rank(BETA_TRUE))

    # Length-controlled win rate of each model against "balanced" as the baseline
    base = NAMES.index("balanced")
    print(f"\nWin rate vs baseline '{NAMES[base]}' (raw vs length-controlled GLM)")
    print(f"{'model':<14}{'raw WR':>8}{'LC WR':>8}{'true WR':>9}")
    for m in range(6):
        if m == base:
            continue
        n = 3000
        x = rng.lognormal(0, 0.6, n)
        lm = answer_lengths(np.full(n, m), x, rng)
        lb = answer_lengths(np.full(n, base), x, rng)
        ss = (lm - lb) / (lm + lb)
        yy = (rng.random(n) < sigmoid(BETA_TRUE[m] - BETA_TRUE[base] + GAMMA_TRUE * ss)).astype(float)
        lc, _ = lc_win_rate(lm - lb, yy)
        true_wr = sigmoid(BETA_TRUE[m] - BETA_TRUE[base])
        print(f"{NAMES[m]:<14}{100 * yy.mean():>8.1f}{100 * lc:>8.1f}{100 * true_wr:>9.1f}")
        if NAMES[m] == "verbose-lite":
            assert yy.mean() - true_wr > 0.08 and abs(lc - true_wr) < abs(yy.mean() - true_wr) / 2


if __name__ == "__main__":
    main()
