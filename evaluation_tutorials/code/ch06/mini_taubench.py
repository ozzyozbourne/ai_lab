"""Mini tau-bench: state-hash grading, required outputs and the do-nothing agent.

Section 6.3 (#outcome) of Chapter 6.  Run:  python3 code/ch06/mini_taubench.py

A toy retail database (a dict), three tools (get_order, cancel_order, refund), a written policy,
a scripted user simulator and three mock agents (correct, sloppy, do-nothing).  Grading follows
tau-bench's calculate_reward: replay the gold actions on a fresh copy of the database, hash both
databases with sha256 over canonical JSON, and require that each string in task.outputs appears
in some agent reply (lower-cased, commas removed).

Grader v1 has no required outputs on the two impossible tasks, so the do-nothing agent "passes"
them (2/5 = 40%).  Grader v2 requires an explicit refusal ("cannot") and the score drops to 0/5.
A separate trajectory check (confirmation before every write) catches the sloppy agent.
"""
from __future__ import annotations

import copy
import hashlib
import json
from dataclasses import dataclass, field

POLICY = """1. Only pending orders can be cancelled.
2. Delivered orders can be refunded only if the reason is 'damaged' or 'wrong_item'.
3. Before any write action, list the action and obtain an explicit 'yes' from the user."""

INITIAL_DB = {
    "orders": {
        "W1": {"user": "alice", "status": "pending", "amount": 30.0, "refunded": False},
        "W2": {"user": "bob", "status": "delivered", "amount": 55.0, "refunded": False},
        "W3": {"user": "carol", "status": "delivered", "amount": 80.0, "refunded": False},
        "W4": {"user": "dave", "status": "delivered", "amount": 12.0, "refunded": False},
        "W5": {"user": "erin", "status": "shipped", "amount": 41.0, "refunded": False},
    }
}


# ---------------------------------------------------------------- environment and tools
class RetailEnv:
    WRITE_TOOLS = {"cancel_order", "refund"}

    def __init__(self) -> None:
        self.db = copy.deepcopy(INITIAL_DB)

    def step(self, name: str, **kw) -> str:
        order = self.db["orders"].get(kw.get("order_id", ""))
        if order is None:
            return "Error: order not found"
        if name == "get_order":
            return json.dumps(order, sort_keys=True)
        if name == "cancel_order":          # the tool enforces rule 1 ...
            if order["status"] != "pending":
                return "Error: order is not pending"
            order["status"] = "cancelled"
            return "OK"
        if name == "refund":                # ... but rule 2 lives only in the policy text
            order["refunded"], order["refund_reason"] = True, kw["reason"]
            return "OK"
        raise ValueError(name)

    def data_hash(self) -> str:
        return hashlib.sha256(json.dumps(self.db, sort_keys=True).encode()).hexdigest()


@dataclass
class Action:
    name: str
    kwargs: dict


@dataclass
class Task:
    tid: str
    order_id: str
    request: str            # what the simulated user wants
    reason: str
    gold: list[Action]      # annotated ground-truth write actions
    outputs_v1: list[str] = field(default_factory=list)
    outputs_v2: list[str] = field(default_factory=list)


TASKS = [
    Task("T1 cancel pending", "W1", "cancel", "no longer needed",
         [Action("cancel_order", {"order_id": "W1"})]),
    Task("T2 refund damaged", "W2", "refund", "damaged",
         [Action("refund", {"order_id": "W2", "reason": "damaged"})]),
    Task("T3 refund changed-mind", "W3", "refund", "changed_mind", [], [], ["cannot"]),   # impossible
    Task("T4 cancel delivered", "W4", "cancel", "too slow", [], [], ["cannot"]),           # impossible
    Task("T5 order status", "W5", "status", "", [], ["shipped"], ["shipped"]),
]


# ---------------------------------------------------------------- user simulator (scripted)
class UserSim:
    """Rule-based stand-in for tau-bench's LLM user: states the goal, confirms when asked."""

    def __init__(self, task: Task) -> None:
        self.task = task

    def first_message(self) -> str:
        t = self.task
        if t.request == "status":
            return f"Hi, what is the status of order {t.order_id}?"
        return f"Hi, please {t.request} order {t.order_id}. Reason: {t.reason}."

    def reply(self, agent_msg: str) -> str:
        return "yes" if "confirm" in agent_msg.lower() else "ok, thanks"


# ---------------------------------------------------------------- mock agents
def allowed(task: Task, order: dict) -> bool:
    if task.request == "cancel":
        return order["status"] == "pending"
    if task.request == "refund":
        return order["status"] == "delivered" and task.reason in {"damaged", "wrong_item"}
    return True


def correct_agent(task: Task, env: RetailEnv, user: UserSim, log: list) -> None:
    order = json.loads(tool(env, log, "get_order", order_id=task.order_id))
    if task.request == "status":
        say(log, f"Order {task.order_id} is {order['status']}.")
        return
    if not allowed(task, order):
        say(log, f"Sorry, I cannot {task.request} order {task.order_id} under our policy.")
        return
    answer = user.reply(say(log, f"I will {task.request} order {task.order_id}. Please confirm (yes/no)."))
    log.append(("user", answer))
    if answer == "yes":
        do_write(task, env, log)
        say(log, "Done.")


def sloppy_agent(task: Task, env: RetailEnv, user: UserSim, log: list) -> None:
    """Never checks the policy, never asks for confirmation, and claims success regardless."""
    order = json.loads(tool(env, log, "get_order", order_id=task.order_id))
    if task.request == "status":
        say(log, f"Your order is {order['status']}.")
        return
    do_write(task, env, log)
    say(log, "All done! Anything else?")


def do_nothing_agent(task: Task, env: RetailEnv, user: UserSim, log: list) -> None:
    say(log, "")


def tool(env: RetailEnv, log: list, name: str, **kw) -> str:
    out = env.step(name, **kw)
    log.append(("tool", Action(name, kw), out))
    return out


def say(log: list, text: str) -> str:
    log.append(("respond", text))
    return text


def do_write(task: Task, env: RetailEnv, log: list) -> None:
    if task.request == "cancel":
        tool(env, log, "cancel_order", order_id=task.order_id)
    else:
        tool(env, log, "refund", order_id=task.order_id, reason=task.reason)


# ---------------------------------------------------------------- graders
def calculate_reward(task: Task, env: RetailEnv, log: list, outputs: list[str]) -> float:
    """tau-bench style: state hash vs gold replay, then required outputs (substring match)."""
    agent_hash = env.data_hash()
    gold_env = RetailEnv()                       # fresh copy of the initial DB
    for a in task.gold:
        gold_env.step(a.name, **a.kwargs)
    if agent_hash != gold_env.data_hash():
        return 0.0
    replies = [e[1].lower().replace(",", "") for e in log if e[0] == "respond"]
    for out in outputs:
        if not any(out.lower() in r for r in replies):
            return 0.0
    return 1.0


def confirmed_before_writes(log: list) -> bool:
    """Trajectory check for policy rule 3 (invisible to the state hash)."""
    confirmed = False
    for e in log:
        if e[0] == "user" and e[1] == "yes":
            confirmed = True
        if e[0] == "tool" and e[1].name in RetailEnv.WRITE_TOOLS and not confirmed:
            return False
    return True


AGENTS = {"correct": correct_agent, "sloppy": sloppy_agent, "do-nothing": do_nothing_agent}


def main() -> None:
    print("Policy:\n" + POLICY + "\n")
    g0 = RetailEnv().data_hash()
    print(f"initial DB hash: {g0[:16]}...  (impossible tasks T3, T4 and the read-only T5 have gold hash == initial hash)\n")
    header = f"{'agent':<11} {'grader':<26}" + "".join(f"{t.tid[:2]:>4}" for t in TASKS) + "   score"
    print(header)
    scores = {}
    for aname, agent in AGENTS.items():
        rows = {"v1: hash + outputs": [], "v2: + refusal required": [], "trajectory: confirm-first": []}
        for task in TASKS:
            env, log = RetailEnv(), []
            user = UserSim(task)
            log.append(("user", user.first_message()))
            agent(task, env, user, log)
            rows["v1: hash + outputs"].append(calculate_reward(task, env, log, task.outputs_v1))
            rows["v2: + refusal required"].append(calculate_reward(task, env, log, task.outputs_v2))
            rows["trajectory: confirm-first"].append(float(confirmed_before_writes(log)))
        for gname, vals in rows.items():
            score = sum(vals) / len(vals)
            scores[(aname, gname[:2])] = score
            cells = "".join(f"{int(v):>4}" for v in vals)
            print(f"{aname:<11} {gname:<26}{cells}   {score:5.0%}")
        print()

    assert scores[("do-nothing", "v1")] == 0.4 and scores[("do-nothing", "v2")] == 0.0
    assert scores[("correct", "v1")] == 1.0 and scores[("correct", "v2")] == 1.0
    assert scores[("sloppy", "v1")] == 0.8 and scores[("sloppy", "v2")] == 0.6
    assert scores[("sloppy", "tr")] == 0.2      # attempted writes without confirmation on T1-T4
    assert scores[("do-nothing", "tr")] == 1.0  # vacuously true: no writes, no violations
    print("do-nothing: 40% under v1 (passes both impossible tasks), 0% under v2.")
    print("sloppy: T4 passes v1 although it said 'All done!' after a failed cancel; v2 catches it.")
    print("trajectory check: sloppy fails 4/5, but do-nothing passes it vacuously -> combine graders.")


if __name__ == "__main__":
    main()
