"""Training-data-side contamination checks: a 13-gram Janitor-style detector and pure-Python MinHash.

Chapter 3, section 3.10 (#detect-corpus). After EleutherAI lm-evaluation-harness
lm_eval/decontamination/janitor.py (defaults ngram_n=13, window_to_remove=200,
too_dirty_cutoff=10, minimum_slice_length=200) and Yang et al. (2023) on rephrased samples.
Run:  python3 code/ch03/ngram_decontam.py
Expected key output: exact copy overlap 1.00, number-swapped copy partially caught, paraphrase 0.00;
MinHash Jaccard estimate tracks the true Jaccard; the janitor drops a doc holding the whole item
(19 hits >= 10) and cuts a +/-200-char window around a 16-word fragment; LSH banding with b=16, r=8
gives P(candidate | s=0.7) = 0.613 and buckets the copies and the number-swapped text with the item.
"""
from __future__ import annotations

import hashlib
import re
import string

N = 13
TRANS = str.maketrans("", "", string.punctuation)


def normalize(s: str) -> str:
    return re.sub(r"\s+", " ", s.lower().translate(TRANS)).strip()


def ngrams(s: str, n: int = N) -> set[str]:
    w = normalize(s).split()
    return {" ".join(w[i:i + n]) for i in range(len(w) - n + 1)}


def overlap(item: str, corpus_ngrams: set[str], n: int = N) -> float:
    g = ngrams(item, n)
    return len(g & corpus_ngrams) / len(g) if g else 0.0


def janitor_clean(doc: str, dirt: set[str], n: int = N, window: int = 200,
                  too_dirty: int = 10, min_len: int = 200) -> list[str]:
    """Simplified Janitor: remove +/- `window` chars around each matching n-gram, drop the doc after
    `too_dirty` hits, keep only clean chunks longer than `min_len` characters."""
    words = list(re.finditer(r"\S+", doc))
    norm = [normalize(m.group()) for m in words]
    hits = []
    for i in range(len(words) - n + 1):
        if " ".join(norm[i:i + n]) in dirt:
            hits.append((words[i].start(), words[i + n - 1].end()))
    if len(hits) >= too_dirty:
        return []
    chunks, splice = [], 0
    for start, end in hits:
        start, end = max(0, start - window), min(len(doc), end + window)
        if start - splice > min_len:
            chunks.append(doc[splice:start])
        splice = max(splice, end)
    if len(doc) - splice > min_len:
        chunks.append(doc[splice:])
    return chunks if hits else [doc]


def shingles(s: str, k: int = 5) -> set[str]:
    t = normalize(s).replace(" ", "")
    return {t[i:i + k] for i in range(len(t) - k + 1)}


def minhash(sh: set[str], num_perm: int = 128) -> list[int]:
    """One salted 64-bit hash per 'permutation'; keep the minimum over the set."""
    return [min(int.from_bytes(hashlib.blake2b(f"{seed}:{x}".encode(), digest_size=8).digest(), "big")
                for x in sh) for seed in range(num_perm)]


def lsh_candidate_prob(s: float, b: int, r: int) -> float:
    """P(two docs with Jaccard s share at least one of b bands of r MinHash rows) = 1 - (1 - s^r)^b."""
    return 1 - (1 - s**r) ** b


def lsh_buckets(sig: list[int], b: int = 16, r: int = 8) -> set[tuple[int, int]]:
    """Band the signature: each (band index, hash of its r rows) is one bucket key."""
    return {(i, hash(tuple(sig[i * r:(i + 1) * r]))) for i in range(b)}


def jaccard(a: set[str], b: set[str]) -> float:
    return len(a & b) / len(a | b)


ITEM = ("Natalia sold clips to 48 of her friends in April, and then she sold half as many clips in May. "
        "How many clips did Natalia sell altogether in April and May?")
VARIANTS = {
    "exact copy": ITEM,
    "copy, reformatted": ITEM.upper().replace(",", " ,"),
    "numbers swapped": ITEM.replace("48", "52").replace("half as many", "a third as many"),
    "paraphrase": ("In April a girl named Natalia managed to sell hair clips to forty-eight friends; in May her "
                   "sales were cut in half. Across both months, what is the total number of clips she sold?"),
    "unrelated": ("A train leaves the station at 3 pm travelling at 60 miles per hour. How far has it gone by "
                  "5 pm if it never stops along the way?"),
}

if __name__ == "__main__":
    print(f"eval item has {len(ngrams(ITEM))} distinct {N}-grams\n")
    print(f"{'training text':<20}{f'{N}-gram overlap':>16}{'flag@0.5':>9}{'char-5 Jaccard':>15}{'MinHash est.':>13}")
    mh_item = minhash(shingles(ITEM))
    res = {}
    for name, text in VARIANTS.items():
        ov = overlap(ITEM, ngrams(text))
        j = jaccard(shingles(ITEM), shingles(text))
        mh = minhash(shingles(text))
        est = sum(a == b for a, b in zip(mh_item, mh)) / len(mh)
        res[name] = (ov, j, est)
        print(f"{name:<20}{ov:16.2f}{'yes' if ov >= 0.5 else 'no':>9}{j:15.2f}{est:13.2f}")

    # Janitor on a 'web page' that embeds the item between unrelated boilerplate.
    pre = "Welcome to our homework help forum. " * 12
    post = " Reply from tutor: try drawing a table of the two months first. " * 8
    print()
    jan: dict[str, list[str]] = {}
    fragment = " ".join(ITEM.split()[:16])          # a quoted fragment: 16 words -> 4 dirty 13-grams
    for label, leak in (("full item", ITEM), ("16-word fragment", fragment)):
        doc = pre + leak + post
        chunks = janitor_clean(doc, ngrams(ITEM))
        print(f"janitor, doc with {label:<17}: {len(doc):5d} chars -> {len(chunks)} chunks, "
              f"{sum(len(c) for c in chunks):4d} chars kept, leak still present: {leak in ''.join(chunks)}")
        jan[label] = chunks
    print()

    assert res["exact copy"][0] == 1.0 and res["copy, reformatted"][0] == 1.0
    assert 0.0 < res["numbers swapped"][0] < 0.5       # partially caught: below the threshold
    assert res["paraphrase"][0] == 0.0                  # the rephrased leak is invisible to n-grams
    assert res["numbers swapped"][2] > 0.6 > res["paraphrase"][2]  # MinHash catches the near-copy
    assert all(abs(r[1] - r[2]) < 0.1 for r in res.values())       # estimator tracks true Jaccard
    print("LSH banding, b=16 bands x r=8 rows (m=128): candidate probability P(s) = 1 - (1 - s^r)^b")
    print("  " + "  ".join(f"P({x:.1f})={lsh_candidate_prob(x, 16, 8):.3f}" for x in (0.5, 0.7, 0.8, 0.9))
          + f"   threshold (1/b)^(1/r) = {(1 / 16) ** (1 / 8):.3f}")
    item_keys = lsh_buckets(mh_item)
    collide = {name: bool(item_keys & lsh_buckets(minhash(shingles(t)))) for name, t in VARIANTS.items()}
    print("  shares a bucket with the eval item:", ", ".join(f"{k}={v}" for k, v in collide.items()))
    print()
    assert abs(lsh_candidate_prob(0.7, 16, 8) - 0.613) < 0.01
    assert collide["exact copy"] and collide["copy, reformatted"] and collide["numbers swapped"]
    assert not collide["unrelated"] and not collide["paraphrase"]

    assert jan["full item"] == []                        # 19 hits >= too_dirty_cutoff: drop the doc
    assert len(jan["16-word fragment"]) == 2 and fragment not in "".join(jan["16-word fragment"])
    print("all checks passed")
