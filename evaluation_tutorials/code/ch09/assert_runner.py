"""A promptfoo-style assertion runner: prompts x providers x tests -> pass/fail matrix.

Chapter 9, section 9.6 (App-level testing libraries). Reads code/ch09/data/assert_tests.json
(prompts, providers, tests[].vars, tests[].assert) and supports the assertion types equals, contains,
icontains, not-contains, not-icontains, regex, is-json, python (an expression over `output`), cost and
latency. The providers are deterministic mocks that also report cost and latency.
Run:  python3 code/ch09/assert_runner.py
Expected key output: a 5-test x 4-column matrix; pass counts small/v1 4, small/v2 5, large/v1 1,
large/v2 3; the prompt fix (v2) repairs JSON for the small model only, and the large model always
breaks the latency budget.
"""
from __future__ import annotations

import json
import pathlib
import re
from dataclasses import dataclass

DATA = pathlib.Path(__file__).resolve().parent / "data" / "assert_tests.json"


@dataclass
class Response:
    output: str
    cost: float          # dollars
    latency_ms: float


def mock_provider(name: str, prompt: str) -> Response:
    """Deterministic stand-ins. 'small' is cheap and terse; 'large' is chatty and slower.
    Under prompt v1 both wrap JSON in a markdown fence; v2 ('return only raw JSON') fixes small only."""
    raw_json = "only raw JSON" in prompt
    brief = "Be brief" in prompt
    q = prompt.split(". ")[-1]
    large = name.endswith("large")
    if "return shoes" in q:
        out = "You can return them within 30 days for a full refund."
        if large and not brief:
            out = "As an AI assistant, I'm happy to help! " + out
    elif "JSON" in q:
        body = '{"name": "Ada Lovelace", "age": 36}'
        out = body if raw_json and not large else f"```json\n{body}\n```"
    elif "order id" in q:
        out = "Your last order is ORD-204817." if not large else "Your last order is ORD-204817, shipped Monday."
    elif "hello" in q.lower():
        out = "Hello! How can I help you today?"
        if large and not brief:
            out += " I can answer questions about orders, returns, shipping and more."
    else:
        out = "We are open 9am to 6pm, Monday to Saturday."
    tokens = len(prompt.split()) + len(out.split())
    cost = tokens * (0.4e-6 if not large else 12e-6)
    latency = 120 + 4 * len(out) * (1 if not large else 6)
    return Response(out, cost, latency)


def check(a: dict, r: Response, vars_: dict) -> tuple[bool, str]:
    t, v, out = a["type"], a.get("value"), r.output
    if t == "equals":
        return out == v, t
    if t == "contains":
        return v in out, f"{t} {v!r}"
    if t == "icontains":
        return v.lower() in out.lower(), f"{t} {v!r}"
    if t == "not-contains":
        return v not in out, f"{t} {v!r}"
    if t == "not-icontains":
        return v.lower() not in out.lower(), f"{t} {v!r}"
    if t == "regex":
        return re.search(v, out) is not None, f"{t} {v}"
    if t == "is-json":
        try:
            json.loads(out)
            return True, t
        except json.JSONDecodeError:
            return False, t
    if t == "python":                       # promptfoo exposes `output` and `context`
        try:
            return bool(eval(v, {"json": json, "re": re}, {"output": out, "context": vars_})), f"python {v}"
        except Exception as e:              # an exception is a failure, not a crash
            return False, f"python raised {type(e).__name__}"
    if t == "cost":
        return r.cost <= a["threshold"], f"cost {r.cost:.5f} <= {a['threshold']}"
    if t == "latency":
        return r.latency_ms <= a["threshold"], f"latency {r.latency_ms:.0f}ms <= {a['threshold']}"
    raise ValueError(f"unknown assertion type {t}")   # fail loudly: never coerce an unknown type


def render(template: str, vars_: dict) -> str:
    return re.sub(r"\{\{(\w+)\}\}", lambda m: str(vars_[m.group(1)]), template)


if __name__ == "__main__":
    cfg = json.loads(DATA.read_text())
    cols = [(p, pid) for p in cfg["providers"] for pid in cfg["prompts"]]
    print(f"{'test':<20}" + "".join(f"{p.split(':')[1] + '/' + pid:>12}" for p, pid in cols))
    totals = {c: 0 for c in cols}
    failures = []
    for test in cfg["tests"]:
        row = f"{test['description']:<20}"
        for prov, pid in cols:
            resp = mock_provider(prov, render(cfg["prompts"][pid], test["vars"]))
            results = [check(a, resp, test["vars"]) for a in test["assert"]]
            ok = all(r[0] for r in results)                       # a test passes if every assertion passes
            totals[(prov, pid)] += ok
            row += f"{'PASS' if ok else 'FAIL':>12}"
            failures += [(test["description"], f"{prov}/{pid}", msg) for good, msg in results if not good]
        print(row)
    print(f"{'passed':<20}" + "".join(f"{totals[c]:>10}/{len(cfg['tests'])}" for c in cols))
    print("\nfailed assertions:")
    for d, col, msg in failures:
        print(f"  {d:<18} {col:<12} {msg}")
    assert [totals[c] for c in cols] == [4, 5, 1, 3], totals
