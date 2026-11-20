"""Hierarchical Bayesian evaluation: Beta-Binomial partial pooling on a grid (no MCMC library).

Chapter 5, section 5.15 (#bayes).
Run:  python3 code/ch05/hierarchical.py
Shows: a small agentic eval with 8 task families and 3-12 trials each, for two agents.
Model: theta_j ~ Beta(mu * kappa, (1 - mu) * kappa), k_j ~ Binomial(n_j, theta_j), with a uniform prior
on mu and a log-uniform prior on kappa, evaluated exactly on a grid (the beta-binomial marginal
likelihood integrates theta_j out). Compares no pooling, complete pooling and partial pooling,
and reports P(agent B's population success rate > agent A's).
"""
from __future__ import annotations

import math

import numpy as np

MU = np.linspace(0.005, 0.995, 199)
KAPPA = np.exp(np.linspace(math.log(0.5), math.log(500), 120))


def log_beta(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    lg = np.vectorize(math.lgamma)
    return lg(a) + lg(b) - lg(a + b)


def grid_posterior(k: np.ndarray, n: np.ndarray) -> np.ndarray:
    """Posterior over (mu, kappa) on the grid, from the product of beta-binomial likelihoods."""
    a = MU[:, None] * KAPPA[None, :]
    b = (1 - MU[:, None]) * KAPPA[None, :]
    logp = np.zeros_like(a)
    for kj, nj in zip(k, n):
        logp += log_beta(a + kj, b + nj - kj) - log_beta(a, b)   # binomial coefficient is constant
    logp -= logp.max()
    post = np.exp(logp)
    return post / post.sum()   # uniform prior on mu, log-uniform on kappa (grid is log-spaced)


def sample(post: np.ndarray, k: np.ndarray, n: np.ndarray, rng: np.random.Generator, draws: int = 20_000):
    flat = rng.choice(post.size, size=draws, p=post.ravel())
    mi, ki = np.unravel_index(flat, post.shape)
    mu, kappa = MU[mi], KAPPA[ki]
    theta = rng.beta(mu[:, None] * kappa[:, None] + k[None, :], (1 - mu[:, None]) * kappa[:, None] + (n - k)[None, :])
    return mu, kappa, theta


def main() -> None:
    families = ["web", "shell", "sql", "email", "calendar", "files", "search", "code"]
    n = np.array([12, 10, 8, 6, 5, 4, 3, 3])
    k_a = np.array([7, 6, 4, 3, 3, 1, 3, 0])
    k_b = np.array([9, 7, 5, 4, 3, 2, 3, 1])
    rng = np.random.default_rng(55)
    res = {}
    for name, k in (("A", k_a), ("B", k_b)):
        post = grid_posterior(k, n)
        mu, kappa, theta = sample(post, k, n, rng)
        res[name] = (mu, theta)
        print(f"Agent {name}: {k.sum()}/{n.sum()} successes overall (complete pooling = {k.sum()/n.sum():.3f})")
        print(f"  population mean mu: posterior mean {mu.mean():.3f}, 95% CrI [{np.quantile(mu,0.025):.3f}, {np.quantile(mu,0.975):.3f}];"
              f" kappa median {np.median(kappa):.1f}")
        print(f"  {'family':<9} {'k/n':>6} {'no pooling':>11} {'partial pooling (95% CrI)':>28}")
        for j, f in enumerate(families):
            lo, hi = np.quantile(theta[:, j], [0.025, 0.975])
            print(f"  {f:<9} {k[j]:>2}/{n[j]:<3} {k[j]/n[j]:11.2f} {theta[:, j].mean():10.2f} [{lo:.2f}, {hi:.2f}]")
        # shrinkage: small families move most towards the population mean
        raw = k / n
        shrunk = theta.mean(axis=0)
        assert abs(shrunk[-1] - mu.mean()) < abs(raw[-1] - mu.mean())  # 0/3 is pulled up towards mu
    p_better = float(np.mean(res["B"][0] > res["A"][0]))
    diff = res["B"][0] - res["A"][0]
    print(f"\nP(mu_B > mu_A) = {p_better:.3f}; posterior mean difference = {diff.mean()*100:+.1f} pts, "
          f"95% CrI [{np.quantile(diff,0.025)*100:+.1f}, {np.quantile(diff,0.975)*100:+.1f}]")
    assert 0.5 < p_better < 0.99


if __name__ == "__main__":
    main()
