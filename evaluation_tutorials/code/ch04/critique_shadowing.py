"""Critique shadowing with a train/dev/test split for the judge prompt (Chapter 4.5, #rubrics).

A principal domain expert labels 60 support-bot traces PASS/FAIL, each with a one-line critique.
The "judge prompt" is modelled as a configuration: which binary fail-criteria it lists plus an
optional length limit. A mock LLM applies each listed criterion with imperfect detection
(seeded per trace, so a given prompt always behaves the same on a given trace).

1. Split the 60 labels into train (12), dev (24) and test (24).
2. Read the train + dev critiques to find candidate criteria (the failure modes the expert names).
3. Iterate the prompt on dev only: choose which of the named criteria to list, by the best
   balanced accuracy (mean of TPR and TNR). Report TPR/TNR on test once.
4. The shortcut: search all 640 prompt variants directly on test. Test looks better; fresh
   traffic (3,000 new traces) does not. Then repeat the whole study 200 times to show the
   optimism is systematic, not luck.

Run: python3 code/ch04/critique_shadowing.py
"""
from __future__ import annotations

import itertools
import re

import numpy as np

CRITERIA = ["unanswered", "invented_policy", "rude", "uses_bullets", "mentions_competitor", "has_emoji",
            "asks_clarifying"]
PREVALENCE = np.array([0.18, 0.15, 0.10, 0.50, 0.15, 0.20, 0.25])
HIT = np.array([0.90, 0.80, 0.85, 0.98, 0.95, 0.99, 0.90])    # P(mock LLM flags | property present)
FALSE = np.array([0.08, 0.06, 0.05, 0.02, 0.03, 0.01, 0.05])  # P(mock LLM flags | property absent)
LENGTH_LIMITS = [None, 120, 160, 200, 240]
EXPERT_FAIL = [0, 1, 2]  # the expert fails a trace if it is unanswered, invents policy, or is rude


def make_traces(n: int, rng: np.random.Generator) -> dict:
    feats = rng.random((n, len(CRITERIA))) < PREVALENCE
    flags = rng.random((n, len(CRITERIA))) < np.where(feats, HIT, FALSE)
    length = rng.normal(150, 50, n).astype(int)
    label = ~feats[:, EXPERT_FAIL].any(1)
    noise = rng.random(n) < 0.05                       # expert judgement calls no rule captures
    label = label ^ noise
    critiques = []
    for i in range(n):
        reasons = [CRITERIA[k] for k in EXPERT_FAIL if feats[i, k]]
        if label[i]:
            critiques.append("PASS: answers the question within policy, polite tone.")
        else:
            critiques.append("FAIL: " + (", ".join(reasons) if reasons else "judgement call, hard to articulate") + ".")
    return {"flags": flags, "length": length, "label": label, "critique": critiques}


def subset(d: dict, sl: slice) -> dict:
    return {k: v[sl] for k, v in d.items()}


def judge(prompt: tuple, d: dict) -> np.ndarray:
    mask, limit = prompt
    passed = ~d["flags"][:, list(mask)].any(1) if mask else np.ones(len(d["label"]), bool)
    if limit is not None:
        passed &= d["length"] <= limit
    return passed


def tpr_tnr(prompt, d) -> tuple[float, float]:
    p, y = judge(prompt, d), d["label"]
    return float(p[y].mean()), float((~p[~y]).mean())


def bal(prompt, d) -> float:
    return float(np.mean(tpr_tnr(prompt, d)))


def describe(prompt) -> str:
    mask, limit = prompt
    return ", ".join(CRITERIA[k] for k in mask) + (f", length>{limit}" if limit else "")


def all_prompts(candidates: list[int], limits=LENGTH_LIMITS) -> list[tuple]:
    return [(tuple(c for c, on in zip(candidates, bits) if on), L)
            for bits in itertools.product([0, 1], repeat=len(candidates)) for L in limits]


def study(rng, verbose: bool = False) -> tuple[float, float]:
    labelled, fresh = make_traces(60, rng), make_traces(3000, rng)
    train, dev, test = subset(labelled, slice(0, 12)), subset(labelled, slice(12, 36)), subset(labelled, slice(36, 60))
    named = set()
    for c in train["critique"] + dev["critique"]:
        named |= {CRITERIA.index(w) for w in re.findall(r"[a-z_]+", c) if w in CRITERIA}
    candidates = sorted(named)
    # No critique ever complains about length, so the dev search does not add a length rule.
    dev_space = all_prompts(candidates, limits=[None])
    dev_prompt = max(dev_space, key=lambda p: (bal(p, dev), -len(p[0]), p[1] is None))
    full = all_prompts(list(range(len(CRITERIA))))
    test_prompt = max(full, key=lambda p: (bal(p, test), -len(p[0])))
    if verbose:
        y = labelled["label"]
        print(f"60 expert labels: {y.sum()} PASS / {(~y).sum()} FAIL; split train 12 / dev 24 / test 24")
        print("Distinct expert critiques in train + dev (with counts):")
        crits = train["critique"] + dev["critique"]
        for c in sorted(set(crits), key=lambda c: (-crits.count(c), c)):   # ties: alphabetical
            print(f"  {crits.count(c):>2} x  {c}")
        print(f"Failure modes named in train+dev critiques: {[CRITERIA[k] for k in candidates]}")
        print(f"Dev search: {len(dev_space)} variants; test-set search: {len(full)} variants\n")
        print(f"{'':<24}{'judge prompt lists':<46}{'test TPR / TNR':>16}{'fresh TPR / TNR':>18}")
        for name, p in (("tuned on dev", dev_prompt), ("tuned on test (wrong)", test_prompt)):
            tt, ft = tpr_tnr(p, test), tpr_tnr(p, fresh)
            print(f"{name:<24}{describe(p):<46}{tt[0]:>8.2f} / {tt[1]:.2f}{ft[0]:>10.2f} / {ft[1]:.2f}")
    return (bal(dev_prompt, test) - bal(dev_prompt, fresh), bal(test_prompt, test) - bal(test_prompt, fresh))


def main() -> None:
    gap_dev, gap_test = study(np.random.default_rng(14), verbose=True)
    print(f"\nOptimism = test balanced accuracy minus fresh balanced accuracy")
    print(f"  this run: dev-tuned {gap_dev:+.3f}   test-tuned {gap_test:+.3f}")
    rng = np.random.default_rng(1)
    gaps = np.array([study(rng) for _ in range(200)])
    print(f"  mean over 200 repeated studies: dev-tuned {gaps[:, 0].mean():+.3f}   test-tuned {gaps[:, 1].mean():+.3f}")
    assert gaps[:, 1].mean() > gaps[:, 0].mean() + 0.05
    assert abs(gaps[:, 0].mean()) < 0.03


if __name__ == "__main__":
    main()
