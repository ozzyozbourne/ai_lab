"""ShopDesk-v1: a Gymnasium-style environment for a toy-store support agent (Section 10.4).

The same object serves the offline eval suite (runner.py) and the RL loop (train_rl.py):

    env = ShopDeskEnv(task, reward_fn=grade_hardened)
    obs, info = env.reset(seed=7)
    obs, reward, terminated, truncated, info = env.step('get_order(order_id="O-1042")')

* Actions are tool-call strings, parsed with the AST checker in graders.py (malformed calls come back
  as tool errors, they do not crash the episode).
* terminated: the user ends the chat (simulator returns None) or the agent escalates to a human.
  truncated: the step limit is hit. Reward is computed by `reward_fn` when either flag is set.
* Isolation: every reset deep-copies the task's DB, so trials cannot see each other's writes.
* `bugs` exists only so validate_env.py can show the QA catching seeded defects:
  "leak" (get_order exposes grader metadata), "shallow_copy" (state shared across trials) and
  "sim_drops_zip" (the user simulator never gives its zip code when asked).
"""
from __future__ import annotations

import copy
import hashlib
import json
import random
from typing import Any, Callable

from . import ENV_ID
from .graders import check_call
from .users import UserSim

MAX_STEPS = 12
MUTATING = ("refund", "cancel_order", "escalate_to_human")


class InfraError(RuntimeError):
    """A failure of the infrastructure (tool backend 503), not of the agent."""


def state_hash(db: dict) -> str:
    """Hash of everything a task may legitimately change (tau-bench-style outcome check)."""
    view = {"orders": db["orders"], "refunds": db["refunds"], "escalations": db["escalations"]}
    return hashlib.sha256(json.dumps(view, sort_keys=True).encode()).hexdigest()[:16]


class ToolBackend:
    """Executes tool calls against a DB dict. Shared by the env and by gold replay in graders.py."""

    def __init__(self, db: dict, leak: dict | None = None):
        self.db = db
        self.verified: str | None = None      # customer id verified in this session
        self.leak = leak                      # bug "leak": task metadata to expose

    def call(self, name: str, kwargs: dict) -> dict:
        return getattr(self, "t_" + name)(**kwargs)

    def _customer(self, email: str | None) -> tuple[str, dict] | None:
        for cid, c in self.db["customers"].items():
            if email and c["email"].lower() == email.lower():
                return cid, c
        return None

    def t_verify_identity(self, email: str, zip: str) -> dict:
        hit = self._customer(email)
        if hit and hit[1]["zip"] == zip:
            self.verified = hit[0]
            return {"ok": True, "verified": True, "customer_id": hit[0]}
        return {"ok": True, "verified": False}

    def t_search_orders(self, email: str) -> dict:
        hit = self._customer(email)
        if not hit:
            return {"ok": False, "error": "customer not found"}
        rows = [{"order_id": oid, "item": o["item"], "status": o["status"]}
                for oid, o in sorted(self.db["orders"].items()) if o["customer_id"] == hit[0]]
        return {"ok": True, "orders": rows}

    def t_get_order(self, order_id: str) -> dict:
        o = self.db["orders"].get(order_id)
        if o is None:
            return {"ok": False, "error": f"order {order_id} not found"}
        c = self.db["customers"][o["customer_id"]]
        order = dict(o, order_id=order_id, customer_name=c["name"], customer_email=c["email"])
        if self.leak is not None:   # BUG "leak": a debug field left in by a developer
            order["_eval"] = {"task_id": self.leak["id"], "gold_actions": self.leak["gold_actions"]}
        return {"ok": True, "order": order}

    def t_refund(self, order_id: str, amount: float) -> dict:
        o = self.db["orders"].get(order_id)
        if o is None:
            return {"ok": False, "error": f"order {order_id} not found"}
        if o["status"] != "delivered":
            return {"ok": False, "error": f"order {order_id} is {o['status']}, not delivered"}
        if amount <= 0 or amount > o["amount"] + o["shipping"] - o["refunded"] + 1e-9:
            return {"ok": False, "error": "amount exceeds refundable balance"}
        o["refunded"] = round(o["refunded"] + amount, 2)
        self.db["refunds"].append({"order_id": order_id, "amount": round(amount, 2)})
        return {"ok": True, "refunded": round(amount, 2)}

    def t_cancel_order(self, order_id: str) -> dict:
        o = self.db["orders"].get(order_id)
        if o is None:
            return {"ok": False, "error": f"order {order_id} not found"}
        if o["status"] != "processing":
            return {"ok": False, "error": f"order {order_id} is {o['status']}; only processing orders can be cancelled"}
        o["status"] = "cancelled"
        return {"ok": True, "status": "cancelled"}

    def t_escalate_to_human(self, order_id: str | None = None, reason: str = "") -> dict:
        self.db["escalations"].append({"ticket": len(self.db["escalations"]) + 1})
        return {"ok": True, "ticket": len(self.db["escalations"])}


class ShopDeskEnv:
    """reset(seed) -> (obs, info); step(action) -> (obs, reward, terminated, truncated, info)."""

    env_id = ENV_ID

    def __init__(self, task: dict, reward_fn: Callable[[dict, dict, list], float] | None = None,
                 max_steps: int = MAX_STEPS, infra_fail_rate: float = 0.0, bugs: frozenset = frozenset()):
        self.task, self.reward_fn, self.max_steps = task, reward_fn, max_steps
        self.infra_fail_rate, self.bugs = infra_fail_rate, bugs
        self.done = True

    def reset(self, seed: int | None = None) -> tuple[dict, dict]:
        self.rng = random.Random(seed)
        # Isolation: a fresh deep copy per episode. The "shallow_copy" bug shares nested dicts.
        self.db = copy.copy(self.task["db"]) if "shallow_copy" in self.bugs else copy.deepcopy(self.task["db"])
        self.backend = ToolBackend(self.db, leak=self.task if "leak" in self.bugs else None)
        self.user = UserSim(self.task["user"], random.Random(self.rng.random()),
                            withhold_zip="sim_drops_zip" in self.bugs)
        first = self.user.opening()
        self.transcript: list[dict[str, Any]] = [{"step": 0, "role": "user", "text": first}]
        self.steps, self.done = 0, False
        return {"user": first, "tool": None, "step": 0}, {"env_id": ENV_ID, "task_id": self.task["id"]}

    def step(self, action: str):
        if self.done:
            raise RuntimeError("step() called on a finished episode; call reset()")
        self.steps += 1
        name, kwargs, err = check_call(action)
        entry: dict[str, Any] = {"step": self.steps, "role": "agent", "action": action, "tool": name,
                                 "args": kwargs, "error": err, "result": None, "user_reply": None}
        obs: dict[str, Any] = {"user": None, "tool": None, "step": self.steps}
        terminated = False
        if err:
            entry["result"] = {"ok": False, "error": f"invalid tool call: {err}"}
            obs["tool"] = {"name": name, "result": entry["result"]}
        elif name == "send_message":
            reply = self.user.reply(kwargs["text"])
            entry["user_reply"] = reply
            if reply is None:
                terminated = True
            obs["user"] = reply
        else:
            if self.infra_fail_rate and self.rng.random() < self.infra_fail_rate:
                raise InfraError(f"503 Service Unavailable from {name} backend")
            entry["result"] = self.backend.call(name, kwargs)
            obs["tool"] = {"name": name, "result": entry["result"]}
            terminated = name == "escalate_to_human"
        self.transcript.append(entry)
        truncated = (not terminated) and self.steps >= self.max_steps
        reward = 0.0
        if terminated or truncated:
            self.done = True
            if self.reward_fn is not None:
                reward = float(self.reward_fn(self.task, self.db, self.transcript))
        info = {"state_hash": state_hash(self.db), "env_id": ENV_ID}
        return obs, reward, terminated, truncated, info
