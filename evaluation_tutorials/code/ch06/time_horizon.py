"""METR-style 50% time horizon: logistic fit in log human time, with a bootstrap CI.

Section 6.8 (#time-horizon) of Chapter 6.  Run:  python3 code/ch06/time_horizon.py

Model (Kwa et al., 2025):  p(success | task) = sigmoid(beta * (log2 h - log2 t_task)),
where t_task is the human completion time and h is the time at which predicted success is 50%.
We use base-2 logs, so beta is the change in log-odds per doubling of task length.

Synthetic data: 40 tasks with human times log-uniform in [1 min, 8 h], 2 agent runs per task
(80 runs), true h = 30 min, true beta = 1.2.  Fit by plain NumPy gradient descent on the
logistic log-likelihood; bootstrap over tasks for a 95% CI on h50; also report h80.
Part 2 fits a doubling time to synthetic horizons of six mock models released over 4 years.
"""
from __future__ import annotations

import numpy as np

TRUE_H, TRUE_BETA = 30.0, 1.2


def fit_logistic(x: np.ndarray, y: np.ndarray, iters: int = 3000, lr: float = 0.5) -> tuple[float, float]:
    """Fit y ~ sigmoid(a + b*x) by gradient descent. Returns (a, b)."""
    xm, xs = x.mean(), x.std()
    z = (x - xm) / xs                           # standardise for stable steps
    a, b = 0.0, 0.0
    for _ in range(iters):
        p = 1 / (1 + np.exp(-(a + b * z)))
        a -= lr * np.mean(p - y)
        b -= lr * np.mean((p - y) * z)
    return a - b * xm / xs, b / xs              # undo the standardisation


def horizon(a: float, b: float, p: float = 0.5) -> tuple[float, float]:
    """With logit = a + b*log2 t and b < 0: beta = -b; time where success = p."""
    beta = -b
    log2_h50 = a / beta
    log2_hp = log2_h50 - np.log(p / (1 - p)) / beta
    return float(2 ** log2_hp), float(beta)


def simulate(rng: np.random.Generator, n_tasks: int = 40, runs: int = 2) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    t = np.exp(rng.uniform(np.log(1), np.log(480), size=n_tasks))
    task = np.repeat(np.arange(n_tasks), runs)
    x = np.log2(t[task])
    p = 1 / (1 + np.exp(-TRUE_BETA * (np.log2(TRUE_H) - x)))
    y = (rng.random(len(x)) < p).astype(float)
    return x, y, task


def main() -> None:
    rng = np.random.default_rng(0)
    x, y, task = simulate(rng)
    a, b = fit_logistic(x, y)
    h50, beta = horizon(a, b)
    h80, _ = horizon(a, b, 0.8)
    print(f"runs: {len(y)} on {task.max() + 1} tasks; overall success {y.mean():.2f}")
    print(f"true  h50 = {TRUE_H:.1f} min, beta = {TRUE_BETA:.2f}")
    print(f"fit   h50 = {h50:.1f} min, beta = {beta:.2f}, h80 = {h80:.1f} min")

    boots = []
    n_tasks = task.max() + 1
    for _ in range(300):
        pick = rng.integers(0, n_tasks, size=n_tasks)
        idx = np.concatenate([np.flatnonzero(task == k) for k in pick])
        if y[idx].min() == y[idx].max():
            continue
        boots.append(horizon(*fit_logistic(x[idx], y[idx], iters=1500))[0])
    lo, hi = np.percentile(boots, [2.5, 97.5])
    print(f"task-bootstrap 95% CI for h50: {lo:.1f} to {hi:.1f} min ({len(boots)} resamples)")
    assert lo < TRUE_H < hi and 10 < h50 < 60 and h80 < h50

    print("\nFigure 6.5 data: empirical success by task-length bin, and fitted curve")
    edges = np.log2([1, 4, 15, 60, 240, 480])
    for lo_e, hi_e in zip(edges[:-1], edges[1:]):
        m = (x >= lo_e) & (x < hi_e + 1e-9)
        print(f"  {2 ** lo_e:5.0f}-{2 ** hi_e:4.0f} min: n={m.sum():2d} success={y[m].mean():.2f}")
    for t in (1, 2, 4, 8, 15, 30, 60, 120, 240, 480):
        print(f"  fitted p({t:>3} min) = {1 / (1 + np.exp(-(a + b * np.log2(t)))):.3f}")

    print("\nPart 2: doubling time from synthetic model horizons (true doubling = 7 months)")
    months = np.array([0, 9, 17, 26, 35, 46], dtype=float)
    log2_h = np.log2(2.0) + months / 7.0 + rng.normal(0, 0.4, size=months.size)
    slope, intercept = np.polyfit(months, log2_h, 1)
    print("  horizons (min):", ", ".join(f"{2 ** v:.0f}" for v in log2_h))
    print(f"  fitted doubling time = {1 / slope:.1f} months")
    assert 5 < 1 / slope < 9.5


if __name__ == "__main__":
    main()
