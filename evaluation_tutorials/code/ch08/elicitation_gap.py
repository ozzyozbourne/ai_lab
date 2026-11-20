"""Under-elicitation flips a dangerous-capability decision (Chapter 8.8, #dangerous-capabilities).

A mock suite of 40 CTF-like tasks (TASK_00 ... TASK_39), each with 4 subtasks. A mock model has a
latent ability theta; the chance of solving a task in one attempt is sigmoid(theta - d_task + s),
where s is the elicitation boost of the setup:
  weak scaffold (single prompt, small token budget)  s = -1.5
  strong agent scaffold                               s =  0.0
  strong scaffold after fine-tuning elicitation       s = +0.5
We draw n = 10 attempts per task, and report pass@1 and the unbiased pass@10 estimator
(Chen et al.), plus subtask partial credit. The policy threshold is "the model solves >= 25% of
tasks"; we 'rule out' only if the Wilson upper bound on the solved fraction is below 25%.

Run:  python3 code/ch08/elicitation_gap.py
Key output: weak scaffold + pass@1 (0.052) would rule the capability out; strong scaffold + pass@10
(0.675) crosses the threshold. Worked pass@k: n = 10, c = 2, k = 5 -> 0.778; worked time horizon t50 = 64 min.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from _common import table, wilson  # noqa: E402

THRESHOLD = 0.25


def pass_at_k(n: int, c: int, k: int) -> float:
    if n - c < k:
        return 1.0
    return 1.0 - math.comb(n - c, k) / math.comb(n, k)


def main() -> None:
    rng = np.random.default_rng(5)
    d = rng.normal(2.0, 1.5, size=40)                # task difficulty (logit units)
    theta = -0.6
    setups = {"weak scaffold": -1.5, "strong scaffold": 0.0, "strong + fine-tune elicit": 0.5}
    n = 10
    rows, decisions = [], {}
    for name, boost in setups.items():
        p = 1 / (1 + np.exp(-(theta - d + boost)))
        c = rng.binomial(n, p)                         # successes out of n attempts per task
        # subtasks are easier: each of 4 subtasks solved with prob sigmoid(theta - d + boost + 1.5)
        p_sub = 1 / (1 + np.exp(-(theta - d + boost + 1.5)))
        sub_credit = rng.binomial(4, p_sub).mean() / 4
        p1 = np.mean([pass_at_k(n, int(ci), 1) for ci in c])
        p10 = np.mean([pass_at_k(n, int(ci), 10) for ci in c])
        for metric, val in (("pass@1", p1), ("pass@10", p10)):
            k = round(val * 40)
            lo, hi = wilson(k, 40)
            verdict = "rule out" if hi < THRESHOLD else ("crossed" if lo >= THRESHOLD else "cannot rule out")
            decisions[(name, metric)] = verdict
            rows.append((name, metric, f"{val:.3f}", f"[{lo:.3f}, {hi:.3f}]", f"{sub_credit:.3f}", verdict))
    print(f"40 tasks, n = {n} attempts each, threshold = {THRESHOLD:.0%} of tasks solved")
    print(table(rows, ["setup", "metric", "solved", "Wilson 95% CI", "subtask credit", "decision"]))

    print(f"\nworked pass@k: n = 10, c = 2, k = 5 -> {pass_at_k(10, 2, 5):.3f}")
    assert abs(pass_at_k(10, 2, 5) - 0.778) < 1e-3
    a, b = 3.0, 0.5                                    # METR-style P = sigmoid(a - b * log2 t)
    t50 = 2 ** (a / b)
    print(f"worked time horizon: a = {a}, b = {b} -> t50 = 2^(a/b) = {t50:.0f} min; "
          f"after one 7-month doubling: {2 * t50:.0f} min")
    assert t50 == 64
    assert decisions[("weak scaffold", "pass@1")] == "rule out"
    assert decisions[("strong scaffold", "pass@10")] != "rule out"


if __name__ == "__main__":
    main()
