"""Calibration metrics: ECE (equal-width and equal-mass), MCE, Brier score, reliability-diagram
bins, temperature scaling by grid search, and SimpleQA's correct / incorrect / not-attempted F-score.

Chapter 2, section 2.6 (#calibration) and Figure 2.5.
Run:  python3 code/ch02/calibration.py
Expected key output: ECE = 0.305 on the 10-prediction table; HLE-style RMS calibration error; temperature scaling cuts the ECE of an
over-confident mock model; the abstaining SimpleQA model has the higher F; with a confidence
target t = 0.75 (penalty 3 per wrong answer) the scores are -1.20 vs -0.65.
"""
from __future__ import annotations

import numpy as np


def bins_equal_width(conf: np.ndarray, m: int) -> list[np.ndarray]:
    edges = np.linspace(0, 1, m + 1)
    # right-closed bins (lo, hi]; confidence 0 goes in the first bin
    idx = np.clip(np.searchsorted(edges, conf, side="left") - 1, 0, m - 1)
    return [np.where(idx == b)[0] for b in range(m)]


def bins_equal_mass(conf: np.ndarray, m: int) -> list[np.ndarray]:
    order = np.argsort(conf, kind="stable")
    return [chunk for chunk in np.array_split(order, m)]


def calibration_table(conf, correct, bins):
    rows = []
    for b in bins:
        if len(b) == 0:
            continue
        rows.append((len(b), float(conf[b].mean()), float(correct[b].mean())))
    return rows


def ece_mce(conf, correct, bins) -> tuple[float, float]:
    n = len(conf)
    rows = calibration_table(conf, correct, bins)
    gaps = [abs(acc - c) for _, c, acc in rows]
    return sum(cnt / n * g for (cnt, _, _), g in zip(rows, gaps)), max(gaps)


def rms_calibration_error(conf, correct, beta: int, skip_last: bool = True) -> float:
    """HLE-style RMS calibration error: sort by stated confidence, cut into equal-mass bins of beta
    items (the final bin absorbs the remainder), sqrt(sum |B|/N * (acc - conf)^2).
    skip_last=True reproduces hle_eval/run_judge_results.py, whose loop range(len(bins) - 1)
    never visits the last (highest-confidence) bin; that bin still counts in N."""
    order = np.argsort(conf)
    conf, correct = conf[order], correct[order]
    n = len(conf)
    bins = [[i * beta, (i + 1) * beta] for i in range(n // beta)]
    bins[-1] = [bins[-1][0], n]
    used = bins[:-1] if skip_last else bins
    total = sum((hi - lo) / n * (conf[lo:hi].mean() - correct[lo:hi].mean()) ** 2 for lo, hi in used)
    return float(np.sqrt(total))


def brier_binary(conf, correct) -> float:
    return float(np.mean((conf - correct) ** 2))


def softmax(z: np.ndarray) -> np.ndarray:
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def nll(logits, y, T) -> float:
    p = softmax(logits / T)
    return float(-np.mean(np.log(p[np.arange(len(y)), y] + 1e-12)))


def simpleqa_summary(correct: int, incorrect: int, not_attempted: int) -> dict[str, float]:
    total = correct + incorrect + not_attempted
    is_correct = correct / total
    attempted = (correct + incorrect) / total
    acc_att = is_correct / attempted if attempted else 0.0
    f = 2 * acc_att * is_correct / (acc_att + is_correct) if acc_att + is_correct else 0.0
    return {"correct": is_correct, "not_attempted": not_attempted / total,
            "acc_given_attempted": acc_att, "f": f}


def penalised_score(correct: int, incorrect: int, not_attempted: int, t: float) -> float:
    """Confidence-target grading (Kalai et al. 2025): +1 correct, -t/(1-t) wrong, 0 for abstaining.
    Answering is worth it only when P(correct) > t; t = 0 is ordinary 0/1 accuracy."""
    total = correct + incorrect + not_attempted
    return (correct - t / (1 - t) * incorrect) / total


if __name__ == "__main__":
    print("== Worked example: 10 predictions, 5 equal-width bins ==")
    conf = np.array([0.20, 0.25, 0.30, 0.55, 0.60, 0.70, 0.75, 0.85, 0.90, 0.95])
    corr = np.array([0, 1, 0, 0, 0, 1, 1, 1, 1, 0], dtype=float)
    bins = bins_equal_width(conf, 5)
    print(f"{'bin':<10}{'n':>3}{'conf':>8}{'acc':>8}{'|gap|*n/N':>11}")
    edges = np.linspace(0, 1, 6)
    for b, (lo, hi) in zip(bins, zip(edges[:-1], edges[1:])):
        c, a = conf[b].mean(), corr[b].mean()
        print(f"({lo:.1f},{hi:.1f}]{len(b):>3}{c:>8.3f}{a:>8.3f}{len(b) / 10 * abs(a - c):>11.3f}")
    ece, mce = ece_mce(conf, corr, bins)
    ece_m, _ = ece_mce(conf, corr, bins_equal_mass(conf, 5))
    print(f"ECE (equal-width, M=5) = {ece:.3f}   MCE = {mce:.3f}")
    print(f"ECE (equal-mass,  M=5) = {ece_m:.3f}")
    print(f"Brier score            = {brier_binary(conf, corr):.3f}")
    assert abs(ece - 0.305) < 1e-9 and abs(mce - 0.575) < 1e-9
    rms_hle = rms_calibration_error(conf, corr, beta=2, skip_last=True)
    rms_all = rms_calibration_error(conf, corr, beta=2, skip_last=False)
    print(f"RMS calibration error, equal-mass bins of beta=2: HLE loop (last bin skipped) = {rms_hle:.4f}"
          f"   all bins = {rms_all:.4f}")
    print(f"HLE reports 100 * round(err, 2) = {100 * round(rms_hle, 2):.0f}")
    assert abs(rms_hle - 0.2525) < 5e-5 and abs(rms_all - 0.3160) < 5e-5, (rms_hle, rms_all)

    print("\n== Over-confident mock classifier (4 classes), then temperature scaling ==")
    rng = np.random.default_rng(17)
    n = 4000
    y = rng.integers(4, size=n)
    logits = rng.normal(0, 1, size=(n, 4))
    logits[np.arange(n), y] += 1.3          # real signal
    logits *= 3.0                           # ... but logits are stretched: over-confident
    val, test = np.arange(0, 2000), np.arange(2000, n)
    grid = np.round(np.arange(0.5, 6.01, 0.05), 2)
    best_T = min(grid, key=lambda T: nll(logits[val], y[val], T))   # fit T on validation only
    for name, T in [("T = 1 (raw)", 1.0), (f"T = {best_T:.2f} (fitted)", best_T)]:
        p = softmax(logits[test] / T)
        conf_t = p.max(axis=1)
        corr_t = (p.argmax(axis=1) == y[test]).astype(float)
        e10, m10 = ece_mce(conf_t, corr_t, bins_equal_width(conf_t, 10))
        onehot = np.eye(4)[y[test]]
        brier_mc = float(np.mean(np.sum((p - onehot) ** 2, axis=1)))
        print(f"{name:<20} acc={corr_t.mean():.3f}  mean conf={conf_t.mean():.3f}  ECE={e10:.3f}"
              f"  MCE={m10:.3f}  Brier(4-class)={brier_mc:.3f}  NLL={nll(logits[test], y[test], T):.3f}")
        print("   reliability bins (conf, acc, n): " + "  ".join(
            f"({c:.2f},{a:.2f},{k})" for k, c, a in calibration_table(conf_t, corr_t, bins_equal_width(conf_t, 10))))
        if T == 1.0:
            raw_ece = e10
        else:
            assert e10 < raw_ece / 2   # scaling fixes most of the miscalibration
    assert best_T > 1.5                # the fitted temperature softens the logits

    print("\n== SimpleQA-style grading: correct / incorrect / not attempted (100 questions) ==")
    for name, counts in [("always answers", (45, 55, 0)), ("abstains when unsure", (40, 35, 25))]:
        s = simpleqa_summary(*counts)
        print(f"{name:<22} correct={s['correct']:.3f}  not_attempted={s['not_attempted']:.2f}"
              f"  acc|attempted={s['acc_given_attempted']:.3f}  F={s['f']:.3f}")
    assert simpleqa_summary(40, 35, 25)["f"] > simpleqa_summary(45, 55, 0)["f"]

    print("\n== Scoring that rewards abstention: +1 / -t/(1-t) / 0 ==")
    for t in (0.0, 0.5, 0.75):
        a, b = penalised_score(45, 55, 0, t), penalised_score(40, 35, 25, t)
        print(f"t = {t:<4}  penalty {t / (1 - t):.0f}   always answers {a:+.2f}   abstains when unsure {b:+.2f}")
    assert abs(penalised_score(45, 55, 0, 0.0) - 0.45) < 1e-12 and abs(penalised_score(40, 35, 25, 0.0) - 0.40) < 1e-12
    assert abs(penalised_score(45, 55, 0, 0.75) + 1.20) < 1e-12 and abs(penalised_score(40, 35, 25, 0.75) + 0.65) < 1e-12
