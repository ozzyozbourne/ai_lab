"""A CI regression gate for a prompt change: assertions, repeats, paired bootstrap, margin, cache.

Chapter 9, section 9.9 (Regression testing in CI). Reads code/ch09/data/regression_set.jsonl (200
items). A seeded mock model answers each item; three assertions grade the answer (valid JSON, cites a
[doc-N] source, under max_chars). The item passes if all three pass. Run-to-run noise is on purpose:
the same model at "temperature 0" still flips items between runs (Atil et al. 2024).
Two gates are compared over 1,000 simulated CI runs:
  naive  : one run per arm, fail if candidate pass rate < baseline - 1 point
  paired : 3 repeats per arm, paired bootstrap 95% CI [lo, hi] of the per-item difference, margin 5 pts:
           PASS if lo >= -margin (non-inferior); FAIL if hi < 0 (clear regression);
           otherwise INCONCLUSIVE -> escalate to 10 repeats and decide again (still unclear -> REVIEW)
Run:  python3 code/ch09/prompt_regression_ci.py
Expected key output: identical candidate -> naive gate fails about 37% of runs, paired gate about 4% (two looks at 2.5% each);
a real 5- or 10-point regression is failed by the paired gate in essentially every run; the cached
baseline re-run costs 0 model calls.
"""
from __future__ import annotations

import json
import pathlib
import random

import numpy as np

DATA = pathlib.Path(__file__).resolve().parent / "data" / "regression_set.jsonl"
ITEMS = [json.loads(line) for line in DATA.read_text().splitlines()]
P_BASE = np.array([1.0 - it["difficulty"] for it in ITEMS])        # per-item pass probability


class CachedModel:
    """Mock model + response cache keyed by (model, prompt_version, item, repeat)."""

    def __init__(self):
        self.cache: dict[tuple, str] = {}
        self.calls = 0

    def answer(self, version: str, drop: float, item: dict, repeat: int) -> str:
        key = ("mock-model-2026-01", version, item["id"], repeat)
        if key not in self.cache:
            self.calls += 1
            rng = random.Random(f"{version}:{item['id']}:{repeat}")
            p = max(0.0, 1.0 - item["difficulty"] - drop)
            q = 1.0 - p ** (1 / 3)                                  # per-assertion failure prob
            body = '{"answer": "See policy", "source": "[doc-%d]"}' % (int(item["id"][1:]) % 7)
            if rng.random() < q:
                body = body.replace("}", "")                        # broken JSON
            if rng.random() < q:
                body = body.replace("[doc-", "[ref ")               # missing citation
            if rng.random() < q:
                body += " " + "x" * item["max_chars"]               # rambling
            self.cache[key] = body
        return self.cache[key]


def assertions(out: str, item: dict) -> dict[str, bool]:
    try:
        json.loads(out)
        ok_json = True
    except json.JSONDecodeError:
        ok_json = False
    return {"is_json": ok_json, "cites_source": "[doc-" in out, "length": len(out) <= item["max_chars"]}


def run_suite(model: CachedModel, version: str, drop: float, repeats: int) -> np.ndarray:
    """Return an (items x repeats) 0/1 matrix of item passes."""
    return np.array([[float(all(assertions(model.answer(version, drop, it, r), it).values()))
                      for r in range(repeats)] for it in ITEMS])


def paired_gate(base: np.ndarray, cand: np.ndarray, margin: float, rng, B: int = 2000):
    d = cand.mean(axis=1) - base.mean(axis=1)                        # per-item paired difference
    idx = rng.integers(0, len(d), size=(B, len(d)))
    boots = d[idx].mean(axis=1)
    lo, hi = np.quantile(boots, [0.025, 0.975])
    if lo >= -margin:
        verdict = "PASS"                                             # any regression is < margin
    elif hi < 0:
        verdict = "FAIL"                                             # regression is clear
    else:
        verdict = "INCONCLUSIVE"                                     # CI too wide: get more data
    return d.mean(), lo, hi, verdict


def two_stage(p_b: np.ndarray, p_c: np.ndarray, rng, margin: float = 0.05) -> str:
    b = (rng.random((len(p_b), 3)) < p_b[:, None]).astype(float)
    c = (rng.random((len(p_c), 3)) < p_c[:, None]).astype(float)
    v = paired_gate(b, c, margin, rng, B=400)[3]
    if v != "INCONCLUSIVE":
        return v
    b = np.hstack([b, rng.random((len(p_b), 7)) < p_b[:, None]])    # escalate: 7 more repeats
    c = np.hstack([c, rng.random((len(p_c), 7)) < p_c[:, None]])
    v = paired_gate(b, c, margin, rng, B=400)[3]
    return "REVIEW" if v == "INCONCLUSIVE" else v


def simulate(drop: float, sims: int, rng) -> dict[str, float]:
    """Vectorised version of the same mock, for many CI runs."""
    p_c = np.clip(P_BASE - drop, 0, 1)
    counts = {"naive_fail": 0, "PASS": 0, "FAIL": 0, "REVIEW": 0}
    for _ in range(sims):
        b1 = rng.random(len(P_BASE)) < P_BASE
        c1 = rng.random(len(P_BASE)) < p_c
        counts["naive_fail"] += c1.mean() < b1.mean() - 0.01
        counts[two_stage(P_BASE, p_c, rng)] += 1
    return {k: v / sims for k, v in counts.items()}


if __name__ == "__main__":
    rng = np.random.default_rng(9)
    model = CachedModel()
    base = run_suite(model, "prompt-v7", 0.0, 3)
    first_calls = model.calls
    base_again = run_suite(model, "prompt-v7", 0.0, 3)               # second CI job: all cache hits
    assert (base == base_again).all() and model.calls == first_calls
    cand = run_suite(model, "prompt-v8", 0.0, 3)                     # a refactor that changes nothing
    print(f"items={len(ITEMS)} repeats=3  model calls: baseline {first_calls}, "
          f"re-run baseline {model.calls - first_calls - 600} (cached), candidate 600")
    per_assert = {k: np.mean([assertions(model.answer('prompt-v7', 0.0, it, 0), it)[k] for it in ITEMS])
                  for k in ("is_json", "cites_source", "length")}
    print("baseline assertion pass rates (repeat 0): "
          + ", ".join(f"{k} {v:.3f}" for k, v in per_assert.items()))
    print(f"single-run pass rates: baseline {base[:, 0].mean():.3f}, candidate {cand[:, 0].mean():.3f}"
          f"  (same model; difference is noise)")
    m, lo, hi, verdict = paired_gate(base, cand, 0.05, rng)
    print(f"paired gate on 3 repeats: diff {m:+.3f}, 95% CI [{lo:+.3f}, {hi:+.3f}] -> {verdict}")
    print("\n1,000 simulated CI runs per scenario (paired gate escalates INCONCLUSIVE to 10 repeats)")
    print(f"{'true change':>12} {'naive FAIL':>11} {'paired PASS':>12} {'paired FAIL':>12} {'REVIEW':>7}")
    rates = {}
    for drop in (0.0, 0.02, 0.05, 0.10):
        r = simulate(drop, 1000, rng)
        rates[drop] = r
        print(f"{-drop:>+12.2f} {r['naive_fail']:>11.1%} {r['PASS']:>12.1%} {r['FAIL']:>12.1%} {r['REVIEW']:>7.1%}")
    assert 0.30 < rates[0.0]["naive_fail"] < 0.45 and rates[0.0]["FAIL"] < 0.05
    assert rates[0.05]["FAIL"] > 0.95 and rates[0.10]["FAIL"] > 0.99
