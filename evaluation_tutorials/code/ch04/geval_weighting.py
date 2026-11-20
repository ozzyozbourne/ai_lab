"""G-Eval probability-weighted scores vs greedy scores (Chapter 4.4, #anatomy).

G-Eval (Liu et al., 2023) replaces the single sampled score with the expectation
sum_i p(s_i) * s_i over the judge's token probabilities for the score tokens "1".."5".
Part 1 reproduces the worked example (expected score 3.65 vs greedy 4).
Part 2 simulates 300 summaries with a hidden continuous quality in [1, 5]. A mock judge
produces a softmax distribution over 1..5 centred near the true quality (plus noise).
We compare greedy (argmax) scores with expected scores on ties and Spearman rho.

Run: python3 code/ch04/geval_weighting.py
"""
from __future__ import annotations

import numpy as np

SCORES = np.arange(1, 6)


def expected_score(probs: np.ndarray) -> float:
    probs = np.asarray(probs, float)
    return float((probs / probs.sum()) @ SCORES)


def mock_judge_probs(true_quality: float, rng: np.random.Generator, sharpness: float = 1.5,
                     noise: float = 0.5) -> np.ndarray:
    """Logprob-like distribution over scores 1..5 for one item."""
    centre = true_quality + rng.normal(0, noise)
    logits = -sharpness * (SCORES - centre) ** 2
    p = np.exp(logits - logits.max())
    return p / p.sum()


def rank(x: np.ndarray) -> np.ndarray:
    order = x.argsort(kind="stable")
    r = np.empty(len(x))
    r[order] = np.arange(len(x))
    for v in np.unique(x):
        r[x == v] = r[x == v].mean()
    return r


def spearman(a, b) -> float:
    return float(np.corrcoef(rank(np.asarray(a, float)), rank(np.asarray(b, float)))[0, 1])


def main() -> None:
    p = np.array([0.05, 0.10, 0.20, 0.45, 0.20])
    e = expected_score(p)
    print(f"Worked example: p(1..5) = {p.tolist()}")
    print(f"  greedy score = {SCORES[p.argmax()]}   expected score = {e:.2f}")
    assert abs(e - 3.65) < 1e-9 and SCORES[p.argmax()] == 4

    rng = np.random.default_rng(11)
    truth = rng.uniform(1, 5, size=300)
    probs = np.array([mock_judge_probs(t, rng) for t in truth])
    greedy = SCORES[probs.argmax(1)].astype(float)
    sampled = np.array([rng.choice(SCORES, p=q) for q in probs], float)
    expected = probs @ SCORES

    print("\n300 items with hidden continuous quality; mock judge with logprobs")
    print(f"{'scoring rule':<26}{'distinct values':>16}{'Spearman vs truth':>20}")
    for name, s in (("sampled (T=1) integer", sampled), ("greedy integer", greedy), ("probability-weighted", expected)):
        print(f"{name:<26}{len(np.unique(np.round(s, 6))):>16}{spearman(s, truth):>20.3f}")
    assert spearman(expected, truth) > spearman(greedy, truth) > spearman(sampled, truth)

    # Ties matter when comparing two systems: fraction of item pairs the rule cannot order
    i, j = np.triu_indices(len(truth), 1)
    tie_g = np.mean(greedy[i] == greedy[j])
    tie_e = np.mean(np.isclose(expected[i], expected[j]))
    print(f"\nFraction of item pairs tied: greedy {tie_g:.3f}, probability-weighted {tie_e:.3f}")


if __name__ == "__main__":
    main()
