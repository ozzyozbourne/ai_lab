"""Honest error bars and comparisons for attack success rates (Chapter 8.5, #asr).

Part 1: Wilson 95% intervals for 12/100 and 18/100 (a JailbreakBench-sized behaviour set).
Part 2: unpaired two-proportion z-test vs paired McNemar on the same 100 behaviours, for two
        pairings with identical marginals (12% vs 18%) but different overlap.
Part 3: universal vs per-behaviour jailbreaks on a mock 20-template x 100-behaviour success
        matrix, and the selection bias from picking the best template on the test behaviours.

Run:  python3 code/ch08/asr_stats.py
Key output: Wilson [0.070, 0.198] for 12/100; z = 1.19, p = 0.23; McNemar p = 0.180 for
b = 10, c = 4 but p = 0.031 for b = 6, c = 0.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from _common import mcnemar_exact, two_prop_z, wilson  # noqa: E402


def paired_outcomes(both: int, a_only: int, b_only: int, n: int = 100) -> tuple[list[int], list[int]]:
    a = [1] * both + [1] * a_only + [0] * b_only
    b = [1] * both + [0] * a_only + [1] * b_only
    rest = n - len(a)
    return a + [0] * rest, b + [0] * rest


def main() -> None:
    print("Part 1: Wilson 95% CIs on 100 behaviours")
    for k in (12, 18):
        lo, hi = wilson(k, 100)
        print(f"  {k}/100: ASR = {k / 100:.2f}, CI = [{lo:.3f}, {hi:.3f}]")
    lo12, hi12 = wilson(12, 100)
    assert abs(lo12 - 0.070) < 1e-3 and abs(hi12 - 0.198) < 1e-3

    z, p = two_prop_z(12, 100, 18, 100)
    print(f"\nPart 2: attack A 12/100 vs attack B 18/100\n  unpaired z-test: z = {z:.2f}, p = {p:.3f}")
    assert abs(z - 1.19) < 0.01 and abs(p - 0.235) < 0.005
    for both, a_only, b_only in [(8, 4, 10), (12, 0, 6)]:
        a, b = paired_outcomes(both, a_only, b_only)
        assert sum(a) == 12 and sum(b) == 18
        pm = mcnemar_exact(b_only, a_only)
        print(f"  paired, both broken = {both:2d}, A-only c = {a_only}, B-only b = {b_only:2d}: "
              f"exact McNemar p = {pm:.3f}")
    assert abs(mcnemar_exact(10, 4) - 0.180) < 1e-3
    assert abs(mcnemar_exact(6, 0) - 0.031) < 1e-3

    print("\nPart 3: universal vs per-behaviour jailbreaks (mock success matrix)")
    rng = np.random.default_rng(3)
    strength = rng.normal(-2.0, 0.25, size=20)              # template effectiveness (logit)
    suscept = rng.normal(0.0, 1.2, size=100)               # behaviour susceptibility (logit)
    prob = 1 / (1 + np.exp(-(strength[:, None] + suscept[None, :])))
    success = rng.random(prob.shape) < prob               # one attempt per (template, behaviour)
    per_template = success.mean(axis=1)
    print(f"  best single template ('universal') ASR  = {per_template.max():.3f}")
    print(f"  median template ASR                     = {np.median(per_template):.3f}")
    print(f"  any of 20 templates per behaviour       = {success.any(axis=0).mean():.3f}")
    # Selection bias: choose the best template on half the behaviours, test on the other half
    dev, test = np.arange(50), np.arange(50, 100)
    best = int(np.argmax(success[:, dev].mean(axis=1)))
    print(f"  template chosen on dev half: dev ASR = {success[best, dev].mean():.3f}, "
          f"held-out ASR = {success[best, test].mean():.3f}, true mean p = {prob[best].mean():.3f}")
    assert success.any(axis=0).mean() > per_template.max()
    assert success[best, dev].mean() > prob[best].mean()  # winner's curse on the dev half


if __name__ == "__main__":
    main()
