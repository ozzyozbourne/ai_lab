"""Juries of judges (PoLL) and why correlated errors limit the gain (Chapter 4.7, #aggregation).

Binary correct/incorrect QA judgments on 2,000 items. Each mock judge is right 80% of the time.
A panel takes the majority (max) vote. With independent judges, majority voting of 3 gives
3p^2 - 2p^3 = 0.896. When judges share a "family" error (with probability rho a judge copies
its family's shared verdict, which is itself only 80% right), the gain shrinks.
We also reproduce the PoLL cost ratio from the paper's per-million-token prices.

Run: python3 code/ch04/jury_poll.py
"""
from __future__ import annotations

from math import comb

import numpy as np

P_CORRECT, N_ITEMS = 0.80, 2000


def panel_verdicts(truth: np.ndarray, k: int, rho: float, rng, n_families: int = 1) -> np.ndarray:
    """k judges spread over n_families; returns (k, n) verdict matrix."""
    n = len(truth)
    family_correct = rng.random((n_families, n)) < P_CORRECT
    out = []
    for j in range(k):
        fam = j % n_families
        own_correct = rng.random(n) < P_CORRECT
        copy = rng.random(n) < rho
        correct = np.where(copy, family_correct[fam], own_correct)
        out.append(np.where(correct, truth, ~truth))
    return np.array(out)


def judge_run_cost(items: int, orders: int, samples: int, tok_in: int, tok_out: int, p_in: float, p_out: float) -> float:
    """Dollar cost of a judge run; prices are per million tokens."""
    return items * orders * samples * (tok_in * p_in + tok_out * p_out) / 1e6


def kappa(a: np.ndarray, b: np.ndarray) -> float:
    p_o = np.mean(a == b)
    p_e = a.mean() * b.mean() + (1 - a.mean()) * (1 - b.mean())
    return (p_o - p_e) / (1 - p_e)


def main() -> None:
    rng = np.random.default_rng(5)
    truth = rng.random(N_ITEMS) < 0.6
    theory3 = 3 * P_CORRECT ** 2 - 2 * P_CORRECT ** 3
    theory5 = sum(comb(5, j) * P_CORRECT ** j * (1 - P_CORRECT) ** (5 - j) for j in range(3, 6))
    print(f"Each judge correct with p = {P_CORRECT}; independent majority vote, theory: k=3 {theory3:.3f}, k=5 {theory5:.3f}\n")
    print(f"{'setting':<44}{'k=1':>8}{'k=3':>8}{'k=5':>8}   (accuracy vs truth)")
    acc = {}
    for name, rho, fams in (("independent judges (diverse families)", 0.0, 5),
                            ("same family, rho = 0.3", 0.3, 1),
                            ("same family, rho = 0.6", 0.6, 1)):
        row = []
        for k in (1, 3, 5):
            v = panel_verdicts(truth, k, rho, rng, n_families=fams)
            maj = v.sum(0) * 2 > k
            row.append(np.mean(maj == truth))
        acc[name] = row
        print(f"{name:<44}" + "".join(f"{a:>8.3f}" for a in row))
    ind = acc["independent judges (diverse families)"]
    corr = acc["same family, rho = 0.6"]
    assert abs(ind[1] - theory3) < 0.02
    assert (corr[1] - corr[0]) < (ind[1] - ind[0]) / 2

    v = panel_verdicts(truth, 3, 0.0, rng, n_families=3)
    maj = v.sum(0) >= 2
    print(f"\nkappa vs truth: single judge {kappa(v[0], truth):.3f}, majority of 3 diverse judges {kappa(maj, truth):.3f}")

    # PoLL cost (Verga et al. 2024): panel $1.25/M input + $4.25/M output vs GPT-4 Turbo $10 + $30
    tin, tout = 1000, 200   # tokens per judgment, an assumption for illustration
    panel = (tin * 1.25 + tout * 4.25) / 1e6
    gpt4t = (tin * 10 + tout * 30) / 1e6
    print(f"Cost per judgment at {tin} input / {tout} output tokens: panel ${panel:.4f} vs GPT-4 Turbo ${gpt4t:.4f}"
          f" -> {gpt4t / panel:.1f}x cheaper")
    assert 7 < gpt4t / panel < 8

    # Cost of one eval run (Section 4.13): items x orders x samples x (in*p_in + out*p_out)
    run_cost = judge_run_cost(items=2000, orders=2, samples=1, tok_in=1500, tok_out=400, p_in=3.0, p_out=15.0)
    print(f"Eval run: 2,000 items x 2 orders x 1 sample x (1,500 in at $3/M + 400 out at $15/M) = ${run_cost:.2f}")
    assert abs(run_cost - 42.0) < 1e-9


if __name__ == "__main__":
    main()
