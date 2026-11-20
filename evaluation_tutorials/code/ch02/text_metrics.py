"""Scoring generated text by hand: SQuAD EM/F1, BLEU, ROUGE-1/ROUGE-L, a toy BERTScore, and
IFEval-style prompt-level vs instruction-level accuracy (strict and loose).

Chapter 2, section 2.3 (#text-metrics).
Run:  python3 code/ch02/text_metrics.py
Expected key output: F1 = 0.667 (EM = 0); sentence BLEU = 0.000 but ROUGE-L F1 = 0.769 for the
same pair; BLEU = 0.595 for a near-copy; toy BERTScore rewards "sat" vs "sitting";
IFEval mock: prompt-level strict 1/3, instruction-level strict 3/6, loose 2/3 and 4/6.
"""
from __future__ import annotations

import math
import re
import string
from collections import Counter

import numpy as np


# ---------- SQuAD-style normalisation, EM and token F1 (same steps as HF evaluate's squad metric) ----------
def normalize_answer(s: str) -> str:
    s = s.lower()
    s = "".join(ch for ch in s if ch not in set(string.punctuation))
    s = re.sub(r"\b(a|an|the)\b", " ", s)
    return " ".join(s.split())


def exact_match(pred: str, gold: str) -> float:
    return float(normalize_answer(pred) == normalize_answer(gold))


def token_f1(pred: str, gold: str) -> float:
    p, g = normalize_answer(pred).split(), normalize_answer(gold).split()
    common = Counter(p) & Counter(g)          # multiset intersection
    same = sum(common.values())
    if same == 0:
        return 0.0
    precision, recall = same / len(p), same / len(g)
    return 2 * precision * recall / (precision + recall)


# ---------- BLEU (Papineni et al. 2002) ----------
def ngrams(tokens: list[str], n: int) -> Counter:
    return Counter(tuple(tokens[i:i + n]) for i in range(len(tokens) - n + 1))


def clipped_counts(cand: list[str], ref: list[str], n: int) -> tuple[int, int]:
    c, r = ngrams(cand, n), ngrams(ref, n)
    matched = sum(min(cnt, r[g]) for g, cnt in c.items())   # clipping
    return matched, max(sum(c.values()), 0)


def bleu(pairs: list[tuple[str, str]], max_n: int = 4, smooth: bool = False) -> tuple[float, list[float], float]:
    """Corpus BLEU over (candidate, reference) pairs; one pair = sentence BLEU.
    smooth=True adds one to numerator and denominator for n > 1 (a simple add-one smoothing)."""
    match = [0] * max_n
    total = [0] * max_n
    c_len = r_len = 0
    for cand, ref in pairs:
        ct, rt = cand.split(), ref.split()
        c_len, r_len = c_len + len(ct), r_len + len(rt)
        for n in range(1, max_n + 1):
            m, t = clipped_counts(ct, rt, n)
            match[n - 1] += m
            total[n - 1] += t
    precisions = []
    for n in range(max_n):
        m, t = match[n], total[n]
        if smooth and n > 0:
            m, t = m + 1, t + 1
        precisions.append(m / t if t else 0.0)
    bp = 1.0 if c_len > r_len else math.exp(1 - r_len / c_len)
    if min(precisions) == 0:
        return 0.0, precisions, bp
    return bp * math.exp(sum(math.log(p) for p in precisions) / max_n), precisions, bp


# ---------- ROUGE (Lin 2004) ----------
def rouge_n(cand: str, ref: str, n: int = 1) -> tuple[float, float, float]:
    m, t_c = clipped_counts(cand.split(), ref.split(), n)
    t_r = sum(ngrams(ref.split(), n).values())
    p, r = m / t_c, m / t_r
    return p, r, (2 * p * r / (p + r) if p + r else 0.0)


def lcs_len(a: list[str], b: list[str]) -> int:
    dp = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i, x in enumerate(a, 1):
        for j, y in enumerate(b, 1):
            dp[i][j] = dp[i - 1][j - 1] + 1 if x == y else max(dp[i - 1][j], dp[i][j - 1])
    return dp[-1][-1]


def rouge_l(cand: str, ref: str) -> tuple[int, float, float, float]:
    c, r = cand.split(), ref.split()
    lcs = lcs_len(c, r)
    p, rec = lcs / len(c), lcs / len(r)
    return lcs, p, rec, 2 * p * rec / (p + rec)


# ---------- Toy BERTScore: greedy cosine matching over hand-made embeddings ----------
def toy_embeddings() -> dict[str, np.ndarray]:
    rng = np.random.default_rng(0)
    vocab = ["the", "cat", "is", "sitting", "sat", "on", "mat", "dog", "ran", "rug"]
    emb = {w: rng.normal(size=16) for w in vocab}
    # make "sitting" a near-synonym of "sat" (cosine 0.9) and "rug" close to "mat"
    def blend(base: np.ndarray, cos: float, seed: int) -> np.ndarray:
        u = base / np.linalg.norm(base)
        v = np.random.default_rng(seed).normal(size=16)
        v -= v.dot(u) * u
        v /= np.linalg.norm(v)
        return cos * u + math.sqrt(1 - cos ** 2) * v
    emb["sitting"] = blend(emb["sat"], 0.9, 1)
    emb["rug"] = blend(emb["mat"], 0.8, 2)
    return {w: v / np.linalg.norm(v) for w, v in emb.items()}


def bertscore(cand: str, ref: str, emb: dict[str, np.ndarray]) -> tuple[float, float, float]:
    C = np.stack([emb[w] for w in cand.split()])
    R = np.stack([emb[w] for w in ref.split()])
    sim = C @ R.T                       # cosine similarities (unit vectors)
    p = sim.max(axis=1).mean()          # each candidate token -> best reference token
    r = sim.max(axis=0).mean()          # each reference token -> best candidate token
    return float(p), float(r), float(2 * p * r / (p + r))


# ---------- IFEval-style verifiable instructions (Zhou et al. 2023) ----------
def loose_variants(resp: str) -> list[str]:
    """IFEval 'loose' check: also try the response with markdown '*' removed and/or its first
    and/or last line dropped; an instruction counts as followed if ANY non-empty variant passes."""
    lines = resp.split("\n")
    bases = [resp, "\n".join(lines[1:]), "\n".join(lines[:-1]), "\n".join(lines[1:-1])]
    return [v for b in bases for v in (b, b.replace("*", "")) if v.strip()]


IFEVAL_MOCK = [   # (response, [(instruction, checker), ...])
    ("the sky is blue because of rayleigh scattering.",
     [("all lowercase", lambda r: r == r.lower()), ("mention 'blue'", lambda r: "blue" in r)]),
    ("**Yes**, the meeting moved to Friday at noon.",
     [("at least 5 words", lambda r: len(r.split()) >= 5), ("start with 'Yes'", lambda r: r.startswith("Yes"))]),
    ("Sure, here it is: name=Ada, age=36",
     [("valid JSON object", lambda r: r.strip().startswith("{") and r.strip().endswith("}")),
      ("no commas", lambda r: "," not in r)]),
]


def ifeval_scores(mock, loose: bool) -> tuple[float, float, list[list[bool]]]:
    results = [[any(chk(v) for v in (loose_variants(resp) if loose else [resp])) for _, chk in instrs]
               for resp, instrs in mock]
    prompt_level = float(np.mean([all(r) for r in results]))
    instruction_level = float(np.mean([x for r in results for x in r]))
    return prompt_level, instruction_level, results


if __name__ == "__main__":
    print("== EM and token F1 (SQuAD normalisation) ==")
    pred, gold = "The cat sat on the mat.", "A cat was sitting on the mat"
    print(f"normalised pred: {normalize_answer(pred)!r}")
    print(f"normalised gold: {normalize_answer(gold)!r}")
    em, f1 = exact_match(pred, gold), token_f1(pred, gold)
    print(f"EM = {em:.0f}   F1 = {f1:.3f}")
    assert em == 0 and abs(f1 - 2 / 3) < 1e-9

    cand1, ref1 = "the cat is sitting on the mat", "the cat sat on the mat"
    print("\n== BLEU vs ROUGE on one pair ==")
    print(f"candidate: {cand1!r}\nreference: {ref1!r}")
    b, ps, bp = bleu([(cand1, ref1)])
    print("clipped precisions p1..p4 =", " ".join(f"{p:.3f}" for p in ps), f" BP = {bp:.3f}")
    print(f"sentence BLEU (no smoothing)  = {b:.3f}")
    bs, _, _ = bleu([(cand1, ref1)], smooth=True)
    print(f"sentence BLEU (add-one, n>1)  = {bs:.3f}")
    r1 = rouge_n(cand1, ref1, 1)
    lcs, lp, lr, lf = rouge_l(cand1, ref1)
    print(f"ROUGE-1  P={r1[0]:.3f} R={r1[1]:.3f} F={r1[2]:.3f}")
    print(f"ROUGE-L  LCS={lcs}  P={lp:.3f} R={lr:.3f} F={lf:.3f}")
    assert b == 0.0 and lcs == 5 and abs(lf - 0.769) < 1e-3
    assert [round(p, 4) for p in ps] == [round(5 / 7, 4), 0.5, 0.2, 0.0]

    cand2, ref2 = "the cat sat on the red mat today", "the cat sat on the mat today"
    b2, ps2, _ = bleu([(cand2, ref2)])
    print(f"\nnear-copy {cand2!r}: p = " + " ".join(f"{p:.3f}" for p in ps2) + f"  BLEU = {b2:.3f}")
    assert abs(b2 - 0.595) < 1e-3
    bc, psc, bpc = bleu([(cand1, ref1), (cand2, ref2)])
    print(f"corpus BLEU over both pairs (counts pooled before the geometric mean) = {bc:.3f}")

    print("\n== Toy BERTScore (greedy cosine matching) ==")
    emb = toy_embeddings()
    print(f"cos(sat, sitting) = {emb['sat'] @ emb['sitting']:.2f}")
    for cand in [cand1, "the dog ran on the rug", "the cat sat on the rug"]:
        p, r, f = bertscore(cand, ref1, emb)
        lf_ = rouge_l(cand, ref1)[3]
        bl = bleu([(cand, ref1)], smooth=True)[0]
        print(f"{cand:<32} BERTScore F={f:.3f}  ROUGE-L F={lf_:.3f}  BLEU(smoothed)={bl:.3f}")

    print("\n== IFEval-style scoring: 3 prompts x 2 verifiable instructions ==")
    for mode in ("strict", "loose"):
        pl, il, res = ifeval_scores(IFEVAL_MOCK, loose=(mode == "loose"))
        print(f"{mode:<6} per-instruction {res}  prompt-level {pl:.3f}  instruction-level {il:.3f}")
    assert ifeval_scores(IFEVAL_MOCK, False)[:2] == (1 / 3, 3 / 6)
    assert ifeval_scores(IFEVAL_MOCK, True)[:2] == (2 / 3, 4 / 6)
