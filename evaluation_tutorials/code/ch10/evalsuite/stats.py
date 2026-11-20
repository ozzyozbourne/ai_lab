"""Statistics for the capstone (Chapter 5 methods, re-implemented with stdlib + NumPy).

wilson, mean_se, clustered_se (Miller 2024), paired_cluster_bootstrap, mcnemar, pass_at_k (Chen et al.
2021), pass_hat_k (tau-bench), mde (Miller's power formula), cohen_kappa, tpr_tnr, bootstrap_ci,
iqm (rliable), ppi_mean_ci (Angelopoulos et al. 2023), psi (drift), percentile.
"""
from __future__ import annotations

import math
from statistics import NormalDist

import numpy as np

Z95 = NormalDist().inv_cdf(0.975)   # 1.95996...


def wilson(k: float, n: int, z: float = Z95) -> tuple[float, float]:
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return (max(0.0, centre - half), min(1.0, centre + half))


def mean_se(x) -> tuple[float, float]:
    x = np.asarray(x, float)
    return float(x.mean()), float(x.std(ddof=1) / math.sqrt(len(x)))


def clustered_se(values, clusters) -> float:
    """SE_cl = (1/n) * sqrt( sum_c ( sum_{i in c} (s_i - mean) )^2 )   (Miller 2024, Sec. 2)."""
    v = np.asarray(values, float)
    m, n = v.mean(), len(v)
    sums: dict = {}
    for val, c in zip(v, clusters):
        sums[c] = sums.get(c, 0.0) + (val - m)
    return float(math.sqrt(sum(s * s for s in sums.values())) / n)


def paired_cluster_bootstrap(diffs, clusters, B: int = 4000, seed: int = 0) -> tuple[float, float, float]:
    """Mean paired difference and a 95% percentile CI, resampling whole clusters (templates)."""
    d = np.asarray(diffs, float)
    keys = sorted(set(clusters))
    idx = {k: np.array([i for i, c in enumerate(clusters) if c == k]) for k in keys}
    sums = np.array([d[idx[k]].sum() for k in keys])
    cnts = np.array([len(idx[k]) for k in keys])
    rng = np.random.default_rng(seed)
    pick = rng.integers(0, len(keys), size=(B, len(keys)))
    boots = sums[pick].sum(1) / cnts[pick].sum(1)
    lo, hi = np.percentile(boots, [2.5, 97.5])
    return float(d.mean()), float(lo), float(hi)


def mcnemar(b: int, c: int) -> tuple[float, float]:
    """b = baseline right & candidate wrong, c = baseline wrong & candidate right.
    Returns (chi2 with continuity correction, exact two-sided binomial p)."""
    n = b + c
    if n == 0:
        return 0.0, 1.0
    chi2 = (abs(b - c) - 1) ** 2 / n
    tail = sum(math.comb(n, i) for i in range(0, min(b, c) + 1)) / 2 ** n
    return chi2, min(1.0, 2 * tail)


def pass_at_k(n: int, c: int, k: int) -> float:
    if n - c < k:
        return 1.0
    return 1.0 - math.comb(n - c, k) / math.comb(n, k)


def pass_hat_k(n: int, c: int, k: int) -> float:
    """tau-bench's unbiased pass^k: probability that k trials drawn without replacement all pass."""
    return math.comb(c, k) / math.comb(n, k)


def mde(n: int, var_diff: float, alpha: float = 0.05, power: float = 0.80) -> float:
    """Minimum detectable effect for a paired comparison with per-task difference variance var_diff."""
    z = NormalDist().inv_cdf(1 - alpha / 2) + NormalDist().inv_cdf(power)
    return z * math.sqrt(var_diff / n)


def n_for_mde(delta: float, var_diff: float, alpha: float = 0.05, power: float = 0.80) -> int:
    z = NormalDist().inv_cdf(1 - alpha / 2) + NormalDist().inv_cdf(power)
    return math.ceil(z * z * var_diff / delta ** 2)


def tpr_tnr(y_true, y_pred) -> tuple[float, float]:
    """Positive class = FAIL (the thing we want the judge to catch)."""
    yt, yp = np.asarray(y_true, bool), np.asarray(y_pred, bool)
    return float((yp & yt).sum() / max(1, yt.sum())), float((~yp & ~yt).sum() / max(1, (~yt).sum()))


def cohen_kappa(y1, y2) -> float:
    a, b = np.asarray(y1, bool), np.asarray(y2, bool)
    po = float((a == b).mean())
    pe = float(a.mean() * b.mean() + (1 - a.mean()) * (1 - b.mean()))
    return (po - pe) / (1 - pe) if pe < 1 else 1.0


def bootstrap_ci(stat, n: int, B: int = 2000, seed: int = 0) -> tuple[float, float]:
    """Percentile CI of stat(idx) over B resamples of the indices 0..n-1."""
    rng = np.random.default_rng(seed)
    vals = [stat(rng.integers(0, n, n)) for _ in range(B)]
    lo, hi = np.nanpercentile(vals, [2.5, 97.5])
    return float(lo), float(hi)


def iqm(x) -> float:
    """Interquartile mean: mean of the middle 50% (rliable; trims floor(25%) from each end)."""
    s = np.sort(np.asarray(x, float))
    cut = int(math.floor(0.25 * len(s)))
    return float(s[cut:len(s) - cut].mean())


def ppi_mean_ci(y_lab, yhat_lab, yhat_unlab, alpha: float = 0.05) -> tuple[float, float, float]:
    """Prediction-powered estimate of a mean: judge mean on unlabeled data minus the rectifier."""
    y, f, fu = (np.asarray(a, float) for a in (y_lab, yhat_lab, yhat_unlab))
    theta = fu.mean() - (f - y).mean()
    se = math.sqrt(fu.var(ddof=1) / len(fu) + (f - y).var(ddof=1) / len(y))
    z = NormalDist().inv_cdf(1 - alpha / 2)
    return float(theta), float(theta - z * se), float(theta + z * se)


def psi(expected, actual, eps: float = 1e-6) -> float:
    e = np.clip(np.asarray(expected, float), eps, None)
    a = np.clip(np.asarray(actual, float), eps, None)
    return float(((a - e) * np.log(a / e)).sum())


def percentile(x, q: float) -> float:
    return float(np.percentile(np.asarray(x, float), q))


if __name__ == "__main__":
    # reproduce the Chapter 5 worked numbers this package relies on
    lo, hi = wilson(3, 10)
    assert abs(lo - 0.108) < 1e-3 and abs(hi - 0.603) < 1e-3
    assert abs(clustered_se([1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 1, 0], list("aaaabbbbcccc")) - 0.236) < 1e-3
    assert abs(pass_hat_k(10, 7, 3) - 0.292) < 1e-3 and abs(psi([.25] * 4, [.1, .2, .3, .4]) - 0.228) < 1e-3
    print("stats self-test ok")
