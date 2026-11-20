"""Prediction-powered inference (PPI) for an online judge metric: correct the judge with a few human labels.

Chapter 9, section 9.13 (Online evaluation). N = 10,000 production answers are scored by an LLM judge
(no gold labels); n = 300 of them are also labelled by humans. True faithfulness rate 0.74; the judge
has TPR 0.95 and FPR 0.40, so it says "faithful" about 80% of the time.
  PPI estimate  theta_PP = mean(f on N) - mean(f - Y on n)
  variance      Var(f)/N + Var(f - Y)/n
(Angelopoulos et al. 2023; ARES uses the same idea.) Compares naive judge mean, human-only mean and
PPI over 1,000 simulated weeks: bias, CI width and 95% CI coverage.
Run:  python3 code/ch09/ppi_online.py
Expected key output: worked example 0.80 - 0.06 = 0.74; naive judge coverage 0%, human-only and PPI
about 95%, PPI CI 14% narrower than human-only; with a better judge (TPR .97, FPR .05) PPI is
54% narrower. Rogan-Gladen (p_obs - FPR)/(TPR - FPR), with TPR and FPR estimated on the same 300 labels
and a delta-method SE, is also nearly unbiased: (0.807 - 0.40)/(0.95 - 0.40) = 0.740.
"""
from __future__ import annotations

import numpy as np

Z = 1.959964


def ppi_mean_ci(y_lab: np.ndarray, f_lab: np.ndarray, f_unlab: np.ndarray) -> tuple[float, float]:
    rect = f_lab - y_lab
    est = f_unlab.mean() - rect.mean()
    se = np.sqrt(f_unlab.var(ddof=1) / len(f_unlab) + rect.var(ddof=1) / len(rect))
    return est, se


def rogan_gladen_ci(y_lab: np.ndarray, f_lab: np.ndarray, f_unlab: np.ndarray) -> tuple[float, float]:
    """theta = (p_obs - FPR) / (TPR - FPR), with TPR/FPR estimated on the labelled sample.
    Delta-method SE: Var(p)/J^2 + (theta^2 Var(TPR) + (1 - theta)^2 Var(FPR)) / J^2, J = TPR - FPR."""
    pos, neg = y_lab == 1, y_lab == 0
    tpr, fpr, p = f_lab[pos].mean(), f_lab[neg].mean(), f_unlab.mean()
    j = tpr - fpr
    theta = (p - fpr) / j
    var = (p * (1 - p) / len(f_unlab) + theta ** 2 * tpr * (1 - tpr) / pos.sum()
           + (1 - theta) ** 2 * fpr * (1 - fpr) / neg.sum()) / j ** 2
    return theta, np.sqrt(var)


def simulate(true_p: float, tpr: float, fpr: float, N: int, n: int, sims: int, rng) -> dict:
    out = {k: {"est": [], "cover": [], "width": []} for k in ("judge", "human", "ppi", "rg")}
    for _ in range(sims):
        y = rng.random(N + n) < true_p                      # unobserved truth for every item
        f = np.where(y, rng.random(N + n) < tpr, rng.random(N + n) < fpr).astype(float)
        y = y.astype(float)
        f_u, f_l, y_l = f[:N], f[N:], y[N:]                 # the labelled n are a random sample
        cands = {
            "judge": (f_u.mean(), f_u.std(ddof=1) / np.sqrt(N)),
            "human": (y_l.mean(), y_l.std(ddof=1) / np.sqrt(n)),
            "ppi": ppi_mean_ci(y_l, f_l, f_u),
            "rg": rogan_gladen_ci(y_l, f_l, f_u),
        }
        for k, (est, se) in cands.items():
            out[k]["est"].append(est)
            out[k]["cover"].append(abs(est - true_p) <= Z * se)
            out[k]["width"].append(2 * Z * se)
    return {k: {m: float(np.mean(v)) for m, v in d.items()} for k, d in out.items()}


if __name__ == "__main__":
    judge_N, judge_n, human_n = 0.80, 0.82, 0.76
    rect = judge_n - human_n
    print(f"worked example: judge on N = {judge_N:.2f}; on the labelled 300 judge {judge_n:.2f} vs humans "
          f"{human_n:.2f}; rectifier {rect:.2f}; PPI = {judge_N - rect:.2f}")
    assert abs(judge_N - rect - 0.74) < 1e-9
    p, tpr, fpr = 0.74, 0.95, 0.40
    p_obs = p * tpr + (1 - p) * fpr
    print(f"judge positive rate implied by TPR/FPR: {p_obs:.3f}")
    print(f"Rogan-Gladen with known TPR/FPR: ({p_obs:.3f} - {fpr}) / ({tpr} - {fpr}) = {(p_obs - fpr) / (tpr - fpr):.3f}")
    rng = np.random.default_rng(2024)
    res = simulate(p, tpr, fpr, 10_000, 300, 1000, rng)
    print(f"\n1,000 simulated weeks, true rate {p}, N = 10,000 judged, n = 300 human-labelled")
    print(f"{'estimator':<13} {'mean est':>9} {'bias':>7} {'95% CI width':>13} {'coverage':>9}")
    for k, lab in (("judge", "judge only"), ("human", "humans only"), ("ppi", "PPI"), ("rg", "Rogan-Gladen")):
        r = res[k]
        print(f"{lab:<13} {r['est']:>9.3f} {r['est'] - p:>+7.3f} {r['width']:>13.3f} {r['cover']:>9.1%}")
    gain = 1 - res["ppi"]["width"] / res["human"]["width"]
    print(f"PPI interval is {gain:.0%} narrower than humans-only")
    good = simulate(p, 0.97, 0.05, 10_000, 300, 1000, rng)
    gain2 = 1 - good["ppi"]["width"] / good["human"]["width"]
    print(f"with a better judge (TPR 0.97, FPR 0.05): PPI coverage {good['ppi']['cover']:.1%}, "
          f"{gain2:.0%} narrower than humans-only")
    assert abs(res["rg"]["est"] - p) < 0.01 and 0.90 < res["rg"]["cover"] < 0.98
    assert res["judge"]["cover"] < 0.01 and 0.93 < res["ppi"]["cover"] < 0.97
    assert abs(res["ppi"]["est"] - p) < 0.003 and 0.10 < gain < 0.25 and gain2 > gain
