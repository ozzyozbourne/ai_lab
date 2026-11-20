"""Comparing two models on the same questions: paired SE, McNemar, permutation, paired bootstrap.

Chapter 5, section 5.5 (#paired) and Figure 5.3.
Run:  python3 code/ch05/paired.py
Shows: two mock models that share question difficulty (logit p = theta_i + model effect).
Unpaired SE of the difference vs paired SE, the correlation-term identity, McNemar's exact test,
a sign-flip permutation test, a paired bootstrap CI, the overlapping-CI fallacy, the
analytic unpaired-vs-paired SE curve used for Figure 5.3, and paired_clustered(): two agents on
40 repos x 5 tasks with K = 4 trials per task (reduce over K, difference, then cluster by repo).
"""
from __future__ import annotations

import math

import numpy as np

from _common import binom_two_sided_p, norm_cdf

N = 500


def sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def main() -> None:
    rng = np.random.default_rng(6)
    theta = rng.normal(0.0, 3.0, size=N)          # shared question easiness
    a = (rng.random(N) < sigmoid(theta + 0.30)).astype(float)   # model A slightly stronger
    b = (rng.random(N) < sigmoid(theta + 0.00)).astype(float)
    ma, mb = a.mean(), b.mean()
    se_a, se_b = a.std(ddof=1) / math.sqrt(N), b.std(ddof=1) / math.sqrt(N)
    rho = float(np.corrcoef(a, b)[0, 1])
    d = a - b
    se_unpaired = math.sqrt(se_a**2 + se_b**2)
    se_paired = d.std(ddof=1) / math.sqrt(N)
    se_identity = math.sqrt(se_a**2 + se_b**2 - 2 * se_a * se_b * rho)
    print(f"n = {N} questions. A = {ma:.3f} (SE {se_a:.4f}), B = {mb:.3f} (SE {se_b:.4f}), corr(sA, sB) = {rho:.3f}")
    true_diff = float(np.mean(sigmoid(theta + 0.30) - sigmoid(theta)))
    print(f"difference = {d.mean()*100:+.1f} pts (expected difference on these questions = {true_diff*100:+.1f} pts)")
    print(f"  unpaired SE of difference = {se_unpaired:.4f}  -> z = {d.mean()/se_unpaired:.2f}, "
          f"p = {2*(1-norm_cdf(abs(d.mean())/se_unpaired)):.3f}")
    print(f"  paired SE of difference   = {se_paired:.4f}  -> z = {d.mean()/se_paired:.2f}, "
          f"p = {2*(1-norm_cdf(abs(d.mean())/se_paired)):.4f}")
    print(f"  identity sqrt(SEa^2+SEb^2-2 rho SEa SEb) = {se_identity:.4f}")
    assert abs(se_identity - se_paired) < 1e-3

    ci_a = (ma - 1.96 * se_a, ma + 1.96 * se_a)
    ci_b = (mb - 1.96 * se_b, mb + 1.96 * se_b)
    print(f"  95% CI A = [{ci_a[0]:.3f}, {ci_a[1]:.3f}], B = [{ci_b[0]:.3f}, {ci_b[1]:.3f}] -> overlap: {ci_a[0] < ci_b[1]}")

    # McNemar: only discordant pairs matter
    n10 = int(((a == 1) & (b == 0)).sum())
    n01 = int(((a == 0) & (b == 1)).sum())
    p_exact = binom_two_sided_p(n10, n10 + n01)
    chi2 = (abs(n10 - n01) - 1) ** 2 / (n10 + n01)
    print(f"McNemar: A-only right = {n10}, B-only right = {n01}, exact p = {p_exact:.4f}, chi2(cc) = {chi2:.2f}")

    # Paired permutation (sign flip)
    prng = np.random.default_rng(0)
    signs = prng.choice([-1.0, 1.0], size=(20_000, N))
    null = (signs * d).mean(axis=1)
    p_perm = float((np.abs(null) >= abs(d.mean())).mean())
    print(f"Sign-flip permutation test (20,000 flips): p = {p_perm:.4f}")

    # Paired bootstrap
    brng = np.random.default_rng(1)
    idx = brng.integers(0, N, size=(10_000, N))
    boots = d[idx].mean(axis=1)
    lo, hi = np.percentile(boots, [2.5, 97.5])
    print(f"Paired bootstrap 95% CI for the difference: [{lo*100:+.1f}, {hi*100:+.1f}] pts")

    assert ci_a[0] < ci_b[1]                    # CIs overlap ...
    assert 2 * (1 - norm_cdf(d.mean() / se_unpaired)) > 0.05  # unpaired test misses it
    assert p_exact < 0.05 and p_perm < 0.05 and lo > 0  # ... yet the paired difference is significant
    assert se_paired < 0.75 * se_unpaired

    print("\nFigure 5.3 data: SE of the difference vs correlation (Var = 0.25 per model, n = 500)")
    print(f"  {'rho':>4}  {'unpaired':>9}  {'paired':>7}  {'ratio':>6}")
    for r in (0.0, 0.2, 0.4, 0.5, 0.6, 0.8, 0.9):
        su = math.sqrt(0.5 / N)
        sp = math.sqrt((0.5 - 2 * 0.25 * r) / N)
        print(f"  {r:4.1f}  {su:9.4f}  {sp:7.4f}  {sp/su:6.2f}")

    paired_clustered()


# --- Paired, clustered and resampled together -------------------------------------------
REPOS, TASKS_PER_REPO, K_TRIALS = 40, 5, 4
SD_REPO, SD_TASK, SD_AGENT_REPO, EFFECT = 1.0, 1.0, 0.8, 0.3


def one_eval(rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Per-task mean success of A and B over K trials, plus the repo id of each task."""
    repo = np.repeat(np.arange(REPOS), TASKS_PER_REPO)
    eta = (rng.normal(0, SD_REPO, REPOS)[repo]                      # shared repo difficulty
           + rng.normal(0, SD_TASK, REPOS * TASKS_PER_REPO))        # shared task difficulty
    gap = EFFECT + rng.normal(0, SD_AGENT_REPO, REPOS)[repo]        # A's edge varies by repo
    pa, pb = sigmoid(eta + gap), sigmoid(eta)
    ya = (rng.random((len(eta), K_TRIALS)) < pa[:, None]).mean(axis=1)   # 1) reduce over K
    yb = (rng.random((len(eta), K_TRIALS)) < pb[:, None]).mean(axis=1)
    return ya, yb, repo


def clustered_se_of_mean(d: np.ndarray, cid: np.ndarray) -> float:
    """sqrt(C/(C-1) * sum_c (sum_{i in c} (d_i - dbar))^2) / n  (Inspect's form)."""
    c = len(np.unique(cid))
    sums = np.bincount(cid, weights=d - d.mean())
    return float(math.sqrt(c / (c - 1) * (sums**2).sum()) / len(d))


def paired_clustered(reps: int = 2000) -> None:
    rng = np.random.default_rng(55)
    # super-population difference: average over fresh repos, tasks and repo-level agent gaps
    big = 2_000_000
    eta = rng.normal(0, SD_REPO, big) + rng.normal(0, SD_TASK, big)
    truth = float(np.mean(sigmoid(eta + EFFECT + rng.normal(0, SD_AGENT_REPO, big)) - sigmoid(eta)))
    n = REPOS * TASKS_PER_REPO
    ses = {"naive unpaired": [], "paired, per-task means": [], "paired + clustered by repo": []}
    cover = {k: 0 for k in ses}
    for _ in range(reps):
        ya, yb, repo = one_eval(rng)
        d = ya - yb                                                  # 2) difference per task
        se = {
            "naive unpaired": math.sqrt(ya.var(ddof=1) / n + yb.var(ddof=1) / n),
            "paired, per-task means": float(d.std(ddof=1) / math.sqrt(n)),
            "paired + clustered by repo": clustered_se_of_mean(d, repo),   # 3) cluster
        }
        for k, v in se.items():
            ses[k].append(v)
            cover[k] += abs(d.mean() - truth) <= 1.96 * v
    print(f"\nPaired + clustered + K trials: {REPOS} repos x {TASKS_PER_REPO} tasks, K = {K_TRIALS}, "
          f"{reps:,} simulated evals")
    print(f"  true difference (super-population) = {truth*100:+.2f} pts")
    print(f"  {'method':<28} {'mean SE':>8} {'95% coverage':>13}")
    for k in ses:
        print(f"  {k:<28} {np.mean(ses[k]):8.4f} {cover[k]/reps*100:12.1f}%")
    assert abs(cover["paired + clustered by repo"] / reps - 0.95) < 0.02
    assert cover["paired, per-task means"] / reps < 0.90


if __name__ == "__main__":
    main()
