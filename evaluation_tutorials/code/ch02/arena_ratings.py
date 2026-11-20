"""Ranking models from pairwise votes: online Elo (order-dependent) vs Bradley-Terry (MLE),
ties (scored as half a win, or dropped), bootstrap confidence intervals with ratings centred
on a mean of 1000 (so no model has a zero-width interval), and style control with a length covariate.

Chapter 2, section 2.7 (#preferences).
Run:  python3 code/ch02/arena_ratings.py
Expected key output: Elo ratings differ between two orderings of the same battles; BT is order-free;
the 'verbose' model ranks 2nd without style control and drops once length is a covariate;
about a quarter of battles are ties, and counting them as 0.5 compresses the rating spread.
"""
from __future__ import annotations

import math

import numpy as np

MODELS = ["alpha", "bravo", "verbose", "delta", "echo", "foxtrot"]
STRENGTH = np.array([0.80, 0.55, 0.30, 0.25, 0.00, -0.30])   # latent quality, natural-log units
MEAN_LEN = np.array([450, 400, 1100, 420, 380, 350])          # typical answer length in tokens
GAMMA_TRUE = 1.2       # voters' preference for longer answers (per unit of normalised length diff)
TIE_RATE = 0.40        # P(tie) = TIE_RATE * exp(-|latent difference|): close battles tie more often
SCALE = 400 / math.log(10)   # natural-log BT units -> Elo points


def simulate(rng: np.random.Generator, n_battles: int):
    a = rng.integers(len(MODELS), size=n_battles)
    b = (a + rng.integers(1, len(MODELS), size=n_battles)) % len(MODELS)   # b != a
    len_a = rng.normal(MEAN_LEN[a], 0.25 * MEAN_LEN[a])
    len_b = rng.normal(MEAN_LEN[b], 0.25 * MEAN_LEN[b])
    z = (len_a - len_b) / (len_a + len_b)              # normalised length difference, as in style control
    d = STRENGTH[a] - STRENGTH[b] + GAMMA_TRUE * z
    p = 1 / (1 + np.exp(-d))
    y = (rng.random(n_battles) < p).astype(float)     # 1 = model a wins, 0 = model b wins
    tie = rng.random(n_battles) < TIE_RATE * np.exp(-np.abs(d))
    y[tie] = 0.5                                       # a tie counts as half a win (as in FastChat)
    return a, b, z, y


def online_elo(a, b, y, k=4.0, init=1000.0) -> np.ndarray:
    """Same update as FastChat compute_elo: base 10, scale 400, K = 4."""
    r = np.full(len(MODELS), init)
    alpha = math.log(10) / 400
    for i, j, s in zip(a, b, y):
        e = 1 / (1 + math.exp(alpha * (r[j] - r[i])))
        r[i] += k * (s - e)
        r[j] -= k * (s - e)
    return r


def fit_bt(a, b, y, z=None, iters=50, ridge=1e-6) -> tuple[np.ndarray, float]:
    """Bradley-Terry by Newton's method on the logistic log-likelihood.
    Design row: +1 for model a, -1 for model b, and optionally the style covariate z.
    Model 0 is pinned to 0 for identifiability (we re-anchor afterwards)."""
    m = len(MODELS)
    n = len(y)
    X = np.zeros((n, m - 1 + (z is not None)))
    for col in range(1, m):
        X[:, col - 1] = (a == col).astype(float) - (b == col).astype(float)
    if z is not None:
        X[:, -1] = z
    w = np.zeros(X.shape[1])
    for _ in range(iters):
        p = 1 / (1 + np.exp(-X @ w))
        grad = X.T @ (y - p) - ridge * w
        H = (X * (p * (1 - p))[:, None]).T @ X + ridge * np.eye(len(w))
        step = np.linalg.solve(H, grad)
        w += step
        if np.max(np.abs(step)) < 1e-10:
            break
    beta = np.concatenate([[0.0], w[: m - 1]])
    gamma = float(w[-1]) if z is not None else 0.0
    return beta, gamma


def to_elo(beta: np.ndarray, centre: float = 1000.0) -> np.ndarray:
    """Elo scale: 400/ln(10) per natural-log unit. Only differences are identified, so we centre the
    ratings on a mean of 1000 (FastChat instead pins one baseline model, whose bootstrap CI is then
    degenerate). Online Elo with init 1000 is zero-sum, so its mean is 1000 too."""
    r = beta * SCALE
    return r - r.mean() + centre


def bootstrap_ci(rng, a, b, y, z=None, rounds=200):
    n = len(y)
    samples = []
    for _ in range(rounds):
        idx = rng.integers(n, size=n)
        beta, _ = fit_bt(a[idx], b[idx], y[idx], None if z is None else z[idx])
        samples.append(to_elo(beta))
    s = np.array(samples)
    return np.percentile(s, 2.5, axis=0), np.percentile(s, 97.5, axis=0)


def ranks(r: np.ndarray) -> np.ndarray:
    out = np.empty(len(r), dtype=int)
    out[np.argsort(-r)] = np.arange(1, len(r) + 1)
    return out


if __name__ == "__main__":
    rng = np.random.default_rng(42)
    a, b, z, y = simulate(rng, 8000)
    print(f"{len(y)} simulated battles ({np.mean(y == 0.5):.1%} ties); verbose model's answers are ~2.5x longer;"
          " ratings centred on mean 1000\n")

    order1 = np.arange(len(y))
    order2 = np.random.default_rng(1).permutation(len(y))
    elo1 = online_elo(a[order1], b[order1], y[order1])
    elo2 = online_elo(a[order2], b[order2], y[order2])

    beta, _ = fit_bt(a, b, y)
    bt = to_elo(beta)
    lo, hi = bootstrap_ci(np.random.default_rng(3), a, b, y)
    beta_sc, gamma = fit_bt(a, b, y, z)
    bt_sc = to_elo(beta_sc)
    lo_sc, hi_sc = bootstrap_ci(np.random.default_rng(4), a, b, y, z)
    true_elo = to_elo(STRENGTH.copy())
    tie_share = float(np.mean(y == 0.5))
    decisive = y != 0.5
    bt_drop = to_elo(fit_bt(a[decisive], b[decisive], y[decisive])[0])

    print(f"{'model':<9}{'true':>7}{'Elo ord1':>10}{'Elo ord2':>10}{'BT':>8}{'95% CI':>15}"
          f"{'BT+style':>10}{'95% CI':>15}  rank BT -> BT+style")
    rb, rs = ranks(bt), ranks(bt_sc)
    for i, name in enumerate(MODELS):
        print(f"{name:<9}{true_elo[i]:>7.0f}{elo1[i]:>10.0f}{elo2[i]:>10.0f}{bt[i]:>8.0f}"
              f"{f'[{lo[i]:.0f},{hi[i]:.0f}]':>15}{bt_sc[i]:>10.0f}{f'[{lo_sc[i]:.0f},{hi_sc[i]:.0f}]':>15}"
              f"  {rb[i]} -> {rs[i]}")
    print(f"\nmax |Elo ord1 - Elo ord2| = {np.max(np.abs(elo1 - elo2)):.1f} points (same battles, different order)")
    print(f"fitted length coefficient gamma = {gamma:.2f} (true {GAMMA_TRUE})")
    spread = lambda r: float(r.max() - r.min())
    print(f"\nties as 0.5: alpha - foxtrot = {spread(bt):.0f} points | ties dropped: {spread(bt_drop):.0f} points"
          f" | true {spread(true_elo):.0f}")
    print("per-model (ties dropped) - (ties as 0.5): " + "  ".join(
        f"{m} {d:+.0f}" for m, d in zip(MODELS, bt_drop - bt)))

    # BT does not depend on order: refit on the shuffled battles
    beta_shuf, _ = fit_bt(a[order2], b[order2], y[order2])
    assert np.allclose(beta_shuf, beta, atol=1e-8)
    assert np.max(np.abs(elo1 - elo2)) > 1.0
    v = MODELS.index("verbose")
    assert rb[v] == 2 and rs[v] >= 3, (rb[v], rs[v])
    assert abs(gamma - GAMMA_TRUE) < 0.3
    assert 0.2 < tie_share < 0.3, tie_share
    assert spread(bt) < spread(bt_drop)                 # ties pull every pair towards 50:50
    assert np.all(hi - lo > 10) and np.all(hi_sc - lo_sc > 10)   # no zero-width interval
    assert abs(bt.mean() - 1000) < 1e-9 and abs(elo1.mean() - 1000) < 1e-6
