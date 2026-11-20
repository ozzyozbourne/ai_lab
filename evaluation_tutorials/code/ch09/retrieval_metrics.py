"""Retrieval metrics from scratch: P@k, R@k, hit@k, RR/MRR, AP/MAP, nDCG (linear and exponential gain).

Chapter 9, section 9.10 (Evaluating retrieval). Reproduces the worked example: relevant d2 (rel 3),
d5 (rel 2), d9 (rel 1); the system returns [d1, d2, d3, d5, d7]. Also shows the RAGAS-style context
precision (AP over retrieved items only) and the incomplete-judgments trap: unjudged documents
count as non-relevant, which punishes a retriever that finds new relevant documents.
Run:  python3 code/ch09/retrieval_metrics.py
Expected key output: P@5 0.400, R@5 0.667, RR 0.500, AP 0.333, nDCG@5 0.578 (linear) / 0.608 (exp),
context precision 0.500; MAP 0.389 and MRR 0.500 over 3 queries; the novel retriever scores 0.660
with unjudged = 0 but 0.943 once the holes are judged.
"""
from __future__ import annotations

import math

Qrels = dict[str, int]                     # doc id -> graded relevance (absent = unjudged)


def precision_at_k(ranked: list[str], qrels: Qrels, k: int) -> float:
    return sum(qrels.get(d, 0) > 0 for d in ranked[:k]) / k


def recall_at_k(ranked: list[str], qrels: Qrels, k: int) -> float:
    rel = {d for d, r in qrels.items() if r > 0}
    return len(rel & set(ranked[:k])) / len(rel)


def hit_at_k(ranked: list[str], qrels: Qrels, k: int) -> float:
    return float(any(qrels.get(d, 0) > 0 for d in ranked[:k]))


def reciprocal_rank(ranked: list[str], qrels: Qrels) -> float:
    return next((1.0 / i for i, d in enumerate(ranked, 1) if qrels.get(d, 0) > 0), 0.0)


def average_precision(ranked: list[str], qrels: Qrels) -> float:
    """AP = (1/|R|) * sum_k P@k * 1[doc k relevant]; relevant docs never retrieved add 0."""
    n_rel = sum(r > 0 for r in qrels.values())
    hits, total = 0, 0.0
    for i, d in enumerate(ranked, 1):
        if qrels.get(d, 0) > 0:
            hits += 1
            total += hits / i
    return total / n_rel if n_rel else 0.0


def dcg(gains: list[float]) -> float:
    return sum(g / math.log2(i + 1) for i, g in enumerate(gains, 1))


def ndcg_at_k(ranked: list[str], qrels: Qrels, k: int, gain: str = "linear") -> float:
    g = (lambda r: float(r)) if gain == "linear" else (lambda r: 2.0 ** r - 1)
    actual = [g(qrels.get(d, 0)) for d in ranked[:k]]
    ideal = sorted((g(r) for r in qrels.values()), reverse=True)[:k]
    return dcg(actual) / dcg(ideal) if ideal else 0.0


def ragas_context_precision(verdicts: list[int]) -> float:
    """Copied logic of RAGAS _calculate_average_precision: divides by #relevant *retrieved*."""
    cumsum, num = 0, 0.0
    for i, v in enumerate(verdicts):
        cumsum += v
        if v:
            num += cumsum / (i + 1)
    return num / (cumsum + 1e-10)


if __name__ == "__main__":
    qrels = {"d2": 3, "d5": 2, "d9": 1}
    run = ["d1", "d2", "d3", "d5", "d7"]
    m = {
        "P@5": precision_at_k(run, qrels, 5), "R@5": recall_at_k(run, qrels, 5),
        "hit@1": hit_at_k(run, qrels, 1), "hit@5": hit_at_k(run, qrels, 5),
        "RR": reciprocal_rank(run, qrels), "AP": average_precision(run, qrels),
        "nDCG@5 linear": ndcg_at_k(run, qrels, 5, "linear"), "nDCG@5 exp": ndcg_at_k(run, qrels, 5, "exp"),
    }
    print("worked example: qrels d2=3, d5=2, d9=1; run [d1, d2, d3, d5, d7]")
    for k, v in m.items():
        print(f"  {k:<14} {v:.3f}")
    print(f"  DCG/IDCG linear = {dcg([0, 3, 0, 2, 0]):.3f} / {dcg([3, 2, 1]):.3f};"
          f" exp = {dcg([0, 7, 0, 3, 0]):.3f} / {dcg([7, 3, 1]):.3f}")
    cp = ragas_context_precision([0, 1, 0, 1, 0])
    print(f"  RAGAS-style context precision on verdicts [0,1,0,1,0] = {cp:.3f} "
          f"(ignores the never-retrieved d9; AP above does not)")
    assert abs(m["nDCG@5 linear"] - 0.578) < 1e-3 and abs(m["nDCG@5 exp"] - 0.608) < 1e-3
    assert abs(m["P@5"] - 0.4) < 1e-9 and abs(m["R@5"] - 2 / 3) < 1e-9 and abs(cp - 0.5) < 1e-6

    # MAP and MRR over three queries
    queries = {
        "q1": (qrels, run),
        "q2": ({"a": 1, "b": 1}, ["a", "x", "b", "y", "z"]),
        "q3": ({"k": 2}, ["u", "v", "w", "x", "y"]),
    }
    aps = {q: average_precision(r, qr) for q, (qr, r) in queries.items()}
    rrs = {q: reciprocal_rank(r, qr) for q, (qr, r) in queries.items()}
    print("\nper query AP / RR: " + ", ".join(f"{q} {aps[q]:.3f}/{rrs[q]:.3f}" for q in queries))
    print(f"MAP = {sum(aps.values()) / 3:.3f}   MRR = {sum(rrs.values()) / 3:.3f}")

    # Incomplete judgments: qrels came from pooling an old system; the new system finds d11 and d12,
    # which nobody judged. A later (LLM or human) assessor finds both relevant (rel 2).
    old_pool_qrels = {"d2": 3, "d5": 2, "d9": 1, "d1": 0, "d3": 0, "d7": 0}
    new_run = ["d11", "d2", "d12", "d5", "d9"]
    full_qrels = {**old_pool_qrels, "d11": 2, "d12": 2}
    as_zero = ndcg_at_k(new_run, old_pool_qrels, 5)
    condensed = ndcg_at_k([d for d in new_run if d in old_pool_qrels], old_pool_qrels, 5)
    filled = ndcg_at_k(new_run, full_qrels, 5)
    old_sys = ndcg_at_k(run, full_qrels, 5)
    print("\nincomplete judgments (new retriever surfaces unjudged d11, d12):")
    print(f"  unjudged = non-relevant  nDCG@5 = {as_zero:.3f}")
    print(f"  condensed list (drop unjudged) = {condensed:.3f}")
    print(f"  after judging the holes  = {filled:.3f}   (old system with full qrels = {old_sys:.3f})")
    assert as_zero < filled and old_sys < filled
