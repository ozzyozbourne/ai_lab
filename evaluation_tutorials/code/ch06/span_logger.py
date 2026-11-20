"""A minimal span logger with OpenTelemetry GenAI-style names, plus a trace grader.

Section 6.10 (#tracing) of Chapter 6.  Run:  python3 code/ch06/span_logger.py

Tracer.span() is a context manager that writes one JSON line per finished span with trace_id,
span_id, parent_id, name, start/end times and attributes.  Span names and attribute keys follow
the OpenTelemetry GenAI semantic conventions (status: Development), e.g. "invoke_agent <name>",
"chat <model>", "execute_tool <tool>", gen_ai.tool.name, gen_ai.usage.input_tokens.
A fake clock keeps the output deterministic.

A mock research agent runs two episodes: a healthy one and one that loops on the same search
call and hits a tool error.  The trace grader reads the JSONL back and computes n_toolcalls,
calls and errors per tool, repeated-call loops, tokens and wall time, then applies thresholds.
"""
from __future__ import annotations

import json
import tempfile
from collections import Counter, defaultdict
from contextlib import contextmanager
from pathlib import Path


class FakeClock:
    def __init__(self) -> None:
        self.t = 0.0

    def advance(self, s: float) -> None:
        self.t += s


class Tracer:
    def __init__(self, path: Path, clock: FakeClock) -> None:
        self.path, self.clock, self.stack, self.n = path, clock, [], 0
        self.trace_id = ""

    def _id(self) -> str:
        self.n += 1
        return f"{self.n:016x}"

    @contextmanager
    def span(self, name: str, **attrs):
        span = {"trace_id": self.trace_id, "span_id": self._id(),
                "parent_id": self.stack[-1]["span_id"] if self.stack else None,
                "name": name, "start": self.clock.t, "attributes": dict(attrs), "status": "OK"}
        self.stack.append(span)
        try:
            yield span["attributes"]
        except Exception as e:                       # record the error, then re-raise
            span["status"], span["attributes"]["error.type"] = "ERROR", type(e).__name__
            raise
        finally:
            self.stack.pop()
            span["end"] = self.clock.t
            with self.path.open("a") as f:
                f.write(json.dumps(span) + "\n")


# ---------------------------------------------------------------- mock agent and tools
class ToolFailure(Exception):
    pass


def tool_call(tr: Tracer, clock: FakeClock, tool: str, args: dict, fail: bool = False) -> str:
    with tr.span(f"execute_tool {tool}", **{"gen_ai.operation.name": "execute_tool",
                                            "gen_ai.tool.name": tool,
                                            "tool.args": json.dumps(args, sort_keys=True)}):
        clock.advance(0.8)
        if fail:
            raise ToolFailure("HTTP 429 from search backend")
        return "result"


def llm_step(tr: Tracer, clock: FakeClock, tokens_in: int, tokens_out: int) -> None:
    with tr.span("chat mock-model-1", **{"gen_ai.operation.name": "chat",
                                         "gen_ai.request.model": "mock-model-1",
                                         "gen_ai.usage.input_tokens": tokens_in,
                                         "gen_ai.usage.output_tokens": tokens_out}):
        clock.advance(1.5)


def run_episode(tr: Tracer, clock: FakeClock, trace_id: str, looping: bool) -> None:
    tr.trace_id = trace_id
    with tr.span("invoke_agent researcher", **{"gen_ai.operation.name": "invoke_agent",
                                               "gen_ai.agent.name": "researcher"}):
        plan = [("search", {"q": "tau-bench pass^k"}), ("fetch", {"url": "arxiv.org/abs/2406.12045"}),
                ("summarize", {"n": 3})]
        if looping:
            plan = [("search", {"q": "tau-bench pass^k"})] * 5 + [("fetch", {"url": "x"})] * 2
        for i, (tool, args) in enumerate(plan):
            llm_step(tr, clock, 1200 + 300 * i, 150)
            try:
                tool_call(tr, clock, tool, args, fail=looping and tool == "fetch")
            except ToolFailure:
                pass                                  # agent swallows the error and carries on
        llm_step(tr, clock, 2500, 400)


# ---------------------------------------------------------------- trace grader
def grade_traces(path: Path, max_toolcalls: int = 6, max_repeat: int = 2) -> dict[str, dict]:
    by_trace: dict[str, list[dict]] = defaultdict(list)
    for line in path.read_text().splitlines():
        s = json.loads(line)
        by_trace[s["trace_id"]].append(s)
    report = {}
    for tid, spans in by_trace.items():
        tools = sorted((s for s in spans if s["attributes"].get("gen_ai.operation.name") == "execute_tool"),
                       key=lambda s: s["start"])
        calls = Counter(s["attributes"]["gen_ai.tool.name"] for s in tools)
        errors = Counter(s["attributes"]["gen_ai.tool.name"] for s in tools if s["status"] == "ERROR")
        longest, run = 1, 1                           # longest run of identical consecutive calls
        for prev, cur in zip(tools, tools[1:]):
            same = (prev["attributes"]["gen_ai.tool.name"], prev["attributes"]["tool.args"]) == \
                   (cur["attributes"]["gen_ai.tool.name"], cur["attributes"]["tool.args"])
            run = run + 1 if same else 1
            longest = max(longest, run)
        root = next(s for s in spans if s["parent_id"] is None)
        tokens = sum(s["attributes"].get("gen_ai.usage.input_tokens", 0) +
                     s["attributes"].get("gen_ai.usage.output_tokens", 0) for s in spans)
        flags = []
        if len(tools) > max_toolcalls:
            flags.append("too_many_toolcalls")
        if longest > max_repeat:
            flags.append(f"loop(x{longest})")
        if errors:
            flags.append("tool_errors")
        report[tid] = {"n_spans": len(spans), "n_toolcalls": len(tools), "calls": dict(calls),
                       "errors": dict(errors), "longest_repeat": longest, "total_tokens": tokens,
                       "wall_s": round(root["end"] - root["start"], 2), "flags": flags}
    return report


def main() -> None:
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "spans.jsonl"
        clock = FakeClock()
        tr = Tracer(path, clock)
        run_episode(tr, clock, "trace-healthy", looping=False)
        run_episode(tr, clock, "trace-looping", looping=True)
        lines = path.read_text().splitlines()
        print(f"wrote {len(lines)} spans; first span line:\n  {lines[0]}\n")
        report = grade_traces(path)
    for tid, r in report.items():
        print(f"{tid}:")
        for k, v in r.items():
            print(f"  {k:<15} {v}")
    assert report["trace-healthy"]["flags"] == []
    assert report["trace-looping"]["n_toolcalls"] == 7 and report["trace-looping"]["longest_repeat"] == 5
    assert report["trace-looping"]["errors"] == {"fetch": 2}


if __name__ == "__main__":
    main()
