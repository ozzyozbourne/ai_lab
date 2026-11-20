"""A multi-turn LLM environment with a tool, a turn limit and a weighted rubric, driven by mock policies.

Section 7.3 (#llm-envs) of Chapter 7.  Run:  python3 code/ch07/text_env.py

The structure mirrors the classic verifiers API (MultiTurnEnv with env_response / is_completed, and
Rubric(funcs, weights) in which a weight of 0.0 means "log it, do not train on it"), re-implemented in
the standard library with no model calls:
  * dataset    : 40 seeded arithmetic word problems (TaskData-like rows: prompt + answer)
  * protocol   : the model may write  CALL calc: <expr>  and the env answers  RESULT: <value>;
                 it ends the episode with  \\boxed{<answer>};  6 turns max (then truncated)
  * rubric     : correct (w=1.0), boxed_format (w=0.2), used_tool_when_needed (w=0.1)
                 plus zero-weight metrics: num_turns, num_tool_calls, truncated
Policies: "careful" (uses the tool), "mental" (answers at once, slips on big products),
          "rambler" (keeps calling the tool and never answers).
Expected key output: careful 1.300 mean reward, mental 0.975, rambler 0.100 (all of it from the tool bonus); rambler truncated 100%.
"""
from __future__ import annotations

import random
import re
from dataclasses import dataclass, field
from typing import Callable

MAX_TURNS = 6


@dataclass(frozen=True)
class TaskData:
    prompt: str
    answer: int
    a: int
    b: int
    c: int


@dataclass
class Trace:
    task: TaskData
    messages: list[tuple[str, str]] = field(default_factory=list)   # (role, text)
    truncated: bool = False
    rewards: dict[str, float] = field(default_factory=dict)
    metrics: dict[str, float] = field(default_factory=dict)
    reward: float = 0.0


def make_dataset(n: int = 40, seed: int = 0) -> list[TaskData]:
    rng = random.Random(seed)
    rows = []
    for _ in range(n):
        a, b, c = rng.randint(12, 99), rng.randint(12, 99), rng.randint(1, 50)
        rows.append(TaskData(f"A crate holds {a} boxes of {b} pens. {c} pens are removed. How many pens remain?",
                             a * b - c, a, b, c))
    return rows


# ---------------------------------------------------------------- environment (rollout protocol)
CALL_RE = re.compile(r"CALL calc:\s*([0-9+\-* ()]+)")
BOXED_RE = re.compile(r"\\boxed\{([^{}]*)\}")


class CalcEnv:
    def env_response(self, trace: Trace) -> str:
        """The environment's turn: execute a tool call if the last message contains one."""
        last = trace.messages[-1][1]
        m = CALL_RE.search(last)
        if not m:
            return "No tool call found. Answer with \\boxed{...} or call the calculator."
        expr = m.group(1)
        return f"RESULT: {eval(expr, {'__builtins__': {}})}"   # the regex allows only digits and + - * ( )

    def is_completed(self, trace: Trace) -> bool:
        if BOXED_RE.search(trace.messages[-1][1]):
            return True
        if sum(r == "assistant" for r, _ in trace.messages) >= MAX_TURNS:
            trace.truncated = True          # stopped by the harness, not by the task: report it separately
            return True
        return False

    def rollout(self, task: TaskData, policy: Callable[[Trace], str]) -> Trace:
        trace = Trace(task, [("user", task.prompt)])
        while True:
            trace.messages.append(("assistant", policy(trace)))
            if self.is_completed(trace):
                return trace
            trace.messages.append(("env", self.env_response(trace)))


# ---------------------------------------------------------------- rubric
def last_boxed(trace: Trace) -> str | None:
    found = [m for r, t in trace.messages if r == "assistant" for m in BOXED_RE.findall(t)]
    return found[-1].strip() if found else None


def correct(trace: Trace) -> float:
    return float(last_boxed(trace) == str(trace.task.answer))


def boxed_format(trace: Trace) -> float:
    return float(last_boxed(trace) is not None)


def used_tool_when_needed(trace: Trace) -> float:
    return float(any(r == "env" and t.startswith("RESULT") for r, t in trace.messages))


def num_turns(trace: Trace) -> float:
    return float(sum(r == "assistant" for r, _ in trace.messages))


def num_tool_calls(trace: Trace) -> float:
    return float(sum(r == "assistant" and "CALL calc" in t for r, t in trace.messages))


def truncated(trace: Trace) -> float:
    return float(trace.truncated)


class Rubric:
    def __init__(self, funcs: list[Callable[[Trace], float]], weights: list[float]):
        assert len(funcs) == len(weights)
        self.funcs, self.weights = funcs, weights

    def score(self, trace: Trace) -> Trace:
        for f, w in zip(self.funcs, self.weights):
            (trace.rewards if w != 0 else trace.metrics)[f.__name__] = f(trace)
        trace.reward = sum(w * f(trace) for f, w in zip(self.funcs, self.weights))
        return trace


RUBRIC = Rubric(funcs=[correct, boxed_format, used_tool_when_needed, num_turns, num_tool_calls, truncated],
                weights=[1.0, 0.2, 0.1, 0.0, 0.0, 0.0])


# ---------------------------------------------------------------- mock policies (no LLM)
def careful(trace: Trace) -> str:
    t, turn = trace.task, num_turns(trace)
    if turn == 0:
        return f"I need {t.a} times {t.b} first. CALL calc: {t.a}*{t.b}"
    if turn == 1:
        prod = int(trace.messages[-1][1].split()[-1])
        return f"Now subtract. CALL calc: {prod}-{t.c}"
    return f"The answer is \\boxed{{{trace.messages[-1][1].split()[-1]}}}"


def make_mental(seed: int) -> Callable[[Trace], str]:
    rng = random.Random(seed)

    def mental(trace: Trace) -> str:
        t = trace.task
        guess = t.a * t.b - t.c
        if t.a * t.b > 3000 and rng.random() < 0.5:   # slips on large products
            guess += rng.choice([-10, 10, -100, 100])
        return f"Easy: \\boxed{{{guess}}}"
    return mental


def rambler(trace: Trace) -> str:
    return f"Let me double-check. CALL calc: {trace.task.a}*{trace.task.b}"


def main() -> None:
    data, env = make_dataset(), CalcEnv()
    t0 = RUBRIC.score(env.rollout(data[0], careful))
    print("One rollout (policy=careful)")
    for role, text in t0.messages:
        print(f"  {role:>9}: {text}")
    print(f"  rewards={t0.rewards} metrics={t0.metrics} -> reward={t0.reward:.2f}\n")

    policies = {"careful": careful, "mental": make_mental(1), "rambler": rambler}
    print(f"{'policy':<9} {'reward':>7} {'correct':>8} {'format':>7} {'tool':>5} | {'turns':>5} {'calls':>5} {'trunc':>6}")
    summary = {}
    for name, pol in policies.items():
        traces = [RUBRIC.score(env.rollout(t, pol)) for t in data]
        avg = lambda k, src: sum(getattr(tr, src)[k] for tr in traces) / len(traces)  # noqa: E731
        summary[name] = (sum(tr.reward for tr in traces) / len(traces), avg("truncated", "metrics"))
        print(f"{name:<9} {summary[name][0]:7.3f} {avg('correct', 'rewards'):8.3f} {avg('boxed_format', 'rewards'):7.3f} "
              f"{avg('used_tool_when_needed', 'rewards'):5.2f} | {avg('num_turns', 'metrics'):5.2f} "
              f"{avg('num_tool_calls', 'metrics'):5.2f} {avg('truncated', 'metrics'):6.0%}")
    assert abs(summary["careful"][0] - 1.3) < 1e-9
    assert abs(summary["rambler"][0] - 0.1) < 1e-9 and summary["rambler"][1] == 1.0
    assert abs(summary["mental"][0] - 0.975) < 1e-9


if __name__ == "__main__":
    main()
