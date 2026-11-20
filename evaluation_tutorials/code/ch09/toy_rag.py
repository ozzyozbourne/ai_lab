"""A toy RAG pipeline with controlled hallucinations: BM25 retrieval, extractive generator, mock NLI.

Chapter 9, section 9.11 (Evaluating generation in RAG). 30 documents (20 products, 10 makers), 30
questions (20 one-hop, 10 two-hop: product -> maker -> headquarters). The "generator" copies the most
relevant context sentences and, at a set injection rate, adds a fabricated sentence: either an invented
fact or a subtly wrong number. Metrics, all RAGAS-shaped:
  faithfulness   = supported answer claims / answer claims   (mock NLI: content-token overlap >= 0.8)
  context recall = reference claims attributable to the retrieved context / reference claims
Run:  python3 code/ch09/toy_rag.py
Expected key output: true faithfulness 1.000 -> 0.829 as the injection rate goes 0 -> 0.5; the
overlap-only checker reads 0.920 because it misses every number swap, the number-aware one reads
0.829; context recall 0.833 at k = 1 (two-hop questions lose their second document) and 1.000 at
k >= 2; a refusal produces NaN, and dropping NaNs inflates the mean.
Citation quality (ALCE-style): each answer sentence carries [doc-id] citations; citation recall = sentences
supported by the passages they cite; citation precision = citations that support their sentence. Swapping
20% of citations for another retrieved doc leaves faithfulness at 1.000 but drops citation recall to ~0.8;
padding 30% of sentences with an extra irrelevant citation leaves recall at 1.000 but lowers precision.
"""
from __future__ import annotations

import math
import random
import re
from collections import Counter

STOP = {"the", "a", "an", "is", "of", "by", "in", "and", "to", "has", "what", "which", "where", "made",
        "that", "company", "it", "its", "was", "for", "how", "much", "does", "who", "makes"}
MAKERS = [("Aerotek", "Lyon"), ("Brightloom", "Osaka"), ("Corvane", "Austin"), ("Dunmere", "Leeds"),
          ("Elstrand", "Turin"), ("Fennick", "Porto"), ("Galvora", "Quito"), ("Hesketh", "Perth"),
          ("Ivorine", "Tartu"), ("Jessamy", "Cork")]
KINDS = ["drone", "kettle", "scooter", "lamp", "headset"]


def tokens(s: str) -> list[str]:
    return [t for t in re.findall(r"[a-z0-9]+", s.lower()) if t not in STOP]


def build_corpus(seed: int = 3):
    rng = random.Random(seed)
    docs, questions = {}, []
    for i, (maker, city) in enumerate(MAKERS):
        docs[f"m{i}"] = [f"{maker} is headquartered in {city}.", f"{maker} was founded in {1950 + 7 * i}.",
                         f"{maker} makes the Zorbel {chr(65 + i)}{i + 1} and the Zorbel {chr(75 + i)}{i + 11}."]
    for j in range(20):
        name, kind, (maker, city) = f"Zorbel {chr(65 + j)}{j + 1}", KINDS[j % 5], MAKERS[j % 10]
        weight, price = rng.randint(200, 2000), rng.randint(20, 900)
        docs[f"p{j}"] = [f"The {name} is a {kind} made by {maker}.", f"The {name} weighs {weight} grams.",
                         f"The {name} costs {price} euros."]
        questions.append((f"How much does the {name} weigh?", [(f"p{j}", 1)]))
        if j < 10:
            questions.append((f"Which company makes the {name} and where is it headquartered?",
                              [(f"p{j}", 0), (f"m{j % 10}", 0)]))
    return docs, questions


class BM25:
    def __init__(self, docs: dict[str, list[str]], k1: float = 1.5, b: float = 0.75):
        self.ids = list(docs)
        self.tf = {d: Counter(tokens(" ".join(s))) for d, s in docs.items()}
        self.len = {d: sum(c.values()) for d, c in self.tf.items()}
        self.avg = sum(self.len.values()) / len(self.len)
        df = Counter(t for c in self.tf.values() for t in c)
        n = len(docs)
        self.idf = {t: math.log(1 + (n - f + 0.5) / (f + 0.5)) for t, f in df.items()}
        self.k1, self.b = k1, b

    def search(self, query: str, k: int) -> list[str]:
        q = tokens(query)
        def score(d):
            tf, norm = self.tf[d], self.k1 * (1 - self.b + self.b * self.len[d] / self.avg)
            return sum(self.idf.get(t, 0) * tf[t] * (self.k1 + 1) / (tf[t] + norm) for t in q if t in tf)
        return sorted(self.ids, key=lambda d: (-score(d), d))[:k]


def generate(question: str, ctx: list[str], rate: float, rng: random.Random) -> tuple[list[str], int]:
    """Extractive answer: the 2 context sentences sharing most tokens with the question, plus maybe
    one fabricated sentence. Returns (answer sentences, number of fabricated sentences)."""
    q = set(tokens(question))
    ranked = sorted(ctx, key=lambda s: -len(q & set(tokens(s))))
    if not ranked or not q & set(tokens(ranked[0])):
        return [], 0                                                   # refusal: "I don't know."
    answer = ranked[:2]
    if rng.random() < rate:
        subject = re.match(r"(The Zorbel \w+|\w+)", answer[0]).group(1)
        if rng.random() < 0.5:
            answer.append(f"{subject} is waterproof to {rng.randint(5, 90)} metres.")  # invented fact
        else:
            src = next((s for s in answer if re.search(r"\b\d+\b", s)), answer[0])
            nums = list(re.finditer(r"\b\d+\b", src))
            if nums:                                                   # change the last number
                m = nums[-1]
                answer.append(src[:m.start()] + str(int(m.group()) + 13) + src[m.end():])  # number swap
            else:
                answer.append(f"{subject} is waterproof to {rng.randint(5, 90)} metres.")
        return answer, 1
    return answer, 0


def supported(claim: str, ctx: list[str], check_numbers: bool) -> bool:
    c = tokens(claim)
    for s in ctx:
        st = set(tokens(s))
        if sum(t in st for t in c) / len(c) >= 0.8:
            if not check_numbers or set(re.findall(r"\d+", claim)) <= set(re.findall(r"\d+", s)):
                return True
    return False


def evaluate(k: int, rate: float, seeds: int = 20):
    docs, qs = build_corpus()
    bm, rng = BM25(docs), random.Random(0)
    faith, faith_num, truth, recall, hits = [], [], [], [], 0
    for question, ref in qs * seeds:                                 # repeat to average the injection noise
        top = bm.search(question, k)
        ctx = [s for d in top for s in docs[d]]
        ans, fab = generate(question, ctx, rate, rng)
        if ans:
            truth.append((len(ans) - fab) / len(ans))
            faith.append(sum(supported(a, ctx, False) for a in ans) / len(ans))
            faith_num.append(sum(supported(a, ctx, True) for a in ans) / len(ans))
        else:
            faith.append(float("nan"))
            faith_num.append(float("nan"))
        recall.append(sum(d in top for d, _ in ref) / len(ref))     # reference claim lives in doc d
        hits += ref[0][0] in top
    mean = lambda xs: sum(x for x in xs if x == x) / sum(1 for x in xs if x == x)
    return mean(faith), mean(faith_num), sum(recall) / len(recall), hits / (len(qs) * seeds), mean(truth)


def citation_eval(k: int, wrong_rate: float, pad_rate: float, seeds: int = 20):
    """Answer sentences cite the doc they came from; at wrong_rate the citation is swapped for another
    retrieved doc, at pad_rate an extra, irrelevant retrieved doc is cited too. Returns (faithfulness over
    the whole context, citation recall, citation precision), using the number-aware mock NLI."""
    docs, qs = build_corpus()
    bm, rng, crng = BM25(docs), random.Random(0), random.Random(1)
    faith, c_rec, c_prec = [], [], []
    for question, _ in qs * seeds:
        top = bm.search(question, k)
        ctx = [s for d in top for s in docs[d]]
        ans, _ = generate(question, ctx, 0.0, rng)
        for sent in ans:
            src = next(d for d in top if sent in docs[d])
            others = [d for d in top if d != src]
            cites = [src]
            if others and crng.random() < wrong_rate:
                cites = [crng.choice(others)]                          # cites the wrong document
            if others and crng.random() < pad_rate:
                extra = [d for d in others if d not in cites]
                if extra:
                    cites.append(crng.choice(extra))                   # an unnecessary extra citation
            faith.append(supported(sent, ctx, True))
            cited_text = [s for d in cites for s in docs[d]]
            c_rec.append(supported(sent, cited_text, True))           # recall: cited passages entail it
            c_prec += [supported(sent, docs[d], True) for d in cites]  # precision: each citation supports it
    m = lambda xs: sum(xs) / len(xs)
    return m(faith), m(c_rec), m(c_prec)


if __name__ == "__main__":
    docs, qs = build_corpus()
    print(f"corpus: {len(docs)} docs, {len(qs)} questions ({sum(len(r) == 2 for _, r in qs)} two-hop)")
    print("\nfaithfulness vs fabrication rate (k = 3)")
    print(f"{'rate':>5} {'true':>6} {'overlap NLI':>12} {'+ number check':>15}")
    f_by_rate = {}
    for rate in (0.0, 0.1, 0.3, 0.5):
        f, fn, _, _, tr = evaluate(3, rate)
        f_by_rate[rate] = (f, fn)
        print(f"{rate:>5.1f} {tr:>6.3f} {f:>12.3f} {fn:>15.3f}")
    print("\ncontext recall vs k (no fabrication)")
    print(f"{'k':>3} {'hit@k (main doc)':>17} {'context recall':>15}")
    rec = {}
    for k in (1, 2, 3, 5):
        _, _, r, h, _ = evaluate(k, 0.0)
        rec[k] = r
        print(f"{k:>3} {h:>17.3f} {r:>15.3f}")
    # NaN handling: three answers, one refusal (no claims -> NaN in RAGAS).
    scores = [1.0, 0.5, float("nan")]
    dropped = sum(s for s in scores if s == s) / 2
    as_zero = sum(s if s == s else 0.0 for s in scores) / 3
    print(f"\nNaN handling for [1.0, 0.5, NaN]: drop NaN -> {dropped:.3f}, count refusal as 0 -> {as_zero:.3f};"
          " report the abstention rate (1/3) separately")
    print("\ncitation quality (k = 3, no fabrication): faithfulness vs ALCE-style citation recall / precision")
    cit = {}
    for wrong, pad in ((0.0, 0.0), (0.2, 0.0), (0.0, 0.3)):
        cit[(wrong, pad)] = citation_eval(3, wrong, pad)
        f, cr, cp = cit[(wrong, pad)]
        print(f"  wrong-doc citations {wrong:.0%}, padded citations {pad:.0%}: faithfulness {f:.3f}, "
              f"citation recall {cr:.3f}, citation precision {cp:.3f}")
    assert cit[(0.0, 0.0)] == (1.0, 1.0, 1.0)
    assert cit[(0.2, 0.0)][0] == 1.0 and cit[(0.2, 0.0)][1] < 0.85
    assert cit[(0.0, 0.3)][1] == 1.0 and cit[(0.0, 0.3)][2] < 0.9
    assert f_by_rate[0.0] == (1.0, 1.0)
    assert f_by_rate[0.5][0] < f_by_rate[0.1][0] < 1.0 and f_by_rate[0.5][1] < f_by_rate[0.5][0]
    assert rec[1] < rec[2] <= rec[3] <= rec[5]
    assert abs(f_by_rate[0.5][1] - 0.829) < 2e-3 and abs(f_by_rate[0.5][0] - 0.920) < 2e-3
    assert abs(rec[1] - 0.833) < 1e-3 and rec[2] == 1.0
