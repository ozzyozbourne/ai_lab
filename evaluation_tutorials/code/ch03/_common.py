"""Shared helpers for Chapter 3 contamination demos: a mock benchmark and a count-based bigram LM.

Not run directly by code/run_all.py (leading underscore).
"""
from __future__ import annotations

import math
import random
from collections import Counter, defaultdict

import numpy as np

SUBJECTS = ["the farmer", "a student", "the baker", "my uncle", "the robot", "a sailor", "the teacher",
            "our neighbour", "the pilot", "a child", "the doctor", "the miner"]
VERBS = ["bought", "found", "sold", "packed", "counted", "painted", "carried", "lost", "shared", "stacked"]
OBJECTS = ["apples", "boxes", "coins", "shells", "pencils", "stones", "tickets", "cards", "jars", "bricks"]
TAILS = ["before lunch", "at the market", "in the morning", "near the river", "after school",
         "on monday", "with a friend", "in the barn", "at the station", "during the storm"]
# A newer-looking vocabulary for the distribution-shifted non-member set (e.g. text from after a cutoff).
NEW_SUBJECTS = ["the influencer", "a drone pilot", "the streamer", "an ai agent", "the gig driver"]
NEW_OBJECTS = ["gpus", "tokens", "e-scooters", "nfts", "subscriptions"]
NEW_TAILS = ["on the livestream", "via the app", "during the outage", "in the metaverse", "after the update"]


def make_item(rng: random.Random, shifted: bool = False) -> list[str]:
    s = rng.choice(NEW_SUBJECTS if shifted else SUBJECTS)
    o = rng.choice(NEW_OBJECTS if shifted else OBJECTS)
    t = rng.choice(NEW_TAILS if shifted else TAILS)
    a, b = rng.randint(2, 60), rng.randint(2, 9)
    words = (f"{s} {rng.choice(VERBS)} {a} {o} {t} and then {rng.choice(VERBS)} {b} more {o} . "
             f"how many {o} are there now ?").split()
    if shifted:  # newer text in this toy is also wordier
        words = words[:-4] + "so tell me exactly how many".split() + words[-3:]
    return words


class BigramLM:
    """Add-k smoothed bigram model over words. `logprobs(seq)` returns log p(w_t | w_{t-1})."""

    def __init__(self, sentences: list[list[str]], k: float = 0.1):
        self.k = k
        self.uni: Counter[str] = Counter()
        self.bi: dict[str, Counter[str]] = defaultdict(Counter)
        for s in sentences:
            toks = ["<s>"] + s
            self.uni.update(toks)
            for a, b in zip(toks, toks[1:]):
                self.bi[a][b] += 1
        self.vocab = sorted(set(self.uni) | {"<unk>"})
        self.V = len(self.vocab)
        self.tot = {a: sum(c.values()) for a, c in self.bi.items()}

    def p(self, prev: str, w: str) -> float:
        c = self.bi.get(prev)
        if c is None:
            return 1.0 / self.V
        return (c.get(w, 0) + self.k) / (self.tot[prev] + self.k * self.V)

    def logprobs(self, seq: list[str], start: str = "<s>") -> np.ndarray:
        toks = [start] + seq
        return np.array([math.log(self.p(a, b)) for a, b in zip(toks, toks[1:])])

    def next_dist_stats(self, prev: str) -> tuple[float, float]:
        """Mean and std of log p(z | prev) for z ~ p(. | prev): the Min-K%++ normaliser."""
        c = self.bi.get(prev, Counter())
        tot = sum(c.values()) + self.k * self.V
        seen = np.array([(n + self.k) / tot for n in c.values()])
        n_unseen = self.V - len(seen)
        p_unseen = self.k / tot
        probs = np.concatenate([seen, np.full(1, p_unseen)])
        weights = np.concatenate([seen, np.full(1, p_unseen * n_unseen)])  # mass per group
        logs = np.log(probs)
        mu = float(np.sum(weights * logs))
        var = float(np.sum(weights * (logs - mu) ** 2))
        return mu, math.sqrt(max(var, 1e-12))


def auroc(pos: np.ndarray, neg: np.ndarray) -> float:
    """Rank-based AUROC = P(score of a random member > score of a random non-member); ties count 1/2."""
    pos, neg = np.asarray(pos)[:, None], np.asarray(neg)[None, :]
    return float(np.mean((pos > neg) + 0.5 * (pos == neg)))
