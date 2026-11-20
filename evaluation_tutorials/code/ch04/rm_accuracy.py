"""Pairwise accuracy vs best-of-4 accuracy for reward models and judges (Chapter 4.8, #meta-eval).

Each of 2,000 prompts has one correct response and three incorrect ones. A mock reward model
scores r = w_q * quality + w_s * style + noise, where "style" is length / markdown polish
that has nothing to do with correctness.
  * pairwise accuracy (RewardBench v1 style): r(chosen) > r(one rejected); chance 50%
  * best-of-4 accuracy (the RewardBench 2 format, partially verified): r(correct) beats all
    three incorrect responses; chance 25%
  * style-hard pairs (RM-Bench idea): the chosen answer is plain, the rejected one is polished

Run: python3 code/ch04/rm_accuracy.py
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class MockRM:
    name: str
    w_quality: float
    w_style: float
    noise: float

    def score(self, quality, style, rng):
        return self.w_quality * quality + self.w_style * style + rng.normal(0, self.noise, np.shape(quality))


def make_data(n: int, rng):
    q_correct = rng.normal(1.0, 0.5, n)
    q_wrong = rng.normal(0.0, 0.5, (n, 3))
    s_correct = rng.normal(0, 1, n)
    s_wrong = rng.normal(0, 1, (n, 3))
    return q_correct, q_wrong, s_correct, s_wrong


def evaluate(rm: MockRM, data, rng) -> dict:
    qc, qw, sc, sw = data
    rc, rw = rm.score(qc, sc, rng), rm.score(qw, sw, rng)
    pairwise = np.mean(rc > rw[:, 0])
    best_of_4 = np.mean(rc > rw.max(1))
    # style-hard: chosen is plain (style -1.5), rejected is polished (style +1.5)
    rc_h = rm.score(qc, np.full_like(qc, -1.5), rng)
    rw_h = rm.score(qw[:, 0], np.full_like(qc, 1.5), rng)
    return {"pairwise": pairwise, "best-of-4": best_of_4, "style-hard pairwise": np.mean(rc_h > rw_h)}


def main() -> None:
    rng = np.random.default_rng(9)
    data = make_data(2000, rng)
    rms = [MockRM("random RM", 0.0, 0.0, 1.0), MockRM("substance RM", 1.0, 0.1, 0.5),
           MockRM("style-biased RM", 1.0, 0.6, 0.5)]
    print(f"{'reward model':<18}{'pairwise':>10}{'best-of-4':>11}{'style-hard pairwise':>21}")
    res = {}
    for rm in rms:
        r = evaluate(rm, data, rng)
        res[rm.name] = r
        print(f"{rm.name:<18}{r['pairwise']:>10.3f}{r['best-of-4']:>11.3f}{r['style-hard pairwise']:>21.3f}")
    rnd = res["random RM"]
    assert abs(rnd["pairwise"] - 0.5) < 0.04 and abs(rnd["best-of-4"] - 0.25) < 0.04
    sub, sty = res["substance RM"], res["style-biased RM"]
    assert sub["best-of-4"] < sub["pairwise"] - 0.1
    assert sty["style-hard pairwise"] < sub["style-hard pairwise"] - 0.2
    # If the four errors were independent, best-of-4 ~ pairwise^3 (a useful rule of thumb)
    print(f"\nRule of thumb: pairwise^3 = {sub['pairwise'] ** 3:.3f} vs measured best-of-4 {sub['best-of-4']:.3f}"
          " (comparisons share the correct answer's score, so they are positively correlated)")


if __name__ == "__main__":
    main()
