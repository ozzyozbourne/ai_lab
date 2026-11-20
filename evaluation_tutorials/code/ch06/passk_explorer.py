"""pass@k vs pass^k for agents: the worked example, the estimators, and Figure 6.3 values.

Section 6.6 (#reliability) of Chapter 6.  Run:  python3 code/ch06/passk_explorer.py

Part 1 reproduces the worked example: n = 8 trials on four tasks with c = 8, 6, 2, 0 successes
gives pass^2 = 0.393 and pass@2 = 0.607.  The estimators are the human-eval product form for
pass@k and tau-bench's comb(c, k) / comb(n, k) for pass^k.
Part 2 simulates 200 tasks whose per-task success probabilities follow Beta(2, 2)
(mean 0.5) and shows that pass^k tracks mean(p_i^k), far above (mean p)^k: heterogeneity matters.
Part 3 prints the curve values used in Figure 6.3.
"""
from __future__ import annotations

from math import comb

import numpy as np


def pass_at_k(n: int, c: int, k: int) -> float:
    """Unbiased pass@k, numerically stable form from openai/human-eval."""
    if n - c < k:
        return 1.0
    return float(1.0 - np.prod(1.0 - k / np.arange(n - c + 1, n + 1)))


def pass_hat_k(n: int, c: int, k: int) -> float:
    """Unbiased pass^k as in sierra-research/tau-bench: P(all k of k draws succeed)."""
    return comb(c, k) / comb(n, k)


def mean_over_tasks(f, n: int, cs: list[int], k: int) -> float:
    return sum(f(n, c, k) for c in cs) / len(cs)


def main() -> None:
    n, cs = 8, [8, 6, 2, 0]
    print("Part 1: worked example, n = 8 trials, successes per task c =", cs)
    print(f"  {'k':>2} {'pass@k':>8} {'pass^k':>8}")
    table = {}
    for k in (1, 2, 4, 8):
        a, h = mean_over_tasks(pass_at_k, n, cs, k), mean_over_tasks(pass_hat_k, n, cs, k)
        table[k] = (a, h)
        print(f"  {k:>2} {a:>8.3f} {h:>8.3f}")
    per_task = [pass_hat_k(n, c, 2) for c in cs]
    print("  per-task pass^2:", [f"{x:.3f}" for x in per_task], "(e.g. C(6,2)/C(8,2) = 15/28)")
    assert abs(table[2][1] - 0.393) < 1e-3 and abs(table[2][0] - 0.607) < 1e-3
    assert table[8] == (0.75, 0.25) and table[1] == (0.5, 0.5)
    # Anthropic's example: 75% per-trial success, 3 trials -> 0.75^3
    print(f"  single task with p = 0.75: pass^3 = {0.75 ** 3:.3f}")

    print("\nPart 2: 200 tasks, p_i ~ Beta(2, 2), n = 16 trials each (seed 6)")
    rng = np.random.default_rng(6)
    p = rng.beta(2, 2, size=200)
    c_sim = rng.binomial(16, p)
    print(f"  {'k':>2} {'est pass@k':>11} {'est pass^k':>11} {'mean(p^k)':>10} {'(mean p)^k':>11}")
    rows = []
    for k in (1, 2, 4, 8, 16):
        a = mean_over_tasks(pass_at_k, 16, list(c_sim), k)
        h = mean_over_tasks(pass_hat_k, 16, list(c_sim), k)
        rows.append((k, a, h, float(np.mean(p ** k)), float(p.mean() ** k)))
        print(f"  {k:>2} {a:>11.3f} {h:>11.3f} {np.mean(p ** k):>10.3f} {p.mean() ** k:>11.3f}")
    k8 = rows[3]
    assert abs(k8[2] - k8[3]) < 0.03 and k8[3] > 3 * k8[4]

    print("\nPart 3: Figure 6.3 values (worked-example tasks, k = 1..8)")
    for k in range(1, 9):
        print(f"  k={k}: pass@k={mean_over_tasks(pass_at_k, n, cs, k):.3f}  "
              f"pass^k={mean_over_tasks(pass_hat_k, n, cs, k):.3f}")


if __name__ == "__main__":
    main()
