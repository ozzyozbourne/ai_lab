"""Proving contamination without the training data: the sharded rank-comparison (permutation) test.

Chapter 3, section 3.11 (#detect-blackbox). After Oren et al. 2023 (tatsu-lab/test_set_contamination):
if a model never saw a benchmark, every ordering of its (exchangeable) items is equally likely, so a
preference for the published order is evidence of verbatim, ordered contamination.
Run:  python3 code/ch03/permutation_test.py
Expected key output: z is large (p << 0.001) for a model trained on the benchmark file in canonical
order, and near 0 for a model trained on a shuffled copy or never trained on it.
"""
from __future__ import annotations

import math
import random

import numpy as np

from _common import BigramLM

SEED, N_ITEMS, SHARDS, PERMS = 31, 1000, 50, 50
NAMES = [f"name{i}" for i in range(60)]   # placeholder first tokens; real items start with varied words
OBJS = ["apples", "coins", "shells", "tickets", "bricks", "jars"]


def make_item(rng: random.Random) -> list[str]:
    a, b = rng.randint(2, 99), rng.randint(2, 99)
    return (f"{rng.choice(NAMES)} has {a} {rng.choice(OBJS)} and gets {b} more . "
            f"how many now ? answer {a + b}").split()


def flat(items: list[list[str]]) -> list[str]:
    return [w for it in items for w in it]


def shard_logprob(lm: BigramLM, items: list[list[str]]) -> float:
    return float(lm.logprobs(flat(items)).sum())


def sharded_test(lm: BigramLM, bench: list[list[str]], rng: random.Random) -> tuple[float, float]:
    size = len(bench) // SHARDS
    diffs = []
    for i in range(SHARDS):
        shard = bench[i * size:(i + 1) * size]
        canon = shard_logprob(lm, shard)
        perm = [shard_logprob(lm, rng.sample(shard, k=len(shard))) for _ in range(PERMS)]
        diffs.append(canon - float(np.mean(perm)))
    d = np.asarray(diffs)
    z = float(np.mean(d) / np.std(d) * np.sqrt(len(d)))   # the line from the reference implementation
    p = 0.5 * math.erfc(z / math.sqrt(2))                 # one-sided; the repo uses a t-distribution
    return z, p


if __name__ == "__main__":
    rng = random.Random(SEED)
    bench = [make_item(rng) for _ in range(N_ITEMS)]           # the published, canonical order
    background = [make_item(rng) for _ in range(5000)]          # same-distribution other text
    shuffled_copy = rng.sample(bench, k=len(bench))

    models = {
        "trained on benchmark file (canonical order)": BigramLM(background + [flat(bench)]),
        "trained on a shuffled copy": BigramLM(background + [flat(shuffled_copy)]),
        "never saw the benchmark": BigramLM(background),
    }
    print(f"{N_ITEMS} items, {SHARDS} shards of {N_ITEMS // SHARDS}, {PERMS} permutations per shard\n")
    print(f"{'model':<46}{'z':>8}{'one-sided p':>14}")
    res = {}
    for name, lm in models.items():
        z, p = sharded_test(lm, bench, random.Random(SEED + 1))
        res[name] = (z, p)
        ptxt = f"{p:.2e}" if p > 1e-300 else "< 1e-300"
        print(f"{name:<46}{z:8.2f}{ptxt:>14}")

    (z_c, p_c), (z_s, _), (z_n, _) = res.values()
    assert z_c > 5 and p_c < 1e-6
    assert abs(z_s) < 3 and abs(z_n) < 3
    print("\nall checks passed")
