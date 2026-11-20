"""A CI regression gate with a capability floor, and graduating saturated tasks.

Chapter 1, section 1.8 (Eval-driven development).
Golden set: data/golden.jsonl (15 regression + 25 capability tasks). Gate config: data/baseline.json.
Gate rule:
  1. every regression task must pass every one of its trials (regression suites sit near 100%);
  2. the 95% Wilson LOWER bound of capability accuracy must be >= capability_floor.
     We use n = number of capability TASKS, not trials, because trials of one task are
     correlated (conservative; Chapter 5 does this properly with clustered SEs).
Run:  python3 code/ch01/regression_gate.py      (exit code 0; the three verdicts are asserted)
Expected key output: v2 PASS, v3 FAIL (regression reg-format-*), v4 FAIL (capability lower bound
below the 0.40 floor); 7 capability tasks graduate after v2 ships.
"""
from __future__ import annotations

import json
import math
import pathlib
import random
from dataclasses import dataclass

HERE = pathlib.Path(__file__).resolve().parent
TRIALS = {"regression": 3, "capability": 5}

# Mock systems: probability of solving a task, per skill. v1 is the shipped release.
SYSTEMS = {
    "v1": {"arithmetic": 1.0, "lookup": 1.0, "format": 1.0, "multi_step": 0.70, "ambiguous": 0.50, "long_context": 0.60},
    "v2": {"arithmetic": 1.0, "lookup": 1.0, "format": 1.0, "multi_step": 0.90, "ambiguous": 0.60, "long_context": 0.70},
    "v3": {"arithmetic": 1.0, "lookup": 1.0, "format": 0.80, "multi_step": 0.95, "ambiguous": 0.70, "long_context": 0.75},
    "v4": {"arithmetic": 1.0, "lookup": 1.0, "format": 1.0, "multi_step": 0.50, "ambiguous": 0.30, "long_context": 0.40},
}


@dataclass
class GateResult:
    version: str
    passed: bool
    regression_failures: list[str]
    cap_accuracy: float
    cap_lower: float
    per_task: dict[str, float]


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def mock_system(version: str, task: dict, trial: int) -> str:
    rng = random.Random(f"{version}:{task['id']}:{trial}")      # string seeds are deterministic
    return task["target"] if rng.random() < SYSTEMS[version][task["skill"]] else "WRONG"


def wilson_lower(p: float, n: int, z: float = 1.96) -> float:
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    return centre - z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom


def run_gate(version: str, tasks: list[dict], floor: float) -> GateResult:
    per_task: dict[str, float] = {}
    for t in tasks:
        k = TRIALS[t["suite"]]
        per_task[t["id"]] = sum(mock_system(version, t, i) == t["target"] for i in range(k)) / k
    reg_fail = [t["id"] for t in tasks if t["suite"] == "regression" and per_task[t["id"]] < 1.0]
    cap = [per_task[t["id"]] for t in tasks if t["suite"] == "capability"]
    acc = sum(cap) / len(cap)
    lower = wilson_lower(acc, len(cap))
    return GateResult(version, not reg_fail and lower >= floor, reg_fail, acc, lower, per_task)


def graduate(tasks: list[dict], results: list[GateResult]) -> list[str]:
    """Capability tasks solved on EVERY trial by every listed release move to the regression suite."""
    return [t["id"] for t in tasks if t["suite"] == "capability"
            and all(r.per_task[t["id"]] == 1.0 for r in results)]


def main() -> dict[str, GateResult]:
    tasks = load_jsonl(HERE / "data" / "golden.jsonl")
    floor = json.loads((HERE / "data" / "baseline.json").read_text())["capability_floor"]
    n_reg = sum(t["suite"] == "regression" for t in tasks)
    print(f"golden set: {n_reg} regression + {len(tasks) - n_reg} capability tasks; capability floor = {floor}")
    print(f"{'version':<8} {'verdict':<8} {'cap acc':>8} {'95% lower':>10}  regression failures")
    results = {}
    for v in SYSTEMS:
        r = run_gate(v, tasks, floor)
        results[v] = r
        print(f"{v:<8} {'PASS' if r.passed else 'FAIL':<8} {r.cap_accuracy:>8.3f} {r.cap_lower:>10.3f}  "
              f"{', '.join(r.regression_failures) or '-'}")

    grads = graduate(tasks, [results["v2"]])
    print(f"\ncapability tasks v2 solved on 5/5 trials -> graduate to regression: {grads}")
    out = HERE / "out"
    out.mkdir(exist_ok=True)
    with (out / "golden_next.jsonl").open("w") as f:
        for t in tasks:
            f.write(json.dumps({**t, "suite": "regression" if t["id"] in grads else t["suite"]}) + "\n")
    print("wrote code/ch01/out/golden_next.jsonl (the next release's golden set)")
    return results | {"_grads": grads}  # type: ignore[operator]


if __name__ == "__main__":
    res = main()
    assert res["v1"].passed and res["v2"].passed
    assert not res["v3"].passed and res["v3"].regression_failures
    assert not res["v4"].passed and not res["v4"].regression_failures and res["v4"].cap_lower < 0.40
    assert len(res["_grads"]) == 7
