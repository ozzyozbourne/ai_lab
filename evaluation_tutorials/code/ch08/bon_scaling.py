"""Best-of-N attack scaling: homogeneous vs heterogeneous behaviours (Chapter 8.5, #asr).

Each of 1,000 placeholder behaviours gets a latent per-attempt success probability
p_b ~ Beta(0.3, 6) (mean 0.048, most behaviours very hard, a few easy). An attacker draws N
independent augmented attempts per behaviour; a behaviour is broken if any attempt succeeds.

We compare
  * homogeneous model: every behaviour has p = mean(p_b); ASR@N = 1 - (1 - p)^N
  * heterogeneous truth: ASR@N = mean_b [1 - (1 - p_b)^N]   (exact) and a Monte Carlo run
and the "linearised" plot log(-log(1 - ASR)) vs log N: slope 1 for homogeneous, < 1 and
power-law-like for heterogeneous. Finally we forecast ASR@1000 from N <= 100 data with
the BoN paper's fit, -log(ASR) = a * N^(-b), and with a naive straight line.

Run:  python3 code/ch08/bon_scaling.py
Key output: ASR@100 = 0.995 (homogeneous) vs 0.608 (heterogeneous); slope 0.487; BoN-form
forecast of ASR@1000 = 0.816 vs actual 0.800; worked p = 0.02, N = 100 -> 0.867.
A final block adds stopping-judge false positives (f = 0, 0.002, 0.01) to ASR@N.
"""
from __future__ import annotations

import numpy as np

NS = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000]
JUDGE_NS = [1, 10, 100, 1000]
JUDGE_FPRS = [0.0, 0.002, 0.01]


def asr_at_n(p: np.ndarray, n: int) -> float:
    return float(np.mean(1.0 - (1.0 - p) ** n))


def main() -> None:
    rng = np.random.default_rng(2024)
    p_b = rng.beta(0.3, 6.0, size=1000)
    p_bar = float(p_b.mean())
    print(f"behaviours = {p_b.size}, mean p_b = {p_bar:.4f}, median p_b = {np.median(p_b):.5f}, "
          f"share with p_b < 0.001 = {np.mean(p_b < 1e-3):.3f}\n")

    # Monte Carlo: first success index for each behaviour is geometric(p_b)
    first = rng.geometric(np.clip(p_b, 1e-12, 1.0))
    print(f"{'N':>5}  {'homog.':>7}  {'heterog.':>8}  {'simulated':>9}  {'log N':>6}  {'log(-log(1-ASR))':>16}")
    het, xs, ys = [], [], []
    for n in NS:
        hom = 1 - (1 - p_bar) ** n
        h = asr_at_n(p_b, n)
        sim = float(np.mean(first <= n))
        het.append(h)
        x, y = np.log(n), np.log(-np.log(1 - h))
        xs.append(x); ys.append(y)
        print(f"{n:5d}  {hom:7.3f}  {h:8.3f}  {sim:9.3f}  {x:6.2f}  {y:16.3f}")

    xs_a, ys_a = np.array(xs), np.array(ys)
    slope_all = np.polyfit(xs_a, ys_a, 1)[0]
    print(f"\nslope of log(-log(1-ASR)) on log N: homogeneous = 1.000 exactly, heterogeneous = {slope_all:.3f}")

    # Forecast ASR@1000 using only N <= 100 (a 10x extrapolation)
    mask = np.array(NS) <= 100
    het_a = np.array(het)
    b1, b0 = np.polyfit(xs_a[mask], ys_a[mask], 1)
    pred_cloglog = 1 - np.exp(-np.exp(b0 + b1 * np.log(1000)))
    # Hughes et al. (BoN) form: -log(ASR) = a * N^(-b), i.e. log(-log ASR) linear in log N
    c1, c0 = np.polyfit(xs_a[mask], np.log(-np.log(het_a[mask])), 1)
    pred_bon = float(np.exp(-np.exp(c0 + c1 * np.log(1000))))
    naive = 1 - (1 - het[0]) ** 1000
    print(f"BoN power-law fit on N<=100: -log(ASR) = {np.exp(c0):.3f} * N^(-{-c1:.3f})")
    print("forecast ASR@1000 from N <= 100:")
    print(f"  independent trials 1-(1-ASR@1)^1000  = {naive:.3f}")
    print(f"  straight line in log(-log(1-ASR))    = {pred_cloglog:.3f}")
    print(f"  BoN power law -log(ASR) = a N^-b     = {pred_bon:.3f}")
    print(f"  actual                               = {het[-1]:.3f}")

    # Worked example in the text
    worked = 1 - 0.98 ** 100
    print(f"\nworked example: p = 0.02, N = 100 -> ASR@N = {worked:.3f}")
    assert abs(worked - 0.867) < 1e-3
    assert 1 - (1 - p_bar) ** 100 > 0.99 and het[NS.index(100)] < 0.7
    assert slope_all < 0.8
    assert abs(pred_bon - het[-1]) < abs(pred_cloglog - het[-1])

    # Judge error under best-of-N: the attack stops at the first sample its stopping judge
    # flags. If each non-harmful sample is wrongly flagged with probability f, a behaviour
    # is reported broken with probability 1 - (1 - p_b)^N (1 - f)^N.
    print("\njudge error under best-of-N: observed ASR@N = mean_b[1 - (1-p_b)^N (1-f)^N]")
    print(f"{'f':>6}  " + "  ".join(f"{'N=' + str(n):>7}" for n in JUDGE_NS))
    table = {}
    for f in JUDGE_FPRS:
        row = [float(np.mean(1.0 - (1.0 - p_b) ** n * (1.0 - f) ** n)) for n in JUDGE_NS]
        table[f] = row
        print(f"{f:6.3f}  " + "  ".join(f"{v:7.3f}" for v in row))
    judge_only = 1 - (1 - 0.002) ** 1000
    print(f"judge error alone (p_b = 0): f = 0.002, N = 1000 -> {judge_only:.3f}")
    assert abs(table[0.0][-1] - het[-1]) < 1e-12
    assert abs(judge_only - 0.865) < 1e-3
    assert table[0.01][-1] > 0.999 and table[0.002][-1] > table[0.0][-1]


if __name__ == "__main__":
    main()
