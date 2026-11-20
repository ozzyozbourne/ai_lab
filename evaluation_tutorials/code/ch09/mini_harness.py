"""An Inspect-shaped eval harness in ~150 lines: Sample, Task(dataset, solver, scorer), async runner.

Chapter 9, section 9.2 (Anatomy of a harness). Every eval tool is this loop:
dataset -> solver -> scorer -> log -> metric.
Run:  python3 code/ch09/mini_harness.py   (from any directory)
Expected key output: 40 samples x 3 epochs, accuracy 0.708, naive stderr 0.042 vs clustered 0.049
(epochs of a sample clustered), the "pass"/"fail" scorer silently coerced to 0.000, and a JSONL log.
"""
from __future__ import annotations

import asyncio
import json
import math
import pathlib
import random
import re
import time
from dataclasses import asdict, dataclass, field
from typing import Awaitable, Callable

OUT = pathlib.Path(__file__).resolve().parent / "out"


@dataclass(frozen=True)
class Sample:                                   # Inspect: Sample(input, target, id, metadata)
    id: str
    input: str
    target: str
    metadata: dict = field(default_factory=dict)


@dataclass
class TaskState:                                # what the solver builds and the scorer reads
    sample: Sample
    epoch: int
    messages: list[dict] = field(default_factory=list)
    completion: str = ""


@dataclass
class Score:
    value: str | float                          # "C"/"I" like Inspect, or a float
    answer: str = ""
    explanation: str = ""


Solver = Callable[[TaskState], Awaitable[TaskState]]
Scorer = Callable[[TaskState, str], Awaitable[Score]]


@dataclass
class Task:
    dataset: list[Sample]
    solver: Solver
    scorer: Scorer
    epochs: int = 1
    name: str = "task"


class MockModel:
    """Seeded stand-in for an LLM. Per-category skill; per-(sample, epoch) RNG so that the
    output does not depend on the order in which concurrent coroutines happen to run."""

    SKILL = {"add": 0.95, "sub": 0.80, "mul": 0.60, "div": 0.40}

    def __init__(self, seed: int = 0, latency_s: float = 0.002):
        self.seed, self.latency_s = seed, latency_s

    async def generate(self, sample: Sample, epoch: int) -> str:
        rng = random.Random(f"{self.seed}:{sample.id}:{epoch}")
        await asyncio.sleep(self.latency_s * rng.random())          # pretend network latency
        if rng.random() < self.SKILL[sample.metadata["category"]]:
            return f"Let me compute. ANSWER: {sample.target}"
        return f"Let me compute. ANSWER: {int(sample.target) + rng.choice([-2, -1, 1, 10])}"


def generate(model: MockModel) -> Solver:       # the simplest solver: call the model once
    async def solve(state: TaskState) -> TaskState:
        state.messages.append({"role": "user", "content": state.sample.input})
        state.completion = await model.generate(state.sample, state.epoch)
        state.messages.append({"role": "assistant", "content": state.completion})
        return state
    return solve


def match_answer() -> Scorer:                   # like Inspect's pattern()/answer() scorers
    async def score(state: TaskState, target: str) -> Score:
        m = re.search(r"ANSWER:\s*(-?\d+)", state.completion)
        if not m:
            return Score("I", "", "invalid_response_format")
        return Score("C" if m.group(1) == target else "I", m.group(1))
    return score


def pass_fail_scorer() -> Scorer:               # a home-made scorer that returns "pass"/"fail"
    async def score(state: TaskState, target: str) -> Score:
        ok = (await match_answer()(state, target)).value == "C"
        return Score("pass" if ok else "fail")
    return score


def value_to_float(v: str | float) -> float:
    """Inspect-style conversion: C/I/P/N -> 1/0/0.5/0. Unknown strings become 0.0 silently."""
    if isinstance(v, (int, float)):
        return float(v)
    return {"C": 1.0, "I": 0.0, "P": 0.5, "N": 0.0}.get(v, 0.0)


async def run_task(task: Task, max_concurrency: int = 8, log_path: pathlib.Path | None = None):
    sem = asyncio.Semaphore(max_concurrency)
    in_flight = peak = 0

    async def one(sample: Sample, epoch: int) -> dict:
        nonlocal in_flight, peak
        async with sem:                                             # cap concurrent model calls
            in_flight += 1
            peak = max(peak, in_flight)
            state = await task.solver(TaskState(sample, epoch))
            sc = await task.scorer(state, sample.target)
            in_flight -= 1
        return {"task": task.name, "id": sample.id, "epoch": epoch,
                "category": sample.metadata["category"], "messages": state.messages,
                "score": asdict(sc), "value": value_to_float(sc.value)}

    jobs = [one(s, e) for e in range(task.epochs) for s in task.dataset]
    records = await asyncio.gather(*jobs)                           # results come back in job order
    if log_path:
        log_path.parent.mkdir(exist_ok=True)
        with log_path.open("w") as f:
            for r in records:
                f.write(json.dumps(r) + "\n")
    return records, peak


def accuracy_and_stderr(records: list[dict]) -> tuple[float, float, float]:
    """Mean over all (sample, epoch) rows; naive SE treats rows as independent, the
    clustered SE treats epochs of the same sample as one cluster (Chapter 5)."""
    v = [r["value"] for r in records]
    n, mean = len(v), sum(v) / len(v)
    sd = math.sqrt(sum((x - mean) ** 2 for x in v) / (n - 1))
    naive = sd / math.sqrt(n)
    clusters: dict[str, float] = {}
    for r in records:
        clusters[r["id"]] = clusters.get(r["id"], 0.0) + (r["value"] - mean)
    g = len(clusters)
    clustered = math.sqrt(g / (g - 1) * sum(c * c for c in clusters.values())) / n
    return mean, naive, clustered


def build_dataset(n_per_cat: int = 10, seed: int = 7) -> list[Sample]:
    rng, ops = random.Random(seed), {"add": "+", "sub": "-", "mul": "*", "div": "//"}
    out = []
    for cat, op in ops.items():
        for i in range(n_per_cat):
            a, b = rng.randint(10, 99), rng.randint(2, 9)
            out.append(Sample(f"{cat}-{i}", f"What is {a} {op} {b}? End with ANSWER: <n>",
                              str(eval(f"{a}{op}{b}")), {"category": cat}))
    return out


if __name__ == "__main__":
    model, data = MockModel(seed=0), build_dataset()
    task = Task(data, generate(model), match_answer(), epochs=3, name="arith")
    t0 = time.perf_counter()
    recs, peak = asyncio.run(run_task(task, max_concurrency=8, log_path=OUT / "arith.jsonl"))
    dt = time.perf_counter() - t0
    acc, se_naive, se_cl = accuracy_and_stderr(recs)
    print(f"samples={len(data)} epochs={task.epochs} rows={len(recs)} peak_concurrency={peak} "
          f"wall={'<1s' if dt < 1 else f'{dt:.1f}s'}")
    print(f"accuracy = {acc:.3f}   stderr naive = {se_naive:.3f}   stderr clustered = {se_cl:.3f}")
    print("per category:")
    for cat in MockModel.SKILL:
        vals = [r["value"] for r in recs if r["category"] == cat]
        print(f"  {cat:<4} {sum(vals) / len(vals):.3f}  (n={len(vals)})")
    # Re-run with a different concurrency: identical results (per-sample RNG, ordered gather).
    recs1, _ = asyncio.run(run_task(task, max_concurrency=1))
    assert [r["value"] for r in recs1] == [r["value"] for r in recs]
    # The silent-coercion trap: a scorer that returns "pass"/"fail" scores 0 everywhere.
    bad = Task(data, generate(model), pass_fail_scorer(), epochs=3, name="arith-passfail")
    bad_recs, _ = asyncio.run(run_task(bad))
    bad_acc = sum(r["value"] for r in bad_recs) / len(bad_recs)
    print(f"same model, scorer returning 'pass'/'fail': accuracy = {bad_acc:.3f}  <- silent coercion")
    print(f"log: out/arith.jsonl ({len(recs)} lines); first record keys: {sorted(recs[0])}")
    assert bad_acc == 0.0 and se_cl > se_naive
    assert abs(acc - 0.708) < 1e-3 and abs(se_cl - 0.049) < 1e-3, (acc, se_cl)
