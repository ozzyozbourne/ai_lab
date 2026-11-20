"""Prediction-powered inference (PPI) for a mean, from the statistics angle.

Chapter 5, section 5.14 (#ppi-stats). The full treatment is in Chapter 4.
Run:  python3 code/ch05/ppi_stats.py
Shows: 5,000 items scored by a lenient mock judge and 200 of them also labelled by humans.
theta_PPI = mean(judge on unlabeled) - mean(judge - human on labeled), Var = s2_f/N + s2_(f-Y)/n.
Compares the biased judge-only mean, the human-only CI and the PPI CI, checks coverage over
2,000 replications, shows the PPI advantage shrinking as the judge gets noisier, and adds the
Rogan-Gladen correction theta = (q + TNR - 1) / (TPR + TNR - 1) with a two-sample bootstrap CI.
Finally, power-tuned PPI++ (lambda* = Cov(Y, f) / ((1 + n/N) Var f), as ppi_py does with lam=None)
falls back toward the human-only interval when the judge is weak.
"""
from __future__ import annotations

import math

import numpy as np

N_UNLAB, N_LAB, TRUE_RATE = 5000, 200, 0.70


def draw(rng: np.random.Generator, n: int, flip: float) -> tuple[np.ndarray, np.ndarray]:
    """Human labels Y ~ Bern(0.7); judge copies Y, flips a share `flip`, and passes 40% of true failures."""
    y = (rng.random(n) < TRUE_RATE).astype(float)
    f = y.copy()
    f[(y == 0) & (rng.random(n) < 0.40)] = 1.0          # leniency: false passes
    flips = rng.random(n) < flip
    f[flips] = 1.0 - f[flips]
    return y, f


def estimates(rng: np.random.Generator, flip: float) -> dict[str, tuple[float, float]]:
    _, f_u = draw(rng, N_UNLAB, flip)
    y_l, f_l = draw(rng, N_LAB, flip)
    judge = (f_u.mean(), 1.96 * f_u.std(ddof=1) / math.sqrt(N_UNLAB))
    human = (y_l.mean(), 1.96 * y_l.std(ddof=1) / math.sqrt(N_LAB))
    rect = f_l - y_l
    ppi_mean = f_u.mean() - rect.mean()
    ppi_half = 1.96 * math.sqrt(f_u.var(ddof=1) / N_UNLAB + rect.var(ddof=1) / N_LAB)
    return {"judge only": judge, "human only": human, "PPI": (ppi_mean, ppi_half)}


def ppi_pp(rng: np.random.Generator, flip: float) -> tuple[float, float, float]:
    """Power-tuned PPI++ for a mean: theta = mean(Y) + lam * (mean f_u - mean f_l); returns (est, half, lam)."""
    _, f_u = draw(rng, N_UNLAB, flip)
    y_l, f_l = draw(rng, N_LAB, flip)
    f_all = np.concatenate([f_u, f_l])
    lam = np.cov(y_l, f_l)[0, 1] / ((1 + N_LAB / N_UNLAB) * f_all.var(ddof=1))
    est = y_l.mean() + lam * (f_u.mean() - f_l.mean())
    half = 1.96 * math.sqrt(lam**2 * f_u.var(ddof=1) / N_UNLAB + (y_l - lam * f_l).var(ddof=1) / N_LAB)
    return float(est), half, float(lam)


def rogan_gladen(q: np.ndarray, tpr: np.ndarray, tnr: np.ndarray) -> np.ndarray:
    """Correct a judged pass rate q for judge error rates (needs TPR + TNR > 1); clip to [0, 1]."""
    return np.clip((q + tnr - 1.0) / (tpr + tnr - 1.0), 0.0, 1.0)


def rg_estimate(rng: np.random.Generator, flip: float, b: int = 1000) -> tuple[float, float, float]:
    """Point estimate and 95% percentile-bootstrap CI, resampling the judged and the calibration set."""
    _, f_u = draw(rng, N_UNLAB, flip)
    y_l, f_l = draw(rng, N_LAB, flip)

    def rates(y: np.ndarray, f: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        pos, neg = (y == 1), (y == 0)
        return (f * pos).sum(-1) / pos.sum(-1), ((1 - f) * neg).sum(-1) / neg.sum(-1)

    tpr, tnr = rates(y_l, f_l)
    est = float(rogan_gladen(np.array(f_u.mean()), tpr, tnr))
    q_star = rng.binomial(N_UNLAB, f_u.mean(), size=b) / N_UNLAB        # bootstrap of a 0/1 mean
    idx = rng.integers(0, N_LAB, size=(b, N_LAB))
    tpr_s, tnr_s = rates(y_l[idx], f_l[idx])
    lo, hi = np.quantile(rogan_gladen(q_star, tpr_s, tnr_s), [0.025, 0.975])
    return est, float(lo), float(hi)


def main() -> None:
    rng = np.random.default_rng(2301)
    est = estimates(rng, flip=0.05)
    print(f"True pass rate {TRUE_RATE:.2f}; {N_UNLAB} judged items, {N_LAB} with human labels (judge flip rate 5%)")
    for k, (m, h) in est.items():
        print(f"  {k:<11} {m:.3f} +/- {h:.3f}")
    cover = {k: 0 for k in est}
    reps = 2000
    widths = {k: [] for k in est}
    for _ in range(reps):
        e = estimates(rng, 0.05)
        for k, (m, h) in e.items():
            cover[k] += abs(m - TRUE_RATE) <= h
            widths[k].append(h)
    print(f"\nCoverage of the 95% intervals over {reps} replications:")
    for k in est:
        print(f"  {k:<11} {cover[k]/reps*100:5.1f}%   mean half-width {np.mean(widths[k]):.3f}")
    assert cover["judge only"] / reps < 0.05 and cover["PPI"] / reps > 0.93
    assert np.mean(widths["PPI"]) < np.mean(widths["human only"])

    print("\nPPI half-width relative to human-only as the judge gets noisier:")
    for flip in (0.0, 0.05, 0.15, 0.30):
        hw = [estimates(rng, flip) for _ in range(300)]
        ratio = np.mean([e["PPI"][1] for e in hw]) / np.mean([e["human only"][1] for e in hw])
        print(f"  judge flip rate {flip:.2f}: PPI / human-only width = {ratio:.2f}")

    print("\nRogan-Gladen correction with TPR/TNR from the 200 human labels (flip rate 5%):")
    est, lo, hi = rg_estimate(rng, 0.05)
    print(f"  one draw: {est:.3f}  95% bootstrap CI [{lo:.3f}, {hi:.3f}]")
    reps_rg, hit, hw = 1000, 0, []
    for _ in range(reps_rg):
        e, l, h = rg_estimate(rng, 0.05)
        hit += l <= TRUE_RATE <= h
        hw.append((h - l) / 2)
    print(f"  coverage over {reps_rg} replications {hit/reps_rg*100:.1f}%, mean half-width {np.mean(hw):.3f}")
    assert hit / reps_rg > 0.93

    print("\nPower-tuned PPI++ (lambda estimated from the data) vs plain PPI (lambda = 1), relative to human-only:")
    rng2 = np.random.default_rng(2302)                  # separate stream keeps the numbers above unchanged
    for flip in (0.05, 0.15, 0.30):
        pp = [ppi_pp(rng2, flip) for _ in range(1000)]
        base = [estimates(rng2, flip) for _ in range(1000)]
        hum = np.mean([e["human only"][1] for e in base])
        r_ppi = np.mean([e["PPI"][1] for e in base]) / hum
        r_pp = np.mean([h for _, h, _ in pp]) / hum
        cov_pp = np.mean([abs(m - TRUE_RATE) <= h for m, h, _ in pp])
        lam_bar = np.mean([lam for _, _, lam in pp])
        print(f"  flip {flip:.2f}: mean lambda* {lam_bar:.2f}; width ratio PPI {r_ppi:.2f}, PPI++ {r_pp:.2f}; PPI++ coverage {cov_pp*100:.1f}%")
        assert r_pp <= 1.02 and r_pp <= r_ppi + 0.01 and cov_pp > 0.91


if __name__ == "__main__":
    main()
