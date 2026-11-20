"""Agreement statistics from scratch (Chapter 4.3, #agreement).

Implements percent agreement, Cohen's kappa (+ TPR/TNR), quadratic-weighted kappa,
Fleiss' kappa, Krippendorff's alpha (nominal and interval), Pearson, Spearman and
Kendall tau-b, and checks every worked number quoted in the chapter:
  Cohen kappa = 0.60 (TPR 0.90, TNR 0.70), always-PASS kappa = 0,
  Krippendorff alpha = 0.611, Spearman rho = 0.829, Kendall tau = 0.600.
It ends with a sample-level vs system-level demo on a seeded mock judge, and a judge
self-agreement (test-retest) check: flip rate, kappa and Krippendorff alpha between repeated runs,
and the alt-test (Calderon et al., ACL 2025): can the judge replace a human annotator?

Run: python3 code/ch04/agreement_toolkit.py
"""
from __future__ import annotations

import itertools
import math
from collections import Counter

import numpy as np


# ---------- two raters, nominal labels ----------
def percent_agreement(a: list, b: list) -> float:
    return sum(x == y for x, y in zip(a, b)) / len(a)


def cohen_kappa(a: list, b: list) -> float:
    n = len(a)
    p_o = percent_agreement(a, b)
    ca, cb = Counter(a), Counter(b)
    p_e = sum((ca[k] / n) * (cb[k] / n) for k in set(a) | set(b))
    return 0.0 if p_e == 1 else (p_o - p_e) / (1 - p_e)


def tpr_tnr(human: list, judge: list, pos="PASS") -> tuple[float, float]:
    tp = sum(h == pos and j == pos for h, j in zip(human, judge))
    tn = sum(h != pos and j != pos for h, j in zip(human, judge))
    n_pos = sum(h == pos for h in human)
    return tp / n_pos, tn / (len(human) - n_pos)


def weighted_kappa(a: list[int], b: list[int], k: int) -> float:
    """Quadratic-weighted kappa for ordinal labels 1..k: 1 - sum(w*O)/sum(w*E)."""
    O = np.zeros((k, k))
    for x, y in zip(a, b):
        O[x - 1, y - 1] += 1
    O /= O.sum()
    E = np.outer(O.sum(1), O.sum(0))
    i, j = np.indices((k, k))
    W = (i - j) ** 2
    return 1 - (W * O).sum() / (W * E).sum()


# ---------- many raters ----------
def fleiss_kappa(items: list[list]) -> float:
    """Every item rated by the same number m of raters."""
    cats = sorted({v for it in items for v in it})
    m, n = len(items[0]), len(items)
    counts = np.array([[it.count(c) for c in cats] for it in items], float)
    P_i = ((counts ** 2).sum(1) - m) / (m * (m - 1))
    p_j = counts.sum(0) / (n * m)
    P_bar, P_e = P_i.mean(), (p_j ** 2).sum()
    return (P_bar - P_e) / (1 - P_e)


def krippendorff_alpha(units: list[list], metric: str = "nominal") -> float:
    """alpha = 1 - D_o / D_e via the coincidence matrix; units may have missing (None) values."""
    units = [[v for v in u if v is not None] for u in units]
    units = [u for u in units if len(u) >= 2]
    vals = sorted({v for u in units for v in u})
    idx = {v: i for i, v in enumerate(vals)}
    o = np.zeros((len(vals), len(vals)))
    for u in units:
        m = len(u)
        for i, j in itertools.permutations(range(m), 2):
            o[idx[u[i]], idx[u[j]]] += 1 / (m - 1)
    n_c = o.sum(1)
    N = n_c.sum()
    v = np.array(vals, float)
    delta = (v[:, None] != v[None, :]).astype(float) if metric == "nominal" else (v[:, None] - v[None, :]) ** 2
    D_o = (o * delta).sum() / N
    D_e = (np.outer(n_c, n_c) * delta).sum() / (N * (N - 1))
    return 1 - D_o / D_e


# ---------- correlations ----------
def rankdata(x) -> np.ndarray:
    x = np.asarray(x, float)
    order = x.argsort()
    r = np.empty(len(x))
    r[order] = np.arange(1, len(x) + 1)
    for val in np.unique(x):  # average ranks for ties
        r[x == val] = r[x == val].mean()
    return r


def pearson(x, y) -> float:
    return float(np.corrcoef(np.asarray(x, float), np.asarray(y, float))[0, 1])


def spearman(x, y) -> float:
    return pearson(rankdata(x), rankdata(y))


def kendall_tau_b(x, y) -> float:
    c = d = tx = ty = 0
    for i, j in itertools.combinations(range(len(x)), 2):
        sx, sy = np.sign(x[i] - x[j]), np.sign(y[i] - y[j])
        if sx == 0 and sy == 0:
            continue
        if sx == 0:
            tx += 1
        elif sy == 0:
            ty += 1
        elif sx == sy:
            c += 1
        else:
            d += 1
    return (c - d) / np.sqrt((c + d + tx) * (c + d + ty))


# ---------- can the judge replace a human? the alt-test (Calderon et al., ACL 2025) ----------
def _betacf(a: float, b: float, x: float) -> float:
    """Continued fraction for the regularized incomplete beta (Numerical Recipes, Lentz's method)."""
    tiny, qab, qap, qam = 1e-300, a + b, a + 1, a - 1
    c, d = 1.0, 1 - qab * x / qap
    d = 1 / (d if abs(d) > tiny else tiny)
    h = d
    for m in range(1, 300):
        m2 = 2 * m
        for aa in (m * (b - m) * x / ((qam + m2) * (a + m2)), -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))):
            d = 1 + aa * d
            d = 1 / (d if abs(d) > tiny else tiny)
            c = 1 + aa / c
            c = c if abs(c) > tiny else tiny
            h *= d * c
        if abs(d * c - 1) < 1e-12:
            break
    return h


def t_cdf(t: float, df: float) -> float:
    """Student-t CDF via the regularized incomplete beta I_x(df/2, 1/2), x = df / (df + t^2)."""
    x = df / (df + t * t)
    a, b = df / 2, 0.5
    lbeta = math.lgamma(a) + math.lgamma(b) - math.lgamma(a + b)
    front = math.exp(a * math.log(x) + b * math.log(1 - x) - lbeta)
    ib = front * _betacf(a, b, x) / a if x < (a + 1) / (a + b + 2) else 1 - front * _betacf(b, a, 1 - x) / b
    return 1 - 0.5 * ib if t > 0 else 0.5 * ib


def ttest_less(x, mu: float) -> float:
    """One-sided one-sample t-test p-value for H1: mean(x) < mu (scipy's ttest_1samp(..., alternative='less'))."""
    x = np.asarray(x, float)
    se = x.std(ddof=1) / math.sqrt(len(x))
    return t_cdf((x.mean() - mu) / se, len(x) - 1)


def benjamini_yekutieli(p: list[float], q: float = 0.05) -> list[int]:
    """Indices rejected by the Benjamini-Yekutieli FDR procedure (valid under any dependence)."""
    m = len(p)
    order = np.argsort(p)
    h_m = sum(1 / i for i in range(1, m + 1))
    k = max([r for r in range(1, m + 1) if p[order[r - 1]] <= r / m * q / h_m], default=0)
    return sorted(order[:k].tolist())


def alt_test(humans: dict[str, dict], llm: dict, epsilon: float = 0.2, q: float = 0.05) -> tuple[float, float, list]:
    """Leave-one-annotator-out alt-test, after nitaytech/alttest (accuracy scoring).
    For each annotator j: on every item, score j and the LLM by their agreement with the *remaining* annotators;
    test H0: P(j at least as good) - P(LLM at least as good) >= epsilon; BY-correct across annotators.
    Returns (winning rate = share of annotators beaten, advantage probability rho, p-values)."""
    p_vals, adv = [], []
    for j in humans:
        d, llm_ind = [], []
        for i, lab_j in humans[j].items():
            rest = [humans[h][i] for h in humans if h != j and i in humans[h]]
            if not rest:
                continue
            s_h = np.mean([lab_j == r for r in rest])
            s_l = np.mean([llm[i] == r for r in rest])
            llm_ind.append(float(s_l >= s_h))
            d.append(float(s_h >= s_l) - float(s_l >= s_h))
        p_vals.append(ttest_less(d, epsilon))
        adv.append(np.mean(llm_ind))
    return len(benjamini_yekutieli(p_vals, q)) / len(humans), float(np.mean(adv)), p_vals


def main() -> None:
    # Worked example 1: 100 items, human vs judge (45 / 5 / 15 / 35)
    human = ["PASS"] * 50 + ["FAIL"] * 50
    judge = ["PASS"] * 45 + ["FAIL"] * 5 + ["PASS"] * 15 + ["FAIL"] * 35
    po, k = percent_agreement(human, judge), cohen_kappa(human, judge)
    tpr, tnr = tpr_tnr(human, judge)
    print("Worked example: human vs judge on 100 items")
    print(f"  percent agreement p_o = {po:.3f}   Cohen kappa = {k:.3f}   TPR = {tpr:.2f}   TNR = {tnr:.2f}")
    assert abs(po - 0.80) < 1e-9 and abs(k - 0.60) < 1e-9 and abs(tpr - 0.90) < 1e-9 and abs(tnr - 0.70) < 1e-9

    # Imbalance trap: 95% truly pass, judge always says PASS
    human2 = ["PASS"] * 95 + ["FAIL"] * 5
    judge2 = ["PASS"] * 100
    po2, k2 = percent_agreement(human2, judge2), cohen_kappa(human2, judge2)
    tpr2, tnr2 = tpr_tnr(human2, judge2)
    print("Always-PASS judge on a 95%-pass set")
    print(f"  percent agreement p_o = {po2:.3f}   Cohen kappa = {k2:.3f}   TPR = {tpr2:.2f}   TNR = {tnr2:.2f}")
    assert abs(po2 - 0.95) < 1e-9 and abs(k2) < 1e-12 and tnr2 == 0.0

    # Ordinal 1-5 scores: off-by-one disagreements vs large disagreements
    h5 = [1, 2, 3, 4, 5, 3, 4, 2, 5, 1]
    near = [2, 2, 3, 5, 4, 3, 4, 3, 5, 1]   # disagreements all off by one
    far = [5, 2, 3, 1, 4, 3, 4, 5, 5, 1]    # same number of disagreements, larger
    print("Ordinal 1-5 scale, 4 disagreements each")
    for name, j in (("off-by-one", near), ("far-off", far)):
        print(f"  {name:<10} p_o = {percent_agreement(h5, j):.2f}  kappa = {cohen_kappa(h5, j):.3f}"
              f"  quadratic-weighted kappa = {weighted_kappa(h5, j, 5):.3f}")
    assert abs(cohen_kappa(h5, near) - cohen_kappa(h5, far)) < 0.06
    assert weighted_kappa(h5, near, 5) > 0.85 > weighted_kappa(h5, far, 5)

    # Worked example 2: three coders, five items
    units = [[1, 1, 1], [1, 1, 2], [2, 2, 2], [1, 2, 2], [3, 3, 3]]
    a_nom = krippendorff_alpha(units)
    print("Three coders x five items: [1,1,1] [1,1,2] [2,2,2] [1,2,2] [3,3,3]")
    print(f"  Krippendorff alpha (nominal) = {a_nom:.3f}   alpha (interval) = {krippendorff_alpha(units, 'interval'):.3f}"
          f"   Fleiss kappa = {fleiss_kappa(units):.3f}")
    assert abs(a_nom - 0.611) < 1e-3
    with_missing = [[1, 1, None], [1, 1, 2], [2, 2, 2], [1, 2, 2], [3, 3, None]]
    print(f"  same data with two missing ratings: alpha = {krippendorff_alpha(with_missing):.3f}")

    # Worked example 3: ranks
    hr, jr = [1, 2, 3, 4, 5, 6], [2, 1, 4, 3, 6, 5]
    rho, tau = spearman(hr, jr), kendall_tau_b(hr, jr)
    print(f"Ranks {hr} vs {jr}: Spearman rho = {rho:.3f}  Kendall tau = {tau:.3f}  Pearson r = {pearson(hr, jr):.3f}")
    assert abs(rho - 0.829) < 1e-3 and abs(tau - 0.600) < 1e-9
    # Correlation ignores a constant offset: a judge 2 points too generous has r = 1
    offset = [x + 2 for x in hr]
    print(f"  judge = human + 2 points: Pearson r = {pearson(hr, offset):.3f} but mean error = 2.0")

    # Sample-level vs system-level: 8 systems, 1,000 items each, noisy but unbiased judge
    rng = np.random.default_rng(4)
    true_rates = np.linspace(0.45, 0.80, 8)
    item_k, sys_h, sys_j = [], [], []
    for p in true_rates:
        y = rng.random(1000) < p
        flip = rng.random(1000) < 0.25         # judge flips 25% of item labels
        j = np.where(flip, ~y, y)
        item_k.append(cohen_kappa(list(y), list(j)))
        sys_h.append(y.mean())
        sys_j.append(j.mean())
    print("Sample-level vs system-level (8 systems, judge flips 25% of item labels)")
    print(f"  mean item-level kappa = {np.mean(item_k):.3f}   system-level Spearman = {spearman(sys_h, sys_j):.3f}")
    print(f"  but judge pass rates are squeezed toward 50%: best system human {max(sys_h):.3f} vs judge {max(sys_j):.3f}")
    assert np.mean(item_k) < 0.6 and spearman(sys_h, sys_j) > 0.9

    # Judge self-agreement (test-retest): the same judge, production sampling settings, run 3 times per item.
    # 70% of items are clear-cut (judge says the human's label with p = 0.97); 30% are borderline, where the
    # judge's P(PASS) is only 0.65 for human-PASS items and 0.35 for human-FAIL items, so repeated runs disagree.
    rng = np.random.default_rng(5)
    n = 400
    y = rng.random(n) < 0.6
    border = rng.random(n) < 0.30
    p_pass = np.where(border, np.where(y, 0.65, 0.35), np.where(y, 0.97, 0.03))
    runs = rng.random((3, n)) < p_pass                      # three independent judge runs
    flip = np.mean(runs[0] != runs[1])
    k12 = cohen_kappa(list(runs[0]), list(runs[1]))
    alpha_runs = krippendorff_alpha([list(map(int, runs[:, i])) for i in range(n)])
    k_single = np.mean([cohen_kappa(list(y), list(r)) for r in runs])
    k_major = cohen_kappa(list(y), list(runs.sum(0) >= 2))
    print("Judge self-agreement (test-retest): 3 runs per item, 400 items, 30% borderline")
    print(f"  run-1 vs run-2 flip rate = {flip:.3f}   kappa(run1, run2) = {k12:.3f}"
          f"   Krippendorff alpha over 3 runs = {alpha_runs:.3f}")
    print(f"  judge-human kappa: single run (mean of 3) = {k_single:.3f}   majority of 3 runs = {k_major:.3f}")
    print(f"  flip rate on borderline items = {np.mean(runs[0][border] != runs[1][border]):.3f},"
          f" on clear items = {np.mean(runs[0][~border] != runs[1][~border]):.3f}")
    assert 0.08 < flip < 0.20 and k_major > k_single

    # The alt-test: 3 expert annotators label 80 binary items (each 85% accurate vs a latent truth).
    rng = np.random.default_rng(21)
    n_items, truth = 80, rng.random(80) < 0.5
    noisy = lambda acc: np.where(rng.random(n_items) < acc, truth, ~truth)
    humans = {f"h{k}": dict(enumerate(noisy(0.85))) for k in range(3)}
    print("Alt-test (leave one annotator out): 3 experts x 80 items, each 85% accurate; epsilon = 0.2, BY q = 0.05")
    results = {}
    for name, acc in (("strong judge (92% accurate)", 0.92), ("weak judge (70% accurate)", 0.70)):
        w, rho, p = alt_test(humans, dict(enumerate(noisy(acc))), epsilon=0.2)
        results[name] = w
        print(f"  {name:<28} winning rate = {w:.2f} ({'PASS' if w >= 0.5 else 'FAIL'})   advantage prob rho = {rho:.3f}"
              f"   p-values = {', '.join(f'{x:.3g}' for x in p)}")
    assert results["strong judge (92% accurate)"] >= 0.5 > results["weak judge (70% accurate)"]
    assert abs(t_cdf(2.0, 10) - 0.963306) < 1e-5 and abs(t_cdf(-1.5, 79) - 0.068794) < 1e-4


if __name__ == "__main__":
    main()
