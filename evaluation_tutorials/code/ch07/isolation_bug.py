"""Trial isolation: a shared working directory lets later trials read earlier trials' output.

Section 7.6 (#env-qa) of Chapter 7.  Run:  python3 code/ch07/isolation_bug.py

A mock harness runs 5 trials on each of 30 tasks. In every trial the agent must write the answer to
answer.txt in its working directory; the grader reads that file. The mock agent is a weak model that
solves a task with probability 0.3, but it also lists its directory first (as real agents do with `ls`,
`git log`, `find`) and copies any answer it finds there, like the git-history leak Anthropic reported.
  shared  : all trials of a task reuse one directory (the bug; the validation "oracle" run also happens there)
  isolated: each trial gets a fresh tempfile.TemporaryDirectory() and the grader reads only that directory
Expected key output: the shared harness reports pass@1 = 1.000 (the oracle's file is always there);
the isolated harness reports 0.280, close to the agent's real skill of 0.3; without the oracle file the
shared directory still leaks: pass rate by trial index climbs 0.30 -> 0.93.
"""
from __future__ import annotations

import pathlib
import random
import tempfile

N_TASKS, N_TRIALS, SKILL = 30, 5, 0.3


def task_answer(task: int) -> str:
    return str(1000 + 7 * task)


def oracle(workdir: pathlib.Path, task: int) -> None:
    (workdir / "answer.txt").write_text(task_answer(task))


def agent(workdir: pathlib.Path, task: int, rng: random.Random) -> None:
    existing = sorted(p.name for p in workdir.iterdir())            # the agent explores its environment
    if "answer.txt" in existing:
        return                                                       # "the answer is already here"
    for name in existing:
        if name.startswith("trial_") and name.endswith(".log"):
            text = (workdir / name).read_text()
            if "score=1.0" in text:                                  # a previous trial that passed
                (workdir / "answer.txt").write_text(text.split("ANSWER=")[1].strip())
                return
    ans = task_answer(task) if rng.random() < SKILL else str(rng.randint(0, 999))
    (workdir / "answer.txt").write_text(ans)


def grade(workdir: pathlib.Path, task: int) -> float:
    f = workdir / "answer.txt"
    return float(f.exists() and f.read_text().strip() == task_answer(task))


def run(shared: bool, seed: int = 0) -> float:
    rng = random.Random(seed)
    scores = []
    with tempfile.TemporaryDirectory() as root_s:
        root = pathlib.Path(root_s)
        for task in range(N_TASKS):
            if shared:
                wd = root / f"task_{task}"
                wd.mkdir()
                oracle(wd, task)                                     # gold check run in the same directory
                assert grade(wd, task) == 1.0
            for trial in range(N_TRIALS):
                if shared:
                    agent(wd, task, rng)
                    s = grade(wd, task)
                    (wd / f"trial_{trial}.log").write_text(f"score={s} ANSWER={(wd / 'answer.txt').read_text()}")
                else:
                    with tempfile.TemporaryDirectory(dir=root) as fresh:    # fresh, empty, deleted afterwards
                        wd_i = pathlib.Path(fresh)
                        agent(wd_i, task, rng)
                        s = grade(wd_i, task)
                scores.append(s)
    return sum(scores) / len(scores)


def run_shared_no_oracle(seed: int = 0) -> list[float]:
    """Same bug without the oracle file: trial logs alone leak answers once any trial succeeds."""
    rng = random.Random(seed)
    per_trial = [0.0] * N_TRIALS
    with tempfile.TemporaryDirectory() as root_s:
        for task in range(N_TASKS):
            wd = pathlib.Path(root_s) / f"task_{task}"
            wd.mkdir()
            for trial in range(N_TRIALS):
                if (wd / "answer.txt").exists() and grade(wd, task) == 0:
                    (wd / "answer.txt").unlink()                     # harness "cleans up" only failed answers
                agent(wd, task, rng)
                s = grade(wd, task)
                per_trial[trial] += s / N_TASKS
                (wd / f"trial_{trial}.log").write_text(f"score={s} ANSWER={(wd / 'answer.txt').read_text()}")
    return per_trial


def main() -> None:
    shared, isolated = run(shared=True), run(shared=False)
    print(f"{N_TASKS} tasks x {N_TRIALS} trials, agent's true solve rate {SKILL}")
    print(f"  shared working dir (oracle ran there first) : pass@1 = {shared:.3f}")
    print(f"  fresh TemporaryDirectory per trial          : pass@1 = {isolated:.3f}")
    per_trial = run_shared_no_oracle()
    print("  shared dir, no oracle file, pass rate by trial index: " + " ".join(f"{x:.2f}" for x in per_trial))
    print("  (a rising curve over trial index on a fixed task set is a contamination alarm)")
    assert shared == 1.0 and abs(isolated - SKILL) < 0.1
    assert per_trial[-1] > per_trial[0] + 0.3


if __name__ == "__main__":
    main()
