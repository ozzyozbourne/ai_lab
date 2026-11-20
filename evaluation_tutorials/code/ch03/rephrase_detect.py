"""Rephrase detection, the last stage of the layered decontamination recipe: retrieve, then judge.

Chapter 3, section 3.10 (#detect-rephrase). After Yang et al. (2023), "Rethinking Benchmark and
Contamination for Language Models with Rephrased Samples" (lm-sys/llm-decontaminator): for each test
item, retrieve the top-k most similar training texts, then ask a strong LLM "is this a rephrasing?".
Here retrieval is TF-IDF cosine (stand-in for an embedding model) and the judge is a DETERMINISTIC
MOCK that compares normalised key quantities and named entities (stand-in for the strong-LLM judge).
Run:  python3 code/ch03/rephrase_detect.py
Expected key output: among texts not already caught by n-grams/MinHash, the paraphrase is retrieved
at rank 1; the mock judge confirms it and rejects the unrelated problem; several distractors pass a
low cosine threshold (0.1), which is the precision cost the judge removes.
"""
from __future__ import annotations

import re

import numpy as np

from ngram_decontam import ITEM, VARIANTS

STOP = set("a an the and of to in on at for by her his she he it is was were did does do how what many "
           "much then as if its their there this that with from has have had be been are or so".split())
NUM_WORDS = {"two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "ten": 10, "twelve": 12, "twenty": 20,
             "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "eight": 8, "nine": 9, "seven": 7}
FRACTIONS = {"half": "1/2", "third": "1/3", "quarter": "1/4", "double": "2", "twice": "2"}

# Distractor training documents: some share vocabulary with the eval item (sales, months, clips,
# friends, even the name Natalia) but describe different problems.
DISTRACTORS = [
    "Natalia baked 30 cookies on Monday and gave a quarter of them to her neighbours. How many are left?",
    "A shop sold 120 hair clips in April and 80 in May. What was the total number of clips sold?",
    "Tom gave stickers to 12 of his friends in June and twice as many in July. How many friends got stickers?",
    "In May a farmer sold 45 eggs at the market and in June he sold 60. How many eggs did he sell in total?",
    "Maria has 3 boxes with 14 pencils each. She sells 9 pencils. How many pencils does she have now?",
    "A bakery sells bread for 2 dollars a loaf. On Friday it sold 75 loaves. How much money did it make?",
    "Liam read 20 pages on Saturday and half as many on Sunday. How many pages did he read altogether?",
    "The recipe needs 3 cups of flour for 12 muffins. How much flour is needed for 36 muffins?",
    "A cyclist rides 15 kilometres every morning. How far does she ride in a week of mornings?",
    "Write a short poem about the sea at night, with the moon reflected on the waves.",
    "Install the package with pip, then run the tests with pytest from the repository root.",
    "The museum opens at 9 am and closes at 5 pm every day except Monday.",
]


def tokens(s: str) -> list[str]:
    return [w for w in re.findall(r"[a-z]+|\d+", s.lower()) if w not in STOP]


def tfidf(docs: list[str]) -> np.ndarray:
    vocab = sorted({w for d in docs for w in tokens(d)})
    idx = {w: i for i, w in enumerate(vocab)}
    X = np.zeros((len(docs), len(vocab)))
    for r, d in enumerate(docs):
        for w in tokens(d):
            X[r, idx[w]] += 1
    df = (X > 0).sum(0)
    X = np.log1p(X) * (np.log((1 + len(docs)) / (1 + df)) + 1)
    return X / np.linalg.norm(X, axis=1, keepdims=True)


def key_facts(s: str) -> tuple[frozenset, frozenset]:
    """Mock judge features: quantities (digits, number words, fractions) and capitalised names."""
    low = s.lower().replace("-", " ")
    q = {int(x) for x in re.findall(r"\d+", low)}
    words = re.findall(r"[a-z]+", low)
    i = 0
    while i < len(words):                               # "forty eight" -> 48
        w = words[i]
        if w in NUM_WORDS:
            nxt = NUM_WORDS.get(words[i + 1], 0) if i + 1 < len(words) else 0
            compound = NUM_WORDS[w] >= 20 and 0 < nxt < 10
            q.add(NUM_WORDS[w] + (nxt if compound else 0))
            i += compound
        i += 1
    q |= {FRACTIONS[w] for w in words if w in FRACTIONS}
    names = {w for w in re.findall(r"\b[A-Z][a-z]+\b", s)} - {"In", "How", "What", "Across", "A", "The",
                                                                "April", "May", "June", "July"}
    return frozenset(q), frozenset(names)


def mock_judge(test: str, train: str) -> bool:
    """STAND-IN for the strong-LLM judge of Yang et al.: same named entities and the same key quantities
    (every quantity of the test item appears in the candidate) => 'rephrasing'."""
    (qt, nt), (qc, nc) = key_facts(test), key_facts(train)
    return nt == nc and qt <= qc


if __name__ == "__main__":
    # Stages 1-2 (13-grams, MinHash) already flag the copies and the number-swapped near-copy, so stage 3
    # only has to search what is left.
    left = {k: v for k, v in VARIANTS.items() if k in ("paraphrase", "unrelated")}
    names = list(left) + [f"distractor {i:02d}" for i in range(len(DISTRACTORS))]
    texts = list(left.values()) + DISTRACTORS
    X = tfidf([ITEM] + texts)
    cos = X[1:] @ X[0]
    order = np.argsort(-cos)
    print(f"stage 3 searches {len(texts)} training texts not caught by n-gram/MinHash stages")
    print(f"\n{'rank':>4}  {'training text':<15}{'cosine':>7}  judge")
    verdict = {}
    for rank, i in enumerate(order[:5], 1):
        verdict[names[i]] = mock_judge(ITEM, texts[i])
        print(f"{rank:4d}  {names[i]:<15}{cos[i]:7.3f}  {'REPHRASE' if verdict[names[i]] else 'different'}")
    k_unrel = names.index("unrelated")
    print(f"   .. unrelated       {cos[k_unrel]:7.3f}  "
          f"{'REPHRASE' if mock_judge(ITEM, texts[k_unrel]) else 'different'}")

    thr = 0.1
    passing = [n for n, c in zip(names, cos) if c >= thr and n.startswith("distractor")]
    judged = [n for n in passing if mock_judge(ITEM, texts[names.index(n)])]
    print(f"\ndistractors with cosine >= {thr}: {len(passing)} of {len(DISTRACTORS)} "
          f"-> after the judge: {len(judged)} false positives")
    print("key facts of eval item:", sorted(map(str, key_facts(ITEM)[0])), sorted(key_facts(ITEM)[1]))
    print("key facts of paraphrase:", sorted(map(str, key_facts(left['paraphrase'])[0])),
          sorted(key_facts(left["paraphrase"])[1]))

    assert names[order[0]] == "paraphrase"              # retrieved at rank 1
    assert mock_judge(ITEM, left["paraphrase"])         # and confirmed by the judge
    assert not mock_judge(ITEM, left["unrelated"])
    assert len(passing) >= 3 and judged == []           # cosine alone has a precision cost; the judge removes it
    print("\nall checks passed")
