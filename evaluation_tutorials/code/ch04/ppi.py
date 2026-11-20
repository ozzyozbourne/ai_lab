"""Prediction-powered inference (PPI) with a lenient LLM judge (Chapter 4.11, #ppi; Figure 4.4).

Estimate a true pass rate theta from N judge-only items and n items labelled by both a judge
and a human:
    theta_PP = mean(f(X_U)) - mean(f(X_L) - Y_L)        (judge mean minus the "rectifier")
    Var      = Var(f) / N + Var(f - Y) / n               -> CLT 95% CI
Part 1 reproduces the chapter's worked example (0.72 vs naive 0.80) and its CI by hand.
Part 1b corrects the same data with the judge's TPR/TNR (Rogan-Gladen, 0.73) and bootstraps a CI.
Part 2 simulates a judge that is 8 points too lenient: the naive judge mean is biased,
the human-only CI is wide, PPI is unbiased and narrower.
Part 3 shows the gain shrinking as the judge gets noisier, and power-tuned PPI++ (lambda-hat,
the ppi_py default) never doing worse than human-only.
Part 4 compares two systems A and B scored on the same items (a paired A/B test): PPI applied to
the per-item differences f_A - f_B and Y_A - Y_B. A judge equally lenient on both cancels out;
a judge lenient only toward the verbose system B flips the naive verdict, and PPI recovers it.

Run: python3 code/ch04/ppi.py
"""
from __future__ import annotations

import numpy as np

Z = 1.959964


def ppi_mean(y_l, f_l, f_u, lam: float = 1.0):
    """PPI (lam = 1) or power-tuned PPI++ for a mean: theta = mean(Y_L) + lam * (mean f_U - mean f_L)."""
    n, N = len(y_l), len(f_u)
    theta = y_l.mean() + lam * (f_u.mean() - f_l.mean())
    var = lam ** 2 * f_u.var(ddof=1) / N + (y_l - lam * f_l).var(ddof=1) / n
    se = np.sqrt(var)
    return theta, theta - Z * se, theta + Z * se


def lam_hat(y_l, f_l, f_u) -> float:
    n, N = len(y_l), len(f_u)
    f_all = np.concatenate([f_l, f_u])
    return float(np.cov(y_l, f_l)[0, 1] / ((1 + n / N) * f_all.var(ddof=1)))


def classical(y):
    se = y.std(ddof=1) / np.sqrt(len(y))
    return y.mean(), y.mean() - Z * se, y.mean() + Z * se


def judge_labels(y: np.ndarray, tpr: float, fpr: float, rng) -> np.ndarray:
    return np.where(y, rng.random(len(y)) < tpr, rng.random(len(y)) < fpr).astype(float)


def worked_example() -> None:
    N, n = 10_000, 200
    judge_u = 0.80
    # 200 labelled items: judge PASS 156 (0.78), human PASS 140 (0.70); 20 judge-pass/human-fail, 4 the reverse
    d = np.array([1] * 20 + [-1] * 4 + [0] * 176, float)        # f - Y on the labelled set
    rect = d.mean()
    theta = judge_u - rect
    var = judge_u * (1 - judge_u) / N + (np.mean(d ** 2) - rect ** 2) / n
    lo, hi = theta - Z * np.sqrt(var), theta + Z * np.sqrt(var)
    h_se = np.sqrt(0.70 * 0.30 / n)
    print("Part 1: worked example")
    print(f"  judge mean on N=10,000: 0.80; on n=200 labelled: judge 0.78, human 0.70; rectifier = {rect:.2f}")
    print(f"  PPI estimate = 0.80 - {rect:.2f} = {theta:.2f}   95% CI [{lo:.3f}, {hi:.3f}]   (naive judge-only: 0.80)")
    print(f"  human-only estimate = 0.70   95% CI [{0.70 - Z * h_se:.3f}, {0.70 + Z * h_se:.3f}]")
    assert abs(theta - 0.72) < 1e-12 and abs(lo - 0.673) < 1e-3 and abs(hi - 0.767) < 1e-3


def rogan_gladen(q: float, tpr: float, tnr: float) -> float:
    """Rogan-Gladen (1978) correction of an observed judge pass rate q; needs Youden's J = TPR + TNR - 1 > 0."""
    j = tpr + tnr - 1
    if j <= 0:
        raise ValueError("TPR + TNR must exceed 1: the judge is no better than chance")
    return min(1.0, max(0.0, (q + tnr - 1) / j))


def rogan_gladen_example(B: int = 4000) -> None:
    """The worked labelled set again, corrected with TPR/TNR instead of the PPI rectifier; bootstrap CI."""
    N = 10_000
    y = np.array([1] * 140 + [0] * 60)                                  # human labels, 0.70 pass
    f = np.array([1] * 136 + [0] * 4 + [1] * 20 + [0] * 40)             # judge labels on the same 200 items
    tpr, tnr = f[y == 1].mean(), 1 - f[y == 0].mean()
    theta = rogan_gladen(0.80, tpr, tnr)
    rng = np.random.default_rng(16)
    boots = []
    for _ in range(B):                       # resample the labelled set (TPR/TNR uncertainty) and the unlabelled set
        idx = rng.integers(0, len(y), len(y))
        yb, fb = y[idx], f[idx]
        qb = rng.binomial(N, 0.80) / N
        boots.append(rogan_gladen(qb, fb[yb == 1].mean(), 1 - fb[yb == 0].mean()))
    lo, hi = np.percentile(boots, [2.5, 97.5])
    print("\nPart 1b: Rogan-Gladen correction on the same labelled set")
    print(f"  TPR = 136/140 = {tpr:.3f}   TNR = 40/60 = {tnr:.3f}   Youden J = {tpr + tnr - 1:.3f}")
    print(f"  theta_RG = (0.80 + {tnr:.3f} - 1) / {tpr + tnr - 1:.3f} = {theta:.3f}   (PPI: 0.72; naive: 0.80)")
    print(f"  bootstrap 95% CI (B = {B}, resampling TPR/TNR and the judge rate) = [{lo:.3f}, {hi:.3f}]")
    assert abs(tpr - 136 / 140) < 1e-12 and abs(tnr - 40 / 60) < 1e-12 and abs(theta - 0.7313) < 1e-3
    assert lo < 0.70 < hi and (hi - lo) > 0.767 - 0.673               # wider than the PPI interval here


def simulate(reps: int = 1000) -> dict:
    rng = np.random.default_rng(12)
    N, n, p = 10_000, 200, 0.70
    tpr, fpr = 0.95, 0.383              # judge mean = 0.7*0.95 + 0.3*0.383 = 0.78: 8 points lenient
    out = {k: [] for k in ("naive", "human", "ppi")}
    for _ in range(reps):
        y_u = rng.random(N) < p
        y_l = rng.random(n) < p
        f_u, f_l = judge_labels(y_u, tpr, fpr, rng), judge_labels(y_l, tpr, fpr, rng)
        out["naive"].append((f_u.mean(),) + tuple(f_u.mean() + np.array([-Z, Z]) * f_u.std(ddof=1) / np.sqrt(N)))
        out["human"].append(classical(y_l.astype(float)))
        out["ppi"].append(ppi_mean(y_l.astype(float), f_l, f_u))
    print(f"\nPart 2: {reps} simulated studies, true pass rate {p}, judge {100 * (0.7 * tpr + 0.3 * fpr - p):+.0f} points lenient,"
          f" N = {N:,}, n = {n}")
    print(f"{'estimator':<22}{'mean estimate':>14}{'mean CI width':>15}{'coverage of 0.70':>18}")
    summary = {}
    for k, label in (("naive", "naive judge-only"), ("human", "human-only (n=200)"), ("ppi", "PPI")):
        a = np.array(out[k])
        cov = np.mean((a[:, 1] <= p) & (p <= a[:, 2]))
        summary[k] = (a[:, 0].mean(), (a[:, 2] - a[:, 1]).mean(), cov)
        print(f"{label:<22}{summary[k][0]:>14.3f}{summary[k][1]:>15.3f}{cov:>18.3f}")
        if k == "ppi":
            first = a[0]
    print(f"  first study, for Figure 4.4: naive {out['naive'][0][0]:.3f} [{out['naive'][0][1]:.3f}, {out['naive'][0][2]:.3f}],"
          f" human {out['human'][0][0]:.3f} [{out['human'][0][1]:.3f}, {out['human'][0][2]:.3f}],"
          f" PPI {first[0]:.3f} [{first[1]:.3f}, {first[2]:.3f}]")
    assert summary["naive"][2] < 0.05 and 0.92 < summary["ppi"][2] < 0.98 and 0.92 < summary["human"][2] < 0.98
    assert summary["ppi"][1] < summary["human"][1]
    return summary


def gain_vs_error() -> None:
    rng = np.random.default_rng(13)
    N, n, p, reps = 10_000, 200, 0.70, 300
    print("\nPart 3: gain shrinks as the judge gets noisier (judge flips a fraction e of labels, then +8pt leniency)")
    print(f"{'flip rate e':>12}{'judge-human agree':>19}{'PPI/human width':>17}{'eff. n (PPI)':>14}{'PPI++ width ratio':>19}")
    ratios = []
    for e in (0.0, 0.05, 0.10, 0.20, 0.35, 0.50):
        w_h, w_p, w_pp, agree = [], [], [], []
        for _ in range(reps):
            y_u, y_l = rng.random(N) < p, rng.random(n) < p
            def judge(y):
                f = np.where(rng.random(len(y)) < e, ~y, y)
                f = f | (rng.random(len(y)) < 0.08 / (1 - p) * (~f))   # add leniency on judged fails
                return f.astype(float)
            f_u, f_l = judge(y_u), judge(y_l)
            yl = y_l.astype(float)
            agree.append(np.mean(f_l == yl))
            _, lo, hi = classical(yl); w_h.append(hi - lo)
            _, lo, hi = ppi_mean(yl, f_l, f_u); w_p.append(hi - lo)
            _, lo, hi = ppi_mean(yl, f_l, f_u, lam_hat(yl, f_l, f_u)); w_pp.append(hi - lo)
        r = np.mean(w_p) / np.mean(w_h)
        ratios.append(r)
        print(f"{e:>12.2f}{np.mean(agree):>19.3f}{r:>17.3f}{n / r ** 2:>14.0f}{np.mean(w_pp) / np.mean(w_h):>19.3f}")
        assert np.mean(w_pp) / np.mean(w_h) < 1.02
    assert ratios[0] < 0.65 and ratios[-1] > 1.0 and all(a <= b + 0.02 for a, b in zip(ratios, ratios[1:]))


def paired_items(n: int, p_a: float, p_b: float, rng) -> tuple[np.ndarray, np.ndarray]:
    """Human labels for systems A and B on the same items; a shared item difficulty correlates them."""
    hard = rng.random(n) < 0.3
    y_a = rng.random(n) < np.where(hard, p_a - 0.25, p_a + 0.25 * 0.3 / 0.7)
    y_b = rng.random(n) < np.where(hard, p_b - 0.25, p_b + 0.25 * 0.3 / 0.7)
    return y_a, y_b


def ppi_diff(ya_l, yb_l, fa_l, fb_l, fa_u, fb_u):
    """PPI for theta = E[Y_A - Y_B]: ppi_mean applied to per-item differences."""
    return ppi_mean(ya_l.astype(float) - yb_l, fa_l - fb_l, fa_u - fb_u)


def ab_comparison(reps: int = 500) -> None:
    rng = np.random.default_rng(15)
    N, n, p_a, p_b = 10_000, 300, 0.74, 0.68             # truth: A is better by 6 points
    print(f"\nPart 4: paired A/B comparison on the same items; true pass rates A {p_a}, B {p_b} (A - B = {p_a - p_b:+.2f}),"
          f" N = {N:,}, n = {n}, {reps} studies")
    print(f"{'scenario':<34}{'estimator':<12}{'mean A-B':>9}{'mean CI width':>15}{'coverage':>10}{'says B>=A':>11}")
    # fpr_a, fpr_b: P(judge PASS | human FAIL) per system; TPR 0.95 for both. Judge means:
    # scenario 1: A 0.82, B 0.76 (both +8 pt); scenario 2: A 0.74 (unbiased), B 0.80 (+12 pt)
    scenarios = (("1. lenient on both (+8 pt each)", 0.45, 0.356), ("2. lenient only on verbose B", 0.142, 0.48))
    for name, fpr_a, fpr_b in scenarios:
        res = {"naive": [], "human": [], "PPI": []}
        for _ in range(reps):
            ya_u, yb_u = paired_items(N, p_a, p_b, rng)
            ya_l, yb_l = paired_items(n, p_a, p_b, rng)
            fa_u, fb_u = judge_labels(ya_u, 0.95, fpr_a, rng), judge_labels(yb_u, 0.95, fpr_b, rng)
            fa_l, fb_l = judge_labels(ya_l, 0.95, fpr_a, rng), judge_labels(yb_l, 0.95, fpr_b, rng)
            d_u = fa_u - fb_u
            se = d_u.std(ddof=1) / np.sqrt(N)
            res["naive"].append((d_u.mean(), d_u.mean() - Z * se, d_u.mean() + Z * se))
            res["human"].append(classical(ya_l.astype(float) - yb_l))
            res["PPI"].append(ppi_diff(ya_l, yb_l, fa_l, fb_l, fa_u, fb_u))
        out = {}
        for k, a in res.items():
            a = np.array(a)
            out[k] = (a[:, 0].mean(), (a[:, 2] - a[:, 1]).mean(), np.mean((a[:, 1] <= p_a - p_b) & (p_a - p_b <= a[:, 2])),
                      np.mean(a[:, 0] <= 0), np.mean(a[:, 1] > 0))
            label = {"human": "human-only"}.get(k, k)
            print(f"{name if k == 'naive' else '':<34}{label:<12}{out[k][0]:>+9.3f}{out[k][1]:>15.3f}{out[k][2]:>10.3f}{out[k][3]:>11.2f}")
        print(f"{'':<34}CI excludes 0 in favour of A: naive {out['naive'][4]:.2f}, human-only {out['human'][4]:.2f}, PPI {out['PPI'][4]:.2f}")
        assert 0.92 < out["PPI"][2] < 0.98 and out["PPI"][1] < out["human"][1]
        if name.startswith("1."):
            assert abs(out["naive"][0] - (p_a - p_b)) < 0.02          # equal leniency cancels in the difference
        else:
            assert out["naive"][0] < 0 and out["naive"][3] > 0.99     # naive verdict flipped: "B is better"
            assert out["PPI"][0] > 0.05 and out["PPI"][3] < 0.05      # PPI recovers A > B


if __name__ == "__main__":
    worked_example()
    rogan_gladen_example()
    simulate()
    gain_vs_error()
    ab_comparison()
