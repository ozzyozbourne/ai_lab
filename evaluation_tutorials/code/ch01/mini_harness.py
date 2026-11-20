"""A minimal eval harness: tasks, trials, graders, transcripts, aggregate +/- CI.

Chapter 1, section 1.2 (Anatomy of an eval).
Run:  python3 code/ch01/mini_harness.py   (from any directory)
Expected key output: 12 tasks x 5 trials, accuracy 0.467, task-level 95% CI with the t quantile
(11 df) [0.211, 0.723] (the z interval [0.239, 0.695] is too narrow at n = 12);
the exact_match tasks pass 0.200 although the model is right 0.445 of the time (grader brittleness).
A second run with a 10% mock infrastructure-error rate (7 of 60 calls fail) shows how the error policy moves the headline.
Also writes out/run_meta.json (seed, n_trials, graders, sha256 of the task list, timestamp).
"""
from __future__ import annotations

import datetime
import hashlib
import json
import math
import pathlib
import random
import re
from dataclasses import asdict, dataclass, field
from typing import Callable

OUT = pathlib.Path(__file__).resolve().parent / "out"


@dataclass(frozen=True)
class Task:                      # one test: input + success criteria
    id: str
    input: str
    target: str | list[str]
    metadata: dict = field(default_factory=dict)


@dataclass
class Grade:                     # one grader's verdict on one trial
    grader: str
    passed: bool
    detail: str = ""


@dataclass
class Trial:                     # one attempt at a task, with its transcript
    task_id: str
    trial: int
    output: str
    grades: list[Grade]
    status: str = "ok"           # "ok" or "error": did the INFRASTRUCTURE work?
    error: str = ""

    @property
    def passed(self) -> bool:    # combine graders: every grader must pass
        return self.status == "ok" and all(g.passed for g in self.grades)


class MockModel:
    """Seeded stand-in for an LLM: answers correctly with a per-task probability."""

    def __init__(self, seed: int = 0, error_rate: float = 0.0):
        self.rng = random.Random(seed)
        self.err_rng = random.Random(seed + 1)          # separate stream: errors leave answers unchanged
        self.error_rate = error_rate

    def generate(self, task: Task) -> str:
        p_correct = task.metadata["p_correct"]          # per-task difficulty
        good = task.target if isinstance(task.target, str) else ", ".join(task.target)
        if self.rng.random() < p_correct:
            out = self.rng.choice([f"The answer is {good}.", f"{good}", f"Sure! {good}"])
        else:
            out = self.rng.choice(["I am not sure.", "The answer is 41.", "Paris, maybe Lyon"])
        if self.err_rng.random() < self.error_rate:     # mock provider timeout / 5xx
            raise TimeoutError("mock API timeout")
        return out


def exact_match(task: Task, out: str) -> Grade:
    ok = out.strip().lower() == str(task.target).strip().lower()
    return Grade("exact_match", ok)


def regex_number(task: Task, out: str) -> Grade:
    nums = re.findall(r"-?\d+(?:\.\d+)?", out.replace(",", ""))
    ok = bool(nums) and float(nums[-1]) == float(task.target)   # last number wins
    return Grade("regex_number", ok, nums[-1] if nums else "no number")


def contains_all(task: Task, out: str) -> Grade:
    missing = [t for t in task.target if t.lower() not in out.lower()]
    return Grade("contains_all", not missing, f"missing={missing}")


def run_eval(tasks: list[Task], graders: dict[str, list[Callable]], model: MockModel,
             n_trials: int, log_path: pathlib.Path) -> list[Trial]:
    trials: list[Trial] = []
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as log:
        for task in tasks:
            for k in range(n_trials):                  # repeated trials: outputs vary
                try:
                    out = model.generate(task)
                    grades = [g(task, out) for g in graders[task.metadata["kind"]]]
                    trial = Trial(task.id, k, out, grades)
                except Exception as e:                 # infrastructure failed, not the model
                    trial = Trial(task.id, k, "", [], status="error", error=f"{type(e).__name__}: {e}")
                trials.append(trial)
                log.write(json.dumps({**asdict(trial), "passed": trial.passed}) + "\n")
    return trials


# Two-sided 95% t quantiles by degrees of freedom; the standard library has no t quantile function.
T95 = {4: 2.776, 9: 2.262, 11: 2.201, 19: 2.093, 29: 2.045}


def summarize(trials: list[Trial]) -> dict:
    by_task: dict[str, list[int]] = {}
    ok_by_task: dict[str, list[int]] = {}
    for t in trials:
        by_task.setdefault(t.task_id, []).append(int(t.passed))       # errors count as fails
        if t.status == "ok":
            ok_by_task.setdefault(t.task_id, []).append(int(t.passed))
    task_means = [sum(v) / len(v) for v in by_task.values()]
    n = len(task_means)                                # the unit of sampling is the TASK
    mean = sum(task_means) / n
    var = sum((m - mean) ** 2 for m in task_means) / (n - 1)
    se = math.sqrt(var / n)
    naive_se = math.sqrt(mean * (1 - mean) / len(trials))   # pretends trials are independent
    t_crit = T95.get(n - 1, 1.96)                      # z fallback: only valid for large n
    excl = [sum(v) / len(v) for v in ok_by_task.values()]
    return {"n_tasks": n, "n_trials": len(trials), "accuracy": mean, "se": se,
            "ci95_t": (mean - t_crit * se, mean + t_crit * se),
            "ci95_z": (mean - 1.96 * se, mean + 1.96 * se), "naive_se": naive_se,
            "error_rate": sum(t.status == "error" for t in trials) / len(trials),
            "acc_excl_errors": sum(excl) / len(excl)}


def write_run_meta(path: pathlib.Path, tasks: list[Task], graders: dict, seed: int, n_trials: int) -> str:
    """Sidecar reproducibility record: enough to tell whether two runs are comparable."""
    task_hash = hashlib.sha256(json.dumps([asdict(t) for t in tasks], sort_keys=True).encode()).hexdigest()
    meta = {"seed": seed, "n_trials": n_trials, "task_sha256": task_hash,
            "graders": {k: [g.__name__ for g in v] for k, v in graders.items()},
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}
    path.write_text(json.dumps(meta, indent=2))
    return task_hash


def build_tasks() -> list[Task]:
    rng = random.Random(42)
    specs = [("add", "What is 17 + 25?", "42", "number"), ("cap", "Capital of France?", "Paris", "exact"),
             ("mul", "What is 6 * 7?", "42", "number"), ("pets", "Name a cat and a dog.", ["cat", "dog"], "all"),
             ("sub", "What is 100 - 58?", "42", "number"), ("color", "Sky colour on a clear day?", "blue", "exact")]
    tasks = []
    for i in range(2):                                  # two copies with different difficulty
        for name, q, tgt, kind in specs:
            tasks.append(Task(f"{name}-{i}", q, tgt, {"kind": kind, "p_correct": round(rng.uniform(0.2, 0.95), 2)}))
    return tasks


if __name__ == "__main__":
    graders = {"number": [regex_number], "exact": [exact_match], "all": [contains_all]}
    trials = run_eval(build_tasks(), graders, MockModel(seed=7), n_trials=5, log_path=OUT / "transcripts.jsonl")
    task_hash = write_run_meta(OUT / "run_meta.json", build_tasks(), graders, seed=7, n_trials=5)
    s = summarize(trials)
    print(f"tasks={s['n_tasks']}  trials={s['n_trials']}  accuracy={s['accuracy']:.3f}")
    print(f"task-level SE={s['se']:.3f}  95% CI (t, 11 df)=[{s['ci95_t'][0]:.3f}, {s['ci95_t'][1]:.3f}]"
          f"  z-based=[{s['ci95_z'][0]:.3f}, {s['ci95_z'][1]:.3f}] (too narrow)")
    print(f"naive SE treating {s['n_trials']} trials as independent = {s['naive_se']:.3f} (too small)")
    tasks = {t.id: t for t in build_tasks()}
    print(f"{'grader kind':<12} {'mean p_correct':>15} {'observed pass':>14}")
    for kind in graders:
        ids = [i for i, t in tasks.items() if t.metadata["kind"] == kind]
        p_true = sum(tasks[i].metadata["p_correct"] for i in ids) / len(ids)
        obs = [t.passed for t in trials if t.task_id in ids]
        print(f"{kind:<12} {p_true:>15.3f} {sum(obs) / len(obs):>14.3f}")
    print("first transcript line:", (OUT / "transcripts.jsonl").read_text().splitlines()[0][:110], "...")
    print(f"run_meta.json written: seed=7 n_trials=5 task_sha256={task_hash[:12]}...")
    # Same model and seed, but 10% of calls hit a mock infrastructure error.
    e = summarize(run_eval(build_tasks(), graders, MockModel(seed=7, error_rate=0.10), n_trials=5,
                           log_path=OUT / "transcripts_with_errors.jsonl"))
    print(f"with 10% infra errors: error rate={e['error_rate']:.3f}  accuracy (errors=fail)={e['accuracy']:.3f}"
          f"  accuracy (errors excluded)={e['acc_excl_errors']:.3f}")
    assert s["n_trials"] == 60 and abs(s["accuracy"] - 28 / 60) < 1e-9
    assert abs(s["ci95_z"][0] - 0.239) < 1e-3 and abs(s["ci95_z"][1] - 0.695) < 1e-3
    assert abs(s["ci95_t"][0] - 0.2106) < 1e-3 and abs(s["ci95_t"][1] - 0.7227) < 1e-3
    assert s["error_rate"] == 0.0 and s["acc_excl_errors"] == s["accuracy"]
    assert abs(e["error_rate"] - 7 / 60) < 1e-9 and abs(e["accuracy"] - 25 / 60) < 1e-9
    assert abs(e["acc_excl_errors"] - 0.4708) < 1e-3
