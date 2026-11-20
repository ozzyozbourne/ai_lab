"""Environment QA: a vf-validate / Harbor-Oracle style suite over an 11-task toy environment with seeded bugs.

Section 7.6 (#env-qa) of Chapter 7, Figure 7.6.  Run:  python3 code/ch07/validate_env.py

Each task has reset(seed) -> prompt, a gold (reference) solution, and a grader(prompt, answer) -> reward.
Seeded bugs (the kind found in real benchmarks):
  t03 wrong gold solution        t05 answer leaked in the prompt     t06 grader accepts the empty answer
  t07 prompt not determined by seed (global RNG)                      t08 flaky grader (fails gold 30% of the time)
  t09 spec says "comma-separated", grader demands spaces (spec-test inconsistency)
  t10 substring grader (passes any response that contains the answer somewhere)
Checks: gold == 1 (x20), no-op < 1, seed determinism, leakage scan, gold flakiness, a mock-policy pass rate over
16 samples (difficulty band; 0/16 flags a probably-broken task), and a "near-miss" mutation test (a mutated gold
answer must FAIL; catches graders that are too lenient), and a "kitchen-sink" spam probe (the prompt plus the gold
answer buried among near-miss candidates must FAIL; catches substring and list-all-answers graders, ABC's tau-bench finding).
Expected key output: 8 of 11 tasks flagged, each by the check designed for it (t04's lenient grader also shows
up as a saturated 16/16 band; t09 only as a 0/16 band); the 3 clean tasks pass everything.
"""
from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Callable

import numpy as np


@dataclass
class Task:
    tid: str
    make_prompt: Callable[[random.Random], tuple[str, str]]    # rng -> (prompt, hidden answer)
    gold: Callable[[str, str], str]                          # (prompt, hidden) -> reference answer
    grade: Callable[[str, str, str], float]                  # (prompt, hidden, answer) -> reward
    seeded: bool = True

    def reset(self, seed: int) -> tuple[str, str]:
        rng = random.Random(seed) if self.seeded else random.Random()   # bug: unseeded source
        return self.make_prompt(rng)


def sort_prompt(rng):
    xs = [rng.randint(0, 99) for _ in range(6)]
    return f"Sort ascending, comma-separated: {xs}", ",".join(map(str, sorted(xs)))


def exact(prompt, hidden, ans):
    return float(ans.strip() == hidden)


def rev_prompt(rng):
    w = "".join(rng.choice("abcdefgh") for _ in range(7))
    return f"Reverse the string '{w}'.", w[::-1]


def sum_prompt(rng):
    xs = [rng.randint(1, 50) for _ in range(5)]
    return f"Sum these numbers: {xs}", str(sum(xs))


def leak_prompt(rng):
    p, h = sum_prompt(rng)
    return p + f"  (debug: expected={h})", h          # bug: answer in observation


_flaky = random.Random(99)


def flaky_grade(prompt, hidden, ans):
    return exact(prompt, hidden, ans) if _flaky.random() > 0.3 else 0.0   # e.g. a sandbox timeout scored as 0


def lenient_grade(prompt, hidden, ans):
    return float(ans.strip() == "" or ans.strip() == hidden)   # bug: missing-file / empty output counts as pass


def spaced_grade(prompt, hidden, ans):
    return float(ans.strip() == hidden.replace(",", ", "))    # bug: contradicts the "comma-separated" spec


def contains_grade(prompt, hidden, ans):
    return float(hidden in ans)                               # bug: substring match, like tau-bench's database-text tasks


def prefix_grade(prompt, hidden, ans):
    return float(hidden.startswith(ans.strip()) and len(ans.strip()) > 0)  # bug: accepts any prefix


GOLD = lambda p, h: h  # noqa: E731

TASKS = [
    Task("t00", sort_prompt, GOLD, exact),
    Task("t01", rev_prompt, GOLD, exact),
    Task("t02", sum_prompt, GOLD, exact),
    Task("t03", sum_prompt, lambda p, h: str(int(h) + 1), exact),          # wrong gold
    Task("t04", rev_prompt, GOLD, exact),
    Task("t05", leak_prompt, GOLD, exact),
    Task("t06", sort_prompt, GOLD, lenient_grade),
    Task("t07", rev_prompt, GOLD, exact, seeded=False),
    Task("t08", sum_prompt, GOLD, flaky_grade),
    Task("t09", sort_prompt, lambda p, h: h.replace(",", ", "), spaced_grade),
    Task("t10", sum_prompt, GOLD, contains_grade),                         # substring grader, caught only by spam
]
TASKS[4] = Task("t04", rev_prompt, GOLD, prefix_grade)       # lenient prefix grader, caught by the mutation test


def mock_policy(prompt: str, hidden: str, rng: random.Random) -> str:
    """A decent model: follows the spec; right 70% of the time, otherwise makes a small mistake."""
    if rng.random() < 0.7:
        return hidden
    return hidden[:-1] if len(hidden) > 1 else hidden + "0"


def mutate(answer: str) -> str:
    """A near-miss: drop the last character (a correct grader must reject it)."""
    return answer[:-1]


def spam(prompt: str, answer: str) -> str:
    """A kitchen-sink response: the prompt plus the gold answer buried among many near-miss candidates."""
    cands = [answer[:-1], answer + "0", answer[::-1], answer, answer[1:], "0", "1"]
    return prompt + "\nCandidates: " + " | ".join(cands)


def validate(task: Task) -> dict[str, str]:
    r = {}
    golds = []
    for s in range(20):
        p, h = task.reset(s)
        golds.append(task.grade(p, h, task.gold(p, h)))
    r["gold=1"] = "ok" if min(golds) == 1 else ("FLAKY" if max(golds) == 1 else "FAIL")
    noop = [task.grade(*task.reset(s), "") for s in range(5)]
    r["noop<1"] = "ok" if max(noop) < 1 else "FAIL"
    same = all(task.reset(s) == task.reset(s) for s in range(5))
    r["determ"] = "ok" if same else "FAIL"
    leaks = [h in p for p, h in (task.reset(s) for s in range(5))]
    r["leak"] = "ok" if not any(leaks) else "FAIL"
    mut = [task.grade(p, h, mutate(task.gold(p, h))) for p, h in (task.reset(s) for s in range(5))]
    r["mutant"] = "ok" if max(mut) < 1 else "FAIL"
    prng = random.Random(int(task.tid[1:]))
    passes = sum(task.grade(p, h, mock_policy(p, h, prng)) for p, h in (task.reset(100 + s) for s in range(16)))
    r["policy"] = f"{int(passes)}/16"
    r["band"] = "ok" if 0 < passes < 16 else ("ZERO" if passes == 0 else "SAT")
    spr = [task.grade(p, h, spam(p, task.gold(p, h))) for p, h in (task.reset(s) for s in range(5))]
    r["spam"] = "ok" if max(spr) < 1 else "FAIL"
    return r


def main() -> None:
    cols = ["gold=1", "noop<1", "determ", "leak", "mutant", "spam", "policy", "band"]
    print(f"{'task':<5} " + " ".join(f"{c:>7}" for c in cols) + "  verdict")
    flagged, reports = {}, {}
    for t in TASKS:
        r = reports[t.tid] = validate(t)
        bad = [c for c in cols if c != "policy" and r[c] != "ok"]
        flagged[t.tid] = bad
        print(f"{t.tid:<5} " + " ".join(f"{r[c]:>7}" for c in cols) + "  " + ("clean" if not bad else "BROKEN: " + ", ".join(bad)))
    n_bad = sum(bool(v) for v in flagged.values())
    print(f"\n{n_bad}/{len(TASKS)} tasks flagged; clean tasks: {[k for k, v in flagged.items() if not v]}")
    rates = np.array([float(reports[t.tid]["policy"].split("/")[0]) / 16 for t in TASKS])
    print(f"mock-policy pass rate, all tasks {rates.mean():.3f} vs clean tasks only "
          f"{rates[[not flagged[t.tid] for t in TASKS]].mean():.3f} (the policy's true per-sample skill is 0.70)")
    assert abs(rates.mean() - 0.648) < 1e-3
    assert flagged["t03"][:1] == ["gold=1"] and "band" in flagged["t09"]
    assert "leak" in flagged["t05"] and "noop<1" in flagged["t06"] and "determ" in flagged["t07"]
    assert flagged["t08"][:1] == ["gold=1"] and flagged["t04"] == ["mutant", "band"]
    assert flagged["t10"] == ["spam"] and n_bad == 8
    assert [k for k, v in flagged.items() if not v] == ["t00", "t01", "t02"]


if __name__ == "__main__":
    main()
