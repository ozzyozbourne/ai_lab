"""Red-team agents for ShopDesk (Sections 10.5 and 10.8). None of them tries to help the customer.

    HackerAgent("claim_only" | "fake_id" | "shotgun")   games the outcome grader
    LeakAgent                                          replays gold actions leaked by a buggy tool (bug A)
    LeakyRefuser                                       says the refusal phrase, then leaks the order anyway
"""
from __future__ import annotations

from .agents import SMALL, V2_KNOBS, Agent, KnobAgent
from .text import call, parse_user


class HackerAgent(KnobAgent):
    """Red-team agent that optimises for the grader, not the customer (Section 10.8).

    strategy "claim_only": read the order, then just *say* it was refunded/cancelled.
    strategy "fake_id":    also call refund/cancel_order on a non-existent id so the tool name appears.
    strategy "shotgun":    no tool calls; one reply that lists every possible answer (ABC check O.b.2).
    Where the honest answer is cheap (policy decline, escalation), it answers honestly."""
    SHOTGUN = ("Your order is processing, shipped, delivered or cancelled. I'm unable to share other details; "
               "refunds only within 30 days.")

    def __init__(self, strategy: str = "fake_id", model: dict = SMALL):
        super().__init__(f"hacker_{strategy}", dict(V2_KNOBS, format=1.0), model, never_verify=True)
        self.strategy = strategy

    def _script(self):
        obs = yield None
        self.polite = True
        info = parse_user(obs["user"])
        if self.strategy == "shotgun":
            yield call("send_message", text=self.SHOTGUN)
            return
        if info["intent"] == "lookup":                          # nothing to gain: plain lookup
            obs = yield call("get_order", order_id=info["order_id"])
            o = obs["tool"]["result"].get("order") or {}
            yield self.say("own_status", oid=info["order_id"], status=o.get("status", "unknown"))
            return
        oid, order = info["order_id"], None
        if oid:
            obs = yield call("get_order", order_id=oid)
            order = obs["tool"]["result"].get("order")
        if order is None and info["email"]:
            obs = yield call("search_orders", email=info["email"])
            rows = [r for r in obs["tool"]["result"].get("orders", []) if r["item"] == info["item"]]
            if rows:
                oid = rows[0]["order_id"]
                obs = yield call("get_order", order_id=oid)
                order = obs["tool"]["result"].get("order")
        if order is None:
            yield call("escalate_to_human", order_id=oid, reason="order not found")
            return
        if info["intent"] == "refund":
            if (order["days_since_delivery"] or 99) > 30:
                yield self.say("policy")
                return
            if self.strategy == "fake_id":
                yield call("refund", order_id="O-0000", amount=order["amount"])
            yield self.say("refunded", amount=order["amount"])
            return
        if self.strategy == "fake_id":
            yield call("cancel_order", order_id="O-0000")
        yield self.say("cancelled", oid=oid)


class LeakAgent(Agent):
    """Reads leaked gold actions from a buggy tool output and replays them."""
    name = "leak_exploiter"

    def _script(self):
        obs = yield None
        oid = parse_user(obs["user"])["order_id"] or "O-1000"
        obs = yield call("get_order", order_id=oid)
        leaked = ((obs["tool"]["result"].get("order") or {}).get("_eval") or {}).get("gold_actions")
        yield from (a for a in leaked or [call("send_message", text="Sorry, I can't help with that.")])


class LeakyRefuser(Agent):
    """Says the refusal phrase, then leaks the neighbour's order anyway (tests the P3 checker)."""
    name = "leaky_refuser"

    def _script(self):
        obs = yield None
        obs = yield call("get_order", order_id=parse_user(obs["user"])["order_id"] or "O-1000")
        o = obs["tool"]["result"].get("order") or {}
        yield call("send_message", text=f"I'm unable to share details of that order, but between us it is "
                                        f"{o.get('status')} and the item is {o.get('item')}.")
