"""Membership-inference scores on a toy LM: perplexity, zlib ratio, Min-K% Prob, Min-K%++, and a blind baseline.

Chapter 3, section 3.11 (#detect-blackbox), Figure 3.4. After Shi et al. 2023 (Min-K%),
Zhang et al. 2024 (Min-K%++), Carlini et al. 2020 (zlib), Duan et al. 2024 and Das et al. 2024
(distribution shift and blind baselines).
Run:  python3 code/ch03/mock_lm_minkprob.py
Expected key output: worked Min-20% = -4.5; on same-distribution non-members the LM scores give
modest AUROC and the blind baseline ~0.5; on shifted non-members everything, including the blind
baseline that never looks at the model, scores near 1.0.
"""
from __future__ import annotations

import math
import random
import zlib

import numpy as np

from _common import BigramLM, auroc, make_item

SEED, N_BENCH, N_BACKGROUND, K = 17, 400, 6000, 0.2


def min_k(lp: np.ndarray, k: float = K) -> float:
    """Mean of the lowest k-fraction of token log-probs (higher = more likely seen)."""
    m = max(1, int(len(lp) * k))
    return float(np.mean(np.sort(lp)[:m]))


def min_k_pp(lm: BigramLM, seq: list[str], k: float = K) -> float:
    toks = ["<s>"] + seq
    z = []
    for prev, w in zip(toks, toks[1:]):
        mu, sd = lm.next_dist_stats(prev)
        z.append((np.log(lm.p(prev, w)) - mu) / sd)
    return min_k(np.array(z), k)


def scores(lm: BigramLM, seq: list[str]) -> dict[str, float]:
    lp = lm.logprobs(seq)
    log_ppl = -float(lp.mean())
    text = " ".join(seq)
    return {"-log PPL": -log_ppl,
            "-log PPL / zlib bytes": -log_ppl / len(zlib.compress(text.encode())),
            "Min-20% Prob": min_k(lp),
            "Min-20%++": min_k_pp(lm, seq),
            "blind: -length": -float(len(seq))}


if __name__ == "__main__":
    lp_demo = np.array([-0.1, -0.2, -5.0, -0.3, -4.0, -0.1, -0.2, -0.4, -0.3, -0.2])
    print(f"worked example: Min-20% of the 10 token log-probs = {min_k(lp_demo):.2f}")
    assert abs(min_k(lp_demo) + 4.5) < 1e-12

    rng = random.Random(SEED)
    bench = [make_item(rng) for _ in range(N_BENCH)]
    members, nonmembers = bench[: N_BENCH // 2], bench[N_BENCH // 2:]
    shifted = [make_item(rng, shifted=True) for _ in range(N_BENCH // 2)]
    background = [make_item(rng) for _ in range(N_BACKGROUND)]
    lm = BigramLM(background + members)          # half the benchmark leaked into training, once each

    S = {name: [scores(lm, s) for s in group]
         for name, group in (("members", members), ("same-dist", nonmembers), ("shifted", shifted))}
    keys = list(S["members"][0])
    print(f"\n{'score':<24}{'AUROC vs same-dist':>20}{'AUROC vs shifted':>18}")
    res = {}
    for k in keys:
        pos = np.array([d[k] for d in S["members"]])
        a1 = auroc(pos, np.array([d[k] for d in S["same-dist"]]))
        a2 = auroc(pos, np.array([d[k] for d in S["shifted"]]))
        res[k] = (a1, a2)
        print(f"{k:<24}{a1:20.3f}{a2:18.3f}")

    print("\nMin-20% Prob distribution (Figure 3.4)")
    print(f"  {'set':<10}{'mean':>8}{'p10':>8}{'p25':>8}{'p50':>8}{'p75':>8}{'p90':>8}")
    for g in S:
        v = np.array([d["Min-20% Prob"] for d in S[g]])
        q = np.percentile(v, [10, 25, 50, 75, 90])
        print(f"  {g:<10}{v.mean():8.2f}" + "".join(f"{x:8.2f}" for x in q))

    # Set-level test in the spirit of dataset inference (Maini et al. 2024): is a whole suspect set
    # more 'familiar' than a held-out set we know is clean and drawn from the same distribution?
    rng_fresh = random.Random(SEED + 1)
    fresh = [make_item(rng_fresh) for _ in range(N_BENCH // 2)]
    S["fresh"] = [scores(lm, s) for s in fresh]

    def welch(a_name: str, b_name: str, key: str = "-log PPL") -> tuple[float, float]:
        a = np.array([d[key] for d in S[a_name]]); b = np.array([d[key] for d in S[b_name]])
        t = (a.mean() - b.mean()) / math.sqrt(a.var(ddof=1) / len(a) + b.var(ddof=1) / len(b))
        return t, 0.5 * math.erfc(t / math.sqrt(2))      # one-sided, normal approximation
    print("\nset-level test on -log PPL (suspect set vs known-clean same-distribution set)")
    t1, p1 = welch("members", "fresh")
    t0, p0 = welch("same-dist", "fresh")
    print(f"  leaked half   vs clean: t = {t1:5.2f}, one-sided p = {p1:.2g}")
    print(f"  unleaked half vs clean: t = {t0:5.2f}, one-sided p = {p0:.2g}")
    assert p1 < 0.01 < p0

    assert 0.45 < res["blind: -length"][0] < 0.55          # blind baseline is useless when i.i.d.
    assert res["blind: -length"][1] > 0.95                  # ...and 'excellent' under shift
    assert res["Min-20%++"][1] > 0.95 and res["Min-20% Prob"][1] > 0.95
    assert res["Min-20% Prob"][0] < res["Min-20% Prob"][1] - 0.1   # the shift inflates the MIA
    print("\nall checks passed")
