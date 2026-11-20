"""Contamination in miniature: a memoriser mock model that aces leaked items, an n-gram overlap
detector that catches verbatim copies but misses paraphrases (after Yang et al. 2023), and a
fresh 'twin' set that exposes the gap (after GSM1k), plus label noise as an accuracy ceiling.

Chapter 2, section 2.11 (#breakage).
Run:  python3 code/ch02/contamination_demo.py
Expected key output: the detector flags the verbatim leaks and none of the paraphrased leaks;
the memoriser's score on the fresh twin set drops sharply; with 6.49% wrong labels a perfect
model scores about 93.5%.
"""
from __future__ import annotations

import random

NAMES = ["Ava", "Ben", "Chen", "Dina", "Eli", "Fatima", "Goran", "Hana", "Ivan", "Jade"]
ITEMS = ["apples", "marbles", "stickers", "books", "pencils", "shells", "coins", "cards"]


def make_item(rng: random.Random) -> tuple[str, int]:
    name, thing = rng.choice(NAMES), rng.choice(ITEMS)
    a, b, c = rng.randint(3, 40), rng.randint(2, 9), rng.randint(1, 20)
    q = (f"{name} has {a} {thing}. {name} buys {b} more bags with {c} {thing} in each bag. "
         f"How many {thing} does {name} have now?")
    return q, a + b * c


def paraphrase(q: str) -> str:
    """A meaning-preserving rewrite with almost no shared 13-grams."""
    words = q.replace("?", "").replace(".", "").split()
    name, a, thing, b, c = words[0], words[2], words[3], words[6], words[10]
    return (f"Start with {a} {thing} owned by {name}; add {b} bags, every bag holding {c}. "
            f"What is the new total of {thing}?")


def ngrams(text: str, n: int = 13) -> set[tuple[str, ...]]:
    t = text.lower().replace("?", " ").replace(".", " ").split()
    return {tuple(t[i:i + n]) for i in range(len(t) - n + 1)}


def flagged(test_q: str, corpus_index: set, n: int = 13, threshold: float = 0.5) -> bool:
    g = ngrams(test_q, n)
    return bool(g) and len(g & corpus_index) / len(g) >= threshold


class Memoriser:
    """Answers perfectly anything it has seen (verbatim or paraphrased), else is right 35% of the time."""

    def __init__(self, seen_answers: dict[str, int], rng: random.Random):
        self.seen, self.rng = seen_answers, rng

    def answer(self, q: str, true: int) -> int:
        if q in self.seen:
            return self.seen[q]
        return true if self.rng.random() < 0.35 else true + 1


if __name__ == "__main__":
    rng = random.Random(3)
    test = [make_item(rng) for _ in range(200)]
    fresh = [make_item(rng) for _ in range(200)]           # matched twin set, never published
    verbatim_leaks = test[:40]
    para_leaks = test[40:80]
    # pre-training corpus: verbatim copies of 40 items, paraphrases of 40 more, plus unrelated text
    corpus = [q for q, _ in verbatim_leaks] + [paraphrase(q) for q, _ in para_leaks]
    filler = random.Random(9)
    corpus += [" ".join(filler.choice(NAMES + ITEMS + ["the", "has", "bags", "more", "in", "each"])
                        for _ in range(40)) for _ in range(300)]            # unrelated web text
    index = set().union(*(ngrams(doc) for doc in corpus))

    caught_v = sum(flagged(q, index) for q, _ in verbatim_leaks)
    caught_p = sum(flagged(q, index) for q, _ in para_leaks)
    false_pos = sum(flagged(q, index) for q, _ in test[80:])
    print("== 13-gram overlap detector (flag if >= 50% of a test item's 13-grams are in the corpus) ==")
    print(f"verbatim leaks flagged    {caught_v}/40")
    print(f"paraphrased leaks flagged {caught_p}/40")
    print(f"clean items flagged       {false_pos}/120")
    assert caught_v == 40 and caught_p == 0 and false_pos <= 2

    # the model 'learned' the answers of every leaked item, verbatim or paraphrased
    seen = {q: a for q, a in verbatim_leaks + para_leaks}
    model = Memoriser(seen, random.Random(4))
    acc_test = sum(model.answer(q, a) == a for q, a in test) / len(test)
    clean_ids = [i for i, (q, _) in enumerate(test) if not flagged(q, index)]
    acc_decon = sum(model.answer(test[i][0], test[i][1]) == test[i][1] for i in clean_ids) / len(clean_ids)
    acc_fresh = sum(model.answer(q, a) == a for q, a in fresh) / len(fresh)
    print("\n== Memoriser scores ==")
    print(f"public test set               {acc_test:.3f}")
    print(f"after n-gram decontamination  {acc_decon:.3f}   ({len(clean_ids)} items kept; paraphrased leaks survive)")
    print(f"fresh twin set                {acc_fresh:.3f}")
    assert acc_test - acc_fresh > 0.2 and acc_decon > acc_fresh

    print("\n== Label noise sets a ceiling ==")
    n, err_rate = 10_000, 0.0649
    wrong = set(random.Random(5).sample(range(n), round(n * err_rate)))
    perfect = sum(i not in wrong for i in range(n)) / n
    print(f"{err_rate:.2%} of gold labels wrong -> a model that is always right scores {perfect:.3f}")
    assert abs(perfect - (1 - err_rate)) < 1e-3
