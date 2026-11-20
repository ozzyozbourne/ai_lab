"""Shared helpers for Chapter 5 (not run directly by code/run_all.py).

Normal CDF / quantile, binomial tails and the four one-sample intervals for a
proportion (Wald, Wilson, Clopper-Pearson, Beta posterior), all with the
standard library only, so no SciPy is needed.
"""
from __future__ import annotations

import math


def norm_cdf(x: float) -> float:
    """Standard normal CDF via the error function."""
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def norm_ppf(q: float) -> float:
    """Standard normal quantile by bisection on norm_cdf (accurate to ~1e-12)."""
    if not 0.0 < q < 1.0:
        raise ValueError("q must be in (0, 1)")
    lo, hi = -40.0, 40.0
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if norm_cdf(mid) < q:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def binom_cdf(k: int, n: int, p: float) -> float:
    """P(X <= k) for X ~ Binomial(n, p), summed in log space for stability."""
    if k < 0:
        return 0.0
    if k >= n:
        return 1.0
    if p <= 0.0:
        return 1.0
    if p >= 1.0:
        return 0.0
    lp, lq = math.log(p), math.log1p(-p)
    total = 0.0
    for i in range(k + 1):
        total += math.exp(math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1) + i * lp + (n - i) * lq)
    return min(1.0, total)


def _bisect(f, lo: float, hi: float, iters: int = 100) -> float:
    """Root of a monotone increasing f on [lo, hi]."""
    for _ in range(iters):
        mid = 0.5 * (lo + hi)
        if f(mid) < 0:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def beta_cdf_int(x: float, a: int, b: int) -> float:
    """CDF of Beta(a, b) for integer a, b >= 1, via the binomial identity
    P(Beta(a, b) <= x) = P(Binomial(a + b - 1, x) >= a)."""
    return 1.0 - binom_cdf(a - 1, a + b - 1, x)


def beta_ppf_int(q: float, a: int, b: int) -> float:
    """Quantile of Beta(a, b) for integer parameters, by bisection."""
    return _bisect(lambda x: beta_cdf_int(x, a, b) - q, 0.0, 1.0)


def wald(k: int, n: int, z: float = 1.959964) -> tuple[float, float]:
    """CLT ('Wald') interval p_hat +/- z * sqrt(p_hat (1 - p_hat) / n), clipped to [0, 1]."""
    p = k / n
    h = z * math.sqrt(p * (1 - p) / n)
    return max(0.0, p - h), min(1.0, p + h)


def wilson(k: int, n: int, z: float = 1.959964) -> tuple[float, float]:
    """Wilson score interval."""
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return max(0.0, centre - half), min(1.0, centre + half)


def clopper_pearson(k: int, n: int, alpha: float = 0.05) -> tuple[float, float]:
    """Exact (Clopper-Pearson) interval: invert the two one-sided binomial tests."""
    lo = 0.0 if k == 0 else beta_ppf_int(alpha / 2, k, n - k + 1)
    hi = 1.0 if k == n else beta_ppf_int(1 - alpha / 2, k + 1, n - k)
    return lo, hi


def beta_posterior(k: int, n: int, alpha: float = 0.05) -> tuple[float, float]:
    """Equal-tailed credible interval of the Beta(1 + k, 1 + n - k) posterior (uniform prior)."""
    return beta_ppf_int(alpha / 2, 1 + k, 1 + n - k), beta_ppf_int(1 - alpha / 2, 1 + k, 1 + n - k)


def binom_two_sided_p(b: int, n: int) -> float:
    """Exact two-sided binomial test of b successes out of n at p = 0.5 (the exact McNemar test)."""
    if n == 0:
        return 1.0
    lo = min(b, n - b)
    return min(1.0, 2.0 * binom_cdf(lo, n, 0.5))
