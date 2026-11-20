"""Measuring judge biases with a mock pairwise judge (Chapter 4.6, #biases; Figure 4.3).

MockJudge(position_bias, length_bias, self_pref, noise) prefers answer A when
    (q_A - q_B) + position_bias + length_bias*(len_A - len_B) + self_pref*(self_A - self_B) + noise
exceeds a tie margin, where q is a hidden true quality. We run four probes on a "weak" and a
"strong" judge:
  1. position:  judge every pair in both orders; swap consistency and "biased toward first"
  2. verbosity: repetitive-list attack, the same answer padded with 120 tokens of rephrased items
  3. self-preference: equal-quality pairs where one answer comes from the judge's own family
  4. swap-and-aggregate: accuracy against the hidden truth, single order vs both orders
     with inconsistency counted as a tie (the FastChat rule)

Run: python3 code/ch04/mock_judge_biases.py
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class Answer:
    quality: float
    length: int
    by_judge_family: bool = False


@dataclass
class MockJudge:
    position_bias: float
    length_bias: float
    self_pref: float
    noise: float
    tie_margin: float = 0.15
    seed: int = 0

    def __post_init__(self):
        self.rng = np.random.default_rng(self.seed)

    def compare(self, a: Answer, b: Answer) -> str:
        z = (a.quality - b.quality) + self.position_bias + self.length_bias * (a.length - b.length) \
            + self.self_pref * (a.by_judge_family - b.by_judge_family) + self.rng.normal(0, self.noise)
        return "tie" if abs(z) < self.tie_margin else ("A" if z > 0 else "B")


def both_orders(judge: MockJudge, x: Answer, y: Answer) -> tuple[str, str]:
    """Return verdicts in terms of x/y for order (x,y) and order (y,x)."""
    g1 = {"A": "x", "B": "y", "tie": "tie"}[judge.compare(x, y)]
    g2 = {"A": "y", "B": "x", "tie": "tie"}[judge.compare(y, x)]
    return g1, g2


def swap_aggregate(g1: str, g2: str) -> str:
    return g1 if g1 == g2 else "tie"   # FastChat: inconsistent -> tie


def random_answer(rng) -> Answer:
    return Answer(float(rng.normal(0, 1)), int(rng.normal(250, 60)))


def probe(judge: MockJudge, rng: np.random.Generator, n: int = 2000) -> dict:
    res = {}
    # 1. Position bias and 4. swap-and-aggregate, on random pairs
    consistent = first = 0
    single_correct = agg_decided = agg_correct = 0
    by_gap = {"|dq|<0.5": [0, 0], "0.5-1.5": [0, 0], ">1.5": [0, 0]}
    for _ in range(n):
        x, y = random_answer(rng), random_answer(rng)
        g1, g2 = both_orders(judge, x, y)
        truth = "x" if x.quality > y.quality else "y"
        ok = g1 == g2
        consistent += ok
        if not ok and g1 == "x" and g2 == "y":     # picked whichever was shown first, both times
            first += 1
        gap = abs(x.quality - y.quality)
        key = "|dq|<0.5" if gap < 0.5 else ("0.5-1.5" if gap < 1.5 else ">1.5")
        by_gap[key][0] += ok
        by_gap[key][1] += 1
        single_correct += g1 == truth
        agg = swap_aggregate(g1, g2)
        if agg != "tie":
            agg_decided += 1
            agg_correct += agg == truth
    res["swap consistency"] = consistent / n
    res["biased toward first"] = first / n
    res["consistency by gap"] = {k: v[0] / v[1] for k, v in by_gap.items()}
    res["single-order accuracy"] = single_correct / n
    res["swap-agg coverage"] = agg_decided / n
    res["swap-agg accuracy (decided)"] = agg_correct / agg_decided

    # Control: an answer against an identical copy (what "no bias" looks like for probes 2 and 3)
    wins = 0
    for _ in range(n // 2):
        base = random_answer(rng)
        wins += sum(v == "x" for v in both_orders(judge, base, Answer(base.quality, base.length)))
    res["identical copy wins (control)"] = wins / n

    # 2. Repetitive-list attack: same content, +120 tokens of rephrased list items
    wins = 0
    for _ in range(n // 2):
        base = random_answer(rng)
        padded = Answer(base.quality, base.length + 120)
        wins += sum(v == "x" for v in both_orders(judge, padded, base))
    res["padded answer wins"] = wins / n

    # 3. Self-preference: equal quality, one from the judge's own model family
    wins = 0
    for _ in range(n // 2):
        q, L = float(rng.normal()), int(rng.normal(250, 60))
        own, other = Answer(q, L, True), Answer(q, L, False)
        wins += sum(v == "x" for v in both_orders(judge, own, other))
    res["own-family answer wins"] = wins / n
    return res


def main() -> None:
    judges = {"weak judge": MockJudge(position_bias=0.9, length_bias=0.008, self_pref=0.5, noise=0.6, seed=1),
              "strong judge": MockJudge(position_bias=0.25, length_bias=0.001, self_pref=0.15, noise=0.3, seed=2)}
    results = {name: probe(j, np.random.default_rng(42)) for name, j in judges.items()}
    keys = ["swap consistency", "biased toward first", "identical copy wins (control)", "padded answer wins", "own-family answer wins",
            "single-order accuracy", "swap-agg coverage", "swap-agg accuracy (decided)"]
    print(f"{'probe':<32}" + "".join(f"{n:>15}" for n in results))
    for k in keys:
        print(f"{k:<32}" + "".join(f"{r[k]:>15.3f}" for r in results.values()))
    print("\nSwap consistency by true quality gap (position bias bites hardest on close pairs)")
    for g in ("|dq|<0.5", "0.5-1.5", ">1.5"):
        print(f"  {g:<12}" + "".join(f"{r['consistency by gap'][g]:>15.3f}" for r in results.values()))
    w, s = results["weak judge"], results["strong judge"]
    assert w["swap consistency"] < s["swap consistency"]
    assert w["padded answer wins"] > 0.6 and s["padded answer wins"] < 0.5
    assert w["padded answer wins"] > w["identical copy wins (control)"] + 0.2
    assert w["own-family answer wins"] > s["own-family answer wins"] > 0.25
    for r in results.values():
        assert r["swap-agg accuracy (decided)"] > r["single-order accuracy"]
        assert r["consistency by gap"]["|dq|<0.5"] < r["consistency by gap"][">1.5"]


if __name__ == "__main__":
    main()
