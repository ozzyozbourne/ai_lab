"""Selective evaluation with an agreement guarantee and a judge cascade (Chapter 4.11, #ppi).

In the spirit of Trust or Escalate (Jung, Brahman & Choi, 2024): a judge reports a confidence
with each pairwise verdict. On a human-labelled calibration set we choose the lowest confidence
threshold lambda such that, among items whose confidence is >= lambda, the Clopper-Pearson
upper bound on disagreement with humans is <= alpha (fixed-sequence testing from high to low
thresholds, so the guarantee holds with probability >= 1 - delta). Items below the threshold are
escalated: cheap judge -> strong judge -> human.

The headline target (97%) is above the strong judge's unfiltered agreement (0.960), so the
guarantee has to be bought by escalating some items to humans. A sweep over targets
0.85 / 0.90 / 0.95 / 0.97 then shows the coverage-vs-guarantee trade-off.

Run: python3 code/ch04/trust_or_escalate.py
"""
from __future__ import annotations

import math

import numpy as np

ALPHA, DELTA = 0.03, 0.10          # headline target: >= 97% agreement with humans, with probability >= 90%
SWEEP = (0.85, 0.90, 0.95, 0.97)   # agreement targets for the coverage-vs-guarantee table
CHEAP, STRONG = (4.5, 6.0), (5.5, 4.0)   # (skill, slope): P(agree) = sigmoid(skill - slope * difficulty)
COST = {"cheap": 1.0, "strong": 15.0, "human": 200.0}   # relative cost per item (illustrative)


def binom_cdf(k: int, n: int, p: float) -> float:
    if p <= 0:
        return 1.0
    if p >= 1:
        return 0.0 if k < n else 1.0
    return sum(math.exp(math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1)
                        + i * math.log(p) + (n - i) * math.log1p(-p)) for i in range(k + 1))


def cp_upper(k: int, n: int, delta: float) -> float:
    """One-sided Clopper-Pearson upper bound on a rate after k errors in n trials."""
    if k == n:
        return 1.0
    lo, hi = k / n, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if binom_cdf(k, n, mid) > delta:
            lo = mid
        else:
            hi = mid
    return hi


def calibrate(conf: np.ndarray, agree: np.ndarray, alpha: float = ALPHA, steps: int = 10,
              min_n: int = 200) -> float | None:
    """Fixed-sequence test over thresholds at confidence quantiles (coverage 10%, 20%, ..., 100%),
    skipping coverages that would select fewer than min_n items.

    The candidate thresholds depend only on the confidences, never on the labels. We move from
    high to low confidence and stop at the first threshold whose upper bound exceeds alpha.
    """
    coverage = np.arange(1, steps + 1) / steps
    coverage = coverage[coverage * len(conf) >= min_n]
    grid = np.quantile(conf, 1 - coverage)
    chosen = None
    for lam in grid:
        sel = conf >= lam
        if cp_upper(int((~agree[sel]).sum()), int(sel.sum()), DELTA) <= alpha:
            chosen = float(lam)
        else:
            break
    return chosen


def mock_judge(difficulty: np.ndarray, skill: float, slope: float, rng) -> tuple[np.ndarray, np.ndarray]:
    """Returns (agrees_with_human, confidence). Confidence is a noisy, roughly calibrated estimate."""
    p_agree = 1 / (1 + np.exp(-(skill - slope * difficulty)))
    agree = rng.random(len(difficulty)) < p_agree
    conf = np.clip(p_agree + rng.normal(0, 0.03, len(difficulty)), 0.5, 1.0)
    return agree, conf


def run(rng, alpha: float = ALPHA, verbose: bool = False) -> dict:
    # Each item has a difficulty for each judge; the two are only partly correlated (rho ~ 0.5),
    # because different judges find different items hard.
    def difficulties(n):
        shared = rng.random(n)
        return shared, np.clip(0.5 * shared + 0.5 * rng.random(n), 0, 1)
    dc_cal, ds_cal = difficulties(2000)
    dc_test, ds_test = difficulties(5000)
    d_test = dc_test
    cheap_cal, strong_cal = mock_judge(dc_cal, *CHEAP, rng), mock_judge(ds_cal, *STRONG, rng)
    (a_c, c_c), (a_s, c_s) = mock_judge(dc_test, *CHEAP, rng), mock_judge(ds_test, *STRONG, rng)
    n = len(d_test)

    # Strategy B: strong judge alone, calibrated on all calibration items, abstentions -> humans
    lam_alone = calibrate(strong_cal[1], strong_cal[0], alpha) or 1.01
    trust_b = c_s >= lam_alone
    cost_b = COST["strong"] + COST["human"] * (~trust_b).mean()

    # Strategy C: cascade cheap -> strong -> human; stage 2 calibrated on the items stage 1 escalates
    lam_c = calibrate(cheap_cal[1], cheap_cal[0], alpha) or 1.01
    esc = cheap_cal[1] < lam_c
    lam_s = calibrate(strong_cal[1][esc], strong_cal[0][esc], alpha) or 1.01
    stage1 = c_c >= lam_c
    stage2 = ~stage1 & (c_s >= lam_s)
    human = ~stage1 & ~stage2
    judged = stage1 | stage2
    agree_c = np.where(stage1, a_c, a_s)[judged].mean() if judged.any() else 1.0
    cost_c = COST["cheap"] + COST["strong"] * (~stage1).mean() + COST["human"] * human.mean()
    mean_or_1 = lambda x: float(x.mean()) if x.size else 1.0   # an empty selection meets the target vacuously
    out = {"agree_b": mean_or_1(a_s[trust_b]), "agree_c": float(agree_c),
           "cov_b": trust_b.mean(), "cov_c": judged.mean(), "cost_b": cost_b, "cost_c": cost_c}
    if verbose:
        print(f"Target: agreement with humans >= {1 - alpha:.0%} on judge-decided items, with probability >= {1 - DELTA:.0%}")
        print(f"Unfiltered agreement on 5,000 test items: cheap judge {a_c.mean():.3f}, strong judge {a_s.mean():.3f}")
        print(f"Thresholds from 2,000 human-labelled calibration items: strong alone {lam_alone:.3f},"
              f" cascade cheap {lam_c:.3f}, cascade strong (on {esc.sum()} escalated items) {lam_s:.3f}\n")
        print(f"{'strategy':<30}{'judge-decided':>14}{'to humans':>11}{'agreement':>11}{'cost/item':>11}")
        print(f"{'A. all human':<30}{0:>14.3f}{1:>11.3f}{1:>11.3f}{COST['human']:>11.1f}")
        print(f"{'B. strong judge + escalation':<30}{trust_b.mean():>14.3f}{(~trust_b).mean():>11.3f}"
              f"{a_s[trust_b].mean():>11.3f}{cost_b:>11.1f}")
        print(f"{'C. cheap -> strong -> human':<30}{judged.mean():>14.3f}{human.mean():>11.3f}{agree_c:>11.3f}{cost_c:>11.1f}")
        fmt = lambda x: f"{x.mean():.3f}" if x.size else "n/a"
        print(f"   of which cheap judge decided {stage1.mean():.3f} (agreement {fmt(a_c[stage1])}),"
              f" strong judge {stage2.mean():.3f} (agreement {fmt(a_s[stage2])})")
        assert cost_b < COST["human"] and cost_c < COST["human"]
        assert (~trust_b).mean() > 0.05 and human.mean() > 0.0   # the strong judge alone misses the target
        assert a_s.mean() < 1 - alpha                             # ... so some items really go to humans
    return out


def main() -> None:
    run(np.random.default_rng(21), verbose=True)
    rng = np.random.default_rng(99)
    res = [run(rng) for _ in range(100)]
    ok_b = np.mean([r["agree_b"] >= 1 - ALPHA for r in res])
    ok_c = np.mean([r["agree_c"] >= 1 - ALPHA for r in res])
    print(f"\nOver 100 repeated calibrate-then-deploy runs, fraction meeting the {1 - ALPHA:.0%} target:"
          f" B {ok_b:.2f}, C {ok_c:.2f}")
    cov_b, cov_c = np.array([r["cov_b"] for r in res]), np.array([r["cov_c"] for r in res])
    print(f"Coverage: mean B {cov_b.mean():.3f}, C {cov_c.mean():.3f};"
          f" runs certifying under 10% of items: B {np.mean(cov_b < 0.1):.2f}, C {np.mean(cov_c < 0.1):.2f}")
    assert ok_b >= 1 - DELTA and ok_c >= 1 - DELTA

    print("\nCoverage vs guarantee: 100 repeated runs per target (means; 'met' = fraction of runs at or above target)")
    print(f"{'target':>7} | {'B coverage':>10}{'agree':>7}{'met':>6}{'cost':>7} | {'C coverage':>10}{'agree':>7}{'met':>6}{'cost':>7}")
    rows = []
    for target in SWEEP:
        rng = np.random.default_rng(99)        # same seed as above: the 0.97 row repeats those runs
        rs = [run(rng, alpha=1 - target) for _ in range(100)]
        row = {k: float(np.mean([r[k] for r in rs])) for k in rs[0]}
        row["met_b"] = float(np.mean([r["agree_b"] >= target for r in rs]))
        row["met_c"] = float(np.mean([r["agree_c"] >= target for r in rs]))
        rows.append(row)
        print(f"{target:>7.2f} | {row['cov_b']:>10.3f}{row['agree_b']:>7.3f}{row['met_b']:>6.2f}{row['cost_b']:>7.1f}"
              f" | {row['cov_c']:>10.3f}{row['agree_c']:>7.3f}{row['met_c']:>6.2f}{row['cost_c']:>7.1f}")
        assert row["met_b"] >= 1 - DELTA - 0.02 and row["met_c"] >= 1 - DELTA - 0.02
    for a, b in zip(rows, rows[1:]):     # stricter target -> no more coverage, no lower cost
        assert b["cov_b"] <= a["cov_b"] + 1e-9 and b["cov_c"] <= a["cov_c"] + 1e-9
        assert b["cost_c"] >= a["cost_c"] - 1e-9


if __name__ == "__main__":
    main()
