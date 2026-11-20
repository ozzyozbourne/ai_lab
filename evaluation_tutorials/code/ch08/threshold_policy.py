"""From eval scores to framework decisions: rule out vs cannot rule out (Chapter 8.12, #frameworks).

A hypothetical capability threshold: "the model solves >= 20% of an expert-level threshold
task suite". Five mock models report k successes out of n tasks. Three decision rules:
  point     : act if the point estimate k/n >= threshold
  upper-CI  : 'rule out' only if the Wilson 95% upper bound < threshold; 'crossed' if the lower
              bound >= threshold; otherwise 'cannot rule out' -> apply the safeguards anyway
  upper-CI + elicitation margin: as upper-CI but the upper bound is raised by 0.05 to allow for
              capability the evaluators failed to elicit
Then a Monte Carlo check: for a model whose true rate is just over the threshold, how often does
each rule wrongly clear it?

Run:  python3 code/ch08/threshold_policy.py
Key output: 7/60 (11.7%) is 'below' on the point rule but 'cannot rule out' (upper bound 0.222);
a true-0.22 model is wrongly cleared 30.1% of the time by the point rule, 0.46% by upper-CI.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from _common import table, wilson  # noqa: E402

THRESHOLD, MARGIN = 0.20, 0.05
MODELS = {"model A": (2, 60), "model B": (4, 60), "model C": (7, 60), "model D": (19, 60), "model E": (5, 15)}


def decide(k: int, n: int, rule: str) -> str:
    lo, hi = wilson(k, n)
    if rule == "point":
        return "above" if k / n >= THRESHOLD else "below"
    hi = hi + (MARGIN if rule == "margin" else 0.0)
    if hi < THRESHOLD:
        return "rule out"
    return "crossed" if lo >= THRESHOLD else "cannot rule out"


def main() -> None:
    rows = []
    for name, (k, n) in MODELS.items():
        lo, hi = wilson(k, n)
        rows.append((name, f"{k}/{n}", f"{k / n:.3f}", f"[{lo:.3f}, {hi:.3f}]",
                     decide(k, n, "point"), decide(k, n, "upper"), decide(k, n, "margin")))
    print(f"threshold = {THRESHOLD:.0%}, elicitation margin = {MARGIN:.2f}")
    print(table(rows, ["model", "k/n", "rate", "Wilson 95% CI", "point rule", "upper-CI rule",
                       "upper-CI + margin"]))
    assert decide(2, 60, "upper") == "rule out" and decide(7, 60, "upper") == "cannot rule out"
    assert decide(4, 60, "upper") == "rule out" and decide(4, 60, "margin") == "cannot rule out"
    assert decide(19, 60, "upper") == "crossed" and decide(5, 15, "point") == "above"

    rng = np.random.default_rng(12)
    true_p, n, sims = 0.22, 60, 20000
    k = rng.binomial(n, true_p, size=sims)
    clear_point = np.mean(k / n < THRESHOLD)
    clear_upper = np.mean([decide(int(x), n, "upper") == "rule out" for x in k])
    clear_margin = np.mean([decide(int(x), n, "margin") == "rule out" for x in k])
    print(f"\ntrue rate {true_p:.2f} (above threshold), n = {n}: probability the model is wrongly cleared")
    print(f"  point rule      : {clear_point:.3f}")
    print(f"  upper-CI rule   : {clear_upper:.4f}")
    print(f"  upper-CI+margin : {clear_margin:.4f}")
    true_low = rng.binomial(n, 0.05, size=sims)
    burden = np.mean([decide(int(x), n, "upper") != "rule out" for x in true_low])
    print(f"cost: a model with true rate 0.05 is NOT ruled out (safeguards applied) {burden:.3f} of the time")
    assert clear_upper < 0.01 < clear_point


if __name__ == "__main__":
    main()
