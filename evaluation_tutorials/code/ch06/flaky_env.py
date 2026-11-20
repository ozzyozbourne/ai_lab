"""Flaky infrastructure vs agent failure: why an `infra_error` status matters.

Section 6.9 (#harness) of Chapter 6.  Run:  python3 code/ch06/flaky_env.py

300 tasks, an agent whose true success rate is known, 10 workers (sandbox hosts).
Two kinds of infrastructure fault:
  * random: each trial hits an HTTP 503 from a tool backend with probability 5%,
  * correlated: in each rerun every worker is independently "bad" with probability 10%
    (misconfigured, out of memory) and every trial it runs crashes.
Naive harness: any exception = agent failure.  Fixed harness: classify exceptions from the
infrastructure as status `infra_error`, retry them up to 3 times on a different worker, and
report the score over trials that finished plus the count of unrecoverable infra errors.
Expected key output: the naive score is biased low by about 8 points and varies far more across reruns;
the fixed harness recovers the true score.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass

import numpy as np

N_TASKS, N_WORKERS = 300, 10
P_503, P_BAD_WORKER = 0.05, 0.10


class InfraError(Exception):
    """Raised by the environment, not the agent: 503s, OOM-killed containers, timeouts of the host."""


@dataclass
class Trial:
    task: int
    status: str          # "pass" | "agent_fail" | "infra_error"
    attempts: int


def run_once(task: int, worker: int, p_task: np.ndarray, rng: np.random.Generator, bad: set[int]) -> bool:
    if worker in bad:
        raise InfraError("container OOM-killed")
    if rng.random() < P_503:
        raise InfraError("tool backend returned HTTP 503")
    return bool(rng.random() < p_task[task])


def naive_harness(p_task: np.ndarray, rng: np.random.Generator, bad: set[int]) -> list[Trial]:
    out = []
    for t in range(N_TASKS):
        try:
            ok = run_once(t, t % N_WORKERS, p_task, rng, bad)
            out.append(Trial(t, "pass" if ok else "agent_fail", 1))
        except InfraError:
            out.append(Trial(t, "agent_fail", 1))          # the bug: infra failure scored as agent failure
    return out


def fixed_harness(p_task: np.ndarray, rng: np.random.Generator, bad: set[int], max_retries: int = 3) -> list[Trial]:
    out = []
    for t in range(N_TASKS):
        worker, status = t % N_WORKERS, "infra_error"
        for attempt in range(1, max_retries + 2):
            try:
                ok = run_once(t, worker, p_task, rng, bad)
                status = "pass" if ok else "agent_fail"
                break
            except InfraError:
                worker = (worker + 1 + attempt) % N_WORKERS      # retry elsewhere
        out.append(Trial(t, status, attempt))
    return out


def score(trials: list[Trial]) -> tuple[float, int]:
    finished = [x for x in trials if x.status != "infra_error"]
    return sum(x.status == "pass" for x in finished) / len(finished), len(trials) - len(finished)


def main() -> None:
    rng = np.random.default_rng(7)
    p_task = rng.beta(3, 2, size=N_TASKS)                 # true per-task success probabilities
    truth = float(p_task.mean())
    print(f"true expected success rate: {truth:.3f}")

    naive_scores, fixed_scores, n_bad, total_unrec = [], [], [], 0
    for rerun in range(40):
        r = np.random.default_rng(100 + rerun)
        bad = {w for w in range(N_WORKERS) if r.random() < P_BAD_WORKER}
        n_bad.append(len(bad))
        naive_scores.append(score(naive_harness(p_task, r, bad))[0])
        fixed = fixed_harness(p_task, r, bad)
        s, unrec = score(fixed)
        fixed_scores.append(s)
        total_unrec += unrec
        if rerun == 0:
            c = Counter(x.status for x in fixed)
            retried = sum(x.attempts > 1 for x in fixed)
            print(f"rerun 0: bad workers {sorted(bad)}; fixed harness {dict(c)}; "
                  f"{retried} trials needed a retry")
    print(f"bad workers per rerun ranged from {min(n_bad)} to {max(n_bad)}; "
          f"unrecoverable infra errors over 40 reruns: {total_unrec}")
    ns, fs = np.array(naive_scores), np.array(fixed_scores)
    print(f"\n{'harness':<8} {'mean score':>10} {'bias':>7} {'SD across 40 reruns':>20}")
    print(f"{'naive':<8} {ns.mean():>10.3f} {ns.mean() - truth:>+7.3f} {ns.std(ddof=1):>20.4f}")
    print(f"{'fixed':<8} {fs.mean():>10.3f} {fs.mean() - truth:>+7.3f} {fs.std(ddof=1):>20.4f}")
    expected_naive = truth * (1 - P_BAD_WORKER) * (1 - P_503)
    print(f"\nnaive expectation ~ truth x (1 - 0.10) x (1 - 0.05) = {expected_naive:.3f}")
    assert abs(ns.mean() - expected_naive) < 0.02
    assert abs(fs.mean() - truth) < 0.01 and ns.mean() - truth < -0.05
    assert ns.std(ddof=1) > 1.5 * fs.std(ddof=1)


if __name__ == "__main__":
    main()
