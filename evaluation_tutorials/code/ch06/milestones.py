"""Milestones and progress rate: partial credit that says *where* agents fail.

Section 6.4 (#trajectory) of Chapter 6.  Run:  python3 code/ch06/milestones.py

Milestones are predicates over environment states (ToolSandbox).  Our progress rate is the
largest fraction of milestones reached *in order* along the trajectory (a chain, the simplest
milestone DAG); AgentBoard's own progress rate is unordered (Part 3).

Part 1 scores three hand-written trajectories for the task "text Alice 'running late'"
(cellular must be on, Alice's number must be resolved, then the right message sent).
Part 2 simulates two agent versions with the same binary success rate but different failure
points; progress rate and per-milestone reach rates tell them apart.
Part 3 compares our ordered (prefix) progress with AgentBoard's unordered definition
r_t = max_{i<=t} f(s_i, g), where f is the fraction of subgoals the state satisfies, and adds a
ToolSandbox-style minefield (a message sent to anyone but Alice): any violation scores 0.
"""
from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Callable

State = dict
Milestone = tuple[str, Callable[[State], bool]]

MILESTONES: list[Milestone] = [
    ("cellular on", lambda s: s["cellular"]),
    ("contact resolved", lambda s: s.get("resolved_number") == "+33-600-000-111"),
    ("message sent", lambda s: ("+33-600-000-111", "running late") in s["sent"]),
]


def apply(state: State, action: tuple[str, str]) -> State:
    s = {**state, "sent": list(state["sent"])}
    name, arg = action
    if name == "set_cellular":
        s["cellular"] = arg == "on"
    elif name == "search_contacts":
        s["resolved_number"] = "+33-600-000-111" if arg == "Alice" else "+44-700-000-999"
    elif name == "send_message" and s["cellular"] and s.get("resolved_number"):
        s["sent"].append((s["resolved_number"], arg))
    return s


def progress(actions: list[tuple[str, str]]) -> tuple[float, int]:
    """Ordered milestone matching. Returns (progress rate, milestones reached)."""
    state: State = {"cellular": False, "sent": []}
    reached = 0
    for a in actions:
        state = apply(state, a)
        while reached < len(MILESTONES) and MILESTONES[reached][1](state):
            reached += 1
    return reached / len(MILESTONES), reached


def agentboard_progress(actions: list[tuple[str, str]]) -> float:
    """AgentBoard (arXiv:2401.13178, Sec. 2.2): best fraction of subgoals satisfied by any state so far."""
    state: State = {"cellular": False, "sent": []}
    best = 0.0
    for a in actions:
        state = apply(state, a)
        best = max(best, sum(m(state) for _, m in MILESTONES) / len(MILESTONES))
    return best


MINEFIELDS: list[Milestone] = [
    ("message to a wrong number", lambda s: any(num != "+33-600-000-111" for num, _ in s["sent"])),
]


def minefield_score(actions: list[tuple[str, str]]) -> tuple[float, bool]:
    """ToolSandbox-style: ordered progress, but 0 if any minefield is ever triggered."""
    state: State = {"cellular": False, "sent": []}
    hit = False
    for a in actions:
        state = apply(state, a)
        hit = hit or any(m(state) for _, m in MINEFIELDS)
    return (0.0 if hit else progress(actions)[0]), hit


TRAJECTORIES = {
    "complete": [("set_cellular", "on"), ("search_contacts", "Alice"), ("send_message", "running late")],
    "wrong text": [("set_cellular", "on"), ("search_contacts", "Alice"), ("send_message", "late")],
    "wrong contact": [("set_cellular", "on"), ("search_contacts", "Alicia"), ("send_message", "running late")],
    "forgot cellular": [("search_contacts", "Alice"), ("send_message", "running late")],
}

# Reaches every milestone in order, but texted the wrong person first.
WRONG_THEN_FIXED = [("set_cellular", "on"), ("search_contacts", "Alicia"), ("send_message", "running late"),
                    ("search_contacts", "Alice"), ("send_message", "running late")]


@dataclass
class AgentVersion:
    name: str
    p_step: tuple[float, float, float]     # P(reach milestone i | reached i-1)


def simulate(agent: AgentVersion, n: int, rng: random.Random) -> tuple[float, float, list[float]]:
    succ, prog, reach = 0, 0.0, [0, 0, 0]
    for _ in range(n):
        k = 0
        while k < 3 and rng.random() < agent.p_step[k]:
            reach[k] += 1
            k += 1
        succ += k == 3
        prog += k / 3
    return succ / n, prog / n, [r / n for r in reach]


def main() -> None:
    print("Part 1: hand-written trajectories")
    print(f"  {'trajectory':<16} {'binary success':>14} {'progress rate':>14}")
    res = {}
    for name, traj in TRAJECTORIES.items():
        rate, k = progress(traj)
        res[name] = rate
        print(f"  {name:<16} {int(k == 3):>14} {rate:>14.2f}")
    assert res == {"complete": 1.0, "wrong text": 2 / 3, "wrong contact": 1 / 3, "forgot cellular": 0.0}

    print("\nPart 2: two agent versions, 2,000 simulated episodes each (seed 0)")
    rng = random.Random(0)
    v1 = AgentVersion("v1", (0.90, 0.50, 0.40))
    v2 = AgentVersion("v2", (0.90, 0.80, 0.25))
    print(f"  {'version':<8} {'success':>8} {'progress':>9} {'reach m1':>9} {'reach m2':>9} {'reach m3':>9}")
    out = {}
    for v in (v1, v2):
        s, p, r = simulate(v, 2000, rng)
        out[v.name] = (s, p, r)
        print(f"  {v.name:<8} {s:>8.3f} {p:>9.3f}" + "".join(f"{x:>9.3f}" for x in r))
    # True success rates are 0.9*0.5*0.4 = 0.18 for both; the simulation is within noise.
    assert abs(out["v1"][0] - out["v2"][0]) < 0.03
    assert out["v2"][1] - out["v1"][1] > 0.05
    print("  -> same success rate; v2 resolves contacts far more often but fails at the last step.")

    print("\nPart 3: ordered prefix vs AgentBoard max-over-states vs minefield (any violation -> 0)")
    print(f"  {'trajectory':<16} {'binary':>6} {'ordered':>8} {'AgentBoard':>11} {'minefield':>10}")
    part3 = {}
    for name, traj in {**TRAJECTORIES, "wrong then fixed": WRONG_THEN_FIXED}.items():
        rate, k = progress(traj)
        ab = agentboard_progress(traj)
        mf, hit = minefield_score(traj)
        part3[name] = (rate, ab, mf)
        print(f"  {name:<16} {int(k == 3):>6} {rate:>8.2f} {ab:>11.2f} {mf:>10.2f}" + ("  (mine hit)" if hit else ""))
    assert part3["forgot cellular"][:2] == (0.0, 1 / 3)        # unordered credit for the resolved contact
    assert part3["wrong contact"][2] == 0.0                     # the wrong person got the text
    assert part3["wrong then fixed"] == (1.0, 1.0, 0.0)         # binary success, but a mine was stepped on
    print("  -> AgentBoard credits subgoals in any order; the minefield zeroes a 'success' that texted a stranger.")


if __name__ == "__main__":
    main()
