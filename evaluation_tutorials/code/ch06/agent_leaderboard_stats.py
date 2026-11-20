"""Is agent B really better than agent A? Error bars for agent leaderboards.

Section 6.6 (#reliability) of Chapter 6.  Run:  python3 code/ch06/agent_leaderboard_stats.py

A synthetic SWE-bench-like suite: 500 tasks in 25 repositories of 20 tasks.  Per-task success
probabilities share a repository effect (tasks from one repo are correlated).  Agent B is 2 points
better than agent A on average *by construction*, but the size of its advantage
varies by repository.  We compute:

  * the binomial CI for one agent (p = 0.6, N = 500 gives +/- 4.3 points),
  * an unpaired CI for the difference vs a paired bootstrap over tasks vs McNemar's exact test,
  * a cluster (repository) bootstrap, which is wider because tasks within a repo are correlated,
  * the power: how often a real 2-point gap is detected at alpha = 0.05 with N = 500.

Exercise 6.5 changes the design:  --repos R --per-repo K  (defaults 25 and 20) and
--trials T (default 1): each agent runs T trials per task and its per-task score is the mean of
the T outcomes.  McNemar needs one binary outcome per task, so it is skipped when T > 1; power is
then the share of suites whose repository-resampled paired-bootstrap 95% CI of the mean
difference excludes 0 (printed for every design, so designs can be compared on equal terms).
The asserts that pin the chapter's numbers only run for the default design.
"""
from __future__ import annotations

import argparse
from math import comb, sqrt

import numpy as np

N_REPOS, PER_REPO = 25, 20
N = N_REPOS * PER_REPO


def make_suite(rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Return per-task success probabilities for A and B, plus repo ids."""
    repo_mean = rng.beta(6, 4, size=N_REPOS)
    repo = np.repeat(np.arange(N_REPOS), PER_REPO)
    kappa = 0.8                                    # small kappa: tasks are mostly easy or mostly hard
    p_a = rng.beta(repo_mean[repo] * kappa, (1 - repo_mean[repo]) * kappa)
    # B's advantage varies by repo: it fixes a repo-specific share of A's failures (mean 5%),
    # and is worse on some repos.  The mean gap is then rescaled to exactly +2 points.
    f = rng.uniform(-0.15, 0.45, size=N_REPOS)[repo]
    p_b = np.where(f >= 0, p_a + f * (1 - p_a), p_a * (1 + f))
    p_b = np.clip(p_a + (p_b - p_a) * 0.02 / (p_b - p_a).mean(), 0, 1)   # calibrate: true gap = 2 points
    return p_a, p_b, repo


def mcnemar_exact(b: int, c: int) -> float:
    """Two-sided exact McNemar p-value from discordant counts b (A only) and c (B only)."""
    n, k = b + c, min(b, c)
    if n == 0:
        return 1.0
    tail = sum(comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def paired_bootstrap(a: np.ndarray, b: np.ndarray, rng: np.random.Generator, B: int = 4000) -> tuple[float, float]:
    idx = rng.integers(0, len(a), size=(B, len(a)))
    diffs = (b[idx] - a[idx]).mean(axis=1)
    return tuple(np.percentile(diffs, [2.5, 97.5]))


def cluster_bootstrap(a: np.ndarray, b: np.ndarray, repo: np.ndarray, rng: np.random.Generator,
                      B: int = 4000) -> tuple[float, float]:
    d_by_repo = np.array([(b[repo == r] - a[repo == r]).sum() for r in range(N_REPOS)])
    n_by_repo = np.bincount(repo, minlength=N_REPOS)
    idx = rng.integers(0, N_REPOS, size=(B, N_REPOS))
    diffs = d_by_repo[idx].sum(axis=1) / n_by_repo[idx].sum(axis=1)
    return tuple(np.percentile(diffs, [2.5, 97.5]))


def cluster_bootstrap_score(a: np.ndarray, repo: np.ndarray, rng: np.random.Generator, B: int = 4000) -> float:
    s_by_repo = np.array([a[repo == r].sum() for r in range(N_REPOS)])
    idx = rng.integers(0, N_REPOS, size=(B, N_REPOS))
    return float(np.std(s_by_repo[idx].sum(axis=1) / (PER_REPO * N_REPOS)))


def draw(p_a: np.ndarray, p_b: np.ndarray, trials: int, rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    """Per-task scores for A and B: one Bernoulli outcome (T = 1) or the mean of T outcomes."""
    if trials == 1:
        u = rng.random((2, N))                     # independent trial noise per agent
        return (u[0] < p_a).astype(float), (u[1] < p_b).astype(float)
    u = rng.random((2, trials, N))
    return (u[0] < p_a).mean(axis=0), (u[1] < p_b).mean(axis=0)


def cluster_ci_excludes_zero(d: np.ndarray, repo: np.ndarray, rng: np.random.Generator, B: int = 1000) -> bool:
    """Repository-resampled paired bootstrap of the mean difference (equal-sized repos)."""
    d_by_repo = np.bincount(repo, weights=d, minlength=N_REPOS)
    idx = rng.integers(0, N_REPOS, size=(B, N_REPOS))
    lo, hi = np.percentile(d_by_repo[idx].sum(axis=1) / N, [2.5, 97.5])
    return bool(lo > 0 or hi < 0)


def main() -> None:
    global N_REPOS, PER_REPO, N
    ap = argparse.ArgumentParser()
    ap.add_argument("--repos", type=int, default=25)
    ap.add_argument("--per-repo", type=int, default=20)
    ap.add_argument("--trials", type=int, default=1, help="trials per task per agent")
    args = ap.parse_args()
    N_REPOS, PER_REPO, T = args.repos, args.per_repo, args.trials
    N = N_REPOS * PER_REPO
    default = (N_REPOS, PER_REPO, T) == (25, 20, 1)
    if not default:
        print(f"design: {N_REPOS} repos x {PER_REPO} tasks = {N} tasks, {T} trial(s) per task")
    half = 1.96 * sqrt(0.6 * 0.4 / 500)
    print(f"binomial 95% CI half-width at p = 0.6, N = 500: +/- {100 * half:.1f} points")
    assert abs(half - 0.043) < 5e-4

    rng = np.random.default_rng(5)
    p_a, p_b, repo = make_suite(rng)
    a, b = draw(p_a, p_b, T, rng)
    pa, pb = a.mean(), b.mean()
    print(f"\none synthetic run: true means A = {p_a.mean():.3f}, B = {p_b.mean():.3f}")
    print(f"observed: A = {pa:.3f}, B = {pb:.3f}, gap = {100 * (pb - pa):+.1f} points")

    se_unpaired = sqrt(pa * (1 - pa) / N + pb * (1 - pb) / N)
    d = b - a
    se_paired = d.std(ddof=1) / sqrt(N)
    lo_pb, hi_pb = paired_bootstrap(a, b, rng)
    lo_cb, hi_cb = cluster_bootstrap(a, b, repo, rng)
    if T == 1:
        n10, n01 = int(((a == 1) & (b == 0)).sum()), int(((a == 0) & (b == 1)).sum())
        p_mc = mcnemar_exact(n10, n01)
        print(f"agreement between agents on tasks: {np.mean(a == b):.1%}; discordant A-only = {n10}, B-only = {n01}")
    print(f"\n{'method':<28} {'95% CI for B - A (points)':>28}")
    print(f"{'unpaired (independent SEs)':<28} {100 * (pb - pa - 1.96 * se_unpaired):>12.1f} to {100 * (pb - pa + 1.96 * se_unpaired):>5.1f}")
    print(f"{'paired (SE of differences)':<28} {100 * (pb - pa - 1.96 * se_paired):>12.1f} to {100 * (pb - pa + 1.96 * se_paired):>5.1f}")
    print(f"{'paired bootstrap (tasks)':<28} {100 * lo_pb:>12.1f} to {100 * hi_pb:>5.1f}")
    print(f"{'cluster bootstrap (repos)':<28} {100 * lo_cb:>12.1f} to {100 * hi_cb:>5.1f}")
    if T == 1:
        print(f"McNemar exact p-value: {p_mc:.3f}")
    else:
        print("McNemar: skipped (per-task scores are means of several trials, not binary)")
    se_naive = a.std(ddof=1) / sqrt(N) if T > 1 else sqrt(pa * (1 - pa) / N)
    se_clu = cluster_bootstrap_score(a, repo, rng)
    print(f"\nSE of agent A's score: naive {100 * se_naive:.2f} pts, cluster bootstrap {100 * se_clu:.2f} pts "
          f"(design effect {(se_clu / se_naive) ** 2:.2f})")
    if default:
        assert se_paired < se_unpaired and se_clu > se_naive and (hi_cb - lo_cb) > (hi_pb - lo_pb)

    test = "McNemar and repo-cluster paired bootstrap" if T == 1 else "repo-cluster paired bootstrap"
    print(f"\npower: 1,000 fresh suites (B better by exactly 2 points in truth), {test} at alpha = 0.05")
    rng2 = np.random.default_rng(21)
    rng_boot = np.random.default_rng(99)           # separate stream, so the suites are the same for every T
    hits, hits_clu, gaps, true_gaps = 0, 0, [], []
    for _ in range(1000):
        p_a, p_b, repo_s = make_suite(rng2)
        true_gaps.append(p_b.mean() - p_a.mean())
        a, b = draw(p_a, p_b, T, rng2)
        gaps.append(b.mean() - a.mean())
        if T == 1:
            hits += mcnemar_exact(int(((a == 1) & (b == 0)).sum()), int(((a == 0) & (b == 1)).sum())) < 0.05
        hits_clu += cluster_ci_excludes_zero(b - a, repo_s, rng_boot)
    gaps = np.array(gaps)
    mc = f"McNemar significant in {hits / 10:.1f}% of suites; " if T == 1 else ""
    print(f"  mean true gap {100 * np.mean(true_gaps):+.1f} points; {mc}cluster-bootstrap CI excludes 0 in "
          f"{hits_clu / 10:.1f}%; observed gap <= 0 in {np.mean(gaps <= 0):.1%}")
    if default:
        assert hits / 1000 < 0.5 and hits_clu / 1000 < 0.5

if __name__ == "__main__":
    main()
