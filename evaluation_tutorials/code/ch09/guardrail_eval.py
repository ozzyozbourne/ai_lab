"""Evaluate guardrails as classifiers with a latency budget: a regex PII rail, a mock LLM rail, a cascade,
and a deterministic tool-call rail.

Chapter 9, section 9.16 (Guardrails as runtime evals). A guardrail is an eval with an action
attached, so it has the same error types as any classifier: false blocks (annoyed users) and misses
(leaked PII), plus added latency on every request.
Run:  python3 code/ch09/guardrail_eval.py
Expected key output: a threshold sweep for the regex rail (precision 0.987 / recall 0.789 at 0.9: it
misses obfuscated PII); the mock LLM rail has recall 0.979 but 181 ms p50 latency; the cascade
(regex first, LLM only when ambiguous) reaches recall 1.000 with p50 0.05 ms, though its p95 still
pays for the LLM (46% of traffic); the tool-call rail passes 5 of 8 edge-case tests until it is hardened.
"""
from __future__ import annotations

import random
import re

import numpy as np

EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")
CARD = re.compile(r"\b(?:\d[ -]?){15}\d\b")
PHONE = re.compile(r"\+\d{1,3}[ -]?\d[\d -]{7,}\d")              # international format only
OBFUSCATED = re.compile(r"\b\w+ at \w+ dot (com|org|net)\b")
KEYWORDS = ("email", "phone", "card", "call me", "my number")


def luhn_ok(digits: str) -> bool:
    d = [int(c) for c in digits if c.isdigit()][::-1]
    return sum(x if i % 2 == 0 else (2 * x - 9 if 2 * x > 9 else 2 * x) for i, x in enumerate(d)) % 10 == 0


def make_card(rng: random.Random) -> str:
    body = [rng.randint(0, 9) for _ in range(15)]
    for check in range(10):
        if luhn_ok("".join(map(str, body + [check]))):
            return "".join(map(str, body + [check]))
    raise RuntimeError


def build_dataset(seed: int = 1) -> list[tuple[str, int]]:
    rng = random.Random(seed)
    names = ["ana", "li", "omar", "kim", "sven", "ravi"]
    pos, neg = [], []
    for _ in range(25):
        n = rng.choice(names)
        pos += [(f"you can email me at {n}{rng.randint(1, 99)}@example.com", 1),
                (f"my card is {make_card(rng)} please charge it", 1),
                (f"call me on +44 7700 {rng.randint(100000, 999999)}", 1)]
    for _ in range(10):                                         # obfuscated PII the regex misses
        n = rng.choice(names)
        pos += [(f"reach me: {n} at example dot com", 1),
                (f"card four one one one, then {rng.randint(1000, 9999)} {rng.randint(1000, 9999)}", 1)]
    for _ in range(40):
        neg += [(f"where is order ORD-{rng.randint(100000, 999999)}?", 0),
                (f"the email you sent on 2026-0{rng.randint(1, 9)}-1{rng.randint(0, 9)} was blank", 0)]
    for _ in range(20):                                         # hard negatives: long digit strings
        neg += [(f"tracking number {rng.randint(10 ** 15, 10 ** 16 - 1)}", 0),
                (f"my phone app crashes on version 3.{rng.randint(1, 20)}", 0)]
    data = pos + neg
    rng.shuffle(data)
    return data


def regex_score(text: str) -> float:
    s = 0.0
    if EMAIL.search(text):
        s = max(s, 1.0)
    m = CARD.search(text)
    if m:
        s = max(s, 0.9 if luhn_ok(m.group()) else 0.6)
    if PHONE.search(text):
        s = max(s, 0.9)
    if OBFUSCATED.search(text):
        s = max(s, 0.4)
    if any(k in text.lower() for k in KEYWORDS):
        s = max(s, 0.3)
    return s


def llm_score(label: int, rng: np.random.Generator) -> tuple[float, float]:
    """Mock LLM classifier: noisy but better on paraphrases; log-normal latency, median ~180 ms."""
    score = rng.beta(7, 2) if label else rng.beta(2, 7)
    return float(score), float(rng.lognormal(np.log(180), 0.35))


def prf(pred: list[int], gold: list[int]) -> tuple[float, float, float, float]:
    tp = sum(p and g for p, g in zip(pred, gold))
    fp = sum(p and not g for p, g in zip(pred, gold))
    fn = sum((not p) and g for p, g in zip(pred, gold))
    prec = tp / (tp + fp) if tp + fp else 1.0
    rec = tp / (tp + fn)
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    false_block = fp / sum(1 for g in gold if not g)
    return prec, rec, f1, false_block


def refund_rail(call: dict) -> bool:
    """Naive rail: block refunds over 500 (the NeMo Guardrails quickstart rule, re-implemented)."""
    return call["name"] == "issue_refund" and call["args"].get("amount", 0) > 500


def refund_rail_hardened(call: dict) -> bool:
    if call["name"] != "issue_refund":
        return False
    try:
        amount = float(call["args"]["amount"])
    except (KeyError, TypeError, ValueError):
        return True                                             # malformed -> block, fail closed
    return not (0 < amount <= 500)


if __name__ == "__main__":
    data = build_dataset()
    gold = [y for _, y in data]
    print(f"{len(data)} labelled messages, {sum(gold)} contain PII ({20} obfuscated)")
    rs = [regex_score(t) for t, _ in data]
    print("\nregex rail threshold sweep (latency ~0.05 ms)")
    print(f"{'block if >=':>11} {'precision':>10} {'recall':>7} {'F1':>6} {'false-block':>12}")
    for thr in (0.3, 0.4, 0.6, 0.9):
        p, r, f, fb = prf([s >= thr for s in rs], gold)
        print(f"{thr:>11.1f} {p:>10.3f} {r:>7.3f} {f:>6.3f} {fb:>12.3f}")
    rng = np.random.default_rng(3)
    llm = [llm_score(y, rng) for y in gold]
    p_l, r_l, f_l, fb_l = prf([s >= 0.5 for s, _ in llm], gold)
    lat_l = np.array([t for _, t in llm])
    # Cascade: block on a confident regex hit, pass on a clean message, ask the LLM only when ambiguous.
    pred_c, lat_c = [], []
    for s_r, (s_l, t_l) in zip(rs, llm):
        if s_r >= 0.9:
            pred_c.append(1); lat_c.append(0.05)
        elif s_r == 0.0:
            pred_c.append(0); lat_c.append(0.05)
        else:
            pred_c.append(int(s_l >= 0.5)); lat_c.append(0.05 + t_l)
    p_c, r_c, f_c, fb_c = prf(pred_c, gold)
    lat_c = np.array(lat_c)
    print(f"\n{'rail':<16} {'precision':>10} {'recall':>7} {'F1':>6} {'false-block':>12} {'p50 ms':>7} {'p95 ms':>7}")
    p_r, r_r, f_r, fb_r = prf([s >= 0.9 for s in rs], gold)
    print(f"{'regex >= 0.9':<16} {p_r:>10.3f} {r_r:>7.3f} {f_r:>6.3f} {fb_r:>12.3f} {0.05:>7.2f} {0.05:>7.2f}")
    print(f"{'mock LLM >= 0.5':<16} {p_l:>10.3f} {r_l:>7.3f} {f_l:>6.3f} {fb_l:>12.3f} "
          f"{np.percentile(lat_l, 50):>7.0f} {np.percentile(lat_l, 95):>7.0f}")
    print(f"{'cascade':<16} {p_c:>10.3f} {r_c:>7.3f} {f_c:>6.3f} {fb_c:>12.3f} "
          f"{np.percentile(lat_c, 50):>7.2f} {np.percentile(lat_c, 95):>7.0f}")
    print(f"cascade sends {np.mean(lat_c > 1):.0%} of traffic to the LLM rail")
    tests = [  # (tool call, should block)
        ({"name": "issue_refund", "args": {"amount": 120}}, False),
        ({"name": "issue_refund", "args": {"amount": 501}}, True),
        ({"name": "issue_refund", "args": {"amount": 500}}, False),
        ({"name": "lookup_order", "args": {"id": "ORD-1"}}, False),
        ({"name": "issue_refund", "args": {"amount": 9000}}, True),
        ({"name": "issue_refund", "args": {"amount": -800}}, True),     # negative refund = a charge
        ({"name": "issue_refund", "args": {"amount": "600"}}, True),    # string amount from the model
        ({"name": "issue_refund", "args": {}}, True),                    # missing amount
    ]
    def run(rail):
        ok = 0
        for call, want in tests:
            try:
                ok += rail(call) == want
            except Exception:
                pass                                            # a crash is a failed test
        return ok
    n1, n2 = run(refund_rail), run(refund_rail_hardened)
    print(f"\ntool-call rail tests: naive {n1}/{len(tests)}, hardened {n2}/{len(tests)}")
    assert r_l > r_r and p_r > 0.95 and n2 == len(tests) and n1 < n2
    assert np.percentile(lat_c, 50) < np.percentile(lat_l, 50) / 10
