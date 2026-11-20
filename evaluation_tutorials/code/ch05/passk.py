"""pass@k, pass^k and Bayes@N for stochastic agents.

Chapter 5, section 5.9 (#pass-hat-k) and Figure 5.5.
Run:  python3 code/ch05/passk.py
Shows: the unbiased estimators (human-eval product form for pass@k, tau-bench comb(c,k)/comb(n,k)
for pass^k) checked against Monte Carlo; the n=10, c=3 worked example; Agent A (60% on every task)
vs Agent B (always solves 6 of 10 tasks) with the same pass@1 but very different pass^k and pass@k;
the upward bias of the naive (c/n)^k estimator; a Bayes@N posterior with a credible interval; and
the task-level SE, bootstrap CI and coverage of pass^4 for n = 4, 8, 16 trials per task.
"""
from __future__ import annotations

from math import comb

import numpy as np


def pass_at_k(n: int, c: int, k: int) -> float:
    """Unbiased pass@k (Chen et al. 2021), numerically stable product form from openai/human-eval."""
    if n - c < k:
        return 1.0
    return float(1.0 - np.prod(1.0 - k / np.arange(n - c + 1, n + 1)))


def pass_hat_k(n: int, c: int, k: int) -> float:
    """Unbiased pass^k (Yao et al. 2024): probability that k draws without replacement are all successes."""
    return comb(c, k) / comb(n, k)


def main() -> None:
    n, c = 10, 3
    p5, h2, h5 = pass_at_k(n, c, 5), pass_hat_k(n, c, 2), pass_hat_k(n, c, 5)
    print(f"Single task, n={n}, c={c}: pass@5 = {p5:.3f}, pass^2 = {h2:.4f} (naive (c/n)^2 = {(c/n)**2:.2f}), pass^5 = {h5:.0f}")
    assert abs(p5 - 0.917) < 1e-3 and abs(h2 - 3 / 45) < 1e-12 and h5 == 0
    assert abs(pass_at_k(n, c, 5) - (1 - comb(7, 5) / comb(10, 5))) < 1e-12

    rng = np.random.default_rng(0)
    trials = np.array([1] * c + [0] * (n - c))
    mc_at = np.mean([trials[rng.permutation(n)[:5]].max() for _ in range(100_000)])
    mc_hat = np.mean([trials[rng.permutation(n)[:2]].min() for _ in range(100_000)])
    print(f"  Monte Carlo (subsets of the 10 trials): pass@5 = {mc_at:.3f}, pass^2 = {mc_hat:.4f}")
    assert abs(mc_at - p5) < 0.005 and abs(mc_hat - h2) < 0.003

    # Agent A: p = 0.6 on all 10 tasks.  Agent B: p = 1 on 6 tasks, 0 on 4.
    pa = np.full(10, 0.6)
    pb = np.array([1.0] * 6 + [0.0] * 4)
    print("\nPopulation values, 10 tasks (pass^k = mean_i p_i^k, pass@k = mean_i 1-(1-p_i)^k)")
    print(f"  {'k':>2}  {'pass^k A':>9}  {'pass^k B':>9}  {'pass@k A':>9}  {'pass@k B':>9}")
    curve = {}
    for k in (1, 2, 4, 8, 16):
        row = (np.mean(pa**k), np.mean(pb**k), np.mean(1 - (1 - pa) ** k), np.mean(1 - (1 - pb) ** k))
        curve[k] = row
        print(f"  {k:>2}  {row[0]:9.3f}  {row[1]:9.3f}  {row[2]:9.3f}  {row[3]:9.3f}")
    assert abs(curve[8][0] - 0.0168) < 1e-3 and abs(curve[4][2] - 0.9744) < 1e-4
    print(f"  (mean p)^4 = {0.6**4:.3f} for both agents; mean(p_i^4) = {curve[4][0]:.3f} (A) vs {curve[4][1]:.3f} (B)")

    print("\nEstimating pass^4 from n = 8 trials per task, 20,000 simulated evals of a 10-task suite")
    for name, p in (("A", pa), ("B", pb)):
        unb, naive = [], []
        for _ in range(20_000):
            cs = rng.binomial(8, p)
            unb.append(np.mean([pass_hat_k(8, int(ci), 4) for ci in cs]))
            naive.append(np.mean((cs / 8) ** 4))
        truth = np.mean(p**4)
        print(f"  Agent {name}: truth {truth:.4f}  unbiased mean {np.mean(unb):.4f}  naive (c/n)^k mean {np.mean(naive):.4f}")
        if name == "A":
            assert abs(np.mean(unb) - truth) < 0.003 and np.mean(naive) > truth + 0.03

    print("\nBayes@N (uniform Beta(1,1) prior per task), Agent A with n = 8 trials per task")
    cs = rng.binomial(8, pa)
    post_mean = (cs + 1) / (8 + 2)
    draws = rng.beta(cs[:, None] + 1, 8 - cs[:, None] + 1, size=(10, 20_000)).mean(axis=0)
    lo, hi = np.quantile(draws, [0.025, 0.975])
    print(f"  successes per task = {cs.tolist()}  avg@8 = {cs.mean()/8:.3f}")
    print(f"  posterior mean = {post_mean.mean():.3f}, 95% credible interval for suite mean = [{lo:.3f}, {hi:.3f}]")

    print("\nFigure 5.5 data (k, pass@k A, pass@k B, pass^k A, pass^k B)")
    for k in (1, 2, 3, 4, 6, 8, 12, 16):
        print(f"  {k:>2}  {np.mean(1-(1-pa)**k):.3f}  {np.mean(1-(1-pb)**k):.3f}  {np.mean(pa**k):.3f}  {np.mean(pb**k):.3f}")

    passk_uncertainty()


def task_estimates(cs: np.ndarray, n: int, k: int) -> np.ndarray:
    """Per-task unbiased pass^k, h_i = C(c_i, k) / C(n, k)."""
    return np.array([pass_hat_k(n, int(c), k) for c in cs])


def passk_uncertainty(tasks: int = 50, k: int = 4, a: float = 3.0, b: float = 2.0) -> None:
    """SE and CIs for pass^k. Tasks are independent, so SE = sd(h_i) / sqrt(T)."""
    rng = np.random.default_rng(7)
    truth = float(np.prod([(a + j) / (a + b + j) for j in range(k)]))   # E[p^k], p ~ Beta(a, b)
    floor_sd = float(np.sqrt(np.mean(rng.beta(a, b, 1_000_000) ** (2 * k)) - truth**2))
    print(f"\nUncertainty of pass^{k}: T = {tasks} tasks, p_i ~ Beta({a:g},{b:g}) (mean 0.6), true pass^{k} = {truth:.3f}")
    print(f"  floor as n -> infinity (between-task variance only): CI width {2*1.96*floor_sd/np.sqrt(tasks):.3f}")
    print(f"  {'n':>3}  {'estimate':>8}  {'task SE':>7}  {'CI width':>8}  {'task boot':>9}  {'nested boot':>11}  {'mean width':>10}  {'coverage':>8}")
    widths = {}
    for n in (4, 8, 16):
        c = rng.binomial(n, rng.beta(a, b, tasks))                         # one eval
        h = task_estimates(c, n, k)
        se = float(h.std(ddof=1) / np.sqrt(tasks))
        ti = rng.integers(0, tasks, size=(4000, tasks))                     # resample tasks
        boot = h[ti].mean(axis=1)
        c_star = rng.binomial(n, c[ti] / n)                                 # then trials within tasks
        nested = np.vectorize(lambda x: pass_hat_k(n, int(x), k))(c_star).mean(axis=1)
        bw = float(np.subtract(*np.quantile(boot, [0.975, 0.025])))
        nw = float(np.subtract(*np.quantile(nested, [0.975, 0.025])))
        hit, ws = 0, []
        for _ in range(1000):                                               # 1,000 fresh evals
            hh = task_estimates(rng.binomial(n, rng.beta(a, b, tasks)), n, k)
            s_ = hh.std(ddof=1) / np.sqrt(tasks)
            hit += abs(hh.mean() - truth) <= 1.96 * s_
            ws.append(2 * 1.96 * s_)
        widths[n] = float(np.mean(ws))
        print(f"  {n:>3}  {h.mean():8.3f}  {se:7.4f}  {2*1.96*se:8.3f}  {bw:9.3f}  {nw:11.3f}  {widths[n]:10.3f}  {hit/10:7.1f}%")
    assert widths[4] > widths[8] > widths[16] > 2 * 1.96 * floor_sd / np.sqrt(tasks)


if __name__ == "__main__":
    main()
