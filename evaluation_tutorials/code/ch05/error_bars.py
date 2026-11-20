"""Error bars for one model: CLT/Wald, Wilson, Clopper-Pearson and Beta-posterior intervals.

Chapter 5, section 5.2 (#error-bars) and Figure 5.2.
Run:  python3 code/ch05/error_bars.py
Shows: the worked examples (124/200 -> +/-6.7 points, 12/30 -> +/-17.5 points, 3/10 and 0/10),
then the exact coverage of each nominal-95% interval for n in {30, 100, 300, 1000}
(computed by summing over every possible number of correct answers), and a 10,000-run
Monte Carlo check of one cell, and coverage of z, Student-t, percentile-bootstrap and BCa intervals
for non-binary (continuous or rubric) scores at n = 20 and 30.
"""
from __future__ import annotations

import math

import numpy as np

from _common import beta_posterior, clopper_pearson, norm_cdf, norm_ppf, wald, wilson

Z = 1.959964


def vec_binom_cdf(k: np.ndarray, n: int, x: np.ndarray) -> np.ndarray:
    """P(Binomial(n, x_j) <= k_j) for vectors k, x (vectorised, log space)."""
    i = np.arange(n + 1)
    lc = np.array([math.lgamma(n + 1) - math.lgamma(t + 1) - math.lgamma(n - t + 1) for t in i])
    x = np.clip(x, 1e-300, 1 - 1e-16)
    logpmf = lc[None, :] + i[None, :] * np.log(x)[:, None] + (n - i)[None, :] * np.log1p(-x)[:, None]
    mask = i[None, :] <= k[:, None]
    return np.where(mask, np.exp(logpmf), 0.0).sum(axis=1)


def vec_beta_ppf(q: float, a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Quantile of Beta(a_j, b_j), integer parameters, all j at once (bisection)."""
    n = int(a[0] + b[0] - 1)  # a + b - 1 is constant across j in our use
    lo, hi = np.zeros(len(a)), np.ones(len(a))
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        cdf = 1.0 - vec_binom_cdf(a - 1, n, mid)  # P(Beta(a,b) <= mid)
        lo = np.where(cdf < q, mid, lo)
        hi = np.where(cdf < q, hi, mid)
    return 0.5 * (lo + hi)


def all_intervals(n: int) -> dict[str, tuple[np.ndarray, np.ndarray]]:
    """Lower/upper bounds of each method for every possible k = 0..n."""
    k = np.arange(n + 1)
    p = k / n
    h = Z * np.sqrt(p * (1 - p) / n)
    out = {"Wald (CLT)": (p - h, p + h)}
    d = 1 + Z * Z / n
    c = (p + Z * Z / (2 * n)) / d
    hw = Z * np.sqrt(p * (1 - p) / n + Z * Z / (4 * n * n)) / d
    out["Wilson"] = (c - hw, c + hw)
    cp_lo = np.zeros(n + 1)
    cp_hi = np.ones(n + 1)
    cp_lo[1:] = vec_beta_ppf(0.025, k[1:].astype(float), (n - k[1:] + 1).astype(float))
    cp_hi[:-1] = vec_beta_ppf(0.975, (k[:-1] + 1).astype(float), (n - k[:-1]).astype(float))
    out["Clopper-Pearson"] = (cp_lo, cp_hi)
    a, b = (1 + k).astype(float), (1 + n - k).astype(float)
    out["Beta(1,1) posterior"] = (vec_beta_ppf(0.025, a, b), vec_beta_ppf(0.975, a, b))
    return out


def exact_coverage(n: int, ps: np.ndarray) -> dict[str, float]:
    """Average over ps of P(interval contains p), summing exactly over k ~ Binomial(n, p)."""
    ints = all_intervals(n)
    k = np.arange(n + 1)
    lc = np.array([math.lgamma(n + 1) - math.lgamma(t + 1) - math.lgamma(n - t + 1) for t in k])
    res = {}
    for name, (lo, hi) in ints.items():
        covs = []
        for p in ps:
            pmf = np.exp(lc + k * math.log(p) + (n - k) * math.log1p(-p))
            covs.append(float(pmf[(lo <= p) & (p <= hi)].sum()))
        res[name] = float(np.mean(covs))
    return res


def main() -> None:
    print("Worked examples (95% intervals)")
    k, n = 124, 200
    p = k / n
    se = math.sqrt(p * (1 - p) / n)
    lo, hi = p - Z * se, p + Z * se
    print(f"  124/200: mean={p:.3f} SE={se:.4f} CI=[{lo:.3f}, {hi:.3f}] half-width={Z*se*100:.1f} pts")
    assert abs(se - 0.0343) < 1e-4 and abs(Z * se - 0.067) < 1e-3
    se30 = math.sqrt(0.4 * 0.6 / 30)
    print(f"  12/30  : mean=0.400 SE={se30:.4f} half-width={Z*se30*100:.1f} pts; one question = {100/30:.1f} pts")
    assert abs(se30 - 0.0894) < 1e-4 and abs(Z * se30 - 0.175) < 1e-3
    for kk, nn in [(3, 10), (0, 10), (124, 200)]:
        row = [("Wald", wald(kk, nn)), ("Wilson", wilson(kk, nn)),
               ("Clopper-Pearson", clopper_pearson(kk, nn)), ("Beta posterior", beta_posterior(kk, nn))]
        print(f"  {kk}/{nn}: " + "  ".join(f"{m}=[{a:.3f}, {b:.3f}]" for m, (a, b) in row))
    w = wilson(3, 10)
    assert abs(wald(3, 10)[0] - 0.016) < 1e-3 and abs(w[0] - 0.108) < 1e-3 and abs(w[1] - 0.603) < 1e-3
    assert wald(0, 10) == (0.0, 0.0) and abs(wilson(0, 10)[1] - 0.278) < 1e-3

    print("\nExact coverage of nominal 95% intervals")
    settings = {"p = 0.65": np.array([0.65]), "p = 0.90": np.array([0.90]),
                "p ~ U(0.05, 0.95)": np.linspace(0.05, 0.95, 91)}
    names = ["Wald (CLT)", "Wilson", "Clopper-Pearson", "Beta(1,1) posterior"]
    for label, ps in settings.items():
        print(f"  true accuracy {label}")
        print(f"    {'n':>5}  " + "  ".join(f"{m:>19}" for m in names))
        for n in (30, 100, 300, 1000):
            cov = exact_coverage(n, ps)
            print(f"    {n:>5}  " + "  ".join(f"{cov[m]*100:>18.1f}%" for m in names))
            if label.startswith("p ~"):
                assert cov["Clopper-Pearson"] >= 0.95  # exact interval never under-covers on average
                if n == 30:
                    assert cov["Wald (CLT)"] < cov["Wilson"]

    # Monte Carlo check of one cell: n = 30, p = 0.9
    rng = np.random.default_rng(5)
    ks = rng.binomial(30, 0.9, size=10_000)
    hits_wald = np.mean([wald(int(x), 30)[0] <= 0.9 <= wald(int(x), 30)[1] for x in ks])
    hits_wil = np.mean([wilson(int(x), 30)[0] <= 0.9 <= wilson(int(x), 30)[1] for x in ks])
    exact = exact_coverage(30, np.array([0.9]))
    print(f"\nMonte Carlo (10,000 runs, n=30, p=0.90): Wald {hits_wald*100:.1f}% (exact {exact['Wald (CLT)']*100:.1f}%), "
          f"Wilson {hits_wil*100:.1f}% (exact {exact['Wilson']*100:.1f}%)")
    assert abs(hits_wald - exact["Wald (CLT)"]) < 0.01

    nonbinary_coverage()


T975 = {20: 2.093, 30: 2.045}   # Student-t 0.975 quantiles for df = n - 1 = 19, 29
RUBRIC_P = np.array([0.06, 0.03, 0.02, 0.02, 0.02, 0.03, 0.05, 0.12, 0.25, 0.40])   # 1-10 rubric, skewed


def nonbinary_coverage(runs: int = 10_000, b: int = 1000) -> None:
    """Coverage of four 95% intervals for the mean of a skewed bounded score."""
    rng = np.random.default_rng(11)
    dists = {
        "Beta(5,2) score": (lambda size: rng.beta(5, 2, size), 5 / 7),
        "1-10 rubric": (lambda size: rng.choice(np.arange(1, 11), size=size, p=RUBRIC_P), float(RUBRIC_P @ np.arange(1, 11))),
    }
    print("\nNon-binary scores: coverage of nominal 95% intervals for the mean (10,000 runs, B = 1,000)")
    print(f"  {'score':<16} {'n':>3} {'z (CLT)':>8} {'t, n-1 df':>10} {'percentile':>11} {'BCa':>7}")
    res = {}
    for name, (gen, mu) in dists.items():
        for n in (20, 30):
            x = gen((runs, n)).astype(float)
            m, se = x.mean(axis=1), x.std(axis=1, ddof=1) / math.sqrt(n)
            cov_z = np.mean(np.abs(m - mu) <= Z * se)
            cov_t = np.mean(np.abs(m - mu) <= T975[n] * se)
            hit_p = hit_bca = 0
            for r in range(runs):
                xr = x[r]
                boot = xr[rng.integers(0, n, size=(b, n))].mean(axis=1)
                lo, hi = np.quantile(boot, [0.025, 0.975])
                hit_p += lo <= mu <= hi
                # BCa for the mean: jackknife values are (sum - x_i) / (n - 1)
                z0 = norm_ppf(np.clip((boot < m[r]).mean(), 1e-4, 1 - 1e-4))
                jack = (xr.sum() - xr) / (n - 1)
                dj = jack.mean() - jack
                acc = (dj**3).sum() / (6 * ((dj**2).sum()) ** 1.5 + 1e-300)
                zs = np.array([-Z, Z])
                qs = [norm_cdf(float(v)) for v in z0 + (z0 + zs) / (1 - acc * (z0 + zs))]
                lo, hi = np.quantile(boot, qs)
                hit_bca += lo <= mu <= hi
            res[(name, n)] = (cov_z, cov_t, hit_p / runs, hit_bca / runs)
            print(f"  {name:<16} {n:>3} " + " ".join(f"{v*100:>{w}.1f}%" for v, w in zip(res[(name, n)], (7, 9, 10, 6))))
    for key, (cz, ct, cp, cb) in res.items():
        assert ct > cz and max(ct, cb) >= cp   # t (or BCa) beats z and the plain percentile bootstrap


if __name__ == "__main__":
    main()
