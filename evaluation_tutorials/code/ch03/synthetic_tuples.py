"""Synthetic test generation with dimension tuples, Evol-style rewrites and diversity checks.

Chapter 3, section 3.7 (#synthetic), Figure 3.3.
Run:  python3 code/ch03/synthetic_tuples.py
Expected key output: 4x4x4 = 64 raw tuples, 54 valid after the filter; a single-template mock
"LLM" yields low distinct-2 and a high near-duplicate rate; varied templates + evolution fix both.
"""
from __future__ import annotations

import itertools
import random
import re

PERSONAS = ["first-time user", "small-business owner", "accountant", "non-native English speaker"]
FEATURES = ["invoice export", "refund request", "tax settings", "multi-currency"]
SCENARIOS = ["happy path", "ambiguous request", "missing information", "policy edge case"]

# Combinations that make no sense for the product (would waste labelling budget).
INVALID = {("first-time user", "tax settings", "policy edge case"),
           ("first-time user", "multi-currency", "policy edge case")}
INVALID |= {(p, "refund request", "happy path") for p in ("accountant", "small-business owner")}
INVALID |= {(p, "invoice export", s) for p in PERSONAS for s in ("policy edge case",)}
INVALID |= {("accountant", f, "missing information") for f in ("invoice export", "multi-currency")}

ONE_TEMPLATE = ["As a {p}, I need help with {f}. ({s})"]
MANY_TEMPLATES = [
    "hi, {p_short} here. {ask}",
    "{ask} I'm a {p}, if that matters.",
    "Quick one about {f}: {ask}",
    "{ask}",
    "Context: {p}. Problem: {ask} Thanks!",
]
ASKS = {
    "happy path": "how do I do {f} step by step?",
    "ambiguous request": "can you sort out the {f} thing from last week?",
    "missing information": "my {f} failed, what now?",
    "policy edge case": "is {f} allowed if my account was opened in another country 40 days ago?",
}

EVOLVE_OPS = {
    "add_constraint": lambda q, r: q + r.choice([" Answer in under 50 words.", " Do not use bullet points.",
                                                   " I can't log in on desktop, only mobile."]),
    "deepen": lambda q, r: q + r.choice([" Also, why does it work this way?", " What are the risks if I get it wrong?"]),
    "concretize": lambda q, r: q + f" The amount is {r.choice(['$42.10', 'EUR 1,250', '$0.99'])}, invoice #{r.randint(1000, 9999)}.",
    "increase_steps": lambda q, r: q + " After that, I also need to send the result to my bookkeeper and update last quarter.",
}


def tuples() -> tuple[list[tuple[str, str, str]], list[tuple[str, str, str]]]:
    raw = list(itertools.product(PERSONAS, FEATURES, SCENARIOS))
    return raw, [t for t in raw if t not in INVALID]


def mock_llm(t: tuple[str, str, str], templates: list[str], rng: random.Random) -> str:
    """Stand-in for 'turn this tuple into a realistic user message' (step 2 of the pipeline)."""
    p, f, s = t
    ask = ASKS[s].format(f=f)
    return rng.choice(templates).format(p=p, p_short=p.split()[0], f=f, s=s, ask=ask[0].upper() + ask[1:])


def tokens(s: str) -> list[str]:
    return re.findall(r"[a-z0-9$#.,']+", s.lower())


def distinct_n(texts: list[str], n: int) -> float:
    grams = [tuple(tk[i:i + n]) for t in texts for tk in [tokens(t)] for i in range(len(tk) - n + 1)]
    return len(set(grams)) / max(1, len(grams))


def jaccard(a: str, b: str, n: int = 3) -> float:
    A = {tuple(tokens(a)[i:i + n]) for i in range(len(tokens(a)) - n + 1)}
    B = {tuple(tokens(b)[i:i + n]) for i in range(len(tokens(b)) - n + 1)}
    return len(A & B) / max(1, len(A | B))


def near_dup_rate(texts: list[str], thr: float = 0.5) -> float:
    """Share of items that have at least one other item with word-3-gram Jaccard >= thr."""
    dup = [any(jaccard(texts[i], texts[j]) >= thr for j in range(len(texts)) if j != i)
           for i in range(len(texts))]
    return sum(dup) / len(texts)


if __name__ == "__main__":
    rng = random.Random(2026)
    raw, valid = tuples()
    print(f"raw tuples {len(raw)}  valid after filter {len(valid)}")
    assert (len(raw), len(valid)) == (64, 54)

    v1 = [mock_llm(t, ONE_TEMPLATE, rng) for t in valid]
    v2 = [mock_llm(t, MANY_TEMPLATES, rng) for t in valid]
    ops = list(EVOLVE_OPS)
    v3 = [EVOLVE_OPS[rng.choice(ops)](q, rng) if rng.random() < 0.6 else q for q in v2]

    print(f"\n{'generator':<34}{'distinct-1':>11}{'distinct-2':>11}{'near-dup':>10}")
    res = {}
    for name, qs in (("one template", v1), ("5 templates", v2), ("5 templates + evolve (60%)", v3)):
        res[name] = (distinct_n(qs, 1), distinct_n(qs, 2), near_dup_rate(qs))
        print(f"{name:<34}{res[name][0]:11.3f}{res[name][1]:11.3f}{res[name][2]:10.2f}")

    print("\nsamples:")
    for q in v3[:4]:
        print("  -", q)
    print("\nslice coverage (scenario counts):",
          {s: sum(t[2] == s for t in valid) for s in SCENARIOS})

    assert res["one template"][2] > 0.9                       # nearly everything is a near-duplicate
    assert res["5 templates + evolve (60%)"][1] > res["one template"][1]
    assert res["5 templates + evolve (60%)"][2] < res["one template"][2]
    print("all checks passed")
