"""A/B testing an LLM feature: sample size, power, CUPED variance reduction, and the cost of peeking.

Chapter 9, section 9.15 (A/B testing LLM features).
  sample size : n per arm ~ 16 sigma^2 / delta^2 (alpha 0.05 two-sided, power 0.8; Kohavi's rule)
  CUPED       : Y_cv = Y - theta (X - mean X), theta = Cov(X, Y) / Var(X); Var(Y_cv) = Var(Y)(1 - rho^2)
  peeking     : A/A tests checked daily with a fixed z > 1.96 rule, stopping at the first "win"
Run:  python3 code/ch09/ab_test_sim.py
Expected key output: 9,600 per arm for p = 0.6, delta = 2 pts (exact formula 9,419); simulated power
about 0.80; CUPED with rho = 0.6 cuts variance by about 36% and lifts power; peeking at 20 daily looks
inflates the false-positive rate from 5% to about 25%; a constant boundary of |z| > 2.68 (found by simulation) restores 5%;
an O'Brien-Fleming-shaped boundary c*sqrt(K/k) also restores 5% and ends near 2.0 at the final look.
Two checks before reading any result:
  SRM         : chi-square goodness of fit of arm counts vs the planned split (50,500 vs 49,500 -> chi2 10.0, p 0.0016)
  ratio metric: randomised by user, measured per request -> delta-method SE over users, not a per-request binomial SE
"""
from __future__ import annotations

import math

import numpy as np

Z_A, Z_B = 1.959964, 0.841621          # z_{0.975}, z_{0.80}


def n_rule_of_thumb(var: float, delta: float) -> float:
    return 16 * var / delta ** 2


def n_exact(var: float, delta: float) -> float:
    return 2 * (Z_A + Z_B) ** 2 * var / delta ** 2


def power_sim(p: float, delta: float, n: int, sims: int, rng) -> float:
    a = rng.binomial(n, p, sims) / n
    b = rng.binomial(n, p + delta, sims) / n
    pool = (a + b) / 2
    z = (b - a) / np.sqrt(2 * pool * (1 - pool) / n)
    return float(np.mean(np.abs(z) > Z_A))


def cuped_demo(n: int, rho: float, delta: float, sims: int, rng) -> tuple[float, float, float]:
    """Continuous metric (e.g. weekly accepted characters, standardised). Returns variance ratio and
    power without / with CUPED."""
    hits_raw = hits_cv = 0
    ratios = []
    for _ in range(sims):
        x = rng.standard_normal((2, n))                                   # pre-period covariate
        y = rho * x + math.sqrt(1 - rho ** 2) * rng.standard_normal((2, n))
        y[1] += delta
        xa, ya = x.ravel(), y.ravel()
        theta = np.cov(xa, ya)[0, 1] / xa.var(ddof=1)                     # pooled over both arms
        ycv = y - theta * (x - xa.mean())
        ratios.append(ycv.var() / y.var())
        for arr, which in ((y, "raw"), (ycv, "cv")):
            se = math.sqrt(arr[0].var(ddof=1) / n + arr[1].var(ddof=1) / n)
            sig = abs(arr[1].mean() - arr[0].mean()) / se > Z_A
            if which == "raw":
                hits_raw += sig
            else:
                hits_cv += sig
    return float(np.mean(ratios)), hits_raw / sims, hits_cv / sims


def peeking_fpr(looks: int, per_look: int, sims: int, rng, z_crit: float = Z_A, p: float = 0.6) -> float:
    """A/A test: stop and declare a winner at the first look where |z| > z_crit."""
    a = rng.binomial(per_look, p, (sims, looks)).cumsum(axis=1)
    b = rng.binomial(per_look, p, (sims, looks)).cumsum(axis=1)
    n = per_look * np.arange(1, looks + 1)
    pa, pb = a / n, b / n
    pool = (pa + pb) / 2
    z = (pb - pa) / np.sqrt(2 * pool * (1 - pool) / n)
    return float(np.mean((np.abs(z) > z_crit).any(axis=1)))


def obf_fpr(c: float, looks: int, per_look: int, sims: int, rng, p: float = 0.6) -> float:
    """A/A test with an O'Brien-Fleming-shaped boundary: reject at look k if |z_k| > c * sqrt(K / k)."""
    bounds = c * np.sqrt(looks / np.arange(1, looks + 1))
    a = rng.binomial(per_look, p, (sims, looks)).cumsum(axis=1)
    b = rng.binomial(per_look, p, (sims, looks)).cumsum(axis=1)
    n = per_look * np.arange(1, looks + 1)
    pa, pb = a / n, b / n
    pool = (pa + pb) / 2
    z = (pb - pa) / np.sqrt(2 * pool * (1 - pool) / n)
    return float(np.mean((np.abs(z) > bounds).any(axis=1)))


def srm_check(counts, split) -> tuple[float, float]:
    """Sample-ratio-mismatch test: chi-square goodness of fit of observed arm counts against the planned
    split. Returns (chi2, p). For two arms (df = 1) the p-value is erfc(sqrt(chi2 / 2))."""
    counts = np.asarray(counts, dtype=float)
    expected = counts.sum() * np.asarray(split, dtype=float) / np.sum(split)
    chi2 = float(np.sum((counts - expected) ** 2 / expected))
    assert len(counts) == 2, "df = 1 closed form; use a chi-square table for more arms"
    return chi2, math.erfc(math.sqrt(chi2 / 2))


def ratio_aa(n_users: int, sims: int, rng) -> tuple[float, float, float, float]:
    """A/A tests of a per-request acceptance rate R = sum(Y_i) / sum(N_i) with users as the randomisation
    unit. Requests per user are heavy-tailed (lognormal) and each user has their own acceptance propensity,
    so requests within a user are correlated. Returns mean naive SE, mean delta-method SE, naive FPR, delta FPR
    (all for the difference between arms)."""
    N = np.maximum(1, np.round(rng.lognormal(1.5, 1.0, (sims, 2, n_users)))).astype(int)
    prop = rng.beta(2, 3, (sims, 2, n_users))                       # per-user acceptance propensity
    Y = rng.binomial(N, prop)
    sY, sN = Y.sum(axis=2), N.sum(axis=2)
    R = sY / sN                                                      # (sims, 2)
    naive_var = R * (1 - R) / sN                                     # treats every request as independent
    muN = N.mean(axis=2)
    vY, vN = Y.var(axis=2, ddof=1), N.var(axis=2, ddof=1)
    cYN = ((Y - Y.mean(axis=2, keepdims=True)) * (N - muN[..., None])).sum(axis=2) / (n_users - 1)
    delta_var = (vY - 2 * R * cYN + R ** 2 * vN) / (n_users * muN ** 2)
    diff = R[:, 1] - R[:, 0]
    se_naive = np.sqrt(naive_var.sum(axis=1))
    se_delta = np.sqrt(delta_var.sum(axis=1))
    return (float(se_naive.mean()), float(se_delta.mean()),
            float(np.mean(np.abs(diff) / se_naive > Z_A)), float(np.mean(np.abs(diff) / se_delta > Z_A)))


if __name__ == "__main__":
    rng = np.random.default_rng(42)
    p, delta = 0.6, 0.02
    var = p * (1 - p)
    n16, nex = n_rule_of_thumb(var, delta), n_exact(var, delta)
    print(f"thumbs-up rate {p}, MDE {delta:.2f}: n per arm = 16*{var:.2f}/{delta}^2 = {n16:,.0f}"
          f"  (exact 2(z_a+z_b)^2 var/delta^2 = {nex:,.0f})")
    pw = power_sim(p, delta, 9600, 4000, rng)
    print(f"simulated power at n = 9,600 per arm: {pw:.3f}")
    print(f"if only 5% of users leave feedback, users needed per arm = {9600 / 0.05:,.0f}")
    ratio, p_raw, p_cv = cuped_demo(2000, 0.6, 0.08, 500, rng)
    print(f"\nCUPED, rho = 0.6, n = 2,000 per arm, effect 0.08 sd: variance ratio {ratio:.3f} "
          f"(theory 1 - rho^2 = {1 - 0.36:.2f}); power {p_raw:.2f} -> {p_cv:.2f}")
    print("\npeeking in A/A tests (no true effect), 500 users per arm per day")
    fprs = {}
    for looks in (1, 2, 5, 10, 20):
        fprs[looks] = peeking_fpr(looks, 500, 20000, rng)
        print(f"  {looks:>2} looks, stop at first |z| > 1.96: false-positive rate {fprs[looks]:.3f}")
    # find the constant boundary that gives 5% over 20 looks (a Pocock-style boundary, by simulation)
    lo, hi = 1.96, 3.5
    for _ in range(25):
        mid = (lo + hi) / 2
        if peeking_fpr(20, 500, 20000, np.random.default_rng(7), z_crit=mid) > 0.05:
            lo = mid
        else:
            hi = mid
    print(f"  constant boundary for 5% over 20 looks (simulated): |z| > {hi:.2f}")
    # O'Brien-Fleming-shaped boundary c * sqrt(K/k), with c calibrated by simulation to 5% over 20 looks
    lo, hi = 1.5, 3.0
    for _ in range(25):
        mid = (lo + hi) / 2
        if obf_fpr(mid, 20, 500, 20000, np.random.default_rng(7)) > 0.05:
            lo = mid
        else:
            hi = mid
    c_obf = hi
    obf_check = obf_fpr(c_obf, 20, 500, 20000, np.random.default_rng(11))
    print(f"  O'Brien-Fleming-shaped boundary c*sqrt(20/k), c = {c_obf:.2f}: first look |z| > {c_obf * math.sqrt(20):.2f}, "
          f"final look |z| > {c_obf:.2f}; FPR on fresh sims {obf_check:.3f}")

    print("\ntwo checks before reading any result")
    chi2, p_srm = srm_check([50_500, 49_500], [1, 1])
    print(f"  SRM: 50,500 vs 49,500 at a planned 50/50 -> chi2 = {chi2:.1f}, p = {p_srm:.4f}"
          f"  ({'BROKEN experiment' if p_srm < 0.001 else 'investigate' if p_srm < 0.01 else 'ok'})")
    chi2_ok, p_ok = srm_check([50_100, 49_900], [1, 1])
    print(f"  SRM: 50,100 vs 49,900 at a planned 50/50 -> chi2 = {chi2_ok:.1f}, p = {p_ok:.3f}")
    se_n, se_d, fpr_n, fpr_d = ratio_aa(2000, 2000, np.random.default_rng(3))
    print(f"  ratio metric A/A (2,000 users per arm, lognormal requests per user, per-user propensity, 2,000 runs):")
    print(f"    naive per-request SE {se_n:.4f}  -> false-positive rate {fpr_n:.3f}")
    print(f"    delta-method SE      {se_d:.4f}  -> false-positive rate {fpr_d:.3f}   (SE ratio {se_d / se_n:.2f}x)")
    assert abs(chi2 - 10.0) < 1e-9 and p_srm < 0.01 and p_ok > 0.05
    assert se_n < se_d and fpr_n > 0.05 and 0.035 < fpr_d < 0.065
    assert 0.045 < obf_check < 0.056 and 1.9 < c_obf < 2.2 and hi < 2.68
    assert abs(n16 - 9600) < 1e-6 and 0.77 < pw < 0.83
    assert abs(ratio - 0.64) < 0.02 and p_cv > p_raw
    assert 0.04 < fprs[1] < 0.06 and fprs[20] > 0.2
