"""Semantic entropy for confabulation detection (Farquhar et al., Nature 2024), with a mock equivalence.

Chapter 9, section 9.12 (Hallucination detection). Sample M answers, cluster them by meaning (the
paper uses bidirectional entailment; here a normaliser + synonym map plays the NLI model), then
SE = -sum_c p(c) ln p(c). Compares SE with naive lexical entropy over exact strings as a detector of
wrong answers, scored by AUROC (Mann-Whitney).
Run:  python3 code/ch09/semantic_entropy.py
Expected key output: clusters {7, 2, 1} -> 0.802 nats; one cluster -> 0; over 300 mock questions,
AUROC of semantic entropy 0.928 vs lexical entropy 0.807 (paraphrases inflate lexical entropy).
"""
from __future__ import annotations

import math
import random
from collections import Counter

SURFACE = {   # meaning -> paraphrases the mock model may produce
    "paris": ["Paris", "paris.", "It is Paris", "Paris, France"],
    "lyon": ["Lyon", "It is Lyon", "lyon."],
    "marseille": ["Marseille", "It is Marseille"],
    "nice": ["Nice", "nice."],
    "lille": ["Lille", "It is Lille"],
    "nantes": ["Nantes"],
}
CANON = {s.lower().rstrip("."): m for m, forms in SURFACE.items() for s in forms}


def meaning(ans: str) -> str:
    """Stand-in for bidirectional entailment: two answers share a cluster iff they map to one meaning."""
    key = ans.lower().rstrip(".")
    return CANON.get(key, CANON.get(key.replace("it is ", ""), key))


def entropy(counts: list[int]) -> float:
    n = sum(counts)
    return 0.0 - sum(c / n * math.log(c / n) for c in counts if c)


def semantic_entropy(samples: list[str]) -> float:
    return entropy(list(Counter(meaning(s) for s in samples).values()))


def lexical_entropy(samples: list[str]) -> float:
    return entropy(list(Counter(samples).values()))


def auroc(scores: list[float], labels: list[int]) -> float:
    """P(score of a positive > score of a negative), ties count 1/2."""
    pos = [s for s, y in zip(scores, labels) if y]
    neg = [s for s, y in zip(scores, labels) if not y]
    wins = sum((p > q) + 0.5 * (p == q) for p in pos for q in neg)
    return wins / (len(pos) * len(neg))


def mock_question(rng: random.Random, m: int = 10) -> tuple[list[str], int]:
    """Return M sampled answers and label 1 if the majority-meaning answer is wrong."""
    truth = "paris"
    knows = rng.random() < 0.6
    wrong = [w for w in SURFACE if w != truth]
    samples = []
    for _ in range(m):
        if knows:
            mean_ = truth if rng.random() < 0.85 else rng.choice(wrong)
        else:                                            # confabulation: scattered meanings
            mean_ = truth if rng.random() < 0.25 else rng.choice(wrong[: rng.randint(2, 5)])
        samples.append(rng.choice(SURFACE[mean_]))
    top = Counter(meaning(s) for s in samples).most_common(1)[0][0]
    return samples, int(top != truth)


if __name__ == "__main__":
    se = entropy([7, 2, 1])
    print(f"clusters {{7, 2, 1}}: SE = -(.7 ln .7 + .2 ln .2 + .1 ln .1) = {se:.3f} nats")
    print(f"one cluster of 10: SE = {entropy([10]):.3f};  ten singletons: SE = ln 10 = {entropy([1] * 10):.3f}")
    demo = ["Paris", "It is Paris", "Paris, France", "paris.", "Paris", "Paris", "It is Paris",
            "Lyon", "It is Lyon", "Nice"]
    print(f"demo samples: semantic entropy {semantic_entropy(demo):.3f} "
          f"vs lexical entropy {lexical_entropy(demo):.3f} (paraphrases look like disagreement)")
    rng = random.Random(11)
    data = [mock_question(rng) for _ in range(300)]
    labels = [y for _, y in data]
    se_scores = [semantic_entropy(s) for s, _ in data]
    lex_scores = [lexical_entropy(s) for s, _ in data]
    a_se, a_lex = auroc(se_scores, labels), auroc(lex_scores, labels)
    print(f"\n300 mock questions, {sum(labels)} with a wrong majority answer")
    print(f"AUROC semantic entropy = {a_se:.3f}   AUROC lexical entropy = {a_lex:.3f}")
    for thr in (0.5, 1.0, 1.3):
        flag = [s > thr for s in se_scores]
        tp = sum(f and y for f, y in zip(flag, labels))
        fp = sum(f and not y for f, y in zip(flag, labels))
        print(f"  flag if SE > {thr:.1f}: flagged {sum(flag):>3}, precision {tp / max(1, tp + fp):.3f}, "
              f"recall {tp / sum(labels):.3f}")
    assert abs(se - 0.802) < 1e-3 and entropy([10]) == 0.0
    assert a_se > a_lex
