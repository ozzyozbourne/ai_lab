"""Error analysis on 40 mocked agent traces: open codes -> axial codes -> counts.

Chapter 1, section 1.8 (Eval-driven development). Method from the Husain & Shankar evals FAQ:
read traces, write a free-text note on the FIRST problem you see (open coding), group notes into
a failure taxonomy (axial coding), count, and build a transition-failure matrix for agents.
The "agent" is a 4-stage real-estate assistant: parse -> retrieve -> tool_call -> answer.
Run:  python3 code/ch01/error_analysis.py
Expected key output: 34 of 40 traces fail; top category "retrieval miss" (10, 29%); the top
three categories cover 71% of failures; 2 notes stay unclassified (refine the taxonomy).
"""
from __future__ import annotations

import random
from collections import Counter
from dataclasses import dataclass

STAGES = ["parse", "retrieve", "tool_call", "answer"]

# (open-code note templates, stage where the trace first went wrong, how many traces)
SCENARIOS = [
    (["retrieved listings from the wrong city", "search returned no docs for a valid zip code",
      "retriever missed the HOA policy doc", "top documents were irrelevant to the question"], "retrieve", 10),
    (["called create_showing with the wrong date format", "passed listing name instead of listing id",
      "tool call missing required argument agent_id", "wrong tool arguments: price as string"], "tool_call", 8),
    (["invented a pool that is not in the listing", "made up a closing date",
      "hallucinated square footage"], "answer", 6),
    (["ignored the user's budget of 500k", "ignored constraint: 3 bedrooms requested",
      "dropped the pet-friendly requirement"], "parse", 5),
    (["leaked an internal UUID in the reply", "format: returned raw JSON to the user"], "answer", 3),
    (["asked the user the same question twice", "replied in Spanish to an English user"], "answer", 2),
]
N_PASS = 6

# axial coding: category <- keywords (first match wins; order matters, like a human codebook)
CODEBOOK = {
    "retrieval miss": ["retriev", "search returned", "documents were irrelevant"],
    "wrong tool args": ["tool call", "wrong date format", "instead of listing id", "tool arguments"],
    "hallucination": ["invented", "made up", "hallucinated"],
    "ignored constraint": ["ignored", "dropped the"],
    "format / leak": ["uuid", "raw json", "format:"],
}


@dataclass
class Trace:
    id: int
    path: list[str]          # stages the agent actually visited
    failed_at: str | None    # first stage that went wrong (None = trace is fine)
    note: str                # the open code written by the reviewer


def make_traces(seed: int = 11) -> list[Trace]:
    rng = random.Random(seed)
    traces: list[Trace] = []
    for notes, stage, count in SCENARIOS:
        for _ in range(count):
            path = STAGES.copy() if rng.random() < 0.75 or stage == "retrieve" else ["parse", "tool_call", "answer"]
            if stage not in path:
                path = STAGES.copy()
            traces.append(Trace(0, path, stage, rng.choice(notes)))
    for _ in range(N_PASS):
        traces.append(Trace(0, STAGES.copy(), None, "looks good"))
    rng.shuffle(traces)
    for i, t in enumerate(traces):
        t.id = i
    return traces


def axial_code(note: str) -> str:
    low = note.lower()
    for category, keys in CODEBOOK.items():
        if any(k in low for k in keys):
            return category
    return "UNCLASSIFIED"


def pareto(categories: list[str]) -> list[tuple[str, int, float, float]]:
    counts = Counter(categories).most_common()
    total, cum, rows = sum(c for _, c in counts), 0, []
    for cat, c in counts:
        cum += c
        rows.append((cat, c, c / total, cum / total))
    return rows


def transition_matrix(traces: list[Trace]) -> dict[tuple[str, str], int]:
    """Rows: last stage that succeeded. Columns: first stage that failed (Husain & Shankar FAQ)."""
    m: Counter = Counter()
    for t in traces:
        if t.failed_at is None:
            continue
        i = t.path.index(t.failed_at)
        last_ok = t.path[i - 1] if i > 0 else "START"
        m[(last_ok, t.failed_at)] += 1
    return dict(m)


if __name__ == "__main__":
    traces = make_traces()
    failing = [t for t in traces if t.failed_at is not None]
    print(f"traces reviewed: {len(traces)}, failing: {len(failing)}")
    print("\nsample open codes:")
    for t in failing[:4]:
        print(f"  trace {t.id:>2}: {t.note}")

    cats = [axial_code(t.note) for t in failing]
    rows = pareto(cats)
    print(f"\n{'failure category':<20} {'count':>5} {'share':>7} {'cumulative':>11}")
    for cat, c, share, cum in rows:
        print(f"{cat:<20} {c:>5} {share:>7.0%} {cum:>11.0%}")
    unclassified = [t.note for t in failing if axial_code(t.note) == "UNCLASSIFIED"]
    print(f"\nunclassified notes -> add a category or rewrite the codebook: {sorted(set(unclassified))}")

    m = transition_matrix(traces)
    rows_l, cols_l = ["START"] + STAGES[:-1], STAGES
    print("\ntransition-failure matrix (row = last OK stage, column = first failed stage)")
    print(f"{'':<10}" + "".join(f"{c:>10}" for c in cols_l))
    for r in rows_l:
        print(f"{r:<10}" + "".join(f"{m.get((r, c), 0) or '.':>10}" for c in cols_l))

    assert len(failing) == 34
    assert rows[0][0] == "retrieval miss" and rows[0][1] == 10
    assert abs(rows[2][3] - 24 / 34) < 1e-9
    assert len(unclassified) == 2
    assert sum(m.values()) == 34
