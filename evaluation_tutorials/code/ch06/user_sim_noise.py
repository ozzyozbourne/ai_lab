"""How much of an agent's score is the user simulator's fault?

Section 6.5 (#user-sim) of Chapter 6.  Run:  python3 code/ch06/user_sim_noise.py

Reuses mini_taubench.py's retail DB, tasks, tools and grader (v2: hash + required outputs).
The simulator now makes mistakes with probability eps per opportunity:

  * drop a constraint: the first message omits the refund/cancel reason, and
  * end early: instead of answering a confirmation request it says "bye" and leaves.

The agents here *listen*: they parse the order id and reason from the user's message rather than
reading the hidden task, so simulator errors reach the score.  For each eps we run 400 seeded
"runs" (5 tasks x 8 trials = 40 episodes each) and report the mean score, the SD across runs,
and an audit: a failure is simulator-caused if the same deterministic agent passes that task when
the episode is replayed with a perfect (eps = 0) simulator.
"""
from __future__ import annotations

import json
import random
import re

import numpy as np

from mini_taubench import TASKS, RetailEnv, Task, calculate_reward, do_write, say, tool


class NoisyUserSim:
    def __init__(self, task: Task, eps: float, rng: random.Random) -> None:
        self.task, self.eps, self.rng = task, eps, rng
        self.errors = 0

    def first_message(self) -> str:
        t = self.task
        if t.request == "status":
            return f"Hi, what is the status of order {t.order_id}?"
        if self.rng.random() < self.eps:                 # drops a constraint
            self.errors += 1
            return f"Hi, please {t.request} order {t.order_id}."
        return f"Hi, please {t.request} order {t.order_id}. Reason: {t.reason}."

    def reply(self, agent_msg: str) -> str:
        if "confirm" in agent_msg.lower():
            if self.rng.random() < self.eps:             # ends the conversation early
                self.errors += 1
                return "bye"
            return "yes"
        return "ok, thanks"


def parse(msg: str) -> tuple[str, str, str]:
    order = re.search(r"order (W\d+)", msg).group(1)
    request = "status" if "status" in msg else ("cancel" if "cancel" in msg else "refund")
    m = re.search(r"Reason: ([\w ]+)\.", msg)
    return request, order, (m.group(1) if m else "")


def listening_correct(task: Task, env: RetailEnv, user: NoisyUserSim, log: list) -> None:
    """Follows the policy, but only knows what the user said."""
    request, oid, reason = parse(log[0][1])
    order = json.loads(tool(env, log, "get_order", order_id=oid))
    if request == "status":
        say(log, f"Order {oid} is {order['status']}.")
        return
    ok = order["status"] == "pending" if request == "cancel" else (
        order["status"] == "delivered" and reason in {"damaged", "wrong_item"})
    if not ok:
        say(log, f"Sorry, I cannot {request} order {oid} under our policy.")
        return
    answer = user.reply(say(log, f"I will {request} order {oid}. Please confirm (yes/no)."))
    log.append(("user", answer))
    if answer == "yes":
        do_write(Task(task.tid, oid, request, reason, []), env, log)
        say(log, "Done.")


def listening_sloppy(task: Task, env: RetailEnv, user: NoisyUserSim, log: list) -> None:
    """No policy check, no confirmation; writes whatever it heard."""
    request, oid, reason = parse(log[0][1])
    order = json.loads(tool(env, log, "get_order", order_id=oid))
    if request == "status":
        say(log, f"Your order is {order['status']}.")
        return
    do_write(Task(task.tid, oid, request, reason, []), env, log)
    say(log, "All done! Anything else?")


def episode(agent, task: Task, eps: float, rng: random.Random) -> tuple[float, int]:
    env, log = RetailEnv(), []
    user = NoisyUserSim(task, eps, rng)
    log.append(("user", user.first_message()))
    agent(task, env, user, log)
    return calculate_reward(task, env, log, task.outputs_v2), user.errors


def main() -> None:
    agents = {"correct": listening_correct, "sloppy": listening_sloppy}
    clean = {a: [episode(f, t, 0.0, random.Random(0))[0] for t in TASKS] for a, f in agents.items()}
    print("perfect simulator (eps = 0):", {a: f"{np.mean(v):.0%}" for a, v in clean.items()})
    assert clean == {"correct": [1, 1, 1, 1, 1], "sloppy": [1, 1, 0, 0, 1]}

    print(f"\n{'agent':<8} {'eps':>5} {'mean':>7} {'SD across runs':>15} {'failures':>9} {'sim-caused':>11}")
    res = {}
    for aname, agent in agents.items():
        for eps in (0.0, 0.05, 0.1, 0.2):
            rng = random.Random(1000 + int(eps * 100))
            run_scores, fails, sim_fails = [], 0, 0
            for _ in range(400):
                s = []
                for t_idx, task in enumerate(TASKS):
                    for _ in range(8):
                        r, _errs = episode(agent, task, eps, rng)
                        s.append(r)
                        if r == 0:
                            fails += 1
                            sim_fails += clean[aname][t_idx] == 1     # passes with a perfect simulator
                run_scores.append(np.mean(s))
            m, sd = float(np.mean(run_scores)), float(np.std(run_scores, ddof=1))
            share = sim_fails / fails if fails else 0.0
            res[(aname, eps)] = (m, sd, share)
            print(f"{aname:<8} {eps:>5.2f} {m:>7.1%} {100 * sd:>12.1f} pt {fails:>9} {share:>10.0%}")
        print()

    # Expected loss for the correct agent: T1 (cancel) fails if the user leaves at the confirmation
    # (eps); T2 (refund) fails if the reason is dropped or the user leaves (1 - (1 - eps)^2).
    # At eps = 0.2 that is (0.2 + 0.36) / 5 = 11.2 points; every one of its failures is the simulator's.
    assert res[("correct", 0.0)] == (1.0, 0.0, 0.0)
    assert abs(res[("correct", 0.2)][0] - 0.888) < 0.01 and res[("correct", 0.2)][2] == 1.0
    assert res[("correct", 0.2)][1] > res[("correct", 0.05)][1] > 0
    # The sloppy agent never asks for confirmation, so only the dropped reason on T2 hurts it (eps / 5).
    assert abs(res[("sloppy", 0.2)][0] - 0.56) < 0.01 and res[("sloppy", 0.2)][2] < 0.15
    gap0 = res[("correct", 0.0)][0] - res[("sloppy", 0.0)][0]
    gap2 = res[("correct", 0.2)][0] - res[("sloppy", 0.2)][0]
    print(f"correct - sloppy gap: {100 * gap0:.1f} pts at eps = 0, {100 * gap2:.1f} pts at eps = 0.2")
    print("-> simulator errors penalise the agent that talks to the user most, shrink the gap and add variance.")


if __name__ == "__main__":
    main()
