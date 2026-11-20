"""rliable re-implemented in NumPy: IQM, optimality gap, stratified bootstrap CIs, performance profiles,
probability of improvement, and how few-seed point estimates flip conclusions.

Section 7.8 (#few-runs) of Chapter 7.  Run:  python3 code/ch07/rliable_numpy.py

Two mock algorithms on 8 tasks (normalised scores). B is better on every task by 0.08 in its typical run (run noise sd 0.06);
A is unstable: 10% of its runs are "lucky seeds" that score 4x higher. So A has the higher MEAN but B has
the higher median and IQM, and P(B > A) > 0.5 on every task: most practitioners would call B the better method.
Expected key output: a 5-seed SE of 0.0447 and 16 seeds per arm to detect a 1-sd gap; with 3 seeds per arm the
normal approximation says 2.29 sds but a simulated t-test needs about 3.1 (it has only ~56% power at 2.29); the IQM worked example (mean 0.975, median 0.45, IQM 0.45); across 2,000 simulated studies
the mean ranks B first only 24.6% of the time with 3 seeds (and less with more seeds: it measures the lucky tail),
while IQM ranks B first in 80.6% of 3-seed studies and 93.0% of 10-seed studies.
"""
from __future__ import annotations

import numpy as np

N_TASKS = 8
BASE = np.linspace(0.2, 0.9, N_TASKS)          # typical normalised score of A per task


def iqm(x: np.ndarray) -> float:
    """Interquartile mean of all run x task scores (25% trimmed mean, as scipy.stats.trim_mean(x, 0.25))."""
    v = np.sort(np.asarray(x).ravel())
    k = int(0.25 * len(v))
    return float(v[k:len(v) - k].mean())


def optimality_gap(x: np.ndarray, target: float = 1.0) -> float:
    return float(np.mean(np.maximum(target - np.asarray(x), 0.0)))


AGGS = {"mean": lambda x: float(np.mean(x)), "median": lambda x: float(np.median(x)),
        "IQM": iqm, "opt.gap": optimality_gap}


def sample_runs(algo: str, n_runs: int, rng: np.random.Generator) -> np.ndarray:
    """Matrix (n_runs x n_tasks), the layout rliable expects."""
    noise = rng.normal(0, 0.06, (n_runs, N_TASKS))
    if algo == "A":
        lucky = rng.random((n_runs, N_TASKS)) < 0.10
        return np.where(lucky, 4 * BASE, BASE) + noise
    return BASE + 0.08 + noise


def stratified_bootstrap_ci(x: np.ndarray, agg, reps: int, rng: np.random.Generator) -> tuple[float, float]:
    n_runs, n_tasks = x.shape
    stats = np.empty(reps)
    for b in range(reps):
        idx = rng.integers(n_runs, size=(n_runs, n_tasks))         # resample runs independently within each task
        stats[b] = agg(np.take_along_axis(x, idx, axis=0))
    return float(np.percentile(stats, 2.5)), float(np.percentile(stats, 97.5))


def prob_improvement(x: np.ndarray, y: np.ndarray) -> float:
    """P(X > Y): per task Mann-Whitney U / (n*m) with ties counted 1/2, averaged over tasks."""
    per_task = []
    for t in range(x.shape[1]):
        a, b = x[:, t][:, None], y[:, t][None, :]
        per_task.append(float(np.mean((a > b) + 0.5 * (a == b))))
    return float(np.mean(per_task))


def performance_profile(x: np.ndarray, taus: np.ndarray) -> np.ndarray:
    return np.array([(x > t).mean() for t in taus])


def seeds_needed(sigma: float, delta: float, z_alpha: float = 1.96, z_beta: float = 0.8416) -> int:
    """Seeds per algorithm for a two-sample z-test (alpha = 0.05 two-sided, power 0.8) to detect a mean gap delta."""
    return int(np.ceil(2 * (z_alpha + z_beta) ** 2 * sigma ** 2 / delta ** 2))


T_CRIT = {3: 2.7764, 16: 2.0423}   # two-sided 5% Student-t critical values for df = 2n - 2 (df = 4 and df = 30)


def ttest_power(d: float, n: int = 3, sims: int = 200_000, seed: int = 0) -> float:
    """Monte Carlo power of a pooled two-sample t-test (alpha .05, two-sided) for a gap of d run-sds, n runs per arm.
    The noise is drawn from a fixed seed, so power is monotone in d and the search below is exact for these draws."""
    z = np.random.default_rng(seed).normal(size=(sims, 2, n))
    a, b = z[:, 0], z[:, 1] + d
    sp = np.sqrt((a.var(axis=1, ddof=1) + b.var(axis=1, ddof=1)) / 2)
    t = (b.mean(axis=1) - a.mean(axis=1)) / (sp * np.sqrt(2 / n))
    return float(np.mean(np.abs(t) > T_CRIT[n]))


def ttest_mde(n: int = 3, power: float = 0.8) -> float:
    lo, hi = 0.0, 6.0
    for _ in range(30):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if ttest_power(mid, n) < power else (lo, mid)
    return hi


def main() -> None:
    se = 0.1 / np.sqrt(5)
    print(f"SE of a 5-seed mean with run sd 0.1: {se:.4f}  (95% CI half-width {1.96 * se:.3f})")
    for sig, d in ((0.1, 0.1), (0.1, 0.05), (0.2, 0.1)):
        print(f"  seeds per arm to detect a gap of {d} with run sd {sig} (alpha .05, power .8): {seeds_needed(sig, d)}")
    mde3 = np.sqrt(2 * (1.96 + 0.8416) ** 2 / 3)
    mde3_t = ttest_mde(3)
    print(f"  smallest gap (in run sds) that 3 seeds per arm detect with power .8: {mde3:.2f} (normal approx), "
          f"{mde3_t:.2f} (t-test, df = 4, simulated)")
    print(f"    t-test power at the normal-approx gap {mde3:.2f}: {ttest_power(mde3):.3f}; "
          f"at 16 seeds per arm and a 1-sd gap: {ttest_power(1.0, 16):.3f}")
    assert abs(se - 0.0447) < 1e-4 and seeds_needed(0.1, 0.1) == 16 and seeds_needed(0.1, 0.05) == 63
    assert abs(mde3 - 2.29) < 0.01
    assert 3.0 < mde3_t < 3.15 and 0.54 < ttest_power(mde3) < 0.59 and 0.75 < ttest_power(1.0, 16) < 0.81
    ex = np.array([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 5.0])
    print(f"IQM worked example {ex.tolist()}: mean {ex.mean():.3f}, median {np.median(ex):.2f}, IQM {iqm(ex):.2f}")
    assert abs(ex.mean() - 0.975) < 1e-9 and abs(iqm(ex) - 0.45) < 1e-9

    rng = np.random.default_rng(3)
    for n in (3, 10):
        A, B = sample_runs("A", n, rng), sample_runs("B", n, rng)
        print(f"\nOne study with {n} seeds per task (95% stratified bootstrap CIs, 2,000 reps)")
        for name, f in AGGS.items():
            la, ha = stratified_bootstrap_ci(A, f, 2000, rng)
            lb, hb = stratified_bootstrap_ci(B, f, 2000, rng)
            print(f"  {name:<8} A {f(A):.3f} [{la:.3f}, {ha:.3f}]   B {f(B):.3f} [{lb:.3f}, {hb:.3f}]")
        boots = []
        for _ in range(1000):
            ia, ib = rng.integers(n, size=(n, N_TASKS)), rng.integers(n, size=(n, N_TASKS))
            boots.append(prob_improvement(np.take_along_axis(B, ib, 0), np.take_along_axis(A, ia, 0)))
        print(f"  P(B > A) = {prob_improvement(B, A):.3f} [{np.percentile(boots, 2.5):.3f}, {np.percentile(boots, 97.5):.3f}]")
        taus = np.array([0.25, 0.5, 0.75, 1.0, 1.5])
        print("  profile tau=" + " ".join(f"{t:<5}" for t in taus))
        print("    A        " + " ".join(f"{v:<5.2f}" for v in performance_profile(A, taus)))
        print("    B        " + " ".join(f"{v:<5.2f}" for v in performance_profile(B, taus)))

    print("\nHow often does each aggregate rank B above A? (2,000 simulated studies per seed count)")
    print(f"  seeds  " + "  ".join(f"{k:>7}" for k in ("mean", "median", "IQM")))
    flip = {}
    for n in (3, 5, 10):
        wins = {k: 0 for k in ("mean", "median", "IQM")}
        for _ in range(2000):
            A, B = sample_runs("A", n, rng), sample_runs("B", n, rng)
            for k in wins:
                wins[k] += AGGS[k](B) > AGGS[k](A)
        flip[n] = {k: v / 2000 for k, v in wins.items()}
        print(f"  {n:>5}  " + "  ".join(f"{flip[n][k]:7.3f}" for k in wins))
    assert flip[3]["mean"] < 0.3 and flip[10]["mean"] < flip[3]["mean"]
    assert abs(flip[3]["IQM"] - 0.806) < 1e-3 and abs(flip[10]["IQM"] - 0.930) < 1e-3


if __name__ == "__main__":
    main()
