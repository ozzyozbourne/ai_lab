"""Infrastructure failures are not wrong answers: a judge that times out 10% of the time.

Section 7.10 (#at-scale) of Chapter 7.  Run:  python3 code/ch07/infra_vs_model_failure.py

2,000 rollouts with a known true accuracy of 0.70. An LLM-judge reward times out on 10% of calls, and more
often on long responses (long responses are also more often correct here: careful solutions are longer),
so failures are not missing-completely-at-random. Four policies for a timeout:
  zero    : the timeout becomes reward 0                      (the bug the verifiers docs warn about)
  exclude : drop timed-out rollouts, report the rest           (biased when timeouts depend on the response)
  retry3  : retry up to 3 times, then exclude and REPORT the infra-failure rate
  raise   : propagate the exception; the harness re-queues the rollout (equivalent to unlimited retries)
For RL it also counts correct rollouts that received reward 0, i.e. the ones a GRPO update would push DOWN.
Expected key output: true accuracy 0.697; zero reports 0.622 (-7.5 pts), exclude 0.688 (-0.9 pts, and 201 rollouts
silently missing), retry3 0.697 with 2 reported infra failures, raise 0.697; under "zero", 9.6% of correct rollouts
get reward 0 (a negative-advantage training signal), and they are the longer ones.
"""
from __future__ import annotations

import numpy as np

N, TRUE_ACC = 2000, 0.70


class JudgeTimeout(Exception):
    pass


def make_rollouts(rng: np.random.Generator):
    correct = rng.random(N) < TRUE_ACC
    length = np.where(correct, rng.normal(900, 250, N), rng.normal(600, 250, N)).clip(50, None)
    p_timeout = np.clip(0.10 * length / length.mean(), 0, 0.9)          # averages ~10%, more for long answers
    return correct, length, p_timeout


def judge(i: int, correct, p_timeout, rng) -> float:
    if rng.random() < p_timeout[i]:
        raise JudgeTimeout(f"judge call for rollout {i} exceeded 30 s")
    return float(correct[i])


def score(policy: str, correct, p_timeout, rng):
    rewards, infra_fail = [], 0
    for i in range(N):
        tries = {"zero": 1, "exclude": 1, "retry3": 3, "raise": 1000}[policy]
        for _ in range(tries):
            try:
                rewards.append(judge(i, correct, p_timeout, rng))
                break
            except JudgeTimeout:
                continue
        else:
            infra_fail += 1
            if policy == "zero":
                rewards.append(0.0)
    return np.array(rewards), infra_fail


def main() -> None:
    rng = np.random.default_rng(0)
    correct, length, p_timeout = make_rollouts(rng)
    print(f"{N} rollouts, true accuracy {correct.mean():.3f}, mean timeout prob {p_timeout.mean():.3f} "
          f"(correct {p_timeout[correct].mean():.3f}, wrong {p_timeout[~correct].mean():.3f})\n")
    print(f"{'policy':<8} {'reported':>9} {'bias (pts)':>11} {'scored n':>9} {'infra fails':>12}")
    out = {}
    for pol in ("zero", "exclude", "retry3", "raise"):
        r, fails = score(pol, correct, p_timeout, rng)
        out[pol] = r.mean()
        print(f"{pol:<8} {r.mean():9.3f} {100 * (r.mean() - correct.mean()):+11.1f} {len(r):9d} {fails:12d}")

    # RL view: under "zero", which correct rollouts are trained against?
    t = rng.random(N) < p_timeout
    hit = correct & t
    print(f"\nRL view (timeout -> 0): {hit.sum()} of {correct.sum()} correct rollouts ({hit.sum() / correct.sum():.1%}) "
          "receive reward 0, so GRPO assigns them a negative advantage;")
    print(f"they are {length[hit].mean():.0f} tokens long on average vs {length[correct & ~t].mean():.0f} for the rest: "
          "the policy is pushed toward shorter answers.")
    assert abs(out["zero"] - 0.622) < 1e-3 and abs(correct.mean() - 0.697) < 1e-3
    assert abs(out["raise"] - correct.mean()) < 0.03 and abs(out["retry3"] - correct.mean()) < 0.03
    assert out["exclude"] < correct.mean()


if __name__ == "__main__":
    main()
