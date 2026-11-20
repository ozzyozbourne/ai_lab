"""Statistics for RL with few runs: IQM, optimality gap, probability of improvement, performance
profiles and stratified bootstrap CIs, re-implemented in numpy (after Agarwal et al. 2021 / rliable).

Chapter 5, section 5.13 (#rl-stats).
Run:  python3 code/ch05/rl_aggregates.py
Shows: the worked IQM example (mean 1.43, median 0.375, IQM 0.367); two mock algorithms on 12 tasks
with heavy-tailed normalized scores; aggregates with 95% stratified-bootstrap CIs at 3 and 10 runs;
probability of improvement from a hand-written Mann-Whitney U; a performance profile; and how much
the median vs the IQM point estimate wobbles across repeated 3-run vs 10-run studies.
"""
from __future__ import annotations

import numpy as np

N_TASKS = 12


def trim_mean(x: np.ndarray, cut: float = 0.25) -> float:
    """Same convention as scipy.stats.trim_mean: drop int(cut * n) values from each end."""
    s = np.sort(np.ravel(x))
    g = int(cut * len(s))
    return float(s[g: len(s) - g].mean())


def iqm(scores: np.ndarray) -> float:
    return trim_mean(scores, 0.25)


def optimality_gap(scores: np.ndarray, gamma: float = 1.0) -> float:
    return float(gamma - np.mean(np.minimum(scores, gamma)))


def mann_whitney_u(x: np.ndarray, y: np.ndarray) -> float:
    """U = #{(i, j): x_i > y_j} + 0.5 #{ties}."""
    d = x[:, None] - y[None, :]
    return float((d > 0).sum() + 0.5 * (d == 0).sum())


def prob_improvement(sx: np.ndarray, sy: np.ndarray) -> float:
    """P(X > Y) per task from the U statistic, averaged over tasks (scores are runs x tasks)."""
    return float(np.mean([mann_whitney_u(sx[:, t], sy[:, t]) / (sx.shape[0] * sy.shape[0]) for t in range(sx.shape[1])]))


def stratified_bootstrap(scores: np.ndarray, stat, rng: np.random.Generator, reps: int = 2000) -> tuple[float, float]:
    """Resample runs independently within each task (column), recompute the aggregate."""
    r, t = scores.shape
    out = np.empty(reps)
    for b in range(reps):
        idx = rng.integers(0, r, size=(r, t))
        out[b] = stat(np.take_along_axis(scores, idx, axis=0))
    return float(np.quantile(out, 0.025)), float(np.quantile(out, 0.975))


def make_algo(rng: np.random.Generator, runs: int, task_level: np.ndarray, shift: float) -> np.ndarray:
    """Normalized scores: per-task level x lognormal run noise (heavy right tail)."""
    noise = rng.lognormal(0.0, 0.6, size=(runs, N_TASKS))
    return task_level[None, :] * (1 + shift) * noise / np.exp(0.18)


def main() -> None:
    x = np.array([0, .1, .2, .3, .35, .4, .45, .5, 3.0, 9.0])
    print(f"Worked example: mean = {x.mean():.3f}, median = {np.median(x):.3f}, IQM = {iqm(x):.3f}")
    assert abs(x.mean() - 1.43) < 1e-9 and abs(np.median(x) - 0.375) < 1e-9 and abs(iqm(x) - 0.3667) < 1e-4

    rng = np.random.default_rng(2108)
    level = rng.lognormal(-0.7, 0.9, size=N_TASKS)   # some tasks are far 'easier' (scores >> 1)
    big_a = make_algo(np.random.default_rng(999), 20_000, level, 0.25)
    big_b = make_algo(np.random.default_rng(998), 20_000, level, 0.0)
    print(f"Ground truth (20,000 runs): IQM A = {iqm(big_a):.3f}, IQM B = {iqm(big_b):.3f}, P(A > B) = {prob_improvement(big_a[:2000], big_b[:2000]):.3f}")
    for runs in (3, 10):
        a = make_algo(np.random.default_rng(runs), runs, level, 0.25)  # A is truly 25% better on every task
        b = make_algo(np.random.default_rng(100 + runs), runs, level, 0.0)
        print(f"\n{runs} runs x {N_TASKS} tasks, 95% stratified-bootstrap CIs (2,000 reps)")
        for name, f in (("mean", lambda s: float(s.mean())), ("median", lambda s: float(np.median(s))),
                        ("IQM", iqm), ("optimality gap", optimality_gap)):
            la, ha = stratified_bootstrap(a, f, np.random.default_rng(1))
            lb, hb = stratified_bootstrap(b, f, np.random.default_rng(2))
            print(f"  {name:<15} A = {f(a):.3f} [{la:.3f}, {ha:.3f}]   B = {f(b):.3f} [{lb:.3f}, {hb:.3f}]")
        print(f"  P(A > B) = {prob_improvement(a, b):.3f}")
        taus = (0.25, 0.5, 1.0, 2.0)
        print("  performance profile, fraction of runs with score > tau: " +
              "  ".join(f"tau={t}: A {np.mean(a > t):.2f} / B {np.mean(b > t):.2f}" for t in taus))

    print("\nWobble of point estimates across 2,000 repeated studies of algorithm A (sd of the estimate)")
    for runs in (3, 10):
        meds, iqms = [], []
        srng = np.random.default_rng(7)
        for _ in range(2000):
            s = make_algo(srng, runs, level, 0.25)
            meds.append(np.median(s.mean(axis=0)))  # median over tasks of the per-task mean score
            iqms.append(iqm(s))
        print(f"  {runs:>2} runs: median-of-tasks sd = {np.std(meds):.4f}   IQM sd = {np.std(iqms):.4f}")
        if runs == 10:
            assert np.std(iqms) < np.std(meds)


if __name__ == "__main__":
    main()
