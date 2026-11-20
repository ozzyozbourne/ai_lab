"""Environment QA: evaluate the environment before any agent (Section 10.5).

Checks (cf. verifiers' vf-validate --only-gold / --only-noop, Gymnasium's check_env, ABC's checklist):
    gold         the reference solution scores 1 on every task (solvable, grader accepts the right answer)
    null         a do-nothing agent scores 0 on every task (no free passes, e.g. impossible tasks)
    determinism  same seed -> identical transcript and state hash; different seeds -> some variation
    leakage      no observation contains grader-only data (task id, canary, gold actions)
    isolation    an episode never mutates the task's stored DB; a fresh reset restores the initial state
    user sim     gold (open-loop) AND an oracle agent (closed-loop: it must ask for identity, search, ...)
                 score 1 on every task under several env seeds; a failure is the simulator's, not an agent's
"""
from __future__ import annotations

import hashlib
import json

from .agents import GoldAgent, make_agent
from .env import ShopDeskEnv, state_hash
from .graders import grade_hardened


def episode(task: dict, agent, seed: int, bugs=frozenset(), reward_fn=grade_hardened):
    env = ShopDeskEnv(task, reward_fn=reward_fn, bugs=bugs)
    obs, _ = env.reset(seed=seed)
    agent.reset(seed + 1)
    observations = [obs]
    done, reward = False, 0.0
    while not done:
        obs, reward, term, trunc, _ = env.step(agent.act(obs))
        observations.append(obs)
        done = term or trunc
    return reward, env, observations


def _digest(env) -> str:
    return hashlib.sha256(json.dumps(env.transcript, sort_keys=True).encode()).hexdigest()[:12] + state_hash(env.db)


def check_gold(tasks, bugs=frozenset()) -> list[str]:
    return [t["id"] for t in tasks if episode(t, GoldAgent(t), 11, bugs)[0] != 1.0]


def check_null(tasks, bugs=frozenset()) -> list[str]:
    return [t["id"] for t in tasks if episode(t, make_agent("null"), 11, bugs)[0] != 0.0]


def check_determinism(tasks, agent_name: str = "v1", bugs=frozenset()) -> tuple[list[str], float]:
    bad, varied = [], 0
    for t in tasks:
        a = _digest(episode(t, make_agent(agent_name), 5, bugs)[1])
        b = _digest(episode(t, make_agent(agent_name), 5, bugs)[1])
        c = {_digest(episode(t, make_agent(agent_name), s, bugs)[1]) for s in (6, 7, 8)}
        if a != b:
            bad.append(t["id"])
        varied += len(c | {a}) > 1
    return bad, varied / len(tasks)


def hidden_strings(task: dict) -> list[str]:
    return [task["id"], task["canary"], "gold_actions"] + [g for g in task["gold_actions"]
                                                           if not g.startswith("send_message")]


def check_leakage(tasks, bugs=frozenset()) -> list[str]:
    bad = []
    for t in tasks:
        hidden = hidden_strings(t)
        for agent in (GoldAgent(t), make_agent("v2")):
            seen = json.dumps(episode(t, agent, 11, bugs)[2])
            if any(h in seen for h in hidden):
                bad.append(t["id"])
                break
    return bad


def check_isolation(tasks, bugs=frozenset()) -> list[str]:
    bad = []
    for t in tasks:
        before = json.dumps(t["db"], sort_keys=True)
        _, env, _ = episode(t, GoldAgent(t), 11, bugs)
        h0 = state_hash(t["db"])
        env.reset(seed=12)
        if json.dumps(t["db"], sort_keys=True) != before or state_hash(env.db) != h0:
            bad.append(t["id"])
    return bad


def check_user_sim(tasks, bugs=frozenset(), seeds=range(5)) -> list[str]:
    """The open-loop gold agent never asks the user anything, so it cannot catch a simulator that withholds
    facts or misreads questions; the oracle (every knob at 1) depends on the simulator's answers."""
    return [t["id"] for t in tasks if any(episode(t, a, 100 + s, bugs)[0] != 1.0
                                          for s in seeds for a in (GoldAgent(t), make_agent("oracle")))]


def run_qa(tasks, bugs=frozenset()) -> dict:
    det_bad, varied = check_determinism(tasks[::7], bugs=bugs)
    return {"gold = 1": (len(tasks), check_gold(tasks, bugs)),
            "null = 0": (len(tasks), check_null(tasks, bugs)),
            "determinism": (len(tasks[::7]), det_bad),
            "leakage scan": (len(tasks), check_leakage(tasks, bugs)),
            "isolation": (len(tasks), check_isolation(tasks, bugs)),
            "user sim x5": (len(tasks), check_user_sim(tasks, bugs)),
            "_seed_variation": varied}
